import Foundation

/// Something playback did, for the host to map onto whatever analytics tool
/// it uses, and for [`PlaybackCoordinator.handle(event:)`].
///
/// One player instance reports one sequence: `ready`, then `started` once,
/// then whatever the viewer and the network do, and `closed` last. A player
/// that fails before it initializes reports only `error` and `closed`. A
/// retry after a failure, or a change of source, is a new player and so a new
/// sequence.
///
/// Every case carries `sourceId` (the stream id), `position` (the playback
/// position when it happened, zero until the player has reported one) and
/// `duration` (nil until the player has resolved it).
public enum PlaybackEvent: Sendable, Hashable, CustomStringConvertible {
    /// The player initialized, before the first frame.
    case ready(sourceId: String, position: Duration, duration: Duration? = nil)
    /// Reported once: the first time the player reports it is playing.
    case started(sourceId: String, position: Duration, duration: Duration? = nil)
    /// Paused by the viewer or the system. A stall is `bufferingStarted`.
    case paused(sourceId: String, position: Duration, duration: Duration? = nil)
    /// Playback continued after `paused`.
    case resumed(sourceId: String, position: Duration, duration: Duration? = nil)
    /// The position was moved; `position` is where it landed.
    case seeked(sourceId: String, from: Duration, position: Duration, duration: Duration? = nil)
    /// Playback stalled to fill its buffer. Only after `started`.
    case bufferingStarted(sourceId: String, position: Duration, duration: Duration? = nil)
    /// The stall is over.
    case bufferingEnded(sourceId: String, position: Duration, duration: Duration? = nil)
    /// Playback failed. `message` is the text the viewer is shown.
    case error(sourceId: String, message: String, position: Duration, duration: Duration? = nil)
    /// The viewer switched audio track; `language` as the stream tags it.
    case audioTrackChanged(sourceId: String, language: String?, position: Duration, duration: Duration? = nil)
    /// The viewer switched subtitle track; nil `language` is subtitles off.
    case subtitleTrackChanged(sourceId: String, language: String?, position: Duration, duration: Duration? = nil)
    /// An ad break began: the content stopped (or has not started yet) while
    /// an ad from the player config's ad tag is requested and played.
    /// Everything the content reports until `adBreakEnded` (its pause, its
    /// resume) is the ad break's doing, not the viewer's.
    case adBreakStarted(sourceId: String, position: Duration, duration: Duration? = nil)
    /// The ad break is over: played, empty, failed or timed out. The content
    /// plays on.
    case adBreakEnded(sourceId: String, position: Duration, duration: Duration? = nil)
    /// Playback reached the end. Reported once; only `closed` follows.
    case completed(sourceId: String, position: Duration, duration: Duration? = nil)
    /// The player was disposed. Reported once and always last.
    case closed(sourceId: String, position: Duration, duration: Duration? = nil)

    public var sourceId: String {
        switch self {
        case .ready(let id, _, _), .started(let id, _, _), .paused(let id, _, _),
             .resumed(let id, _, _), .seeked(let id, _, _, _), .bufferingStarted(let id, _, _),
             .bufferingEnded(let id, _, _), .error(let id, _, _, _),
             .audioTrackChanged(let id, _, _, _), .subtitleTrackChanged(let id, _, _, _),
             .adBreakStarted(let id, _, _), .adBreakEnded(let id, _, _),
             .completed(let id, _, _), .closed(let id, _, _):
            id
        }
    }

    public var position: Duration {
        switch self {
        case .ready(_, let p, _), .started(_, let p, _), .paused(_, let p, _),
             .resumed(_, let p, _), .seeked(_, _, let p, _), .bufferingStarted(_, let p, _),
             .bufferingEnded(_, let p, _), .error(_, _, let p, _),
             .audioTrackChanged(_, _, let p, _), .subtitleTrackChanged(_, _, let p, _),
             .adBreakStarted(_, let p, _), .adBreakEnded(_, let p, _),
             .completed(_, let p, _), .closed(_, let p, _):
            p
        }
    }

    public var duration: Duration? {
        switch self {
        case .ready(_, _, let d), .started(_, _, let d), .paused(_, _, let d),
             .resumed(_, _, let d), .seeked(_, _, _, let d), .bufferingStarted(_, _, let d),
             .bufferingEnded(_, _, let d), .error(_, _, _, let d),
             .audioTrackChanged(_, _, _, let d), .subtitleTrackChanged(_, _, _, let d),
             .adBreakStarted(_, _, let d), .adBreakEnded(_, _, let d),
             .completed(_, _, let d), .closed(_, _, let d):
            d
        }
    }

    /// The Dart class name, for logs.
    public var name: String {
        switch self {
        case .ready: "PlaybackReady"
        case .started: "PlaybackStarted"
        case .paused: "PlaybackPaused"
        case .resumed: "PlaybackResumed"
        case .seeked: "PlaybackSeeked"
        case .bufferingStarted: "PlaybackBufferingStarted"
        case .bufferingEnded: "PlaybackBufferingEnded"
        case .error: "PlaybackError"
        case .audioTrackChanged: "PlaybackAudioTrackChanged"
        case .subtitleTrackChanged: "PlaybackSubtitleTrackChanged"
        case .adBreakStarted: "PlaybackAdBreakStarted"
        case .adBreakEnded: "PlaybackAdBreakEnded"
        case .completed: "PlaybackCompleted"
        case .closed: "PlaybackClosed"
        }
    }

    /// `PlaybackSeeked(sourceId: s, position: 0:01:40, duration: 1:30:00, from: 0:00:10)`,
    /// as the Dart player logs events.
    public var description: String {
        var fields = ["sourceId: \(sourceId)", "position: \(position.clockString)"]
        if let duration { fields.append("duration: \(duration.clockString)") }
        switch self {
        case .seeked(_, let from, _, _): fields.append("from: \(from.clockString)")
        case .error(_, let message, _, _): fields.append("message: \(message)")
        case .audioTrackChanged(_, let language, _, _), .subtitleTrackChanged(_, let language, _, _):
            fields.append("language: \(language ?? "null")")
        default: break
        }
        return "\(name)(\(fields.joined(separator: ", ")))"
    }
}

/// Feeds the player's [`PlaybackEvent`]s into a [`BeatCollector`].
///
/// The players report state changes only, with the position at each; the
/// collector estimates the position in between.
@MainActor
public final class PlaybackEventAdapter {
    public let collector: BeatCollector
    private var playing = false

    public init(_ collector: BeatCollector) {
        self.collector = collector
    }

    public func add(_ event: PlaybackEvent) {
        let position = event.position
        let duration = event.duration
        switch event {
        case .ready:
            collector.ready(position: position, duration: duration)
        case .started, .resumed:
            playing = true
            collector.playing(position: position, duration: duration)
        case .paused:
            playing = false
            collector.paused(position: position, duration: duration)
        case .bufferingStarted:
            collector.bufferingStarted(position: position, duration: duration)
        case .bufferingEnded:
            collector.bufferingEnded(position: position, duration: duration, isPlaying: playing)
        case .seeked:
            collector.seeked(to: position, duration: duration)
        case .error(_, let message, _, _):
            collector.error(code: "PLAYBACK_FAILED", message: message, position: position)
        case .adBreakStarted:
            collector.beginAd()
        case .adBreakEnded:
            collector.endAd()
        case .completed:
            playing = false
            collector.completed(position: position, duration: duration)
        case .closed, .audioTrackChanged, .subtitleTrackChanged:
            collector.position(position, duration: duration)
        }
    }
}
