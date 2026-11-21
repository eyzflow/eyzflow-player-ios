import Foundation
import Testing
@testable import EYZFlowPlayerCore

/// A fake api.eyzflow.com: answers by path and records every request.
final class FakeBackend: @unchecked Sendable {
    let license = Box<@Sendable (SentRequest) -> FakeResponse>({ _ in
        .json(["token": "plk1.a.b", "mode": "enforce", "analytics": ["enabled": true, "heartbeat_interval_seconds": 60]])
    })
    let open = Box<@Sendable (SentRequest) -> FakeResponse>({ _ in
        .json(["id": "ps_1", "heartbeat_interval_seconds": 30], 201)
    })
    let heartbeat = Box<@Sendable (SentRequest) -> FakeResponse>({ _ in .json(["status": "active"]) })

    lazy var http = FakeHTTPClient { [unowned self] request in
        let path = request.path
        if path == "/v1/player/license" { return self.license.value(request) }
        if path.hasSuffix("/heartbeat") { return self.heartbeat.value(request) }
        if request.method == "DELETE" { return FakeResponse(204) }
        if path.hasSuffix("/playback-sessions") { return self.open.value(request) }
        return FakeResponse(404, "not found")
    }

    var calls: [String] { http.calls }
}

private let defaultConfig = PlaybackCoordinatorConfig(
    streamID: "stream-1",
    isProtected: true,
    playerKey: "pk_x",
    drmAuthorization: "Bearer viewer",
    storefrontID: "sf",
    drmParameters: ["source": "internal"],
    app: PlayerApp(platform: .ios, id: "com.example.app"),
    platform: .ios
)

@MainActor
final class Harness {
    let backend: FakeBackend
    let scheduler = ManualScheduler()
    var limits: [PlaybackLimitError] = []
    var refusals: [PlayerLicenseError] = []
    var errors: [String] = []
    var statuses: [EYZFlowPlayerStatus] = []
    let coordinator: PlaybackCoordinator

    init(_ backend: FakeBackend = FakeBackend(), config: PlaybackCoordinatorConfig = defaultConfig) {
        self.backend = backend
        let box = BeatsBox()
        coordinator = PlaybackCoordinator(
            config: config,
            licenseClient: PlayerLicenseClient(http: backend.http),
            sessionClient: PlaybackSessionClient(http: backend.http),
            beatSender: { beat in box.beats.append(beat); return true },
            deviceIDStore: MemoryDeviceIDStore("device-1"),
            scheduler: scheduler,
            now: { 0 },
            log: { _ in }
        )
        beatsBox = box
        coordinator.onLimitReached = { [unowned self] in limits.append($0) }
        coordinator.onLicenseError = { [unowned self] in refusals.append($0) }
        coordinator.onError = { [unowned self] in errors.append($0) }
        coordinator.onStatusChange = { [unowned self] in statuses.append($0) }
    }

    private let beatsBox: BeatsBox
    var sentBeats: [Beat] { beatsBox.beats }

    var accessHeader: JSONValue? {
        if case .ready(let header?) = coordinator.status { return decodeHeader(header) }
        return nil
    }

    var isReady: Bool { if case .ready = coordinator.status { true } else { false } }
    var isFailed: Bool { if case .failed = coordinator.status { true } else { false } }

    func advance(_ duration: Duration) async {
        await scheduler.advance(by: duration)
        await coordinator.flush()
    }
}

@MainActor
final class BeatsBox {
    var beats: [Beat] = []
}

