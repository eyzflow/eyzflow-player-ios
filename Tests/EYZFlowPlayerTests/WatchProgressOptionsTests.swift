import EYZFlowPlayerCore
import Testing
@testable import EYZFlowPlayer

private struct AppStore: WatchProgressStore {
    func save(catalogueID: String, progressSeconds: Double, completed: Bool) async throws {}
}

@Suite("EYZFlowPlayerOptions watch progress")
struct WatchProgressOptionsTests {
    private func options(
        store: (any WatchProgressStore)? = nil,
        save: Bool = true,
        authorization: String? = "Bearer viewer"
    ) -> EYZFlowPlayerOptions {
        EYZFlowPlayerOptions(
            streamID: "stream",
            title: "Film",
            sourceType: .film(catalogueID: "cat-1"),
            drmAuthorization: authorization,
            storefrontID: "sf",
            offerID: "offer-1",
            watchProgressStore: store,
            saveWatchProgress: save
        )
    }

    @Test("a film with credentials and no store of the app's saves to the EYZFlow watch history")
    func defaultStore() throws {
        #expect(options().saveWatchProgress)
        let store = try #require(options().resolvedWatchProgressStore() as? EYZFlowWatchHistoryStore)
        #expect(store.storefrontID == "sf")
        #expect(store.authorization == "Bearer viewer")
        #expect(store.offerID == "offer-1")
    }

    @Test("the app's store wins; saveWatchProgress false saves nothing; no credentials, no store")
    func choices() {
        #expect(options(store: AppStore()).resolvedWatchProgressStore() is AppStore)
        #expect(options(save: false).resolvedWatchProgressStore() == nil)
        #expect(options(store: AppStore(), save: false).resolvedWatchProgressStore() == nil)
        #expect(options(authorization: nil).resolvedWatchProgressStore() == nil)
    }
}
