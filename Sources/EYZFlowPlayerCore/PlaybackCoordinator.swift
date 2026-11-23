import Foundation

/// Why the player stopped or did not start, as the error screen shows it.
public enum EYZFlowPlayerFailure: Error, Sendable, Hashable {
    /// The player key check refused the app.
    case license(PlayerLicenseError)
    /// A stream or device limit, or the session was ended elsewhere.
    case limit(PlaybackLimitError)

    /// The viewer-facing text.
    public var message: String {
        switch self {
        case .license(let error): error.message
        case .limit(let error): error.message
        }
    }
}

/// Where the player is before and around playback.
public enum EYZFlowPlayerStatus: Sendable, Hashable {
    /// Checking the key and opening the session.
    case loading
    /// Mount the player with this DRM `access-token` header (nil for a stream
    /// that plays without DRM).
    case ready(accessHeader: String?)
    /// Show the failure; the player is not (or no longer) mounted.
    case failed(EYZFlowPlayerFailure)
}

/// What one playback is asked to do.
public struct PlaybackCoordinatorConfig: Sendable, Hashable {
    public var streamID: String
    /// A feature-length source: DRM. Trailers play without it. Either opens a
    /// playback session when there is a storefront and the viewer's
    /// authorization.
    public var isProtected: Bool
    public var playerKey: String?
    public var configID: String?
    /// The viewer's `Authorization`, e.g. `Bearer <token>`.
    public var drmAuthorization: String?
    public var storefrontID: String?
    /// Extra DRM access-token parameters, e.g. `["source": "internal"]`.
    public var drmParameters: [String: JSONValue]
    public var deviceName: String?
    public var app: PlayerApp?
    /// Named in the playback session and in beats.
    public var platform: PlayerPlatform
    /// False turns beats off even when the key has analytics on.
    public var analytics: Bool
    /// The offer (film or episode) played. With `drmAuthorization` and
    /// `storefrontID`, the seconds watched are reported for licensor
    /// royalties. Nil for trailers.
    public var offerID: String?
    /// The catalogue entry played, sent with the royalty reports.
    public var catalogueID: String?

    public init(
        streamID: String,
        isProtected: Bool,
        playerKey: String? = nil,
        configID: String? = nil,
        drmAuthorization: String? = nil,
        storefrontID: String? = nil,
        drmParameters: [String: JSONValue] = [:],
        deviceName: String? = nil,
        app: PlayerApp? = nil,
        platform: PlayerPlatform = .current,
        analytics: Bool = true,
        offerID: String? = nil,
        catalogueID: String? = nil
    ) {
        self.streamID = streamID
        self.isProtected = isProtected
        self.playerKey = playerKey
        self.configID = configID
        self.drmAuthorization = drmAuthorization
        self.storefrontID = storefrontID
        self.drmParameters = drmParameters
        self.deviceName = deviceName
        self.app = app
        self.platform = platform
        self.analytics = analytics
        self.offerID = offerID
        self.catalogueID = catalogueID
    }

    /// Who and what the royalty reports count against, when there is all of
    /// it.
    public var usageTarget: UsageTarget? {
        guard let offerID, !offerID.isEmpty,
              let authorization = drmAuthorization, !authorization.isEmpty,
              let storefrontID, !storefrontID.isEmpty
        else { return nil }
        return UsageTarget(
            storefrontID: storefrontID,
            authorization: authorization,
            offerID: offerID,
            catalogueID: catalogueID
        )
    }
}

/// One playback's EYZFlow side, in the web player's order (`use-shaka.ts`):
/// player key check, then playback session, then the DRM access token; while
/// playing, the token renewal, the session heartbeat and the beats; on close,
/// the final beat and the session's end.
///
/// The host mounts the player when `status` is `.ready`, feeds its events to
/// `handle(event:)`, and calls `close()` when the player goes away.
@MainActor
public final class PlaybackCoordinator {
    public let config: PlaybackCoordinatorConfig
    private let licenseClient: PlayerLicenseClient
    private let sessionClient: PlaybackSessionClient
    private let beatSender: BeatSender
    private let usageSender: UsageSender
    private let deviceIDStore: any DeviceIDStore
    private let scheduler: any PlaybackScheduler
    private let now: MonotonicClock?
    private let log: @MainActor (String) -> Void

