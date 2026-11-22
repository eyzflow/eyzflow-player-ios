import Foundation
import Testing
@testable import EYZFlowPlayerCore

/// The backend's answer (`toPublic`), as `sample-config.json` has it.
private let remoteJSON: JSONValue = [
    "id": "cfg_main01",
    "name": "Main player",
    "isProtected": true,
    "theme": [
        "accentColor": "#ff0000",
        "backgroundColor": "#101010",
        "controlsBarColor": "rgba(0,0,0,0.5)",
        "textColor": "#eeeeee",
        "borderRadius": "4px",
    ],
    "features": [
        "controls": true,
        "autoPlay": false,
        "muted": false,
        "loop": true,
        "chromecast": false,
        "airplay": false,
        "qualitySelector": true,
        "captions": false,
        "pip": false,
        "ads": false,
        "adCountdown": true,
        "autoHideControls": false,
    ],
    "cast": [
        "receiverAppId": "ABCD1234",
        "androidReceiverCompatible": false,
        "autoJoinPolicy": "origin_scoped",
    ],
    "ads": ["adTagUrl": ""],
]

private let remoteObject = remoteJSON.objectValue!

@Suite("PlayerConfig(json:)")
struct PlayerConfigJSONTests {
    @Test("reads the backend shape")
    func backendShape() throws {
        let config = PlayerConfig(json: remoteObject)
        #expect(config.id == "cfg_main01")
        #expect(config.theme.accentColor == "#ff0000")
        #expect(config.theme.borderRadius == "4px")
        #expect(config.features.loop)
        #expect(!config.features.chromecast)
        #expect(config.castReceiverAppID == "ABCD1234")
        #expect(config.cast?.autoJoinPolicy == "origin_scoped")
        #expect(config.ads?.adTagURL == "")
        // The backend sends no drm section.
        #expect(config.drm == nil)
        #expect(config.json == remoteJSON)
    }

    @Test("missing or mistyped fields keep the defaults")
    func mistyped() {
        let config = PlayerConfig(json: [
            "id": "cfg_x",
            "theme": ["accentColor": 42],
            "features": ["loop": "yes", "captions": false],
            "cast": "nope",
        ])
        #expect(config.name == "Default")
        #expect(config.theme == PlayerTheme())
        #expect(config.features == PlayerFeatures(captions: false))
        #expect(config.cast == nil)
        #expect(config.castReceiverAppID == nil)
    }

    @Test("adCountdown: missing (older configs) is on, false is off")
    func adCountdown() {
        // Saved before adCountdown existed.
        var missing = remoteObject
        missing["features"] = ["ads": true, "loop": true]
        #expect(PlayerConfig(json: missing).features.adCountdown)
        #expect(PlayerConfig(json: [:]).features.adCountdown)
        var off = remoteObject
        off["features"] = ["ads": true, "adCountdown": false]
        #expect(!PlayerConfig(json: off).features.adCountdown)
        var on = remoteObject
        on["features"] = ["adCountdown": true]
        #expect(PlayerConfig(json: on).features.adCountdown)
        var mistyped = remoteObject
        mistyped["features"] = ["adCountdown": "no"]
        #expect(PlayerConfig(json: mistyped).features.adCountdown)
        #expect(PlayerConfig.defaults.features.adCountdown)
        #expect(PlayerConfig.defaults.features.json.objectValue?["adCountdown"] == .bool(true))
    }

    @Test("an inline adCountdown wins over the remote config's")
    func adCountdownOverride() {
        var json = remoteObject
        json["features"] = ["adCountdown": true]
        let remote = PlayerConfig(json: json)
        #expect(!mergePlayerConfig(remote, PlayerConfigOverride(features: PlayerFeaturesOverride(adCountdown: false))).features.adCountdown)
        #expect(mergePlayerConfig(remote, PlayerConfigOverride(features: PlayerFeaturesOverride(loop: true))).features.adCountdown)
    }

    @Test("an empty receiver id is no receiver")
    func emptyReceiver() {
        #expect(PlayerConfig(json: ["cast": ["receiverAppId": ""]]).castReceiverAppID == nil)
    }

    @Test("drm parameters carry the storefront")
    func drmParameters() {
        let config = PlayerConfig(json: ["drm": ["parameters": ["storefront_id": "sf-9", "source": "internal"]]])
        #expect(config.drm?.storefrontID == "sf-9")
        #expect(config.drm?.parameters["source"] == "internal")
    }

    @Test("the defaults are the web player's DEFAULT_CONFIG")
    func defaults() {
        let d = PlayerConfig.defaults
        #expect(d.id == "default" && d.name == "Default" && d.isProtected)
        #expect(d.theme.accentColor == "#615fff")
        #expect(d.theme.backgroundColor == "#0a0a0a")
        #expect(d.theme.controlsBarColor == "rgba(10,10,10,0.88)")
        #expect(d.theme.textColor == "#fafafa")
        #expect(d.theme.borderRadius == "10px")
        #expect(d.features == PlayerFeatures(
            controls: true, autoPlay: false, muted: false, loop: false, chromecast: true, airplay: true,
            qualitySelector: true, captions: true, pip: true, ads: false, autoHideControls: true
        ))
    }
}

