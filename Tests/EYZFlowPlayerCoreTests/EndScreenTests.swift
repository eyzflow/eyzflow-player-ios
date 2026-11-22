import Foundation
import Testing
@testable import EYZFlowPlayerCore

private let credits = StreamSignal(id: "c", type: .closingCredits, start: .seconds(540), end: .seconds(600))
private let intro = StreamSignal(id: "i", type: .intro, start: .seconds(5), end: .seconds(65))

@Suite("End screen")
struct EndScreenTests {
    private let on = EndScreenSettings.resolve(config: .defaults, hasContent: true)

    private func phase(
        _ settings: EndScreenSettings,
        _ signal: StreamSignal?,
        at seconds: Double,
        ended: Bool = false,
        hasCredits: Bool = true
    ) -> EndScreenPhase? {
        endScreenPhase(
            settings,
            signal: signal,
            position: .milliseconds(Int64(seconds * 1000)),
            duration: .seconds(600),
            ended: ended,
            hasClosingCredits: hasCredits
        )
    }

    @Test("on with something to show, with the defaults")
    func defaults() {
        #expect(on == EndScreenSettings(enabled: true, autoplaySeconds: 10, showAt: .credits, shrinkVideo: true, secondsBeforeEnd: 20))
        #expect(!EndScreenSettings.resolve(config: .defaults, hasContent: false).enabled)
        #expect(!EndScreenSettings.resolve(config: .defaults, hasContent: true, enabled: false).enabled)
        let off = PlayerConfig(features: PlayerFeatures(endScreen: false))
        #expect(!EndScreenSettings.resolve(config: off, hasContent: true).enabled)
    }

    @Test("the app's values over the config's, clamped")
    func overrides() {
        let remote = PlayerConfig(endScreen: PlayerEndScreenConfig(autoplaySeconds: 5, showAt: .end, shrinkVideo: false, secondsBeforeEnd: 40))
        let fromRemote = EndScreenSettings.resolve(config: remote, hasContent: true)
        #expect(fromRemote.autoplaySeconds == 5)
        #expect(fromRemote.showAt == .end)
        #expect(!fromRemote.shrinkVideo)
        #expect(fromRemote.secondsBeforeEnd == 40)
        let app = EndScreenSettings.resolve(
            config: remote,
            hasContent: true,
            app: PlayerEndScreenConfig(autoplaySeconds: 99, showAt: .credits, secondsBeforeEnd: 500)
        )
        #expect(app.autoplaySeconds == 30)
        #expect(app.showAt == .credits)
        #expect(app.secondsBeforeEnd == 120)
    }

    @Test("over the closing credits, in the last second and after the end")
    func phases() {
        #expect(phase(on, credits, at: 541) == .credits)
        #expect(phase(on, intro, at: 20) == nil)
        #expect(phase(on, nil, at: 599.2) == .ended)
        #expect(phase(on, nil, at: 300, ended: true) == .ended)
        #expect(phase(on, nil, at: 590) == nil, "a stream with closing credits waits for them")
    }

    @Test("without a closing credits signal, the last 20 s count as the credits")
    func fallback() {
        #expect(phase(on, nil, at: 579, hasCredits: false) == nil)
        #expect(phase(on, nil, at: 580, hasCredits: false) == .credits)
        var zero = on
        zero.secondsBeforeEnd = 0
        #expect(phase(zero, nil, at: 595, hasCredits: false) == nil)
    }

    @Test("with showAt end, only at the end; never when off")
    func showAtEnd() {
        var atEnd = on
        atEnd.showAt = .end
        #expect(phase(atEnd, credits, at: 541) == nil)
        #expect(phase(atEnd, nil, at: 590, hasCredits: false) == nil)
        #expect(phase(atEnd, nil, at: 600, ended: true) == .ended)
        var off = on
        off.enabled = false
        #expect(phase(off, credits, at: 541, ended: true) == nil)
    }

    @Test("runtimes and labels")
    func texts() {
        #expect(formatRuntime(.seconds(5520)) == "1 h 32 min")
        #expect(formatRuntime(.seconds(2700)) == "45 min")
        #expect(formatRuntime(.seconds(7200)) == "2 h")
        #expect(formatRuntime(nil).isEmpty)
        #expect(EndScreenLabels(language: "de-DE").nextIn(5) == "Weiter in 5")
        #expect(EndScreenLabels(language: "fr").moreLikeThis == "Titres similaires")
        #expect(EndScreenLabels(language: "ja").upNext == "Up next")
    }

    @Test("reads features.endScreen and the endScreen section")
    func config() {
        let config = PlayerConfig(json: [
            "features": ["endScreen": .bool(false)],
            "endScreen": ["autoplaySeconds": .int(45), "showAt": .string("end"), "shrinkVideo": .bool(false), "secondsBeforeEnd": .int(30)],
        ])
        #expect(!config.features.endScreen)
        #expect(config.endScreen == PlayerEndScreenConfig(autoplaySeconds: 30, showAt: .end, shrinkVideo: false, secondsBeforeEnd: 30))
        #expect(PlayerFeatures(json: [:]).endScreen)
        let merged = config.merged(with: PlayerConfigOverride(endScreen: PlayerEndScreenConfig(secondsBeforeEnd: 10)))
        #expect(merged.endScreen?.secondsBeforeEnd == 10)
        #expect(merged.endScreen?.showAt == .end)
    }
}
