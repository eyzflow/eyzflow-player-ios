# EYZFlowPlayer

The EYZFlow video player for iOS and tvOS apps, as a Swift package.

It plays EYZFlow streams full screen in AVKit's own player, with the EYZFlow
rules built in, the same as the EYZFlow web player and the Flutter package
[`eyzflow_player`](https://pub.dev/packages/eyzflow_player):

- **FairPlay** through `AVContentKeySession`, with the viewer's DRM access token,
- **AirPlay**, **Picture in Picture**, subtitle and audio menus from AVKit, and
  on Apple TV the scrubbing previews from the streams' I-frame playlists,
- **Chromecast** on iPhone and iPad, to the EYZFlow Cast receiver, with no
  Google Cast SDK,
- the **player key check** (`POST /v1/player/license`) and its renewal,
- **playback sessions** for the plan's stream and device limits (and whether
  the plan plays ads), with the same messages as the web and Flutter players,
- **playback quality analytics** ("beats", `POST /v1/player/beat`),
- **watch progress** for films, saved where the app says,
- **ads** on iPhone, iPad and Apple TV from the player config, through
  Google IMA, at the stream's ad break markers.

Requirements: iOS 16, iPadOS 16, tvOS 16, Swift 6. One third-party
dependency, Google's IMA SDK, as two packages:
[for iOS](https://github.com/googleads/swift-package-manager-google-interactive-media-ads-ios)
(linked on iOS only) and
[for tvOS](https://github.com/googleads/swift-package-manager-google-interactive-media-ads-tvos)
(`GoogleInteractiveMediaAdsTvOS`, linked on tvOS only). Both frameworks are
the module `GoogleInteractiveMediaAds`.

## Install

```swift
.package(url: "https://github.com/eyzflow/eyzflow-player-ios", from: "0.5.1"),
// …
.product(name: "EYZFlowPlayer", package: "EYZFlowPlayer"),
```

```swift
import EYZFlowPlayer
```

## Use

```swift
EYZFlowPlayer.present(EYZFlowPlayerOptions(
    streamID: streamID,                         // the EYZFlow stream id
    title: "The film",
    sourceType: .film(catalogueID: catalogueID), // .trailer(…) plays without DRM
    progressSeconds: 754,                       // resume, or nil
    playerKey: "pk_…",                          // optional: key check and analytics
    drmAuthorization: "Bearer \(viewerToken)",
    storefrontID: storefrontID,                 // stream and device limits
    offerID: offerID,                           // royalties: the seconds watched
    watchProgressStore: MyWatchHistory(),
    onLimitReached: { limit in /* STREAM_LIMIT, DEVICE_LIMIT, … */ },
    onClose: { /* the viewer closed the player */ }
))
```

Or present `EYZFlowPlayerViewController(options:)` yourself. It shows a
spinner while the key check and the playback session run, then AVKit's
player, and a message with a Close button when playback is refused or fails.
`EYZFlowPlayback` is the same without UI, for an app with its own player
screen: it gives you the `AVPlayer`.

Watch progress goes to a `WatchProgressStore` you implement, for example with
your call to the EYZFlow watch-history API:

```swift
struct MyWatchHistory: WatchProgressStore {
    func save(catalogueID: String, progressSeconds: Double, completed: Bool) async throws {
        try await api.saveProgress(catalogueID, progressSeconds, completed)
    }
}
```

Films save their position every 10 seconds while playing, on a pause, a seek
and when the app leaves, and as completed at the end. Trailers save nothing.

### Royalties

Licensor royalties are counted from the seconds viewers watch. With
`offerID` (the film or episode played), `drmAuthorization` and
`storefrontID`, the player reports them itself to
`POST /v1/content/storefront/{storefrontID}/playback-events`: every 30
seconds while the film plays, at once on a pause, at the end and when the app
goes to the background, and a last time when the player closes. Only time
spent playing the film counts: not ads, pauses, seeks or stalls, while
casting included. Each report carries the seconds since the previous one (at
most 120) and one session id per playback; seconds a report could not
deliver go with the next one. The film's catalogue id goes with it.

Trailers report nothing. It works with or without a player key and
analytics. An app that sends these events itself should stop once it passes
`offerID`, or the seconds are counted twice.

### Host setup

- **Picture in Picture:** add the `audio` background mode
  (`UIBackgroundModes`) to your app. When the viewer starts it, the player
  screen closes and the app is usable while the film plays on; tapping the
  window's restore button brings the player back.
- **Player key:** add your app's bundle id to the key's allowed apps, with the
  platform `ios` or `tvos`.
- **Chromecast:** add to your Info.plist

  ```xml
  <key>NSLocalNetworkUsageDescription</key>
  <string>Finds TVs on your network to play films on.</string>
  <key>NSBonjourServices</key>
  <array><string>_googlecast._tcp</string></array>
  ```

  The player looks for TVs once the film plays (the first time, iOS asks the
  viewer for the Local Network permission) and shows a Cast button when it
  finds one. The button appears and fades with the native playback controls.
  Casting starts at the phone's position and carries over the
  selected audio and subtitle languages when the TV offers them. The phone
  shows progress and controls for play, pause, seeking and track selection.
  Analytics and watch progress continue during casting. Stop casting returns
  to the TV's position with its last confirmed language choices, including
  subtitles off. If the playback session is revoked, the player stops the TV.
  `castReceiverAppID: nil`
  turns Chromecast off.
- **Ads:** nothing to add for the player. IMA is a dynamic framework that
  Xcode embeds with the package. If your app asks for tracking
  permission (App Tracking Transparency), ask before playback so IMA can use
  the advertising identifier; otherwise IMA requests ads without it.

### Ads

The player plays ads on iPhone, iPad and Apple TV when its config has **Ads** on and an
**Ad tag URL** (dashboard: Player → Configs; `features.ads` and
`ads.adTagUrl`), either from `configID` or from `config`, which wins over the
dashboard config:

```swift
EYZFlowPlayerOptions(
    streamID: streamID,
    title: "The film",
    configID: "cfg_…",                       // or, inline:
    config: PlayerConfigOverride(
        features: PlayerFeaturesOverride(ads: true),
        ads: PlayerAdsConfig(adTagURL: "https://pubads.g.doubleclick.net/gampad/ads?…")
    )
)
```

With Ads off, or an empty tag, no ad request is made at all.

**The viewer's plan:** with `storefrontID` and `drmAuthorization`, the
playback session (opened for clear streams too) says whether the viewer's plan
plays ads for the title. `ads: false` means no ads at all, whatever the config
says. `ads: true`, or no answer (an older backend, no session, a failed
request), leaves it to the config. The session's `ad_targeting` key-values
(e.g. `plan=basic-ads`, `access=svod`) go into the tag's `cust_params`; the
tag's own value wins on the same key. The session answers before the pre-roll
is requested.

The tag is a
VAST or VMAP tag, requested through Google IMA, which draws the ad, its
countdown, skip button and click-through over the player.

- **Streams with ad break markers** (Stream → Signals → Ad break; the backend
  writes them into the HLS playlists as SCTE-35 `EXT-X-DATERANGE`s): ads play
  only at the markers. A marker at the start is a pre-roll; every other one
  is a mid-roll, requested from the tag when playback reaches it. Each plays
  once; markers passed by seeking do not play. The markers win over a VMAP's
  own schedule: at a marker only its pre-roll plays (none if it has no
  pre-roll), and its mid-rolls and post-roll never do, so use a VAST tag for
  these streams.
- **Streams without markers** follow the tag: a VAST pre-roll, or a VMAP's
  pre-roll, mid-rolls and post-roll.
- The content waits at a break until the ad starts, at most 12 s; an empty,
  failed or blocked tag lets it play on, with no error.
- During an ad AVKit's controls, Picture in Picture and the Cast button are
  off. No ads play on AirPlay or while casting, and when casting hands the
  film back, neither the pre-roll nor a break already played plays again.
- **Countdown before a mid-roll:** a small corner notice, "Ad in 5" … "Ad
  in 1", for the last seconds before each mid-roll (never a pre-roll or
  post-roll), in en, de, fr or nl by the device language, English otherwise.
  The length is 5 s, or the config's `ads.countdownSeconds` (1–30, rounded
  and clamped); `playback.adCountdownLength` changes it while playing.
  It counts towards the unplayed markers (a marker passed by seeking gets it
  again when approached later), or on a stream without markers towards a
  VMAP's mid-roll cue points (one played through does not come back after a
  rewind). It hides while paused, seeking, during an ad, on AirPlay or
  casting, and when the viewer seeks past the break. It takes no touches;
  VoiceOver reads it. Only when ads play for the viewer. `features.adCountdown`
  in the config turns it off (`false`); missing means on, for configs saved
  before it. `playback.showsAdCountdown` changes it while playing, without
  reloading the stream.
