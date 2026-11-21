import Foundation

/// Where a film's watch progress goes: the app's watch history, for example
/// its call to the EYZFlow watch-history API. The Flutter package's
/// `WatchProgressStore`.
public protocol WatchProgressStore: Sendable {
    func save(catalogueID: String, progressSeconds: Double, completed: Bool) async throws
}

/// Records a film's position to a [`WatchProgressStore`]: at most once per
/// `interval` of playback while playing, at once on a pause or when the app
/// leaves, and as completed at the end. Trailers record nothing.
///
/// Saves run one after another, so a completion never lands before an earlier
/// progress write. A failed save is logged and never reaches playback.
@MainActor
public final class WatchProgressRecorder {
    public let catalogueID: String?
    private let store: any WatchProgressStore
    private let interval: Double
    private let log: @MainActor (String) -> Void

    private var lastSaved: Double?
    private var finished = false
    private var latest: Double = 0
    private var chain: Task<Void, Never>?

    /// `sourceType` nil or a trailer records nothing.
    public init(
        store: any WatchProgressStore,
        sourceType: EYZFlowSourceType?,
        interval: Duration = .seconds(10),
        log: @escaping @MainActor (String) -> Void = { message in
            #if DEBUG
                print(message)
            #endif
        }
    ) {
        if case .film(let id) = sourceType {
            catalogueID = id
        } else {
            catalogueID = nil
        }
        self.store = store
        self.interval = interval.inSecondsDouble
        self.log = log
    }

    /// Whether this source records at all.
    public var isRecording: Bool { catalogueID != nil }

    /// The position while playing; saved when `interval` has passed since the
    /// last save.
    public func report(_ position: Duration) {
        guard isRecording, !finished else { return }
        let seconds = position.inSecondsDouble
        latest = seconds
        if let lastSaved, abs(seconds - lastSaved) < interval { return }
        save(seconds, completed: false)
    }

    /// Saves the position now: on a pause, a seek or leaving the app.
    public func checkpoint(_ position: Duration) {
        guard isRecording, !finished else { return }
        latest = position.inSecondsDouble
        save(latest, completed: false)
    }

    /// The film reached its end: saved as completed, once. Later reports are
    /// ignored, so a late tick cannot reopen it.
    public func finish() {
        guard isRecording, !finished else { return }
        finished = true
        save(latest, completed: true)
    }

    /// Waits for every save started so far.
    public func flush() async {
        await chain?.value
    }

    private func save(_ seconds: Double, completed: Bool) {
        guard let catalogueID else { return }
        lastSaved = seconds
        let store = self.store
        let previous = chain
        let log = self.log
        chain = Task { @MainActor in
            await previous?.value
            log("[eyzflow-player] watch_progress.put attempted completed=\(completed)")
            do {
                try await store.save(catalogueID: catalogueID, progressSeconds: seconds, completed: completed)
                log("[eyzflow-player] watch_progress.put succeeded")
            } catch {
                // No payload or error text: it may carry tokens.
                log("[eyzflow-player] watch_progress.put failed")
            }
        }
    }
}
