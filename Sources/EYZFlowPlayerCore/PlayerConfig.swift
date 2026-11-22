import Foundation

// Player configs made in the EYZFlow dashboard (Player → Configs), as the web
// player reads them (`config-types.ts`, `remote-config.ts`).

/// The config's look. Values are CSS strings, as the dashboard stores them:
/// colours as `#rrggbb` or `rgba(…)`, the radius as `10px`.
public struct PlayerTheme: Sendable, Hashable {
    public var accentColor: String
    public var backgroundColor: String
    public var controlsBarColor: String
    public var textColor: String
    public var borderRadius: String

    public init(
        accentColor: String = "#615fff",
        backgroundColor: String = "#0a0a0a",
        controlsBarColor: String = "rgba(10,10,10,0.88)",
        textColor: String = "#fafafa",
        borderRadius: String = "10px"
    ) {
        self.accentColor = accentColor
        self.backgroundColor = backgroundColor
        self.controlsBarColor = controlsBarColor
        self.textColor = textColor
        self.borderRadius = borderRadius
    }

    /// Fields the JSON lacks, or gives as something other than a string, keep
    /// `base`'s.
    public init(json: [String: JSONValue], base: PlayerTheme = PlayerTheme()) {
        self = base.merged(with: PlayerThemeOverride(json: json))
    }

    public func merged(with patch: PlayerThemeOverride?) -> PlayerTheme {
        guard let patch else { return self }
        return PlayerTheme(
            accentColor: patch.accentColor ?? accentColor,
            backgroundColor: patch.backgroundColor ?? backgroundColor,
            controlsBarColor: patch.controlsBarColor ?? controlsBarColor,
            textColor: patch.textColor ?? textColor,
            borderRadius: patch.borderRadius ?? borderRadius
        )
    }

    public var json: JSONValue {
        [
            "accentColor": .string(accentColor),
            "backgroundColor": .string(backgroundColor),
            "controlsBarColor": .string(controlsBarColor),
            "textColor": .string(textColor),
            "borderRadius": .string(borderRadius),
        ]
    }
}

/// Part of a [`PlayerTheme`], for an inline [`PlayerConfigOverride`]: the
/// fields given win, the rest keep the remote (or default) value.
public struct PlayerThemeOverride: Sendable, Hashable {
    public var accentColor: String?
    public var backgroundColor: String?
    public var controlsBarColor: String?
    public var textColor: String?
    public var borderRadius: String?

    public init(
        accentColor: String? = nil,
        backgroundColor: String? = nil,
        controlsBarColor: String? = nil,
        textColor: String? = nil,
        borderRadius: String? = nil
    ) {
        self.accentColor = accentColor
        self.backgroundColor = backgroundColor
        self.controlsBarColor = controlsBarColor
        self.textColor = textColor
        self.borderRadius = borderRadius
    }

    public init(json: [String: JSONValue]) {
        self.init(
            accentColor: json["accentColor"]?.stringValue,
            backgroundColor: json["backgroundColor"]?.stringValue,
            controlsBarColor: json["controlsBarColor"]?.stringValue,
            textColor: json["textColor"]?.stringValue,
            borderRadius: json["borderRadius"]?.stringValue
        )
    }
}

/// What the player offers.
public struct PlayerFeatures: Sendable, Hashable {
    public var controls: Bool
    public var autoPlay: Bool
    public var muted: Bool
    public var loop: Bool
    public var chromecast: Bool
    public var airplay: Bool
    public var qualitySelector: Bool
    public var captions: Bool
    public var pip: Bool
    public var ads: Bool
    public var autoHideControls: Bool

    public init(
        controls: Bool = true,
        autoPlay: Bool = false,
        muted: Bool = false,
        loop: Bool = false,
        chromecast: Bool = true,
        airplay: Bool = true,
        qualitySelector: Bool = true,
        captions: Bool = true,
        pip: Bool = true,
        ads: Bool = false,
        autoHideControls: Bool = true
    ) {
        self.controls = controls
        self.autoPlay = autoPlay
        self.muted = muted
        self.loop = loop
        self.chromecast = chromecast
        self.airplay = airplay
        self.qualitySelector = qualitySelector
        self.captions = captions
        self.pip = pip
        self.ads = ads
        self.autoHideControls = autoHideControls
    }

    public init(json: [String: JSONValue], base: PlayerFeatures = PlayerFeatures()) {
        self = base.merged(with: PlayerFeaturesOverride(json: json))
    }

