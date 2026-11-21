// The EYZFlow player for iOS and tvOS apps.
//
// For now this target only re-exports EYZFlowPlayerCore: the EYZFlow rules
// around playback (player key check, playback sessions, DRM access token,
// analytics beats, player configs, thumbnail tracks, and the coordinator that
// runs them in order).
//
// The player itself will be built here on AVKit: AVPlayerViewController,
// FairPlay through AVContentKeySession, AirPlay and Picture in Picture from
// AVKit, tvOS scrubbing previews from the streams' I-frame playlists, and
// Google Cast later.
@_exported import EYZFlowPlayerCore
