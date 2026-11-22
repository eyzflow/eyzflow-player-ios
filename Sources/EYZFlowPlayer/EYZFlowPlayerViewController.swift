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

    #if os(iOS)
    /// Chromecast: nil when the options turn it off.
    private var cast: CastController?
    private var castScanned = false
    private let castButton = UIButton(type: .system)
    private let castingView = CastingView()

    /// IMA draws ads here, over AVKit's player. It lets every touch through
    /// outside an ad break.
    private let adView = UIView()
    private let adSpinner = UIActivityIndicatorView(style: .large)
    #endif

    #if os(tvOS) && canImport(GoogleInteractiveMediaAds)
    /// IMA draws ads here: a screen presented over AVKit's player for each
    /// ad break. It takes the focus (a skip button) and the remote's presses,
    /// so the transport bar cannot move the content under the ad.
    private let adScreen = AdBreakViewController()
    private var adScreenTransitioning = false
    #endif

    #if canImport(GoogleInteractiveMediaAds)
    private var inAdBreak = false
    /// "Ad in 5" … "Ad in 1" before a mid-roll, in a corner over the player.
    private let adCountdownView = AdCountdownView()
    #endif

    public init(options: EYZFlowPlayerOptions) {
        playback = EYZFlowPlayback(options: options)
        #if os(iOS)
            if options.castReceiverAppID != nil {
                cast = CastController(backend: NetworkCastBackend())
            }
        #endif
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        #if canImport(GoogleInteractiveMediaAds)
            playback.adHost = self
        #endif
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
        #if os(iOS)
            setUpCast()
        #endif
        Task { await playback.start() }
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !finished else { return }
        appeared = true
        // AVKit's player was dismissed to hand playback to a TV.
        if playback.state == .casting { return }
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
            #if os(iOS)
                castingView.isHidden = true
                scanForCastDevicesOnce()
            #endif
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
        case .casting:
            spinner.stopAnimating()
            messageLabel.isHidden = true
            closeButton.isHidden = false
        case .closed:
            spinner.stopAnimating()
        }
    }

    private func presentPlayer() {
        guard !finished, appeared, presentedViewController == nil, let player = playback.player else { return }
        // After casting the phone plays a new player.
        let controller = playerController?.player === player ? playerController! : makePlayerController(player)
        playerController = controller
        present(controller, animated: false) { [weak self] in
            // From here on, this screen showing again means AVKit's player
            // was dismissed.
            self?.playerShown = true
            #if os(iOS)
                // After AVKit laid out its own controls, so they sit above them.
                self?.addAdView(to: controller)
                self?.addCastButton(to: controller)
            #elseif canImport(GoogleInteractiveMediaAds)
                self?.addAdCountdownView(to: controller)
                self?.syncAdScreen()
            #endif
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
        #if os(iOS)
            // A film left playing on the TV would stay counted against the plan.
            cast?.stop()
            cast?.dispose()
        #endif
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
        #if os(iOS)
            castingView.isHidden = true
            castingView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(castingView)
            NSLayoutConstraint.activate([
                castingView.topAnchor.constraint(equalTo: view.topAnchor),
                castingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                castingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                castingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        #endif
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

// MARK: - Chromecast

#if os(iOS)
extension EYZFlowPlayerViewController {
    private func setUpCast() {
        guard let cast else { return }
        castingView.onPlayPause = { [weak self] in
            guard let cast = self?.cast else { return }
            if case .active(_, let playback) = cast.state, playback.state == .playing {
                cast.pause()
            } else {
                cast.play()
            }
        }
        castingView.onSeek = { [weak self] position in self?.cast?.seek(to: position) }
        castingView.onStop = { [weak self] in self?.cast?.stop() }
        cast.onChange = { [weak self] in self?.castChanged() }
        cast.onPlayback = { [weak self] playback in self?.playback.castReported(playback) }
        cast.onEnded = { [weak self] reason, position in self?.castEnded(reason, at: position) }
    }

    /// Looks for TVs from when the film first plays, every 10 s until one is
    /// found: the first scan also asks for the Local Network permission and
    /// usually ends before the viewer answers.
    private func scanForCastDevicesOnce() {
        guard let cast, !castScanned else { return }
        castScanned = true
        Task { [weak self] in
            while let self, !self.finished, cast.devices.isEmpty {
                await cast.scan()
                if !cast.devices.isEmpty { break }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func castChanged() {
        guard let cast else { return }
        castButton.isHidden = cast.devices.isEmpty || cast.isCasting || inAdBreak
        castButton.superview?.bringSubviewToFront(castButton)
        if playback.state == .casting { castingView.render(cast.state) }
    }

    /// The Cast button, over AVKit's player. AVKit has no place for it in its
    /// own controls on iPhone, so it sits in the top trailing corner, below
    /// AVKit's top bar.
    private func addCastButton(to controller: AVPlayerViewController) {
        guard cast != nil else { return }
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: "tv.badge.wifi")
        configuration.baseForegroundColor = .white
        configuration.baseBackgroundColor = UIColor(white: 0, alpha: 0.45)
        configuration.cornerStyle = .capsule
        castButton.configuration = configuration
        castButton.accessibilityLabel = NSLocalizedString("Cast to a TV", comment: "Opens the Chromecast picker")
        castButton.removeTarget(nil, action: nil, for: .allEvents)
        castButton.addTarget(self, action: #selector(castTapped), for: .primaryActionTriggered)
        castButton.isHidden = (cast?.devices.isEmpty ?? true) || inAdBreak
        castButton.removeFromSuperview()
        castButton.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(castButton)
        let guide = controller.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            castButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 64),
            castButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
        ])
    }

    @objc private func castTapped() {
        guard let cast, let presenter = playerController else { return }
        let picker = UIAlertController(
            title: NSLocalizedString("Cast to", comment: "Chromecast picker title"),
            message: nil,
            preferredStyle: .actionSheet
        )
        for target in cast.devices {
            picker.addAction(UIAlertAction(title: target.name, style: .default) { [weak self] _ in
                self?.startCasting(to: target)
            })
        }
        picker.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Closes the picker"), style: .cancel))
        picker.popoverPresentationController?.sourceView = castButton
        picker.popoverPresentationController?.sourceRect = castButton.bounds
        presenter.present(picker, animated: true)
    }

    private func startCasting(to target: CastTarget) {
        guard let cast, let appID = playback.options.castReceiverAppID,
              let media = playback.handOverToCast() else { return }
        castingView.show(title: playback.options.title, poster: playback.options.poster)
        castingView.render(.connecting(target))
        castingView.isHidden = false
        view.bringSubviewToFront(closeButton)
        presentedViewController?.dismiss(animated: true)
        Task { await cast.cast(media, to: target, appID: appID) }
    }

    private func castEnded(_ reason: CastEndReason, at position: Duration) {
        // Closing the player stops casting too; nothing to hand back then.
        guard !finished else { return }
        var failure: String?
        if reason == .failed, case .failed(let target, _) = cast?.state {
            failure = String(format: NSLocalizedString("Could not play on %@", comment: "Casting failed"), target.name)
        }
        playback.castEnded(reason, at: position, failure: failure)
        if reason == .finished {
            finish()
            return
        }
        if let failure { playback.options.onError?(failure) }
        // The phone plays on where the TV was (`render(.playing)`).
    }
}
#endif

// MARK: - Ads

#if canImport(GoogleInteractiveMediaAds)
extension EYZFlowPlayerViewController {
    #if os(iOS)
    /// The ad view, over AVKit's player (and moved to a new player after
    /// casting hands playback back).
    private func addAdView(to controller: AVPlayerViewController) {
        if adView.superview !== controller.view {
            adView.removeFromSuperview()
            adView.backgroundColor = .clear
            adView.isUserInteractionEnabled = inAdBreak
            adView.translatesAutoresizingMaskIntoConstraints = false
            adSpinner.color = .white
            adSpinner.hidesWhenStopped = true
            adSpinner.translatesAutoresizingMaskIntoConstraints = false
            if adSpinner.superview == nil { adView.addSubview(adSpinner) }
            controller.view.addSubview(adView)
            NSLayoutConstraint.activate([
                adView.topAnchor.constraint(equalTo: controller.view.topAnchor),
                adView.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
                adView.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
                adView.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
                adSpinner.centerXAnchor.constraint(equalTo: adView.centerXAnchor),
                adSpinner.centerYAnchor.constraint(equalTo: adView.centerYAnchor),
            ])
        } else {
            controller.view.bringSubviewToFront(adView)
        }
        addAdCountdownView(to: controller)
        playback.adContainerAppeared()
    }

    /// The countdown, over the ad view, above AVKit's bottom bar. It takes
    /// no touches.
    private func addAdCountdownView(to controller: AVPlayerViewController) {
        if adCountdownView.superview !== controller.view {
            adCountdownView.removeFromSuperview()
            adCountdownView.translatesAutoresizingMaskIntoConstraints = false
            controller.view.addSubview(adCountdownView)
            let guide = controller.view.safeAreaLayoutGuide
            NSLayoutConstraint.activate([
                adCountdownView.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
                adCountdownView.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -72),
            ])
        } else {
            controller.view.bringSubviewToFront(adCountdownView)
        }
        adCountdownView.show(playback.adCountdown)
    }
    #else
    /// The countdown, in AVKit's content overlay: over the picture, under
    /// the transport bar, never focusable.
    private func addAdCountdownView(to controller: AVPlayerViewController) {
        guard let overlay = controller.contentOverlayView else { return }
        if adCountdownView.superview !== overlay {
            adCountdownView.removeFromSuperview()
            adCountdownView.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(adCountdownView)
            let guide = overlay.safeAreaLayoutGuide
            NSLayoutConstraint.activate([
                adCountdownView.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -90),
                adCountdownView.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -60),
            ])
        }
        adCountdownView.show(playback.adCountdown)
    }

    /// Presents the ad screen over AVKit's player while a break is under
    /// way, and dismisses it after. One transition at a time; each one ends
    /// by checking again.
    fileprivate func syncAdScreen() {
        guard !adScreenTransitioning, let playerController else { return }
        let shown = adScreen.presentingViewController != nil
        let wanted = inAdBreak && playerShown && !finished && playerController.presentingViewController != nil
        if wanted, !shown {
            guard playerController.presentedViewController == nil else { return }
            adScreenTransitioning = true
            adScreen.onAppear = { [weak self] in self?.playback.adContainerAppeared() }
            adScreen.onMenu = { [weak self] in
                // Menu leaves the player, as it does outside an ad; this screen
                // showing again closes the playback (`viewDidAppear`).
                self?.dismiss(animated: true)
            }
            adScreen.onPlayPause = { [weak self] in self?.playback.toggleAdPause() }
            playerController.present(adScreen, animated: false) { [weak self] in
                self?.adScreenTransitioning = false
                self?.syncAdScreen()
            }
        } else if !wanted, shown {
            adScreenTransitioning = true
            adScreen.dismiss(animated: false) { [weak self] in
                self?.adScreenTransitioning = false
                self?.syncAdScreen()
            }
        }
    }
    #endif
}

extension EYZFlowPlayerViewController: AdContainerHost {
    var adContainer: (view: UIView, viewController: UIViewController)? {
        #if os(iOS)
            guard let playerController, adView.superview === playerController.view, adView.window != nil else { return nil }
            return (adView, playerController)
        #else
            guard adScreen.viewIfLoaded?.window != nil else { return nil }
            return (adScreen.view, adScreen)
        #endif
    }

    func adStateChanged(inBreak: Bool, adPlaying: Bool) {
        inAdBreak = inBreak
        // AVKit's controls (seek, tracks, Picture in Picture, AirPlay) and the
        // Cast button are off during a break.
        playerController?.showsPlaybackControls = !inBreak
        #if os(iOS)
            // The ad view takes the touches.
            playerController?.canStartPictureInPictureAutomaticallyFromInline = !inBreak
            adView.isUserInteractionEnabled = inBreak
            adView.backgroundColor = adPlaying ? .black : .clear
            if inBreak, !adPlaying {
                adSpinner.startAnimating()
            } else {
                adSpinner.stopAnimating()
            }
            castButton.isHidden = (cast?.devices.isEmpty ?? true) || (cast?.isCasting ?? false) || inBreak
        #else
            // No scrubbing past the break; the ad screen takes the focus.
            playerController?.requiresLinearPlayback = inBreak
            adScreen.render(waiting: inBreak && !adPlaying, adPlaying: adPlaying)
            syncAdScreen()
        #endif
    }

    func adCountdownChanged(_ seconds: Int?) {
        adCountdownView.show(seconds)
    }

    #if os(tvOS)
    func adFocusChanged(_ environment: (any UIFocusEnvironment)?) {
        adScreen.adFocusEnvironment = environment
    }
    #endif
}

/// The notice before a mid-roll: a small rounded label. Not interactive:
/// touches go through to the player, and VoiceOver reads it as text.
final class AdCountdownView: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        backgroundColor = UIColor(white: 0, alpha: 0.72)
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        label.textColor = .white
        let base = UIFont.preferredFont(forTextStyle: .footnote)
        label.font = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: base.pointSize, weight: .medium))
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        isAccessibilityElement = true
        accessibilityTraits = [.staticText, .updatesFrequently]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Seconds (5 … 1) to show, or nil to hide.
    func show(_ seconds: Int?) {
        guard let seconds else {
            isHidden = true
            return
        }
        let text = AdCountdown.label(seconds)
        let appearing = isHidden
        label.text = text
        accessibilityLabel = text
        isHidden = false
        // Spoken once when it appears, not every second.
        if appearing, UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: text)
        }
    }
}