- **Apple TV:** the same rules (markers, the plan, the countdown, no ads
  on AirPlay), through Google's IMA SDK for tvOS. Each break shows on a
  screen presented over AVKit's player, which takes the focus and the
  remote: the transport bar is off and scrubbing is locked during the ad,
  a skippable ad's skip button takes the focus (IMA's `focusEnvironment`),
  Play/Pause pauses or resumes the ad, Select does nothing (no click-through
  on Apple TV), and Menu leaves the player as it does outside an ad. The
  countdown sits in AVKit's content overlay, over the picture and under the
  transport bar, and never takes the focus.
- `EYZFlowPlayback` on its own (an app with its own player UI) plays no
  ads: they need the player screen's ad layer.
- Events: `adBreakStarted` and `adBreakEnded` around each break, including
  one that turns out to have no ad. Analytics count the content only: ad
  time is neither played, paused nor startup time.

### Skip intro, recap and credits

The intro, recap, opening and closing credits marked on a stream in the
dashboard (Stream → Signals) are read from its HLS playlist, in the same
fetch as the ad markers, with or without ads.

- **iPhone and iPad:** while playback is in one, a "Skip intro", "Skip recap"
  or "Skip credits" button shows over the player, above AVKit's bar. A tap
  seeks to the signal's end, never before it (the first keyframe at or
  after it), or to the end of the film, which ends it. It hides during an ad
  break; the ad countdown moves up above it when both show. It takes the
  config's theme: `controlsBarColor`, `textColor` and `borderRadius`.