    /// Called on a limit refusal, before `onError`.
    public var onLimitReached: (@MainActor (PlaybackLimitError) -> Void)?
    /// Called on a licence refusal, before `onError`.
    public var onLicenseError: (@MainActor (PlayerLicenseError) -> Void)?
    /// Called with the viewer-facing text of every failure and playback error.
    public var onError: (@MainActor (String) -> Void)?
    /// Called on every status change.
    public var onStatusChange: (@MainActor (EYZFlowPlayerStatus) -> Void)?

    public private(set) var status: EYZFlowPlayerStatus = .loading
    private var license: PlayerLicenseSession?
    private(set) var transport: BeatTransport?
    private(set) var usage: UsageReporter?
    private var adapter: PlaybackEventAdapter?
    private var sessionTarget: PlaybackSessionTarget?
    private var sessionID: String?
    private var heartbeat: (any PlaybackTimer)?
    private var heartbeatInFlight = false
    private var disposed = false
    private var endings: [Task<Void, Never>] = []
    private var pending: [Int: Task<Void, Never>] = [:]
    private var nextPendingID = 0
    private var statusContinuations: [UUID: AsyncStream<EYZFlowPlayerStatus>.Continuation] = [:]

    public init(
        config: PlaybackCoordinatorConfig,
        licenseClient: PlayerLicenseClient = PlayerLicenseClient(),
        sessionClient: PlaybackSessionClient = PlaybackSessionClient(),
        beatSender: @escaping BeatSender = HTTPBeatSender().sender,
        usageSender: @escaping UsageSender = HTTPUsageSender().sender,
        deviceIDStore: any DeviceIDStore = UserDefaultsDeviceIDStore(),
        scheduler: any PlaybackScheduler = TaskScheduler(),
        now: MonotonicClock? = nil,
        log: @escaping @MainActor (String) -> Void = { message in
            #if DEBUG
                print(message)
            #endif
        }
    ) {
        self.config = config
        self.licenseClient = licenseClient
        self.sessionClient = sessionClient
        self.beatSender = beatSender
        self.usageSender = usageSender
        self.deviceIDStore = deviceIDStore
        self.scheduler = scheduler
        self.now = now
        self.log = log
    }

    /// The playback session's `ads`: false when the viewer's plan plays no
    /// ads. Nil without an answer (no session, an older backend, a failed
    /// request): the player config decides. Set before `status` is `.ready`.
    public private(set) var planAds: Bool?
    /// The playback session's `ad_targeting`, for the ad tag's `cust_params`.
    public private(set) var adTargeting: [String: String] = [:]

    /// The player token, while the key check has granted one.
    public var playerToken: String? { license?.token }

