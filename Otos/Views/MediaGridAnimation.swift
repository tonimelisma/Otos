import Foundation
import QuartzCore

/// Grid animation constants guide
///
/// Every tuned duration, timing curve, and geometric constant for the grid's
/// animated-apply, insert/remove, selection-ring, and thumbnail-arrival polish
/// (spec 0047) lives here so tests and code review reference one source of exact
/// values instead of magic numbers scattered across the AppKit boundary.
nonisolated enum MediaGridAnimation {
    /// Duration for a tuned animated diffable apply (small inserts/removes only —
    /// the reloadData-class fallback for large/reorder-only applies is unaffected).
    static let applyDuration: TimeInterval = 0.35

    /// Ease-out with a mild overshoot. AppKit's `NSAnimationContext` has no spring
    /// API (verified against the Xcode 27 beta macOS SDK: `NSAnimationContext.h`
    /// exposes only `duration` and a `CAMediaTimingFunction`); the overshoot is
    /// approximated with a bezier whose second control point's y exceeds 1.
    static let applyTimingControlPoint1: (x: Float, y: Float) = (0.2, 0.8)
    static let applyTimingControlPoint2: (x: Float, y: Float) = (0.3, 1.05)

    static var applyTimingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(
            controlPoints:
            applyTimingControlPoint1.x,
            applyTimingControlPoint1.y,
            applyTimingControlPoint2.x,
            applyTimingControlPoint2.y
        )
    }

    /// Fraction of an inserted/removed item's own width used to inset its frame on
    /// all sides, read as a centered scale-up/down (macOS layout attributes have no
    /// transform, only frame/size/alpha — verified against `NSCollectionViewLayout.h`).
    static let insertShrinkFraction: CGFloat = 0.06

    static let thumbnailFadeDuration: TimeInterval = 0.18
    static let thumbnailStaggerPerColumn: TimeInterval = 0.02

    static let selectionRingInDuration: TimeInterval = 0.12
    static let selectionRingOutDuration: TimeInterval = 0.10
}
