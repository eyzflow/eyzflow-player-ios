// The EYZFlow player for iOS, iPadOS and tvOS apps.
//
// `EYZFlowPlayerViewController` (or `EYZFlowPlayer.present(_:from:)`) plays a
// stream full screen in AVKit's player, with FairPlay, AirPlay and Picture in
// Picture; `EYZFlowPlayback` is the same without UI. Both run the EYZFlow rules
// from `EYZFlowPlayerCore`, re-exported here: player key check, playback
// sessions, DRM access token, analytics beats and watch progress.
@_exported import EYZFlowPlayerCore
