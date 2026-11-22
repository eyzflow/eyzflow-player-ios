import Testing
@testable import EYZFlowPlayerCore

@Suite("Apple TV remote during an ad break")
struct AdBreakRemoteTests {
    @Test("Menu leaves the player, Play/Pause toggles the ad, Select does nothing")
    func actions() {
        #expect(AdBreakRemoteAction(.menu) == .leave)
        #expect(AdBreakRemoteAction(.playPause) == .togglePause)
        #expect(AdBreakRemoteAction(.select) == .ignore)
    }

    @Test("arrows and swipes go to the focus engine")
    func passedOn() {
        #expect(AdBreakRemoteAction(.other) == nil)
    }
}
