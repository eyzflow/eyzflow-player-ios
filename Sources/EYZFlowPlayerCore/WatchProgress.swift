import Foundation

/// Where a film's watch progress goes: the EYZFlow watch history
/// ([`EYZFlowWatchHistoryStore`], the default) or the app's own store. The
/// Flutter package's and the web player's `WatchProgressStore`.
public protocol WatchProgressStore: Sendable {
    func save(catalogueID: String, progressSeconds: Double, completed: Bool) async throws
}

/// Saves to the EYZFlow watch history:
/// `PUT /v1/content/storefront/{storefrontID}/watch-history` with the
/// viewer's `Authorization`. The player uses it by itself for a film when
/// `drmAuthorization` and `storefrontID` are set and the app passes no store
/// of its own.
public struct EYZFlowWatchHistoryStore: WatchProgressStore {
    public let storefrontID: String
    /// The viewer's `Authorization` value, e.g. `Bearer <token>`.
    public let authorization: String
    /// The offer played; sent as `offer_id` when set.
    public let offerID: String?
    public let http: any HTTPClient
    public let endpoints: EYZFlowEndpoints

    public init(
        storefrontID: String,
        authorization: String,
        offerID: String? = nil,
        http: any HTTPClient = URLSessionHTTPClient(),
        endpoints: EYZFlowEndpoints = EYZFlowEndpoints()
    ) {
        self.storefrontID = storefrontID
        self.authorization = authorization
        self.offerID = offerID
        self.http = http
        self.endpoints = endpoints
    }

    /// Sends `progressSeconds` as whole seconds. Throws when the request
    /// fails or the API refuses it.
    public func save(catalogueID: String, progressSeconds: Double, completed: Bool) async throws {
        let url = try endpoints.apiURL(
            "/v1/content/storefront/\(storefrontID.encodedURIComponent)/watch-history"
        )
        let seconds = progressSeconds.isFinite ? max(0, Int(progressSeconds.rounded(.down))) : 0
        var body: [String: JSONValue] = [
            "catalogue_id": .string(catalogueID),
            "progress_seconds": .int(seconds),
            "completed": .bool(completed),
        ]
        if let offerID, !offerID.isEmpty { body["offer_id"] = .string(offerID) }
        let (_, response) = try await http.send(
            .json(
                "PUT",
                url,
                headers: ["Content-Type": "application/json", "Authorization": authorization],
                body: .object(body)
            )
        )
        guard response.isSuccess else {
            // No URL or body: they name the viewer's storefront.
            throw EYZFlowRequestError.http(message: "Watch progress was not saved (\(response.statusCode)).", url: nil)
        }
    }
}

/// The store a playback saves its watch progress to, or nil for none:
/// - nothing when `saveWatchProgress` is false, or for a trailer, no source
///   type or an empty catalogue id;
/// - the app's `appStore` when it passed one;
/// - otherwise [`EYZFlowWatchHistoryStore`] when `authorization` and
///   `storefrontID` are set and not empty, else nothing: without the
///   viewer's credentials the API is never called.
public func resolveWatchProgressStore(
    sourceType: EYZFlowSourceType?,
    saveWatchProgress: Bool = true,
    appStore: (any WatchProgressStore)?,
    authorization: String?,
    storefrontID: String?,
    offerID: String?,
    endpoints: EYZFlowEndpoints = EYZFlowEndpoints(),
    http: any HTTPClient = URLSessionHTTPClient()
) -> (any WatchProgressStore)? {
    guard saveWatchProgress, case .film(let catalogueID) = sourceType, !catalogueID.isEmpty else { return nil }
    if let appStore { return appStore }
    guard let authorization, !authorization.isEmpty, let storefrontID, !storefrontID.isEmpty else { return nil }
    return EYZFlowWatchHistoryStore(
        storefrontID: storefrontID,
        authorization: authorization,
        offerID: offerID,
        http: http,
        endpoints: endpoints
    )
}

/// The player config's `watchProgress.completedPercent` as the player uses
/// it: clamped to 50–100, or 95 when it is missing or not a number.
public func watchProgressCompletedPercent(_ percent: Double?) -> Double {
    guard let percent, percent.isFinite else { return WatchProgressRecorder.defaultCompletedPercent }
    return min(100, max(50, percent))
}

/// Records a film's position to a [`WatchProgressStore`]: at most once per
/// `interval` of playback while playing, at once on a pause, a seek or when
/// the app leaves, and as completed at the end. From `completedPercent` of
/// the film on (95 % unless the player config says otherwise) a save counts
/// as completed. Trailers record nothing.
///
/// Positions from before the start position (the resume point) are ignored
/// until playback gets there or the viewer seeks: they come from the moment
/// before the player got there, and saving them would overwrite the viewer's
/// place with 0. A film's first save is never 0 s, not completed.
///
/// Saves run one after another, so a completion never lands before an earlier
/// progress write. A failed save is logged and never reaches playback.
@MainActor
public final class WatchProgressRecorder {
    /// From this share of the film on (in percent), it counts as watched,
    /// unless the player config says otherwise.
    public nonisolated static let defaultCompletedPercent: Double = 95
    /// How close to the start position playback must be before anything is
    /// saved, in seconds.
    static let startTolerance: Double = 2

