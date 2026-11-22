#if os(iOS) || os(tvOS)
import AVFoundation
import EYZFlowPlayerCore
import UIKit

/// A view that shows an `AVPlayer` through its own `AVPlayerLayer`: the end
/// screen moves the film's video here, into a corner, while it shows.
final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// The end screen: presented over AVKit's player at the closing credits or
/// after the film. "Up next" counts down and plays the next stream; the films
/// can be picked; the small video in the corner (or "Back to credits", or
/// Menu on Apple TV) goes back. On Apple TV, Play has the focus.
@MainActor
final class EndScreenViewController: UIViewController {
    var onPick: ((EndScreenItem, Bool) -> Void)?
    var onBack: (() -> Void)?
    /// Closes the player (iPhone, iPad: the close button).
    var onClose: (() -> Void)?

    /// The film's video, while it is moved here.
    let videoView = PlayerLayerView()

    private let endScreen: EYZFlowEndScreen
    private let settings: EndScreenSettings
    private let theme: PlayerTheme
    private let labels = EndScreenLabels()
    private(set) var phase: EndScreenPhase

    private let dimView = UIView()
    private let gradient = CAGradientLayer()
    private let backButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private var cardButtons: [UIButton] = []
    private var left: Int?
    private var timer: Timer?
    private var picked = false

    private var isTV: Bool {
        #if os(tvOS)
            true
        #else
            false
        #endif
    }