- **Apple TV:** the same through AVKit's own skip button
  (`contextualActions`), over the transport bar, which the Siri Remote
  focuses.
- Text in en, de, fr or nl by the device language, English otherwise.
- `features.skipButtons: false` in the config hides the button; missing
  means on. The events still come.
- `skipButtonTypes` picks the types with a button (`intro`, `recap`,
  `openingCredits`, `closingCredits`): by default all but the closing
  credits, where skipping only ends the film. Types left out keep their
  default; an inline `PlayerConfigOverride(skipButtonTypes:)` wins per type.
- Events: `signalStarted` and `signalEnded`, with the `StreamSignal` (type,
  start, end, label), and `EYZFlowPlayerOptions.onSignal` (the signal, then
  nil), e.g. to offer the next episode when `.closingCredits` starts.
  `EYZFlowPlayback.skipSignal()` and `activeSignal` are for an app with its
  own player UI.
- The dashboard's `label` is passed on, not shown.

### End screen

Pass films and the next stream, and the player shows a Netflix-like end
screen over the closing credits (the video shrinks into a corner) and after
the film:

```swift
let next = EndScreenItem(streamID: "…", title: "Episode 2", poster: posterURL, duration: .seconds(2700), badge: "S1 E2")
let options = EYZFlowPlayerOptions(
    streamID: streamID,
    title: "Episode 1",
    sourceType: .film(catalogueID: catalogueID),
    endScreen: EYZFlowEndScreen(
        items: [next, similarFilm, otherFilm],
        nextUp: next,
        onSelect: { selection in
            // selection.item, selection.autoplay; preventDefault() to handle it yourself
        }
    )
)
```

- **Up next** counts down (`autoplaySeconds`, 10 by default, 0 for none)
  and plays the next stream; Cancel stops the countdown. Any film in the
  row plays on tap (Apple TV: select).
- A pick plays **in place**, in the same AVKit player: the old playback is
  closed (position saved, last beat, session closed) and the new one runs
  its own key check, session and FairPlay. A film picked during a film
  plays as a film unless the item has its own `sourceType`.
- **When:** over the closing credits signal; on a stream without one, the
  last `secondsBeforeEnd` seconds (20 by default, 0 for only at the end);
  and after the end. `showAt: .end` shows it only after the end.
