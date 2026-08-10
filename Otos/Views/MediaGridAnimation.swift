import AppKit
import Foundation
import QuartzCore

/// Grid animation constants guide
///
/// Every tuned duration, timing curve, and geometric constant for the grid's
/// animated-apply, insert/remove, selection-ring, and thumbnail-arrival polish
/// (spec 0047) lives here so tests and code review reference one source of exact
/// values instead of magic numbers scattered across the AppKit boundary.
nonisolated enum MediaGridAnimation {
    /// Duration for a tuned animated diffable apply (small inserts/removes and
    /// same-descriptor reorder-only applies). Descriptor-changed reorders and
    /// large membership applies keep the unanimated reloadData-class path.
    static let applyDuration: TimeInterval = 0.35

    /// Quiet window after the last scroll-bounds tick before a move animation is
    /// allowed and before the mutation gate releases scroll-hold (Part C). One
    /// coalesced scroll flush is 16 ms; 250 ms of quiet means the user has
    /// plausibly stopped. Shared by animation suppress and `endScrollHold`.
    static let applyAnimationScrollQuietThreshold: TimeInterval = 0.25

    /// During live scrolling a move animation is invisible churn; apply instantly
    /// instead. Never downgrades `animatingDifferences` — that path is the
    /// reloadData teardown plan 0008 removed.
    nonisolated static func suppressesApplyAnimation(
        lastScrollTickAge: TimeInterval
    ) -> Bool {
        lastScrollTickAge < applyAnimationScrollQuietThreshold
    }

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

    static let selectionRingInDuration: TimeInterval = 0.12
    static let selectionRingOutDuration: TimeInterval = 0.10

    /// Duration for an animated grid-zoom column-count swap (spec 0048).
    static let zoomDuration: TimeInterval = 0.30
    static var zoomTimingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(name: .easeInEaseOut)
    }

    /// Reduce Motion is an accessibility display setting, not a preference: a user who
    /// enables it is telling the system that motion causes them discomfort. Every
    /// animated path — structural applies, insert/remove, thumbnail fade, selection
    /// ring, zoom reflow — resolves through this one value so no site can forget it.
    nonisolated static var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
