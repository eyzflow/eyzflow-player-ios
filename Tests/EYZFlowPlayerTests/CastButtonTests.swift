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
}
#endif
