import Foundation

/// An ad break marked on a stream in the dashboard (Stream → Signals → Ad
/// break). The backend writes each one into the plain HLS media playlists as
/// SCTE-35: an `#EXT-X-DATERANGE` with `SCTE35-OUT`, anchored by
/// `#EXT-X-PROGRAM-DATE-TIME:1970-01-01T00:00:00.000Z` before the first
/// segment, so `START-DATE` minus the anchor is the position in the content.
///
/// Intro and credits signals (`CLASS="com.eyzflow.signal"`) are written next
/// to them and are not ad breaks.
///
/// The same rules as the web player's `ad-breaks.ts` and the Flutter
/// package's `ad_breaks.dart`.
public struct AdBreak: Sendable, Hashable, CustomStringConvertible {
    public var id: String
    /// Position in the content.
    public var start: Duration
    /// The planned length of the ad pod, when the break has one. Not sent to
    /// the ad server: the tag decides the pod.
    public var duration: Duration?

    public init(id: String, start: Duration, duration: Duration? = nil) {
        self.id = id
        self.start = start
        self.duration = duration
    }

    public var description: String { "AdBreak(\(id) at \(start.clockString))" }
}

/// A break at or before this is a pre-roll: it plays before the content
/// starts.
public let adPrerollWindow: Duration = .milliseconds(500)

/// Playback moving further than this between two position reports is a seek
/// or a jump, not playing through: breaks passed that way are not played.
/// The player reports the position every 0.5 s while playing.
public let adMaxPlayStep: Duration = .seconds(2)

/// The class EYZFlow gives its intro and credits DATERANGEs.
private let hlsSpanClass = "com.eyzflow.signal"

/// `KEY=value` and `KEY="quoted, value"` pairs of an HLS attribute list.
func hlsAttributes(_ list: Substring) -> [String: String] {
    var out: [String: String] = [:]
    var rest = list[...]
    while !rest.isEmpty {
        guard let equals = rest.firstIndex(of: "=") else { break }
        let key = rest[..<equals].trimmingCharacters(in: CharacterSet(charactersIn: ", "))
        var after = rest[rest.index(after: equals)...]
        let value: Substring
        if after.first == "\"" {
            after = after.dropFirst()
            let close = after.firstIndex(of: "\"") ?? after.endIndex
            value = after[..<close]
            rest = close < after.endIndex ? after[after.index(after: close)...] : ""
        } else {
            let comma = after.firstIndex(of: ",") ?? after.endIndex
            value = after[..<comma]
            rest = after[comma...]
        }
        if !rest.isEmpty, rest.first == "," { rest = rest.dropFirst() }
        if !key.isEmpty { out[key] = String(value) }
    }
    return out
}

/// An ISO 8601 date with or without fractional seconds.
func parseISODate(_ value: String) -> Date? {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: trimmed) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: trimmed)
}

private func seconds(_ value: String?) -> Duration? {
    guard let value, let s = Double(value), s > 0, s.isFinite else { return nil }
    return .microseconds(Int64((s * 1_000_000).rounded()))
}

private func duration(between start: Date, and anchor: Date) -> Duration {
    .microseconds(Int64((start.timeIntervalSince(anchor) * 1_000_000).rounded()))
}

/// The ad breaks in one HLS playlist (a media playlist; a master playlist
/// carries none, but is read the same way), in order.
///
/// A DATERANGE is an ad break when it has `SCTE35-OUT` (or `SCTE35-CMD`) and
/// is not one of EYZFlow's span signals. Its position is its `START-DATE`
/// minus the first `EXT-X-PROGRAM-DATE-TIME`. Without that anchor a
/// DATERANGE cannot be placed and is skipped.
public func parseHLSAdBreaks(_ playlist: String) -> [AdBreak] {
    var anchor: Date?
    var ranges: [[String: String]] = []
    for raw in playlist.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
            if anchor == nil { anchor = parseISODate(String(line.dropFirst(25))) }
        } else if line.hasPrefix("#EXT-X-DATERANGE:") {
            ranges.append(hlsAttributes(line.dropFirst(17)))
        }
    }
    guard let anchor else { return [] }
    var breaks: [AdBreak] = []
    var seen: Set<String> = []
    for range in ranges {
        if range["CLASS"] == hlsSpanClass { continue }
        guard range["SCTE35-OUT"] != nil || range["SCTE35-CMD"] != nil else { continue }
        guard let startDate = range["START-DATE"].flatMap(parseISODate) else { continue }
        let start = duration(between: startDate, and: anchor)
        if start < .zero { continue }
        let id = range["ID"] ?? "t\(start.inMilliseconds)"
        guard seen.insert(id).inserted else { continue }
        breaks.append(AdBreak(id: id, start: start, duration: seconds(range["PLANNED-DURATION"] ?? range["DURATION"])))
    }
    return breaks.sorted { $0.start < $1.start }
}

