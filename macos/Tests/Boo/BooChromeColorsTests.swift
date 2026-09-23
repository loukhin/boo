import SwiftUI
import Testing
@testable import Ghostty

struct BooChromeColorsTests {
    @Test(arguments: [Ghostty.Config.BackgroundBlur.macosGlassRegular, .macosGlassClear])
    func glassDoesNotPaintOverWindowEffect(style: Ghostty.Config.BackgroundBlur) {
        let config = MockConfig(backgroundBlur: style, backgroundColor: .black, backgroundOpacity: 0.5)
        #expect(BooChromeColors.terminalBackgroundColor(for: config) == .clear)
        #expect(BooChromeColors.terminalChromeBackgroundColor(for: config) == .clear)
    }

    @Test func ordinaryBackgroundKeepsConfiguredOpacity() {
        let config = MockConfig(backgroundBlur: .disabled, backgroundColor: .black, backgroundOpacity: 0.5)
        #expect(BooChromeColors.terminalBackgroundColor(for: config) == Color.black.opacity(0.5))
        #expect(BooChromeColors.terminalChromeBackgroundColor(for: config) != .clear)
    }
}