    public func merged(with patch: PlayerFeaturesOverride?) -> PlayerFeatures {
        guard let patch else { return self }
        return PlayerFeatures(
            controls: patch.controls ?? controls,
            autoPlay: patch.autoPlay ?? autoPlay,
            muted: patch.muted ?? muted,
            loop: patch.loop ?? loop,
            chromecast: patch.chromecast ?? chromecast,
            airplay: patch.airplay ?? airplay,
            qualitySelector: patch.qualitySelector ?? qualitySelector,
            captions: patch.captions ?? captions,
            pip: patch.pip ?? pip,
            ads: patch.ads ?? ads,
            autoHideControls: patch.autoHideControls ?? autoHideControls
        )
    }

    public var json: JSONValue {
        [
            "controls": .bool(controls),
            "autoPlay": .bool(autoPlay),
            "muted": .bool(muted),
            "loop": .bool(loop),
            "chromecast": .bool(chromecast),
            "airplay": .bool(airplay),
            "qualitySelector": .bool(qualitySelector),
            "captions": .bool(captions),
            "pip": .bool(pip),
            "ads": .bool(ads),
            "autoHideControls": .bool(autoHideControls),
        ]
    }
}

/// Part of a [`PlayerFeatures`], for an inline [`PlayerConfigOverride`].
public struct PlayerFeaturesOverride: Sendable, Hashable {
    public var controls: Bool?
    public var autoPlay: Bool?
    public var muted: Bool?
    public var loop: Bool?
    public var chromecast: Bool?
    public var airplay: Bool?
    public var qualitySelector: Bool?
    public var captions: Bool?
    public var pip: Bool?
    public var ads: Bool?
    public var autoHideControls: Bool?

    public init(
        controls: Bool? = nil,
        autoPlay: Bool? = nil,
        muted: Bool? = nil,
        loop: Bool? = nil,
        chromecast: Bool? = nil,
        airplay: Bool? = nil,
        qualitySelector: Bool? = nil,
        captions: Bool? = nil,
        pip: Bool? = nil,
        ads: Bool? = nil,
        autoHideControls: Bool? = nil
    ) {
        self.controls = controls
        self.autoPlay = autoPlay
        self.muted = muted
        self.loop = loop
        self.chromecast = chromecast
        self.airplay = airplay
        self.qualitySelector = qualitySelector
        self.captions = captions
        self.pip = pip
        self.ads = ads
        self.autoHideControls = autoHideControls
    }

    public init(json: [String: JSONValue]) {
        self.init(
            controls: json["controls"]?.boolValue,
            autoPlay: json["autoPlay"]?.boolValue,
            muted: json["muted"]?.boolValue,
            loop: json["loop"]?.boolValue,
            chromecast: json["chromecast"]?.boolValue,
            airplay: json["airplay"]?.boolValue,
            qualitySelector: json["qualitySelector"]?.boolValue,
            captions: json["captions"]?.boolValue,
            pip: json["pip"]?.boolValue,
            ads: json["ads"]?.boolValue,
            autoHideControls: json["autoHideControls"]?.boolValue
        )
    }
}

/// The config's Chromecast settings.
public struct PlayerCastConfig: Sendable, Hashable {
    /// The Cast receiver's app id; empty means none set.
    public var receiverAppID: String
    /// Web only (the Cast SDK's Android-receiver flag).
    public var androidReceiverCompatible: Bool?
    /// Web only (`tab_and_origin_scoped`, `origin_scoped`, `page_scoped`).
    public var autoJoinPolicy: String?

    public init(receiverAppID: String = "", androidReceiverCompatible: Bool? = nil, autoJoinPolicy: String? = nil) {
        self.receiverAppID = receiverAppID
        self.androidReceiverCompatible = androidReceiverCompatible
        self.autoJoinPolicy = autoJoinPolicy
    }

    public init(json: [String: JSONValue]) {
        self.init(
            receiverAppID: json["receiverAppId"]?.stringValue ?? "",
            androidReceiverCompatible: json["androidReceiverCompatible"]?.boolValue,
            autoJoinPolicy: json["autoJoinPolicy"]?.stringValue
        )
    }

    /// Nil fields left out.
    public var json: JSONValue {
        var out: [String: JSONValue] = ["receiverAppId": .string(receiverAppID)]
        if let androidReceiverCompatible { out["androidReceiverCompatible"] = .bool(androidReceiverCompatible) }
        if let autoJoinPolicy { out["autoJoinPolicy"] = .string(autoJoinPolicy) }
        return .object(out)
    }
}

/// The config's ads: a VAST or VMAP tag, played on iPhone and iPad when
/// `features.ads` is on (see `PlayerConfig.adTagToPlay`).
public struct PlayerAdsConfig: Sendable, Hashable {
    public var adTagURL: String

    public init(adTagURL: String = "") {
        self.adTagURL = adTagURL
    }

