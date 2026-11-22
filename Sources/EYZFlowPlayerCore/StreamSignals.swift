import Foundation

/// What an intro, recap or credits signal marked on a stream in the dashboard
/// (Stream → Signals) is. The backend writes each one into every HLS media
/// playlist as
///
///     #EXT-X-DATERANGE:ID="eyz-intro",CLASS="com.eyzflow.signal",
///       START-DATE="1970-01-01T00:00:15.000Z",DURATION=15.000,
///       X-EYZ-TYPE="intro",X-EYZ-LABEL="Main titles"
///
/// anchored by `#EXT-X-PROGRAM-DATE-TIME:1970-01-01T00:00:00.000Z` before the
/// first segment, so `START-DATE` minus the anchor is the position in the
/// content.
///
/// The same rules as the web player's `stream-signals.ts` and the Flutter
/// package's `stream_signals.dart`.
public enum StreamSignalType: String, Sendable, Hashable, CaseIterable {
    case intro
    case recap
    case openingCredits = "opening_credits"
    case closingCredits = "closing_credits"
}

/// One signal: a span of the content the viewer can skip.
public struct StreamSignal: Sendable, Hashable, CustomStringConvertible {
    public var id: String
    public var type: StreamSignalType
    /// Position in the content where the span starts.
    public var start: Duration
    /// Where the span ends: a skip lands here.
    public var end: Duration
    /// The label set in the dashboard, if any. Not shown by the player.
    public var label: String?

    public init(id: String, type: StreamSignalType, start: Duration, end: Duration, label: String? = nil) {
        self.id = id
        self.type = type
        self.start = start
        self.end = end
        self.label = label
    }

    public var description: String {
        "StreamSignal(\(type.rawValue) \(start.clockString)–\(end.clockString)\(label.map { ", \($0)" } ?? ""))"
    }

    /// The skip button's text in `language` (en, de, fr, nl; English
    /// otherwise), by default the device's.
    public func skipLabel(language: String? = nil) -> String {
        let tag = language ?? Locale.preferredLanguages.first ?? "en"
        let code = tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? "en"
        switch (code, type) {
        case ("de", .intro): return "Intro überspringen"
        case ("de", .recap): return "Rückblick überspringen"
        case ("de", .openingCredits): return "Vorspann überspringen"
        case ("de", .closingCredits): return "Abspann überspringen"
        case ("fr", .intro): return "Passer l’intro"
        case ("fr", .recap): return "Passer le récap"
        case ("fr", _): return "Passer le générique"
        case ("nl", .intro): return "Intro overslaan"
        case ("nl", .recap): return "Samenvatting overslaan"
        case ("nl", .openingCredits): return "Begintiteling overslaan"
        case ("nl", .closingCredits): return "Aftiteling overslaan"
        case (_, .intro): return "Skip intro"
        case (_, .recap): return "Skip recap"
        case (_, _): return "Skip credits"
        }
    }
}

/// The class the backend gives its signal DATERANGEs.
public let hlsSignalClass = "com.eyzflow.signal"

/// Playback this close to a span's end counts as past it, so a span that
/// ends at the very end of the film doesn't leave the button up.
public let signalEndSlack: Duration = .milliseconds(250)

private func spanSeconds(_ value: String?) -> Duration? {
    guard let value, let s = Double(value), s > 0, s.isFinite else { return nil }
    return .microseconds(Int64((s * 1_000_000).rounded()))
}

private func offset(of date: Date, from anchor: Date) -> Duration {
    .microseconds(Int64((date.timeIntervalSince(anchor) * 1_000_000).rounded()))
}

/// The signals in one HLS playlist, in order: the `com.eyzflow.signal`
/// DATERANGEs with a known `X-EYZ-TYPE` and a positive `DURATION` (or an
/// `END-DATE`). Without the `EXT-X-PROGRAM-DATE-TIME` anchor nothing can be
/// placed.
public func parseHLSSignals(_ playlist: String) -> [StreamSignal] {
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
    var signals: [StreamSignal] = []
    var seen: Set<String> = []
    for range in ranges where range["CLASS"] == hlsSignalClass {
        guard let type = range["X-EYZ-TYPE"].flatMap(StreamSignalType.init(rawValue:)),
              let startDate = range["START-DATE"].flatMap(parseISODate) else { continue }
        let start = offset(of: startDate, from: anchor)
        if start < .zero { continue }
        let length = spanSeconds(range["DURATION"])
            ?? range["END-DATE"].flatMap(parseISODate).map { offset(of: $0, from: startDate) }
        guard let length, length > .zero else { continue }
        let id = range["ID"] ?? "\(type.rawValue)-\(start.inMilliseconds)"
        guard seen.insert(id).inserted else { continue }
        let label = range["X-EYZ-LABEL"]?.trimmingCharacters(in: .whitespaces)
        signals.append(StreamSignal(
            id: id,
            type: type,
            start: start,
            end: start + length,
            label: label?.isEmpty == false ? label : nil
        ))
    }
    return signals.sorted { $0.start < $1.start }
}

/// The markers of an HLS stream: its ad breaks and its signals.
public struct HLSMarkers: Sendable, Hashable {
    public var adBreaks: [AdBreak]
    public var signals: [StreamSignal]

