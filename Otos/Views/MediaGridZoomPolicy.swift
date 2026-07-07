import CoreGraphics
import Foundation

/// Grid zoom anchor guide
///
/// Pure geometry: given the frames of currently visible tiles and the viewport's
/// center point, picks the tile whose frame center is nearest that point. The
/// zoom swap scrolls back to this tile after the layout change so "the middle
/// row stays" (spec 0048) instead of the viewport drifting to an arbitrary
/// scroll offset when tile sizes change. Kept independent of `NSCollectionView`
/// so it is directly unit-testable.
nonisolated enum MediaGridZoomPolicy {
    struct TileFrame {
        let indexPath: IndexPath
        let frame: CGRect
    }

    /// Returns the index path whose frame center is nearest `viewportCenter`, or `nil`
    /// for an empty grid. Ties resolve to the first tile in `frames`' order, so passing
    /// frames in a stable (e.g. index-path-sorted) order keeps the pick deterministic.
    static func nearestToCenter(frames: [TileFrame], viewportCenter: CGPoint) -> IndexPath? {
        var best: TileFrame?
        var bestDistanceSquared = CGFloat.greatestFiniteMagnitude
        for candidate in frames {
            let distanceSquared = distanceSquared(from: candidate.frame, to: viewportCenter)
            if distanceSquared < bestDistanceSquared {
                bestDistanceSquared = distanceSquared
                best = candidate
            }
        }
        return best?.indexPath
    }

    private static func distanceSquared(from frame: CGRect, to point: CGPoint) -> CGFloat {
        let dx = frame.midX - point.x
        let dy = frame.midY - point.y
        return dx * dx + dy * dy
    }
}

/// Pinch-to-zoom step consumption guide
///
/// `NSMagnificationGestureRecognizer.magnification` is cumulative since the gesture
/// began; the controller resets it to 0 after each read, so `accumulated` here is the
/// incremental magnification since the last consume call. Returns the *net* column-count
/// delta for every whole threshold crossing rather than one delta per crossing, because
/// the installed column count does not update until the round trip through
/// `onColumnCountChangeRequested` → the ViewModel intent → SwiftUI →
/// `receiveColumnCount(_:)` completes; the controller therefore adds this net delta to the
/// mutation gate's newest `requestedColumnCount` (not an already-installed value) so a
/// synchronous burst of crossings accumulates instead of requesting the same target
/// repeatedly.
nonisolated enum MediaGridPinchZoomPolicy {
    static func consumeSteps(
        accumulated: CGFloat,
        threshold: CGFloat = 0.3
    ) -> (netSteps: Int, remainder: CGFloat) {
        var remainder = accumulated
        var netSteps = 0
        while abs(remainder) >= threshold {
            // Pinch out (positive) is zoom in: fewer columns.
            netSteps += remainder > 0 ? -1 : 1
            remainder += remainder > 0 ? -threshold : threshold
        }
        return (netSteps, remainder)
    }
}