    init(endScreen: EYZFlowEndScreen, settings: EndScreenSettings, theme: PlayerTheme, phase: EndScreenPhase) {
        self.endScreen = endScreen
        self.settings = settings
        self.theme = theme
        self.phase = phase
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        let seconds = endScreen.nextUp == nil ? 0 : settings.autoplaySeconds
        left = seconds > 0 ? seconds : nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var accent: UIColor { UIColor(css: theme.accentColor) ?? UIColor(red: 0.38, green: 0.37, blue: 1, alpha: 1) }
    private var textColor: UIColor { UIColor(css: theme.textColor) ?? .white }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        dimView.translatesAutoresizingMaskIntoConstraints = false
        dimView.layer.addSublayer(gradient)
        view.addSubview(dimView)
        NSLayoutConstraint.activate([
            dimView.topAnchor.constraint(equalTo: view.topAnchor),
            dimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            dimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        buildVideo()
        buildContent()
        #if os(iOS)
            buildClose()
        #endif
        applyPhase()
        startCountdown()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        gradient.frame = dimView.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        timer?.invalidate()
        timer = nil
    }

    // MARK: Phase

    func setPhase(_ phase: EndScreenPhase) {
        guard phase != self.phase else { return }
        self.phase = phase
        if isViewLoaded { applyPhase() }
    }

    private func applyPhase() {
        let credits = phase == .credits
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.colors = credits
            ? [UIColor(white: 0, alpha: 0.92).cgColor, UIColor(white: 0, alpha: 0.78).cgColor, UIColor(white: 0, alpha: 0.4).cgColor]
            : [UIColor(white: 0, alpha: 0.88).cgColor, UIColor(white: 0, alpha: 0.88).cgColor]
        backButton.isHidden = !credits
    }

    // MARK: Video

    private func buildVideo() {
        videoView.translatesAutoresizingMaskIntoConstraints = false
        videoView.backgroundColor = .black
        videoView.layer.cornerRadius = isTV ? 14 : 10
        videoView.layer.masksToBounds = true
        videoView.playerLayer.videoGravity = .resizeAspect
        videoView.isHidden = true
        view.addSubview(videoView)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: guide.topAnchor, constant: isTV ? 40 : 16),
            videoView.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: isTV ? -60 : -16),
            videoView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.34),
            videoView.heightAnchor.constraint(equalTo: videoView.widthAnchor, multiplier: 9.0 / 16.0),
        ])
        #if os(iOS)
            let tap = UITapGestureRecognizer(target: self, action: #selector(backTapped))
            videoView.addGestureRecognizer(tap)
            videoView.isUserInteractionEnabled = true
            videoView.accessibilityLabel = labels.backToCredits
            videoView.accessibilityTraits = .button
            videoView.isAccessibilityElement = true
        #endif
    }

    #if os(iOS)
    private func buildClose() {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "xmark")
        config.baseForegroundColor = textColor
        closeButton.configuration = config
        closeButton.accessibilityLabel = NSLocalizedString("Close", comment: "Closes the player")
        closeButton.addTarget(self, action: #selector(closeTapped), for: .primaryActionTriggered)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            closeButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8),
        ])
    }

    @objc private func closeTapped() {
        onClose?()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    #endif

    /// Shows `player` in the corner (nil: nothing there).
    func showVideo(_ player: AVPlayer?) {
        loadViewIfNeeded()
        videoView.playerLayer.player = player
        videoView.isHidden = player == nil
    }

    // MARK: Content

    private func buildContent() {
        let scale: CGFloat = isTV ? 1.6 : 1
        let column = UIStackView()
        column.axis = .vertical
        column.alignment = .leading
        column.spacing = 14 * scale
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: isTV ? 80 : 24),
            column.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: isTV ? -80 : -24),
            column.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: isTV ? -60 : -24),
        ])

        styleText(backButton, title: labels.backToCredits, size: 13 * scale, weight: .regular, alpha: 0.8)
        backButton.addTarget(self, action: #selector(backTapped), for: .primaryActionTriggered)
        column.addArrangedSubview(backButton)

        if let next = endScreen.nextUp {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 16 * scale
            row.alignment = .center
            if traitCollection.horizontalSizeClass != .compact || isTV {
                row.addArrangedSubview(posterView(for: next, width: 220 * scale))
            }
            let body = UIStackView()
            body.axis = .vertical
            body.alignment = .leading
            body.spacing = 4 * scale
            body.addArrangedSubview(label(labels.upNext.uppercased(), size: 11 * scale, weight: .bold, color: accent))
            body.addArrangedSubview(label(next.title, size: 20 * scale, weight: .bold, color: textColor, lines: 2))
            if let description = next.description {
                body.addArrangedSubview(label(description, size: 13 * scale, weight: .regular, color: textColor.withAlphaComponent(0.8), lines: 2))
            }
            let actions = UIStackView(arrangedSubviews: [playButton, cancelButton])
            actions.spacing = 10 * scale
            body.setCustomSpacing(10 * scale, after: body.arrangedSubviews.last!)
            body.addArrangedSubview(actions)
            row.addArrangedSubview(body)
            column.addArrangedSubview(row)

            var play = UIButton.Configuration.filled()
            play.baseBackgroundColor = accent
            play.baseForegroundColor = .white
            play.contentInsets = NSDirectionalEdgeInsets(top: 9 * scale, leading: 18 * scale, bottom: 9 * scale, trailing: 18 * scale)
            playButton.configuration = play
            playButton.addTarget(self, action: #selector(playTapped), for: .primaryActionTriggered)

            var cancel = UIButton.Configuration.bordered()
            cancel.baseForegroundColor = textColor
            cancel.contentInsets = play.contentInsets
            cancelButton.configuration = cancel
            cancelButton.setTitle(labels.cancel, for: .normal)
            cancelButton.addTarget(self, action: #selector(cancelTapped), for: .primaryActionTriggered)
            updatePlayTitle()
        }

        if !endScreen.items.isEmpty {
            column.addArrangedSubview(label(endScreen.title ?? labels.moreLikeThis, size: 15 * scale, weight: .semibold, color: textColor))
            let scroll = UIScrollView()
            scroll.showsHorizontalScrollIndicator = false
            scroll.clipsToBounds = false
            scroll.translatesAutoresizingMaskIntoConstraints = false
            let cards = UIStackView()
            cards.axis = .horizontal
            cards.spacing = 12 * scale
            cards.translatesAutoresizingMaskIntoConstraints = false
            scroll.addSubview(cards)
            let cardWidth: CGFloat = isTV ? 300 : 170
            for item in endScreen.items {
                let card = cardButton(for: item, width: cardWidth, scale: scale)
                cardButtons.append(card)
                cards.addArrangedSubview(card)
            }
            column.addArrangedSubview(scroll)
            NSLayoutConstraint.activate([
                cards.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                cards.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                cards.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
                cards.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
                cards.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
                scroll.widthAnchor.constraint(equalTo: guide.widthAnchor, constant: isTV ? -160 : -48),
                scroll.heightAnchor.constraint(equalToConstant: cardWidth * 9 / 16 + 50 * scale),
            ])
        }
    }

    private func label(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor, lines: Int = 1) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.numberOfLines = lines
        return label
    }

    private func styleText(_ button: UIButton, title: String, size: CGFloat, weight: UIFont.Weight, alpha: CGFloat) {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.baseForegroundColor = textColor.withAlphaComponent(alpha)
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: size, weight: weight)
            return attributes
        }
        button.configuration = config
    }

    private func posterView(for item: EndScreenItem, width: CGFloat) -> UIView {
        let image = UIImageView()
        image.contentMode = .scaleAspectFill
        image.clipsToBounds = true
        image.layer.cornerRadius = 8
        image.backgroundColor = UIColor(white: 1, alpha: 0.12)
        image.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            image.widthAnchor.constraint(equalToConstant: width),
            image.heightAnchor.constraint(equalToConstant: width * 9 / 16),
        ])
        load(item.poster, into: image)
        if let badge = item.badge { addBadge(badge, to: image) }
        return image
    }

    private func cardButton(for item: EndScreenItem, width: CGFloat, scale: CGFloat) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.imagePlacement = .top
        config.imagePadding = 6
        config.titleAlignment = .leading
        config.title = item.title
        config.subtitle = formatRuntime(item.duration).isEmpty ? nil : formatRuntime(item.duration)
        config.baseForegroundColor = textColor
        config.contentInsets = .zero
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 13 * scale, weight: .semibold)
            return attributes
        }
        config.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 12 * scale)
            return attributes
        }
        config.image = placeholder(width: width)
        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .leading
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.accessibilityLabel = item.title
        button.addAction(UIAction { [weak self] _ in self?.pick(item, autoplay: false) }, for: .primaryActionTriggered)
        if let url = item.poster {
            Task { [weak button] in
                guard let image = await Self.image(url, size: CGSize(width: width, height: width * 9 / 16)) else { return }
                button?.configuration?.image = image
            }
        }
        return button
    }

    private func placeholder(width: CGFloat) -> UIImage {
        let size = CGSize(width: width, height: width * 9 / 16)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor(white: 1, alpha: 0.12).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8).fill()
        }
    }

    private func addBadge(_ text: String, to view: UIView) {
        let badge = PaddedLabel()
        badge.text = text
        badge.font = .systemFont(ofSize: isTV ? 18 : 11, weight: .semibold)
        badge.textColor = .white
        badge.backgroundColor = accent
        badge.layer.cornerRadius = 4
        badge.layer.masksToBounds = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            badge.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
        ])
    }

    private func load(_ url: URL?, into imageView: UIImageView) {
        guard let url else { return }
        Task { [weak imageView] in
            guard let image = await Self.image(url, size: nil) else { return }
            imageView?.image = image
        }
    }

    /// A poster, scaled to fill `size` with rounded corners when given.
    private static func image(_ url: URL, size: CGSize?) async -> UIImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else { return nil }
        guard let size else { return image }
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8).addClip()
            let ratio = max(size.width / image.size.width, size.height / image.size.height)
            let drawn = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
            image.draw(in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2, width: drawn.width, height: drawn.height))
        }
    }

    // MARK: Countdown and picking

    private func startCountdown() {
        guard left != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let current = left, !picked else { return }
        if current <= 1 {
            left = 0
            timer?.invalidate()
            timer = nil
            updatePlayTitle()
            if let next = endScreen.nextUp { pick(next, autoplay: true) }
        } else {
            left = current - 1
            updatePlayTitle()
        }
    }

    private func updatePlayTitle() {
        playButton.configuration?.title = left.map { labels.nextIn(max($0, 0)) } ?? labels.play
        cancelButton.isHidden = left == nil
    }

    private func pick(_ item: EndScreenItem, autoplay: Bool) {
        guard !picked else { return }
        picked = true
        timer?.invalidate()
        timer = nil
        onPick?(item, autoplay)
    }

    @objc private func playTapped() {
        if let next = endScreen.nextUp { pick(next, autoplay: false) }
    }

    @objc private func cancelTapped() {
        timer?.invalidate()
        timer = nil
        left = nil
        updatePlayTitle()
        #if os(tvOS)
            setNeedsFocusUpdate()
        #endif
    }

    @objc private func backTapped() {
        onBack?()
    }

    // MARK: Focus (Apple TV)

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        if endScreen.nextUp != nil { return [playButton] }
        if let first = cardButtons.first { return [first] }
        return super.preferredFocusEnvironments
    }

    #if os(tvOS)
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.filter { $0.type != .menu }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            onBack?()
            return
        }
        super.pressesEnded(presses, with: event)
    }
    #endif
}

/// A label with a little padding, for the badge.
private final class PaddedLabel: UILabel {
    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.insetBy(dx: 6, dy: 2))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 12, height: size.height + 4)
    }
}

extension UIColor {
    /// A theme colour from the dashboard (`#rrggbb`, `rgba(…)`, …).
    convenience init?(css value: String) {
        guard let color = CSSColor(css: value) else { return nil }
        self.init(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}
#endif
