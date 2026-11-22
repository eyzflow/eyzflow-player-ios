import Foundation
import Testing
@testable import EYZFlowPlayerCore

private let target = PlaybackSessionTarget(storefrontID: "sf 1", authorization: "Bearer viewer", deviceID: "device-1")

@Suite("PlaybackSessionClient.open")
struct PlaybackSessionOpenTests {
    @Test("posts the stream and platform with the viewer and device")
    func posts() async throws {
        let http = FakeHTTPClient { _ in .json(["id": "ps_1", "heartbeat_interval_seconds": 45], 201) }
        let client = PlaybackSessionClient(http: http)

        let session = try await client.open(target, streamID: "stream-1", platform: .tizen, deviceName: "Living room TV")

        #expect(session.id == "ps_1")
        #expect(session.heartbeatInterval == .seconds(45))
        let sent = try #require(http.requests.first)
        #expect(sent.method == "POST")
        #expect(sent.url.absoluteString == "https://api.eyzflow.com/v1/content/storefront/sf%201/playback-sessions")
        #expect(sent.headers["Authorization"] == "Bearer viewer")
        #expect(sent.headers["X-Device-Id"] == "device-1")
        #expect(sent.json == ["stream_id": "stream-1", "platform": "tizen", "device_name": "Living room TV"])
    }

    @Test("names the Apple platforms as the backend does")
    func applePlatforms() async throws {
        let http = FakeHTTPClient { _ in .json(["id": "ps_1"]) }
        _ = try await PlaybackSessionClient(http: http).open(target, streamID: "s", platform: .ios)
        _ = try await PlaybackSessionClient(http: http).open(target, streamID: "s", platform: .tvos)
        #expect(http.requests.map { $0.json?["platform"] } == ["ios", "tvos"])
        #expect(http.requests.first?.json?["device_name"] == nil)
    }

    @Test("a null id means the storefront has limits off")
    func nullID() async throws {
        let client = PlaybackSessionClient(http: FakeHTTPClient { _ in .json(["id": nil]) })

        let session = try await client.open(target, streamID: "s", platform: .android)

        #expect(session.id == nil)
        #expect(session.heartbeatInterval == .seconds(30))
    }

    @Test("reads the plan's ads answer and its targeting")
    func adsAnswer() async throws {
        let body: JSONValue = [
            "id": "ps_1",
            "ads": true,
            "ad_targeting": ["plan": "basic-ads", "access": "svod", "count": 3, "flag": true, "empty": "", "nested": ["a": "b"]],
        ]
        let client = PlaybackSessionClient(http: FakeHTTPClient { _ in .json(body, 201) })

        let session = try await client.open(target, streamID: "s", platform: .ios)

        #expect(session.ads == true)
        #expect(session.adTargeting == ["plan": "basic-ads", "access": "svod"])
    }

    @Test("ads false is kept; missing or not a boolean is nil")
    func adsMissing() async throws {
        func open(_ body: JSONValue) async throws -> PlaybackSession {
            try await PlaybackSessionClient(http: FakeHTTPClient { _ in .json(body) })
                .open(target, streamID: "s", platform: .ios)
        }
        let off = try await open(["id": "ps_1", "ads": false])
        #expect(off.ads == false)
        #expect(off.adTargeting.isEmpty)

        let older = try await open(["id": "ps_1"])
        #expect(older.ads == nil)
        #expect(older.adTargeting.isEmpty)

        let odd = try await open(["id": "ps_1", "ads": "yes", "ad_targeting": ["x", "y"]])
        #expect(odd.ads == nil)
        #expect(odd.adTargeting.isEmpty)

        let null = try await open(["id": nil, "ads": nil, "ad_targeting": nil])
        #expect(null.ads == nil)
    }

    @Test("throws the limit with its body")
    func limit() async throws {
        let body: JSONValue = ["code": "STREAM_LIMIT", "message": "server text", "sessions": [["device_name": "Phone"]]]
        let client = PlaybackSessionClient(http: FakeHTTPClient { _ in .json(body, 403) })

        let error = await #expect(throws: PlaybackLimitError.self) {
            try await client.open(target, streamID: "s", platform: .android)
        }
        #expect(error?.code == .streamLimit)
        #expect(error?.message == "You're watching on too many screens. Stop playback on another device to watch here.")
        #expect(error?.details["sessions"]?.arrayValue?.isEmpty == false)
    }

    @Test("throws a plain error for any other failure")
    func plainError() async throws {
        let client = PlaybackSessionClient(http: FakeHTTPClient { _ in FakeResponse(500, "oops") })
        do {
            _ = try await client.open(target, streamID: "s", platform: .android)
            Issue.record("did not throw")
        } catch {
            #expect(!(error is PlaybackLimitError))
        }
    }

    @Test("limit messages are the web player's")
    func messages() {
        #expect(PlaybackLimitCode.allCases.map(\.wireName)
            == ["STREAM_LIMIT", "DEVICE_LIMIT", "DEVICE_REVOKED", "SESSION_REVOKED", "PLAYBACK_SESSION_ENDED"])
        #expect(PlaybackLimitCode.deviceLimit.message
            == "Your plan's device limit is reached. Remove a device in your account to watch here.")
        #expect(PlaybackLimitCode.sessionRevoked.message == "You were signed out on this device. Sign in again to watch.")
        #expect(PlaybackLimitCode.playbackSessionEnded.message == "Playback was stopped from another device.")
    }
}

@Suite("PlaybackSessionClient.heartbeat")
struct PlaybackSessionHeartbeatTests {
    private func beat(_ response: FakeResponse) async -> Bool {
        let http = FakeHTTPClient { request in
            #expect(request.path == "/v1/content/storefront/sf%201/playback-sessions/ps_1/heartbeat")
            #expect(request.method == "POST")
            return response
        }
        return await PlaybackSessionClient(http: http).heartbeat(target, sessionID: "ps_1")
    }

    @Test("alive on ok")
    func alive() async {
        #expect(await beat(.json(["status": "active"])))
    }

    @Test("dead when ended, unauthorized or gone")
    func dead() async {
        #expect(await !beat(.json(["status": "ended"])))
        #expect(await !beat(FakeResponse(401)))
        #expect(await !beat(FakeResponse(404)))
    }

    @Test("alive on a passing failure")
    func passingFailure() async {
        #expect(await beat(FakeResponse(503)))
        let offline = PlaybackSessionClient(http: FakeHTTPClient { _ in throw Offline() })
        #expect(await offline.heartbeat(target, sessionID: "ps_1"))
    }
}

@Test("close deletes the session and never throws")
func closeDeletes() async {
    let http = FakeHTTPClient { _ in FakeResponse(204) }
    await PlaybackSessionClient(http: http).close(target, sessionID: "ps_1")
    await PlaybackSessionClient(http: FakeHTTPClient { _ in throw Offline() }).close(target, sessionID: "ps_1")

    #expect(http.calls == ["DELETE /v1/content/storefront/sf%201/playback-sessions/ps_1"])
}
