import Foundation
import Testing
@testable import EYZFlowPlayerCore

/// A media playlist as the backend writes it
/// (`manifest-signal-markers.util.ts`): an ad break at 0 s, one at 8 s with a
/// planned pod of 30 s, and an intro span that is no ad break.
private let mediaPlaylist = """
#EXTM3U
#EXT-X-VERSION:6
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-PROGRAM-DATE-TIME:1970-01-01T00:00:00.000Z
#EXT-X-DATERANGE:ID="eyz-ad-1",START-DATE="1970-01-01T00:00:00.000Z",SCTE35-OUT=0xFC302000000000000000FFF00F05000000017FEF7E0000000000000000000000
#EXT-X-DATERANGE:ID="eyz-intro",CLASS="com.eyzflow.signal",START-DATE="1970-01-01T00:00:02.000Z",DURATION=20.000,X-EYZ-TYPE="intro",X-EYZ-LABEL="Intro, part 1"
#EXT-X-DATERANGE:ID="eyz-ad-2",START-DATE="1970-01-01T00:00:08.000Z",PLANNED-DURATION=30.000,SCTE35-OUT=0xFC302500000000000000FFF01405000000027FEFFE000AFC80FE0029325E0000000000000000
#EXTINF:6.000,
seg-0.ts
#EXTINF:6.000,
seg-1.ts
#EXT-X-ENDLIST
"""

private let masterPlaylist = """
#EXTM3U
#EXT-X-VERSION:6
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Deutsch",LANGUAGE="de",URI="audio/de/index.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",URI="subs/en/index.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,AUDIO="aud"

video/720p/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,AUDIO="aud"
video/1080p/index.m3u8
"""

private let master = URL(string: "https://stream.eyzflow.com/abc/master.m3u8")!

@Suite("Ad break markers")
struct AdBreaksTests {
    @Test("reads the ad breaks and skips the intro and credits spans")
    func reads() {
        #expect(parseHLSAdBreaks(mediaPlaylist) == [
            AdBreak(id: "eyz-ad-1", start: .zero),
            AdBreak(id: "eyz-ad-2", start: .seconds(8), duration: .seconds(30)),
        ])
    }

    @Test("START-DATE is placed against the playlist anchor")
    func anchor() {
        let playlist = """
        #EXTM3U
        #EXT-X-PROGRAM-DATE-TIME:2026-01-01T10:00:00.000Z
        #EXT-X-DATERANGE:ID="a",START-DATE="2026-01-01T10:01:30.500Z",SCTE35-OUT=0xFC
        #EXT-X-DATERANGE:ID="early",START-DATE="2026-01-01T09:59:00Z",SCTE35-OUT=0xFC
        #EXTINF:6.0,
        seg.ts
        #EXT-X-PROGRAM-DATE-TIME:2026-01-01T10:00:06.000Z
        """
        #expect(parseHLSAdBreaks(playlist) == [AdBreak(id: "a", start: .milliseconds(90_500))])
    }

    @Test("without an anchor no DATERANGE can be placed")
    func noAnchor() {
        let playlist = """
        #EXTM3U
        #EXT-X-DATERANGE:ID="a",START-DATE="1970-01-01T00:00:08.000Z",SCTE35-OUT=0xFC
        """
        #expect(parseHLSAdBreaks(playlist).isEmpty)
    }

    @Test("a DATERANGE without SCTE-35 is not an ad break")
    func notSCTE() {
        let playlist = """
        #EXT-X-PROGRAM-DATE-TIME:1970-01-01T00:00:00.000Z
        #EXT-X-DATERANGE:ID="x",START-DATE="1970-01-01T00:00:08.000Z",DURATION=3
        """
        #expect(parseHLSAdBreaks(playlist).isEmpty)
    }

    @Test("a playlist without markers has no breaks")
    func none() {
        #expect(parseHLSAdBreaks(masterPlaylist).isEmpty)
    }

    @Test("media playlists come from the master, video first")
    func mediaPlaylists() {
        #expect(hlsMediaPlaylistURLs(masterPlaylist, master: master).map(\.absoluteString) == [
            "https://stream.eyzflow.com/abc/video/720p/index.m3u8",
            "https://stream.eyzflow.com/abc/video/1080p/index.m3u8",
            "https://stream.eyzflow.com/abc/audio/de/index.m3u8",
        ])
    }

    @Test("loads the master, then its first media playlist")
    func loads() async {
        let http = FakeHTTPClient { request in
            switch request.url.path {
            case "/abc/master.m3u8": FakeResponse(200, masterPlaylist)
            case "/abc/video/720p/index.m3u8": FakeResponse(200, mediaPlaylist)
            default: FakeResponse(404)
            }
        }
        let breaks = await loadHLSAdBreaks(http: http, master: master)
        #expect(breaks.map(\.id) == ["eyz-ad-1", "eyz-ad-2"])
        #expect(http.calls == ["GET /abc/master.m3u8", "GET /abc/video/720p/index.m3u8"])
    }

    @Test("a manifest that cannot be loaded gives no breaks")
    func unreadable() async {
        let missing = FakeHTTPClient { _ in FakeResponse(404) }
        #expect(await loadHLSAdBreaks(http: missing, master: master).isEmpty)
        let offline = FakeHTTPClient { _ in throw Offline() }
        #expect(await loadHLSAdBreaks(http: offline, master: master).isEmpty)
        let mediaMissing = FakeHTTPClient { request in
            request.url.path == "/abc/master.m3u8" ? FakeResponse(200, masterPlaylist) : FakeResponse(500)
        }
        #expect(await loadHLSAdBreaks(http: mediaMissing, master: master).isEmpty)
    }
}

