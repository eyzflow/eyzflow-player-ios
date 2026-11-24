#if os(iOS)
import Testing
import UIKit
@testable import EYZFlowPlayer

@MainActor
struct CastButtonTests {
    private final class ControlsOwner: UIViewController {
        var controlsHidden = false
        override var prefersStatusBarHidden: Bool { controlsHidden }
    }

    @Test("Cast follows full-screen controls after discovery, dismissal and remount")
    func followsControls() async throws {
        let owner = ControlsOwner()
        let window = UIWindow()
        let button = CastButton(type: .system)
        owner.controlsHidden = true
        button.controlsOwner = owner
        button.isHidden = true
        window.addSubview(button)

        // Discovery finishes while the controls are already hidden.
        button.isHidden = false
        #expect(button.alpha == 0)
        #expect(!button.isUserInteractionEnabled)
        #expect(button.accessibilityElementsHidden)

        func waitForOpacity(_ value: CGFloat) async throws {
            let deadline = ContinuousClock.now + .seconds(2)
            while button.alpha != value && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(button.alpha == value)
        }
        owner.controlsHidden = false
        try await waitForOpacity(1)
        #expect(button.isUserInteractionEnabled)
        #expect(!button.accessibilityElementsHidden)
        owner.controlsHidden = true
        try await waitForOpacity(0)
        #expect(!button.isUserInteractionEnabled)

        // An ad or an active cast still takes precedence when native controls return.
        button.isHidden = true
        owner.controlsHidden = false
        #expect(button.isHidden)
        button.isHidden = false
        #expect(button.alpha == 1)

        button.removeFromSuperview()
        let next = ControlsOwner()
        next.controlsHidden = true
        button.controlsOwner = next
        window.addSubview(button)
        #expect(button.alpha == 0)
        button.removeFromSuperview()
    }

    @Test("Cast sits one row below AVKit's top bar, in line with its trailing button")
    func placement() {
        // iPhone portrait: the bar starts at the safe area's top, 21 pt in.
        let portrait = CastButton.placement(
            safeArea: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0),
            idiom: .phone, verticalSizeClass: .regular)
        #expect(portrait.top == 118) // 62 + 44 + 12
        #expect(portrait.trailing == 21)

        // iPhone landscape: no top inset, AVKit runs inside the side safe area.
        let landscape = CastButton.placement(
            safeArea: UIEdgeInsets(top: 0, left: 62, bottom: 20, right: 62),
            idiom: .phone, verticalSizeClass: .compact)
        #expect(landscape.top == 80) // 24 + 44 + 12
        #expect(landscape.trailing == 37)

        let iPad = CastButton.placement(
            safeArea: UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0),
            idiom: .pad, verticalSizeClass: .regular)
        #expect(iPad.top == 88) // 24 + 8 + 44 + 12
        #expect(iPad.trailing == 10)

        // Before iOS 26, landscape keeps the earlier place.
        let older = CastButton.placement(
            safeArea: UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59),
            idiom: .phone, verticalSizeClass: .compact, measuredLayout: false)
        #expect(older.top == 64)
        #expect(older.trailing == 75) // 59 + 16
    }

    @Test("The Cast icon is a template image, so it takes the button's tint")
    func icon() {
        let icon = CastButton.castIcon()
        #expect(icon.size == CGSize(width: 24, height: 24))
        #expect(icon.renderingMode == .alwaysTemplate)

        let button = CastButton(type: .system)
        button.applyStyle()
        #expect(button.configuration?.image != nil)
        #expect(button.configuration?.cornerStyle == .capsule)
    }
}
#endif
