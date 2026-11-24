#if os(iOS)
import UIKit

/// AVKit changes its full-screen status bar preference when its controls appear
/// or disappear. iOS has no transport-bar visibility delegate callback.
@MainActor
final class CastButton: UIButton {
    weak var controlsOwner: UIViewController? {
        didSet { updateMonitoring() }
    }

    // Discovery, casting and ads determine eligibility. Alpha follows the native controls.
    override var isHidden: Bool {
        didSet {
            if isHidden != oldValue { updateMonitoring() }
        }
    }

    private var displayLink: CADisplayLink?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateMonitoring()
    }

    private func updateMonitoring() {
        guard window != nil, controlsOwner != nil, !isHidden else {
            displayLink?.invalidate()
            displayLink = nil
            return
        }
        updateVisibility(animated: false)
        guard displayLink == nil else { return }
        // This computed UIKit preference does not send KVO notifications.
        let link = CADisplayLink(target: self, selector: #selector(syncWithControls))
        link.preferredFramesPerSecond = 10
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func syncWithControls() {
        updateVisibility(animated: true)
    }

    private func updateVisibility(animated: Bool) {
        guard let controlsOwner else { return }
        let visible = !controlsOwner.prefersStatusBarHidden
        let opacity: CGFloat = visible ? 1 : 0
        guard alpha != opacity else { return }
        isUserInteractionEnabled = visible
        accessibilityElementsHidden = !visible
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.alpha = opacity
            }
        } else {
            alpha = opacity
        }
    }
}
#endif
