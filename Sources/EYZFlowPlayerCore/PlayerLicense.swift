import Foundation

/// Refusals of the player key check (`POST /v1/player/license`), and of DRM
/// licences by the site check. Same codes as the web player.
public enum PlayerLicenseCode: String, Sendable, CaseIterable, Codable {
    case playerKeyInvalid = "PLAYER_KEY_INVALID"
    case originRequired = "ORIGIN_REQUIRED"
    case playerKeyStreamMismatch = "PLAYER_KEY_STREAM_MISMATCH"
    case domainNotAllowed = "DOMAIN_NOT_ALLOWED"
    /// The app is not on the key's allowed apps. Read as a refusal
    /// whether the backend answers this or `domainNotAllowed`.
    case appNotAllowed = "APP_NOT_ALLOWED"
    case playerTokenRequired = "PLAYER_TOKEN_REQUIRED"
    case playerTokenInvalid = "PLAYER_TOKEN_INVALID"
    case playerTokenOriginMismatch = "PLAYER_TOKEN_ORIGIN_MISMATCH"

    public var wireName: String { rawValue }

    public static func fromWire(_ value: JSONValue?) -> PlayerLicenseCode? {
        value?.stringValue.flatMap(PlayerLicenseCode.init(rawValue:))
    }

    /// What the viewer is told.
    public var message: String {
        switch self {
        case .playerKeyInvalid:
            "This player is not set up correctly (invalid player key)."
        case .playerKeyStreamMismatch:
            "This video cannot be played with this player key."
        case .originRequired, .domainNotAllowed, .appNotAllowed, .playerTokenOriginMismatch:
            "This video cannot be played in this app."
        case .playerTokenRequired, .playerTokenInvalid:
            "The player's licence check expired. Close the player and start again to keep watching."
        }
    }
}

/// A refusal of the player key check, as the host's `onLicenseError` gets it,
/// and the error [`PlayerLicenseClient.acquire(_:)`] throws for it.
public struct PlayerLicenseError: Error, Sendable, Hashable, CustomStringConvertible {
    public let code: PlayerLicenseCode
    public let message: String

    public init(code: PlayerLicenseCode, message: String) {
        self.code = code
        self.message = message
    }

    public init(_ code: PlayerLicenseCode) {
        self.init(code: code, message: code.message)
    }

    /// Equal by code, as in Dart.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.code == rhs.code }
    public func hash(into hasher: inout Hasher) { hasher.combine(code) }

    public var description: String { "PlayerLicenseError(\(code.wireName))" }
}

/// How the organisation applies the site (or app) check.
public enum PlayerKeyMode: String, Sendable, Codable {
    case off, log, enforce

    public static func fromWire(_ value: JSONValue?) -> PlayerKeyMode {
        switch value?.stringValue {
        case "log": .log
        case "enforce": .enforce
        default: .off
        }
    }
}

/// A granted player key check: the short-lived player token and what the
/// player should do with it.
public struct PlayerLicense: Sendable, Hashable {
    public var token: String
    public var expiresIn: Duration
    public var refreshAfter: Duration
    public var mode: PlayerKeyMode

    /// Set when the app is not allowed but the organisation only logs: what
    /// enforce would answer. Informational.
    public var wouldRefuse: PlayerLicenseCode?

    /// Whether to send beats: the key has analytics on and the app is allowed.
    public var analyticsEnabled: Bool
    public var heartbeatInterval: Duration

    public init(
        token: String,
        expiresIn: Duration = .seconds(900),
        refreshAfter: Duration = .seconds(600),
        mode: PlayerKeyMode = .off,
        wouldRefuse: PlayerLicenseCode? = nil,
        analyticsEnabled: Bool = false,
        heartbeatInterval: Duration = .seconds(60)
    ) {
        self.token = token
        self.expiresIn = expiresIn
        self.refreshAfter = refreshAfter
        self.mode = mode
        self.wouldRefuse = wouldRefuse
        self.analyticsEnabled = analyticsEnabled
        self.heartbeatInterval = heartbeatInterval
    }

    /// The answer's JSON. Returns nil without a string `token`.
    public init?(json: [String: JSONValue]) {
        guard let token = json["token"]?.stringValue else { return nil }
        let analytics = json["analytics"]?.objectValue ?? [:]
        self.init(
            token: token,
            expiresIn: secondsOr(json["expires_in"], 900),
            refreshAfter: secondsOr(json["refresh_after"], 600),
            mode: .fromWire(json["mode"]),
            wouldRefuse: .fromWire(json["would_refuse"]),
            analyticsEnabled: analytics["enabled"] == .bool(true),
            heartbeatInterval: secondsOr(analytics["heartbeat_interval_seconds"], 60)
        )
    }
}

/// A JSON number rounded to whole seconds, else `fallback` seconds.
func secondsOr(_ value: JSONValue?, _ fallback: Int) -> Duration {
    guard let number = value?.numberValue, number.isFinite else { return .seconds(fallback) }
    return .seconds(Int(number.rounded()))
}

