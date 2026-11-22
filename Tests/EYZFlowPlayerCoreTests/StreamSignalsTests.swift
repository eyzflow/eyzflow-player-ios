import Foundation
import Testing
@testable import EYZFlowPlayerCore

/// A media playlist as the backend writes it (`manifest-signal-markers.util.ts`).
private let mediaPlaylist = """
#EXTM3U
#EXT-X-VERSION:6
#EXT-X-TARGETDURATION:6
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-PROGRAM-DATE-TIME:1970-01-01T00:00:00.000Z
#EXT-X-DATERANGE:ID="eyz-recap",CLASS="com.eyzflow.signal",START-DATE="1970-01-01T00:00:02.000Z",DURATION=10.000,X-EYZ-TYPE="recap"
#EXT-X-DATERANGE:ID="eyz-intro",CLASS="com.eyzflow.signal",START-DATE="1970-01-01T00:00:15.000Z",DURATION=15.000,X-EYZ-TYPE="intro",X-EYZ-LABEL="Main titles"
#EXT-X-DATERANGE:ID="eyz-ad-1",START-DATE="1970-01-01T00:00:40.000Z",PLANNED-DURATION=30.000,SCTE35-OUT=0xFC302000
#EXT-X-DATERANGE:ID="eyz-closing-credits",CLASS="com.eyzflow.signal",START-DATE="1970-01-01T00:00:50.000Z",DURATION=10.000,X-EYZ-TYPE="closing_credits"
#EXTINF:6.000,
seg-0.ts
#EXT-X-ENDLIST
"""

private let masterPlaylist = """
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
360p/360p.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720
720p/720p.m3u8
"""

private let master = URL(string: "https://stream.eyzflow.com/film/master.m3u8")!

