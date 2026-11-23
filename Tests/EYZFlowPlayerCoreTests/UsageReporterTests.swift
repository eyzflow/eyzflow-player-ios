import Foundation
import Testing
@testable import EYZFlowPlayerCore

private let target = UsageTarget(
    storefrontID: "sf",
    authorization: "Bearer viewer",
    offerID: "0b6c7c55-2a8e-4b1f-9d6e-1c2f3a4b5c6d",
    catalogueID: "6f1e2d3c-4b5a-4968-8776-655443322110"
)

@MainActor
private final class UsageHarness {
    let scheduler = ManualScheduler()
    var playedMs = 0
    var results: [UsageSendResult] = []
    var sent: [JSONValue] = []
    var reporter: UsageReporter!

    init(_ results: [UsageSendResult] = [], target: UsageTarget = target) {
        self.results = results
        reporter = UsageReporter(
            target: target,
            playedMs: { [unowned self] in playedMs },
            send: { [unowned self] _, body in
                sent.append(body)
                return self.results.isEmpty ? .ok : self.results.removeFirst()
            },
            scheduler: scheduler,
            sessionID: "sess-0001"
        )
    }

    var seconds: [Int] { sent.compactMap { $0["watched_seconds"]?.numberValue.map { Int($0) } } }
}

@Suite("UsageReporter")
@MainActor
struct UsageReporterTests {
    @Test("reports the whole seconds played since the last report, with one session id")
    func deltas() async {
        let h = UsageHarness()
        h.playedMs = 30_400
        await h.reporter.report()
        h.playedMs += 29_800
        await h.reporter.report()
        #expect(h.seconds == [30, 30])
        #expect(h.sent.first == [
            "offer_id": .string(target.offerID),
            "catalogue_id": .string(target.catalogueID!),
            "session_id": "sess-0001",
            "watched_seconds": 30,
            "is_trailer": false,
        ])
    }

    @Test("sends nothing for less than a second")
    func underASecond() async {
        let h = UsageHarness()
        h.playedMs = 900
        await h.reporter.report()
        #expect(h.sent.isEmpty)
    }

    @Test("sends at most 120 s at once and the rest with the next report")
    func capped() async {
        let h = UsageHarness()
        h.playedMs = 200_000
        await h.reporter.report()
        await h.reporter.report()
        #expect(h.seconds == [120, 80])
    }

    @Test("sends seconds again after a failed report, but not after a refused one")
    func retryAndDrop() async {
        let h = UsageHarness([.retry, .ok, .drop])
        h.playedMs = 10_000
        await h.reporter.report()
        h.playedMs += 5_000
        await h.reporter.report()
        h.playedMs += 7_000
        await h.reporter.report()
        h.playedMs += 3_000
        await h.reporter.report()
        #expect(h.seconds == [10, 15, 7, 3])
    }

    @Test("reports every 30 s, and once more when stopped")
    func timerAndStop() async {
        let h = UsageHarness()
        h.reporter.start()
        h.playedMs = 30_000
        await h.scheduler.advance(by: .seconds(30))
        h.playedMs += 12_000
        await h.reporter.stop()
        await h.reporter.stop()
        h.playedMs += 8_000
        await h.reporter.report()
        #expect(h.seconds == [30, 12])
        #expect(h.scheduler.pendingTimers == 0)
    }

    @Test("leaves out a catalogue id that is not a UUID")
    func catalogueNotUUID() async {
        var other = target
        other.catalogueID = "film-42"
        let h = UsageHarness(target: other)
        h.playedMs = 5_000
        await h.reporter.report()
        #expect(h.sent.first?["catalogue_id"] == nil)
    }

    @Test("posts to playback-events with the viewer's authorization; 404 is dropped, 500 retried")
    func httpSender() async {
        let status = Box(201)
        let http = FakeHTTPClient { _ in FakeResponse(status.value) }
        let sender = HTTPUsageSender(http: http)
        #expect(await sender.send(target, ["watched_seconds": 30]) == .ok)
        status.value = 404
        #expect(await sender.send(target, ["watched_seconds": 30]) == .drop)
        status.value = 500
        #expect(await sender.send(target, ["watched_seconds": 30]) == .retry)
        #expect(http.calls.first == "POST /v1/content/storefront/sf/playback-events")
        #expect(http.requests.first?.headers["Authorization"] == "Bearer viewer")
        #expect(http.requests.first?.json == ["watched_seconds": 30])
    }
}

