# EYZFlowPlayer

The EYZFlow video player for iOS and tvOS apps, as a Swift package.

This first version holds the player's EYZFlow side, without UI: the rules the
EYZFlow web player and the Flutter package `eyzflow_player` follow against
`https://api.eyzflow.com`, ported one to one so native Apple apps behave the
same:

- the **player key check** (`POST /v1/player/license`) and its renewal,
- **playback sessions** for the plan's stream and device limits,
- the **DRM access token** (the `access-token` header the licence servers read),
- the **device id**,
- **playback quality analytics** ("beats", `POST /v1/player/beat`),
- **player configs** from the dashboard (`GET /v1/player-configs/{id}`),
- **WebVTT thumbnail tracks** for scrubbing previews,
- the **stream source** model and its derived stream and DRM URLs,
- and the **playback coordinator** that runs all of it in the web player's
  order around one playback.

Requirements: iOS 16, tvOS 16, Swift 6 (language mode 6). macOS 13 is listed
only so `swift test` runs on a Mac. No third-party dependencies.

## Install

```swift
.package(url: "https://github.com/eyzflow/eyzflow-player-ios", branch: "main"),
// …
.product(name: "EYZFlowPlayer", package: "EYZFlowPlayer"),
```

```swift
import EYZFlowPlayer
```

## Targets

| Target | What |
| --- | --- |
| `EYZFlowPlayerCore` | Foundation only (no UIKit, no AVFoundation). Everything below. |
| `EYZFlowPlayer` | The library product. Re-exports `EYZFlowPlayerCore`; the AVKit player will live here. |
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

## Still to come

The player itself, built in this package on AVKit:

- playback in `AVPlayerViewController`,
- FairPlay through `AVContentKeySession` (certificate and licence URLs from
  `EYZFlowSource`, the coordinator's access header on licence
  requests),
- AirPlay and Picture in Picture from AVKit,
- tvOS scrubbing previews from the streams' I-frame playlists,
- Google Cast later (receiver app id `A534F914`).

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
