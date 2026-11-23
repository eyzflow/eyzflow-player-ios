import Foundation

/// Refusals the backend gives when a plan's stream or device limit is
/// reached, or the viewer was signed out. Same codes as the web player.
public enum PlaybackLimitCode: String, Sendable, CaseIterable, Codable {
    case streamLimit = "STREAM_LIMIT"
    case deviceLimit = "DEVICE_LIMIT"
    case deviceRevoked = "DEVICE_REVOKED"
    case sessionRevoked = "SESSION_REVOKED"
    /// Not a backend code: the heartbeat found the session ended elsewhere.
    case playbackSessionEnded = "PLAYBACK_SESSION_ENDED"

    public var wireName: String { rawValue }

    public static func fromWire(_ value: JSONValue?) -> PlaybackLimitCode? {
        value?.stringValue.flatMap(PlaybackLimitCode.init(rawValue:))
    }

    /// What the viewer is told.
    public var message: String {
        switch self {
        case .streamLimit:
            "You're watching on too many screens. Stop playback on another device to watch here."
        case .deviceLimit:
            "Your plan's device limit is reached. Remove a device in your account to watch here."
        case .deviceRevoked, .sessionRevoked:
            "You were signed out on this device. Sign in again to watch."
        case .playbackSessionEnded:
            "Playback was stopped from another device."
        }
    }
}

/// A limit refusal, as the host's `onLimitReached` gets it, and the error
/// [`PlaybackSessionClient.open(_:streamID:platform:deviceName:)`] throws.
public struct PlaybackLimitError: Error, Sendable, Hashable, CustomStringConvertible {
    public let code: PlaybackLimitCode

    /// The viewer-facing text for `code` (not the server's wording).
    public let message: String

    /// The response body: `sessions` for STREAM_LIMIT, `devices` for
    /// DEVICE_LIMIT. Empty when the refusal did not come from a response.
    public let details: [String: JSONValue]

    public init(code: PlaybackLimitCode, message: String, details: [String: JSONValue] = [:]) {
        self.code = code
        self.message = message
        self.details = details
    }

    public init(_ code: PlaybackLimitCode) {
        self.init(code: code, message: code.message)
    }

    public var description: String { "PlaybackLimitError(\(code.wireName))" }
}

/// An open playback session.
public struct PlaybackSession: Sendable, Hashable {
    /// Nil while the storefront's limits are off: nothing to heartbeat or close.
    public var id: String?
    public var heartbeatInterval: Duration
    /// Whether the viewer's plan plays ads for this title: its plan asks for
    /// ads, or the product is AVOD/FAST. Nil when the backend did not say (an
    /// older backend): the player config decides.
    public var ads: Bool?
    /// Key-values for the ad request's `cust_params`, e.g.
    /// `["plan": "basic-ads", "access": "svod"]`.
    public var adTargeting: [String: String]

    public init(
        id: String?,
        heartbeatInterval: Duration = .seconds(30),
        ads: Bool? = nil,
        adTargeting: [String: String] = [:]
    ) {
        self.id = id
        self.heartbeatInterval = heartbeatInterval
        self.ads = ads
        self.adTargeting = adTargeting
    }
}

/// Whose session it is: the storefront, the viewer and their device.
public struct PlaybackSessionTarget: Sendable, Hashable {
    public var storefrontID: String
    /// The viewer's `Authorization` value, e.g. `Bearer <token>`.
    public var authorization: String
    public var deviceID: String

    public init(storefrontID: String, authorization: String, deviceID: String) {
        self.storefrontID = storefrontID
        self.authorization = authorization
        self.deviceID = deviceID
    }
}

/// Reads a limit refusal from a response body, if it is one.
public func readLimitError(_ body: Data) -> PlaybackLimitError? {
    guard let object = JSONValue.decode(body)?.objectValue,
          let code = PlaybackLimitCode.fromWire(object["code"])
    else { return nil }
    return PlaybackLimitError(code: code, message: code.message, details: object)
}

