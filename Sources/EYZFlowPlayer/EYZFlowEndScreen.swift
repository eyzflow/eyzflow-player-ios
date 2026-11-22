import EYZFlowPlayerCore
import Foundation
#if os(iOS) || os(tvOS)
import UIKit
#endif

/// The built-in end screen: "Up next" with a countdown and a row of films the
/// app passes, over the closing credits (the video moved into a corner) or
/// after the film. A picked film plays in place, with its own key check,
/// session and FairPlay. The player config's `features.endScreen` and
/// `endScreen` settings apply where `settings` leaves them out.
public struct EYZFlowEndScreen: Sendable {
    /// The row of films.
    public var items: [EndScreenItem]
    /// The next stream: "Up next", played when its countdown reaches 0.
    public var nextUp: EndScreenItem?
    /// The row's heading; "More like this" in the viewer's language by default.
    public var title: String?
    /// `autoplaySeconds`, `showAt`, `shrinkVideo` and `secondsBeforeEnd`,
    /// over the config's.
    public var settings: PlayerEndScreenConfig
    /// False turns it off for this player, over the config.
    public var enabled: Bool
    /// Hears every pick before the player plays it in place; call
    /// `preventDefault()` to handle it yourself.
    public var onSelect: (@MainActor @Sendable (EndScreenSelection) -> Void)?

    public init(
        items: [EndScreenItem] = [],
        nextUp: EndScreenItem? = nil,
        title: String? = nil,
        settings: PlayerEndScreenConfig = PlayerEndScreenConfig(),
        enabled: Bool = true,
        onSelect: (@MainActor @Sendable (EndScreenSelection) -> Void)? = nil
    ) {
        self.items = items
        self.nextUp = nextUp
        self.title = title
        self.settings = settings
        self.enabled = enabled
        self.onSelect = onSelect
    }

    /// Something to show: films or a next stream.
    public var hasContent: Bool { !items.isEmpty || nextUp != nil }
}

/// The viewer (or the "Up next" countdown) picked an item.
@MainActor
public final class EndScreenSelection {
    public let item: EndScreenItem
    /// Picked by the countdown reaching 0, not by the viewer.
    public let autoplay: Bool
    public private(set) var isPrevented = false

    init(item: EndScreenItem, autoplay: Bool) {
        self.item = item
        self.autoplay = autoplay
    }

    /// The player does not play the item itself: the app handles it.
    public func preventDefault() {
        isPrevented = true
    }
}

#if os(iOS) || os(tvOS)
/// What an app's overlay can do to playback.
@MainActor
public struct EYZFlowOverlayControls {
    /// Jumps to the end of the signal playback is in.
    public let skip: () -> Void
    public let seek: (Duration) -> Void
    public let play: () -> Void
    public let pause: () -> Void
    /// Hides the overlay until playback enters another signal or the film ends.
    public let dismiss: () -> Void
}

/// The moment an app's overlay is asked for.
@MainActor
public struct EYZFlowOverlayContext {
    /// The intro, recap or credits signal playback is in; nil after the end.
    public let signal: StreamSignal?
    /// The film played to its end.
    public let ended: Bool
    public let controls: EYZFlowOverlayControls
}

/// The app's own view controller over the player at a signal or after the
/// end, presented over AVKit's player; nil shows nothing. It wins over the
/// end screen.
public typealias EYZFlowOverlayProvider = @MainActor @Sendable (EYZFlowOverlayContext) -> UIViewController?
#endif