/// What the player key check is asked about.
public struct PlayerLicenseRequest: Sendable, Hashable {
    /// `pk_…`, from the dashboard's Player → Keys.
    public var key: String
    public var streamID: String
    public var configID: String?

    /// The app in place of a web Origin. Without it the backend answers
    /// `ORIGIN_REQUIRED` to a native client.
    public var app: PlayerApp?
    public var playerVersion: String

    public init(
        key: String,
        streamID: String,
        configID: String? = nil,
        app: PlayerApp? = nil,
        playerVersion: String = eyzflowPlayerVersion
    ) {
        self.key = key
        self.streamID = streamID
        self.configID = configID
        self.app = app
        self.playerVersion = playerVersion
    }

    public var json: JSONValue {
        var body: [String: JSONValue] = [
            "key": .string(key),
            "stream_id": .string(streamID),
            "player_version": .string(playerVersion),
        ]
        if let configID { body["config_id"] = .string(configID) }
        if let app { body["app"] = app.json }
        return .object(body)
    }
}

/// `POST /v1/player/license`.
public struct PlayerLicenseClient: Sendable {
    public let http: any HTTPClient
    public let endpoints: EYZFlowEndpoints

    public init(
        http: any HTTPClient = URLSessionHTTPClient(),
        endpoints: EYZFlowEndpoints = EYZFlowEndpoints()
    ) {
        self.http = http
        self.endpoints = endpoints
    }

    /// Throws [`PlayerLicenseError`] on a refusal, and any other error when
    /// the check could not be made (network, server error, rate limit).
    public func acquire(_ request: PlayerLicenseRequest) async throws -> PlayerLicense {
        let url = try endpoints.apiURL("/v1/player/license")
        let (data, response) = try await http.send(
            .json(
                "POST", url,
                headers: ["Content-Type": "application/json"],
                body: request.json
            )
        )
        let body = JSONValue.decode(data)
        guard response.isSuccess else {
            if let code = PlayerLicenseCode.fromWire(body?["code"]) {
                throw PlayerLicenseError(code)
            }
            throw EYZFlowRequestError.http(
                message: "Player licence check failed (\(response.statusCode)).",
                url: url
            )
        }
        guard let object = body?.objectValue, let license = PlayerLicense(json: object) else {
            throw EYZFlowRequestError.format("Player licence answer has no token.")
        }
        return license
    }
}

/// Makes one player key check.
public typealias PlayerLicenseAcquirer = @MainActor (PlayerLicenseRequest) async throws -> PlayerLicense

/// The current player token, renewed before it expires while the player is
/// open. A failed renewal keeps the old token and tries again a minute later;
/// a refusal (the key was switched off, the app removed) is reported once.
@MainActor
public final class PlayerLicenseSession {
    /// Renewals never come sooner than this.
    public static let minimumRefresh: Duration = .seconds(10)
    /// After a failed renewal.
    public static let retryAfterFailure: Duration = .seconds(60)

    private let request: PlayerLicenseRequest
    private let acquire: PlayerLicenseAcquirer
    private let onRefused: @MainActor (PlayerLicenseError) -> Void
    private let scheduler: any PlaybackScheduler
    private var timer: (any PlaybackTimer)?
    private var stopped = false

    public private(set) var current: PlayerLicense
    public var token: String { current.token }

    private init(
        request: PlayerLicenseRequest,
        current: PlayerLicense,
        acquire: @escaping PlayerLicenseAcquirer,
        scheduler: any PlaybackScheduler,
        onRefused: @escaping @MainActor (PlayerLicenseError) -> Void
    ) {
        self.request = request
        self.current = current
        self.acquire = acquire
        self.scheduler = scheduler
        self.onRefused = onRefused
        schedule(after: current.refreshAfter)
    }

    /// Makes the first check. Throws as [`PlayerLicenseClient.acquire(_:)`]
    /// does.
    public static func start(
        _ request: PlayerLicenseRequest,
        acquire: @escaping PlayerLicenseAcquirer,
        scheduler: any PlaybackScheduler,
        onRefused: @escaping @MainActor (PlayerLicenseError) -> Void
    ) async throws -> PlayerLicenseSession {
        let first = try await acquire(request)
        return PlayerLicenseSession(
            request: request,
            current: first,
            acquire: acquire,
            scheduler: scheduler,
            onRefused: onRefused
        )
    }

    public func stop() {
        stopped = true
        timer?.cancel()
        timer = nil
    }

    private func schedule(after delay: Duration) {
        guard !stopped else { return }
        // Held strongly, as a Dart Timer holds its callback: a session renews
        // until it is stopped, whether or not anyone else keeps it.
        timer = scheduler.schedule(after: max(delay, Self.minimumRefresh)) { [self] in
            await refresh()
        }
    }

    private func refresh() async {
        timer = nil
        do {
            let next = try await acquire(request)
            guard !stopped else { return }
            current = next
            schedule(after: next.refreshAfter)
        } catch let refusal as PlayerLicenseError {
            guard !stopped else { return }
            stop()
            onRefused(refusal)
        } catch {
            schedule(after: Self.retryAfterFailure)
        }
    }
}
