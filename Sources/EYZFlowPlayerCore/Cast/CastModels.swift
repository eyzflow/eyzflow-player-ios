import Foundation

/// The EYZFlow Cast receiver: plays the DASH manifest with Widevine and adds
/// the DRM `access-token` to licence requests.
public let eyzflowCastReceiverAppID = "A534F914"

/// A Cast device on the network, as the picker lists it.
public struct CastTarget: Sendable, Hashable, Identifiable {
    /// The Bonjour service name: stable for one device.
    public var id: String
    /// What the viewer named the TV, else the service name.
    public var name: String
    public var model: String?
    public var host: String
    public var port: Int

    public init(id: String, name: String, model: String? = nil, host: String, port: Int = 8009) {
        self.id = id
        self.name = name
        self.model = model
        self.host = host
        self.port = port
    }

    public static func == (lhs: CastTarget, rhs: CastTarget) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// What the TV is doing.
public enum CastPlayerState: String, Sendable {
    case idle = "IDLE"
    case buffering = "BUFFERING"
    case playing = "PLAYING"
    case paused = "PAUSED"
}

/// The receiver's state, as its last status said.
public struct CastPlayback: Sendable, Equatable {
    public var state: CastPlayerState
    public var position: Duration { didSet { hasReportedPosition = true } }
    /// False for partial status reports that omitted currentTime.
    public private(set) var hasReportedPosition: Bool
    public var tracks: [CastTrack] = []
    /// Nil until the receiver confirms the selection. An empty list is meaningful.
    public var activeTrackIDs: [Int]? {
        didSet { hasReportedActiveTrackIDs = activeTrackIDs != nil }
    }
    private(set) var hasReportedActiveTrackIDs = false
    public var duration: Duration?
    /// Why the receiver is idle: `FINISHED`, `CANCELLED`, `INTERRUPTED`,
    /// `ERROR`, or nil.
    public var idleReason: String?

    public init(
        state: CastPlayerState = .idle,
        position: Duration? = nil,
        duration: Duration? = nil,
        idleReason: String? = nil
    ) {
        self.state = state
        self.position = position ?? .zero
        hasReportedPosition = position != nil
        self.duration = duration
        self.idleReason = idleReason
    }

    mutating func estimatePosition(_ estimate: Duration) {
        position = estimate
        hasReportedPosition = false
    }

    public var isFinished: Bool { state == .idle && idleReason == "FINISHED" }
    public var isError: Bool { state == .idle && idleReason == "ERROR" }

    /// The next playback from a `MEDIA_STATUS` entry. Receivers leave out
    /// `currentTime` from some updates: absent means unchanged, not zero.
    public func updated(with status: [String: JSONValue]) -> CastPlayback {
        var next = self
        if let state = status["playerState"]?.stringValue.flatMap(CastPlayerState.init(rawValue:)) {
            next.state = state
        }
        next.hasReportedPosition = status["currentTime"]?.numberValue != nil
        if let seconds = status["currentTime"]?.numberValue {
            next.position = .milliseconds(Int64((seconds * 1000).rounded()))
        }
        if let seconds = status["media"]?["duration"]?.numberValue, seconds > 0 {
            next.duration = .milliseconds(Int64((seconds * 1000).rounded()))
        }
        if let tracks = status["media"]?["tracks"]?.arrayValue {
            next.tracks = tracks.compactMap(CastTrack.init)
        }
        next.hasReportedActiveTrackIDs = false
        if let ids = status["activeTrackIds"]?.arrayValue {
            next.activeTrackIDs = ids.compactMap { $0.numberValue.flatMap(Int.init(exactly:)) }
        }
        next.idleReason = status["idleReason"]?.stringValue
        return next
    }
}

/// What to play on the TV.
public struct CastMedia: Sendable, Equatable {
    public var streamID: String
    public var contentURL: String
    public var contentType: String
    public var title: String
    public var posterURL: String?
    public var trackSelection = CastTrackSelection()
    public var startAt: Duration
    /// For the EYZFlow receiver: `manifestUrl`, `licenseUrl`, `accessToken`.
    public var customData: [String: JSONValue]

    public init(
        streamID: String,
        contentURL: String,
        contentType: String,
        title: String,
        posterURL: String? = nil,
        startAt: Duration = .zero,
        customData: [String: JSONValue] = [:]
    ) {
        self.streamID = streamID
        self.contentURL = contentURL
        self.contentType = contentType
        self.title = title
        self.posterURL = posterURL
        self.startAt = startAt
        self.customData = customData
    }

    /// The TV plays the DASH manifest: the EYZFlow receiver plays it with
    /// Widevine the way the web player does. It addresses the same segments
    /// as the HLS the phone plays.
    ///
    /// `accessHeader` is the DRM `access-token` the phone plays with (nil for
    /// a clear stream). It carries the phone's device and playback session,
    /// so the film on the TV counts as the phone's one stream.
    public static func `for`(_ source: EYZFlowSource, startAt: Duration, accessHeader: String?) -> CastMedia {
        let manifest = source.dashStreamURL.absoluteString
        var customData: [String: JSONValue] = ["manifestUrl": .string(manifest)]
        if let accessHeader {
            customData["licenseUrl"] = .string(source.widevineLicenseURL.absoluteString)
            customData["accessToken"] = .string(accessHeader)
        }
        return CastMedia(
            streamID: source.id,
            contentURL: manifest,
            contentType: "application/dash+xml",
            title: source.title,
            posterURL: source.poster?.absoluteString,
            startAt: startAt,
            customData: customData
        )
    }

    /// The `media` object of a `LOAD` request.
    public var mediaJSON: JSONValue {
        var media: [String: JSONValue] = [
            "contentId": .string(contentURL),
            "contentType": .string(contentType),
            "streamType": "BUFFERED",
        ]
        if !customData.isEmpty { media["customData"] = .object(customData) }
        var metadata: [String: JSONValue] = ["metadataType": 0, "title": .string(title)]
        if let posterURL { metadata["images"] = [["url": .string(posterURL)]] }
        media["metadata"] = .object(metadata)
        return .object(media)
    }
}
