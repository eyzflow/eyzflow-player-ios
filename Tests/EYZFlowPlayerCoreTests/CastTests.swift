import Foundation
import Testing
@testable import EYZFlowPlayerCore

private let livingRoom = CastTarget(id: "tv-1", name: "Living Room TV", model: "Chromecast", host: "192.168.1.20")

private func minutes(_ value: Int64) -> Duration { .seconds(value * 60) }

/// A TV that records what it was asked and reports what the test says.
@MainActor
final class FakeTV: CastConnection {
    var onPlayback: (@MainActor (CastPlayback) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    var onClose: (@MainActor () -> Void)?
    var calls: [String] = []
    var loaded: CastMedia?

    func report(_ playback: CastPlayback) { onPlayback?(playback) }
    func refuse(_ reason: String) { onError?(reason) }
    func disconnect() { onClose?() }

    func load(_ media: CastMedia) {
        loaded = media
        calls.append("load")
    }

    func play() { calls.append("play") }
    func pause() { calls.append("pause") }
    func seek(to position: Duration) { calls.append("seek \(position)") }
    func stop() { calls.append("stop") }
}

struct Refused: Error, CustomStringConvertible {
    let description: String
}

@MainActor
final class FakeCastBackend: CastBackend {
    var devices = [livingRoom]
    let tv = FakeTV()
    var appID: String?
    var scans = 0
    var connects = 0
    var connectError: (any Error)?
    /// Fails only the first connection, like a TV that restarted on a new port.
    var firstConnectError: (any Error)?
    var scanError: (any Error)?

    func discover(timeout: Duration) async throws -> [CastTarget] {
        scans += 1
        if let scanError { throw scanError }
        return devices
    }

    func connect(_ target: CastTarget, appID: String) async throws -> any CastConnection {
        self.appID = appID
        connects += 1
        if let firstConnectError, connects == 1 { throw firstConnectError }
        if let connectError { throw connectError }
        return tv
    }
}

private let media = CastMedia(
    streamID: "s",
    contentURL: "https://stream.eyzflow.com/s/manifest.mpd",
    contentType: "application/dash+xml",
    title: "Film",
    startAt: minutes(10)
)

@MainActor
@Suite("CastController")
struct CastControllerTests {
    let backend = FakeCastBackend()
    let scheduler = ManualScheduler()
    let ended = Ref<[(CastEndReason, Duration)]>([])
    let playbacks = Ref<[CastPlayback]>([])
    let cast: CastController

    init() {
        cast = CastController(backend: backend, scheduler: scheduler, log: { _ in })
        cast.onPlayback = { [playbacks] in playbacks.value.append($0) }
        cast.onEnded = { [ended] in ended.value.append(($0, $1)) }
    }

    private var endings: [CastEndReason] { ended.value.map(\.0) }

    @Test("scans for TVs; a failed scan leaves no devices")
    func scan() async {
        #expect(cast.devices.isEmpty)
        await cast.scan()
        #expect(cast.devices == [livingRoom])
        #expect(!cast.isScanning)

        let failing = FakeCastBackend()
        failing.scanError = Refused(description: "no network")
        let other = CastController(backend: failing, scheduler: scheduler, log: { _ in })
        await other.scan()
        #expect(other.devices.isEmpty)
    }

    @Test("connects to the receiver, loads and reports the TV")
    func casts() async {
        await cast.cast(media, to: livingRoom, appID: "ABCD1234")
        #expect(backend.appID == "ABCD1234")
        #expect(backend.tv.loaded == media)
        #expect(cast.state == .connecting(livingRoom))

        backend.tv.report(CastPlayback(state: .playing, position: minutes(10)))
        #expect(cast.state == .active(livingRoom, CastPlayback(state: .playing, position: minutes(10))))
        #expect(playbacks.value.map(\.position) == [minutes(10)])
    }

    @Test("stop ends at the TV position and stops the receiver")
    func stop() async {
        await cast.cast(media, to: livingRoom, appID: "A")
        backend.tv.report(CastPlayback(state: .playing, position: minutes(12)))
        cast.stop()
        #expect(ended.value.map(\.1) == [minutes(12)])
        #expect(endings == [.stopped])
        #expect(backend.tv.calls.last == "stop")
        #expect(cast.state == .off)
    }

    @Test("stop while connecting resumes where the phone was")
    func stopWhileConnecting() async {
        await cast.cast(media, to: livingRoom, appID: "A")
        cast.stop()
        #expect(ended.value.map(\.1) == [minutes(10)])
    }

