import Foundation

extension PlayerConfig {
    /// The ad tag to play: set only when `features.ads` is on and
    /// `ads.adTagUrl` is not empty (trimmed). Nil means no ad request at all.
    public var adTagToPlay: String? {
        guard features.ads else { return nil }
        let url = ads?.adTagURL.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return url.isEmpty ? nil : url
    }
}

/// Ads for one impression: the config's ad tag, the stream's markers and
/// what has been played.
///
/// One per playback. It outlives the player, so when casting hands playback
/// back to the phone (a fresh player), the pre-roll and the breaks already
/// played do not play again.
@MainActor
public final class PlayerAds {
    /// The VAST or VMAP tag, requested from the ad server through Google IMA.
    public let adTagURL: String

    /// The stream's ad break markers, as read from its manifest.
    public private(set) var schedule = AdBreakSchedule()

    private var markers: Task<Void, Never>?
    fileprivate var prerollTaken = false

    public init(adTagURL: String) {
        self.adTagURL = adTagURL
    }

    /// Reads the markers once per impression, with `load`.
    public func loadMarkers(_ load: @escaping @MainActor () async -> [AdBreak]) {
        guard markers == nil else { return }
        markers = Task { @MainActor [weak self] in
            let breaks = await load()
            self?.schedule.add(breaks)
        }
    }

    /// Waits until the markers are read (at once when no read was started).
    public func markersLoaded() async {
        await markers?.value
    }

    fileprivate func takePreroll() -> AdBreak? { schedule.takePreroll() }
    fileprivate func due(from previous: Duration, to current: Duration) -> AdBreak? {
        schedule.due(from: previous, to: current)
    }
}

/// What [`AdBreakScheduler`] asks of the ad SDK and the content player.
@MainActor
public protocol AdDriver: AnyObject {
    /// Requests the ad tag. The answer comes back through
    /// `AdBreakScheduler.adsLoaded(cuePoints:)` or `adsFailed()`.
    func requestAds()
    /// Starts the loaded ads: a VAST ad, or a VMAP's pre-roll.
    func startAds()
    /// Drops the ads manager. Whatever it still had scheduled never plays,
    /// and a late answer to a request still out is dropped too.
    func discardAds()
    /// The content played to its end: a VMAP's post-roll may play now.
    func contentComplete()
    func pauseContent()
    func resumeContent()
}

/// When ads play: the same rules as the web and Flutter players.
///
/// - A stream without ad break markers requests the tag once, before the
///   content starts, and lets it decide: a VAST pre-roll, or a VMAP's own
///   schedule (pre-roll, mid-rolls at its cue points, post-roll).
/// - A stream with markers plays ads only at them. A marker at the start is a
///   pre-roll; every other marker is a mid-roll, requested from the tag when
///   playback reaches it, each played once. Markers passed by seeking are not
///   played. After each break the ads manager is dropped, so a VMAP's own
///   mid-rolls and post-roll never play: at a marker only a VMAP's pre-roll
///   plays, and one without a pre-roll gives no ad there.
/// - The content waits at a break until the ad starts, or until it turns out
///   there is none (an empty, failed or blocked tag, or no answer within
///   `guardTime`): then it plays on, with no error.
///
/// Free of IMA and AVFoundation: an [`AdDriver`] does that work.
@MainActor
public final class AdBreakScheduler {
    private enum Mode {
        /// The stream has ad break markers: ads play only at them.
        case markers
        /// No markers: the tag decides.
        case tag
    }

    public let ads: PlayerAds
    public weak var driver: (any AdDriver)?
    /// How long the content waits for an ad to start before it plays on.
    public let guardTime: Duration
    private let scheduler: any PlaybackScheduler
    private let suppressed: @MainActor () -> Bool

    /// An ad break began: the content stopped (or waits) for it.
    public var onBreakStarted: (@MainActor () -> Void)?
    /// The ad break is over (played, empty, failed or timed out).
    public var onBreakEnded: (@MainActor () -> Void)?
    /// `inBreak`, `adPlaying` or `containerNeeded` may have changed.
    public var onChange: (@MainActor () -> Void)?

