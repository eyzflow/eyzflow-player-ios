import Foundation
import Testing
@testable import EYZFlowPlayerCore

private let base = URL(string: "https://stream.eyzflow.com/s1/thumbnails/thumbnail.vtt")!

/// The start of a real EYZFlow track.
private let vtt = """
WEBVTT

00:00:00.000 --> 00:00:05.000
thumb_0001.jpg#xywh=0,0,199,112

00:00:05.000 --> 00:00:10.000
thumb_0001.jpg#xywh=199,0,199,112

00:00:10.000 --> 00:00:15.000
thumb_0002.jpg#xywh=0,112,199,112

"""

@Suite("ThumbnailTrack.parse")
struct ThumbnailParseTests {
    @Test("reads sprite tiles and resolves their images")
    func sprites() throws {
        let track = ThumbnailTrack.parse(vtt, base: base)
        #expect(track.tiles.count == 3)
        let second = track.tiles[1]
        #expect(second.start == .seconds(5))
        #expect(second.end == .seconds(10))
        #expect(second.image.absoluteString == "https://stream.eyzflow.com/s1/thumbnails/thumb_0001.jpg")
        #expect(second.x == 199 && second.y == 0 && second.width == 199 && second.height == 112)
        #expect(second.isSprite)
    }

    @Test("reads whole images, short times, cue ids and CRLF")
    func wholeImages() throws {
        let track = ThumbnailTrack.parse(
            "WEBVTT\r\n\r\n1\r\n00:05.500 --> 00:10.000 align:start\r\nhttps://cdn.example/a.jpg\r\n",
            base: base
        )
        let tile = try #require(track.tiles.first)
        #expect(track.tiles.count == 1)
        #expect(tile.start == .milliseconds(5500))
        #expect(tile.image.absoluteString == "https://cdn.example/a.jpg")
        #expect(!tile.isSprite)
    }

    @Test("skips cues it cannot read")
    func skips() throws {
        let track = ThumbnailTrack.parse(
            "WEBVTT\n\nnot a time --> 00:00:05.000\na.jpg\n\n00:00:05.000 --> 00:00:10.000\nb.jpg#xywh=1,2\n",
            base: base
        )
        // The broken xywh still shows the whole image.
        let tile = try #require(track.tiles.first)
        #expect(track.tiles.count == 1)
        #expect(tile.image.lastPathComponent == "b.jpg")
        #expect(!tile.isSprite)
    }
}

@Suite("ThumbnailTrack.at")
struct ThumbnailAtTests {
    let track = ThumbnailTrack.parse(vtt, base: base)

    @Test("finds the tile showing at a time")
    func finds() {
        #expect(track.at(.zero)?.x == 0)
        #expect(track.at(.seconds(7))?.x == 199)
        #expect(track.at(.seconds(10))?.y == 112)
    }

    @Test("holds the last tile past the end, the first before the start")
    func holds() {
        #expect(track.at(.seconds(7200)) == track.tiles.last)
        #expect(track.at(.seconds(-1)) == track.tiles.first)
    }

    @Test("an empty track has no tile")
    func empty() {
        #expect(ThumbnailTrack([]).at(.zero) == nil)
    }
}

@Suite("ThumbnailLoader")
struct ThumbnailLoaderTests {
    @Test("loads once per URL")
    func once() async throws {
        let http = FakeHTTPClient { _ in FakeResponse(200, vtt) }
        let loader = ThumbnailLoader(http: http)
        let a = try #require(await loader.load(base))
        let b = try #require(await loader.load(base))
        #expect(a.tiles.count == 3)
        #expect(a === b)
        #expect(http.requests.count == 1)
    }

    @Test("a missing or empty track loads as nil and is tried again")
    func missing() async {
        let count = Box(0)
        let http = FakeHTTPClient { _ in
            count.update { $0 += 1; return $0 } == 1 ? FakeResponse(404, "not found") : FakeResponse(200, "WEBVTT\n")
        }
        let loader = ThumbnailLoader(http: http)
        #expect(await loader.load(base) == nil)
        #expect(await loader.load(base) == nil)
        #expect(count.value == 2)
    }

    @Test("a network failure loads as nil")
    func offline() async {
        let loader = ThumbnailLoader(http: FakeHTTPClient { _ in throw Offline() })
        #expect(await loader.load(base) == nil)
    }
}
