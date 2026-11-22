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
    /// Stops the media and closes the connection.
    func stop()
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
    /// Every status the TV reports while casting.
    public var onPlayback: (@MainActor (CastPlayback) -> Void)?
    /// Casting ended, with where the TV was.
    public var onEnded: (@MainActor (CastEndReason, Duration) -> Void)?

    private var connection: (any CastConnection)?
    private var loadTimer: (any PlaybackTimer)?
    private var started = false
    private var ending = false
    private var startAt: Duration = .zero
    private var last = CastPlayback()
    private var disposed = false

    public init(
        backend: any CastBackend,
        scheduler: any PlaybackScheduler = TaskScheduler(),
        loadTimeout: Duration = .seconds(20),
        log: @escaping @MainActor (String) -> Void = { message in
            #if DEBUG
                print(message)
            #endif
        }
    ) {
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
        ending = false
        startAt = media.startAt
        last = CastPlayback(position: media.startAt)
        state = .connecting(target)
        let connection: any CastConnection
        do {
            connection = try await connect(target, appID: appID)
        } catch {
            log("[eyzflow-cast] connect failed: \(error)")
            ending = true
            state = .failed(target, reason: "\(error)")
            onEnded?(.failed, media.startAt)
            return
        }
        guard !disposed, !ending else {
            connection.stop()
            return
        }
        self.connection = connection
        connection.onPlayback = { [weak self] playback in self?.received(playback, from: target) }
        connection.onError = { [weak self] reason in
            guard let self else { return }
            log("[eyzflow-cast] receiver refused: \(reason)")
            fail(target, reason, at: positionOf(last))
        }
        connection.onClose = { [weak self] in
            guard let self else { return }
            end(target, .disconnected, at: positionOf(last))
        }
        loadTimer = scheduler.schedule(after: loadTimeout) { [weak self] in
            guard let self, !started else { return }
            fail(target, "timeout", at: startAt)
        }
        connection.load(media)
    }

    public func play() { connection?.play() }
    public func pause() { connection?.pause() }
    public func seek(to position: Duration) { connection?.seek(to: position) }

    /// Stops casting. The phone takes over at the TV's position.
    public func stop() {
        switch state {
        case .connecting(let target): end(target, .stopped, at: startAt)
        case .active(let target, let playback): end(target, .stopped, at: positionOf(playback))
        default: break
        }
    }

    /// Ends casting and forgets the TV, without reporting how it ended.
    public func dispose() {
        disposed = true
        loadTimer?.cancel()
        connection?.stop()
        connection = nil
    }

    /// Connects; when that fails for a network reason, scans again and retries
    /// once with the TV's current address: a TV that restarted listens on a
    /// new port. A receiver the TV refused (`LAUNCH_ERROR`) is not retried.
    private func connect(_ target: CastTarget, appID: String) async throws -> any CastConnection {
        do {
            return try await backend.connect(target, appID: appID)
        } catch {
            if "\(error)".contains("LAUNCH_ERROR") || disposed { throw error }
            log("[eyzflow-cast] connect failed (\(error)); looking again")
            let found = try await backend.discover(timeout: .seconds(4))
            devices = found
            guard let again = found.first(where: { $0.id == target.id }), !disposed else { throw error }
            return try await backend.connect(again, appID: appID)
        }
    }

    private func received(_ playback: CastPlayback, from target: CastTarget) {
        guard !ending else { return }
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
            fail(target, "ERROR", at: positionOf(playback))
            return
        }
        // Before the media started, the receiver reports idle with no reason.
        if playback.state == .idle, !started { return }
        state = .active(target, playback)
        onPlayback?(playback)
    }

    /// Before the receiver reported a position, the TV is where it started.
    private func positionOf(_ playback: CastPlayback) -> Duration {
        playback.position > .zero ? playback.position : startAt
    }

    private func fail(_ target: CastTarget, _ reason: String, at position: Duration) {
        end(target, .failed, at: position, failure: reason)
    }

    /// Ends casting once, whichever way it ends.
    private func end(_ target: CastTarget, _ reason: CastEndReason, at position: Duration, failure: String? = nil) {
        guard !ending else { return }
        ending = true
        log("[eyzflow-cast] \(target.name): ended (\(reason)\(failure.map { ": \($0)" } ?? "")) at \(position)")
        loadTimer?.cancel()
        loadTimer = nil
        let connection = self.connection
        self.connection = nil
        state = reason == .failed ? .failed(target, reason: failure ?? "failed") : .off
        onEnded?(reason, position)
        // A TV that closed the connection has nothing left to stop.
        if reason != .disconnected { connection?.stop() }
    }
}
