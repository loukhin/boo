//
//  TerminalViewContainerTests.swift
//  Ghostty
//
//  Created by Lukas on 26.02.2026.
//

import SwiftUI
import Testing
@testable import Ghostty

class MockTerminalViewContainer: TerminalViewContainer {
    var _windowCornerRadius: CGFloat?
    override var windowThemeFrameView: NSView? {
        NSView()
    }

    override var windowCornerRadius: CGFloat? {
        _windowCornerRadius
    }
}

class MockConfig: Ghostty.Config {
    internal init(backgroundBlur: Ghostty.Config.BackgroundBlur, backgroundColor: Color, backgroundOpacity: Double) {
        self._backgroundBlur = backgroundBlur
        self._backgroundColor = backgroundColor
        self._backgroundOpacity = backgroundOpacity
        super.init(config: nil)
    }

    var _backgroundBlur: Ghostty.Config.BackgroundBlur
    var _backgroundColor: Color
    var _backgroundOpacity: Double

    override var backgroundBlur: Ghostty.Config.BackgroundBlur {
        _backgroundBlur
    }

    override var backgroundColor: Color {
        _backgroundColor
    }

    override var backgroundOpacity: Double {
        _backgroundOpacity
    }
}

struct TerminalViewContainerTests {
    @MainActor
    @Test func glassReloadReusesEffectAndRemovesItWhenDisabled() async throws {
        guard #available(macOS 26.0, *) else { return }
        let view = MockTerminalViewContainer { EmptyView() }
        let config = MockConfig(backgroundBlur: .macosGlassRegular, backgroundColor: .black, backgroundOpacity: 0.5)
        view.ghosttyConfigDidChange(config, preferredBackgroundColor: nil)
        let originalEffect = try #require(view.glassEffectView)

        config._backgroundBlur = .macosGlassClear
        view.ghosttyConfigDidChange(config, preferredBackgroundColor: nil)
        try await Task.sleep(nanoseconds: UInt64(1e8))
        #expect(view.glassEffectView === originalEffect)

        config._backgroundBlur = .disabled
        view.ghosttyConfigDidChange(config, preferredBackgroundColor: nil)
        try await Task.sleep(nanoseconds: UInt64(1e8))
        #expect(view.glassEffectView == nil)
    }

    @Test(arguments: [Ghostty.Config.BackgroundBlur.macosGlassRegular, .macosGlassClear])
    func glassAvailability(style: Ghostty.Config.BackgroundBlur) async throws {
        let view = await MockTerminalViewContainer {
            EmptyView()
        }

        let config = MockConfig(backgroundBlur: style, backgroundColor: .clear, backgroundOpacity: 1)
        await view.ghosttyConfigDidChange(config, preferredBackgroundColor: nil)
        try await Task.sleep(nanoseconds: UInt64(1e8)) // wait for the view to be setup if needed
        if #available(macOS 26.0, *) {
            #expect(view.glassEffectView != nil)
        } else {
            #expect(view.glassEffectView == nil)
        }
    }
}
