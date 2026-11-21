import Foundation

// A player heartbeat ("beat") as `POST /v1/player/beat` takes it: the
// impression's counters so far and the errors since the last beat. Same
// schema as the web player (`analytics/types.ts`) and the backend's
// `parseBeat`, plus `platform` for app players.

/// The impression's counters so far. Cumulative, so a lost or repeated beat
/// changes nothing.
public struct BeatMetrics: Sendable, Hashable {
    /// From the player starting to load to the video being ready.
    public var playerStartupMs: Int?
    /// From loading (the apps always autoplay) to the first frame. Nil until
    /// a frame showed.
    public var videoStartupMs: Int?
    public var playedMs: Int
    public var pausedMs: Int
    public var rebufferMs: Int
    public var rebufferCount: Int
    public var seekCount: Int
    /// Bitrates and dropped frames: nil and 0 in v1, because the native
    /// players do not report them yet.
    public var avgBitrate: Int?
    public var minBitrate: Int?
    public var maxBitrate: Int?
    public var qualitySwitches: Int
    public var droppedFrames: Int
    public var maxPositionS: Double
    public var durationS: Double?

    public init(
        playerStartupMs: Int? = nil,
        videoStartupMs: Int? = nil,
        playedMs: Int = 0,
        pausedMs: Int = 0,
        rebufferMs: Int = 0,
        rebufferCount: Int = 0,
        seekCount: Int = 0,
        avgBitrate: Int? = nil,
        minBitrate: Int? = nil,
        maxBitrate: Int? = nil,
        qualitySwitches: Int = 0,
        droppedFrames: Int = 0,
        maxPositionS: Double = 0,
        durationS: Double? = nil
    ) {
        self.playerStartupMs = playerStartupMs
        self.videoStartupMs = videoStartupMs
        self.playedMs = playedMs
        self.pausedMs = pausedMs
        self.rebufferMs = rebufferMs
        self.rebufferCount = rebufferCount
        self.seekCount = seekCount
        self.avgBitrate = avgBitrate
        self.minBitrate = minBitrate
        self.maxBitrate = maxBitrate
        self.qualitySwitches = qualitySwitches
        self.droppedFrames = droppedFrames
        self.maxPositionS = maxPositionS
        self.durationS = durationS
    }

    /// Every field, nulls included.
    public var json: JSONValue {
        [
            "player_startup_ms": .optional(playerStartupMs),
            "video_startup_ms": .optional(videoStartupMs),
            "played_ms": .int(playedMs),
            "paused_ms": .int(pausedMs),
            "rebuffer_ms": .int(rebufferMs),
            "rebuffer_count": .int(rebufferCount),
            "seek_count": .int(seekCount),
            "avg_bitrate": .optional(avgBitrate),
            "min_bitrate": .optional(minBitrate),
            "max_bitrate": .optional(maxBitrate),
            "quality_switches": .int(qualitySwitches),
            "dropped_frames": .int(droppedFrames),
            "max_position_s": .double(maxPositionS),
            "duration_s": .optional(durationS),
        ]
    }
}

/// An error the viewer met. `n` numbers it within the impression (0–19).
public struct BeatError: Sendable, Hashable {
    public var n: Int
    /// At most 64 characters.
    public var code: String
    /// At most 32 characters.
    public var category: String?
    /// At most 300 characters. The backend scrubs URLs and tokens from it too.
    public var message: String?
    public var positionS: Double?

    public init(n: Int, code: String, category: String? = nil, message: String? = nil, positionS: Double? = nil) {
        self.n = n
        self.code = code
        self.category = category
        self.message = message
        self.positionS = positionS
    }

    public var json: JSONValue {
        [
            "n": .int(n),
            "code": .string(code),
            "category": .optional(category),
            "message": .optional(message),
            "position_s": .optional(positionS),
        ]
    }
}

public struct Beat: Sendable, Hashable, Encodable {
    /// The player token from the licence check.
    public var token: String
    /// The impression id: a UUID per video loaded.
    public var sid: String
    /// Grows with every beat; the server keeps the newest.
    public var seq: Int
    /// Wall-clock milliseconds when the impression started.
    public var startedAt: Int
    public var isFinal: Bool
    public var streamID: String
    public var isLive: Bool
    public var autoplay: Bool
    /// `widevine`, `fairplay`, `playready`, `none`, or nil when unknown.
    public var drm: String?
    public var playerVersion: String
    /// `ios`, `tvos`, `android`, …
    public var platform: String?
    public var metrics: BeatMetrics
    public var errors: [BeatError]

    public init(
        token: String,
        sid: String,
        seq: Int,
        startedAt: Int,
        isFinal: Bool,
        streamID: String,
        isLive: Bool,
        autoplay: Bool,
        drm: String?,
        playerVersion: String,
        platform: String?,
        metrics: BeatMetrics,
        errors: [BeatError]
    ) {
        self.token = token
        self.sid = sid
        self.seq = seq
        self.startedAt = startedAt
        self.isFinal = isFinal
        self.streamID = streamID
        self.isLive = isLive
        self.autoplay = autoplay
        self.drm = drm
        self.playerVersion = playerVersion
        self.platform = platform
        self.metrics = metrics
        self.errors = errors
    }

    /// The request body, nulls included.
    public var json: JSONValue {
        [
            "token": .string(token),
            "sid": .string(sid),
            "seq": .int(seq),
            "started_at": .int(startedAt),
            "final": .bool(isFinal),
            "stream_id": .string(streamID),
            "is_live": .bool(isLive),
            "autoplay": .bool(autoplay),
            "drm": .optional(drm),
            "player_version": .string(playerVersion),
            "platform": .optional(platform),
            "m": metrics.json,
            "errors": .array(errors.map(\.json)),
        ]
    }

    public func encode(to encoder: any Encoder) throws {
        try json.encode(to: encoder)
    }
}