/// The media playlists a master playlist points at (video variants first,
/// then audio renditions), resolved against `master`. The backend writes the
/// same markers into each, so the first one is enough.
public func hlsMediaPlaylistURLs(_ masterPlaylist: String, master: URL) -> [URL] {
    let lines = masterPlaylist
        .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    var variants: [URL] = []
    var audio: [URL] = []
    for (i, line) in lines.enumerated() {
        if line.hasPrefix("#EXT-X-STREAM-INF") {
            if let next = lines[(i + 1)...].first(where: { !$0.isEmpty }), !next.hasPrefix("#"),
               let url = URL(string: next, relativeTo: master)?.absoluteURL {
                variants.append(url)
            }
        } else if line.hasPrefix("#EXT-X-MEDIA:") {
            let attributes = hlsAttributes(line.dropFirst(13)[...])
            if attributes["TYPE"] == "AUDIO", let uri = attributes["URI"],
               let url = URL(string: uri, relativeTo: master)?.absoluteURL {
                audio.append(url)
            }
        }
    }
    return variants + audio
}

/// Reads the ad breaks of the HLS stream at `master`, the playlist the player
/// loads: from the master itself and from its first media playlist. A
/// manifest that cannot be loaded gives no breaks; the stream then counts as
/// one without markers.
public func loadHLSAdBreaks(
    http: any HTTPClient = URLSessionHTTPClient(),
    master: URL,
    timeout: Duration = .seconds(5)
) async -> [AdBreak] {
    func get(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout.inSecondsDouble
        guard let (data, response) = try? await http.send(request), response.statusCode == 200 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    guard let body = await get(master) else { return [] }
    let own = parseHLSAdBreaks(body)
    if !own.isEmpty || !body.contains("#EXT-X-STREAM-INF") { return own }
    guard let first = hlsMediaPlaylistURLs(body, master: master).first,
          let playlist = await get(first) else { return [] }
    return parseHLSAdBreaks(playlist)
}

/// The stream's ad breaks, each played at most once per impression.
public struct AdBreakSchedule: Sendable {
    private var byID: [String: AdBreak] = [:]
    private var played: Set<String> = []

    public init(_ breaks: [AdBreak] = []) {
        add(breaks)
    }

    public mutating func add(_ breaks: [AdBreak]) {
        for adBreak in breaks { byID[adBreak.id] = adBreak }
    }

    /// The stream has ad breaks: ads play at them, not where the ad tag
    /// would put them.
    public var hasBreaks: Bool { !byID.isEmpty }

    public var breaks: [AdBreak] { byID.values.sorted { ($0.start, $0.id) < ($1.start, $1.id) } }

    /// Starts of the mid-roll breaks not played yet, in order: what the
    /// countdown before a break counts towards. A break passed by seeking
    /// stays here, as it still plays when playback reaches it later.
    public var upcomingMidrollStarts: [Duration] {
        breaks.filter { $0.start > adPrerollWindow && !played.contains($0.id) }.map(\.start)
    }

    /// The pre-roll break, if the stream has one not yet played; marked as
    /// played.
    public mutating func takePreroll() -> AdBreak? {
        for adBreak in breaks {
            if adBreak.start > adPrerollWindow { break }
            if played.insert(adBreak.id).inserted { return adBreak }
        }
        return nil
    }

    /// The break the playhead reached while playing from `previous` to
    /// `current`, marked as played; nil when none was reached, or when the
    /// move was a seek. With several breaks in one step (rare), only the last
    /// plays, and all of them count as played.
    public mutating func due(from previous: Duration, to current: Duration) -> AdBreak? {
        let step = current - previous
        guard step > .zero, step <= adMaxPlayStep else { return nil }
        var reached: AdBreak?
        for adBreak in breaks where adBreak.start > adPrerollWindow && !played.contains(adBreak.id) {
            if adBreak.start > previous, adBreak.start <= current {
                played.insert(adBreak.id)
                reached = adBreak
            }
        }
        return reached
    }
}
