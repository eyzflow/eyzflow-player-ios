import Foundation
import Testing
@testable import EYZFlowPlayerCore

/// Records every save; fails them while `error` is set.
private actor RecordingStore: WatchProgressStore {
    struct Write: Equatable {
        let catalogueID: String
        let seconds: Double
        let completed: Bool
    }

    var writes: [Write] = []
    var error: (any Error)?
    var delay: Duration?

    func setError(_ error: (any Error)?) { self.error = error }
    func setDelay(_ delay: Duration?) { self.delay = delay }

    func save(catalogueID: String, progressSeconds: Double, completed: Bool) async throws {
        writes.append(Write(catalogueID: catalogueID, seconds: progressSeconds, completed: completed))
        if let delay { try await Task.sleep(for: delay) }
        if let error { throw error }
    }
}

@MainActor
@Suite("WatchProgressRecorder")
struct WatchProgressRecorderTests {
    private let film = EYZFlowSourceType.film(catalogueID: "episode")

    private func recorder(
        _ store: RecordingStore,
        type: EYZFlowSourceType? = .film(catalogueID: "episode"),
        start: Duration? = nil
    ) -> WatchProgressRecorder {
        WatchProgressRecorder(store: store, sourceType: type, startPosition: start, log: { _ in })
    }

    @Test("saves at most once per interval while playing")
    func throttles() async {
        let store = RecordingStore()
        let recorder = recorder(store)
        #expect(recorder.isRecording)
        recorder.report(.seconds(3))
        recorder.report(.seconds(9))
        recorder.report(.seconds(13))
        await recorder.flush()
        #expect(await store.writes.map(\.seconds) == [3, 13])
    }

