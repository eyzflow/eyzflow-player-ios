import Foundation

/// Sends one beat. True when it was delivered, or refused for good (400, 401,
/// 413: a resend would be refused too); false to keep its errors for the next.
public typealias BeatSender = @MainActor (Beat) async -> Bool

/// `POST /v1/player/beat`. The path avoids the word "analytics", which content
/// blockers stop on the web.
public struct HTTPBeatSender: Sendable {
    public let http: any HTTPClient
    public let endpoints: EYZFlowEndpoints

    public init(
        http: any HTTPClient = URLSessionHTTPClient(),
        endpoints: EYZFlowEndpoints = EYZFlowEndpoints()
    ) {
        self.http = http
        self.endpoints = endpoints
    }

    /// Whether the beat counts as delivered: 2xx, 400, 401 or 413.
    public func send(_ beat: Beat) async -> Bool {
        do {
            let url = try endpoints.apiURL("/v1/player/beat")
            let (_, response) = try await http.send(
                .json("POST", url, headers: ["Content-Type": "application/json"], body: beat.json)
            )
            let status = response.statusCode
            return (200..<300).contains(status) || status == 400 || status == 401 || status == 413
        } catch {
            return false
        }
    }

    /// `send` as a [`BeatSender`].
    public var sender: BeatSender {
        { beat in await self.send(beat) }
    }
}

/// Sends one impression's beats: at once on the first frame and on errors,
/// then every heartbeat interval, on `beat()` calls from the host (the app
/// going to the background) and a final one on `stop()`. Each beat carries
/// the counters so far and a growing sequence number, so the server keeps the
/// newest and ignores repeats.
@MainActor
public final class BeatTransport {
    /// Beats never come more often than this.
    public static let minimumInterval: Duration = .seconds(10)

    private let collector: BeatCollector
    private let token: @MainActor () -> String?
    private let sendBeat: BeatSender
    private let scheduler: any PlaybackScheduler
    public let streamID: String
    public let interval: Duration
    public let autoplay: Bool
    public let isLive: Bool
    public let drm: String?
    public let platform: PlayerPlatform?
    public let playerVersion: String
    public let impressionID: String
    public let startedAt: Int
    private var seq = 0
    private var timer: (any PlaybackTimer)?
    private var inFlight: [Int: Task<Void, Never>] = [:]
    private var nextTaskID = 0
    public private(set) var isStopped = false

    public init(
        collector: BeatCollector,
        token: @escaping @MainActor () -> String?,
        streamID: String,
        interval: Duration,
        send: @escaping BeatSender,
        scheduler: any PlaybackScheduler,
        autoplay: Bool = true,
        isLive: Bool = false,
        drm: String? = nil,
        platform: PlayerPlatform? = nil,
        playerVersion: String = eyzflowPlayerVersion,
        impressionID: String? = nil,
        wallClock: () -> Date = Date.init
    ) {
        self.collector = collector
        self.token = token
        self.streamID = streamID
        self.interval = interval
        self.sendBeat = send
        self.scheduler = scheduler
        self.autoplay = autoplay
        self.isLive = isLive
        self.drm = drm
        self.platform = platform
        self.playerVersion = playerVersion
        self.impressionID = impressionID ?? newUUIDv4()
        self.startedAt = Int((wallClock().timeIntervalSince1970 * 1000).rounded(.down))
        collector.onMilestone = { [weak self] in self?.beatSoon() }
    }

    public func start() {
        guard timer == nil, !isStopped else { return }
        timer = scheduler.scheduleRepeating(every: max(interval, Self.minimumInterval)) { [weak self] in
            await self?.beat()
        }
    }

    /// Sends the last beat and stops. Safe to call more than once.
    public func stop() async {
        guard !isStopped else { return }
        isStopped = true
        timer?.cancel()
        timer = nil
        collector.onMilestone = nil
        await sendBeat(isFinal: true)
    }

    /// Sends a beat now, unless stopped.
    public func beat() async {
        guard !isStopped else { return }
        await sendBeat(isFinal: false)
    }

    /// `beat()` without waiting for it.
    func beatSoon() {
        let id = nextTaskID
        nextTaskID += 1
        inFlight[id] = Task { [weak self] in
            await self?.beat()
            self?.inFlight[id] = nil
        }
    }

    /// Waits for the beats started without waiting (milestones, background).
    func flush() async {
        while !inFlight.isEmpty {
            for task in Array(inFlight.values) { await task.value }
        }
    }

    private func sendBeat(isFinal: Bool) async {
        guard let token = token() else { return }
        let errors = collector.takeErrors()
        seq += 1
        let sent = await sendBeat(
            Beat(
                token: token,
                sid: impressionID,
                seq: seq,
                startedAt: startedAt,
                isFinal: isFinal,
                streamID: streamID,
                isLive: isLive,
                autoplay: autoplay,
                drm: drm,
                playerVersion: playerVersion,
                platform: platform?.wireName,
                metrics: collector.metrics(),
                errors: errors
            )
        )
        if !sent, !errors.isEmpty { collector.returnErrors(errors) }
    }
}