    /// The status now and every change after, until `close()`.
    public func statusUpdates() -> AsyncStream<EYZFlowPlayerStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: EYZFlowPlayerStatus.self)
        continuation.yield(status)
        if disposed {
            continuation.finish()
            return stream
        }
        let id = UUID()
        statusContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.statusContinuations[id] = nil }
        }
        return stream
    }

    /// Checks the key, opens the session and builds the access header; ends
    /// with `status` `.ready` or `.failed` (unless closed meanwhile).
    public func start() async {
        let deviceID = await readDeviceID()
        if disposed { return }

        if let key = config.playerKey, !key.isEmpty {
            let client = licenseClient
            do {
                license = try await PlayerLicenseSession.start(
                    PlayerLicenseRequest(
                        key: key,
                        streamID: config.streamID,
                        configID: config.configID,
                        app: config.app
                    ),
                    acquire: { request in try await client.acquire(request) },
                    scheduler: scheduler,
                    onRefused: { [weak self] error in self?.licenseRefusedWhilePlaying(error) }
                )
            } catch let refusal as PlayerLicenseError {
                fail(.license(refusal))
                await endAll()
                return
            } catch {
                // The check could not be made: play on without a token, as the
                // web player does. The DRM gate decides.
                log("[eyzflow-player] licence check failed: \(error)")
            }
            if disposed {
                await endAll()
                return
            }
            if let current = license?.current, config.analytics, current.analyticsEnabled {
                startAnalytics(interval: current.heartbeatInterval)
            }
        }
        if let target = config.usageTarget { startUsage(target) }

        // A storefront viewer (signed in, with a storefront): the playback
        // session counts this stream against the plan's limits and says
        // whether the plan plays ads. Opened for clear streams too, for the
        // ads answer; only protected streams get the DRM access header.
        var accessHeader: String?
        if let authorization = config.drmAuthorization, !authorization.isEmpty {
            let storefrontID = config.storefrontID.flatMap { $0.isEmpty ? nil : $0 }
            var parameters = config.drmParameters
            if let storefrontID { parameters["storefront_id"] = .string(storefrontID) }
            parameters["device_id"] = .string(deviceID)
            if let storefrontID {
                let target = PlaybackSessionTarget(
                    storefrontID: storefrontID,
                    authorization: authorization,
                    deviceID: deviceID
                )
                do {
                    let session = try await sessionClient.open(
                        target,
                        streamID: config.streamID,
                        platform: config.platform,
                        deviceName: config.deviceName
                    )
                    sessionTarget = target
                    sessionID = session.id
                    if disposed {
                        await endAll()
                        return
                    }
                    planAds = session.ads
                    adTargeting = session.adTargeting
                    if let id = session.id {
                        parameters["playback_session_id"] = .string(id)
                        startHeartbeat(target: target, sessionID: id, interval: session.heartbeatInterval)
                    }
                } catch let limit as PlaybackLimitError {
                    fail(.limit(limit))
                    await endAll()
                    return
                } catch {
                    // Not a limit: carry on, the licence request enforces
                    // limits; ads follow the player config.
                    log("[eyzflow-player] playback session failed: \(error)")
                }
            }
            if config.isProtected {
                // Fixed for this load: the player takes the header once.
                parameters["player_token"] = license.map { .string($0.token) }
                accessHeader = buildAccessToken(authorization, parameters: parameters)
            }
        }

        if disposed {
            await endAll()
            return
        }
        setStatus(.ready(accessHeader: accessHeader))
    }

    /// Every event the player reports.
    public func handle(event: PlaybackEvent) {
        adapter?.add(event)
        switch event {
        case .paused, .completed: usage?.reportSoon()
        default: break
        }
        if case .error(_, let message, _, _) = event {
            if let failure = Self.failure(in: message) {
                fail(failure)
                return
            }
            onError?(message)
        }
    }

    /// The app went to the background: send what there is, it may not return.
    public func onBackgrounded() {
        transport?.beatSoon()
        usage?.reportSoon()
    }

    /// Ends everything; returns once the final beat and the session's close
    /// were sent.
    public func close() async {
        disposed = true
        for continuation in statusContinuations.values { continuation.finish() }
        statusContinuations = [:]
        await endAll()
    }

    /// Waits for work started without waiting: failures' clean-up, milestone
    /// and background beats.
    func flush() async {
        while !pending.isEmpty {
            for task in Array(pending.values) { await task.value }
        }
        await transport?.flush()
        await usage?.flush()
    }

    /// The collector both the beats and the royalty reports read, made once.
    private func eventCollector() -> BeatCollector {
        if let adapter { return adapter.collector }
        let adapter = PlaybackEventAdapter(BeatCollector(now: now))
        self.adapter = adapter
        return adapter.collector
    }

    private func startAnalytics(interval: Duration) {
        let collector = eventCollector()
        let transport = BeatTransport(
            collector: collector,
            token: { [weak self] in self?.license?.token },
            streamID: config.streamID,
            interval: interval,
            send: beatSender,
            scheduler: scheduler,
            drm: config.isProtected && config.drmAuthorization != nil ? config.platform.drmName : "none",
            platform: config.platform
        )
        transport.start()
        self.transport = transport
    }

    /// The seconds watched, for licensor royalties: the same played time as
    /// the beats, whether they are on or not.
    private func startUsage(_ target: UsageTarget) {
        let collector = eventCollector()
        let usage = UsageReporter(
            target: target,
            playedMs: { collector.metrics().playedMs },
            send: usageSender,
            scheduler: scheduler
        )
        usage.start()
        self.usage = usage
    }

    private func startHeartbeat(target: PlaybackSessionTarget, sessionID: String, interval: Duration) {
        heartbeat = scheduler.scheduleRepeating(every: interval) { [weak self] in
            await self?.beatSession(target: target, sessionID: sessionID)
        }
    }

    private func beatSession(target: PlaybackSessionTarget, sessionID: String) async {
        if heartbeatInFlight || disposed { return }
        heartbeatInFlight = true
        defer { heartbeatInFlight = false }
        let alive = await sessionClient.heartbeat(target, sessionID: sessionID)
        if !alive, !disposed {
            fail(.limit(PlaybackLimitError(.playbackSessionEnded)))
            await endAll()
        }
    }

    private func licenseRefusedWhilePlaying(_ error: PlayerLicenseError) {
        // Only an enforcing organisation stops a playback already under way.
        guard license?.current.mode == .enforce else { return }
        fail(.license(error))
    }

    /// A DRM licence refused by the limit or site check names its code in the
    /// error text, when the platform passes the server's body on.
    static func failure(in message: String) -> EYZFlowPlayerFailure? {
        for code in PlayerLicenseCode.allCases where message.contains(code.wireName) {
            return .license(PlayerLicenseError(code))
        }
        for code in PlaybackLimitCode.allCases where message.contains(code.wireName) {
            return .limit(PlaybackLimitError(code))
        }
        return nil
    }

    /// Shows the failure, tells the host, and ends everything (without
    /// waiting; `endAll()` waits).
    private func fail(_ failure: EYZFlowPlayerFailure) {
        if case .failed = status { return }
        if disposed { return }
        setStatus(.failed(failure))
        switch failure {
        case .license(let error): onLicenseError?(error)
        case .limit(let error): onLimitReached?(error)
        }
        onError?(failure.message)
        track { [weak self] in await self?.endAll() }
    }

    /// Stops renewal, heartbeat and beats (with a final beat) and closes the
    /// session. Each part once; a later call also stops what was set up after
    /// an earlier one, and every call returns once all of it was sent.
    private func endAll() async {
        heartbeat?.cancel()
        heartbeat = nil
        license?.stop()
        let transport = self.transport
        let usage = self.usage
        let target = sessionTarget
        let sessionID = self.sessionID
        self.sessionID = nil
        let sessionClient = self.sessionClient
        endings.append(
            Task { @MainActor in
                async let beat: Void = { await transport?.stop() }()
                async let report: Void = { await usage?.stop() }()
                if let target, let sessionID {
                    await sessionClient.close(target, sessionID: sessionID)
                }
                await beat
                await report
            }
        )
        for ending in endings { await ending.value }
    }

    private func track(_ work: @escaping @MainActor () async -> Void) {
        let id = nextPendingID
        nextPendingID += 1
        pending[id] = Task { [weak self] in
            await work()
            self?.pending[id] = nil
        }
    }

    private func readDeviceID() async -> String {
        do {
            return try await deviceIDStore.read()
        } catch {
            log("[eyzflow-player] device id unavailable: \(error)")
            return await MemoryDeviceIDStore().read()
        }
    }

    private func setStatus(_ next: EYZFlowPlayerStatus) {
        if disposed { return }
        status = next
        onStatusChange?(next)
        for continuation in statusContinuations.values { continuation.yield(next) }
    }
}
