# Changelog

## Unreleased

- Ads on iPhone and iPad through Google IMA, when the player config has
  `features.ads` on and an `ads.adTagUrl` (from `configID`, or the new
  `config` option); otherwise no ad request at all. Apple TV plays no ads.
- Ad breaks at the stream's SCTE-35 markers (Stream → Signals → Ad break),
  read from its HLS playlist: a marker at the start is a pre-roll, the others
  mid-rolls when playback reaches them, each once, none when passed by
  seeking; markers win over a VMAP's own schedule. Streams without markers
  follow the tag (VAST pre-roll, or a VMAP's pre-, mid- and post-rolls).
- AVKit's controls and the Cast button are off during an ad; no ads on
  AirPlay; casting hands back without repeating played breaks.
- `PlaybackEvent.adBreakStarted` and `.adBreakEnded` (new cases: a `switch`
  over `PlaybackEvent` needs them); analytics leave ad time out of played,
  paused and startup time (`BeatCollector.beginAd()` / `endAd()`).
- New dependency: Google's `GoogleInteractiveMediaAds` (iOS only).
- A countdown before each mid-roll, "Ad in 5" … "Ad in 1" (en, de, fr, nl),
  when ads play for the viewer: at the markers, or a VMAP's mid-roll cue
  points on streams without them. `features.adCountdown: false` turns it off
  (missing is on); `EYZFlowPlayback.showsAdCountdown` changes it while
  playing.
- The countdown's length from the config's `ads.countdownSeconds` (1–30,
  rounded and clamped; 5 when missing); `EYZFlowPlayback.adCountdownLength`
  changes it while playing.

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
