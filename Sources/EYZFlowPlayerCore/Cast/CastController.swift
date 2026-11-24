import Foundation

/// Finds Cast devices and opens connections to them.
@MainActor
public protocol CastBackend: AnyObject {
    /// One scan; every device found within `timeout`.
    func discover(timeout: Duration) async throws -> [CastTarget]
    /// Connects and launches the receiver `appID`.
    func connect(_ target: CastTarget, appID: String) async throws -> any CastConnection
}

/// One connection to a TV with the receiver running.
@MainActor
public protocol CastConnection: AnyObject {
    var onPlayback: (@MainActor (CastPlayback) -> Void)? { get set }
    var onError: (@MainActor (String) -> Void)? { get set }
    /// The TV closed the connection.
    var onClose: (@MainActor () -> Void)? { get set }
    func load(_ media: CastMedia)
    func play()
    func pause()
    func seek(to position: Duration)
    func requestStatus()
    func setActiveTracks(_ ids: [Int])
    /// Releases a superseded launch before it has loaded any media.
    func disconnect()
    /// Stops the media and closes the connection.
    func stop()
}

// Existing custom backends can continue to provide transport-only casting.
public extension CastConnection {
    func requestStatus() {}
    func setActiveTracks(_ ids: [Int]) {}
    func disconnect() {}
}

/// Where casting is.
public enum CastState: Sendable, Equatable {
    /// Not casting: the phone plays.
    case off
    /// Connecting to the TV and loading the media.
    case connecting(CastTarget)
    /// The TV plays.
    case active(CastTarget, CastPlayback)
    /// Casting failed; the phone plays again.
    case failed(CastTarget, reason: String)

    public var target: CastTarget? {
        switch self {
        case .off: nil
        case .connecting(let target), .active(let target, _), .failed(let target, _): target
        }
    }
}

/// Why casting ended.
public enum CastEndReason: Sendable, Equatable {
    /// The viewer stopped casting.
    case stopped
    /// The film played to its end on the TV.
    case finished
    /// The TV closed the connection: switched off, another phone took over,
    /// or the receiver was stopped from the TV.
    case disconnected
    /// The receiver could not play the media.
    case failed
}

/// Finds TVs, casts one film to one of them, and reports how it ends. The
/// Flutter package's `EYZFlowCastController`.
@MainActor
public final class CastController {
    private let backend: any CastBackend
    private let scheduler: any PlaybackScheduler
    /// How long the TV may take to start playing before casting counts as
    /// failed.
    public let loadTimeout: Duration
    private let log: @MainActor (String) -> Void

    /// Devices found by the last scan.
    public private(set) var devices: [CastTarget] = [] { didSet { onChange?() } }
    public private(set) var isScanning = false { didSet { onChange?() } }
    public private(set) var state: CastState = .off { didSet { onChange?() } }

    /// Any of the above changed.
    public var onChange: (@MainActor () -> Void)?
    /// Receiver updates and estimated progress between reports while playing.
    public var onPlayback: (@MainActor (CastPlayback) -> Void)?
    /// Casting ended, with where the TV was.
    public var onEnded: (@MainActor (CastEndReason, Duration) -> Void)?

    private var connection: (any CastConnection)?
    private var loadTimer: (any PlaybackTimer)?
    private var started = false
    private var attempt: UUID?
    private var clockTimer: (any PlaybackTimer)?
    private let now: MonotonicClock
    private var anchorMs = 0
    private var lastStatusRequestMs = 0
    private var seeking = false
    private var pendingTracks = CastTrackSelection()
    // EDIT_TRACKS_INFO replaces every track. Compose adjacent edits until the TV replies.
    private var requestedTrackIDs: [Int]?
    private var startAt: Duration = .zero
    private var last = CastPlayback()
    private var disposed = false

    public init(
        backend: any CastBackend,
        scheduler: any PlaybackScheduler = TaskScheduler(),
        loadTimeout: Duration = .seconds(20),
        now: MonotonicClock? = nil,
        log: @escaping @MainActor (String) -> Void = { message in
            #if DEBUG
                print(message)
            #endif
        }
    ) {
        self.now = now ?? makeMonotonicClock()
        self.backend = backend
        self.scheduler = scheduler
        self.loadTimeout = loadTimeout
        self.log = log
    }

