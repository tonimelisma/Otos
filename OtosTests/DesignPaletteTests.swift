import AppKit
@testable import OtosKit
import SwiftUI
import Testing

struct DesignPaletteTests {
    @Test func l3AgainstBarReproducesHigValidationRatios() {
        #expect(contrastRatio(DesignPalette.l3(for: .light), over: DesignPalette.bar(for: .light)).isApproximately(5.7))
        #expect(contrastRatio(DesignPalette.l3(for: .dark), over: DesignPalette.bar(for: .dark)).isApproximately(6.2))
    }

    @Test func labelClearsTextContrastMinimumAgainstBar() {
        #expect(contrastRatio(DesignPalette.label(for: .light), over: DesignPalette.bar(for: .light)) >= 4.5)
        #expect(contrastRatio(DesignPalette.label(for: .dark), over: DesignPalette.bar(for: .dark)) >= 4.5)
    }

    @Test func hairlineUnderIncreaseContrastRevertsToSystemSeparator() {
        for colorScheme: ColorScheme in [.light, .dark] {
            let reverted = DesignPalette.hairline(for: colorScheme, increaseContrast: true)
            #expect(reverted == Color(nsColor: .separatorColor))
            let deviation = DesignPalette.hairline(for: colorScheme, increaseContrast: false)
            #expect(deviation != Color(nsColor: .separatorColor))
        }
    }

    @Test func chromeOrderIsDistinguishableInBothAppearances() {
        for colorScheme: ColorScheme in [.light, .dark] {
            let content = DesignPalette.content(for: colorScheme)
            let sidebar = DesignPalette.sidebar(for: colorScheme)
            let bar = DesignPalette.bar(for: colorScheme)
            #expect(content != sidebar)
            #expect(sidebar != bar)
            #expect(content != bar)
        }
    }
}

/// WCAG 2.x relative-luminance contrast ratio, computed from the palette's
/// actual resolved `Color` values rather than re-deriving the arithmetic by
/// hand, so a slipped opacity or hex digit fails this test. `NSColor`
/// conversion does not flatten alpha against a backdrop — `label`/`l3`/`l4`
/// are translucent black/white — so the foreground is alpha-composited over
/// the (opaque) background before either luminance is measured, matching what
/// a viewer actually sees painted on that chrome.
private func contrastRatio(_ foreground: Color, over background: Color) -> Double {
    let fg = RGBA(foreground)
    let bg = RGBA(background)
    let composited = RGB(
        red: fg.red * fg.alpha + bg.red * (1 - fg.alpha),
        green: fg.green * fg.alpha + bg.green * (1 - fg.alpha),
        blue: fg.blue * fg.alpha + bg.blue * (1 - fg.alpha)
    )
    let foregroundLuminance = composited.relativeLuminance
    let backgroundLuminance = bg.rgb.relativeLuminance
    let lighter = max(foregroundLuminance, backgroundLuminance)
    let darker = min(foregroundLuminance, backgroundLuminance)
    return (lighter + 0.05) / (darker + 0.05)
}

private struct RGB {
    let red: Double
    let green: Double
    let blue: Double

    var relativeLuminance: Double {
        func linearize(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
    }
}

private struct RGBA {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(_ color: Color) {
        let resolved = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        red = Double(resolved.redComponent)
        green = Double(resolved.greenComponent)
        blue = Double(resolved.blueComponent)
        alpha = Double(resolved.alphaComponent)
    }

    var rgb: RGB {
        RGB(red: red, green: green, blue: blue)
    }
}

private extension Double {
    func isApproximately(_ target: Double, tolerance: Double = 0.15) -> Bool {
        abs(self - target) <= tolerance
    }
}
