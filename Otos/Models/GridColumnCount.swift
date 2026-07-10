import Foundation

/// Grid zoom column-count policy guide
///
/// Pure bounds/validation logic for the media grid's user-adjustable column count
/// (spec 0048), independent of `UserDefaults` or AppKit so it is directly
/// unit-testable. Two distinct rules exist because they answer different
/// questions: `clamped` answers "what is the nearest valid value to a deliberate
/// user request" (a zoom-out request one step past the minimum should land on the
/// minimum, not silently reset to the default); `validated` answers "is this a
/// trustworthy stored preference" (a missing or corrupted preference should not
/// be treated as if the user had deliberately requested the nearest bound).
nonisolated enum GridColumnCount {
    static let minimum = 3
    static let maximum = 9
    static let defaultValue = 6

    /// Clamps a requested column count (zoom in/out, slider, pinch) into the valid range.
    static func clamped(_ requested: Int) -> Int {
        min(max(requested, minimum), maximum)
    }

    /// Validates a raw stored value (e.g. from `UserDefaults`); anything outside the
    /// valid range, including an unset/zero value, falls back to the default.
    static func validated(_ stored: Int) -> Int {
        (minimum ... maximum).contains(stored) ? stored : defaultValue
    }
}