    public var isCasting: Bool {
        switch state {
        case .connecting, .active: true
        default: false
        }
    }

    /// Scans the network once. A failed scan (no Wi-Fi, local network
    /// permission refused) leaves the list empty.
    public func scan(timeout: Duration = .seconds(4)) async {
        guard !isScanning, !disposed else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            devices = try await backend.discover(timeout: timeout)
        } catch {
            log("[eyzflow-cast] discovery failed: \(error)")
        }
    }

    /// Hands playback to `target` with the receiver `appID`.
    public func cast(_ media: CastMedia, to target: CastTarget, appID: String) async {
        guard !isCasting, !disposed else { return }
        started = false
        let id = UUID()
        attempt = id
        seeking = false
        pendingTracks = media.trackSelection
        requestedTrackIDs = nil
        startAt = media.startAt
        last = CastPlayback(position: media.startAt)
        anchorMs = now()
        lastStatusRequestMs = anchorMs
        state = .connecting(target)
        let connection: any CastConnection
        do {
            connection = try await connect(target, appID: appID, attempt: id)
        } catch {
            guard attempt == id else { return }
            log("[eyzflow-cast] connect failed: \(error)")
            fail(target, "\(error)", at: media.startAt)
            return
        }
        guard attempt == id else {
            connection.disconnect()
            return
        }
        self.connection = connection
        connection.onPlayback = { [weak self] playback in
            guard let self, attempt == id else { return }
            received(playback, from: target)
        }
        connection.onError = { [weak self] reason in
            guard let self, attempt == id else { return }
            log("[eyzflow-cast] receiver refused: \(reason)")
            fail(target, reason, at: currentPosition)
        }
        connection.onClose = { [weak self] in
            guard let self, attempt == id else { return }
            end(target, .disconnected, at: currentPosition)
        }
        loadTimer = scheduler.schedule(after: loadTimeout) { [weak self] in
            guard let self, attempt == id, !started else { return }
            fail(target, "timeout", at: startAt)
        }
        clockTimer = scheduler.scheduleRepeating(every: .seconds(1)) { [weak self] in
            guard let self, attempt == id else { return }
            tick(target)
        }
        connection.load(media)
    }

    public func play() { connection?.play() }
    public func pause() { connection?.pause() }
    public func seek(to position: Duration) {
        guard let connection else { return }
        last.position = currentPosition
        seeking = true
        connection.seek(to: position)
    }

    public func selectTrack(_ kind: CastTrack.Kind, id: Int?) {
        guard case .active = state else { return }
        if let id {
            guard last.tracks.contains(where: { $0.kind == kind && $0.id == id }) else { return }
        } else if kind != .subtitles {
            return
        }
        let active = requestedTrackIDs ?? last.activeTrackIDs
        let ids = last.replacing(kind, with: id, in: active ?? [])
        if active?.sorted() != ids { requestTracks(ids) }
    }

    private func requestTracks(_ ids: [Int]) {
        requestedTrackIDs = ids
        connection?.setActiveTracks(ids)
    }

    /// Stops casting. The phone takes over at the TV's position.
    public func stop() {
        switch state {
        case .connecting(let target): end(target, .stopped, at: startAt)
        case .active(let target, _): end(target, .stopped, at: currentPosition)
        default: break
        }
    }

    /// Ends casting and forgets the TV, without reporting how it ended.
    public func dispose() {
        disposed = true
        cancel()
    }

    /// Ends remote playback without handing an invalidated session back to the phone.
    package func cancel() {
        guard attempt != nil else { return }
        releaseConnection(stopMedia: true)
        state = .off
    }

    /// Connects; when that fails for a network reason, scans again and retries
    /// once with the TV's current address: a TV that restarted listens on a
    /// new port. A receiver the TV refused (`LAUNCH_ERROR`) is not retried.
    private func connect(_ target: CastTarget, appID: String, attempt id: UUID) async throws -> any CastConnection {
        do {
            return try await backend.connect(target, appID: appID)
        } catch {
            if "\(error)".contains("LAUNCH_ERROR") || attempt != id { throw error }
            log("[eyzflow-cast] connect failed (\(error)); looking again")
            let found = try await backend.discover(timeout: .seconds(4))
            guard attempt == id else { throw error }
            devices = found
            guard let again = found.first(where: { $0.id == target.id }) else { throw error }
            return try await backend.connect(again, appID: appID)
        }
    }

    private func received(_ playback: CastPlayback, from target: CastTarget) {
        // An idle status before LOAD takes effect describes the previous media.
        if playback.state == .idle, !started, !playback.isError { return }
        var playback = playback
        if playback.hasReportedPosition {
            seeking = false
        } else {
            playback.estimatePosition(currentPosition)
        }
        anchorMs = now()
        if playback.hasReportedActiveTrackIDs { requestedTrackIDs = nil }
        last = playback
        if playback.state == .playing || playback.state == .paused {
            started = true
            loadTimer?.cancel()
        }
        if playback.isFinished, started {
            end(target, .finished, at: playback.duration ?? playback.position)
            return
        }
        if playback.isError {
            fail(target, "ERROR", at: playback.position)
            return
        }
        // The receiver goes back to its default tracks when the film starts, so
        // a switch sent while it still loads is lost: wait until it plays.
        if started { applyPhoneTracks(to: playback) }
        publish(playback, from: target)
    }

    private var currentPosition: Duration {
        guard !seeking, last.state == .playing else { return last.position }
        let estimate = last.position + .milliseconds(max(0, now() - anchorMs))
        return min(estimate, last.duration ?? estimate)
    }

    private func tick(_ target: CastTarget) {
        guard case .active = state else { return }
        if now() - lastStatusRequestMs >= 15_000 {
            lastStatusRequestMs = now()
            connection?.requestStatus()
        }
        guard last.state == .playing, !seeking else { return }
        var estimate = last
        estimate.estimatePosition(currentPosition)
        publish(estimate, from: target)
    }

    private func publish(_ playback: CastPlayback, from target: CastTarget) {
        state = .active(target, playback)
        onPlayback?(playback)
    }

    private func applyPhoneTracks(to playback: CastPlayback) {
        let active = requestedTrackIDs ?? playback.activeTrackIDs
        var ids = active ?? []
        func selectLanguage(_ language: String, for kind: CastTrack.Kind) {
            let matches = playback.tracks.filter { $0.kind == kind && CastTrackSelection.matches(language, $0.language) }
            if let first = matches.first, !matches.contains(where: { ids.contains($0.id) }) {
                ids = playback.replacing(kind, with: first.id, in: ids)
            }
        }
        if let language = pendingTracks.audioLanguage, playback.tracks.contains(where: { $0.kind == .audio }) {
            selectLanguage(language, for: .audio)
            pendingTracks.audioLanguage = nil
        }
        var explicitOff = false
        if playback.tracks.contains(where: { $0.kind == .subtitles }) {
            switch pendingTracks.subtitles {
            case .unspecified: break
            case .language(let language): selectLanguage(language, for: .subtitles)
            case .off:
                ids = playback.replacing(.subtitles, with: nil, in: ids)
                explicitOff = true
            }
            pendingTracks.subtitles = .unspecified
        }
        if ids.sorted() != (active ?? []).sorted() || (explicitOff && active == nil) { requestTracks(ids) }
    }

    private func fail(_ target: CastTarget, _ reason: String, at position: Duration) {
        end(target, .failed, at: position, failure: reason)
    }

    /// Ends casting once, whichever way it ends.
    private func end(_ target: CastTarget, _ reason: CastEndReason, at position: Duration, failure: String? = nil) {
        guard attempt != nil else { return }
        log("[eyzflow-cast] \(target.name): ended (\(reason)) at \(position)")
        releaseConnection(stopMedia: reason != .disconnected)
        state = reason == .failed ? .failed(target, reason: failure ?? "failed") : .off
        onEnded?(reason, position)
    }

    private func releaseConnection(stopMedia: Bool) {
        attempt = nil
        loadTimer?.cancel()
        clockTimer?.cancel()
        loadTimer = nil
        clockTimer = nil
        let connection = self.connection
        self.connection = nil
        connection?.onPlayback = nil
        connection?.onClose = nil
        connection?.onError = nil
        if stopMedia { connection?.stop() }
    }
}
