import EYZFlowPlayer
import SwiftUI

@main
struct ExampleApp: App {
    var body: some Scene {
        WindowGroup {
            LoaderView()
        }
    }
}

/// A loader for `EYZFlowPlayer`: a stream, the viewer's credentials and an
/// optional player key; Play presents the player full screen. The log shows
/// every playback event, limit and refusal.
struct LoaderView: View {
    // Launch with EYZFLOW_STREAM_ID set to prefill the stream.
    @AppStorage("streamID") private var streamID = ProcessInfo.processInfo.environment["EYZFLOW_STREAM_ID"] ?? ""
    @AppStorage("title") private var title = ""
    @AppStorage("isFilm") private var isFilm = true
    @AppStorage("catalogueID") private var catalogueID = ""
    @AppStorage("authorization") private var authorization = ""
    @AppStorage("storefrontID") private var storefrontID = ""
    @AppStorage("playerKey") private var playerKey = ""
    @AppStorage("startAt") private var startAt = ""
    // Launch with EYZFLOW_AD_TAG set to prefill the ad tag.
    @AppStorage("adTag") private var adTag = ProcessInfo.processInfo.environment["EYZFLOW_AD_TAG"] ?? ""
    @AppStorage("configID") private var configID = ""
    @State private var log: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $isFilm) {
                        Text("Film").tag(true)
                        Text("Trailer").tag(false)
                    }
                    field("Stream ID", text: $streamID)
                    field("Title", text: $title)
                    if isFilm {
                        field("Catalogue ID (for watch progress)", text: $catalogueID)
                        field("DRM authorization (Cognito token or raw value)", text: $authorization)
                        field("Storefront ID (stream and device limits)", text: $storefrontID)
                        field("Start at (seconds)", text: $startAt)
                    }
                    field("Player key (pk_…)", text: $playerKey)
                    field("Player config (cfg_…)", text: $configID)
                    field("Ad tag URL (VAST or VMAP; turns ads on)", text: $adTag)
                    Button("Play", action: play)
                        .disabled(streamID.trimmed.isEmpty)
                }
                Section("Log") {
                    ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("EYZFlow Player")
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
    }

    private func play() {
        let id = streamID.trimmed
        let token = authorization.trimmed
        // A viewer's Cognito token (a JWT) goes out as "Bearer …" with a
        // storefront session; any other value as it is, with neither.
        let isViewerToken = token.hasPrefix("eyJ")
        let options = EYZFlowPlayerOptions(
            streamID: id,
            title: title.trimmed.isEmpty ? id : title.trimmed,
            sourceType: isFilm
                ? .film(catalogueID: catalogueID.trimmed.isEmpty ? id : catalogueID.trimmed)
                : .trailer(catalogueID: id),
            progressSeconds: Double(startAt.trimmed),
            playerKey: playerKey.trimmed.nilIfEmpty,
            configID: configID.trimmed.nilIfEmpty,
            config: adTag.trimmed.isEmpty ? nil : PlayerConfigOverride(
                features: PlayerFeaturesOverride(ads: true),
                ads: PlayerAdsConfig(adTagURL: adTag.trimmed)
            ),
            drmAuthorization: token.isEmpty ? nil : (isViewerToken ? "Bearer \(token)" : token),
            storefrontID: isViewerToken ? storefrontID.trimmed.nilIfEmpty : nil,
            drmParameters: isViewerToken ? ["source": "internal"] : [:],
            deviceName: "Example \(PlayerPlatform.current.wireName)",
            onEvent: { event in add(event.description) },
            onLimitReached: { limit in add("limit \(limit.code.wireName)") },
            onLicenseError: { error in add("key refused \(error.code.wireName)") },
            onError: { message in add("error: \(message)") },
            onClose: { add("closed") }
        )
        add("▶ \(id) (\(isFilm ? "film" : "trailer"))")
        EYZFlowPlayer.present(options)
    }

    private func add(_ line: String) {
        let time = Date.now.formatted(date: .omitted, time: .standard)
        log.insert("\(time)  \(line)", at: 0)
        NSLog("[example] %@", line)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
