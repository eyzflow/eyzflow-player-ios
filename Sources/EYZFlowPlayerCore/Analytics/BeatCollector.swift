import Foundation

/// Where the impression is. Time is added to the state being left.
public enum BeatState: Sendable, Hashable {
    case startup, playing, paused, buffering, seeking, ended, error
}

/// Watches one impression (one video loaded in the player) and keeps its
/// quality counters: how long it took to start, how long it played, paused
/// and stalled, how often it stalled and was sought, and its errors.
///
/// The web player's `AnalyticsCollector`, fed by calls instead of DOM events:
/// the player reports state changes as [`PlaybackEvent`]s, which
/// [`PlaybackEventAdapter`] turns into these calls.
@MainActor
public final class BeatCollector {
    static let maxErrors = 20

    /// A buffering that starts this soon after a seek is the seek loading,
    /// not a stall: the web player counts neither (`seeking` state).
    static let seekSettleMs = 3000

    private let now: MonotonicClock
    private let createdAt: Int
    private var since: Int
    public private(set) var state: BeatState = .startup
    private var isReady = false
    private var everPlayed = false
    private var playerStartupMs: Int?
    private var videoStartupMs: Int?
    private var playedMs = 0
    private var pausedMs = 0
    private var rebufferMs = 0
    private var rebufferCount = 0
    private var seekCount = 0
    private var maxPositionS: Double = 0
    private var durationS: Double?
    private var positionS: Double?
    private var positionAt = 0
    private var lastSeekAt: Int?
    private var errorCount = 0
    private var pending: [BeatError] = []

    /// Called on the first frame and on errors, so the transport sends a beat
    /// at once.
    public var onMilestone: (@MainActor () -> Void)?

    public init(now: MonotonicClock? = nil) {
        self.now = now ?? makeMonotonicClock()
        createdAt = self.now()
        since = createdAt
    }

    /// The player is initialized and can play: its own startup is over.
    public func ready(position: Duration? = nil, duration: Duration? = nil) {
        observe(position, duration)
        if isReady { return }
        isReady = true
        playerStartupMs = now() - createdAt
    }

    /// The player reports playing. The first time, that is the first frame.
    public func playing(position: Duration? = nil, duration: Duration? = nil) {
        observe(position, duration)
        if !everPlayed {
            everPlayed = true
            if !isReady { ready() }
            videoStartupMs = now() - createdAt
            enter(.playing)
            onMilestone?()
            return
        }
        if state == .ended || state == .error { return }
        enter(.playing)
    }

    public func paused(position: Duration? = nil, duration: Duration? = nil) {
        observe(position, duration)
        if !everPlayed { return }
        if state == .ended || state == .error { return }
        enter(.paused)
    }

    public func bufferingStarted(position: Duration? = nil, duration: Duration? = nil) {
        observe(position, duration)
        guard everPlayed, state == .playing else { return }
        if let lastSeekAt, now() - lastSeekAt <= Self.seekSettleMs {
            enter(.seeking)
            return
        }
        rebufferCount += 1
        enter(.buffering)
    }

    /// Buffering ended; `isPlaying` says whether playback carries on.
    public func bufferingEnded(position: Duration? = nil, duration: Duration? = nil, isPlaying: Bool = true) {
        observe(position, duration)
        guard state == .buffering || state == .seeking else { return }
        enter(isPlaying ? .playing : .paused)
    }

    public func seeked(to: Duration, duration: Duration? = nil) {
        if !everPlayed || state == .ended {
            observe(to, duration, seek: true)
            return
        }
        // Counts the time played up to the seek at the old position.
        maxPositionS = max(maxPositionS, estimatedPositionS())
        observe(to, duration, seek: true)
        seekCount += 1
        lastSeekAt = now()
    }

    public func completed(position: Duration? = nil, duration: Duration? = nil) {
        observe(position, duration)
        enter(.ended)
    }

    /// An error the viewer met. Kept once per impression up to 20; a fatal one
    /// ends the impression.
    public func error(
        code: String,
        category: String? = nil,
        message: String? = nil,
        fatal: Bool = true,
        position: Duration? = nil
    ) {
        observe(position, nil)
        if errorCount < Self.maxErrors {
            pending.append(
                BeatError(
                    n: errorCount,
                    code: cut(code, 64),
                    category: category.map { cut($0, 32) },
                    message: message.map { cut($0, 300) },
                    positionS: estimatedPositionSOrNil()
                )
            )
        }
        errorCount += 1
        if fatal { enter(.error) }
        onMilestone?()
    }

    /// A position report with no state change.
    public func position(_ position: Duration?, duration: Duration? = nil) {
        observe(position, duration)
    }

    /// The counters so far, the time in the current state included.
    public func metrics() -> BeatMetrics {
        let open = now() - since
        var played = playedMs
        var paused = pausedMs
        var rebuffer = rebufferMs
        switch state {
        case .playing: played += open
        case .paused: paused += open
        case .buffering: rebuffer += open
        default: break
        }
        return BeatMetrics(
            playerStartupMs: playerStartupMs,
            videoStartupMs: videoStartupMs,
            playedMs: played,
            pausedMs: paused,
            rebufferMs: rebuffer,
            rebufferCount: rebufferCount,
            seekCount: seekCount,
            maxPositionS: max(maxPositionS, estimatedPositionS()),
            durationS: durationS
        )
    }

    /// The errors not yet sent, once.
    public func takeErrors() -> [BeatError] {
        let out = pending
        pending = []
        return out
    }

    /// Errors that could not be sent go back to be sent with the next beat.
    public func returnErrors(_ errors: [BeatError]) {
        pending = Array((errors + pending).prefix(Self.maxErrors))
    }

    private func enter(_ next: BeatState) {
        if next == state { return }
        let now = now()
        let spent = now - since
        switch state {
        case .playing:
            playedMs += spent
            positionS = estimatedPositionSOrNil()
            positionAt = now
        case .paused:
            pausedMs += spent
        case .buffering:
            rebufferMs += spent
        default:
            break
        }
        maxPositionS = max(maxPositionS, positionS ?? 0)
        state = next
        since = now
    }

    private func observe(_ position: Duration?, _ duration: Duration?, seek: Bool = false) {
        if let duration, duration > .zero {
            durationS = Double(duration.inMilliseconds) / 1000
        }
        guard let position else { return }
        let seconds = Double(position.inMilliseconds) / 1000
        if !seek { maxPositionS = max(maxPositionS, seconds) }
        positionS = seconds
        positionAt = now()
    }

    /// The players report a position only with a state change, so while
    /// playing the position is the last report plus the time since, up to the
    /// duration.
    private func estimatedPositionSOrNil() -> Double? {
        guard let known = positionS else { return nil }
        if state != .playing { return known }
        let estimate = known + Double(now() - positionAt) / 1000
        if let durationS, estimate > durationS { return durationS }
        return estimate
    }

    private func estimatedPositionS() -> Double {
        estimatedPositionSOrNil() ?? 0
    }
}

/// The first `max` UTF-16 code units, as Dart's `substring` counts.
private func cut(_ value: String, _ max: Int) -> String {
    let units = value.utf16
    guard units.count > max else { return value }
    let end = units.index(units.startIndex, offsetBy: max)
    return String(units[..<end]) ?? String(value.prefix(max))
}
