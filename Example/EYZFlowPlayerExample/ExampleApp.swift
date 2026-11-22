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
    // Launch with EYZFLOW_END_SCREEN_IDS set to prefill the end screen.
    @AppStorage("endScreenIDs") private var endScreenIDs = ProcessInfo.processInfo.environment["EYZFLOW_END_SCREEN_IDS"] ?? ""
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
                    field("End screen stream IDs (comma-separated; the first is Up next)", text: $endScreenIDs)
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
        .task {
            // Values from the launch environment win over the saved ones.
            let environment = ProcessInfo.processInfo.environment
            if let value = environment["EYZFLOW_STREAM_ID"] { streamID = value }
            if let value = environment["EYZFLOW_START_AT"] { startAt = value }
            if let value = environment["EYZFLOW_END_SCREEN_IDS"] { endScreenIDs = value }
            // Launch with EYZFLOW_AUTOPLAY=1 to play at once, for device checks.
            guard ProcessInfo.processInfo.environment["EYZFLOW_AUTOPLAY"] == "1", !streamID.trimmed.isEmpty else { return }
            try? await Task.sleep(for: .seconds(1))
            play()
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
            endScreen: endScreen(),
            onLimitReached: { limit in add("limit \(limit.code.wireName)") },
            onLicenseError: { error in add("key refused \(error.code.wireName)") },
            onError: { message in add("error: \(message)") },
            onClose: { add("closed") }
        )
        add("▶ \(id) (\(isFilm ? "film" : "trailer"))")
        EYZFlowPlayer.present(options)
    }

    /// The end screen for the IDs in the field: the first is "Up next", all
    /// of them are in the row. Picks are logged, then played in place.
    private func endScreen() -> EYZFlowEndScreen? {
        let ids = endScreenIDs.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
        guard !ids.isEmpty else { return nil }
        let items = ids.enumerated().map { index, id in
            EndScreenItem(streamID: id, title: "Film \(index + 1)", description: "Stream \(id)", badge: index == 0 ? "Next" : nil)
        }
        return EYZFlowEndScreen(items: items, nextUp: items.first, onSelect: { selection in
            add("end screen: \(selection.autoplay ? "autoplay" : "picked") \(selection.item.streamID)")
        })
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
