import AppKit

/// The menu items Otos binds to a key with no modifier (DES-093): the letters (P, U, X,
/// C, E, I, W, Z) and Lightroom's editing punctuation — \ (Show Original), , and .
/// (Select Previous and Next Adjustment), = and - (Increase and Decrease Adjustment).
///
/// A view that takes keys for itself (the grid's type-select, the crop frame's arrows)
/// offers these to the menu bar first, so the command fires whichever view has focus.
nonisolated enum BareMenuKey {
    private static let punctuation: Set<String> = ["\\", ",", ".", "=", "-"]

    /// True when the menu bar took `event` as one of its bare-key commands.
    @MainActor
    static func performMenuCommand(_ event: NSEvent) -> Bool {
        guard isBareMenuKey(event) else { return false }
        return NSApp?.mainMenu?.performKeyEquivalent(with: event) == true
    }

    static func isBareMenuKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
              let chars = event.charactersIgnoringModifiers, chars.count == 1
        else { return false }
        return punctuation.contains(chars) || chars.unicodeScalars.allSatisfy(CharacterSet.letters.contains)
    }
}
