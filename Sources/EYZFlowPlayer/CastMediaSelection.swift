#if os(iOS) || os(tvOS)
import AVFoundation
import EYZFlowPlayerCore

@MainActor
extension AVPlayerItem {
    private func language(of option: AVMediaSelectionOption) -> String? {
        option.extendedLanguageTag ?? option.locale?.identifier
    }

    func castTracks(audioGroup: AVMediaSelectionGroup?, subtitleGroup: AVMediaSelectionGroup?) -> CastTrackSelection {
        let selection = currentMediaSelection
        var tracks = CastTrackSelection()
        if let audioGroup, let audio = selection.selectedMediaOption(in: audioGroup) {
            tracks.audioLanguage = language(of: audio)
        }
        if let subtitleGroup {
            if let text = selection.selectedMediaOption(in: subtitleGroup) {
                if let tag = language(of: text) { tracks.subtitles = .language(tag) }
            } else {
                tracks.subtitles = .off
            }
        }
        return tracks
    }

    func restoreCastTracks(_ tracks: CastTrackSelection, audioGroup: AVMediaSelectionGroup?, subtitleGroup: AVMediaSelectionGroup?) {
        func select(_ tag: String?, in group: AVMediaSelectionGroup?) {
            guard let tag, let group else { return }
            if let current = currentMediaSelection.selectedMediaOption(in: group),
               CastTrackSelection.matches(tag, language(of: current)) { return }
            if let option = group.options.first(where: { CastTrackSelection.matches(tag, language(of: $0)) }) {
                self.select(option, in: group)
            }
        }
        select(tracks.audioLanguage, in: audioGroup)
        switch tracks.subtitles {
        case .unspecified: break
        case .off:
            if let subtitleGroup { self.select(nil, in: subtitleGroup) }
        case .language(let tag): select(tag, in: subtitleGroup)
        }
    }
}
#endif
