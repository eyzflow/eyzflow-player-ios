#if os(iOS)
import EYZFlowPlayerCore
import UIKit

/// The phone while a TV plays: the poster, "Playing on …", play/pause, a seek
/// bar and Stop casting.
@MainActor
final class CastingView: UIView {
    var onPlayPause: (() -> Void)?
    var onSeek: ((Duration) -> Void)?
    var onStop: (() -> Void)?

    private let posterView = UIImageView()
    private let iconView = UIImageView(image: UIImage(systemName: "tv"))
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let slider = UISlider()
    private let elapsedLabel = UILabel()
    private let durationLabel = UILabel()
    private let playPauseButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .large)
    private let stopButton = UIButton(type: .system)
    private var dragging = false
    private var posterURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(title: String, poster: URL?) {
        titleLabel.text = title
        guard poster != posterURL else { return }
        posterURL = poster
        posterView.image = nil
        guard let poster else { return }
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: poster),
                  let image = UIImage(data: data) else { return }
            self?.posterView.image = image
        }
    }

    func render(_ state: CastState) {
        switch state {
        case .connecting(let target):
            statusLabel.text = String(format: NSLocalizedString("Connecting to %@…", comment: "Casting status"), target.name)
            setPlayback(nil)
        case .active(let target, let playback):
            statusLabel.text = String(format: NSLocalizedString("Playing on %@", comment: "Casting status"), target.name)
            setPlayback(playback)
        case .off, .failed:
            setPlayback(nil)
        }
    }

    private func setPlayback(_ playback: CastPlayback?) {
        guard let playback else {
            spinner.startAnimating()
            playPauseButton.isHidden = true
            slider.isHidden = true
            elapsedLabel.isHidden = true
            durationLabel.isHidden = true
            return
        }
        spinner.stopAnimating()
        playPauseButton.isHidden = false
        let playing = playback.state == .playing
        playPauseButton.configuration?.image = UIImage(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
        playPauseButton.accessibilityLabel = playing
            ? NSLocalizedString("Pause", comment: "Pauses the TV")
            : NSLocalizedString("Play", comment: "Plays on the TV")
        let duration = playback.duration?.inSecondsDouble ?? 0
        let hasDuration = duration > 0
        slider.isHidden = !hasDuration
        elapsedLabel.isHidden = !hasDuration
        durationLabel.isHidden = !hasDuration
        guard hasDuration else { return }
        slider.maximumValue = Float(duration)
        if !dragging {
            slider.value = Float(playback.position.inSecondsDouble)
            elapsedLabel.text = Self.time(playback.position.inSecondsDouble)
        }
        durationLabel.text = Self.time(duration)
    }

    private func build() {
        posterView.contentMode = .scaleAspectFill
        posterView.clipsToBounds = true
        posterView.alpha = 0.25

        iconView.tintColor = .white
        iconView.preferredSymbolConfiguration = .init(pointSize: 44)
        titleLabel.textColor = .white
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.numberOfLines = 2
        titleLabel.textAlignment = .center
        statusLabel.textColor = UIColor(white: 1, alpha: 0.7)
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textAlignment = .center

        for label in [elapsedLabel, durationLabel] {
            label.textColor = UIColor(white: 1, alpha: 0.7)
            label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        }
        slider.addTarget(self, action: #selector(sliderMoved), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderReleased), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        var play = UIButton.Configuration.plain()
        play.baseForegroundColor = .white
        play.preferredSymbolConfigurationForImage = .init(pointSize: 56)
        playPauseButton.configuration = play
        playPauseButton.addAction(UIAction { [weak self] _ in self?.onPlayPause?() }, for: .primaryActionTriggered)
        spinner.color = .white

        var stop = UIButton.Configuration.tinted()
        stop.title = NSLocalizedString("Stop casting", comment: "Returns playback to the phone")
        stop.image = UIImage(systemName: "stop.fill")
        stop.imagePadding = 8
        stop.baseForegroundColor = .white
        stop.baseBackgroundColor = .white
        stopButton.configuration = stop
        stopButton.addAction(UIAction { [weak self] _ in self?.onStop?() }, for: .primaryActionTriggered)

        let timeRow = UIStackView(arrangedSubviews: [elapsedLabel, slider, durationLabel])
        timeRow.spacing = 8
        timeRow.alignment = .center
        let controls = UIStackView(arrangedSubviews: [timeRow, playPauseButton, spinner, stopButton])
        controls.axis = .vertical
        controls.spacing = 20
        controls.alignment = .center
        let header = UIStackView(arrangedSubviews: [iconView, titleLabel, statusLabel])
        header.axis = .vertical
        header.spacing = 12
        header.alignment = .center

        for subview in [posterView, header, controls] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        let guide = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            posterView.topAnchor.constraint(equalTo: topAnchor),
            posterView.bottomAnchor.constraint(equalTo: bottomAnchor),
            posterView.leadingAnchor.constraint(equalTo: leadingAnchor),
            posterView.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.centerXAnchor.constraint(equalTo: centerXAnchor),
            header.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -60),
            header.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 24),
            controls.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            controls.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -24),
            timeRow.widthAnchor.constraint(equalTo: controls.widthAnchor),
        ])
        setPlayback(nil)
    }

    @objc private func sliderMoved() {
        dragging = true
        elapsedLabel.text = Self.time(Double(slider.value))
    }

    @objc private func sliderReleased() {
        dragging = false
        onSeek?(.milliseconds(Int64(Double(slider.value) * 1000)))
    }

    private static func time(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
#endif
