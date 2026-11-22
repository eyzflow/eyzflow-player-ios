#if (os(iOS) || os(tvOS)) && canImport(GoogleInteractiveMediaAds)
import AVFoundation
import EYZFlowPlayerCore
import GoogleInteractiveMediaAds
import UIKit

/// Where ads are drawn: a view on screen over the player, and the view
/// controller that shows it (for the ad's click-through).
@MainActor
protocol AdContainerHost: AnyObject {
    /// Nil until the view is on screen. IMA needs its display container
    /// in a window before the request.
    var adContainer: (view: UIView, viewController: UIViewController)? { get }
    /// An ad break began or ended, or its ad started: hide or show the
    /// player's controls.
    func adStateChanged(inBreak: Bool, adPlaying: Bool)
    /// The countdown before a mid-roll changed: seconds (5 … 1), or nil to
    /// hide it.
    func adCountdownChanged(_ seconds: Int?)
    #if os(tvOS)
    /// IMA's focus environment changed (a skip button appeared, or the ad
    /// ended): focus moves there.
    func adFocusChanged(_ environment: (any UIFocusEnvironment)?)
    #endif
}

/// Plays the ads [`AdBreakScheduler`] asks for through Google IMA.
///
/// IMA draws the ad, its countdown, skip button and click-through in the
/// host's ad view. A display container is made for each request, once that
/// view is on screen; `discardAds()` destroys the ads manager, and answers to
/// a request or manager dropped that way are recognised by their generation
/// and dropped too.
@MainActor
final class IMAAdDriver: NSObject, AdDriver {
    let adTagURL: String
    private weak var player: AVPlayer?
    private weak var host: (any AdContainerHost)?
    /// Set once by the owner, before the first request.
    weak var scheduler: AdBreakScheduler?

    private let loader: IMAAdsLoader
    private var manager: IMAAdsManager?
    private var container: IMAAdDisplayContainer?
    private var playhead: IMAAVPlayerContentPlayhead?
    private var generation = 0
    private var requestPending = false
    #if os(tvOS)
    private var adPaused = false
    private weak var lastFocus: AnyObject?
    #endif

    init(adTagURL: String, player: AVPlayer, host: any AdContainerHost) {
        self.adTagURL = adTagURL
        self.player = player
        self.host = host
        let settings = IMASettings()
        settings.enableDebugMode = false
        loader = IMAAdsLoader(settings: settings)
        super.init()
        loader.delegate = self
    }

    // MARK: AdDriver

    func requestAds() {
        requestPending = true
        sendIfReady()
    }

    /// The host's ad view is on screen now: a request waiting for it goes.
    func containerAppeared() {
        sendIfReady()
    }

    private func sendIfReady() {
        guard requestPending, let player,
              let (view, viewController) = host?.adContainer, view.window != nil else { return }
        requestPending = false
        let container = IMAAdDisplayContainer(adContainer: view, viewController: viewController, companionSlots: nil)
        self.container = container
        let playhead = IMAAVPlayerContentPlayhead(avPlayer: player)
        self.playhead = playhead
        let request = IMAAdsRequest(
            adTagUrl: adTagURL,
            adDisplayContainer: container,
            contentPlayhead: playhead,
            userContext: NSNumber(value: generation)
        )
        log("requesting ads")
        loader.requestAds(with: request)
    }

    func startAds() {
        manager?.start()
    }

    func discardAds() {
        generation += 1
        requestPending = false
        manager?.delegate = nil
        manager?.destroy()
        manager = nil
        container = nil
        playhead = nil
        #if os(tvOS)
            adPaused = false
            reportFocus()
        #endif
    }

    #if os(tvOS)
    /// Play/Pause on the Siri Remote during an ad.
    func togglePause() {
        guard let manager else { return }
        if adPaused {
            manager.resume()
        } else {
            manager.pause()
        }
    }

    /// Passes IMA's focus environment on when it changed. IMA has no event
    /// for it, so it is checked on every event and progress report.
    private func reportFocus() {
        let environment = container?.focusEnvironment
        guard (environment as AnyObject?) !== lastFocus else { return }
        lastFocus = environment
        host?.adFocusChanged(environment)
    }
    #endif

    func contentComplete() {
        loader.contentComplete()
    }

    func pauseContent() {
        player?.pause()
    }

    func resumeContent() {
        player?.play()
    }

    private func isCurrent(_ userContext: Any?) -> Bool {
        (userContext as? NSNumber)?.intValue == generation
    }

