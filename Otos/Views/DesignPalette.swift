import AppKit
import SwiftUI

/// DES-021/DES-022/DES-023 palette guide.
///
/// The one file DES-020 permits to write a color literal: Otos's chrome is
/// lighter than the system default (DES-022) and its text levels use custom
/// opacities because the system secondary/tertiary label colors fail the text
/// contrast minimum on that lighter chrome (`hig-validation.md` F-1/F-2).
/// Every other view names colors semantically via `.primary`/system
/// materials/`Color.accentColor` or these members; `guard-design-system.sh`
/// allowlists only this file.
nonisolated enum DesignPalette {
    // MARK: - DES-021 text

    /// L1/L2: label at 85% opacity, both appearances. L1 and L2 share this one
    /// text color; DES-002/DES-003 differentiate them by weight and size, not
    /// color.
    static func label(for colorScheme: ColorScheme) -> Color {
        base(for: colorScheme).opacity(0.85)
    }

    /// L3: 60% black light / 60% white dark — 5.7:1 / 6.2:1 against the bar
    /// chrome (`hig-validation.md` F-1), clearing the 4.5:1 text minimum the
    /// system secondary label color fails at this chrome's lightness.
    static func l3(for colorScheme: ColorScheme) -> Color {
        base(for: colorScheme).opacity(0.60)
    }

    // MARK: - DES-022 chrome

    static func content(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(hex: 0x1C1C1E) : Color(hex: 0xFFFFFF)
    }

    static func sidebar(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(hex: 0x242426) : Color(hex: 0xFAFAFB)
    }

    static func bar(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(hex: 0x2A2A2C) : Color(hex: 0xFBFBFC)
    }

    // MARK: - DES-062 badge

    /// The badge well on a thumbnail: black at 55% in both appearances, because it sits
    /// on a photograph, not on chrome. `badgeNSColor` is the same value for the AppKit
    /// tile.
    static let badge = Color(nsColor: badgeNSColor)
    static let badgeNSColor = NSColor.black.withAlphaComponent(0.55)
    /// Text on `badge`.
    static let badgeLabel = Color.white
    /// The hairline edge of a dark tag that must read where the picture under it is dark
    /// too — the duplicates list's Trash tag on a dimmed photo (DES-107): white at 30%, in
    /// both appearances, because it sits on a photograph, not on chrome.
    static let badgeEdge = Color.white.opacity(0.30)

    /// The edge of a thumbnail stack on the Places map (DES-103): white, so the stack
    /// separates from any map underneath it; the accent replaces it for selection.
    static let mapStackEdge = Color.white

    // MARK: - DES-112 text on a photograph

    /// The scrim under text set on a photograph — an On This Day card's year, the story's
    /// date (DES-112): black at 40% at the text's edge, fading to clear across the photo,
    /// in both appearances, because it sits on a photograph, not on chrome.
    static let photoScrim = Color.black.opacity(0.40)
    /// Text on `photoScrim`.
    static let photoLabel = Color.white

    // MARK: - DES-023 hairline

    /// 8% black light / 10% white dark. DES-084: under Increase Contrast,
    /// hairlines revert to the system separator strength instead of this
    /// deviation. `increaseContrast` defaults to the live accessibility
    /// setting; callers pass it explicitly only to test the reversion rule.
    static func hairline(
        for colorScheme: ColorScheme,
        increaseContrast: Bool = prefersIncreaseContrast
    ) -> Color {
        guard !increaseContrast else {
            return Color(nsColor: .separatorColor)
        }
        return base(for: colorScheme).opacity(colorScheme == .dark ? 0.10 : 0.08)
    }

    // MARK: - Live accessibility state

    static var prefersIncreaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    private static func base(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white : .black
    }
}

private nonisolated extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
