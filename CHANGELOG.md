# Changelog

## Unreleased

- Skip intro, recap and credits (EYF-215). The signals marked on a stream
  (Stream → Signals) are read from its HLS playlist. While playback is in
  one, a "Skip intro", "Skip recap" or "Skip credits" button shows over the
  player on iPhone and iPad, and AVKit's own skip button on Apple TV. A skip
  lands at the signal's end, never before it. `features.skipButtons: false`
  hides it. The iPhone and iPad button takes the config's theme. Text in en,
  de, fr and nl.
- `skipButtonTypes` (EYF-223): the skip button per signal type, from the
  player config or inline. By default intro, recap and opening credits; no
  "Skip credits" over the closing credits unless `closingCredits: true`.
- New `PlaybackEvent` cases `signalStarted` and `signalEnded`, and
  `EYZFlowPlayerOptions.onSignal`, for offering the next episode at the
  closing credits. An exhaustive `switch` over `PlaybackEvent` needs the two
  new cases. `EYZFlowPlayback.skipSignal()`, `activeSignal` and `config`.
- The stream's playlist is read once per playback for its markers even
  without ads (`loadHLSMarkers`; `loadHLSAdBreaks` reads it too).

## 0.3.0

- Ads on Apple TV, through Google's IMA SDK for tvOS (new dependency,
  `GoogleInteractiveMediaAdsTvOS`, tvOS only), with the same rules as on
  iPhone: the stream's markers, the viewer's plan and targeting, the
  countdown, no ads on AirPlay. During a break the transport bar is off and
  scrubbing locked; a skippable ad's skip button takes the focus;
  Play/Pause pauses the ad, Menu leaves the player.
- IMA's ad display container is created without companion slots on both
  platforms: the tvOS framework lacks `IMACompanionAdSlot`, and an app using
  that initializer failed to link.

## 0.2.0

- Ads on iPhone and iPad through Google IMA, when the player config has
  `features.ads` on and an `ads.adTagUrl` (from `configID`, or the new
  `config` option); otherwise no ad request at all. Apple TV plays no ads.
- Ad breaks at the stream's SCTE-35 markers (Stream → Signals → Ad break),
  read from its HLS playlist: a marker at the start is a pre-roll, the others
  mid-rolls when playback reaches them, each once, none when passed by
  seeking; markers win over a VMAP's own schedule. Streams without markers
  follow the tag (VAST pre-roll, or a VMAP's pre-, mid- and post-rolls).
- Ads follow the viewer's plan: the playback session's `ads` and
  `ad_targeting` (`PlaybackCoordinator.planAds` / `adTargeting`). `ads: false`
  makes no ad request at all (no pre-roll, no mid-rolls), whatever the
  config says; `true` or no answer (an older backend, no session) leaves it
  to the config. The targeting goes into the tag's `cust_params`, the tag's
  own values winning (`adTagForPlayback(configTag:planAds:targeting:)`,
  `adTagWithTargeting(_:_:)`). Clear streams (trailers) now open a playback
  session too when there is a `storefrontID` and `drmAuthorization`, so the
  plan's stream limits count them.
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
