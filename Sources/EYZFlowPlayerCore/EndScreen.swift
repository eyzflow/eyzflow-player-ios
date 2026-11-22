import Foundation

/// A film or episode the end screen offers. The app supplies them; the player
/// plays `streamID` in place when it is picked.
public struct EndScreenItem: Sendable, Hashable, Identifiable {
    public var streamID: String
    public var title: String
    /// Shown 16:9.
    public var poster: URL?
    public var description: String?
    public var duration: Duration?
    /// A short tag over the poster, e.g. "New" or "S1 E2".
    public var badge: String?
    /// How it plays when picked. Nil: the same kind as the stream playing (a
    /// film plays with FairPlay, its progress recorded against `streamID`).
    public var sourceType: EYZFlowSourceType?
    /// Anything the app wants back in `onSelect`.
    public var userInfo: [String: JSONValue]

    public var id: String { streamID }

    public init(
        streamID: String,
        title: String,
        poster: URL? = nil,
        description: String? = nil,
        duration: Duration? = nil,
        badge: String? = nil,
        sourceType: EYZFlowSourceType? = nil,
        userInfo: [String: JSONValue] = [:]
    ) {
        self.streamID = streamID
        self.title = title
        self.poster = poster
        self.description = description
        self.duration = duration
        self.badge = badge
        self.sourceType = sourceType
        self.userInfo = userInfo
    }
}

/// When the end screen shows: from the closing credits (else at the end), or
/// only at the end.
public enum EndScreenShowAt: String, Sendable, Hashable {
    case credits
    case end
}

/// The config's end screen settings (`features.endScreen`). The items come
/// from the app.
public struct PlayerEndScreenConfig: Sendable, Hashable {
    /// Seconds the "Up next" countdown runs, 0…30; 0 is no countdown. Nil: 10.
    public var autoplaySeconds: Int?
    /// Nil: `.credits`.
    public var showAt: EndScreenShowAt?
    /// Nil: on.
    public var shrinkVideo: Bool?
    /// On a stream without a closing credits signal, the end screen shows this
    /// many seconds before the end, as at the credits (0…120; 0: only when the
    /// film ends). Nil: 20.
    public var secondsBeforeEnd: Int?

    public init(autoplaySeconds: Int? = nil, showAt: EndScreenShowAt? = nil, shrinkVideo: Bool? = nil, secondsBeforeEnd: Int? = nil) {
        self.autoplaySeconds = autoplaySeconds
        self.showAt = showAt
        self.shrinkVideo = shrinkVideo
        self.secondsBeforeEnd = secondsBeforeEnd
    }

    public init(json: [String: JSONValue]) {
        self.init(
            autoplaySeconds: endScreenSeconds(json["autoplaySeconds"], max: endScreenAutoplayMaxSeconds),
            showAt: json["showAt"]?.stringValue.flatMap(EndScreenShowAt.init(rawValue:)),
            shrinkVideo: json["shrinkVideo"]?.boolValue,
            secondsBeforeEnd: endScreenSeconds(json["secondsBeforeEnd"], max: endScreenBeforeEndMaxSeconds)
        )
    }

    /// `patch`'s values over these.
    public func merged(with patch: PlayerEndScreenConfig?) -> PlayerEndScreenConfig {
        guard let patch else { return self }
        return PlayerEndScreenConfig(
            autoplaySeconds: patch.autoplaySeconds ?? autoplaySeconds,
            showAt: patch.showAt ?? showAt,
            shrinkVideo: patch.shrinkVideo ?? shrinkVideo,
            secondsBeforeEnd: patch.secondsBeforeEnd ?? secondsBeforeEnd
        )
    }

    public var json: JSONValue {
        var out: [String: JSONValue] = [:]
        if let autoplaySeconds { out["autoplaySeconds"] = .int(autoplaySeconds) }
        if let showAt { out["showAt"] = .string(showAt.rawValue) }
        if let shrinkVideo { out["shrinkVideo"] = .bool(shrinkVideo) }
        if let secondsBeforeEnd { out["secondsBeforeEnd"] = .int(secondsBeforeEnd) }
        return .object(out)
    }
}

public let endScreenAutoplayDefaultSeconds = 10
public let endScreenAutoplayMaxSeconds = 30
public let endScreenBeforeEndDefaultSeconds = 20
public let endScreenBeforeEndMaxSeconds = 120

/// A whole number of seconds from 0 to `max`, or nil for a missing value or
/// one that is not a number.
func endScreenSeconds(_ value: JSONValue?, max: Int) -> Int? {
    guard let number = value?.numberValue, number.isFinite else { return nil }
    return Swift.min(max, Swift.max(0, Int(number.rounded())))
}

func endScreenSeconds(_ value: Int?, max: Int) -> Int? {
    value.map { Swift.min(max, Swift.max(0, $0)) }
}