@Suite("Ad break schedule")
struct AdBreakScheduleTests {
    let breaks = [
        AdBreak(id: "pre", start: .zero),
        AdBreak(id: "mid", start: .seconds(8)),
        AdBreak(id: "late", start: .seconds(30)),
    ]

    @Test("a break at the start is the pre-roll, taken once")
    func preroll() {
        var schedule = AdBreakSchedule(breaks)
        #expect(schedule.takePreroll()?.id == "pre")
        #expect(schedule.takePreroll() == nil)
    }

    @Test("no pre-roll without a break at the start")
    func noPreroll() {
        var schedule = AdBreakSchedule(Array(breaks.dropFirst()))
        #expect(schedule.takePreroll() == nil)
        #expect(schedule.hasBreaks)
    }

    @Test("a mid-roll is due when playback reaches it, once")
    func midroll() {
        var schedule = AdBreakSchedule(breaks)
        #expect(schedule.due(from: .seconds(7), to: .milliseconds(7500)) == nil)
        #expect(schedule.due(from: .milliseconds(7500), to: .seconds(8))?.id == "mid")
        #expect(schedule.due(from: .milliseconds(7500), to: .seconds(8)) == nil)
    }

    @Test("a break passed by seeking is not played")
    func seek() {
        var schedule = AdBreakSchedule(breaks)
        #expect(schedule.due(from: .seconds(4), to: .seconds(20)) == nil)
        #expect(schedule.due(from: .seconds(20), to: .seconds(4)) == nil)
        // Playing through it after rewinding still plays it once.
        #expect(schedule.due(from: .seconds(7), to: .milliseconds(8500))?.id == "mid")
    }

    @Test("the pre-roll is never a mid-roll")
    func prerollNotMid() {
        var schedule = AdBreakSchedule([AdBreak(id: "pre", start: .milliseconds(300))])
        #expect(schedule.due(from: .zero, to: .seconds(1)) == nil)
    }

    @Test("the gate needs features.ads and a non-empty tag")
    func gate() {
        var config = PlayerConfig(features: PlayerFeatures(ads: true), ads: PlayerAdsConfig(adTagURL: "  https://ads/tag  "))
        #expect(config.adTagToPlay == "https://ads/tag")
        config.features.ads = false
        #expect(config.adTagToPlay == nil)
        config.features.ads = true
        config.ads = PlayerAdsConfig(adTagURL: "   ")
        #expect(config.adTagToPlay == nil)
        config.ads = nil
        #expect(config.adTagToPlay == nil)
    }
}
