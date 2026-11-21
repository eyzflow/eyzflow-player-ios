import Foundation

/// What kind of playback an [`EYZFlowSource`] is: a trailer (never
/// DRM-protected) or a film (played with FairPlay and the source's
/// `drmAccessHeader`). The Flutter package's `EyzflowTrailer` / `EyzflowFilm`.
public enum EYZFlowSourceType: Sendable, Hashable {
    /// A trailer, identified by its own catalogue id.
    case trailer(catalogueID: String)
    /// A film, identified by its catalogue id (the key for watch progress).
    case film(catalogueID: String)

    /// The catalogue identity behind this source type.
    public var catalogueID: String {
        switch self {
        case .trailer(let id), .film(let id): id
        }
    }

    /// Whether the source plays with DRM (and so a playback session).
    public var isProtected: Bool {
        if case .film = self { return true }
        return false
    }
}

/// What to play, and the stream and DRM URLs derived from its id. The
/// Flutter package's `EyzflowSource` (same fields, same URLs).
public struct EYZFlowSource: Sendable, Hashable {
    /// The stream id.
    public var id: String
    public var title: String
    public var description: String?
    public var poster: URL?
    public var drmAccessHeader: String?
    public var sourceType: EYZFlowSourceType?

    /// Seconds to seek to once the player reports a duration, or nil to start
    /// at the beginning.
    public var progressSeconds: Double?

    public init(
        id: String,
        title: String,
        description: String? = nil,
        poster: URL? = nil,
        drmAccessHeader: String? = nil,
        sourceType: EYZFlowSourceType? = nil,
        progressSeconds: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.poster = poster
        self.drmAccessHeader = drmAccessHeader
        self.sourceType = sourceType
        self.progressSeconds = progressSeconds
    }

    /// `https://stream.eyzflow.com/{id}/master.m3u8`.
    public var hlsStreamURL: URL { Self.url("https://stream.eyzflow.com/\(pathID)/master.m3u8") }

    /// `https://stream.eyzflow.com/{id}/manifest.mpd`.
    public var dashStreamURL: URL { Self.url("https://stream.eyzflow.com/\(pathID)/manifest.mpd") }

    /// `https://stream.eyzflow.com/fps.cer`.
    public var fairplayCertificateURL: URL { Self.url("https://stream.eyzflow.com/fps.cer") }

    /// `https://api.eyzflow.com/v1/drm/{id}/fairplay/acquire`.
    public var fairplayLicenseURL: URL { Self.url("https://api.eyzflow.com/v1/drm/\(pathID)/fairplay/acquire") }

    /// `https://api.eyzflow.com/v1/drm/{id}/widevine/acquire`.
    public var widevineLicenseURL: URL { Self.url("https://api.eyzflow.com/v1/drm/\(pathID)/widevine/acquire") }

    /// `https://stream.eyzflow.com/{id}/thumbnails/thumbnail.vtt`.
    public var thumbnailsURL: URL { Self.url("https://stream.eyzflow.com/\(pathID)/thumbnails/thumbnail.vtt") }

    /// The id, escaped for a URL path segment.
    private var pathID: String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
    }

    private static func url(_ string: String) -> URL {
        // Every string above is an https URL with an escaped path segment.
        URL(string: string)!
    }
}
