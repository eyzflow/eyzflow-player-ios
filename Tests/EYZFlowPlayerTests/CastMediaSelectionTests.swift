#if os(iOS) || os(tvOS)
import AVFoundation
import EYZFlowPlayerCore
import Testing
@testable import EYZFlowPlayer

@MainActor
@Suite("AVPlayer Cast handoff")
struct CastMediaSelectionTests {
    @Test("AVPlayer selections survive remounting, including subtitles off and unmatched audio")
    func roundTrip() async throws {
        // The offline MP4 contains silent English and German audio and timed text in both languages.
        let url = try #require(Bundle.module.url(forResource: "tracks", withExtension: "mp4", subdirectory: "Fixtures"))
        let outgoing = AVPlayerItem(url: url)
        let audio = try #require(try await outgoing.asset.loadMediaSelectionGroup(for: .audible))
        let text = try #require(try await outgoing.asset.loadMediaSelectionGroup(for: .legible))
        let german = try #require(audio.options.first { $0.extendedLanguageTag == "de" })
        let english = try #require(text.options.first { $0.extendedLanguageTag == "en" })
        outgoing.select(german, in: audio)
        outgoing.select(english, in: text)
        let sent = outgoing.castTracks(audioGroup: audio, subtitleGroup: text)
        #expect(sent == .init(audioLanguage: "de", subtitles: .language("en")))
        #expect(outgoing.castTracks(audioGroup: audio, subtitleGroup: nil).subtitles == .unspecified)

        let returning = AVPlayerItem(url: url)
        let newAudio = try #require(try await returning.asset.loadMediaSelectionGroup(for: .audible))
        let newText = try #require(try await returning.asset.loadMediaSelectionGroup(for: .legible))
        returning.restoreCastTracks(sent, audioGroup: newAudio, subtitleGroup: newText)
        #expect(returning.castTracks(audioGroup: newAudio, subtitleGroup: newText) == sent)

        returning.restoreCastTracks(.init(audioLanguage: "eng", subtitles: .language("deu")),
                                    audioGroup: newAudio, subtitleGroup: newText)
        #expect(returning.castTracks(audioGroup: newAudio, subtitleGroup: newText)
                == .init(audioLanguage: "en", subtitles: .language("de")))
        returning.restoreCastTracks(.init(audioLanguage: "ja", subtitles: .off),
                                    audioGroup: newAudio, subtitleGroup: newText)
        #expect(returning.castTracks(audioGroup: newAudio, subtitleGroup: newText)
                == .init(audioLanguage: "en", subtitles: .off))
    }
}
#endif
