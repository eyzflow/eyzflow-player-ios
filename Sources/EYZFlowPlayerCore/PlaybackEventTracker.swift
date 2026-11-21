import Foundation

/// Turns what a player reports into [`PlaybackEvent`]s in the documented
/// order: `ready`, `started` once, then pauses, resumes, stalls, seeks, track
/// changes and errors, `completed` at most once, and `closed` last.
///
/// The player side only reports its state; this decides which event that
/// state change is. Kept free of AVFoundation so the rules are tested on
/// their own.
@MainActor
public final class PlaybackEventTracker {
    public let sourceID: String
    /// Receives every event, in order.
    public var onEvent: (@MainActor (PlaybackEvent) -> Void)?

    private var readyReported = false
    private var started = false
    private var playing = false
    private var buffering = false
    private var completed = false
    private var closed = false
    private var lastErrorMessage: String?
    private var lastPosition: Duration = .zero
    private var lastDuration: Duration?

    public init(sourceID: String) {
        self.sourceID = sourceID
    }

    /// The player's state now. Call it whenever any of it may have changed.
    public func update(
        isReady: Bool,
        isPlaying: Bool,
        isBuffering: Bool,
        position: Duration,
        duration: Duration?
    ) {
        remember(position, duration)
        guard !closed, !completed else { return }
        if isReady, !readyReported {
            readyReported = true
            emit(.ready(sourceId: sourceID, position: position, duration: duration))
        }
        guard readyReported else { return }

        if isBuffering {
            // A stall is not a pause: `playing` keeps its value.
            if started, !buffering {
                buffering = true
                emit(.bufferingStarted(sourceId: sourceID, position: position, duration: duration))
            }
            return
        }
        if buffering {
            buffering = false
            emit(.bufferingEnded(sourceId: sourceID, position: position, duration: duration))
        }
        if isPlaying, !playing {
            playing = true
            if started {
                emit(.resumed(sourceId: sourceID, position: position, duration: duration))
            } else {
                started = true
                emit(.started(sourceId: sourceID, position: position, duration: duration))
            }
        } else if !isPlaying, playing {
            playing = false
            emit(.paused(sourceId: sourceID, position: position, duration: duration))
        }
    }

    /// The position jumped (a seek). Reported only once playback has started.
    public func seeked(from: Duration, to position: Duration, duration: Duration?) {
        remember(position, duration)
        guard started, !completed, !closed, from != position else { return }
        emit(.seeked(sourceId: sourceID, from: from, position: position, duration: duration))
    }

    /// Playback failed. The same message is reported once.
    public func failed(message: String) {
        guard !closed, message != lastErrorMessage else { return }
        lastErrorMessage = message
        emit(.error(sourceId: sourceID, message: message, position: lastPosition, duration: lastDuration))
    }

    /// Playback reached the end.
    public func reachedEnd(position: Duration, duration: Duration?) {
        remember(position, duration)
        guard !completed, !closed else { return }
        completed = true
        playing = false
        emit(.completed(sourceId: sourceID, position: position, duration: duration))
    }

    /// The viewer picked an audio track (`language` as the stream tags it).
    public func audioTrackChanged(language: String?) {
        guard started, !closed else { return }
        emit(.audioTrackChanged(sourceId: sourceID, language: language, position: lastPosition, duration: lastDuration))
    }

    /// The viewer picked subtitles; nil is subtitles off.
    public func subtitleTrackChanged(language: String?) {
        guard started, !closed else { return }
        emit(.subtitleTrackChanged(sourceId: sourceID, language: language, position: lastPosition, duration: lastDuration))
    }

    /// The player went away. Reported once, always last.
    public func close() {
        guard !closed else { return }
        closed = true
        emit(.closed(sourceId: sourceID, position: lastPosition, duration: lastDuration))
    }

    /// Where playback last was.
    public var position: Duration { lastPosition }
    public var duration: Duration? { lastDuration }
    public var hasStarted: Bool { started }
    public var isPlaying: Bool { playing }

    private func remember(_ position: Duration, _ duration: Duration?) {
        lastPosition = position
        if let duration { lastDuration = duration }
    }

    private func emit(_ event: PlaybackEvent) {
        onEvent?(event)
    }
}
