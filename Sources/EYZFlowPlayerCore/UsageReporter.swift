import Foundation

/// What a usage report counts against: the viewer, their storefront and the
/// offer played.
public struct UsageTarget: Sendable, Hashable {
    public var storefrontID: String
    /// The viewer's `Authorization` value, e.g. `Bearer <token>`.
    public var authorization: String
    /// The offer (film or episode) played.
    public var offerID: String
    /// The catalogue entry played; left out of the report when it is not a
    /// UUID.
    public var catalogueID: String?

    public init(storefrontID: String, authorization: String, offerID: String, catalogueID: String? = nil) {
        self.storefrontID = storefrontID
        self.authorization = authorization
        self.offerID = offerID
        self.catalogueID = catalogueID
    }
}

/// How a report went.
public enum UsageSendResult: Sendable, Hashable {
    /// Counted.
    case ok
    /// Not counted yet: send the seconds again with the next report.
    case retry
    /// Refused; sending the same report again would not help.
    case drop
}

/// Sends one report: the target and the `playback-events` body.
public typealias UsageSender = @MainActor (UsageTarget, JSONValue) async -> UsageSendResult

/// `POST /v1/content/storefront/:storefront_id/playback-events`.
public struct HTTPUsageSender: Sendable {
    public let http: any HTTPClient
    public let endpoints: EYZFlowEndpoints

    public init(
        http: any HTTPClient = URLSessionHTTPClient(),
        endpoints: EYZFlowEndpoints = EYZFlowEndpoints()
    ) {
        self.http = http
        self.endpoints = endpoints
    }

    public func send(_ target: UsageTarget, _ body: JSONValue) async -> UsageSendResult {
        do {
            let url = try endpoints.apiURL(
                "/v1/content/storefront/\(target.storefrontID.encodedURIComponent)/playback-events"
            )
            let (_, response) = try await http.send(
                .json(
                    "POST",
                    url,
                    headers: ["Content-Type": "application/json", "Authorization": target.authorization],
                    body: body
                )
            )
            if response.isSuccess { return .ok }
            // A bad body, a signed-out viewer or an unknown offer: the same
            // report would be refused again.
            if [400, 401, 403, 404].contains(response.statusCode) { return .drop }
            return .retry
        } catch {
            return .retry
        }
    }

    /// `send` as a [`UsageSender`].
    public var sender: UsageSender {
        { target, body in await self.send(target, body) }
    }
}

/// Reports the seconds of a film the viewer watched, for licensor royalties:
/// every 30 s while it plays, at once on a pause, at the end and when the app
/// goes to the background, and a last time on `stop()`. Each report carries
/// the seconds since the previous one (at most 120) and one session id for
/// the whole playback. Seconds a report could not deliver go with the next
/// one. The web player's `UsageReporter`.
///
/// The played time comes from a [`BeatCollector`], so pauses, seeks and
/// stalls do not count.
@MainActor
public final class UsageReporter {
    /// The longest report the backend takes.
    public static let maxReportSeconds = 120
    /// How often a playing film reports.
    public static let defaultInterval: Duration = .seconds(30)

    public let target: UsageTarget
    public let sessionID: String
    public let interval: Duration
    private let playedMs: @MainActor () -> Int
    private let sendReport: UsageSender
    private let scheduler: any PlaybackScheduler
    /// Played milliseconds already moved into `pendingMs`.
    private var takenMs = 0
    /// Milliseconds not reported yet.
    private var pendingMs = 0
    private var reportInFlight = false
    private var timer: (any PlaybackTimer)?
    private var inFlight: [Int: Task<Void, Never>] = [:]
    private var nextTaskID = 0
    public private(set) var isStopped = false

    public init(
        target: UsageTarget,
        playedMs: @escaping @MainActor () -> Int,
        send: @escaping UsageSender,
        scheduler: any PlaybackScheduler,
        interval: Duration = UsageReporter.defaultInterval,
        sessionID: String? = nil
    ) {
        self.target = target
        self.playedMs = playedMs
        self.sendReport = send
        self.scheduler = scheduler
        self.interval = interval
        self.sessionID = sessionID ?? newUUIDv4()
    }

    public func start() {
        guard timer == nil, !isStopped else { return }
        timer = scheduler.scheduleRepeating(every: interval) { [weak self] in
            await self?.report()
        }
    }

    /// Sends the last report and stops. Safe to call more than once.
    public func stop() async {
        guard !isStopped else { return }
        isStopped = true
        timer?.cancel()
        timer = nil
        await send(isFinal: true)
    }

    /// Reports now, unless stopped or a report is still on its way.
    public func report() async {
        guard !isStopped else { return }
        await send(isFinal: false)
    }

    /// `report()` without waiting for it: a pause, the end, the background.
    public func reportSoon() {
        let id = nextTaskID
        nextTaskID += 1
        inFlight[id] = Task { [weak self] in
            await self?.report()
            self?.inFlight[id] = nil
        }
    }

    /// Waits for the reports started without waiting.
    func flush() async {
        while !inFlight.isEmpty {
            for task in Array(inFlight.values) { await task.value }
        }
    }

    private func send(isFinal: Bool) async {
        let played = playedMs()
        if played > takenMs {
            pendingMs += played - takenMs
            takenMs = played
        }
        // One report at a time, so a slow one is not overtaken; the last one
        // goes out regardless.
        if reportInFlight, !isFinal { return }
        let seconds = min(pendingMs / 1000, Self.maxReportSeconds)
        guard seconds >= 1 else { return }
        pendingMs -= seconds * 1000

        var body: [String: JSONValue] = [
            "offer_id": .string(target.offerID),
            "session_id": .string(sessionID),
            "watched_seconds": .int(seconds),
            "is_trailer": .bool(false),
        ]
        if let catalogueID = target.catalogueID, UUID(uuidString: catalogueID) != nil {
            body["catalogue_id"] = .string(catalogueID)
        }
        reportInFlight = true
        let result = await sendReport(target, .object(body))
        reportInFlight = false
        if result == .retry { pendingMs += seconds * 1000 }
    }
}
