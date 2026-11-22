import Foundation
import Testing
@testable import EYZFlowPlayerCore

private func ok(_ over: [String: JSONValue] = [:]) -> FakeResponse {
    var body: [String: JSONValue] = [
        "token": "plk1.a.b",
        "expires_in": 900,
        "refresh_after": 600,
        "mode": "enforce",
        "would_refuse": nil,
        "analytics": ["enabled": true, "heartbeat_interval_seconds": 60],
    ]
    body.merge(over) { _, new in new }
    return .json(.object(body))
}

private func licence(_ token: String) -> PlayerLicense {
    PlayerLicense(token: token, mode: .enforce)
}

private let app = PlayerApp(platform: .androidTV, id: "com.example.tv")

@Suite("PlayerLicenseClient.acquire")
struct PlayerLicenseClientTests {
    @Test("posts the key with the app and reads the licence")
    func postsKeyWithApp() async throws {
        let http = FakeHTTPClient { _ in ok() }
        let client = PlayerLicenseClient(http: http)

        let licence = try await client.acquire(PlayerLicenseRequest(key: "pk_x", streamID: "s1", app: app))

        #expect(licence.token == "plk1.a.b")
        #expect(licence.expiresIn == .seconds(900))
        #expect(licence.refreshAfter == .seconds(600))
        #expect(licence.mode == .enforce)
        #expect(licence.wouldRefuse == nil)
        #expect(licence.analyticsEnabled)
        #expect(licence.heartbeatInterval == .seconds(60))
        let sent = try #require(http.requests.first)
        #expect(sent.method == "POST")
        #expect(sent.url.absoluteString == "https://api.eyzflow.com/v1/player/license")
        #expect(sent.headers["Content-Type"] == "application/json")
        #expect(sent.json == [
            "key": "pk_x",
            "stream_id": "s1",
            "player_version": .string(eyzflowPlayerVersion),
            "app": ["platform": "androidtv", "id": "com.example.tv"],
        ])
        #expect(eyzflowPlayerVersion == "ios/0.3.0")
    }

    @Test("sends config_id when given")
    func sendsConfigID() async throws {
        let http = FakeHTTPClient { _ in ok() }
        _ = try await PlayerLicenseClient(http: http)
            .acquire(PlayerLicenseRequest(key: "pk", streamID: "s", configID: "cfg_1"))
        #expect(http.requests.first?.json?["config_id"] == "cfg_1")
        #expect(http.requests.first?.json?["app"] == nil)
    }

    @Test("reads defaults when the answer leaves fields out")
    func defaults() async throws {
        let client = PlayerLicenseClient(http: FakeHTTPClient { _ in .json(["token": "t"]) })

        let licence = try await client.acquire(PlayerLicenseRequest(key: "pk", streamID: "s"))

        #expect(licence.mode == .off)
        #expect(!licence.analyticsEnabled)
        #expect(licence.refreshAfter == .seconds(600))
        #expect(licence.heartbeatInterval == .seconds(60))
    }

    @Test("names would_refuse in log mode")
    func wouldRefuse() async throws {
        let client = PlayerLicenseClient(http: FakeHTTPClient { _ in
            ok(["mode": "log", "would_refuse": "DOMAIN_NOT_ALLOWED"])
        })

        let licence = try await client.acquire(PlayerLicenseRequest(key: "pk", streamID: "s"))

        #expect(licence.mode == .log)
        #expect(licence.wouldRefuse == .domainNotAllowed)
    }

    @Test("throws a PlayerLicenseError with a viewer message")
    func refusal() async throws {
        let client = PlayerLicenseClient(http: FakeHTTPClient { _ in
            .json(["code": "PLAYER_KEY_INVALID", "message": "x"], 403)
        })

        let error = await #expect(throws: PlayerLicenseError.self) {
            try await client.acquire(PlayerLicenseRequest(key: "pk", streamID: "s"))
        }
        #expect(error?.code == .playerKeyInvalid)
        #expect(error?.message == "This player is not set up correctly (invalid player key).")
    }

    @Test("a refused app reads as a licence refusal")
    func appNotAllowed() async throws {
        let client = PlayerLicenseClient(http: FakeHTTPClient { _ in .json(["code": "APP_NOT_ALLOWED"], 403) })

        let error = await #expect(throws: PlayerLicenseError.self) {
            try await client.acquire(PlayerLicenseRequest(key: "pk", streamID: "s"))
        }
        #expect(error?.code == .appNotAllowed)
        #expect(error?.message == "This video cannot be played in this app.")
    }

    @Test("throws a plain error when the check cannot be made")
    func plainError() async throws {
        for response in [FakeResponse(502, "bad gateway"), .json(["code": "RATE_LIMITED"], 429)] {
            let client = PlayerLicenseClient(http: FakeHTTPClient { _ in response })
            do {
                _ = try await client.acquire(PlayerLicenseRequest(key: "pk", streamID: "s"))
                Issue.record("did not throw")
            } catch {
                #expect(!(error is PlayerLicenseError))
            }
        }
    }

    @Test("a 2xx answer without a token is a format error")
    func noToken() async throws {
        let client = PlayerLicenseClient(http: FakeHTTPClient { _ in .json(["mode": "off"]) })
        await #expect(throws: EYZFlowRequestError.format("Player licence answer has no token.")) {
            try await client.acquire(PlayerLicenseRequest(key: "pk", streamID: "s"))
        }
    }

    @Test("every code has its wire name and the web player's message")
    func codes() {
        #expect(PlayerLicenseCode.allCases.map(\.wireName) == [
            "PLAYER_KEY_INVALID", "ORIGIN_REQUIRED", "PLAYER_KEY_STREAM_MISMATCH", "DOMAIN_NOT_ALLOWED",
            "APP_NOT_ALLOWED", "PLAYER_TOKEN_REQUIRED", "PLAYER_TOKEN_INVALID", "PLAYER_TOKEN_ORIGIN_MISMATCH",
        ])
        #expect(PlayerLicenseCode.playerTokenInvalid.message
            == "The player's licence check expired. Close the player and start again to keep watching.")
        #expect(PlayerLicenseCode.playerKeyStreamMismatch.message == "This video cannot be played with this player key.")
    }
}

