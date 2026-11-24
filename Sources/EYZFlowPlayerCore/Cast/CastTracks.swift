import Foundation

public struct CastTrack: Sendable, Equatable {
    public enum Kind: String, Sendable { case audio = "AUDIO", subtitles = "TEXT" }
    public let id: Int
    public let kind: Kind
    public let language: String?
    public let name: String?

    public init(id: Int, kind: Kind, language: String? = nil, name: String? = nil) {
        self.id = id
        self.kind = kind
        self.language = language
        self.name = name
    }

    init?(_ json: JSONValue) {
        guard let id = json["trackId"]?.numberValue.flatMap(Int.init(exactly:)),
              let kind = json["type"]?.stringValue.flatMap(Kind.init(rawValue:)) else { return nil }
        self.init(id: id, kind: kind, language: json["language"]?.stringValue, name: json["name"]?.stringValue)
    }
}

/// Languages survive a handoff between HLS and DASH, whose track IDs are unrelated.
public struct CastTrackSelection: Sendable, Equatable {
    public enum Subtitles: Sendable, Equatable {
        case unspecified, off, language(String)
    }
    public var audioLanguage: String?
    public var subtitles: Subtitles

    public init(audioLanguage: String? = nil, subtitles: Subtitles = .unspecified) {
        self.audioLanguage = audioLanguage
        self.subtitles = subtitles
    }

    // ISO 639-2 bibliographic spellings still used in media manifests.
    private static let bibliographicCodes = [
        "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "chi": "zho",
        "cze": "ces", "dut": "nld", "fre": "fra", "geo": "kat", "ger": "deu",
        "gre": "ell", "ice": "isl", "mac": "mkd", "mao": "mri", "may": "msa",
        "per": "fas", "rum": "ron", "slo": "slk", "tib": "bod", "wel": "cym",
    ]

    package static func matches(_ lhs: String?, _ rhs: String?) -> Bool {
        func base(_ tag: String?) -> String? {
            guard let tag, !tag.isEmpty else { return nil }
            let code = Locale.Language(identifier: tag).languageCode
            if let key = code?.identifier, let alias = bibliographicCodes[key] { return alias }
            guard let base = code?.identifier(.alpha3), base != "und", base != "zxx" else { return nil }
            return base
        }
        guard let left = base(lhs) else { return false }
        return left == base(rhs)
    }

    /// Only confirmed receiver choices replace what the phone was playing.
    public func updated(with playback: CastPlayback) -> Self {
        guard let ids = playback.activeTrackIDs else { return self }
        let active = playback.tracks.filter { ids.contains($0.id) }
        var next = self
        if let audio = active.first(where: { $0.kind == .audio })?.language {
            next.audioLanguage = audio
        }
        if let text = active.first(where: { $0.kind == .subtitles }) {
            if let language = text.language { next.subtitles = .language(language) }
        } else if playback.tracks.contains(where: { $0.kind == .subtitles }) {
            next.subtitles = .off
        }
        return next
    }
}

extension CastPlayback {
    /// Receivers replace the entire list, even when the viewer changes just one track.
    func replacing(_ kind: CastTrack.Kind, with id: Int?, in active: [Int]) -> [Int] {
        let sameKind = Set(tracks.filter { $0.kind == kind }.map(\.id))
        var ids = active.filter { !sameKind.contains($0) }
        if let id { ids.append(id) }
        return ids.sorted()
    }
}