/// The end screen as one player shows it: the app's values over the config.
public struct EndScreenSettings: Sendable, Hashable {
    public var enabled: Bool
    public var autoplaySeconds: Int
    public var showAt: EndScreenShowAt
    public var shrinkVideo: Bool
    public var secondsBeforeEnd: Int

    public init(enabled: Bool, autoplaySeconds: Int, showAt: EndScreenShowAt, shrinkVideo: Bool, secondsBeforeEnd: Int) {
        self.enabled = enabled
        self.autoplaySeconds = autoplaySeconds
        self.showAt = showAt
        self.shrinkVideo = shrinkVideo
        self.secondsBeforeEnd = secondsBeforeEnd
    }

    /// On only with something to show (items or a next stream),
    /// `features.endScreen` not false, and the app not switching it off. The
    /// app's values (`app`) over the config's.
    public static func resolve(
        config: PlayerConfig,
        hasContent: Bool,
        enabled: Bool = true,
        app: PlayerEndScreenConfig = PlayerEndScreenConfig()
    ) -> EndScreenSettings {
        let remote = config.endScreen ?? PlayerEndScreenConfig()
        return EndScreenSettings(
            enabled: hasContent && config.features.endScreen && enabled,
            autoplaySeconds: endScreenSeconds(app.autoplaySeconds, max: endScreenAutoplayMaxSeconds)
                ?? remote.autoplaySeconds ?? endScreenAutoplayDefaultSeconds,
            showAt: app.showAt ?? remote.showAt ?? .credits,
            shrinkVideo: app.shrinkVideo ?? remote.shrinkVideo ?? true,
            secondsBeforeEnd: endScreenSeconds(app.secondsBeforeEnd, max: endScreenBeforeEndMaxSeconds)
                ?? remote.secondsBeforeEnd ?? endScreenBeforeEndDefaultSeconds
        )
    }
}

/// When the end screen shows.
public enum EndScreenPhase: String, Sendable, Hashable {
    case credits
    case ended
}

/// Over the closing credits; on a stream without them (`hasClosingCredits`
/// false) the last `secondsBeforeEnd` seconds count as the credits. After the
/// end, or in its last second (credits that run to the end leave their
/// signal a moment before the end is reported). Or not now.
public func endScreenPhase(
    _ settings: EndScreenSettings,
    signal: StreamSignal?,
    position: Duration?,
    duration: Duration?,
    ended: Bool,
    hasClosingCredits: Bool
) -> EndScreenPhase? {
    guard settings.enabled else { return nil }
    let atEnd: Bool = {
        if ended { return true }
        guard let position, let duration, duration > .zero else { return false }
        return position >= duration - .seconds(1)
    }()
    if atEnd { return .ended }
    guard settings.showAt == .credits else { return nil }
    if signal?.type == .closingCredits { return .credits }
    if !hasClosingCredits, settings.secondsBeforeEnd > 0, let position, let duration, duration > .zero,
       position >= duration - .seconds(settings.secondsBeforeEnd) {
        return .credits
    }
    return nil
}

/// "1 h 32 min", "45 min"; empty for a missing or very short length.
public func formatRuntime(_ duration: Duration?) -> String {
    guard let duration, duration >= .seconds(60) else { return "" }
    let minutes = Int((duration.inSecondsDouble / 60).rounded())
    let h = minutes / 60
    let m = minutes % 60
    if h == 0 { return "\(m) min" }
    return m == 0 ? "\(h) h" : "\(h) h \(m) min"
}

/// The end screen's texts in the viewer's language (en, de, fr, nl; English
/// otherwise).
public struct EndScreenLabels: Sendable {
    public var upNext: String
    public var play: String
    public var cancel: String
    public var moreLikeThis: String
    public var backToCredits: String
    private var nextInFormat: @Sendable (Int) -> String

    public func nextIn(_ seconds: Int) -> String { nextInFormat(seconds) }

    public init(language: String? = nil) {
        let tag = language ?? Locale.preferredLanguages.first ?? "en"
        let code = tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? "en"
        switch code {
        case "de":
            upNext = "Als Nächstes"; play = "Abspielen"; cancel = "Abbrechen"
            moreLikeThis = "Ähnliche Titel"; backToCredits = "Zurück zum Abspann"
            nextInFormat = { "Weiter in \($0)" }
        case "fr":
            upNext = "À suivre"; play = "Lecture"; cancel = "Annuler"
            moreLikeThis = "Titres similaires"; backToCredits = "Revenir au générique"
            nextInFormat = { "Suite dans \($0)" }
        case "nl":
            upNext = "Hierna"; play = "Afspelen"; cancel = "Annuleren"
            moreLikeThis = "Meer zoals dit"; backToCredits = "Terug naar de aftiteling"
            nextInFormat = { "Volgende over \($0)" }
        default:
            upNext = "Up next"; play = "Play"; cancel = "Cancel"
            moreLikeThis = "More like this"; backToCredits = "Back to credits"
            nextInFormat = { "Next in \($0)" }
        }
    }
}
