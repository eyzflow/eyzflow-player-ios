# Changelog

## Unreleased

### Added

- Chromecast on iPhone and iPad, with no Google Cast SDK: Bonjour discovery,
  the Cast protocol over TLS (`CastChannel`, `NetworkCastBackend`), and
  `CastController` (connect with one retry, load timeout, how casting ends).
  The player shows a Cast button when a TV is found, hands the film to the
  EYZFlow receiver at the current position with the phone's access token,
  shows a casting screen, and takes the film back at the TV's position.
  `EYZFlowPlayerOptions.castReceiverAppID` (default `A534F914`, nil turns it
  off) and `poster`.
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
