import AppKit
import Foundation
import SwiftUI
import GhosttyKit

enum BooChromeColors {
    /// Small CIE L* delta for chrome around the terminal. This keeps the
    /// difference subtle while making light-mode darkening and dark-mode
    /// lightening closer in perceived strength than a fixed sRGB blend.
    private static let chromeLightnessDelta: CGFloat = 2.8

    static func terminalBackgroundColor(for config: Ghostty.Config) -> Color {
        config.backgroundColor.opacity(clampedBackgroundOpacity(for: config))
    }

    static func terminalChromeBackgroundColor(for config: Ghostty.Config) -> Color {
        Color(
            chromeBackgroundColor(for: config)
                .withAlphaComponent(clampedBackgroundOpacity(for: config))
        )
    }

    static func chromeBackgroundColor(for config: Ghostty.Config) -> NSColor {
        let background = NSColor(config.backgroundColor).usingColorSpace(.sRGB) ?? .windowBackgroundColor
        return chromeBackgroundColor(from: background)
    }

    static func chromeBackgroundColor(from background: NSColor) -> NSColor {
        let background = background.usingColorSpace(.sRGB) ?? background
        let components = sRGBComponents(of: background)
        let currentLightness = perceptualLightness(
            red: components.red,
            green: components.green,
            blue: components.blue
        )
        let shouldDarken = currentLightness > 50
        let targetLightness = shouldDarken
            ? max(0, currentLightness - chromeLightnessDelta)
            : min(100, currentLightness + chromeLightnessDelta)
        guard abs(targetLightness - currentLightness) > 0.01 else { return background }

        let target: NSColor = shouldDarken ? .black : .white
        let targetComponent: CGFloat = shouldDarken ? 0 : 1
        let fraction = blendFraction(
            from: components,
            toward: targetComponent,
            targetLightness: targetLightness,
            darkening: shouldDarken
        )
        return background.blended(withFraction: fraction, of: target) ?? background
    }

    static func clampedBackgroundOpacity(for config: Ghostty.Config) -> Double {
        min(1, max(0, config.backgroundOpacity))
    }

    private static func sRGBComponents(of color: NSColor) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue)
    }

    private static func blendFraction(
        from components: (red: CGFloat, green: CGFloat, blue: CGFloat),
        toward targetComponent: CGFloat,
        targetLightness: CGFloat,
        darkening: Bool
    ) -> CGFloat {
        var low: CGFloat = 0
        var high: CGFloat = 1

        for _ in 0..<18 {
            let mid = (low + high) / 2
            let red = blend(components.red, toward: targetComponent, fraction: mid)
            let green = blend(components.green, toward: targetComponent, fraction: mid)
            let blue = blend(components.blue, toward: targetComponent, fraction: mid)
            let lightness = perceptualLightness(red: red, green: green, blue: blue)

            if darkening {
                if lightness > targetLightness {
                    low = mid
                } else {
                    high = mid
                }
            } else {
                if lightness < targetLightness {
                    low = mid
                } else {
                    high = mid
                }
            }
        }

        return high
    }

    private static func blend(_ component: CGFloat, toward target: CGFloat, fraction: CGFloat) -> CGFloat {
        component * (1 - fraction) + target * fraction
    }

    private static func perceptualLightness(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
        let luminance = 0.2126 * linearizedSRGB(red)
            + 0.7152 * linearizedSRGB(green)
            + 0.0722 * linearizedSRGB(blue)

        if luminance <= 216 / 24389 {
            return luminance * 24389 / 27
        }

        return 116 * pow(luminance, 1 / 3) - 16
    }

    private static func linearizedSRGB(_ value: CGFloat) -> CGFloat {
        if value <= 0.04045 {
            return value / 12.92
        }

        return pow((value + 0.055) / 1.055, 2.4)
    }
}
