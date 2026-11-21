# Changelog

## Unreleased

### Added

- `EYZFlowPlayerCore`: the EYZFlow playback rules, ported from the Flutter
  package `eyzflow_player`: player key check and renewal, playback
  sessions, DRM access token, device id (`UserDefaults`, `eyzflow.deviceId`),
  analytics beats, player configs, WebVTT thumbnail tracks, the stream source
  model, and `PlaybackCoordinator` with `PlaybackEvent`.
- `EYZFlowPlayer`: the library product, re-exporting the core until the AVKit
  player is added.
- Tests ported from the Flutter package (Swift Testing).
