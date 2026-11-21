import Foundation
import Testing
@testable import EYZFlowPlayerCore

@MainActor
@Suite("PlaybackEventTracker")
struct PlaybackEventTrackerTests {
    private func tracker() -> (PlaybackEventTracker, () -> [String]) {
        let tracker = PlaybackEventTracker(sourceID: "s")
        var names: [String] = []
        tracker.onEvent = { names.append($0.name) }
        return (tracker, { names })
    }

    private func update(
        _ tracker: PlaybackEventTracker,
        ready: Bool = true,
        playing: Bool = false,
        buffering: Bool = false,
        at seconds: Int64 = 0
    ) {
        tracker.update(
            isReady: ready,
            isPlaying: playing,
            isBuffering: buffering,
            position: .seconds(seconds),
            duration: .seconds(600)
        )
    }

    @Test("ready, started once, then pause and resume")
    func order() {
        let (t, names) = tracker()
        update(t, ready: false)
        update(t)
        update(t, playing: true)
        update(t, playing: true, at: 5)
        update(t, at: 6)
        update(t, playing: true, at: 6)
        #expect(names() == ["PlaybackReady", "PlaybackStarted", "PlaybackPaused", "PlaybackResumed"])
    }

    @Test("a stall is buffering, not a pause, and only after start")
    func buffering() {
        let (t, names) = tracker()
        update(t, buffering: true)
        update(t, playing: true)
        update(t, buffering: true, at: 3)
        update(t, buffering: true, at: 3)
        update(t, playing: true, at: 4)
        #expect(names() == [
            "PlaybackReady", "PlaybackStarted",
            "PlaybackBufferingStarted", "PlaybackBufferingEnded",
        ])
    }

    @Test("seeks count only after start and when the position moved")
    func seeks() {
        let (t, names) = tracker()
        update(t)
        t.seeked(from: .zero, to: .seconds(30), duration: nil)
        update(t, playing: true, at: 30)
        t.seeked(from: .seconds(30), to: .seconds(30), duration: nil)
        t.seeked(from: .seconds(30), to: .seconds(90), duration: nil)
        #expect(names() == ["PlaybackReady", "PlaybackStarted", "PlaybackSeeked"])
    }

    @Test("completed once; only closed follows")
    func completion() {
        let (t, names) = tracker()
        update(t, playing: true)
        t.reachedEnd(position: .seconds(600), duration: .seconds(600))
        t.reachedEnd(position: .seconds(600), duration: .seconds(600))
        update(t, playing: true, at: 600)
        t.seeked(from: .seconds(600), to: .zero, duration: nil)
        t.close()
        t.close()
        #expect(names() == ["PlaybackReady", "PlaybackStarted", "PlaybackCompleted", "PlaybackClosed"])
    }

    @Test("the same error is reported once")
    func errors() {
        let (t, names) = tracker()
        t.failed(message: "boom")
        t.failed(message: "boom")
        t.failed(message: "other")
        t.close()
        #expect(names() == ["PlaybackError", "PlaybackError", "PlaybackClosed"])
    }

    @Test("track changes after start carry the language")
    func tracks() {
        let tracker = PlaybackEventTracker(sourceID: "s")
        var events: [PlaybackEvent] = []
        tracker.onEvent = { events.append($0) }
        tracker.audioTrackChanged(language: "de")
        tracker.update(isReady: true, isPlaying: true, isBuffering: false, position: .seconds(1), duration: nil)
        tracker.audioTrackChanged(language: "en")
        tracker.subtitleTrackChanged(language: nil)
        #expect(events.dropFirst(2).map(\.description) == [
            "PlaybackAudioTrackChanged(sourceId: s, position: 0:00:01, language: en)",
            "PlaybackSubtitleTrackChanged(sourceId: s, position: 0:00:01, language: null)",
        ])
    }
}