@Suite("PlaybackCoordinator royalty usage")
@MainActor
struct PlaybackCoordinatorUsageTests {
    private func coordinator(
        _ config: PlaybackCoordinatorConfig,
        clock: Ref<Int>,
        sent: Ref<[JSONValue]>,
        scheduler: ManualScheduler,
        http: FakeHTTPClient
    ) -> PlaybackCoordinator {
        PlaybackCoordinator(
            config: config,
            licenseClient: PlayerLicenseClient(http: http),
            sessionClient: PlaybackSessionClient(http: http),
            beatSender: { _ in true },
            usageSender: { _, body in sent.value.append(body); return .ok },
            deviceIDStore: MemoryDeviceIDStore("device-1"),
            scheduler: scheduler,
            now: { clock.value },
            log: { _ in }
        )
    }

    private let http = FakeHTTPClient { request in
        if request.path.hasSuffix("/playback-sessions") {
            return .json(["id": "ps_1", "heartbeat_interval_seconds": 600], 201)
        }
        return FakeResponse(204)
    }

    @Test("reports the film's played time without a player key, on pause and on close; ads, seeks and stalls add nothing")
    func reportsPlayedTime() async {
        let clock = Ref(0)
        let sent = Ref<[JSONValue]>([])
        let scheduler = ManualScheduler()
        let c = coordinator(
            PlaybackCoordinatorConfig(
                streamID: "stream-1",
                isProtected: true,
                drmAuthorization: "Bearer viewer",
                storefrontID: "sf",
                platform: .ios,
                offerID: "offer-1"
            ),
            clock: clock,
            sent: sent,
            scheduler: scheduler,
            http: http
        )
        await c.start()
        c.handle(event: .started(sourceId: "stream-1", position: .zero))
        clock.value += 20_000
        c.handle(event: .adBreakStarted(sourceId: "stream-1", position: seconds(20)))
        clock.value += 30_000 // a 30 s ad
        c.handle(event: .adBreakEnded(sourceId: "stream-1", position: seconds(20)))
        c.handle(event: .seeked(sourceId: "stream-1", from: seconds(20), position: seconds(1800)))
        c.handle(event: .bufferingStarted(sourceId: "stream-1", position: seconds(1800)))
        clock.value += 2_000
        c.handle(event: .bufferingEnded(sourceId: "stream-1", position: seconds(1800)))
        clock.value += 5_000
        c.handle(event: .paused(sourceId: "stream-1", position: seconds(1805)))
        await c.flush()
        clock.value += 60_000 // paused
        c.handle(event: .resumed(sourceId: "stream-1", position: seconds(1805)))
        clock.value += 7_000
        await c.close()

        #expect(sent.value.compactMap { $0["watched_seconds"]?.numberValue } == [25, 7])
        #expect(Set(sent.value.compactMap { $0["session_id"]?.stringValue }).count == 1)
        #expect(sent.value.allSatisfy { $0["offer_id"] == "offer-1" })
    }

    @Test("reports nothing without an offer id or a viewer")
    func noTarget() async {
        let clock = Ref(0)
        let sent = Ref<[JSONValue]>([])
        let scheduler = ManualScheduler()
        for config in [
            PlaybackCoordinatorConfig(streamID: "s", isProtected: true, drmAuthorization: "Bearer viewer", storefrontID: "sf", platform: .ios),
            PlaybackCoordinatorConfig(streamID: "s", isProtected: false, storefrontID: "sf", platform: .ios, offerID: "offer-1"),
        ] {
            let c = coordinator(config, clock: clock, sent: sent, scheduler: scheduler, http: http)
            await c.start()
            c.handle(event: .started(sourceId: "s", position: .zero))
            clock.value += 30_000
            await c.close()
        }
        #expect(sent.value.isEmpty)
    }
}
