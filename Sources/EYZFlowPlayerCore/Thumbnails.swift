import Foundation

/// One preview image: a whole image, or a tile cut from a sprite with
/// `#xywh=x,y,w,h`, shown for `start` up to `end`.
public struct ThumbnailTile: Sendable, Hashable, CustomStringConvertible {
    public var start: Duration
    public var end: Duration
    /// The image URL, resolved against the track's URL.
    public var image: URL
    /// The tile inside `image`, in image pixels; all nil for a whole image.
    public var x: Int?
    public var y: Int?
    public var width: Int?
    public var height: Int?

    public init(start: Duration, end: Duration, image: URL, x: Int? = nil, y: Int? = nil, width: Int? = nil, height: Int? = nil) {
        self.start = start
        self.end = end
        self.image = image
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isSprite: Bool { width != nil && height != nil }

    public var description: String {
        let tile = isSprite ? "#\(x ?? 0),\(y ?? 0),\(width ?? 0),\(height ?? 0)" : ""
        return "ThumbnailTile(\(start)–\(end) \(image.lastPathComponent)\(tile))"
    }
}

/// A WebVTT thumbnail track, as EYZFlow packages one for every stream
/// (`thumbnails/thumbnail.vtt`: a 199×112 tile per 5 seconds, cut from
/// sprite images).
public final class ThumbnailTrack: Sendable {
    /// Sorted by start.
    public let tiles: [ThumbnailTile]

    public init(_ tiles: [ThumbnailTile]) {
        self.tiles = tiles.sorted { $0.start < $1.start }
    }

    public var isEmpty: Bool { tiles.isEmpty }

    /// The tile shown at `position`: the last one starting at or before it.
    /// Past the end the last tile, before the start the first.
    public func at(_ position: Duration) -> ThumbnailTile? {
        guard !tiles.isEmpty else { return nil }
        var low = 0
        var high = tiles.count - 1
        while low < high {
            let mid = (low + high + 1) >> 1
            if tiles[mid].start <= position {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return tiles[low]
    }

    /// Parses a WebVTT thumbnail track. Image URLs are resolved against
    /// `base`, the track's own URL. Cues it cannot read are skipped.
    public static func parse(_ vtt: String, base: URL) -> ThumbnailTrack {
        let lines = vtt
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var tiles: [ThumbnailTile] = []
        var i = 0
        while i < lines.count {
            defer { i += 1 }
            let line = lines[i]
            guard let arrow = line.range(of: "-->") else { continue }
            let afterArrow = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            let endText = afterArrow.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
            guard let start = time(String(line[..<arrow.lowerBound])), let end = time(endText) else {
                continue
            }
            // The payload is the next non-empty line.
            var j = i + 1
            while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                j += 1
            }
            if j >= lines.count { break }
            if let tile = tile(lines[j].trimmingCharacters(in: .whitespaces), base: base, start: start, end: end) {
                tiles.append(tile)
            }
            i = j
        }
        return ThumbnailTrack(tiles)
    }

    private static func tile(_ payload: String, base: URL, start: Duration, end: Duration) -> ThumbnailTile? {
        if payload.isEmpty || payload.contains("-->") { return nil }
        let hash = payload.range(of: "#xywh=")
        let path = hash.map { String(payload[..<$0.lowerBound]) } ?? payload
        guard let image = URL(string: path, relativeTo: base)?.absoluteURL else { return nil }
        guard let hash else { return ThumbnailTile(start: start, end: end, image: image) }
        let parts = payload[hash.upperBound...]
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, parts.allSatisfy({ ($0 ?? -1) >= 0 }) else {
            return ThumbnailTile(start: start, end: end, image: image)
        }
        return ThumbnailTile(start: start, end: end, image: image, x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    /// `hh:mm:ss.mmm` or `mm:ss.mmm`.
    private static func time(_ value: String) -> Duration? {
        let parts = value.trimmingCharacters(in: .whitespaces)
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count >= 2, parts.count <= 3,
              let seconds = Double(parts[parts.count - 1]),
              let minutes = Int(parts[parts.count - 2]),
              let hours = parts.count == 3 ? Int(parts[0]) : 0
        else { return nil }
        let ms = (Double((hours * 3600 + minutes * 60) * 1000) + seconds * 1000).rounded()
        return .milliseconds(Int(ms))
    }
}

/// Loads thumbnail tracks, once per URL. A track that cannot be loaded or
/// parsed loads as nil: the player seeks without previews.
public actor ThumbnailLoader {
    private let http: any HTTPClient
    private var cache: [URL: Task<ThumbnailTrack?, Never>] = [:]

    /// The one the players use.
    public static let shared = ThumbnailLoader()

    public init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    public func load(_ url: URL) async -> ThumbnailTrack? {
        if let pending = cache[url] { return await pending.value }
        let http = self.http
        let task = Task { await Self.fetch(url, http: http) }
        cache[url] = task
        let track = await task.value
        // A failure is not remembered: the next film (or the next try) loads
        // again.
        if track == nil, cache[url] == task { cache[url] = nil }
        return track
    }

    private static func fetch(_ url: URL, http: any HTTPClient) async -> ThumbnailTrack? {
        do {
            let (data, response) = try await http.send(URLRequest(url: url))
            guard response.statusCode == 200, let text = String(data: data, encoding: .utf8) else { return nil }
            let track = ThumbnailTrack.parse(text, base: url)
            return track.isEmpty ? nil : track
        } catch {
            return nil
        }
    }
}
