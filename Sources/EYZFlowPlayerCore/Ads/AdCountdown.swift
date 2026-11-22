import Foundation

/// The notice before a mid-roll ("Ad in 5" … "Ad in 1"): its maths and its
/// text, free of UIKit and AVFoundation.
///
/// The same rules as the web player's `ad-countdown.ts`.
public enum AdCountdown {
    /// How many seconds before a mid-roll the notice counts down, unless the
    /// config's `ads.countdownSeconds` says otherwise.
    public static let defaultLength = 5
    /// The longest countdown a config may ask for.
    public static let maxLength = 30

    /// The countdown's length for the config's `ads.countdownSeconds`:
    /// rounded and clamped to 1…30, or 5 when missing or not a number.
    public static func length(_ configured: Double?) -> Int {
        guard let configured, configured.isFinite else { return defaultLength }
        return Int(min(Double(maxLength), max(1, configured.rounded())))
    }

    /// The whole seconds left (`length` … 1, rounded up) until the nearest
    /// break start ahead of `position`, or nil when none is within `length`
    /// seconds. A break at or behind the playhead (reached, or seeked past)
    /// is not counted towards.
    public static func seconds(
        at position: Duration,
        breakStarts: [Duration],
        length: Int = defaultLength
    ) -> Int? {
        guard let next = breakStarts.filter({ $0 > position }).min() else { return nil }
        let left = next - position
        guard left > .zero, left <= .seconds(length) else { return nil }
        let millis = left.inMilliseconds
        return max(1, (millis + 999) / 1000)
    }

    /// The notice, in the viewer's language: en, de, fr or nl, English for
    /// any other. `language` is a BCP 47 tag such as `de-DE`; nil reads the
    /// device's first preferred language.
    public static func label(_ seconds: Int, language: String? = nil) -> String {
        let tag = language ?? Locale.preferredLanguages.first ?? "en"
        let code = tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? "en"
        switch code {
        case "de": return "Werbung in \(seconds)"
        case "fr": return "Publicité dans \(seconds)"
        case "nl": return "Reclame over \(seconds)"
        default: return "Ad in \(seconds)"
        }
    }
}

/// The mid-roll cue points of a VMAP tag, on a stream without ad break
/// markers (IMA plays those breaks itself). IMA's `adCuePoints` give 0 for
/// the pre-roll and -1 for the post-roll: neither is counted down to.
///
/// A cue point counts as passed once playback runs through it, so its
/// countdown does not come back after a rewind: IMA plays each break once.
/// One seeked over is not passed.
public struct AdCuePointSchedule: Sendable, Equatable {
    private var starts: [Duration] = []
    private var passed: Set<Duration> = []

    public init(_ cuePoints: [Duration] = []) {
        set(cuePoints)
    }

    /// The tag's cue points; mid-rolls only are kept.
    public mutating func set(_ cuePoints: [Duration]) {
        starts = cuePoints.filter { $0 > adPrerollWindow }.sorted()
    }

    /// Playback moved from `previous` to `current`: cue points played
    /// through are passed, not ones seeked over.
    public mutating func pass(from previous: Duration, to current: Duration) {
        let step = current - previous
        guard step > .zero, step <= adMaxPlayStep else { return }
        for start in starts where start > previous && start <= current {
            passed.insert(start)
        }
    }

    /// The mid-roll cue points not passed yet, in order.
    public var upcoming: [Duration] { starts.filter { !passed.contains($0) } }
}