    @Test("the film ending on the TV is reported once")
    func finished() async {
        await cast.cast(media, to: livingRoom, appID: "A")
        backend.tv.report(CastPlayback(state: .playing, position: minutes(10), duration: minutes(90)))
        backend.tv.report(CastPlayback(state: .idle, duration: minutes(90), idleReason: "FINISHED"))
        backend.tv.disconnect()
        #expect(endings == [.finished])
        #expect(ended.value.map(\.1) == [minutes(90)])
    }

    @Test("the TV closing the connection ends at its last position")
    func disconnected() async {
        await cast.cast(media, to: livingRoom, appID: "A")
        backend.tv.report(CastPlayback(state: .paused, position: minutes(20)))
        backend.tv.disconnect()
        #expect(endings == [.disconnected])
        #expect(ended.value.map(\.1) == [minutes(20)])
        #expect(!backend.tv.calls.contains("stop"))
    }

    @Test("a refused load fails, at the start position")
    func refused() async {
        await cast.cast(media, to: livingRoom, appID: "A")
        backend.tv.refuse("LOAD_FAILED / 104")
        #expect(endings == [.failed])
        #expect(ended.value.map(\.1) == [minutes(10)])
        #expect(cast.state == .failed(livingRoom, reason: "LOAD_FAILED / 104"))
    }

    @Test("a connection that cannot be made fails")
    func cannotConnect() async {
        backend.connectError = Refused(description: "refused")
        await cast.cast(media, to: livingRoom, appID: "A")
        #expect(endings == [.failed])
        #expect(!cast.isCasting)
    }

    @Test("a refused address is looked up again and retried once")
    func retried() async {
        backend.firstConnectError = Refused(description: "Connection refused")
        await cast.cast(media, to: livingRoom, appID: "A")
        #expect(backend.connects == 2)
        #expect(backend.scans == 1)
        #expect(cast.state == .connecting(livingRoom))
        #expect(backend.tv.loaded == media)
    }

    @Test("a refused receiver is not retried")
    func launchRefused() async {
        backend.connectError = Refused(description: "Cast LAUNCH_ERROR: NOT_FOUND")
        await cast.cast(media, to: livingRoom, appID: "A")
        #expect(backend.connects == 1)
        #expect(endings == [.failed])
    }

    @Test("a TV that never starts playing fails after the load timeout")
    func loadTimeout() async {
        await cast.cast(media, to: livingRoom, appID: "A")
        backend.tv.report(CastPlayback(state: .buffering))
        await scheduler.advance(by: .seconds(19))
        #expect(ended.value.isEmpty)
        await scheduler.advance(by: .seconds(2))
        #expect(endings == [.failed])
    }

    @Test("transport goes to the TV")
    func transport() async {
        await cast.cast(media, to: livingRoom, appID: "A")
        cast.pause()
        cast.play()
        cast.seek(to: minutes(30))
        #expect(backend.tv.calls == ["load", "pause", "play", "seek \(minutes(30))"])
    }
}

@Suite("CastMedia")
struct CastMediaTests {
    let source = EYZFlowSource(id: "stream-1", title: "Film", sourceType: .film(catalogueID: "cat"))

    @Test("a film carries the licence URL and the access token")
    func film() {
        let media = CastMedia.for(source, startAt: minutes(5), accessHeader: "token")
        #expect(media.contentURL == "https://stream.eyzflow.com/stream-1/manifest.mpd")
        #expect(media.contentType == "application/dash+xml")
        #expect(media.startAt == minutes(5))
        #expect(media.customData == [
            "manifestUrl": "https://stream.eyzflow.com/stream-1/manifest.mpd",
            "licenseUrl": "https://api.eyzflow.com/v1/drm/stream-1/widevine/acquire",
            "accessToken": "token",
        ])
    }

    @Test("a clear stream carries no licence")
    func clear() {
        let media = CastMedia.for(source, startAt: .zero, accessHeader: nil)
        #expect(media.customData == ["manifestUrl": "https://stream.eyzflow.com/stream-1/manifest.mpd"])
    }

    @Test("a missing currentTime keeps the position")
    func partialStatus() {
        let playing = CastPlayback().updated(with: [
            "playerState": "PLAYING", "currentTime": 12.5, "media": ["duration": 600],
        ])
        #expect(playing == CastPlayback(state: .playing, position: .milliseconds(12500), duration: .seconds(600)))
        let paused = playing.updated(with: ["playerState": "PAUSED"])
        #expect(paused.position == .milliseconds(12500))
        #expect(paused.state == .paused)
    }
}

