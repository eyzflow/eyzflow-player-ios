#if os(iOS)
import EYZFlowPlayerCore
import Testing
import UIKit
@testable import EYZFlowPlayer

@MainActor
@Suite("Cast track menu")
struct CastingViewTests {
    @Test("the phone shows receiver tracks and checks Off only when confirmed")
    func selection() throws {
        let view = CastingView()
        let tv = CastTarget(id: "1", name: "TV", host: "localhost")
        let playback = CastPlayback().updated(with: [
            "media": ["tracks": [
                ["trackId": 2, "type": "AUDIO", "name": "English 5.1"],
                ["trackId": 5, "type": "TEXT", "name": "Deutsch"],
            ]],
        ])
        view.render(.active(tv, playback))
        func findMenuButton(in view: UIView) -> UIButton? {
            if let button = view as? UIButton, button.menu != nil { return button }
            return view.subviews.lazy.compactMap { findMenuButton(in: $0) }.first
        }
        let button = try #require(findMenuButton(in: view))
        func actions() -> [UIAction] {
            (button.menu?.children as? [UIMenu] ?? []).flatMap { $0.children.compactMap { $0 as? UIAction } }
        }
        #expect(actions().map(\.title) == ["English 5.1", NSLocalizedString("Off", comment: ""), "Deutsch"])
        #expect(actions().allSatisfy { $0.state == .off })
        view.render(.active(tv, playback.updated(with: ["activeTrackIds": [2]])))
        #expect(actions().map(\.state) == [.on, .on, .off])

        var selected: Int?
        view.onTrackSelected = { kind, id in
            #expect(kind == .subtitles)
            selected = id
        }
        let german = try #require(actions().last)
        UIButton(primaryAction: german).sendActions(for: .primaryActionTriggered)
        #expect(selected == 5)
        view.render(.off)
        #expect(button.isHidden)
    }
}
#endif