    public let catalogueID: String?
    private let store: any WatchProgressStore
    private let interval: Double
    private let log: @MainActor (String) -> Void

    /// From this share of the film on (50–100, in percent), a save counts as
    /// completed; 100 means only the end itself. Set it from the player
    /// config's `watchProgress.completedPercent`; values outside 50–100 are
    /// clamped, and a non-number means 95.
    public var completedPercent: Double = WatchProgressRecorder.defaultCompletedPercent {
        didSet { completedPercent = watchProgressCompletedPercent(completedPercent) }
    }

    private var startSeconds: Double = 0
    private var armed = true
    private var lastSaved: Double?
    private var lastEntry: (seconds: Int, completed: Bool)?
    private var finished = false
    private var latest: Double = 0
    private var duration: Double = 0
    private var chain: Task<Void, Never>?

    /// `sourceType` nil or a trailer records nothing. `startPosition` is where
    /// playback starts (the resume point); nil starts at the beginning.
    public init(
        store: any WatchProgressStore,
        sourceType: EYZFlowSourceType?,
        startPosition: Duration? = nil,
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
        reload(from: startPosition)
    }

    /// Whether this source records at all.
    public var isRecording: Bool { catalogueID != nil }

    /// The stream loads again from `position` (a resume point, or where a TV
    /// stopped): positions before it are ignored until playback gets there
    /// or the viewer seeks. Nil or 0 starts at the beginning.
    public func reload(from position: Duration?) {
        let seconds = position?.inSecondsDouble ?? 0
        startSeconds = seconds.isFinite ? max(0, seconds) : 0
        armed = startSeconds <= Self.startTolerance
    }

    /// The position while playing; saved when `interval` has passed since the
    /// last save. `duration`, when known, decides when the film counts as
    /// completed.
    public func report(_ position: Duration, duration: Duration? = nil) {
        guard track(position, duration: duration) else { return }
        if let lastSaved, abs(latest - lastSaved) < interval { return }
        save()
    }

    /// Saves the position now: on a pause or leaving the app.
    public func checkpoint(_ position: Duration, duration: Duration? = nil) {
        guard track(position, duration: duration) else { return }
        save()
    }

    /// The viewer moved to `position` themselves: from now on positions are
    /// theirs, wherever the start was. Saved at once.
    public func seeked(to position: Duration, duration: Duration? = nil) {
        guard isRecording, !finished else { return }
        armed = true
        checkpoint(position, duration: duration)
    }

    /// The film reached its end: saved as completed, once, at its duration
    /// when known. Later reports are ignored, so a late tick cannot reopen it.
    public func finish() {
        complete(at: duration > 0 ? duration : latest)
    }

    /// A receiver can report the final position after the last watch-progress tick.
    public func finish(at position: Duration) {
        complete(at: position.inSecondsDouble)
    }

    private func complete(at seconds: Double) {
        guard isRecording, !finished else { return }
        finished = true
        latest = seconds
        enqueue(seconds: seconds, completed: true)
    }

    /// Waits for every save started so far.
    public func flush() async {
        await chain?.value
    }

    /// Takes `position` as the latest one; false when it is not to be saved.
    private func track(_ position: Duration, duration: Duration?) -> Bool {
        guard isRecording, !finished else { return false }
        if let duration, duration > .zero { self.duration = duration.inSecondsDouble }
        let seconds = position.inSecondsDouble
        guard seconds.isFinite else { return false }
        if !armed {
            if seconds < startSeconds - Self.startTolerance { return false }
            armed = true
        }
        latest = seconds
        return true
    }

    private func save() {
        let ratio = completedPercent / 100
        let completed = duration > 0 && (ratio >= 1 ? latest >= duration - 0.5 : latest >= duration * ratio)
        enqueue(seconds: latest, completed: completed)
    }

    private func enqueue(seconds: Double, completed: Bool) {
        guard let catalogueID else { return }
        let whole = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        // Opening a film and leaving at once doesn't put it in "Continue watching".
        if lastEntry == nil, whole == 0, !completed { return }
        lastSaved = seconds
        if let lastEntry, lastEntry.seconds == whole, lastEntry.completed == completed { return }
        lastEntry = (whole, completed)
        let store = self.store
        let previous = chain
        let log = self.log
        let progress = Double(whole)
        chain = Task { @MainActor in
            await previous?.value
            log("[eyzflow-player] watch_progress.put attempted completed=\(completed)")
            do {
                try await store.save(catalogueID: catalogueID, progressSeconds: progress, completed: completed)
                log("[eyzflow-player] watch_progress.put succeeded")
            } catch {
                // No payload or error text: it may carry tokens.
                log("[eyzflow-player] watch_progress.put failed")
            }
        }
    }
}