#if os(tvOS)
/// The ad screen on Apple TV, presented over AVKit's player for an ad break:
/// IMA's display container. Focus goes to IMA's focus environment (a
/// skippable ad's skip button) when it has one. Menu leaves the player,
/// Play/Pause pauses or resumes the ad, and no press reaches AVKit's player
/// underneath, so the content cannot be played or moved during the ad.
final class AdBreakViewController: UIViewController {
    var onAppear: (() -> Void)?
    var onMenu: (() -> Void)?
    var onPlayPause: (() -> Void)?

    /// IMA's `IMAAdDisplayContainer.focusEnvironment`.
    var adFocusEnvironment: (any UIFocusEnvironment)? {
        didSet {
            guard (adFocusEnvironment as AnyObject?) !== (oldValue as AnyObject?) else { return }
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
    }

    private let spinner = UIActivityIndicatorView(style: .large)

    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAppear?()
        setNeedsFocusUpdate()
    }

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        if let adFocusEnvironment { return [adFocusEnvironment] }
        return super.preferredFocusEnvironments
    }

    /// Waiting for the ad: the paused content shows through, with a spinner.
    /// Playing: black under IMA's ad.
    func render(waiting: Bool, adPlaying: Bool) {
        loadViewIfNeeded()
        view.backgroundColor = adPlaying ? .black : .clear
        if waiting {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.filter { !AdBreakPress.swallowed($0.type) }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch AdBreakPress.action(for: press.type) {
            case .leave: onMenu?()
            case .togglePause: onPlayPause?()
            case .ignore, .none: break
            }
        }
        let rest = presses.filter { !AdBreakPress.swallowed($0.type) }
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.filter { !AdBreakPress.swallowed($0.type) }
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.filter { !AdBreakPress.swallowed($0.type) }
        if !rest.isEmpty { super.pressesChanged(rest, with: event) }
    }
}

/// The ad screen's view of a press: what `AdBreakRemoteAction` decides.
enum AdBreakPress {
    static func action(for type: UIPress.PressType) -> AdBreakRemoteAction? {
        let button: AdBreakRemoteButton = switch type {
        case .menu: .menu
        case .playPause: .playPause
        case .select: .select
        default: .other
        }
        return AdBreakRemoteAction(button)
    }

    /// Not passed on to AVKit's player underneath.
    static func swallowed(_ type: UIPress.PressType) -> Bool { action(for: type) != nil }
}
#endif
#endif

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
