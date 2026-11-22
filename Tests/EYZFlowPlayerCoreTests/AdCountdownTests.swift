import Foundation
import Testing
@testable import EYZFlowPlayerCore

private func s(_ seconds: Double) -> Duration { .milliseconds(Int64((seconds * 1000).rounded())) }

@Suite("Ad countdown")
struct AdCountdownTests {
    @Test("counts down the last 5 s before a break, in whole seconds rounded up")
    func thresholds() {
        let starts = [s(30)]
        #expect(AdCountdown.seconds(at: s(24.9), breakStarts: starts) == nil)
        #expect(AdCountdown.seconds(at: s(25), breakStarts: starts) == 5)
        #expect(AdCountdown.seconds(at: s(25.1), breakStarts: starts) == 5)
        #expect(AdCountdown.seconds(at: s(26), breakStarts: starts) == 4)
        #expect(AdCountdown.seconds(at: s(26.5), breakStarts: starts) == 4)
        #expect(AdCountdown.seconds(at: s(27.5), breakStarts: starts) == 3)
        #expect(AdCountdown.seconds(at: s(28.2), breakStarts: starts) == 2)
        #expect(AdCountdown.seconds(at: s(29), breakStarts: starts) == 1)
        #expect(AdCountdown.seconds(at: s(29.999), breakStarts: starts) == 1)
        #expect(AdCountdown.seconds(at: s(30), breakStarts: starts) == nil)
    }

    @Test("a 10 s countdown counts 10 … 1")
    func tenSeconds() {
        let starts = [s(30)]
        #expect(AdCountdown.seconds(at: s(19.9), breakStarts: starts, length: 10) == nil)
        #expect(AdCountdown.seconds(at: s(20), breakStarts: starts, length: 10) == 10)
        #expect(AdCountdown.seconds(at: s(20.5), breakStarts: starts, length: 10) == 10)
        #expect(AdCountdown.seconds(at: s(25), breakStarts: starts, length: 10) == 5)
        #expect(AdCountdown.seconds(at: s(29.5), breakStarts: starts, length: 10) == 1)
        #expect(AdCountdown.seconds(at: s(30), breakStarts: starts, length: 10) == nil)
    }

    @Test("a 3 s countdown counts 3 … 1")
    func threeSeconds() {
        let starts = [s(30)]
        #expect(AdCountdown.seconds(at: s(26.9), breakStarts: starts, length: 3) == nil)
        #expect(AdCountdown.seconds(at: s(27), breakStarts: starts, length: 3) == 3)
        #expect(AdCountdown.seconds(at: s(28.5), breakStarts: starts, length: 3) == 2)
        #expect(AdCountdown.seconds(at: s(29.9), breakStarts: starts, length: 3) == 1)
    }

    @Test("the length: rounded, clamped to 1…30, 5 when missing")
    func length() {
        #expect(AdCountdown.length(nil) == 5)
        #expect(AdCountdown.length(.nan) == 5)
        #expect(AdCountdown.length(.infinity) == 5)
        #expect(AdCountdown.length(8) == 8)
        #expect(AdCountdown.length(0) == 1)
        #expect(AdCountdown.length(90) == 30)
        #expect(AdCountdown.length(7.4) == 7)
    }

    @Test("uses the nearest break ahead, in any order")
    func nearest() {
        #expect(AdCountdown.seconds(at: s(57), breakStarts: [s(90), s(30), s(60)]) == 3)
        #expect(AdCountdown.seconds(at: s(10), breakStarts: []) == nil)
    }

    @Test("a break seeked past is not counted towards; the next one is")
    func seekPast() {
        let starts = [s(30), s(60)]
        #expect(AdCountdown.seconds(at: s(27), breakStarts: starts) == 3)
        #expect(AdCountdown.seconds(at: s(40), breakStarts: starts) == nil)
        #expect(AdCountdown.seconds(at: s(56), breakStarts: starts) == 4)
    }

    @Test("speaks the device language: en, de, fr, nl, English otherwise")
    func labels() {
        #expect(AdCountdown.label(5, language: "en-GB") == "Ad in 5")
        #expect(AdCountdown.label(4, language: "de-DE") == "Werbung in 4")
        #expect(AdCountdown.label(3, language: "fr") == "Publicité dans 3")
        #expect(AdCountdown.label(2, language: "nl-BE") == "Reclame over 2")
        #expect(AdCountdown.label(2, language: "nl_NL") == "Reclame over 2")
        #expect(AdCountdown.label(1, language: "es") == "Ad in 1")
        #expect(AdCountdown.label(1, language: "") == "Ad in 1")
    }
}

@Suite("Ad break schedule: upcoming mid-rolls")
struct AdBreakScheduleUpcomingTests {
    @Test("lists unplayed mid-roll markers, not the pre-roll")
    func upcoming() {
        var schedule = AdBreakSchedule([
            AdBreak(id: "pre", start: .zero),
            AdBreak(id: "a", start: s(30)),
            AdBreak(id: "b", start: s(60)),
        ])
        #expect(schedule.upcomingMidrollStarts == [s(30), s(60)])
        #expect(schedule.due(from: s(29.8), to: s(30.1))?.id == "a")
        #expect(schedule.upcomingMidrollStarts == [s(60)])
    }

    @Test("keeps a marker passed by seeking: it plays, and is counted down to, when reached later")
    func seekedStaysUnplayed() {
        var schedule = AdBreakSchedule([AdBreak(id: "a", start: s(30))])
        #expect(schedule.due(from: s(27), to: s(40)) == nil)
        #expect(schedule.upcomingMidrollStarts == [s(30)])
        #expect(AdCountdown.seconds(at: s(26), breakStarts: schedule.upcomingMidrollStarts) == 4)
    }
}

@Suite("VMAP cue points")
struct AdCuePointScheduleTests {
    @Test("keeps mid-roll cue points only: 0 is the pre-roll, -1 the post-roll")
    func filters() {
        let schedule = AdCuePointSchedule([.zero, s(15), .seconds(-1), s(0.4), s(45)])
        #expect(schedule.upcoming == [s(15), s(45)])
    }

    @Test("a cue point played through is not counted down again after a rewind")
    func playedThrough() {
        var schedule = AdCuePointSchedule([s(15)])
        schedule.pass(from: s(10), to: s(12))
        #expect(schedule.upcoming == [s(15)])
        schedule.pass(from: s(14.9), to: s(15.1))
        #expect(schedule.upcoming.isEmpty)
        #expect(AdCountdown.seconds(at: s(12), breakStarts: schedule.upcoming) == nil)
    }

    @Test("a cue point seeked over is still ahead after a rewind")
    func seekedOver() {
        var schedule = AdCuePointSchedule([s(15)])
        schedule.pass(from: s(10), to: s(20))
        #expect(schedule.upcoming == [s(15)])
        schedule.pass(from: s(15), to: s(10))
        #expect(schedule.upcoming == [s(15)])
    }
}