    public init(json: [String: JSONValue]) {
        self.init(adTagURL: json["adTagUrl"]?.stringValue ?? "")
    }

    public var json: JSONValue { ["adTagUrl": .string(adTagURL)] }
}

/// Extra DRM access-token parameters, e.g. `["storefront_id": "…"]`. The
/// dashboard does not store this section today; it comes from an inline
/// config, as on the web.
public struct PlayerDRMConfig: Sendable, Hashable {
    public var parameters: [String: JSONValue]

    public init(parameters: [String: JSONValue] = [:]) {
        self.parameters = parameters
    }

    public init(json: [String: JSONValue]) {
        self.init(parameters: json["parameters"]?.objectValue ?? [:])
    }

    /// `parameters.storefront_id`, when it is a non-empty string.
    public var storefrontID: String? {
        guard let id = parameters["storefront_id"]?.stringValue, !id.isEmpty else { return nil }
        return id
    }

    public var json: JSONValue { ["parameters": .object(parameters)] }
}

/// A player config: `GET /v1/player-configs/{configId}`, merged with an
/// inline [`PlayerConfigOverride`] by [`mergePlayerConfig(_:_:)`].
public struct PlayerConfig: Sendable, Hashable {
    public var id: String
    public var name: String
    /// Whether the config plays protected streams. The app players decide from
    /// the source type instead (a feature-length source plays with DRM).
    public var isProtected: Bool
    public var theme: PlayerTheme
    public var features: PlayerFeatures
    public var cast: PlayerCastConfig?
    public var ads: PlayerAdsConfig?
    public var drm: PlayerDRMConfig?

    /// The web player's `DEFAULT_CONFIG`, and the backend's defaults.
    public static let defaults = PlayerConfig()

    public init(
        id: String = "default",
        name: String = "Default",
        isProtected: Bool = true,
        theme: PlayerTheme = PlayerTheme(),
        features: PlayerFeatures = PlayerFeatures(),
        cast: PlayerCastConfig? = nil,
        ads: PlayerAdsConfig? = nil,
        drm: PlayerDRMConfig? = nil
    ) {
        self.id = id
        self.name = name
        self.isProtected = isProtected
        self.theme = theme
        self.features = features
        self.cast = cast
        self.ads = ads
        self.drm = drm
    }

    /// The backend's camelCase JSON. Missing or mistyped fields keep the
    /// defaults, so an older or newer backend never stops playback.
    public init(json: [String: JSONValue]) {
        let defaults = PlayerConfig.defaults
        self.init(
            id: json["id"]?.stringValue ?? defaults.id,
            name: json["name"]?.stringValue ?? defaults.name,
            isProtected: json["isProtected"]?.boolValue ?? defaults.isProtected,
            theme: json["theme"]?.objectValue.map { PlayerTheme(json: $0) } ?? defaults.theme,
            features: json["features"]?.objectValue.map { PlayerFeatures(json: $0) } ?? defaults.features,
            cast: json["cast"]?.objectValue.map(PlayerCastConfig.init(json:)),
            ads: json["ads"]?.objectValue.map(PlayerAdsConfig.init(json:)),
            drm: json["drm"]?.objectValue.map(PlayerDRMConfig.init(json:))
        )
    }

    /// `cast.receiverAppId`, when set.
    public var castReceiverAppID: String? {
        guard let id = cast?.receiverAppID, !id.isEmpty else { return nil }
        return id
    }

    public var json: JSONValue {
        var out: [String: JSONValue] = [
            "id": .string(id),
            "name": .string(name),
            "isProtected": .bool(isProtected),
            "theme": theme.json,
            "features": features.json,
        ]
        if let cast { out["cast"] = cast.json }
        if let ads { out["ads"] = ads.json }
        if let drm { out["drm"] = drm.json }
        return .object(out)
    }

    /// [`mergePlayerConfig(_:_:)`] with `self` as the base.
    public func merged(with patch: PlayerConfigOverride?) -> PlayerConfig {
        mergePlayerConfig(self, patch)
    }
}

/// The web player's inline `config` prop: what is given here wins over the
/// remote config.
public struct PlayerConfigOverride: Sendable, Hashable {
    public var id: String?
    public var name: String?
    public var isProtected: Bool?
    /// Merged field by field.
    public var theme: PlayerThemeOverride?
    /// Merged field by field.
    public var features: PlayerFeaturesOverride?
    /// Replaces the remote `cast` as a whole.
    public var cast: PlayerCastConfig?
    /// Replaces the remote `ads` as a whole.
    public var ads: PlayerAdsConfig?
    /// Its parameters are merged over the remote ones.
    public var drm: PlayerDRMConfig?