    private var mode: Mode = .tag
    private var disposed = false
    private var requesting = false
    private var managerAlive = false
    public private(set) var inBreak = false
    public private(set) var adPlaying = false
    private var pausedContent = false
    private var cuePoints: [Duration] = []
    /// A VMAP's mid-roll cue points, for the countdown before them (no
    /// markers only).
    private var cueSchedule = AdCuePointSchedule()
    private var guardTimer: (any PlaybackTimer)?
    private var hold: Gate?
    private var lastPosition: Duration?
    /// The content played to its end: a post-roll neither pauses nor resumes
    /// it.
    private var contentEnded = false

    /// - Parameter suppressed: true while no ads may start, e.g. while the
    ///   video plays on AirPlay.
    public init(
        ads: PlayerAds,
        driver: any AdDriver,
        guardTime: Duration = .seconds(12),
        scheduler: any PlaybackScheduler = TaskScheduler(),
        suppressed: @escaping @MainActor () -> Bool = { false }
    ) {
        self.ads = ads
        self.driver = driver
        self.guardTime = guardTime
        self.scheduler = scheduler
        self.suppressed = suppressed
    }

    /// The ads SDK needs its display container on screen: an ad is
    /// requested, playing, or (a VMAP without markers) still scheduled.
    public var containerNeeded: Bool { requesting || managerAlive }

    /// The countdown before the next mid-roll at `position`: whole seconds
    /// (`length` … 1) or nil for no notice. It counts towards the stream's unplayed
    /// mid-roll markers, or on a stream without markers a VMAP's mid-roll cue
    /// points not yet played through. Nil during a break, while no ads may
    /// start (AirPlay), and once disposed. The player hides it while paused
    /// or seeking, and when the config turns it off.
    public func countdown(at position: Duration, length: Int = AdCountdown.defaultLength) -> Int? {
        guard !disposed, !inBreak, !requesting, !adPlaying, !suppressed() else { return nil }
        let starts = ads.schedule.hasBreaks ? ads.schedule.upcomingMidrollStarts : cueSchedule.upcoming
        return AdCountdown.seconds(at: position, breakStarts: starts, length: length)
    }

    /// Awaited before the content first plays: a pre-roll, if there is one,
    /// plays first. Returns when it is over, or at once when there is none.
    public func beforeContent() async {
        if disposed || ads.prerollTaken { return }
        await ads.markersLoaded()
        if disposed || ads.prerollTaken { return }
        ads.prerollTaken = true
        if suppressed() { return }
        if ads.schedule.hasBreaks {
            mode = .markers
            if ads.takePreroll() == nil { return }
        } else {
            mode = .tag
        }
        let gate = Gate()
        hold = gate
        beginBreak()
        request()
        await gate.wait()
    }

    /// A position report from the content player.
    public func contentPosition(_ position: Duration) {
        let previous = lastPosition
        lastPosition = position
        if let previous { cueSchedule.pass(from: previous, to: position) }
        guard !disposed, let previous, ads.schedule.hasBreaks, !inBreak, !requesting, !suppressed() else { return }
        guard ads.due(from: previous, to: position) != nil else { return }
        mode = .markers
        beginBreak()
        pausedContent = true
        driver?.pauseContent()
        request()
    }

    /// The content jumped (a seek): the next report is measured from here.
    public func contentSeeked(to position: Duration) {
        lastPosition = position
    }

    /// The content played to its end. Returns once a VMAP's post-roll is
    /// over, or at once when there is none.
    public func contentCompleted() async {
        guard !disposed, mode == .tag, managerAlive, !inBreak, !suppressed(),
              cuePoints.contains(where: { $0 < .zero }) else { return }
        contentEnded = true
        let gate = Gate()
        hold = gate
        startGuard()
        driver?.contentComplete()
        await gate.wait()
    }

