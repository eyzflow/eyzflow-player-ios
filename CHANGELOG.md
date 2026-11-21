# Changelog

## 0.1.0

First release.

- `EYZFlowPlayer.present(_:from:)` and `EYZFlowPlayerViewController`: EYZFlow
  streams full screen in AVKit's player on iPhone, iPad and Apple TV, with
  FairPlay, AirPlay, Picture in Picture, resume, and the limit and key error
  screens. `EYZFlowPlayback` is the same without UI.
- Chromecast on iPhone and iPad to the EYZFlow Cast receiver, with no Google
  Cast SDK: a Cast button, a casting screen, and the hand-over at the current
  position in both directions.
- The EYZFlow rules, the same as the web player and the Flutter package
  `eyzflow_player`: the player key check, playback sessions for stream and
  device limits, playback quality analytics, and watch progress for films
  (`WatchProgressStore`).
- `Example/`: a loader app for iPhone, iPad and Apple TV.
