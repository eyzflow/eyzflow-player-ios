#if os(iOS) || os(tvOS)
import AVFoundation
import EYZFlowPlayerCore
import Foundation
#if canImport(GoogleInteractiveMediaAds)
import UIKit
#endif

/// One playback, without UI: the EYZFlow rules (key check, session, access
/// token, beats) around an `AVPlayer` with FairPlay, its events and the
/// film's watch progress. `EYZFlowPlayerViewController` shows it; an app with
/// its own player UI can drive it directly.
@MainActor
public final class EYZFlowPlayback {
    /// Where the playback is.
    public enum State: Sendable, Equatable {
        /// Checking the key, opening the session, loading the stream.
        case loading
        /// The player has the stream; show `player`.
        case playing
        /// A TV plays it; the phone shows the casting screen.
        case casting
        /// Stopped with a viewer-facing message.
        case failed(message: String)
        /// Closed.
        case closed
    }

    public let options: EYZFlowPlayerOptions
    /// The player, once the stream is mounted.
    public private(set) var player: AVPlayer?
    public private(set) var state: State = .loading {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    /// Called on every state change.
    public var onStateChange: (@MainActor (State) -> Void)?

    private let coordinator: PlaybackCoordinator
    private let tracker: PlaybackEventTracker
    private let recorder: WatchProgressRecorder?
    private var keyLoader: FairPlayKeyLoader?
    private var item: AVPlayerItem?
    private var observations: [NSKeyValueObservation] = []
    private var notificationTokens: [any NSObjectProtocol] = []
    private var timeObserver: Any?
    /// Finds seeks in the ticks and time jumps; see `SeekDetector`.
    private var seeks = SeekDetector()
    private var resumed = false
    private var resumeSeconds: Double?
    private var accessHeader: String?

    #if canImport(GoogleInteractiveMediaAds)
    /// Shows the ads; without one (an app with its own player UI) no ads
    /// play.
    weak var adHost: (any AdContainerHost)?
    /// The impression's ads, from the player config; nil plays none.
    private var ads: PlayerAds?
    /// The current player's ad breaks.
    private var adScheduler: AdBreakScheduler?
    private var adDriver: IMAAdDriver?
    /// A time jump (a seek) since the last position report: the countdown
    /// hides until the next one.
    private var adSeeking = false

    /// Shows the countdown before a mid-roll ("Ad in 5" … "Ad in 1") when ads
    /// play for this viewer. Set from the player config's
    /// `features.adCountdown` (missing is on) when the playback starts; the
    /// app may change it any time after, without reloading the stream.
    public var showsAdCountdown = true {
        didSet { if showsAdCountdown != oldValue { updateAdCountdown() } }
    }

    /// How many seconds before a mid-roll the countdown starts (1…30). Set
    /// from the config's `ads.countdownSeconds` (missing: 5) when the
    /// playback starts; the app may change it any time after, without
    /// reloading the stream. Values outside 1…30 are clamped.
    public var adCountdownLength = AdCountdown.defaultLength {
        didSet {
            // Assigning here does not call didSet again.
            adCountdownLength = AdCountdown.length(Double(adCountdownLength))
            if adCountdownLength != oldValue { updateAdCountdown() }
        }
    }

    /// The seconds (`adCountdownLength` … 1) until a mid-roll starts while its countdown shows;
    /// otherwise nil. Hidden while paused, seeking, during a break, on AirPlay
    /// or casting, and when the viewer seeks past the break.
    public private(set) var adCountdown: Int?

    /// Called when `adCountdown` changes. The player screen shows it itself.
    public var onAdCountdownChange: (@MainActor (Int?) -> Void)?
    #endif

    public init(options: EYZFlowPlayerOptions) {
        self.options = options
        coordinator = PlaybackCoordinator(
            config: PlaybackCoordinatorConfig(
                streamID: options.streamID,
                isProtected: options.isProtected,
                playerKey: options.playerKey,
                configID: options.configID,
                drmAuthorization: options.drmAuthorization,
                storefrontID: options.storefrontID,
                drmParameters: options.drmParameters,
                deviceName: options.deviceName,
                app: .current,
                platform: .current,
                analytics: options.analytics
            ),
            licenseClient: PlayerLicenseClient(endpoints: options.endpoints),
            sessionClient: PlaybackSessionClient(endpoints: options.endpoints),
            beatSender: HTTPBeatSender(endpoints: options.endpoints).sender
        )
        tracker = PlaybackEventTracker(sourceID: options.streamID)
        recorder = options.watchProgressStore.map {
            WatchProgressRecorder(store: $0, sourceType: options.sourceType)
        }
        coordinator.onLimitReached = { [options] error in options.onLimitReached?(error) }
        coordinator.onLicenseError = { [options] error in options.onLicenseError?(error) }
        coordinator.onError = { [options] message in options.onError?(message) }
        coordinator.onStatusChange = { [weak self] status in
            if case .failed(let failure) = status { self?.stop(with: failure.message) }
        }
        tracker.onEvent = { [weak self] event in self?.handle(event) }
    }

    /// Checks the key, opens the session and mounts the stream. Returns once
    /// the player has the stream, or the playback failed.
    public func start() async {
        guard state == .loading, player == nil else { return }
        #if canImport(GoogleInteractiveMediaAds)
            async let adConfig = Self.adConfig(for: options)
            // The session answers before any ad request: the pre-roll is
            // requested only once the player is mounted, after this.
            await coordinator.start()
            let config = await adConfig
            showsAdCountdown = config.features.adCountdown
            adCountdownLength = config.ads?.countdownLength ?? AdCountdown.defaultLength
            setUpAds(adTag: adTagForPlayback(
                configTag: config.adTagToPlay,
                planAds: coordinator.planAds,
                targeting: coordinator.adTargeting
            ))
        #else
            await coordinator.start()
        #endif
        guard state == .loading else { return }
        switch coordinator.status {
        case .ready(let accessHeader):
            self.accessHeader = accessHeader
            mount(from: options.progressSeconds)
        case .failed(let failure):
            stop(with: failure.message)
        case .loading:
            break
        }
    }

    /// Ends the playback: the last position saved, the final beat sent and
    /// the session closed. Safe to call more than once.
    public func close() async {
        if state == .closed { return }
        let wasPlaying = player != nil || state == .casting
        player?.pause()
        if wasPlaying { recorder?.checkpoint(player != nil ? currentPosition : tracker.position) }
        tracker.close()
        teardown()
        state = .closed
        await recorder?.flush()
        await coordinator.close()
    }

    /// The app went to the background: save the position and send a beat.
    public func didEnterBackground() {
        guard player != nil || state == .casting else { return }
        recorder?.checkpoint(player != nil ? currentPosition : tracker.position)
        coordinator.onBackgrounded()
    }

    // MARK: Casting

    /// Hands playback to a TV: the phone's player stops where it is, and the
    /// returned media starts there on the TV with the phone's access token (so
    /// the TV counts as the phone's one stream). Nil when nothing plays.
    public func handOverToCast() -> CastMedia? {
        guard state == .playing, let player else { return nil }
        #if canImport(GoogleInteractiveMediaAds)
            if adScheduler?.inBreak == true { return nil }
        #endif
        let position = currentPosition
        player.pause()
        tracker.update(isReady: true, isPlaying: false, isBuffering: false, position: position, duration: currentDuration)
        recorder?.checkpoint(position)
        teardown()
        state = .casting
        return CastMedia.for(options.source, startAt: position, accessHeader: accessHeader)
    }

    /// What the TV reports while casting: it feeds the events, the beats and
    /// watch progress, as the phone's player would.
    public func castReported(_ playback: CastPlayback) {
        guard state == .casting else { return }
        tracker.update(
            isReady: true,
            isPlaying: playback.state == .playing,
            isBuffering: playback.state == .buffering,
            position: playback.position,
            duration: playback.duration
        )
        if playback.state == .playing { recorder?.report(playback.position) }
    }

    /// Casting ended. The film ending on the TV completes it; otherwise the
    /// phone plays on from where the TV was. `failure` is the viewer-facing
    /// text when the TV could not play it.
    public func castEnded(_ reason: CastEndReason, at position: Duration, failure: String? = nil) {
        guard state == .casting else { return }
        if reason == .finished {
            tracker.reachedEnd(position: position, duration: tracker.duration)
            recorder?.finish()
            return
        }
        if let failure { tracker.failed(message: failure) }
        recorder?.checkpoint(position)
        mount(from: position.inSecondsDouble)
    }

    // MARK: Mounting

    private func mount(from seconds: Double?) {
        let source = options.source
        resumeSeconds = seconds
        resumed = false
        groupsRequested = false
        seeks.reset(to: .milliseconds(Int64((seconds ?? 0) * 1000)))
        let asset = AVURLAsset(url: source.hlsStreamURL)
        if let accessHeader {
            let loader = FairPlayKeyLoader(
                configuration: .init(
                    certificateURL: source.fairplayCertificateURL,
                    licenseURL: source.fairplayLicenseURL,
                    headers: ["access-token": accessHeader]
                )
            )
            loader.onError = { [weak self] message in
                Task { @MainActor in self?.playbackFailed(message) }
            }
            // Before the item exists, so its keys come to the loader.
            loader.attach(asset)
            keyLoader = loader
        }
        let item = AVPlayerItem(asset: asset)
        #if os(tvOS)
            // The title and description in the tvOS info panel.
            item.externalMetadata = metadata()
        #endif
        self.item = item
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true
        self.player = player
        activateAudioSession()
        observe(player: player, item: item)
        state = .playing
        startContent(player)
    }

    /// Plays the content, after a pre-roll if there is one.
    private func startContent(_ player: AVPlayer) {
        #if canImport(GoogleInteractiveMediaAds)
            if let scheduler = makeAdScheduler(for: player) {
                Task { [weak self] in
                    await scheduler.beforeContent()
                    guard let self, self.adScheduler === scheduler, self.player === player else { return }
                    if self.options.autoplay { player.play() }
                }
                return
            }
        #endif
        if options.autoplay { player.play() }
    }

    #if os(tvOS)
    private func metadata() -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        func add(_ identifier: AVMetadataIdentifier, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            items.append(item)
        }
        add(.commonIdentifierTitle, options.title)
        add(.commonIdentifierDescription, options.description)
        return items
    }
    #endif

