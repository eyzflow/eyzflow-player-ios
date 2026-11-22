import Foundation
import Testing
@testable import EYZFlowPlayerCore

@MainActor
final class FakeAdDriver: AdDriver {
    var calls: [String] = []
    var onRequest: (() -> Void)?

    func requestAds() {
        calls.append("request")
        onRequest?()
    }
    func startAds() { calls.append("start") }
    func discardAds() { calls.append("discard") }
    func contentComplete() { calls.append("contentComplete") }
    func pauseContent() { calls.append("pause") }
    func resumeContent() { calls.append("resume") }
}

@Suite("Ad break scheduler")
@MainActor
final class AdSchedulerTests {
    let driver = FakeAdDriver()
    let clock = ManualScheduler()
    var breaks: [String] = []

    private func make(markers: [AdBreak], suppressed: @escaping @MainActor () -> Bool = { false }) async -> AdBreakScheduler {
        let ads = PlayerAds(adTagURL: "https://ads/tag")
        ads.loadMarkers { markers }
        await ads.markersLoaded()
        return make(ads, suppressed: suppressed)
    }

    private func make(_ ads: PlayerAds, suppressed: @escaping @MainActor () -> Bool = { false }) -> AdBreakScheduler {
        let scheduler = AdBreakScheduler(ads: ads, driver: driver, scheduler: clock, suppressed: suppressed)
        scheduler.onBreakStarted = { [unowned self] in breaks.append("started") }
        scheduler.onBreakEnded = { [unowned self] in breaks.append("ended") }
        return scheduler
    }

    /// Runs `beforeContent()` until it waits for the ad, and returns a task
    /// that finishes with it.
    private func startBeforeContent(_ scheduler: AdBreakScheduler) async -> Task<Void, Never> {
        let task = Task { await scheduler.beforeContent() }
        while !driver.calls.contains("request") { await Task.yield() }
        return task
    }

    // MARK: Without markers

    @Test("without markers the tag is requested before the content and its pre-roll plays")
    func tagPreroll() async {
        let scheduler = await make(markers: [])
        let task = await startBeforeContent(scheduler)
        #expect(scheduler.inBreak)
        #expect(scheduler.containerNeeded)
        scheduler.adsLoaded(cuePoints: [])
        scheduler.contentPauseRequested()
        #expect(scheduler.adPlaying)
        scheduler.contentResumeRequested()
        await task.value
        #expect(driver.calls == ["request", "start", "discard"])
        #expect(breaks == ["started", "ended"])
        #expect(!scheduler.containerNeeded)
    }

    @Test("an empty or failed tag lets the content play with no error")
    func tagFails() async {
        let scheduler = await make(markers: [])
        let task = await startBeforeContent(scheduler)
        scheduler.adsFailed()
        await task.value
        #expect(driver.calls == ["request", "discard"])
        #expect(breaks == ["started", "ended"])
    }

    @Test("a tag that does not answer gives up after 12 s, and its late answer is dropped")
    func tagTimesOut() async {
        let scheduler = await make(markers: [])
        let task = await startBeforeContent(scheduler)
        await clock.advance(by: .seconds(11))
        #expect(scheduler.inBreak)
        await clock.advance(by: .seconds(1))
        await task.value
        #expect(!scheduler.inBreak)
        scheduler.adsLoaded(cuePoints: [])
        #expect(driver.calls == ["request", "discard", "discard"])
    }

    @Test("a VMAP without markers keeps its schedule: mid-roll and post-roll")
    func vmapSchedule() async {
        let scheduler = await make(markers: [])
        let task = await startBeforeContent(scheduler)
        scheduler.adsLoaded(cuePoints: [.zero, .seconds(15), .seconds(-1)])
        scheduler.contentPauseRequested()
        scheduler.contentResumeRequested()
        await task.value
        #expect(scheduler.containerNeeded)
        #expect(driver.calls == ["request", "start"])

        // IMA's own mid-roll, from the content playhead.
        scheduler.contentPauseRequested()
        #expect(scheduler.inBreak)
        scheduler.contentResumeRequested()
        #expect(driver.calls == ["request", "start", "pause", "resume"])

        // The post-roll after the content ended.
        let end = Task { await scheduler.contentCompleted() }
        while !driver.calls.contains("contentComplete") { await Task.yield() }
        scheduler.contentPauseRequested()
        scheduler.allAdsCompleted()
        await end.value
        #expect(driver.calls == ["request", "start", "pause", "resume", "contentComplete", "discard"])
        #expect(breaks == ["started", "ended", "started", "ended", "started", "ended"])
    }

