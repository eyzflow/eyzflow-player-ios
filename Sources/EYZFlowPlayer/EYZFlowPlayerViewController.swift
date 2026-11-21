#if os(iOS) || os(tvOS)
import AVKit
import EYZFlowPlayerCore
import UIKit

/// The EYZFlow player, full screen. Present it, or call
/// [`EYZFlowPlayer.present(_:from:)`]:
///
/// ```swift
/// let player = EYZFlowPlayerViewController(options: EYZFlowPlayerOptions(
///     streamID: streamID,
///     title: "Film",
///     sourceType: .film(catalogueID: catalogueID),
///     drmAuthorization: "Bearer \(viewerToken)",
///     storefrontID: storefrontID
/// ))
/// present(player, animated: true)
/// ```
///
/// It shows a spinner while the key check and playback session run, then
/// AVKit's own player (controls, AirPlay, Picture in Picture, subtitles and
/// audio menus, and on Apple TV the scrubbing previews), and a message with a
/// Close button when playback is refused or fails. Closing it (AVKit's close
/// button, Menu on Apple TV) ends the playback.
@MainActor
public final class EYZFlowPlayerViewController: UIViewController {
    public let playback: EYZFlowPlayback

    private var playerController: AVPlayerViewController?
    private var appeared = false
    private var playerShown = false
    private var finished = false
    private var pictureInPictureActive = false
    private var restoringFromPictureInPicture = false
    private var backgroundToken: (any NSObjectProtocol)?

    private let spinner = UIActivityIndicatorView(style: .large)
    private let messageLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    public init(options: EYZFlowPlayerOptions) {
        playback = EYZFlowPlayback(options: options)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildViews()
        playback.onStateChange = { [weak self] state in self?.render(state) }
        render(playback.state)
        backgroundToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.playback.didEnterBackground() }
        }
        Task { await playback.start() }
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !finished else { return }
        appeared = true
        guard let playerController, playerShown else {
            // First appearance: the stream may be ready already.
            if playback.state == .playing { presentPlayer() }
            return
        }
        // Visible again under a player AVKit dismissed.
        guard playerController.presentingViewController == nil, presentedViewController == nil else { return }
        if restoringFromPictureInPicture { return }
        if pictureInPictureActive {
            // The film plays on in the floating window; give the app back.
            PictureInPictureKeeper.keep(self)
            dismiss(animated: false)
            return
        }
        // Closed by the viewer.
        finish()
    }

    #if os(iOS)
    override public var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    #endif

    // MARK: State

    private func render(_ state: EYZFlowPlayback.State) {
        switch state {
        case .loading:
            spinner.startAnimating()
            messageLabel.isHidden = true
            closeButton.isHidden = false
        case .playing:
            spinner.stopAnimating()
            messageLabel.isHidden = true
            closeButton.isHidden = false
            // Only once this screen is on: presenting during its own
            // presentation is refused.
            if appeared { presentPlayer() }
        case .failed(let message):
            spinner.stopAnimating()
            messageLabel.text = message
            messageLabel.isHidden = false
            closeButton.isHidden = false
            if let presented = presentedViewController {
                presented.dismiss(animated: true)
            }
            playerController = nil
            playerShown = false
        case .closed:
            spinner.stopAnimating()
        }
    }

    private func presentPlayer() {
        guard !finished, appeared, presentedViewController == nil, let player = playback.player else { return }
        let controller = playerController ?? makePlayerController(player)
        playerController = controller
        present(controller, animated: false) { [weak self] in
            // From here on, this screen showing again means AVKit's player
            // was dismissed.
            self?.playerShown = true
        }
    }

    private func makePlayerController(_ player: AVPlayer) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.delegate = self
        controller.modalPresentationStyle = .fullScreen
        #if os(iOS)
            controller.allowsPictureInPicturePlayback = true
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            controller.entersFullScreenWhenPlaybackBegins = false
        #endif
        return controller
    }

    /// Closes the player: playback ended and the screen dismissed.
    private func finish() {
        guard !finished else { return }
        finished = true
        PictureInPictureKeeper.release(self)
        if let backgroundToken { NotificationCenter.default.removeObserver(backgroundToken) }
        let onClose = playback.options.onClose
        Task {
            await playback.close()
            if presentingViewController != nil {
                dismiss(animated: true)
            }
            onClose?()
        }
    }

    @objc private func closeTapped() {
        finish()
    }

    // MARK: Views

    private func buildViews() {
        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        messageLabel.textColor = .white
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.font = .preferredFont(forTextStyle: .headline)
        messageLabel.isHidden = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageLabel)

        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "xmark")
        configuration.baseForegroundColor = .white
        closeButton.configuration = configuration
        closeButton.accessibilityLabel = NSLocalizedString("Close", comment: "Closes the player")
        closeButton.addTarget(self, action: #selector(closeTapped), for: .primaryActionTriggered)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 32),
            messageLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -32),
            closeButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            closeButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8),
        ])
    }
}

// MARK: - AVPlayerViewControllerDelegate

extension EYZFlowPlayerViewController: AVPlayerViewControllerDelegate {
    #if os(iOS)
    public nonisolated func playerViewControllerWillStartPictureInPicture(_ controller: AVPlayerViewController) {
        MainActor.assumeIsolated { pictureInPictureActive = true }
    }

    public nonisolated func playerViewControllerDidStopPictureInPicture(_ controller: AVPlayerViewController) {
        MainActor.assumeIsolated {
            pictureInPictureActive = false
            if restoringFromPictureInPicture {
                restoringFromPictureInPicture = false
            } else if presentingViewController == nil {
                // The floating window was closed without returning to the app's
                // player: the playback ends.
                finish()
            }
        }
    }

    public nonisolated func playerViewController(
        _ controller: AVPlayerViewController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        let completion = Unchecked(completionHandler)
        MainActor.assumeIsolated {
            restoringFromPictureInPicture = true
            guard let host = Self.topViewController() else {
                completion.value(false)
                return
            }
            if presentingViewController == nil {
                host.present(self, animated: false) { [self] in
                    present(controller, animated: true) { completion.value(true) }
                }
            } else if controller.presentingViewController == nil {
                present(controller, animated: true) { completion.value(true) }
            } else {
                completion.value(true)
            }
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
    #endif
}

/// Keeps a player alive while it plays only in the Picture in Picture window,
/// with its screen dismissed.
@MainActor
enum PictureInPictureKeeper {
    private static var players: [ObjectIdentifier: EYZFlowPlayerViewController] = [:]

    static func keep(_ player: EYZFlowPlayerViewController) {
        players[ObjectIdentifier(player)] = player
    }

    static func release(_ player: EYZFlowPlayerViewController) {
        players[ObjectIdentifier(player)] = nil
    }
}

/// Presents the EYZFlow player full screen.
@MainActor
public enum EYZFlowPlayer {
    /// Presents a player for `options` from `presenter`, or from the key
    /// window's top view controller. Returns it, or nil with no window.
    @discardableResult
    public static func present(
        _ options: EYZFlowPlayerOptions,
        from presenter: UIViewController? = nil
    ) -> EYZFlowPlayerViewController? {
        let player = EYZFlowPlayerViewController(options: options)
        let host = presenter ?? {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
            var top = window?.rootViewController
            while let presented = top?.presentedViewController { top = presented }
            return top
        }()
        guard let host else { return nil }
        host.present(player, animated: true)
        return player
    }
}
#endif