- **Back:** "Back to credits", a tap on the small video, or Menu on Apple
  TV hides it until the film ends. On iPhone and iPad the close button
  closes the player.
- Remote config: `features.endScreen: false` turns it off; the `endScreen`
  section sets `autoplaySeconds`, `showAt`, `shrinkVideo` and
  `secondsBeforeEnd`. `EYZFlowEndScreen(settings:)` wins over it,
  `enabled: false` turns it off for one player. Without items and a next
  stream nothing shows. Accent and text colours from the theme.
- **Your own overlay:** `options.overlay` is asked at every signal and at
  the end, with the signal and `controls` (skip, seek, play, pause,
  dismiss). The view controller it returns is presented over AVKit's player
  (over full screen unless it sets its own style) and wins over the end
  screen; nil shows the end screen, or nothing.
- Text in en, de, fr or nl.

## Targets

| Target | What |
| --- | --- |
| `EYZFlowPlayerCore` | Foundation only (no UIKit, no AVFoundation). Everything below. |
| `EYZFlowPlayer` | The library product: the AVKit player (`EYZFlowPlayerViewController`, `EYZFlowPlayback`, FairPlay). Re-exports `EYZFlowPlayerCore`. |
| `EYZFlowPlayerCoreTests` | Swift Testing suites, ported from the Flutter package's tests. |

## API

### Playback coordinator

One playback's EYZFlow side. Main-actor isolated, no UI.

```swift
let coordinator = PlaybackCoordinator(
    config: PlaybackCoordinatorConfig(
        streamID: source.id,
        isProtected: source.sourceType?.isProtected ?? false,
        playerKey: "pk_…",
        configID: "cfg_…",
        drmAuthorization: "Bearer \(viewerToken)",
        storefrontID: storefrontID,
        drmParameters: ["source": "internal"],
        deviceName: UIDevice.current.name,
        app: .current,              // PlayerApp(platform: .ios / .tvos, id: bundle id)
        platform: .current,         // .ios or .tvos
        offerID: offerID,           // royalty reports; nil for trailers
        catalogueID: catalogueID
    )
)
coordinator.onLimitReached = { error in … }    // PlaybackLimitError
coordinator.onLicenseError = { error in … }    // PlayerLicenseError
coordinator.onError = { message in … }         // viewer-facing text
coordinator.onStatusChange = { status in … }   // or: for await s in coordinator.statusUpdates()

await coordinator.start()
switch coordinator.status {
case .loading: break
case .ready(let accessHeader): break   // mount the player; send `access-token: accessHeader` with DRM licence requests
case .failed(let failure): break       // show failure.message
}

coordinator.handle(event: .started(sourceId: source.id, position: .zero))   // every PlaybackEvent
coordinator.onBackgrounded()                                                // app went to the background
await coordinator.close()                                                   // final beat, session closed
```

`start()` reads the device id, makes the player key check (a refusal fails;
an unreachable check plays on without a token), starts beats when the key has
analytics on, opens the playback session when there is a storefront and the
viewer's authorization, for clear streams too (a limit fails; another error
plays on; `planAds` and `adTargeting` hold its ads answer), and builds the
access header for a protected stream. While playing it renews the player token (a refusal stops playback only
when the organisation enforces), heartbeats the session (ended elsewhere stops
playback) and sends beats. A playback error whose text names a licence or limit
code (`DEVICE_LIMIT`, `APP_NOT_ALLOWED`, …) fails with that code.

`PlaybackEvent` cases: `ready`, `started`, `paused`, `resumed`,
`seeked(from:)`, `bufferingStarted`, `bufferingEnded`, `error(message:)`,
`audioTrackChanged(language:)`, `subtitleTrackChanged(language:)`,
`adBreakStarted`, `adBreakEnded`, `completed`, `closed`; each with
`sourceId`, `position` and `duration`.

### Clients and models

