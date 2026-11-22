import Foundation
import Testing
@testable import EYZFlowPlayerCore

@Suite("BeatCollector")
@MainActor
final class BeatCollectorTests {
    var now = 0
    var milestones = 0
    var collector: BeatCollector!

    init() {
        collector = BeatCollector(now: { [unowned self] in self.now })
        collector.onMilestone = { [unowned self] in self.milestones += 1 }
    }

    @Test("times startup to ready and to the first frame")
    func startup() {
        now = 400
        collector.ready(duration: seconds(3600))
        now = 1500
        collector.playing(position: .zero)

        let m = collector.metrics()
        #expect(m.playerStartupMs == 400)
        #expect(m.videoStartupMs == 1500)
        #expect(m.durationS == 3600)
        #expect(milestones == 1)
    }

    @Test("adds time to the state being left, the open one included")
    func stateTime() {
        collector.playing(position: .zero)
        now = 10000
        collector.paused(position: seconds(10))
        now = 15000
        collector.playing(position: seconds(10))
        now = 17000
        collector.bufferingStarted()
        now = 20000

        let m = collector.metrics()
        #expect(m.playedMs == 12000)
        #expect(m.pausedMs == 5000)
        #expect(m.rebufferMs == 3000)
        #expect(m.rebufferCount == 1)
    }

    @Test("buffering before the first frame is startup, not a stall")
    func startupBuffering() {
        collector.bufferingStarted()
        now = 2000
        collector.bufferingEnded()
        collector.playing(position: .zero)

        #expect(collector.metrics().rebufferCount == 0)
    }

    @Test("ending a stall returns to playing or paused")
    func stallEnds() {
        collector.playing(position: .zero)
        collector.bufferingStarted()
        collector.bufferingEnded(isPlaying: false)
        #expect(collector.state == .paused)
    }

    @Test("counts seeks after the first frame; the seek loading is no stall")
    func seeks() {
        collector.seeked(to: seconds(30))
        collector.playing(position: seconds(30))
        now = 5000
        collector.seeked(to: seconds(600))
        now = 5500
        collector.bufferingStarted(position: seconds(600))
        now = 7000
        collector.bufferingEnded(position: seconds(600))
        now = 60000
        collector.bufferingStarted(position: seconds(653))

        let m = collector.metrics()
        #expect(m.seekCount == 1)
        #expect(m.rebufferCount == 1)
        // Played up to the buffering after the seek, and again after it.
        #expect(m.playedMs == 5500 + 53000)
    }

    @Test("estimates the position while playing, up to the duration")
    func estimates() {
        collector.ready(duration: seconds(100))
        collector.playing(position: seconds(10))
        now = 30000
        #expect(collector.metrics().maxPositionS == 40)
        now = 200_000
        #expect(collector.metrics().maxPositionS == 100)
    }

    @Test("keeps the furthest position across a seek back")
    func seekBack() {
        collector.playing(position: seconds(10))
        now = 50000
        collector.seeked(to: seconds(5))
        #expect(collector.metrics().maxPositionS == 60)
    }

    @Test("keeps at most 20 errors, sends each once, returns unsent ones")
    func errors() {
        collector.playing(position: .zero)
        for i in 0..<25 {
            collector.error(code: "E\(i)", message: String(repeating: "x", count: 400), fatal: false)
        }
        let errors = collector.takeErrors()
        #expect(errors.count == 20)
        #expect(errors.first?.n == 0)
        #expect(errors.first?.message?.count == 300)
        #expect(collector.takeErrors().isEmpty)
        #expect(milestones == 1 + 25)

        collector.returnErrors(Array(errors.prefix(2)))
        #expect(collector.takeErrors().map(\.code) == ["E0", "E1"])
    }

    @Test("cuts code to 64 and category to 32 characters")
    func cuts() {
        collector.error(code: String(repeating: "c", count: 100), category: String(repeating: "k", count: 50), fatal: false)
        let error = collector.takeErrors()[0]
        #expect(error.code.count == 64)
        #expect(error.category?.count == 32)
        #expect(error.message == nil)
        #expect(error.positionS == nil)
    }

