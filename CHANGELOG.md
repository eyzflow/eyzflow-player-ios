# Changelog

## Unreleased

### Added

- `EYZFlowPlayer`: the AVKit player. `EYZFlowPlayerViewController` and
  `EYZFlowPlayer.present(_:from:)` play a stream full screen in
  `AVPlayerViewController` with FairPlay (`AVContentKeySession`), AirPlay,
  Picture in Picture, resume and the limit and key error screens;
  `EYZFlowPlayback` is the same without UI.
- `PlaybackEventTracker`: the player's state turned into `PlaybackEvent`s,
  which feed the beats and `EYZFlowPlayerOptions.onEvent`.
- `WatchProgressStore` and `WatchProgressRecorder`: a film's watch progress.
- `FairPlayLicenseFormat`: the FairPlay licence wire format.
- `Example/`: a loader app for iPhone, iPad and Apple TV.
- `EYZFlowPlayerCore`: the EYZFlow playback rules, ported from the Flutter
  package `eyzflow_player`: player key check and renewal, playback
  sessions, DRM access token, device id (`UserDefaults`, `eyzflow.deviceId`),
  analytics beats, player configs, WebVTT thumbnail tracks, the stream source
  model, and `PlaybackCoordinator` with `PlaybackEvent`.
- Tests ported from the Flutter package (Swift Testing).