| Type | Does |
| --- | --- |
| `EYZFlowEndpoints` | API and stream CDN origins (production by default). |
| `PlayerPlatform`, `PlayerApp`, `eyzflowPlayerVersion` | What the player says it is (`ios`, `tvos`, …; `ios/0.5.1`). |
| `PlayerLicenseClient.acquire(_:)`, `PlayerLicenseSession` | Player key check and renewal (at `refresh_after`, never sooner than 10 s, a minute after a failure, a refusal reported once). |
| `PlaybackSessionClient` `open` / `heartbeat` / `close` | Stream and device limits (`X-Device-Id`, `platform`). |
| `buildAccessToken(_:parameters:)` | The DRM `access-token` header. |
| `DeviceIDStore`, `UserDefaultsDeviceIDStore` (`eyzflow.deviceId`), `MemoryDeviceIDStore`, `newUUIDv4()` | Device id. |
| `BeatCollector`, `BeatTransport`, `HTTPBeatSender`, `Beat` | Analytics beats (interval floor 10 s; 2xx, 400, 401 and 413 count as delivered; unsent errors go with the next beat; a final beat on stop). |
| `PlaybackEventAdapter` | Feeds `PlaybackEvent`s into a `BeatCollector`. |
| `PlayerConfig`, `PlayerConfigOverride`, `mergePlayerConfig(_:_:)`, `PlayerConfigClient` | Dashboard configs, merged with an inline override; loaded once per API origin and id, nil (the defaults) on failure or after 5 s. |
| `PlayerConfig.adTagToPlay`, `adTagForPlayback(configTag:planAds:targeting:)`, `adTagWithTargeting(_:_:)`, `PlayerAds`, `AdBreakScheduler`, `AdDriver` | The ad gate (the config and the viewer's plan), the tag's `cust_params` targeting, and when ads play (IMA-free; the player's IMA driver does the SDK work). |
| `AdCountdown`, `AdCuePointSchedule` | The countdown before a mid-roll: seconds left (5 … 1) to the nearest break ahead, a VMAP's mid-roll cue points, and the notice's text. |
| `AdBreak`, `AdBreakSchedule`, `parseHLSAdBreaks(_:)`, `loadHLSAdBreaks(http:master:)` | Ad break markers from the HLS playlists; each played once, none passed by seeking. |
| `ThumbnailTrack`, `ThumbnailLoader` | WebVTT thumbnail tracks, `at(position)`, loaded once per URL. |
| `EYZFlowSource`, `EYZFlowSourceType` | The stream source: id, title, poster, DRM header, film or trailer, progress, and its HLS, DASH, FairPlay, Widevine and thumbnail URLs. |
| `HTTPClient`, `URLSessionHTTPClient` | The network, behind a protocol. |
| `PlaybackScheduler`, `TaskScheduler`, `MonotonicClock` | The timers and clock, injectable for tests. |

Untyped JSON (DRM parameters, limit details) is a `JSONValue`, read field by
field as the Dart and web players do, so a missing or mistyped field falls back
instead of failing.

## Where it comes from

The same rules as the EYZFlow web player and the Flutter package
[`eyzflow_player`](https://pub.dev/packages/eyzflow_player): wire formats,
defaults, codes and viewer messages are the same, and the tests use the same
fixtures and expectations.

## Not yet

- Player configs (`configID`) give the key check, the ads and the skip
  button's look, but do not style AVKit's player.

## Example

`Example/EYZFlowPlayerExample.xcodeproj` is a loader app for iPhone, iPad and
Apple TV: a stream id, the viewer's token, a storefront and a player key, and
a log of every playback event, and an Ad tag URL field that turns ads on
(Google's sample tags work). The launch environment can fill it in:
`EYZFLOW_STREAM_ID`, `EYZFLOW_AD_TAG`, and `EYZFLOW_AUTOPLAY=1` to play at once.
For a device, put your Apple team in
`Example/Config/Team.xcconfig` (git-ignored): `DEVELOPMENT_TEAM = <team id>`.

## Develop

```sh
swift build
swift test
xcodebuild -scheme EYZFlowPlayer -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme EYZFlowPlayer -destination 'generic/platform=tvOS Simulator' build
```

The tvOS build needs the tvOS simulator runtime (Xcode → Settings →
Components). Without it, SwiftPM builds against the SDK directly:

```sh
swift build --sdk "$(xcrun --sdk appletvsimulator --show-sdk-path)" --triple arm64-apple-tvos16.0-simulator
```

## Licence

MIT, see `LICENSE`.
