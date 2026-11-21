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

    private func recorder(_ store: RecordingStore, type: EYZFlowSourceType? = .film(catalogueID: "episode")) -> WatchProgressRecorder {
        WatchProgressRecorder(store: store, sourceType: type, log: { _ in })
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
}
