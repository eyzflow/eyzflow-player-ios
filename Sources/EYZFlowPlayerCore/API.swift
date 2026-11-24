import Foundation

/// This library's version, sent with licence checks and beats. Prefixed so
/// the backend can tell app players from the web player (`0.6.0`).
public let eyzflowPlayerVersion = "ios/0.6.0"

/// The EYZFlow origins the player talks to. Production by default; a host
/// points them at a dev or staging stack for testing.
public struct EYZFlowEndpoints: Sendable, Hashable {
    /// DRM licences, playback sessions, player keys and analytics.
    public var api: String

    /// Manifests, segments and the FairPlay certificate. Kept for parity with
    /// the web player.
    public var streamCDN: String

    public init(
        api: String = "https://api.eyzflow.com",
        streamCDN: String = "https://stream.eyzflow.com"
    ) {
        self.api = api
        self.streamCDN = streamCDN
    }

    /// The API origin (without a trailing `/`) followed by `path`.
    public func apiURL(_ path: String) throws -> URL {
        let origin = api.hasSuffix("/") ? String(api.dropLast()) : api
        guard let url = URL(string: origin + path) else {
            throw EYZFlowRequestError.invalidURL(origin + path)
        }
        return url
    }
}

/// Where the player runs, as playback sessions, licence checks and beats name
/// it. The raw values are the backend's (`playback-sessions.controller.ts`).
public enum PlayerPlatform: String, Sendable, CaseIterable, Codable {
    case android = "android"
    case androidTV = "androidtv"
    case ios = "ios"
    case tvos = "tvos"
    case tizen = "tizen"
    case webos = "webos"

    /// The wire value.
    public var wireName: String { rawValue }

    /// TV platforms, for the analytics device class.
    public var isTV: Bool {
        switch self {
        case .androidTV, .tvos, .tizen, .webos: true
        case .android, .ios: false
        }
    }

    /// The DRM system the platform's player uses for protected streams, as
    /// beats name it: Widevine on Android and Tizen, FairPlay on Apple.
    public var drmName: String {
        switch self {
        case .ios, .tvos: "fairplay"
        case .webos: "playready"
        default: "widevine"
        }
    }

    /// The platform this build runs on: `tvos` on Apple TV, `ios` otherwise
    /// (macOS included, where only the tests run).
    public static var current: PlayerPlatform {
        #if os(tvOS)
            .tvos
        #else
            .ios
        #endif
    }
}

/// The app the player runs in, sent with the player key check in place of a
/// web page's Origin: the platform and the app's bundle id.
public struct PlayerApp: Sendable, Hashable, CustomStringConvertible {
    public var platform: PlayerPlatform

    /// `com.example.app`.
    public var id: String

    public init(platform: PlayerPlatform, id: String) {
        self.platform = platform
        self.id = id
    }

    /// This app: [`PlayerPlatform.current`] and the main bundle's id, or nil
    /// without one.
    public static var current: PlayerApp? {
        guard let id = Bundle.main.bundleIdentifier, !id.isEmpty else { return nil }
        return PlayerApp(platform: .current, id: id)
    }

    public var json: JSONValue {
        ["platform": .string(platform.wireName), "id": .string(id)]
    }

    public var description: String { "PlayerApp(\(platform.wireName), \(id))" }
}

extension String {
    /// Percent-encodes everything but `A-Za-z0-9-_.!~*'()`, as Dart's
    /// `Uri.encodeComponent` and JavaScript's `encodeURIComponent` do.
    var encodedURIComponent: String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz")
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!~*'()")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
