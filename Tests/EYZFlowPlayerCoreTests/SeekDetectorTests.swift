import Foundation
import Testing
@testable import EYZFlowPlayerCore

@Suite("SeekDetector")
struct SeekDetectorTests {
    private let start = ContinuousClock.now

    /// `seconds` of wall time after the start.
    private func at(_ seconds: Double) -> ContinuousClock.Instant {
        start.advanced(by: .milliseconds(Int64(seconds * 1000)))
    }

    /// Feeds `(wall time, position, rate)` reports; returns the seeks found.
    private func seeks(
        _ reports: [(Double, Double, Double)],
        from origin: Duration? = .zero
    ) -> [Seek] {
        var detector = SeekDetector()
        detector.reset(to: origin)
        return reports.compactMap { time, position, rate in
            detector.observe(position: .milliseconds(Int64(position * 1000)), rate: rate, at: at(time))
        }
    }

    private func seek(_ from: Double, _ to: Double) -> Seek {
        Seek(from: .milliseconds(Int64(from * 1000)), to: .milliseconds(Int64(to * 1000)))
    }

    @Test("playing through reports no seek")
    func playingThrough() {
        let ticks = (0...40).map { (Double($0) * 0.5, Double($0) * 0.5, 1.0) }
        #expect(seeks(ticks).isEmpty)
    }

    @Test("a late tick is not a seek")
    func lateTick() {
        // The main thread was busy for three seconds; the playhead moved on.
        #expect(seeks([(0, 0, 1), (0.5, 0.5, 1), (3.5, 3.5, 1), (4, 4, 1)]).isEmpty)
    }

    @Test("double speed is not a seek")
    func doubleSpeed() {
        let ticks = (0...20).map { (Double($0) * 0.25, Double($0) * 0.5, 2.0) }
        #expect(seeks(ticks).isEmpty)
    }

    @Test("pausing, buffering and resuming are not seeks")
    func pauseAndBuffer() {
        let reports: [(Double, Double, Double)] = [
            (0, 0, 1), (0.5, 0.5, 1), (0.7, 0.7, 0), // paused
            (10, 0.7, 0), (10, 0.7, 1), (10.5, 1.2, 1), // resumed
            (11, 1.7, 1), (15, 1.7, 1), (15.5, 2.2, 1), // stalled, played on
        ]
        #expect(seeks(reports).isEmpty)
    }

    @Test("a forward seek while playing, from where playback was")
    func forward() {
        // AVKit's +10 s: the tick and then the jump notification report it.
        let reports: [(Double, Double, Double)] = [
            (0, 0, 1), (0.5, 0.5, 1), (1, 1, 1), (1.2, 11.2, 1), (1.2, 11.2, 1), (1.7, 11.7, 1),
        ]
        // It went from 1.2 s, where playback had got to since the last tick.
        #expect(seeks(reports) == [seek(1.2, 11.2)])
    }

    @Test("a backward seek while playing")
    func backward() {
        let reports: [(Double, Double, Double)] = [
            (0, 20, 1), (0.5, 20.5, 1), (0.6, 10.6, 1), (0.6, 10.6, 1), (1.1, 11.1, 1),
        ]
        #expect(seeks(reports, from: .seconds(20)) == [seek(20.6, 10.6)])
    }

    @Test("a seek while paused")
    func whilePaused() {
        #expect(seeks([(0, 30, 0), (60, 30, 0), (61, 45, 0)], from: .seconds(30)) == [seek(30, 45)])
    }

    @Test("a seek after a stall is from where the stall began, give or take a tick")
    func afterStall() {
        #expect(seeks([(0, 10, 1), (5, 30, 1)], from: .seconds(10)) == [seek(10.5, 30)])
    }

    @Test("jumps under the tolerance are not seeks")
    func small() {
        #expect(seeks([(0, 5, 1), (0.5, 4.5, 1), (1, 5.8, 1)], from: .seconds(5)).isEmpty)
    }

    @Test("a resume starts over at its position")
    func resume() {
        var detector = SeekDetector()
        detector.reset(to: .zero)
        _ = detector.observe(position: .zero, rate: 0, at: at(0))
        detector.reset(to: .seconds(120))
        #expect(detector.observe(position: .seconds(120), rate: 1, at: at(1)) == nil)
        #expect(detector.observe(position: .milliseconds(120_500), rate: 1, at: at(1.5)) == nil)
    }

    @Test("the first report after a reset with no origin is not a seek")
    func noOrigin() {
        #expect(seeks([(0, 42, 1), (0.5, 42.5, 1)], from: nil).isEmpty)
    }
}