    private func activateAudioSession() {
        #if os(iOS) || os(tvOS)
            // Plays with the silent switch on, over AirPlay and in Picture in
            // Picture (which also needs the app's audio background mode).
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    // MARK: Observing

    private func observe(player: AVPlayer, item: AVPlayerItem) {
        observations = [
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.sync() }
            },
            item.observe(\.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.itemStatusChanged() }
            },
        ]
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reachedEnd() }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
                let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
                MainActor.assumeIsolated { self?.playbackFailed(message ?? "Playback failed") }
            },
            center.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.timeJumped() }
            },
            center.addObserver(forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.mediaSelectionChanged() }
            },
        ]
        // Every half second: ad breaks are found by the position moving on.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private var currentPosition: Duration {
        guard let time = player?.currentTime(), time.isNumeric else { return .zero }
        return .milliseconds(Int64((time.seconds * 1000).rounded()))
    }

    private var currentDuration: Duration? {
        guard let time = item?.duration, time.isNumeric, time.seconds > 0 else { return nil }
        return .milliseconds(Int64((time.seconds * 1000).rounded()))
    }

    private func sync() {
        #if canImport(GoogleInteractiveMediaAds)
            defer { updateAdCountdown() }
        #endif
        guard let player, let item else { return }
        let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        let isBuffering = waiting && player.reasonForWaitingToPlay != .noItemToPlay
        tracker.update(
            isReady: item.status == .readyToPlay,
            isPlaying: player.timeControlStatus == .playing,
            isBuffering: isBuffering,
            position: currentPosition,
            duration: currentDuration
        )
    }

    private func itemStatusChanged() {
        guard let item else { return }
        switch item.status {
        case .readyToPlay:
            resumeIfNeeded()
            loadMediaSelectionGroups()
            sync()
        case .failed:
            // A FairPlay failure says more than AVFoundation's generic error.
            let message = keyLoader?.lastErrorMessage
                ?? item.error?.localizedDescription
                ?? "Playback failed"
            playbackFailed(message)
        default:
            break
        }
    }

    private func resumeIfNeeded() {
        guard !resumed else { return }
        resumed = true
        guard let seconds = resumeSeconds, seconds > 0, let player else { return }
        // Not into the last seconds: resuming there would end at once.
        if let duration = currentDuration?.inSecondsDouble, seconds >= duration - 5 { return }
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
        seeks.reset(to: .milliseconds(Int64(seconds * 1000)))
    }

    private func tick() {
        let position = currentPosition
        // The time observer also fires on a jump, before the jump
        // notification: the seek is found here then.
        let seek = detectSeek(at: position)
        if tracker.isPlaying { recorder?.report(position) }
        sync()
        #if canImport(GoogleInteractiveMediaAds)
            if seek == nil { adSeeking = false }
            adScheduler?.contentPosition(position)
            updateAdCountdown()
        #endif
    }

    private func timeJumped() {
        detectSeek(at: currentPosition)
    }

    /// Reports the seek that got the playhead to `position`, if it was one.
    @discardableResult
    private func detectSeek(at position: Duration) -> Seek? {
        guard let seek = seeks.observe(position: position, rate: Double(player?.rate ?? 0)) else { return nil }
        #if canImport(GoogleInteractiveMediaAds)
            // Before the position reaches the ads: a break seeked over is
            // not one played through.
            adScheduler?.contentSeeked(to: seek.to)
            adSeeking = true
            updateAdCountdown()
        #endif
        tracker.seeked(from: seek.from, to: seek.to, duration: currentDuration)
        if tracker.hasStarted { recorder?.checkpoint(seek.to) }
        return seek
    }

    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var lastAudioLanguage: String?
    private var lastSubtitleLanguage: String?
    private var groupsRequested = false

    private func loadMediaSelectionGroups() {
        guard !groupsRequested, let asset = item?.asset else { return }
        groupsRequested = true
        Task { [weak self] in
            let audio = try? await asset.loadMediaSelectionGroup(for: .audible)
            let subtitles = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard let self else { return }
            audioGroup = audio
            subtitleGroup = subtitles
            if let item, let audio {
                lastAudioLanguage = item.currentMediaSelection.selectedMediaOption(in: audio)?.extendedLanguageTag
            }
            if let item, let subtitles {
                lastSubtitleLanguage = item.currentMediaSelection.selectedMediaOption(in: subtitles)?.extendedLanguageTag
            }
        }
    }

    private func mediaSelectionChanged() {
        guard let item else { return }
        let selection = item.currentMediaSelection
        if let audioGroup {
            let language = selection.selectedMediaOption(in: audioGroup)?.extendedLanguageTag
            if language != lastAudioLanguage {
                lastAudioLanguage = language
                tracker.audioTrackChanged(language: language)
            }
        }
        if let subtitleGroup {
            let language = selection.selectedMediaOption(in: subtitleGroup)?.extendedLanguageTag
            if language != lastSubtitleLanguage {
                lastSubtitleLanguage = language
                tracker.subtitleTrackChanged(language: language)
            }
        }
    }

    private func reachedEnd() {
        tracker.reachedEnd(position: currentPosition, duration: currentDuration)
        recorder?.finish()
        #if canImport(GoogleInteractiveMediaAds)
            // A VMAP's post-roll, on a stream without markers.
            if let adScheduler { Task { await adScheduler.contentCompleted() } }
        #endif
    }

    private func playbackFailed(_ message: String) {
        guard state == .playing || state == .loading else { return }
        tracker.failed(message: message)
        // The coordinator fails the playback itself (with the viewer's text)
        // when the message names a limit or key code; otherwise show it.
        if case .failed = coordinator.status { return }
        stop(with: message)
    }

    private func handle(_ event: PlaybackEvent) {
        coordinator.handle(event: event)
        if case .paused = event { recorder?.checkpoint(event.position) }
        options.onEvent?(event)
    }

    private func stop(with message: String) {
        guard state != .closed else { return }
        if case .failed = state { return }
        player?.pause()
        if player != nil { recorder?.checkpoint(tracker.position) }
        teardown()
        state = .failed(message: message)
    }

    private func teardown() {
        #if canImport(GoogleInteractiveMediaAds)
            if let adScheduler {
                self.adScheduler = nil
                adScheduler.dispose()
                adDriver = nil
                adHost?.adStateChanged(inBreak: false, adPlaying: false)
            }
            adSeeking = false
        #endif
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observations.forEach { $0.invalidate() }
        observations = []
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens = []
        player?.replaceCurrentItem(with: nil)
        player = nil
        item = nil
        keyLoader?.onError = nil
        keyLoader = nil
        #if canImport(GoogleInteractiveMediaAds)
            updateAdCountdown()
        #endif
    }
}

