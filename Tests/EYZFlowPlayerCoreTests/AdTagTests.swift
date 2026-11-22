import Foundation
import Testing
@testable import EYZFlowPlayerCore

/// The `cust_params` of a tag, decoded.
private func custParams(_ tag: String) -> [String: String]? {
    guard let raw = URLComponents(string: tag)?.queryItems?.first(where: { $0.name == "cust_params" })?.value
    else { return nil }
    var out: [String: String] = [:]
    for pair in raw.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
        out[parts[0]] = parts.count > 1 ? parts[1] : ""
    }
    return out
}

@Suite("adTagWithTargeting")
struct AdTagWithTargetingTests {
    @Test("adds cust_params to a tag without any, URL-encoded")
    func adds() throws {
        let out = adTagWithTargeting(
            "https://ads.example.com/gampad/ads?iu=/1/x&sz=640x480",
            ["plan": "basic-ads", "access": "svod"]
        )
        #expect(out == "https://ads.example.com/gampad/ads?iu=/1/x&sz=640x480&cust_params=access%3Dsvod%26plan%3Dbasic-ads")
        #expect(custParams(out) == ["plan": "basic-ads", "access": "svod"])
        #expect(URLComponents(string: out)?.queryItems?.first { $0.name == "iu" }?.value == "/1/x")
    }

    @Test("keeps the tag's own cust_params and lets them win")
    func keepsExisting() {
        let tag = "https://ads.example.com/ads?cust_params=" + "genre=drama&plan=fixed".encodedURIComponent + "&correlator=[timestamp]"
        let out = adTagWithTargeting(tag, ["plan": "basic-ads", "access": "svod"])
        #expect(custParams(out.replacingOccurrences(of: "[timestamp]", with: "1"))
            == ["genre": "drama", "plan": "fixed", "access": "svod"])
        // The rest of the tag is kept as written, macros included.
        #expect(out.hasSuffix("&correlator=[timestamp]"))
        #expect(out.hasPrefix("https://ads.example.com/ads?cust_params=genre%3Ddrama%26plan%3Dfixed%26access%3Dsvod"))
    }

    @Test("encodes values that need it")
    func encodes() {
        let out = adTagWithTargeting("https://ads.example.com/ads", ["plan": "a b&c=d"])
        #expect(out == "https://ads.example.com/ads?cust_params=plan%3Da%2520b%2526c%253Dd")
        #expect(custParams(out) == ["plan": "a b&c=d"])
    }

    @Test("keeps a fragment after the query")
    func fragment() {
        let out = adTagWithTargeting("https://ads.example.com/ads?a=1#frag", ["plan": "x"])
        #expect(out == "https://ads.example.com/ads?a=1&cust_params=plan%3Dx#frag")
    }

    @Test("leaves the tag alone with nothing to add or when it is not a URL")
    func unchanged() {
        #expect(adTagWithTargeting("https://ads.example.com/ads?a=1", [:]) == "https://ads.example.com/ads?a=1")
        #expect(adTagWithTargeting("not a url", ["plan": "x"]) == "not a url")
        #expect(adTagWithTargeting("/relative/path?a=1", ["plan": "x"]) == "/relative/path?a=1")
        #expect(adTagWithTargeting("", ["plan": "x"]) == "")
    }
}

@Suite("adTagForPlayback")
struct AdTagForPlaybackTests {
    let tag = "https://ads.example.com/ads?iu=/1/x"

    @Test("ads false from the session requests no ads at all")
    func plansWithoutAds() {
        #expect(adTagForPlayback(configTag: tag, planAds: false) == nil)
        #expect(adTagForPlayback(configTag: tag, planAds: false, targeting: ["plan": "premium"]) == nil)
    }

    @Test("ads true or no answer leaves it to the config")
    func configDecides() {
        #expect(adTagForPlayback(configTag: tag, planAds: true) == tag)
        #expect(adTagForPlayback(configTag: tag, planAds: nil) == tag)
        #expect(adTagForPlayback(configTag: nil, planAds: true) == nil)
        #expect(adTagForPlayback(configTag: nil, planAds: nil) == nil)
    }

    @Test("the session's targeting goes into the tag")
    func targeting() {
        let out = adTagForPlayback(configTag: tag, planAds: true, targeting: ["plan": "basic-ads"])
        #expect(out == "https://ads.example.com/ads?iu=/1/x&cust_params=plan%3Dbasic-ads")
    }
}