    @Test("a pause saves at once; completion once, and never reopened")
    func checkpointAndFinish() async {
        let store = RecordingStore()
        let recorder = recorder(store)
        recorder.report(.seconds(20))
        recorder.checkpoint(.seconds(23))
        recorder.finish()
        recorder.report(.seconds(45))
        recorder.checkpoint(.seconds(46))
        recorder.finish()
        await recorder.flush()
        #expect(await store.writes == [
            .init(catalogueID: "episode", seconds: 20, completed: false),
            .init(catalogueID: "episode", seconds: 23, completed: false),
            .init(catalogueID: "episode", seconds: 23, completed: true),
        ])
    }

    @Test("the receiver's final position completes watch progress after the last tick")
    func receiverFinished() async {
        let store = RecordingStore()
        let recorder = recorder(store)
        recorder.report(.seconds(118))
        recorder.finish(at: .seconds(120))
        await recorder.flush()
        #expect(await store.writes.last == .init(catalogueID: "episode", seconds: 120, completed: true))
    }

    @Test("saves run in order: completion after a slow progress write")
    func ordered() async {
        let store = RecordingStore()
        await store.setDelay(.milliseconds(50))
        let recorder = recorder(store)
        recorder.report(.seconds(30))
        recorder.finish()
        await recorder.flush()
        #expect(await store.writes.map(\.completed) == [false, true])
    }

    @Test("a trailer records nothing")
    func trailer() async {
        let store = RecordingStore()
        let recorder = recorder(store, type: .trailer(catalogueID: "t"))
        #expect(!recorder.isRecording)
        recorder.report(.seconds(30))
        recorder.finish()
        await recorder.flush()
        #expect(await store.writes.isEmpty)
    }

    @Test("a failed save is swallowed and later saves go on")
    func failure() async {
        let store = RecordingStore()
        await store.setError(URLError(.notConnectedToInternet))
        let recorder = recorder(store)
        recorder.report(.seconds(30))
        await recorder.flush()
        await store.setError(nil)
        recorder.checkpoint(.seconds(31))
        await recorder.flush()
        #expect(await store.writes.map(\.seconds) == [30, 31])
    }

    // MARK: Resume guard

    @Test("a resume saves nothing before playback reaches the start position")
    func resumeGuard() async {
        let store = RecordingStore()
        let recorder = recorder(store, start: .seconds(754))
        // The player reports 0 before the resume seek lands, and pauses or
        // leaves there.
        recorder.report(.zero)
        recorder.checkpoint(.seconds(1))
        recorder.report(.seconds(30))
        await recorder.flush()
        #expect(await store.writes.isEmpty)
        // Within 2 s of the start counts as there.
        recorder.report(.seconds(753))
        recorder.checkpoint(.seconds(760))
        await recorder.flush()
        #expect(await store.writes.map(\.seconds) == [753, 760])
    }

    @Test("a viewer seek before the start position is theirs and saved")
    func seekBeforeStart() async {
        let store = RecordingStore()
        let recorder = recorder(store, start: .seconds(754))
        recorder.report(.zero)
        recorder.seeked(to: .seconds(120))
        recorder.report(.seconds(131))
        await recorder.flush()
        #expect(await store.writes.map(\.seconds) == [120, 131])
    }

    @Test("reloading from a new position guards it again; nil arms at once")
    func reload() async {
        let store = RecordingStore()
        let recorder = recorder(store)
        recorder.report(.seconds(40))
        recorder.reload(from: .seconds(300))
        recorder.report(.zero)
        recorder.report(.seconds(299))
        recorder.reload(from: nil)
        recorder.report(.seconds(20))
        await recorder.flush()
        #expect(await store.writes.map(\.seconds) == [40, 299, 20])
    }

    @Test("a film's first save is never 0 s, not completed")
    func neverWatched() async {
        let store = RecordingStore()
        let recorder = recorder(store)
        recorder.report(.zero)
        recorder.checkpoint(.milliseconds(900))
        await recorder.flush()
        #expect(await store.writes.isEmpty)
        recorder.report(.seconds(12))
        recorder.checkpoint(.zero)
        await recorder.flush()
        // Once watched, going back to the start is saved.
        #expect(await store.writes.map(\.seconds) == [12, 0])
    }

    @Test("saves whole seconds and skips a repeat of the last save")
    func wholeSeconds() async {
        let store = RecordingStore()
        let recorder = recorder(store)
        recorder.report(.milliseconds(12_700))
        recorder.checkpoint(.milliseconds(12_900))
        await recorder.flush()
        #expect(await store.writes.map(\.seconds) == [12])
    }

    // MARK: Completed

    @Test("completed from 95 % of the duration by default")
    func completedDefault() async {
        let store = RecordingStore()
        let recorder = recorder(store)
        #expect(recorder.completedPercent == 95)
        recorder.report(.seconds(940), duration: .seconds(1000))
        recorder.report(.seconds(950), duration: .seconds(1000))
        await recorder.flush()
        #expect(await store.writes.map(\.completed) == [false, true])
    }

    @Test("completedPercent from the config: clamped to 50–100")
    func completedPercent() async {
        let store = RecordingStore()
        let recorder = recorder(store)
        recorder.completedPercent = 80
        recorder.report(.seconds(800), duration: .seconds(1000))
        await recorder.flush()
        #expect(await store.writes.last?.completed == true)
        recorder.completedPercent = 10
        #expect(recorder.completedPercent == 50)
        recorder.completedPercent = 250
        #expect(recorder.completedPercent == 100)
        recorder.completedPercent = .nan
        #expect(recorder.completedPercent == 95)
    }

    @Test("100 % completes only at the end itself; finish() at the duration")
    func completedAtEnd() async {
        let store = RecordingStore()
        let recorder = recorder(store)
        recorder.completedPercent = 100
        recorder.report(.seconds(990), duration: .seconds(1000))
        recorder.checkpoint(.seconds(998))
        await recorder.flush()
        #expect(await store.writes.map(\.completed) == [false, false])
        recorder.finish()
        await recorder.flush()
        #expect(await store.writes.last == .init(catalogueID: "episode", seconds: 1000, completed: true))
    }
}

// MARK: - EYZFlowWatchHistoryStore

private struct AppStore: WatchProgressStore {
    func save(catalogueID: String, progressSeconds: Double, completed: Bool) async throws {}
}

@Suite("EYZFlowWatchHistoryStore")
struct EYZFlowWatchHistoryStoreTests {
    private let endpoints = EYZFlowEndpoints(api: "https://api.test")