    @Test("a VMAP without a pre-roll starts the content at once")
    func vmapNoPreroll() async {
        let scheduler = await make(markers: [])
        let task = await startBeforeContent(scheduler)
        scheduler.adsLoaded(cuePoints: [.seconds(15)])
        await task.value
        #expect(driver.calls == ["request", "start"])
        #expect(scheduler.containerNeeded)
    }

    // MARK: With markers

    @Test("markers without one at the start: no pre-roll, a mid-roll when playback reaches it")
    func markerMidroll() async {
        let scheduler = await make(markers: [AdBreak(id: "mid", start: .seconds(8))])
        await scheduler.beforeContent()
        #expect(driver.calls.isEmpty)

        scheduler.contentPosition(.seconds(7))
        scheduler.contentPosition(.milliseconds(7500))
        #expect(driver.calls.isEmpty)
        scheduler.contentPosition(.milliseconds(8000))
        #expect(driver.calls == ["pause", "request"])
        #expect(scheduler.inBreak)
        scheduler.adsLoaded(cuePoints: [])
        scheduler.contentPauseRequested()
        scheduler.contentResumeRequested()
        #expect(driver.calls == ["pause", "request", "start", "discard", "resume"])

        // Rewinding and playing through again plays nothing.
        scheduler.contentPosition(.seconds(2))
        scheduler.contentPosition(.milliseconds(7900))
        scheduler.contentPosition(.milliseconds(8400))
        #expect(driver.calls.count == 5)
    }

    @Test("markers at 0 s and 8 s: a pre-roll, then a mid-roll")
    func markerPrerollAndMid() async {
        let scheduler = await make(markers: [AdBreak(id: "pre", start: .zero), AdBreak(id: "mid", start: .seconds(8))])
        let task = await startBeforeContent(scheduler)
        scheduler.adsLoaded(cuePoints: [])
        scheduler.contentPauseRequested()
        scheduler.contentResumeRequested()
        await task.value
        #expect(driver.calls == ["request", "start", "discard"])

        scheduler.contentPosition(.milliseconds(7600))
        scheduler.contentPosition(.milliseconds(8100))
        #expect(driver.calls.suffix(2) == ["pause", "request"])
    }

    @Test("markers win over a VMAP: only its pre-roll plays at a marker, its own schedule is dropped")
    func markersWinOverVMAP() async {
        let scheduler = await make(markers: [AdBreak(id: "a", start: .seconds(8)), AdBreak(id: "b", start: .seconds(30))])
        await scheduler.beforeContent()
        scheduler.contentPosition(.milliseconds(7600))
        scheduler.contentPosition(.milliseconds(8100))
        scheduler.adsLoaded(cuePoints: [.zero, .seconds(15), .seconds(-1)])
        scheduler.contentPauseRequested()
        scheduler.contentResumeRequested()
        // Dropped right after the marker's break, so the 15 s mid-roll and the
        // post-roll never play.
        #expect(driver.calls == ["pause", "request", "start", "discard", "resume"])
        #expect(!scheduler.containerNeeded)
        await scheduler.contentCompleted()
        #expect(!driver.calls.contains("contentComplete"))
    }

    @Test("a VMAP without a pre-roll gives no ad at a marker")
    func vmapNoPrerollAtMarker() async {
        let scheduler = await make(markers: [AdBreak(id: "a", start: .seconds(8))])
        await scheduler.beforeContent()
        scheduler.contentPosition(.milliseconds(7600))
        scheduler.contentPosition(.milliseconds(8100))
        scheduler.adsLoaded(cuePoints: [.seconds(15)])
        #expect(driver.calls == ["pause", "request", "discard", "resume"])
        #expect(breaks == ["started", "ended"])
    }

    @Test("seeking past a marker plays no ad")
    func seekPastMarker() async {
        let scheduler = await make(markers: [AdBreak(id: "a", start: .seconds(8))])
        await scheduler.beforeContent()
        scheduler.contentPosition(.seconds(4))
        scheduler.contentPosition(.seconds(20))
        scheduler.contentPosition(.milliseconds(20500))
        #expect(driver.calls.isEmpty)
    }

    @Test("a failed tag at a mid-roll resumes the content with no error")
    func midrollFails() async {
        let scheduler = await make(markers: [AdBreak(id: "a", start: .seconds(8))])
        await scheduler.beforeContent()
        scheduler.contentPosition(.milliseconds(7600))
        scheduler.contentPosition(.milliseconds(8100))
        scheduler.adsFailed()
        #expect(driver.calls == ["pause", "request", "discard", "resume"])
        #expect(!scheduler.inBreak)
    }