    @Test("a fatal error ends the impression")
    func fatal() {
        collector.playing(position: .zero)
        now = 4000
        collector.error(code: "PLAYBACK_FAILED")
        now = 9000
        collector.playing()

        #expect(collector.state == .error)
        #expect(collector.metrics().playedMs == 4000)
    }

    @Test("completion stops the clock")
    func completion() {
        collector.playing(position: .zero)
        now = 3000
        collector.completed(position: seconds(3))
        now = 9000
        #expect(collector.state == .ended)
        #expect(collector.metrics().playedMs == 3000)
    }
}

@Suite("BeatTransport")
@MainActor
struct BeatTransportTests {
    @Test("beats on the first frame, every interval, and a final one")
    func beats() async throws {
        let scheduler = ManualScheduler()
        var beats: [Beat] = []
        let collector = BeatCollector(now: { 0 })
        let transport = BeatTransport(
            collector: collector,
            token: { "plk1.a.b" },
            streamID: "stream-1",
            interval: .seconds(60),
            send: { beats.append($0); return true },
            scheduler: scheduler,
            drm: "fairplay",
            platform: .tvos,
            impressionID: "00000000-0000-4000-8000-000000000000",
            wallClock: { Date(timeIntervalSince1970: 1) }
        )
        transport.start()

        collector.playing(position: .zero)
        await transport.flush()
        await scheduler.advance(by: .seconds(120))
        await transport.stop()

        #expect(beats.map(\.seq) == [1, 2, 3, 4])
        #expect(beats.map(\.isFinal) == [false, false, false, true])
        let json = try #require(beats.last?.json)
        #expect(json["token"] == "plk1.a.b")
        #expect(json["sid"] == "00000000-0000-4000-8000-000000000000")
        #expect(json["started_at"] == 1000)
        #expect(json["final"] == true)
        #expect(json["stream_id"] == "stream-1")
        #expect(json["drm"] == "fairplay")
        #expect(json["platform"] == "tvos")
        #expect(json["autoplay"] == true)
        #expect(json["is_live"] == false)
        #expect(json["player_version"] == .string(eyzflowPlayerVersion))
        #expect(json["errors"] == [])
        let m = try #require(json["m"]?.objectValue)
        #expect(Set(m.keys) == [
            "player_startup_ms", "video_startup_ms", "played_ms", "paused_ms", "rebuffer_ms", "rebuffer_count",
            "seek_count", "avg_bitrate", "min_bitrate", "max_bitrate", "quality_switches", "dropped_frames",
            "max_position_s", "duration_s",
        ])
        #expect(m["avg_bitrate"] == .null)

        await transport.stop()
        await scheduler.advance(by: .seconds(120))
        #expect(beats.count == 4)
    }

    @Test("the beat body keeps nulls and names every field as the backend does")
    func body() throws {
        let beat = Beat(
            token: "t", sid: "s", seq: 1, startedAt: 2, isFinal: false, streamID: "x", isLive: false,
            autoplay: true, drm: nil, playerVersion: "ios/0.2.0", platform: nil,
            metrics: BeatMetrics(), errors: [BeatError(n: 0, code: "E")]
        )
        let decoded = try #require(JSONValue.decode(JSONEncoder().encode(beat))?.objectValue)
        #expect(Set(decoded.keys) == [
            "token", "sid", "seq", "started_at", "final", "stream_id", "is_live", "autoplay", "drm",
            "player_version", "platform", "m", "errors",
        ])
        #expect(decoded["drm"] == .null)
        #expect(decoded["platform"] == .null)
        #expect(decoded["errors"] == [["n": 0, "code": "E", "category": nil, "message": nil, "position_s": nil]])
    }

    @Test("sends nothing without a token")
    func noToken() async {
        let scheduler = ManualScheduler()
        var sent = 0
        let transport = BeatTransport(
            collector: BeatCollector(now: { 0 }),
            token: { nil },
            streamID: "s",
            interval: .seconds(10),
            send: { _ in sent += 1; return true },
            scheduler: scheduler
        )
        transport.start()
        await scheduler.advance(by: .seconds(60))
        await transport.stop()
        #expect(sent == 0)
    }

    @Test("puts back the errors of a beat that did not go")
    func putsBackErrors() async {
        let collector = BeatCollector(now: { 0 })
        var sent: [[String]] = []
        let online = Ref(false)
        let transport = BeatTransport(
            collector: collector,
            token: { "t" },
            streamID: "s",
            interval: .seconds(60),
            send: { beat in
                sent.append(beat.errors.map(\.code))
                return online.value
            },
            scheduler: ManualScheduler()
        )

        collector.error(code: "E1")
        await transport.flush()
        online.value = true
        await transport.beat()

        #expect(sent == [["E1"], ["E1"]])
    }

    @Test("beats at most every ten seconds")
    func floor() async {
        let scheduler = ManualScheduler()
        var sent = 0
        let transport = BeatTransport(
            collector: BeatCollector(now: { 0 }),
            token: { "t" },
            streamID: "s",
            interval: .seconds(1),
            send: { _ in sent += 1; return true },
            scheduler: scheduler
        )
        transport.start()
        await scheduler.advance(by: .seconds(30))
        #expect(sent == 3)
    }
}