    public init(adBreaks: [AdBreak] = [], signals: [StreamSignal] = []) {
        self.adBreaks = adBreaks
        self.signals = signals
    }

    public static let none = HLSMarkers()
}

/// Reads the markers of the HLS stream at `master`, the playlist the player
/// loads: from the master itself and, when it has none, from its first media
/// playlist (the backend writes the same markers into each). A manifest that
/// cannot be loaded gives no markers.
public func loadHLSMarkers(
    http: any HTTPClient = URLSessionHTTPClient(),
    master: URL,
    timeout: Duration = .seconds(5)
) async -> HLSMarkers {
    func get(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout.inSecondsDouble
        guard let (data, response) = try? await http.send(request), response.statusCode == 200 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    func parse(_ playlist: String) -> HLSMarkers {
        HLSMarkers(adBreaks: parseHLSAdBreaks(playlist), signals: parseHLSSignals(playlist))
    }
    guard let body = await get(master) else { return .none }
    let own = parse(body)
    if !own.adBreaks.isEmpty || !own.signals.isEmpty || !body.contains("#EXT-X-STREAM-INF") { return own }
    guard let first = hlsMediaPlaylistURLs(body, master: master).first,
          let playlist = await get(first) else { return .none }
    return parse(playlist)
}

/// The signal covering `position`; with overlapping spans, the one that
/// started last.
public func signal(at position: Duration?, in signals: [StreamSignal]) -> StreamSignal? {
    guard let position else { return nil }
    var found: StreamSignal?
    for signal in signals where position >= signal.start && position < signal.end - signalEndSlack {
        if found == nil || signal.start > found!.start { found = signal }
    }
    return found
}

/// The signal playback is in, from the player's position reports. Reports
/// entering and leaving one through `onStarted` and `onEnded` (leaving the
/// old one first when playback moves straight into another).
@MainActor
public final class SignalTracker {
    public var onStarted: (@MainActor (StreamSignal) -> Void)?
    public var onEnded: (@MainActor (StreamSignal) -> Void)?

    /// The signal playback is in, if any.
    public private(set) var current: StreamSignal?

    /// The stream's signals, once read from the playlist.
    public var signals: [StreamSignal] = [] {
        didSet { update() }
    }

    private var position: Duration?
    /// A signal the viewer skipped, and where the skip goes, until a
    /// position report shows the seek landed.
    private var skipped: (signal: StreamSignal, target: Duration)?

    public init() {}

    /// A position report. Nil (no position yet, or the content ended)
    /// leaves any signal.
    public func report(_ position: Duration?) {
        self.position = position
        if let skip = skipped,
           position.map({ $0 >= skip.target - signalEndSlack || $0 < skip.signal.start }) ?? true {
            skipped = nil
        }
        update()
    }

    /// The viewer skipped `signal`: it is left at once and stays left while
    /// the player still reports positions inside it from before the seek to
    /// `target` landed. A report at `target` (or before the signal's start)
    /// ends that.
    public func skip(_ signal: StreamSignal, to target: Duration) {
        skipped = (signal, target)
        update()
    }

    /// Forgets everything, for a new player.
    public func reset() {
        signals = []
        skipped = nil
        report(nil)
    }

    private func update() {
        var next = signal(at: position, in: signals)
        if let candidate = next, candidate.id == skipped?.signal.id { next = nil }
        guard next?.id != current?.id else { return }
        let previous = current
        current = next
        if let previous { onEnded?(previous) }
        if let next { onStarted?(next) }
    }
}

/// A colour as the dashboard stores it in a theme, 0…1 per channel.
public struct CSSColor: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb(r,g,b)` or
    /// `rgba(r,g,b,a)`; nil for anything else. The same formats as the
    /// Flutter package's `parseCssColor`.
    public init?(css value: String) {
        let s = value.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("#") {
            var hex = String(s.dropFirst())
            if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else { return nil }
            let channel = { (shift: UInt64) in Double((v >> shift) & 0xFF) / 255 }
            if hex.count == 6 {
                self.init(red: channel(16), green: channel(8), blue: channel(0))
            } else {
                self.init(red: channel(24), green: channel(16), blue: channel(8), alpha: channel(0))
            }
            return
        }
        guard s.hasPrefix("rgb"), let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")") else { return nil }
        let parts = s[s.index(after: open)..<close].split(separator: ",").map {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard parts.count == 3 || parts.count == 4, parts.allSatisfy({ $0 != nil }) else { return nil }
        let n = parts.map { $0! }
        self.init(
            red: min(max(n[0] / 255, 0), 1),
            green: min(max(n[1] / 255, 0), 1),
            blue: min(max(n[2] / 255, 0), 1),
            alpha: n.count == 4 ? min(max(n[3], 0), 1) : 1
        )
    }
}

/// A theme length such as `10px` (or a bare number), in points; nil for
/// anything else.
public func cssLength(_ value: String) -> Double? {
    var s = value.trimmingCharacters(in: .whitespaces).lowercased()
    if s.hasSuffix("px") { s.removeLast(2) }
    guard let n = Double(s.trimmingCharacters(in: .whitespaces)), n >= 0, n.isFinite else { return nil }
    return n
}
