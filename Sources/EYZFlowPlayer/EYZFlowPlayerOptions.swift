import EYZFlowPlayerCore
import Foundation

/// What to play and how: the stream, the viewer's credentials and the hooks
/// the app wants. The Flutter package's `EyzflowPlayer` parameters.
public struct EYZFlowPlayerOptions: Sendable {
    /// The EYZFlow stream id (not the catalogue id).
    public var streamID: String
    public var title: String
    public var description: String?
    /// Shown while casting and on the TV.
    public var poster: URL?
    /// A film plays with FairPlay; a trailer, or nil, plays clear. Either
    /// opens a playback session with `storefrontID` and `drmAuthorization`.
    public var sourceType: EYZFlowSourceType?
    /// Where to start, in seconds; nil starts at the beginning.
    public var progressSeconds: Double?

    /// `pk_…` from the dashboard's Player → Keys. Without it there is no key
    /// check and no analytics. The app's bundle id must be on the key's
    /// allowed apps.
    public var playerKey: String?
    /// A player config from the dashboard (Player → Configs), `cfg_…`. Its
    /// ads (`features.ads` and `ads.adTagUrl`) play on iPhone, iPad and Apple TV.
    public var configID: String?
    /// Wins over the dashboard config, field by field, as the web player's
    /// inline `config`; e.g. `PlayerConfigOverride(features: .init(ads: true),
    /// ads: PlayerAdsConfig(adTagURL: tag))`.
    public var config: PlayerConfigOverride?
    /// The viewer's `Authorization` for DRM and the playback session, e.g.
    /// `Bearer <token>`.
    public var drmAuthorization: String?
    /// Opens a playback session (with `drmAuthorization`, for clear streams
    /// too) for the stream and device limits and the plan's ads answer.
    public var storefrontID: String?
    /// Extra DRM access-token parameters.
    public var drmParameters: [String: JSONValue]
    /// Shown in the viewer's device list.
    public var deviceName: String?
    /// The EYZFlow API and CDN origins; production by default.
    public var endpoints: EYZFlowEndpoints
    /// False turns beats off even when the key has analytics on.
    public var analytics: Bool
    /// Where a film's watch progress goes.
    public var watchProgressStore: (any WatchProgressStore)?
    /// Start playing as soon as the stream is ready.
    public var autoplay: Bool
    /// The Cast receiver films play on: the EYZFlow receiver by default. Nil
    /// turns Chromecast off. iPhone and iPad only.
    public var castReceiverAppID: String?

    /// Every playback event, in order.
    public var onEvent: (@MainActor @Sendable (PlaybackEvent) -> Void)?
    /// A stream or device limit refused or ended playback.
    public var onLimitReached: (@MainActor @Sendable (PlaybackLimitError) -> Void)?
    /// The player key check refused the app.
    public var onLicenseError: (@MainActor @Sendable (PlayerLicenseError) -> Void)?
    /// The viewer-facing text of every failure.
    public var onError: (@MainActor @Sendable (String) -> Void)?
    /// The player was closed, by the viewer or after a failure.
    public var onClose: (@MainActor @Sendable () -> Void)?

    public init(
        streamID: String,
        title: String,
        description: String? = nil,
        poster: URL? = nil,
        sourceType: EYZFlowSourceType? = nil,
        progressSeconds: Double? = nil,
        playerKey: String? = nil,
        configID: String? = nil,
        config: PlayerConfigOverride? = nil,
        drmAuthorization: String? = nil,
        storefrontID: String? = nil,
        drmParameters: [String: JSONValue] = [:],
        deviceName: String? = nil,
        endpoints: EYZFlowEndpoints = EYZFlowEndpoints(),
        analytics: Bool = true,
        watchProgressStore: (any WatchProgressStore)? = nil,
        autoplay: Bool = true,
        castReceiverAppID: String? = eyzflowCastReceiverAppID,
        onEvent: (@MainActor @Sendable (PlaybackEvent) -> Void)? = nil,
        onLimitReached: (@MainActor @Sendable (PlaybackLimitError) -> Void)? = nil,
        onLicenseError: (@MainActor @Sendable (PlayerLicenseError) -> Void)? = nil,
        onError: (@MainActor @Sendable (String) -> Void)? = nil,
        onClose: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.streamID = streamID
        self.title = title
        self.description = description
        self.poster = poster
        self.sourceType = sourceType
        self.progressSeconds = progressSeconds
        self.playerKey = playerKey
        self.configID = configID
        self.config = config
        self.drmAuthorization = drmAuthorization
        self.storefrontID = storefrontID
        self.drmParameters = drmParameters
        self.deviceName = deviceName
        self.endpoints = endpoints
        self.analytics = analytics
        self.watchProgressStore = watchProgressStore
        self.autoplay = autoplay
        self.castReceiverAppID = castReceiverAppID
        self.onEvent = onEvent
        self.onLimitReached = onLimitReached
        self.onLicenseError = onLicenseError
        self.onError = onError
        self.onClose = onClose
    }

    /// The source the player plays, before the access header is known.
    public var source: EYZFlowSource {
        EYZFlowSource(
            id: streamID,
            title: title,
            description: description,
            poster: poster,
            sourceType: sourceType,
            progressSeconds: progressSeconds
        )
    }

    /// Whether this plays with DRM.
    public var isProtected: Bool { sourceType?.isProtected ?? false }
}