    @Test("a mid-roll that does not answer resumes after 12 s")
    func midrollTimesOut() async {
        let scheduler = await make(markers: [AdBreak(id: "a", start: .seconds(8))])
        await scheduler.beforeContent()
        scheduler.contentPosition(.milliseconds(7600))
        scheduler.contentPosition(.milliseconds(8100))
        await clock.advance(by: .seconds(12))
        #expect(driver.calls == ["pause", "request", "discard", "resume"])
    }

    // MARK: Suppressed, and the impression

    @Test("no ads while suppressed (AirPlay)")
    func suppressed() async {
        let scheduler = await make(markers: [AdBreak(id: "pre", start: .zero), AdBreak(id: "a", start: .seconds(8))], suppressed: { true })
        await scheduler.beforeContent()
        scheduler.contentPosition(.milliseconds(7600))
        scheduler.contentPosition(.milliseconds(8100))
        #expect(driver.calls.isEmpty)
        #expect(breaks.isEmpty)
    }

    @Test("a new player for the same impression (after casting) repeats neither the pre-roll nor played breaks")
    func handBack() async {
        let ads = PlayerAds(adTagURL: "https://ads/tag")
        ads.loadMarkers { [AdBreak(id: "pre", start: .zero), AdBreak(id: "a", start: .seconds(8)), AdBreak(id: "b", start: .seconds(30))] }
        let first = make(ads)
        let task = await startBeforeContent(first)
        first.adsFailed()
        await task.value
        first.contentPosition(.milliseconds(7600))
        first.contentPosition(.milliseconds(8100))
        first.adsFailed()
        first.dispose()
        driver.calls = []

        let second = make(ads)
        await second.beforeContent()
        second.contentPosition(.milliseconds(7600))
        second.contentPosition(.milliseconds(8100))
        #expect(driver.calls.isEmpty)
        second.contentPosition(.milliseconds(29600))
        second.contentPosition(.milliseconds(30100))
        #expect(driver.calls == ["pause", "request"])
    }

    @Test("disposing during a break ends it and drops the ads")
    func disposeInBreak() async {
        let scheduler = await make(markers: [])
        let task = await startBeforeContent(scheduler)
        scheduler.dispose()
        await task.value
        #expect(breaks == ["started", "ended"])
        #expect(driver.calls == ["request", "discard"])
    }
}

@Suite("Analytics around ad breaks")
@MainActor
struct AdAnalyticsTests {
    @Test("ad time counts as neither played, paused nor startup time")
    func adTimeLeftOut() {
        let box = Ref(0)
        let collector = BeatCollector(now: { box.value })
        let adapter = PlaybackEventAdapter(collector)
        func at(_ ms: Int, _ event: PlaybackEvent) {
            box.value = ms
            adapter.add(event)
        }
        // A 20 s pre-roll before the first frame.
        at(300, .ready(sourceId: "s", position: .zero))
        at(500, .adBreakStarted(sourceId: "s", position: .zero))
        at(20500, .adBreakEnded(sourceId: "s", position: .zero))
        at(21000, .started(sourceId: "s", position: .zero))
        // Played 10 s, then a 30 s mid-roll with the content paused under it.
        at(31000, .adBreakStarted(sourceId: "s", position: .seconds(10)))
        at(31100, .paused(sourceId: "s", position: .seconds(10)))
        at(60000, .resumed(sourceId: "s", position: .seconds(10)))
        at(61000, .adBreakEnded(sourceId: "s", position: .seconds(10)))
        box.value = 66000
        let m = collector.metrics()
        #expect(m.videoStartupMs == 1000)
        #expect(m.playedMs == 15000)
        #expect(m.pausedMs == 0)
        #expect(m.maxPositionS == 15)
    }

    @Test("the tracker reports a break once, and ends one still open on close")
    func trackerEvents() {
        let tracker = PlaybackEventTracker(sourceID: "s")
        var names: [String] = []
        tracker.onEvent = { names.append($0.name) }
        tracker.adBreakStarted()
        tracker.adBreakStarted()
        tracker.adBreakEnded()
        tracker.adBreakEnded()
        tracker.adBreakStarted()
        tracker.close()
        #expect(names == [
            "PlaybackAdBreakStarted", "PlaybackAdBreakEnded",
            "PlaybackAdBreakStarted", "PlaybackAdBreakEnded", "PlaybackClosed",
        ])
    }
}