@Suite("mergePlayerConfig (the web player mergeConfig)")
struct MergePlayerConfigTests {
    let remote: PlayerConfig = {
        var json = remoteObject
        json["drm"] = ["parameters": ["storefront_id": "sf-remote", "source": "web"]]
        return PlayerConfig(json: json)
    }()

    @Test("no inline config is the remote config")
    func noOverride() {
        #expect(mergePlayerConfig(remote, nil) == remote)
    }

    @Test("theme and features merge field by field")
    func fieldByField() {
        let merged = mergePlayerConfig(remote, PlayerConfigOverride(
            theme: PlayerThemeOverride(textColor: "#000000"),
            features: PlayerFeaturesOverride(chromecast: true)
        ))
        #expect(merged.theme.textColor == "#000000")
        #expect(merged.theme.accentColor == "#ff0000")
        #expect(merged.features.chromecast)
        #expect(merged.features.loop)
    }

    @Test("cast and ads are replaced as a whole")
    func replaced() {
        let merged = mergePlayerConfig(remote, PlayerConfigOverride(cast: PlayerCastConfig(receiverAppID: "X")))
        #expect(merged.castReceiverAppID == "X")
        #expect(merged.cast?.autoJoinPolicy == nil)
        #expect(merged.ads == remote.ads)
    }

    @Test("drm parameters merge, inline winning")
    func drmMerge() {
        let merged = remote.merged(with: PlayerConfigOverride(drm: PlayerDRMConfig(parameters: ["storefront_id": "sf-inline"])))
        #expect(merged.drm?.parameters == ["storefront_id": "sf-inline", "source": "web"])
    }

    @Test("id, name and isProtected are overridable")
    func scalars() {
        let merged = mergePlayerConfig(remote, PlayerConfigOverride(name: "Inline", isProtected: false))
        #expect(merged.id == "cfg_main01")
        #expect(merged.name == "Inline")
        #expect(!merged.isProtected)
    }
}

/// Serialized: the config cache is shared by every client.
@Suite("PlayerConfigClient", .serialized)
struct PlayerConfigClientTests {
    init() {
        PlayerConfigClient.clearCache()
    }

    @Test("loads the public config once and keeps it")
    func loadsOnce() async throws {
        let http = FakeHTTPClient { _ in .json(remoteJSON) }
        let configs = PlayerConfigClient(http: http, endpoints: EYZFlowEndpoints(api: "https://api.dev.test/"))

        let first = try #require(await configs.load("cfg_main01"))
        let second = await configs.load("cfg_main01")

        #expect(first.id == "cfg_main01")
        #expect(second == first)
        #expect(http.requests.count == 1)
        let sent = try #require(http.requests.first)
        #expect(sent.url.absoluteString == "https://api.dev.test/v1/player-configs/cfg_main01")
        #expect(sent.method == "GET")
        #expect(sent.headers["Accept"] == "application/json")
        // Public: no Authorization.
        #expect(sent.headers.keys.contains { $0.lowercased() == "authorization" } == false)
    }

    @Test("caches per config id, shared across clients")
    func perID() async throws {
        let http = FakeHTTPClient { request in .json(["id": .string(request.url.lastPathComponent)]) }
        #expect(await PlayerConfigClient(http: http).load("cfg_a")?.id == "cfg_a")
        #expect(await PlayerConfigClient(http: http).load("cfg_b")?.id == "cfg_b")
        _ = await PlayerConfigClient(http: http).load("cfg_a")
        #expect(http.requests.count == 2)
    }

    @Test("encodes the config id into the path")
    func encodes() async {
        let http = FakeHTTPClient { _ in FakeResponse(200, "{}") }
        _ = await PlayerConfigClient(http: http).load("a/b c")
        #expect(http.requests.first?.path == "/v1/player-configs/a%2Fb%20c")
    }

    @Test("a 404 falls back to the defaults and is not kept")
    func notFound() async {
        let http = FakeHTTPClient { _ in .json(["statusCode": 404, "message": "not found"], 404) }
        let configs = PlayerConfigClient(http: http)
        #expect(await configs.load("cfg_gone") == nil)
        await #expect(throws: PlayerConfigError(configID: "cfg_gone", reason: "HTTP 404")) {
            try await configs.fetch("cfg_gone")
        }
        #expect(http.requests.count == 2)
    }

    @Test("a body that is not a JSON object falls back")
    func notObject() async {
        #expect(await PlayerConfigClient(http: FakeHTTPClient { _ in FakeResponse(200, "<html>") }).load("cfg_html") == nil)
        #expect(await PlayerConfigClient(http: FakeHTTPClient { _ in FakeResponse(200, "[]") }).load("cfg_list") == nil)
    }

    @Test("no network falls back")
    func offline() async {
        #expect(await PlayerConfigClient(http: FakeHTTPClient { _ in throw Offline() }).load("cfg_offline") == nil)
    }

    @Test("a slow API falls back after the timeout")
    func slow() async {
        let configs = PlayerConfigClient(
            http: FakeHTTPClient { _ in
                try await Task.sleep(for: .seconds(3600))
                return FakeResponse(200, "{}")
            },
            timeout: .milliseconds(10)
        )
        #expect(await configs.load("cfg_slow") == nil)
    }
}
