import Foundation

/// A Siri Remote button, as the Apple TV ad screen sees it.
public enum AdBreakRemoteButton: Sendable, Equatable {
    case menu
    case playPause
    case select
    /// Arrows, swipes and the rest: left to the focus engine.
    case other
}

/// What a Siri Remote press does during an ad break on Apple TV, for the
/// presses no focused item (such as IMA's skip button) handled. Kept apart
/// from UIKit so it can be tested.
public enum AdBreakRemoteAction: Sendable, Equatable {
    /// Menu: leave the player, as Menu does outside an ad (the playback
    /// closes and the ad with it).
    case leave
    /// Play/Pause: pause or resume the ad, never the content underneath.
    case togglePause
    /// Select with nothing focused: nothing. No click-through on Apple TV,
    /// and the content underneath stays paused.
    case ignore

    /// The action for `button`; nil passes the press on.
    public init?(_ button: AdBreakRemoteButton) {
        switch button {
        case .menu: self = .leave
        case .playPause: self = .togglePause
        case .select: self = .ignore
        case .other: return nil
        }
    }
}
