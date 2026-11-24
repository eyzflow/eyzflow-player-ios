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
    private var topConstraint: NSLayoutConstraint?
    private var trailingConstraint: NSLayoutConstraint?

    /// AVKit's round buttons are 44 pt.
    nonisolated static let size: CGFloat = 44

    /// A round button with the Google Cast icon, like AVKit's own buttons.
    func applyStyle() {
        var configuration: UIButton.Configuration
        #if compiler(>=6.2)
            if #available(iOS 26, *) {
                configuration = .glass()
            } else {
                configuration = Self.filledConfiguration()
            }
        #else
            configuration = Self.filledConfiguration()
        #endif
        configuration.image = Self.castIcon()
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        configuration.contentInsets = .zero
        self.configuration = configuration
        // AVKit's controls are dark whatever the app's appearance.
        overrideUserInterfaceStyle = .dark
    }

    private static func filledConfiguration() -> UIButton.Configuration {
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = UIColor(white: 0, alpha: 0.45)
        return configuration
    }

    /// Adds the button to AVKit's view, under the trailing end of its top bar.
    func pin(in view: UIView) {
        removeFromSuperview()
        translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(self)
        let top = topAnchor.constraint(equalTo: view.topAnchor)
        let trailing = view.trailingAnchor.constraint(equalTo: trailingAnchor)
        NSLayoutConstraint.activate([
            top, trailing,
            widthAnchor.constraint(equalToConstant: Self.size),
            heightAnchor.constraint(equalToConstant: Self.size),
        ])
        topConstraint = top
        trailingConstraint = trailing
        updatePlacement()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updatePlacement()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updatePlacement()
    }

    private func updatePlacement() {
        guard let superview, let topConstraint, let trailingConstraint else { return }
        let placement = Self.placement(
            safeArea: superview.safeAreaInsets,
            idiom: traitCollection.userInterfaceIdiom,
            verticalSizeClass: traitCollection.verticalSizeClass,
            measuredLayout: Self.hasMeasuredLayout
        )
        if topConstraint.constant != placement.top { topConstraint.constant = placement.top }
        if trailingConstraint.constant != placement.trailing { trailingConstraint.constant = placement.trailing }
    }

    /// AVKit's margins below are measured on iOS 26.
    private static var hasMeasuredLayout: Bool {
        if #available(iOS 26, *) { return true }
        return false
    }

    /// Where the button sits: one row below AVKit's top bar, in line with its
    /// trailing button (the volume control). AVKit has no API for its bar's
    /// frame, so these are its measured margins on iOS 26:
    /// - iPhone portrait: the bar starts at the safe area's top, 21 pt in.
    /// - iPhone landscape: 24 pt down and 37 pt in, inside the safe area.
    /// - iPad: 8 pt below the safe area's top, 10 pt in.
    /// Before iOS 26 only iPhone portrait was checked; landscape and iPad keep
    /// the earlier place, 64 pt below the safe area's top and 16 pt in.
    nonisolated static func placement(
        safeArea: UIEdgeInsets,
        idiom: UIUserInterfaceIdiom,
        verticalSizeClass: UIUserInterfaceSizeClass,
        measuredLayout: Bool = true
    ) -> (top: CGFloat, trailing: CGFloat) {
        let portraitPhone = idiom != .pad && verticalSizeClass != .compact
        if !measuredLayout && !portraitPhone {
            return (safeArea.top + 64, safeArea.right + 16)
        }
        let barTop: CGFloat
        let trailing: CGFloat
        if idiom == .pad {
            barTop = safeArea.top + 8
            trailing = safeArea.right + 10
        } else if verticalSizeClass == .compact {
            barTop = max(safeArea.top, 24)
            trailing = 37
        } else {
            barTop = safeArea.top
            trailing = max(safeArea.right, 21)
        }
        let gap: CGFloat = 12
        return (barTop + size + gap, trailing)
    }

    /// The Google Cast icon (a screen with waves in its corner), drawn as a
    /// template image. SF Symbols has no Cast symbol.
    nonisolated static func castIcon(pointSize: CGFloat = 24) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: pointSize, height: pointSize), format: format)
        let image = renderer.image { context in
            // Drawn on Material's 24-unit grid.
            context.cgContext.scaleBy(x: pointSize / 24, y: pointSize / 24)
            UIColor.black.set()

            let screen = UIBezierPath()
            screen.move(to: CGPoint(x: 2, y: 8))
            screen.addLine(to: CGPoint(x: 2, y: 5))
            screen.addArc(withCenter: CGPoint(x: 3, y: 5), radius: 1, startAngle: .pi, endAngle: -.pi / 2, clockwise: true)
            screen.addLine(to: CGPoint(x: 21, y: 4))
            screen.addArc(withCenter: CGPoint(x: 21, y: 5), radius: 1, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
            screen.addLine(to: CGPoint(x: 22, y: 19))
            screen.addArc(withCenter: CGPoint(x: 21, y: 19), radius: 1, startAngle: 0, endAngle: .pi / 2, clockwise: true)
            screen.addLine(to: CGPoint(x: 14, y: 20))
            screen.lineWidth = 2
            screen.stroke()

            let corner = CGPoint(x: 1, y: 21)
            for radius: CGFloat in [6, 10] {
                let wave = UIBezierPath(arcCenter: corner, radius: radius, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
                wave.lineWidth = 2
                wave.stroke()
            }
            let dot = UIBezierPath()
            dot.move(to: corner)
            dot.addArc(withCenter: corner, radius: 3, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
            dot.close()
            dot.fill()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

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