    public init(
        id: String? = nil,
        name: String? = nil,
        isProtected: Bool? = nil,
        theme: PlayerThemeOverride? = nil,
        features: PlayerFeaturesOverride? = nil,
        cast: PlayerCastConfig? = nil,
        ads: PlayerAdsConfig? = nil,
        drm: PlayerDRMConfig? = nil
    ) {
        self.id = id
        self.name = name
        self.isProtected = isProtected
        self.theme = theme
        self.features = features
        self.cast = cast
        self.ads = ads
        self.drm = drm
    }
}

/// The web player's `mergeConfig`: `patch` over `base`. Theme and features
/// merge field by field, `cast` and `ads` are replaced, DRM parameters merge.
public func mergePlayerConfig(_ base: PlayerConfig, _ patch: PlayerConfigOverride?) -> PlayerConfig {
    guard let patch else { return base }
    return PlayerConfig(
        id: patch.id ?? base.id,
        name: patch.name ?? base.name,
        isProtected: patch.isProtected ?? base.isProtected,
        theme: base.theme.merged(with: patch.theme),
        features: base.features.merged(with: patch.features),
        cast: patch.cast ?? base.cast,
        ads: patch.ads ?? base.ads,
        drm: patch.drm.map { drm in
            PlayerDRMConfig(
                parameters: (base.drm?.parameters ?? [:]).merging(drm.parameters) { _, inline in inline }
            )
        } ?? base.drm
    )
}

/// A player config could not be loaded.
public struct PlayerConfigError: Error, Sendable, Hashable, CustomStringConvertible {
    public let configID: String
    public let reason: String

    public init(configID: String, reason: String) {
        self.configID = configID
        self.reason = reason
    }

    public var description: String {
        "PlayerConfigError: failed to load player config \"\(configID)\": \(reason)"
    }
}

/// Loads player configs from `GET {api}/v1/player-configs/{configId}`, a
/// public endpoint (no auth; the backend sends `Cache-Control: public,
/// max-age=60` and 404 for an unknown id).
///
/// Like the web player, a loaded config is kept in memory for the life of the
/// app, per API origin and config id; a failure is not kept, so the next
/// player tries again.
public struct PlayerConfigClient: Sendable {
    public let http: any HTTPClient
    public let endpoints: EYZFlowEndpoints

    /// How long playback waits for the config before it starts with the
    /// defaults.
    public let timeout: Duration

    public init(
        http: any HTTPClient = URLSessionHTTPClient(),
        endpoints: EYZFlowEndpoints = EYZFlowEndpoints(),
        timeout: Duration = .seconds(5)
    ) {
        self.http = http
        self.endpoints = endpoints
        self.timeout = timeout
    }

    private static let cache = ConfigCache()

    /// Forgets every loaded config.
    public static func clearCache() {
        cache.clear()
    }

    /// The config, from the cache when it was loaded before. Throws
    /// [`PlayerConfigError`] when it cannot be loaded.
    public func fetch(_ configID: String) async throws(PlayerConfigError) -> PlayerConfig {
        let url: URL
        do {
            url = try endpoints.apiURL("/v1/player-configs/\(configID.encodedURIComponent)")
        } catch {
            throw PlayerConfigError(configID: configID, reason: "\(error)")
        }
        if let cached = Self.cache[url] { return cached }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await sendWithTimeout(request)
        } catch {
            throw PlayerConfigError(configID: configID, reason: "\(error)")
        }
        guard response.statusCode == 200 else {
            throw PlayerConfigError(configID: configID, reason: "HTTP \(response.statusCode)")
        }
        guard let json = JSONValue.decode(data) else {
            throw PlayerConfigError(configID: configID, reason: "not JSON")
        }
        guard let object = json.objectValue else {
            throw PlayerConfigError(configID: configID, reason: "not a JSON object")
        }
        let config = PlayerConfig(json: object)
        Self.cache[url] = config
        return config
    }

    /// `fetch(_:)`, or nil when the config cannot be loaded: playback then goes
    /// on with the defaults, as on the web.
    public func load(_ configID: String) async -> PlayerConfig? {
        try? await fetch(configID)
    }

    private func sendWithTimeout(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let http = self.http
        let timeout = self.timeout
        return try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
            group.addTask { try await http.send(request) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw EYZFlowRequestError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw EYZFlowRequestError.timeout }
            return first
        }
    }
}

private final class ConfigCache: @unchecked Sendable {
    private let lock = NSLock()
    private var configs: [URL: PlayerConfig] = [:]

    subscript(url: URL) -> PlayerConfig? {
        get { lock.withLock { configs[url] } }
        set { lock.withLock { configs[url] = newValue } }
    }

    func clear() {
        lock.withLock { configs.removeAll() }
    }
}
