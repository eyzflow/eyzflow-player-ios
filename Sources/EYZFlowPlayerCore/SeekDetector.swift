import Foundation

/// A jump of the playhead: where playback was, and where it is now.
public struct Seek: Equatable, Sendable {
    public let from: Duration
    public let to: Duration

    public init(from: Duration, to: Duration) {
        self.from = from
        self.to = to
    }
}

/// Finds seeks in the positions a player reports, so each is reported once
/// with where it started.
///
/// AVPlayer gives no reliable "seek from" itself: its periodic time observer
/// also fires on a jump, before `timeJumpedNotification`, so by the time the
/// notification arrives the jump is already the last position seen. Both
/// report here instead; whichever comes first finds the jump, the other sees
/// the position it already knows.
///
/// A position is a seek when it is behind the last one, or ahead of it by
/// more than playback could have moved since (the time passed at the
/// playback rate), each by at least `tolerance`.
public struct SeekDetector: Sendable {
    /// The smallest jump reported.
    public var tolerance: Duration

    private var position: Duration?
    private var rate: Double = 0
    private var time: ContinuousClock.Instant?

    public init(tolerance: Duration = .seconds(1)) {
        self.tolerance = tolerance
    }

    /// The last position seen.
    public var lastPosition: Duration? { position }

    /// Starts over at `position` (a new stream, or a resume the viewer did
    /// not ask for): nothing before it counts as a seek.
    public mutating func reset(to position: Duration?) {
        self.position = position
        time = nil
        rate = 0
    }

    /// The player is at `position`, playing at `rate` (0 when paused), at
    /// `time`. Returns the seek that got it there, if it was one.
    public mutating func observe(
        position: Duration,
        rate: Double,
        at time: ContinuousClock.Instant = .now
    ) -> Seek? {
        defer {
            self.position = position
            self.rate = rate
            self.time = time
        }
        guard let previous = self.position else { return nil }
        let elapsed = self.time.map { max(.zero, time - $0) } ?? .zero
        // Either rate may have held since the last report: playing then
        // paused, or paused then playing.
        let playable = elapsed * max(self.rate, rate, 0)
        let moved = position - previous
        guard previous - position >= tolerance || moved >= playable + tolerance else { return nil }
        // Playback went on from the last report until the seek; at most a
        // tick's worth, so a stall since is not counted as played.
        let played = min(elapsed, Self.maxPlayedBeforeSeek) * max(self.rate, 0)
        // Whole milliseconds, like the positions the player reports.
        let playedMilliseconds = Int64((played.inSecondsDouble * 1000).rounded())
        return Seek(from: previous + .milliseconds(playedMilliseconds), to: position)
    }

    /// How far the seek's origin is carried on from the last report.
    static let maxPlayedBeforeSeek: Duration = .milliseconds(500)
}