@Suite("HTTPBeatSender")
struct HTTPBeatSenderTests {
    private let beat = Beat(
        token: "t", sid: "s", seq: 1, startedAt: 0, isFinal: true, streamID: "x", isLive: false,
        autoplay: true, drm: "none", playerVersion: eyzflowPlayerVersion, platform: "ios",
        metrics: BeatMetrics(), errors: []
    )

    @Test("posts to /v1/player/beat; 2xx, 400, 401 and 413 count as delivered")
    func statuses() async throws {
        for (status, delivered) in [(200, true), (204, true), (400, true), (401, true), (413, true), (429, false), (500, false)] {
            let http = FakeHTTPClient { _ in FakeResponse(status) }
            #expect(await HTTPBeatSender(http: http).send(beat) == delivered, "status \(status)")
            let sent = try #require(http.requests.first)
            #expect(sent.call == "POST /v1/player/beat")
            #expect(sent.json?["platform"] == "ios")
        }
        #expect(await !HTTPBeatSender(http: FakeHTTPClient { _ in throw Offline() }).send(beat))
    }
}

@Suite("PlaybackEventAdapter")
@MainActor
struct PlaybackEventAdapterTests {
    @Test("feeds events into the collector")
    func feeds() {
        let now = Ref(0)
        let collector = BeatCollector(now: { now.value })
        let adapter = PlaybackEventAdapter(collector)
        adapter.add(.ready(sourceId: "s", position: .zero, duration: seconds(100)))
        now.value = 500
        adapter.add(.started(sourceId: "s", position: .zero))
        now.value = 2500
        adapter.add(.paused(sourceId: "s", position: seconds(2)))
        adapter.add(.bufferingStarted(sourceId: "s", position: seconds(2)))
        adapter.add(.bufferingEnded(sourceId: "s", position: seconds(2)))
        #expect(collector.state == .paused)
        adapter.add(.resumed(sourceId: "s", position: seconds(2)))
        now.value = 4500
        adapter.add(.seeked(sourceId: "s", from: seconds(4), position: seconds(50)))
        adapter.add(.error(sourceId: "s", message: "boom", position: seconds(50)))

        let m = collector.metrics()
        #expect(m.playerStartupMs == 0)
        #expect(m.videoStartupMs == 500)
        #expect(m.playedMs == 4000)
        #expect(m.seekCount == 1)
        #expect(m.durationS == 100)
        #expect(collector.state == .error)
        let error = collector.takeErrors().first
        #expect(error?.code == "PLAYBACK_FAILED")
        #expect(error?.message == "boom")
    }

    @Test("events describe themselves as the Dart player logs them")
    func descriptions() {
        #expect(PlaybackEvent.seeked(sourceId: "s", from: seconds(10), position: seconds(100), duration: .seconds(5400)).description
            == "PlaybackSeeked(sourceId: s, position: 0:01:40, duration: 1:30:00, from: 0:00:10)")
        #expect(PlaybackEvent.subtitleTrackChanged(sourceId: "s", language: nil, position: .zero).description
            == "PlaybackSubtitleTrackChanged(sourceId: s, position: 0:00:00, language: null)")
    }
}