@Suite("Stream signals")
struct StreamSignalsTests {
    @Test("reads the backend DATERANGEs: type, span and label")
    func parses() {
        #expect(parseHLSSignals(mediaPlaylist) == [
            StreamSignal(id: "eyz-recap", type: .recap, start: .seconds(2), end: .seconds(12)),
            StreamSignal(id: "eyz-intro", type: .intro, start: .seconds(15), end: .seconds(30), label: "Main titles"),
            StreamSignal(id: "eyz-closing-credits", type: .closingCredits, start: .seconds(50), end: .seconds(60)),
        ])
    }

    @Test("takes END-DATE when there is no DURATION")
    func endDate() {
        let playlist = """
        #EXT-X-PROGRAM-DATE-TIME:1970-01-01T00:00:00.000Z
        #EXT-X-DATERANGE:ID="a",CLASS="com.eyzflow.signal",START-DATE="1970-01-01T00:00:05.000Z",END-DATE="1970-01-01T00:01:05.000Z",X-EYZ-TYPE="opening_credits"
        """
        #expect(parseHLSSignals(playlist).first?.end == .seconds(65))
    }

    @Test("skips ad breaks, unknown types, empty spans and an unanchored playlist")
    func skips() {
        let unanchored = """
        #EXT-X-DATERANGE:ID="a",CLASS="com.eyzflow.signal",START-DATE="1970-01-01T00:00:05.000Z",DURATION=60,X-EYZ-TYPE="intro"
        """
        let odd = """
        #EXT-X-PROGRAM-DATE-TIME:1970-01-01T00:00:00.000Z
        #EXT-X-DATERANGE:ID="a",CLASS="com.eyzflow.signal",START-DATE="1970-01-01T00:00:05.000Z",DURATION=60,X-EYZ-TYPE="ad_break"
        #EXT-X-DATERANGE:ID="b",CLASS="com.eyzflow.signal",START-DATE="1970-01-01T00:00:05.000Z",DURATION=0,X-EYZ-TYPE="intro"
        #EXT-X-DATERANGE:ID="c",CLASS="com.example.other",START-DATE="1970-01-01T00:00:05.000Z",DURATION=60,X-EYZ-TYPE="intro"
        """
        #expect(parseHLSSignals(unanchored).isEmpty)
        #expect(parseHLSSignals(odd).isEmpty)
    }

    @Test("one fetch of the first media playlist gives ad breaks and signals")
    func loadsBoth() async {
        let http = FakeHTTPClient { request in
            switch request.url.path {
            case "/film/master.m3u8": FakeResponse(200, masterPlaylist)
            case "/film/360p/360p.m3u8": FakeResponse(200, mediaPlaylist)
            default: FakeResponse(404)
            }
        }
        let markers = await loadHLSMarkers(http: http, master: master)
        #expect(markers.adBreaks.map(\.start) == [.seconds(40)])
        #expect(markers.signals.map(\.type) == [.recap, .intro, .closingCredits])
        #expect(http.calls == ["GET /film/master.m3u8", "GET /film/360p/360p.m3u8"])
    }

    @Test("a manifest that cannot be read gives no markers")
    func unreadable() async {
        let offline = FakeHTTPClient { _ in throw Offline() }
        #expect(await loadHLSMarkers(http: offline, master: master) == .none)
    }

    @Test("in a span from its start until just before its end; the latest start wins")
    func spans() {
        let credits = StreamSignal(id: "credits", type: .openingCredits, start: .zero, end: .seconds(120))
        let intro = StreamSignal(id: "intro", type: .intro, start: .seconds(30), end: .seconds(90))
        #expect(signal(at: .milliseconds(29_900), in: [intro]) == nil)
        #expect(signal(at: .seconds(30), in: [intro])?.id == "intro")
        #expect(signal(at: .milliseconds(89_700), in: [intro])?.id == "intro")
        #expect(signal(at: .milliseconds(89_800), in: [intro]) == nil)
        #expect(signal(at: nil, in: [intro]) == nil)
        #expect(signal(at: .seconds(10), in: [credits, intro])?.id == "credits")
        #expect(signal(at: .seconds(40), in: [credits, intro])?.id == "intro")
        #expect(signal(at: .seconds(100), in: [credits, intro])?.id == "credits")
    }

    @Test("button text in the viewer's language")
    func labels() {
        let intro = StreamSignal(id: "i", type: .intro, start: .zero, end: .seconds(1))
        let closing = StreamSignal(id: "c", type: .closingCredits, start: .zero, end: .seconds(1))
        let opening = StreamSignal(id: "o", type: .openingCredits, start: .zero, end: .seconds(1))
        #expect(intro.skipLabel(language: "en-US") == "Skip intro")
        #expect(closing.skipLabel(language: "de-DE") == "Abspann überspringen")
        #expect(opening.skipLabel(language: "de") == "Vorspann überspringen")
        #expect(opening.skipLabel(language: "nl_BE") == "Begintiteling overslaan")
        #expect(closing.skipLabel(language: "fr") == "Passer le générique")
        #expect(intro.skipLabel(language: "ja") == "Skip intro")
    }
}

@Suite("Signal tracker")
@MainActor
struct SignalTrackerTests {
    private func tracker(log: Ref<[String]>) -> SignalTracker {
        let tracker = SignalTracker()
        tracker.onStarted = { log.value.append("start \($0.id)") }
        tracker.onEnded = { log.value.append("end \($0.id)") }
        return tracker
    }

    @Test("reports entering and leaving, the old one first")
    func entersAndLeaves() {
        let log = Ref<[String]>([])
        let tracker = tracker(log: log)
        tracker.report(.seconds(20))
        #expect(log.value.isEmpty)
        tracker.signals = parseHLSSignals(mediaPlaylist)
        for position: Duration? in [.seconds(21), .seconds(5), .seconds(6), .seconds(55), nil] {
            tracker.report(position)
        }
        #expect(log.value == [
            "start eyz-intro", "end eyz-intro",
            "start eyz-recap", "end eyz-recap",
            "start eyz-closing-credits", "end eyz-closing-credits",
        ])
        #expect(tracker.current == nil)
    }

    @Test("a skip stays done while positions from before the seek come in")
    func skipHolds() {
        let log = Ref<[String]>([])
        let tracker = tracker(log: log)
        tracker.signals = parseHLSSignals(mediaPlaylist)
        tracker.report(.seconds(20))
        tracker.skip(tracker.current!, to: .seconds(30))
        #expect(tracker.current == nil)
        tracker.report(.milliseconds(20_500))
        tracker.report(.seconds(21))
        #expect(tracker.current == nil)
        tracker.report(.seconds(30))
        tracker.report(.seconds(16))
        #expect(tracker.current?.id == "eyz-intro")
        #expect(log.value == ["start eyz-intro", "end eyz-intro", "start eyz-intro"])
    }

    @Test("seeking back before a skipped signal clears the skip")
    func skipClears() {
        let tracker = SignalTracker()
        tracker.signals = parseHLSSignals(mediaPlaylist)
        tracker.report(.seconds(20))
        tracker.skip(tracker.current!, to: .seconds(30))
        tracker.report(.seconds(1))
        tracker.report(.seconds(15))
        #expect(tracker.current?.id == "eyz-intro")
    }
}