// MARK: - Ads

#if canImport(GoogleInteractiveMediaAds)
extension EYZFlowPlayback {
    /// The config for the ads: the dashboard config (when `configID` is set)
    /// with `options.config` over it. Its `adTagToPlay` is nil when
    /// `features.ads` is off or the tag is empty: then no ad request is made
    /// at all.
    fileprivate static func adConfig(for options: EYZFlowPlayerOptions) async -> PlayerConfig {
        var config = PlayerConfig.defaults
        if let id = options.configID, !id.isEmpty,
           let remote = await PlayerConfigClient(endpoints: options.endpoints).load(id) {
            config = remote
        }
        return config.merged(with: options.config)
    }

    /// `adTag` is the tag to request, the plan's rule and targeting applied;
    /// nil plays no ads (no pre-roll, no mid-rolls).
    fileprivate func setUpAds(adTag: String?) {
        guard let adTag, ads == nil else { return }
        let ads = PlayerAds(adTagURL: adTag)
        let master = options.source.hlsStreamURL
        ads.loadMarkers { await loadHLSAdBreaks(master: master) }
        self.ads = ads
    }

    /// The ad breaks for a new player, when the impression has ads and an
    /// ad host shows them.
    fileprivate func makeAdScheduler(for player: AVPlayer) -> AdBreakScheduler? {
        guard let ads, let adHost else { return nil }
        let driver = IMAAdDriver(adTagURL: ads.adTagURL, player: player, host: adHost)
        let scheduler = AdBreakScheduler(ads: ads, driver: driver) { [weak player] in
            // AirPlay: no ads on the TV.
            player?.isExternalPlaybackActive ?? false
        }
        driver.scheduler = scheduler
        scheduler.onBreakStarted = { [weak self] in self?.tracker.adBreakStarted() }
        scheduler.onBreakEnded = { [weak self] in self?.tracker.adBreakEnded() }
        scheduler.onChange = { [weak self, weak scheduler] in
            guard let self, let scheduler, scheduler === self.adScheduler else { return }
            self.adHost?.adStateChanged(inBreak: scheduler.inBreak, adPlaying: scheduler.adPlaying)
            self.updateAdCountdown()
        }
        adDriver = driver
        adScheduler = scheduler
        return scheduler
    }

    /// The ad host's view is on screen: a request waiting for it goes.
    func adContainerAppeared() {
        adDriver?.containerAppeared()
    }

    #if os(tvOS)
    /// Play/Pause on the Siri Remote during an ad: pauses or resumes the ad.
    func toggleAdPause() {
        adDriver?.togglePause()
    }
    #endif

    /// Works out the countdown before the next mid-roll and passes on a
    /// change. Only while ads play for this viewer (an ad scheduler exists),
    /// the config has it on, and the content plays (or buffers) on this
    /// device, not seeking.
    fileprivate func updateAdCountdown() {
        var seconds: Int?
        if showsAdCountdown, !adSeeking, state == .playing, let player, let adScheduler,
           player.timeControlStatus != .paused {
            seconds = adScheduler.countdown(at: currentPosition, length: adCountdownLength)
        }
        guard seconds != adCountdown else { return }
        adCountdown = seconds
        adHost?.adCountdownChanged(seconds)
        onAdCountdownChange?(seconds)
    }
}
#endif
#endif