    fileprivate func loaded(_ data: IMAAdsLoadedData) {
        guard isCurrent(data.userContext), let manager = data.adsManager else {
            data.adsManager?.destroy()
            return
        }
        self.manager = manager
        manager.delegate = self
        let rendering = IMAAdsRenderingSettings()
        manager.initialize(with: rendering)
        // Seconds; 0 is a VMAP's pre-roll, -1 its post-roll. A VAST has none.
        let cuePoints = manager.adCuePoints.compactMap { ($0 as? NSNumber)?.doubleValue }.map { seconds in
            seconds < 0 ? Duration.seconds(-1) : Duration.milliseconds(Int64((seconds * 1000).rounded()))
        }
        log("ads loaded, cue points \(cuePoints)")
        scheduler?.adsLoaded(cuePoints: cuePoints)
    }

    fileprivate func failed(_ data: IMAAdLoadingErrorData) {
        guard isCurrent(data.userContext) else { return }
        log("ads failed to load: \(data.adError.message ?? "\(data.adError.code.rawValue)")")
        scheduler?.adsFailed()
    }

    fileprivate func event(_ event: IMAAdEvent, from manager: IMAAdsManager) {
        guard manager === self.manager else { return }
        if event.type != .AD_PERIOD_STARTED, event.type != .LOG { log("ad event \(event.typeString)") }
        #if os(tvOS)
            switch event.type {
            case .PAUSE: adPaused = true
            case .RESUME, .STARTED: adPaused = false
            default: break
            }
        #endif
        switch event.type {
        case .ALL_ADS_COMPLETED:
            scheduler?.allAdsCompleted()
        default:
            break
        }
        #if os(tvOS)
            reportFocus()
        #endif
    }

    fileprivate func progressed(_ manager: IMAAdsManager) {
        #if os(tvOS)
            guard manager === self.manager else { return }
            reportFocus()
        #endif
    }

    fileprivate func error(_ error: IMAAdError, from manager: IMAAdsManager) {
        guard manager === self.manager else { return }
        log("ad failed: \(error.message ?? "\(error.code.rawValue)")")
        scheduler?.adError()
    }

    fileprivate func pauseRequested(by manager: IMAAdsManager) {
        guard manager === self.manager else { return }
        scheduler?.contentPauseRequested()
        #if os(tvOS)
            reportFocus()
        #endif
    }

    fileprivate func resumeRequested(by manager: IMAAdsManager) {
        guard manager === self.manager else { return }
        scheduler?.contentResumeRequested()
        #if os(tvOS)
            reportFocus()
        #endif
    }

    private func log(_ message: String) {
        #if DEBUG
            print("[eyzflow-player] \(message)")
        #endif
    }
}

extension IMAAdDriver: IMAAdsLoaderDelegate {
    nonisolated func adsLoader(_ loader: IMAAdsLoader, adsLoadedWith adsLoadedData: IMAAdsLoadedData) {
        let data = Unchecked(adsLoadedData)
        MainActor.assumeIsolated { loaded(data.value) }
    }

    nonisolated func adsLoader(_ loader: IMAAdsLoader, failedWith adErrorData: IMAAdLoadingErrorData) {
        let data = Unchecked(adErrorData)
        MainActor.assumeIsolated { failed(data.value) }
    }
}

extension IMAAdDriver: IMAAdsManagerDelegate {
    nonisolated func adsManager(_ adsManager: IMAAdsManager, didReceive event: IMAAdEvent) {
        let args = Unchecked((adsManager, event))
        MainActor.assumeIsolated { self.event(args.value.1, from: args.value.0) }
    }

    nonisolated func adsManager(_ adsManager: IMAAdsManager, didReceive error: IMAAdError) {
        let args = Unchecked((adsManager, error))
        MainActor.assumeIsolated { self.error(args.value.1, from: args.value.0) }
    }

    nonisolated func adsManagerDidRequestContentPause(_ adsManager: IMAAdsManager) {
        let manager = Unchecked(adsManager)
        MainActor.assumeIsolated { pauseRequested(by: manager.value) }
    }

    nonisolated func adsManager(_ adsManager: IMAAdsManager, adDidProgressToTime mediaTime: TimeInterval, totalTime: TimeInterval) {
        let manager = Unchecked(adsManager)
        MainActor.assumeIsolated { progressed(manager.value) }
    }

    nonisolated func adsManagerDidRequestContentResume(_ adsManager: IMAAdsManager) {
        let manager = Unchecked(adsManager)
        MainActor.assumeIsolated { resumeRequested(by: manager.value) }
    }
}
#endif