/// Concurrent-stream and device limits:
/// `/v1/content/storefront/:storefront_id/playback-sessions`.
public struct PlaybackSessionClient: Sendable {
    public let http: any HTTPClient
    public let endpoints: EYZFlowEndpoints

    public init(
        http: any HTTPClient = URLSessionHTTPClient(),
        endpoints: EYZFlowEndpoints = EYZFlowEndpoints()
    ) {
        self.http = http
        self.endpoints = endpoints
    }

    private func url(_ storefrontID: String, _ path: String = "") throws -> URL {
        try endpoints.apiURL(
            "/v1/content/storefront/\(storefrontID.encodedURIComponent)/playback-sessions\(path)"
        )
    }

    /// Content-Type only with a JSON body: the API refuses an empty body sent as application/json (400), which failed
    /// every heartbeat and close.
    private func headers(_ target: PlaybackSessionTarget, json: Bool = false) -> [String: String] {
        var headers = [
            "Authorization": target.authorization,
            "X-Device-Id": target.deviceID,
        ]
        if json { headers["Content-Type"] = "application/json" }
        return headers
    }

    /// Starts watching: checks the plan's limits. Throws
    /// [`PlaybackLimitError`] on a limit, and any other error when the session
    /// could not be opened.
    public func open(
        _ target: PlaybackSessionTarget,
        streamID: String,
        platform: PlayerPlatform,
        deviceName: String? = nil
    ) async throws -> PlaybackSession {
        let url = try url(target.storefrontID)
        var body: [String: JSONValue] = [
            "stream_id": .string(streamID),
            "platform": .string(platform.wireName),
        ]
        if let deviceName { body["device_name"] = .string(deviceName) }
        let (data, response) = try await http.send(
            .json("POST", url, headers: headers(target, json: true), body: .object(body))
        )
        guard response.isSuccess else {
            if let limit = readLimitError(data) { throw limit }
            throw EYZFlowRequestError.http(
                message: "Could not start playback (\(response.statusCode)).",
                url: url
            )
        }
        guard let decoded = JSONValue.decode(data) else {
            throw EYZFlowRequestError.format("Playback session answer is not JSON.")
        }
        let map = decoded.objectValue ?? [:]
        let id = map["id"]?.stringValue
        let interval = map["heartbeat_interval_seconds"]?.numberValue
        let ads = map["ads"]?.boolValue
        var targeting: [String: String] = [:]
        for (key, value) in map["ad_targeting"]?.objectValue ?? [:] {
            // String values only, as the web player reads them.
            if let text = value.stringValue, !text.isEmpty, !key.isEmpty { targeting[key] = text }
        }
        return PlaybackSession(
            id: id?.isEmpty == false ? id : nil,
            heartbeatInterval: .seconds(
                interval.map { $0 > 0 ? Int($0.rounded()) : 30 } ?? 30
            ),
            ads: ads,
            adTargeting: targeting
        )
    }

    /// Keeps the session open. False when it was ended elsewhere (device
    /// removed, signed out everywhere); true on a passing failure, so the next
    /// heartbeat tries again.
    public func heartbeat(_ target: PlaybackSessionTarget, sessionID: String) async -> Bool {
        let data: Data
        let response: HTTPURLResponse
        do {
            let url = try url(target.storefrontID, "/\(sessionID.encodedURIComponent)/heartbeat")
            (data, response) = try await http.send(.json("POST", url, headers: headers(target)))
        } catch {
            return true
        }
        if response.statusCode == 401 || response.statusCode == 404 { return false }
        guard response.isSuccess else { return true }
        guard let body = JSONValue.decode(data) else { return true }
        return body["status"] != .string("ended")
    }

    /// Stops watching so the stream is free at once. Never throws.
    public func close(_ target: PlaybackSessionTarget, sessionID: String) async {
        do {
            let url = try url(target.storefrontID, "/\(sessionID.encodedURIComponent)")
            _ = try await http.send(.json("DELETE", url, headers: headers(target)))
        } catch {
            // The server drops a session that stops heartbeating.
        }
    }
}