@Suite("Signal events")
@MainActor
struct SignalEventTests {
    @Test("the tracker reports signal events with the signal, named as in Dart")
    func events() {
        let events = Ref<[PlaybackEvent]>([])
        let tracker = PlaybackEventTracker(sourceID: "film")
        tracker.onEvent = { events.value.append($0) }
        let intro = StreamSignal(id: "eyz-intro", type: .intro, start: .seconds(15), end: .seconds(30))
        tracker.signalStarted(intro)
        tracker.signalEnded(intro)
        #expect(events.value.map(\.name) == ["PlaybackSignalStarted", "PlaybackSignalEnded"])
        #expect(events.value.first?.description.contains("signal: StreamSignal(intro 0:00:15–0:00:30)") == true)
    }

    @Test("features.skipButtons is read, and missing is on")
    func config() {
        #expect(PlayerFeatures(json: [:]).skipButtons)
        #expect(!PlayerFeatures(json: ["skipButtons": .bool(false)]).skipButtons)
        #expect(PlayerFeatures(skipButtons: false).json.objectValue?["skipButtons"] == .bool(false))
    }
}

@Suite("Theme values")
struct ThemeValueTests {
    @Test("reads the dashboard's colour formats")
    func colours() {
        #expect(CSSColor(css: "#ff0000") == CSSColor(red: 1, green: 0, blue: 0))
        #expect(CSSColor(css: "#fff")?.blue == 1)
        #expect(CSSColor(css: "#00000080")?.alpha == Double(0x80) / 255)
        #expect(CSSColor(css: "rgba(10, 10, 10, 0.88)") == CSSColor(red: 10.0 / 255, green: 10.0 / 255, blue: 10.0 / 255, alpha: 0.88))
        #expect(CSSColor(css: "rgb(255,255,255)")?.alpha == 1)
        #expect(CSSColor(css: "red") == nil)
        #expect(CSSColor(css: "#12345") == nil)
    }

    @Test("reads px lengths")
    func lengths() {
        #expect(cssLength("10px") == 10)
        #expect(cssLength(" 4 ") == 4)
        #expect(cssLength("1em") == nil)
    }
}

@Suite("Skip button types")
struct SkipButtonTypesTests {
    @Test("all but the closing credits by default; the config switches types")
    func defaults() {
        let config = PlayerConfig.defaults
        #expect(config.showsSkipButton(for: .intro))
        #expect(config.showsSkipButton(for: .recap))
        #expect(config.showsSkipButton(for: .openingCredits))
        #expect(!config.showsSkipButton(for: .closingCredits))

        let remote = PlayerConfig(json: [
            "features": ["skipButtons": .bool(true)],
            "skipButtonTypes": ["recap": .bool(false), "closingCredits": .bool(true)],
        ])
        #expect(!remote.showsSkipButton(for: .recap))
        #expect(remote.showsSkipButton(for: .closingCredits))
        #expect(remote.showsSkipButton(for: .intro))

        let off = PlayerConfig(json: ["features": ["skipButtons": .bool(false)]])
        #expect(!off.showsSkipButton(for: .intro))
    }

    @Test("an inline config overrides type by type")
    func merge() {
        let remote = PlayerConfig(skipButtonTypes: PlayerSkipButtonTypes(recap: false))
        let merged = remote.merged(with: PlayerConfigOverride(skipButtonTypes: PlayerSkipButtonTypes(closingCredits: true)))
        #expect(!merged.showsSkipButton(for: .recap))
        #expect(merged.showsSkipButton(for: .closingCredits))
    }
}