    /// IMA loaded the tag. `cuePoints` are a VMAP's break positions (zero is
    /// its pre-roll, a negative one its post-roll); a VAST has none.
    public func adsLoaded(cuePoints: [Duration]) {
        if disposed { return }
        requesting = false
        managerAlive = true
        if !inBreak {
            // The break already gave up waiting for it.
            discard()
            onChange?()
            return
        }
        self.cuePoints = cuePoints
        if mode == .tag { cueSchedule.set(cuePoints) }
        let hasPreroll = cuePoints.isEmpty || cuePoints.contains(.zero)
        if mode == .markers, !hasPreroll {
            // A VMAP with no pre-roll: nothing for this marker.
            breakOver()
            return
        }
        driver?.startAds()
        if !hasPreroll {
            // A VMAP without a pre-roll: the content starts, and IMA asks for
            // it to pause at its own cue points.
            breakOver()
            return
        }
        onChange?()
    }

    /// The tag could not be loaded: empty, blocked, failed or timed out.
    public func adsFailed() {
        if disposed { return }
        requesting = false
        if inBreak || hold != nil {
            breakOver(drop: true)
        } else {
            discard()
            onChange?()
        }
    }

    /// IMA starts an ad break: the content must pause.
    public func contentPauseRequested() {
        if disposed { return }
        cancelGuard()
        if !inBreak {
            // A VMAP's own mid-roll or post-roll, on a stream without markers.
            beginBreak()
            if !contentEnded {
                pausedContent = true
                driver?.pauseContent()
            }
        }
        adPlaying = true
        onChange?()
    }

    /// IMA's ad break is over: the content plays on.
    public func contentResumeRequested() {
        guard !disposed, inBreak else { return }
        breakOver()
    }

    /// Every ad the tag scheduled has played.
    public func allAdsCompleted() {
        if disposed { return }
        breakOver(drop: true)
    }

    /// An ad failed while loading or playing. Outside a break IMA carries on
    /// with the rest of its schedule.
    public func adError() {
        guard !disposed, inBreak else { return }
        breakOver()
    }

    /// Ends everything: a break under way ends, the content is not resumed.
    public func dispose() {
        if disposed { return }
        disposed = true
        cancelGuard()
        if inBreak { onBreakEnded?() }
        inBreak = false
        adPlaying = false
        let gate = hold
        hold = nil
        gate?.open()
        driver?.discardAds()
    }

    private func request() {
        requesting = true
        startGuard()
        driver?.requestAds()
        onChange?()
    }

    private func beginBreak() {
        inBreak = true
        onBreakStarted?()
    }

    private func startGuard() {
        cancelGuard()
        guardTimer = scheduler.schedule(after: guardTime) { [weak self] in
            guard let self, !self.disposed else { return }
            self.guardTimer = nil
            self.breakOver(drop: true)
        }
    }

    private func cancelGuard() {
        guardTimer?.cancel()
        guardTimer = nil
    }

    /// Ends the current break, if any, and drops the ads manager unless a
    /// VMAP on a stream without markers still has breaks to come.
    private func breakOver(drop: Bool = false) {
        cancelGuard()
        let wasInBreak = inBreak
        inBreak = false
        adPlaying = false
        let keep = !drop && mode == .tag && managerAlive && cuePoints.contains { $0 != .zero }
        if !keep { discard() }
        if wasInBreak { onBreakEnded?() }
        let gate = hold
        hold = nil
        gate?.open()
        if pausedContent {
            pausedContent = false
            driver?.resumeContent()
        }
        onChange?()
    }

    /// Also when no manager is loaded yet: a request may be out, and the
    /// driver drops its late answer.
    private func discard() {
        requesting = false
        managerAlive = false
        cuePoints = []
        cueSchedule.set([])
        driver?.discardAds()
    }
}

/// A one-shot latch: `wait()` returns once `open()` was called.
@MainActor
private final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