    @Test("PUTs the watch history with the viewer's Authorization")
    func request() async throws {
        let http = FakeHTTPClient { _ in FakeResponse(204) }
        let store = EYZFlowWatchHistoryStore(
            storefrontID: "sf 1",
            authorization: "Bearer viewer",
            offerID: "offer-1",
            http: http,
            endpoints: endpoints
        )
        try await store.save(catalogueID: "cat-1", progressSeconds: 754.9, completed: false)
        let sent = try #require(http.requests.first)
        #expect(http.calls == ["PUT /v1/content/storefront/sf%201/watch-history"])
        #expect(sent.url.host == "api.test")
        #expect(sent.headers["Authorization"] == "Bearer viewer")
        #expect(sent.headers["Content-Type"] == "application/json")
        #expect(sent.json == [
            "catalogue_id": "cat-1",
            "progress_seconds": 754,
            "completed": false,
            "offer_id": "offer-1",
        ])
    }

    @Test("no offer: no offer_id")
    func noOffer() async throws {
        let http = FakeHTTPClient { _ in FakeResponse(200) }
        for offer in [nil, ""] as [String?] {
            let store = EYZFlowWatchHistoryStore(storefrontID: "sf", authorization: "Bearer v", offerID: offer, http: http, endpoints: endpoints)
            try await store.save(catalogueID: "cat-1", progressSeconds: 60, completed: true)
        }
        for sent in http.requests {
            #expect(sent.json == ["catalogue_id": "cat-1", "progress_seconds": 60, "completed": true])
        }
    }

    @Test("a refusal throws")
    func refused() async {
        let http = FakeHTTPClient { _ in FakeResponse(401) }
        let store = EYZFlowWatchHistoryStore(storefrontID: "sf", authorization: "Bearer v", http: http, endpoints: endpoints)
        await #expect(throws: EYZFlowRequestError.self) {
            try await store.save(catalogueID: "cat-1", progressSeconds: 60, completed: false)
        }
    }

    @Test("a film with credentials saves to the EYZFlow watch history")
    @MainActor
    func defaultStore() async throws {
        let http = FakeHTTPClient { _ in FakeResponse(204) }
        let store = try #require(resolveWatchProgressStore(
            sourceType: .film(catalogueID: "cat-1"),
            appStore: nil,
            authorization: "Bearer viewer",
            storefrontID: "sf",
            offerID: "offer-1",
            endpoints: endpoints,
            http: http
        ) as? EYZFlowWatchHistoryStore)
        #expect(store.offerID == "offer-1")
        let recorder = WatchProgressRecorder(store: store, sourceType: .film(catalogueID: "cat-1"), log: { _ in })
        recorder.report(.seconds(42))
        await recorder.flush()
        #expect(http.calls == ["PUT /v1/content/storefront/sf/watch-history"])
        #expect(http.requests.first?.json?["progress_seconds"] == 42)
    }

    @Test("the app's own store replaces the default")
    func appStore() {
        let store = resolveWatchProgressStore(
            sourceType: .film(catalogueID: "cat-1"),
            appStore: AppStore(),
            authorization: "Bearer viewer",
            storefrontID: "sf",
            offerID: nil
        )
        #expect(store is AppStore)
    }

    @Test("saveWatchProgress false saves nothing, to either store")
    func optOut() {
        for app in [nil, AppStore()] as [AppStore?] {
            #expect(resolveWatchProgressStore(
                sourceType: .film(catalogueID: "cat-1"),
                saveWatchProgress: false,
                appStore: app,
                authorization: "Bearer viewer",
                storefrontID: "sf",
                offerID: nil
            ) == nil)
        }
    }

    @Test("no credentials: no store, so no request")
    @MainActor
    func noCredentials() async {
        let http = FakeHTTPClient { _ in FakeResponse(204) }
        let cases: [(String?, String?)] = [(nil, "sf"), ("Bearer v", nil), ("", "sf"), ("Bearer v", ""), (nil, nil)]
        for (authorization, storefront) in cases {
            #expect(resolveWatchProgressStore(
                sourceType: .film(catalogueID: "cat-1"),
                appStore: nil,
                authorization: authorization,
                storefrontID: storefront,
                offerID: nil,
                endpoints: endpoints,
                http: http
            ) == nil)
        }
        #expect(http.requests.isEmpty)
    }

    @Test("trailers and sources without a type save nothing")
    func trailers() {
        for type in [.trailer(catalogueID: "t"), nil, .film(catalogueID: "")] as [EYZFlowSourceType?] {
            #expect(resolveWatchProgressStore(
                sourceType: type,
                appStore: AppStore(),
                authorization: "Bearer viewer",
                storefrontID: "sf",
                offerID: nil
            ) == nil)
        }
    }
}
