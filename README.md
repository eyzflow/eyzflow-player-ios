# EYZFlowPlayer

The EYZFlow video player for iOS and tvOS apps, as a Swift package.

It plays EYZFlow streams full screen in AVKit's own player, with the EYZFlow
rules built in, the same as the EYZFlow web player and the Flutter package
[`eyzflow_player`](https://pub.dev/packages/eyzflow_player):

- **FairPlay** through `AVContentKeySession`, with the viewer's DRM access token,
- **AirPlay**, **Picture in Picture**, subtitle and audio menus from AVKit, and
  on Apple TV the scrubbing previews from the streams' I-frame playlists,
- the **player key check** (`POST /v1/player/license`) and its renewal,
- **playback sessions** for the plan's stream and device limits, with the
  same messages as the web and Flutter players,
- **playback quality analytics** ("beats", `POST /v1/player/beat`),
- **watch progress** for films, saved where the app says.

Requirements: iOS 16, iPadOS 16, tvOS 16, Swift 6. No third-party
dependencies.

## Install

```swift
.package(url: "https://github.com/eyzflow/eyzflow-player-ios", branch: "main"),
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
analytics on, opens the playback session for a protected stream with a
storefront (a limit fails; another error plays on), and builds the access
header. While playing it renews the player token (a refusal stops playback only
when the organisation enforces), heartbeats the session (ended elsewhere stops
playback) and sends beats. A playback error whose text names a licence or limit
code (`DEVICE_LIMIT`, `APP_NOT_ALLOWED`, …) fails with that code.

`PlaybackEvent` cases: `ready`, `started`, `paused`, `resumed`,
`seeked(from:)`, `bufferingStarted`, `bufferingEnded`, `error(message:)`,
`audioTrackChanged(language:)`, `subtitleTrackChanged(language:)`,
`completed`, `closed`; each with `sourceId`, `position` and `duration`.

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

- Google Cast. The EYZFlow Cast receiver (`A534F914`) is ready; the sender
  side needs Google's Cast SDK.
- Player configs (`configID`) are loaded for the key check but do not style
  AVKit's player.

## Example

`Example/EYZFlowPlayerExample.xcodeproj` is a loader app for iPhone, iPad and
Apple TV: a stream id, the viewer's token, a storefront and a player key, and
a log of every playback event. For a device, put your Apple team in
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