@Suite("PlayerLicenseSession")
@MainActor
struct PlayerLicenseSessionTests {
    @Test("renews after refresh_after and retries a failed renewal a minute later")
    func renewsAndRetries() async throws {
        let scheduler = ManualScheduler()
        var answers: [Result<PlayerLicense, any Error>] = [.success(licence("t1")), .failure(Offline()), .success(licence("t2"))]
        let session = try await PlayerLicenseSession.start(
            PlayerLicenseRequest(key: "pk", streamID: "s"),
            acquire: { _ in try answers.removeFirst().get() },
            scheduler: scheduler,
            onRefused: { _ in Issue.record("not refused") }
        )
        #expect(session.token == "t1")

        await scheduler.advance(by: .seconds(600))
        #expect(session.token == "t1")
        await scheduler.advance(by: .seconds(60))
        #expect(session.token == "t2")
        session.stop()
        #expect(scheduler.pendingTimers == 0)
    }

    @Test("reports a refusal once and stops")
    func refusalOnce() async throws {
        let scheduler = ManualScheduler()
        var calls = 0
        var refusals: [PlayerLicenseError] = []
        _ = try await PlayerLicenseSession.start(
            PlayerLicenseRequest(key: "pk", streamID: "s"),
            acquire: { _ in
                calls += 1
                if calls == 1 { return licence("t1") }
                throw PlayerLicenseError(.playerKeyInvalid)
            },
            scheduler: scheduler,
            onRefused: { refusals.append($0) }
        )
        await scheduler.advance(by: .seconds(600 * 3))

        #expect(refusals.map(\.code) == [.playerKeyInvalid])
        #expect(calls == 2)
    }

    @Test("never renews sooner than ten seconds")
    func floor() async throws {
        let scheduler = ManualScheduler()
        var calls = 0
        let session = try await PlayerLicenseSession.start(
            PlayerLicenseRequest(key: "pk", streamID: "s"),
            acquire: { _ in
                calls += 1
                return PlayerLicense(token: "t", refreshAfter: .zero)
            },
            scheduler: scheduler,
            onRefused: { _ in }
        )
        await scheduler.advance(by: .seconds(9))
        #expect(calls == 1)
        await scheduler.advance(by: .seconds(1))
        #expect(calls == 2)
        session.stop()
    }
}