@Suite("PlaybackCoordinator")
@MainActor
struct PlaybackCoordinatorTests {
    @Test("checks the key, opens a session and builds the access token")
    func happyPath() async throws {
        let h = Harness()
        await h.coordinator.start()

        #expect(h.backend.calls == [
            "POST /v1/player/license",
            "POST /v1/content/storefront/sf/playback-sessions",
        ])
        #expect(h.backend.http.requests[0].json?["app"] == ["platform": "ios", "id": "com.example.app"])
        #expect(h.backend.http.requests[1].headers["X-Device-Id"] == "device-1")
        #expect(h.backend.http.requests[1].json?["platform"] == "ios")
        #expect(h.accessHeader == [
            "headers": ["authorization": "Bearer viewer"],
            "parameters": [
                "source": "internal",
                "storefront_id": "sf",
                "device_id": "device-1",
                "playback_session_id": "ps_1",
                "player_token": "plk1.a.b",
            ],
        ])
        #expect(h.coordinator.playerToken == "plk1.a.b")
        #expect(h.statuses.count == 1)
        await h.coordinator.close()
    }

    @Test("heartbeats the session, and closes it with a final beat")
    func heartbeatAndClose() async {
        let h = Harness()
        await h.coordinator.start()
        h.coordinator.handle(event: .started(sourceId: "stream-1", position: .zero))
        await h.coordinator.flush()

        await h.advance(.seconds(61))
        await h.coordinator.close()

        #expect(h.backend.calls.filter { $0.hasSuffix("/heartbeat") }.count == 2)
        #expect(h.backend.calls.last == "DELETE /v1/content/storefront/sf/playback-sessions/ps_1")
        #expect(h.sentBeats.map(\.isFinal) == [false, false, true])
        #expect(h.sentBeats.allSatisfy { $0.platform == "ios" })
        #expect(h.sentBeats.first?.drm == "fairplay")
        #expect(h.scheduler.pendingTimers == 0)
    }

    @Test("a stream limit fails before playback and reaches the host")
    func streamLimit() async throws {
        let backend = FakeBackend()
        backend.open.value = { _ in .json(["code": "STREAM_LIMIT", "sessions": []], 403) }
        let h = Harness(backend)
        await h.coordinator.start()

        guard case .failed(.limit(let error)) = h.coordinator.status else {
            Issue.record("not a limit failure: \(h.coordinator.status)")
            return
        }
        #expect(error.code == .streamLimit)
        #expect(h.limits.map(\.code) == [.streamLimit])
        #expect(h.errors.count == 1)
        #expect(h.errors.first?.contains("too many screens") == true)
        await h.coordinator.close()
    }

    @Test("a refused key fails before any session")
    func refusedKey() async {
        let backend = FakeBackend()
        backend.license.value = { _ in .json(["code": "PLAYER_KEY_INVALID"], 403) }
        let h = Harness(backend)
        await h.coordinator.start()

        #expect(h.isFailed)
        #expect(h.refusals.map(\.code) == [.playerKeyInvalid])
        #expect(h.backend.calls == ["POST /v1/player/license"])
        await h.coordinator.close()
    }

    @Test("an unreachable key check plays on without token or beats")
    func unreachableKeyCheck() async throws {
        let backend = FakeBackend()
        backend.license.value = { _ in FakeResponse(502) }
        let h = Harness(backend)
        await h.coordinator.start()

        let parameters = try #require(h.accessHeader?["parameters"]?.objectValue)
        #expect(parameters["player_token"] == nil)
        h.coordinator.handle(event: .started(sourceId: "stream-1", position: .zero))
        await h.coordinator.close()
        #expect(h.sentBeats.isEmpty)
    }

    @Test("a session ended elsewhere stops playback")
    func sessionEnded() async {
        let backend = FakeBackend()
        backend.heartbeat.value = { _ in .json(["status": "ended"]) }
        let h = Harness(backend)
        await h.coordinator.start()
        #expect(h.isReady)

        await h.advance(.seconds(30))

        #expect(h.isFailed)
        #expect(h.limits.map(\.code) == [.playbackSessionEnded])
        #expect(h.limits.first?.message == "Playback was stopped from another device.")
        #expect(h.backend.calls.last == "DELETE /v1/content/storefront/sf/playback-sessions/ps_1")
        await h.coordinator.close()
    }

    @Test("limits off: no heartbeat and no session id in the token")
    func limitsOff() async throws {
        let backend = FakeBackend()
        backend.open.value = { _ in .json(["id": nil]) }
        let h = Harness(backend)
        await h.coordinator.start()
        await h.advance(.seconds(5 * 60))

        let parameters = try #require(h.accessHeader?["parameters"]?.objectValue)
        #expect(parameters["playback_session_id"] == nil)
        #expect(h.backend.calls.filter { $0.hasSuffix("/heartbeat") }.isEmpty)
        await h.coordinator.close()
    }

    @Test("without a key or storefront: no calls, DRM header only")
    func noKeyNoStorefront() async {
        let h = Harness(config: PlaybackCoordinatorConfig(
            streamID: "stream-1", isProtected: true, drmAuthorization: "Bearer viewer"
        ))
        await h.coordinator.start()

        #expect(h.backend.calls.isEmpty)
        #expect(h.accessHeader?["parameters"] == ["device_id": "device-1"])
        await h.coordinator.close()
    }

    @Test("a trailer plays with no DRM header and no session")
    func trailer() async {
        let h = Harness(config: PlaybackCoordinatorConfig(
            streamID: "trailer-1", isProtected: false, drmAuthorization: "Bearer viewer", storefrontID: "sf"
        ))
        await h.coordinator.start()

        #expect(h.backend.calls.isEmpty)
        #expect(h.coordinator.status == .ready(accessHeader: nil))
        await h.coordinator.close()
    }

    @Test("a DRM licence refused for the limit fails with that limit")
    func drmLimitInError() async {
        let h = Harness()
        await h.coordinator.start()

        h.coordinator.handle(event: .error(
            sourceId: "stream-1",
            message: #"License request failed: {"code":"DEVICE_LIMIT"}"#,
            position: .zero
        ))
        await h.coordinator.flush()

        #expect(h.limits.map(\.code) == [.deviceLimit])
        #expect(h.isFailed)
        #expect(h.backend.calls.last == "DELETE /v1/content/storefront/sf/playback-sessions/ps_1")
        await h.coordinator.close()
    }

    @Test("a licence code in a playback error fails with that refusal; other errors only reach onError")
    func licenceCodeInError() async {
        let h = Harness()
        await h.coordinator.start()
        h.coordinator.handle(event: .error(sourceId: "stream-1", message: "network down", position: .zero))
        #expect(h.isReady)
        #expect(h.errors == ["network down"])

        h.coordinator.handle(event: .error(sourceId: "stream-1", message: "403 APP_NOT_ALLOWED", position: .zero))
        await h.coordinator.flush()
        #expect(h.refusals.map(\.code) == [.appNotAllowed])
        #expect(h.errors == ["network down", "This video cannot be played in this app."])
        await h.coordinator.close()
    }

    @Test("a renewal refusal stops playback only when enforcing", arguments: ["enforce", "log"])
    func renewalRefusal(mode: String) async {
        let backend = FakeBackend()
        let checks = Box(0)
        backend.license.value = { _ in
            let n = checks.update { $0 += 1; return $0 }
            if n == 1 { return .json(["token": "t", "mode": .string(mode), "refresh_after": 600]) }
            return .json(["code": "PLAYER_KEY_INVALID"], 403)
        }
        let h = Harness(backend)
        await h.coordinator.start()
        await h.advance(.seconds(600))

        #expect(mode == "enforce" ? h.isFailed : h.isReady, "\(mode)")
        await h.coordinator.close()
    }

    @Test("status updates stream the current status and every change until close")
    func statusStream() async {
        let h = Harness()
        let stream = h.coordinator.statusUpdates()
        await h.coordinator.start()
        await h.coordinator.close()
        var seen: [EYZFlowPlayerStatus] = []
        for await status in stream { seen.append(status) }
        #expect(seen.count == 2)
        #expect(seen.first == .loading)
        if case .ready = seen.last {} else { Issue.record("last status \(String(describing: seen.last))") }
    }

    @Test("closing during the key check stops everything set up after it")
    func closeDuringStart() async {
        let backend = FakeBackend()
        let h = Harness(backend)
        let start = Task { await h.coordinator.start() }
        await h.coordinator.close()
        await start.value
        await h.coordinator.close()
        #expect(h.scheduler.pendingTimers == 0)
        #expect(h.coordinator.status == .loading)
    }
}
