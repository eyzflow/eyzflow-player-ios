import Foundation
import Testing
@testable import EYZFlowPlayerCore

@Suite("EYZFlowSource")
struct SourceTests {
    @Test("derives the stream and DRM URLs from its id")
    func urls() {
        let source = EYZFlowSource(id: "sample-stream", title: "Sample")
        #expect(source.hlsStreamURL == URL(string: "https://stream.eyzflow.com/sample-stream/master.m3u8"))
        #expect(source.fairplayCertificateURL == URL(string: "https://stream.eyzflow.com/fps.cer"))
        #expect(source.fairplayLicenseURL == URL(string: "https://api.eyzflow.com/v1/drm/sample-stream/fairplay/acquire"))
        #expect(source.dashStreamURL == URL(string: "https://stream.eyzflow.com/sample-stream/manifest.mpd"))
        #expect(source.widevineLicenseURL == URL(string: "https://api.eyzflow.com/v1/drm/sample-stream/widevine/acquire"))
        #expect(source.thumbnailsURL == URL(string: "https://stream.eyzflow.com/sample-stream/thumbnails/thumbnail.vtt"))
    }

    @Test("an id with a slash or space stays one path segment")
    func escapedID() {
        let source = EYZFlowSource(id: "a/b c", title: "Odd")
        #expect(source.hlsStreamURL.absoluteString == "https://stream.eyzflow.com/a%2Fb%20c/master.m3u8")
    }

    @Test("equal by value")
    func equality() {
        #expect(
            EYZFlowSource(id: "film-1", title: "Film", sourceType: .film(catalogueID: "c"))
                == EYZFlowSource(id: "film-1", title: "Film", sourceType: .film(catalogueID: "c"))
        )
        #expect(
            EYZFlowSource(id: "film-1", title: "Film", drmAccessHeader: "header-a")
                != EYZFlowSource(id: "film-1", title: "Film", drmAccessHeader: "header-b")
        )
    }

    @Test("source types carry the catalogue id; only films are protected")
    func sourceTypes() {
        #expect(EYZFlowSourceType.trailer(catalogueID: "catalogue-1").catalogueID == "catalogue-1")
        #expect(EYZFlowSourceType.film(catalogueID: "catalogue-1").catalogueID == "catalogue-1")
        #expect(EYZFlowSourceType.trailer(catalogueID: "c") != .film(catalogueID: "c"))
        #expect(EYZFlowSourceType.film(catalogueID: "c").isProtected)
        #expect(!EYZFlowSourceType.trailer(catalogueID: "c").isProtected)
    }
}
