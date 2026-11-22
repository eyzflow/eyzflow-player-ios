import Foundation

/// The ad tag one playback requests, or nil for no ad request at all.
///
/// `configTag` is the player config's tag ([`PlayerConfig.adTagToPlay`]).
/// `planAds` is the playback session's `ads`: false plays no ads (no pre-roll,
/// no mid-rolls), whatever the config says; true or nil (no session, an older
/// backend, a failed request) leaves it to the config. The session's
/// `targeting` goes into the tag's `cust_params`.
///
/// The same rule as the web player's `use-shaka.ts`.
public func adTagForPlayback(
    configTag: String?,
    planAds: Bool?,
    targeting: [String: String] = [:]
) -> String? {
    guard let configTag, planAds != false else { return nil }
    return adTagWithTargeting(configTag, targeting)
}

/// Adds key-values to an ad tag's `cust_params` query parameter (Google Ad
/// Manager's custom targeting, URL-encoded `k=v&k2=v2`), keeping any the tag
/// already has; the tag's own value wins on the same key. Returns the tag
/// unchanged when there is nothing to add or it is not a URL.
///
/// Only the `cust_params` parameter is rewritten: the rest of the tag,
/// macros such as `[timestamp]` included, is kept as written. The web
/// player's `withTargeting` (`ad-tag.ts`).
public func adTagWithTargeting(_ adTagURL: String, _ targeting: [String: String]) -> String {
    if targeting.isEmpty { return adTagURL }
    // `scheme://host…` with no whitespace. Checked by hand: URLComponents
    // refuses tags with `[macro]` placeholders on older systems.
    guard adTagURL.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://[^/?#\s]+[^\s]*$"#, options: .regularExpression) != nil
    else { return adTagURL }

    // Split off the fragment, then the query.
    var rest = Substring(adTagURL)
    var fragment: Substring = ""
    if let hash = rest.firstIndex(of: "#") {
        fragment = rest[hash...]
        rest = rest[..<hash]
    }
    var base = rest
    var query: Substring?
    if let question = rest.firstIndex(of: "?") {
        base = rest[..<question]
        query = rest[rest.index(after: question)...]
    }

    var segments = query.map { $0.split(separator: "&", omittingEmptySubsequences: false).map(String.init) } ?? []
    let prefix = "cust_params="
    let index = segments.firstIndex { $0.hasPrefix(prefix) }

    var pairs: [(key: String, value: String)] = []
    if let index {
        let inner = formDecode(String(segments[index].dropFirst(prefix.count)))
        for pair in inner.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = formDecode(String(parts[0]))
            if key.isEmpty { continue }
            pairs.append((key, parts.count > 1 ? formDecode(String(parts[1])) : ""))
        }
    }
    let existing = Set(pairs.map(\.key))
    for key in targeting.keys.sorted() where !existing.contains(key) {
        pairs.append((key, targeting[key]!))
    }

    let inner = pairs.map { "\($0.key.encodedURIComponent)=\($0.value.encodedURIComponent)" }.joined(separator: "&")
    let segment = prefix + inner.encodedURIComponent
    if let index {
        segments[index] = segment
    } else {
        segments.append(segment)
    }
    let joined = segments.filter { !$0.isEmpty }.joined(separator: "&")
    return "\(base)?\(joined)\(fragment)"
}

/// Percent-decodes a query value, `+` as a space (as `URLSearchParams` reads
/// it). A value that is not valid percent-encoding is kept as written.
private func formDecode(_ value: String) -> String {
    let spaced = value.replacingOccurrences(of: "+", with: " ")
    return spaced.removingPercentEncoding ?? spaced
}
