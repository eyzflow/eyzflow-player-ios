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
- **ads** on iPhone and iPad from the player config, through Google IMA, at
  the stream's ad break markers.

Requirements: iOS 16, iPadOS 16, tvOS 16, Swift 6. One third-party
dependency: Google's
[IMA SDK for iOS](https://github.com/googleads/swift-package-manager-google-interactive-media-ads-ios)
(`GoogleInteractiveMediaAds`, linked on iOS only).

## Install

```swift
.package(url: "https://github.com/eyzflow/eyzflow-player-ios", from: "0.1.0"),
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
  finds one. Casting hands the film over at the current position; the phone
  shows the TV's progress, play/pause, a seek bar and Stop casting, and the
  playback session, analytics and watch progress carry on. Stopping hands
  the film back to the phone where the TV was. `castReceiverAppID: nil`
  turns Chromecast off.
- **Ads:** nothing to add for the player. IMA is a dynamic framework that
  Xcode embeds with the package. If your app asks for tracking
  permission (App Tracking Transparency), ask before playback so IMA can use
  the advertising identifier; otherwise IMA requests ads without it.

### Ads

The player plays ads on iPhone and iPad when its config has **Ads** on and an
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
  in 1", for the last 5 s before each mid-roll (`ads.countdownSeconds` in the
  config sets the length, 1–30; missing or out of range falls back to 5 or
  is clamped; `playback.adCountdownLength` changes it while playing) (never a pre-roll or
  post-roll), in en, de, fr or nl by the device language, English otherwise.
  It counts towards the unplayed markers (a marker passed by seeking gets it
  again when approached later), or on a stream without markers towards a
  VMAP's mid-roll cue points (one played through does not come back after a
  rewind). It hides while paused, seeking, during an ad, on AirPlay or
  casting, and when the viewer seeks past the break. It takes no touches;
  VoiceOver reads it. Only when ads play for the viewer. `features.adCountdown`
  in the config turns it off (`false`); missing means on, for configs saved
  before it. `playback.showsAdCountdown` changes it while playing, without
  reloading the stream.
- Apple TV plays no ads (IMA for tvOS is a separate SDK).
- `EYZFlowPlayback` on its own (an app with its own player UI) plays no
  ads: they need the player screen's ad layer.
- Events: `adBreakStarted` and `adBreakEnded` around each break, including
  one that turns out to have no ad. Analytics count the content only: ad
  time is neither played, paused nor startup time.

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
        platform: .current          // .ios or .tvos
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
| `PlayerPlatform`, `PlayerApp`, `eyzflowPlayerVersion` | What the player says it is (`ios`, `tvos`, …; `ios/0.1.0`). |
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

- Player configs (`configID`) give the key check and the ads, but do not
  style AVKit's player.

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
