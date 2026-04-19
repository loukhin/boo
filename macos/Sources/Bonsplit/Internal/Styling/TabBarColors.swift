import SwiftUI
import AppKit

/// Native macOS colors for the tab bar
enum TabBarColors {
    // MARK: - Tab Bar Background

    static var barBackground: Color {
        .clear
    }

    static var barMaterial: Material {
        .bar
    }
    
    /// Whether the tab bar should be transparent (let window background show through)
    static var isTransparent: Bool {
        true
    }

    // MARK: - Tab States

    static var activeTabBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static var hoveredTabBackground: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.5)
    }

    static var inactiveTabBackground: Color {
        .clear
    }

    // MARK: - Text Colors

    static var activeText: Color {
        Color(nsColor: .labelColor)
    }

    static var inactiveText: Color {
        Color(nsColor: .labelColor).opacity(0.7)
    }

    // MARK: - Borders & Indicators

    static var separator: Color {
        Color(nsColor: .separatorColor)
    }

    static var dropIndicator: Color {
        Color.accentColor
    }

    static var focusRing: Color {
        Color.accentColor.opacity(0.5)
    }

    static var dirtyIndicator: Color {
        Color(nsColor: .labelColor).opacity(0.6)
    }

    // MARK: - Shadows

    static var tabShadow: Color {
        Color.black.opacity(0.08)
    }
}
