import Foundation
import Testing
@testable import EYZFlowPlayerCore

@Suite("FairPlayLicenseFormat")
struct FairPlayLicenseFormatTests {
    @Test("the content id is the skd URI without its scheme")
    func contentIdentifier() {
        let skd = "skd://aaa55728-d53b-a1c1-2c84-857ac86dd456:F662D5E7144DE1610B528238900F05D0"
        let expected = Data("aaa55728-d53b-a1c1-2c84-857ac86dd456:F662D5E7144DE1610B528238900F05D0".utf8)
        #expect(FairPlayLicenseFormat.contentIdentifier(identifier: skd, initializationData: nil) == expected)
        #expect(
            FairPlayLicenseFormat.contentIdentifier(identifier: URL(string: "skd://key-1")!, initializationData: nil)
                == Data("key-1".utf8)
        )
        #expect(FairPlayLicenseFormat.contentIdentifier(identifier: nil, initializationData: Data((skd + "\u{0}").utf8)) == expected)
        #expect(FairPlayLicenseFormat.contentIdentifier(identifier: "skd://", initializationData: nil) == nil)
        #expect(FairPlayLicenseFormat.contentIdentifier(identifier: nil, initializationData: nil) == nil)
    }

    @Test("the CKC: raw, base64, <ckc> and JSON")
    func ckc() {
        let raw = Data([0x00, 0xFF, 0x10, 0x80, 0x01])
        let base64 = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E]).base64EncodedString()
        #expect(FairPlayLicenseFormat.ckc(from: raw) == raw)
        #expect(FairPlayLicenseFormat.ckc(from: Data("<ckc>\(base64)</ckc>".utf8)) == Data(base64Encoded: base64))
        #expect(FairPlayLicenseFormat.ckc(from: Data("{\"ckc\":\"\(base64)\"}".utf8)) == Data(base64Encoded: base64))
        #expect(FairPlayLicenseFormat.ckc(from: Data(base64.utf8)) == Data(base64Encoded: base64))
        #expect(FairPlayLicenseFormat.ckc(from: Data()) == nil)
    }

    @Test("the certificate: DER, or base64 DER")
    func certificate() {
        let der = Data([0x30, 0x82, 0x01, 0x0A])
        #expect(FairPlayLicenseFormat.certificate(from: der) == der)
        #expect(FairPlayLicenseFormat.certificate(from: Data(der.base64EncodedString().utf8)) == der)
        #expect(FairPlayLicenseFormat.certificate(from: Data()) == nil)
    }

    @Test("an error body is kept for its code")
    func body() {
        #expect(FairPlayLicenseFormat.bodyText(Data(" {\"code\":\"STREAM_LIMIT\"} ".utf8)) == "{\"code\":\"STREAM_LIMIT\"}")
        #expect(FairPlayLicenseFormat.bodyText(nil) == "")
    }
}