@Suite("CastCodec")
struct CastCodecTests {
    @Test("a frame round-trips, including long and non-ASCII payloads")
    func roundTrip() throws {
        let message = CastChannelMessage(
            sourceID: "sender-0",
            destinationID: "receiver-0",
            namespace: "urn:x-cast:com.google.cast.media",
            payload: "{\"title\":\"Amélie \(String(repeating: "x", count: 300))\"}"
        )
        var buffer = CastFrameBuffer()
        #expect(try buffer.add(CastCodec.encodeFrame(message)) == [message])
    }

    @Test("partial frames wait; several frames in one read all come out")
    func framing() throws {
        let a = CastChannelMessage(sourceID: "a", destinationID: "b", namespace: "n", payload: "{}")
        let b = CastChannelMessage(sourceID: "c", destinationID: "d", namespace: "n", payload: "{\"x\":1}")
        let bytes = CastCodec.encodeFrame(a) + CastCodec.encodeFrame(b)
        var buffer = CastFrameBuffer()
        #expect(try buffer.add(bytes.prefix(5)).isEmpty)
        #expect(try buffer.add(bytes.dropFirst(5)) == [a, b])
    }
}

@MainActor
@Suite("CastChannel")
struct CastChannelTests {
    let written = Ref<[CastChannelMessage]>([])
    let scheduler = ManualScheduler()
    let channel: CastChannel

    init() {
        let written = self.written
        channel = CastChannel(appID: "A534F914", scheduler: scheduler) { data in
            var buffer = CastFrameBuffer()
            written.value.append(contentsOf: (try? buffer.add(data)) ?? [])
        }
    }

    private func incoming(_ json: String, from source: String = "receiver-0") {
        channel.receive(CastCodec.encodeFrame(CastChannelMessage(
            sourceID: source, destinationID: "sender-0", namespace: "n", payload: json
        )))
    }

    private var types: [String] { written.value.compactMap { $0.json?["type"]?.stringValue } }

    @Test("connects, launches the receiver and joins it once it runs")
    func launch() async {
        var launched = 0
        channel.onLaunched = { launched += 1 }
        channel.start()
        #expect(types == ["CONNECT", "LAUNCH"])
        #expect(written.value[1].json?["appId"]?.stringValue == "A534F914")

        incoming(#"{"type":"RECEIVER_STATUS","status":{"applications":[{"appId":"A534F914","transportId":"t-1"}]}}"#)
        #expect(launched == 1)
        #expect(Array(types.suffix(2)) == ["CONNECT", "GET_STATUS"])
        #expect(written.value.last?.destinationID == "t-1")

        await scheduler.advance(by: .seconds(5))
        #expect(types.last == "PING")
    }

    @Test("loads with the media, and transport names the media session")
    func load() {
        channel.start()
        incoming(#"{"type":"RECEIVER_STATUS","status":{"applications":[{"appId":"A534F914","transportId":"t-1"}]}}"#)
        channel.load(media)
        let load = written.value.last?.json
        #expect(load?["type"]?.stringValue == "LOAD")
        #expect(load?["currentTime"]?.numberValue == 600)
        #expect(load?["media"]?["contentType"]?.stringValue == "application/dash+xml")

        var reported: [CastPlayback] = []
        channel.onPlayback = { reported.append($0) }
        incoming(#"{"type":"MEDIA_STATUS","status":[{"mediaSessionId":7,"playerState":"PLAYING","currentTime":601}]}"#, from: "t-1")
        #expect(reported.last?.state == .playing)
        channel.seek(to: .seconds(900))
        #expect(written.value.last?.json?["mediaSessionId"]?.numberValue == 7)
        #expect(written.value.last?.json?["currentTime"]?.numberValue == 900)
    }

    @Test("answers pings, and reports refusals and launch errors")
    func errors() {
        var errors: [String] = []
        var launchErrors: [String] = []
        channel.onError = { errors.append($0) }
        channel.onLaunchError = { launchErrors.append($0) }
        incoming(#"{"type":"PING"}"#)
        #expect(types.last == "PONG")
        incoming(#"{"type":"LOAD_FAILED","reason":"x","detailedErrorCode":905}"#)
        #expect(errors == ["LOAD_FAILED / x / 905"])
        incoming(#"{"type":"LAUNCH_ERROR","reason":"NOT_FOUND"}"#)
        #expect(launchErrors == ["Cast LAUNCH_ERROR: NOT_FOUND"])
    }

    @Test("the device closing ends the channel once, and nothing is sent after")
    func close() {
        var closed = 0
        channel.onClose = { closed += 1 }
        channel.start()
        incoming(#"{"type":"CLOSE"}"#)
        channel.socketClosed()
        let count = written.value.count
        channel.play()
        #expect(closed == 1)
        #expect(written.value.count == count)
    }
}
