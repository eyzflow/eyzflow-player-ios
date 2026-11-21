import Foundation
import Testing
@testable import EYZFlowPlayerCore

@Test("builds the base64 JSON the licence gate reads, without nulls")
func accessTokenWithoutNulls() {
    let header = buildAccessToken(
        "Bearer viewer",
        parameters: [
            "source": "internal",
            "storefront_id": "sf",
            "device_id": "d",
            "playback_session_id": nil,
            "player_token": "plk1.a.b",
        ]
    )

    #expect(decodeHeader(header) == [
        "headers": ["authorization": "Bearer viewer"],
        "parameters": [
            "source": "internal",
            "storefront_id": "sf",
            "device_id": "d",
            "player_token": "plk1.a.b",
        ],
    ])
}

@Test("matches the web player for ASCII payloads (btoa)")
func accessTokenMatchesWeb() {
    // btoa(JSON.stringify({headers:{authorization:"a"},parameters:{}}))
    #expect(buildAccessToken("a") == "eyJoZWFkZXJzIjp7ImF1dGhvcml6YXRpb24iOiJhIn0sInBhcmFtZXRlcnMiOnt9fQ==")
}

@Test("does not escape slashes")
func accessTokenSlashes() throws {
    let header = buildAccessToken("Bearer a/b", parameters: ["source": "x/y"])
    let text = try #require(Data(base64Encoded: header).flatMap { String(data: $0, encoding: .utf8) })
    #expect(text == #"{"headers":{"authorization":"Bearer a/b"},"parameters":{"source":"x/y"}}"#)
}

@Test("UUIDs are version 4")
func uuidV4() {
    let id = newUUIDv4()
    #expect(id.wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/) != nil)
    #expect(newUUIDv4() != id)
}

@Test("the memory store keeps one id")
func memoryStore() async {
    let store = MemoryDeviceIDStore()
    #expect(await store.read() == store.read())
    #expect(await MemoryDeviceIDStore("fixed").read() == "fixed")
}

@Test("the UserDefaults store keeps one id under eyzflow.deviceId")
func userDefaultsStore() throws {
    let suite = "eyzflow.tests.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let store = UserDefaultsDeviceIDStore(suiteName: suite)
    let id = store.read()
    #expect(UserDefaultsDeviceIDStore(suiteName: suite).read() == id)
    #expect(UserDefaults(suiteName: suite)?.string(forKey: "eyzflow.deviceId") == id)
    #expect(UserDefaultsDeviceIDStore.defaultKey == "eyzflow.deviceId")
}
