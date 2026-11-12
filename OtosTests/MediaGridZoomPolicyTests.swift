import AppKit
import CoreGraphics
import Foundation
@testable import OtosKit
import Testing

struct MediaGridZoomPolicyTests {
    @Test func nearestToCenterPicksTheTileWhoseCenterIsClosest() {
        let frames = [
            MediaGridZoomPolicy.TileFrame(indexPath: path(0), frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            MediaGridZoomPolicy.TileFrame(indexPath: path(1), frame: CGRect(x: 100, y: 0, width: 100, height: 100)),
            MediaGridZoomPolicy.TileFrame(indexPath: path(2), frame: CGRect(x: 200, y: 0, width: 100, height: 100)),
        ]
        // Frame 1's center (150, 50) is nearest a viewport centered at (160, 60).
        let anchor = MediaGridZoomPolicy.nearestToCenter(
            frames: frames,
            viewportCenter: CGPoint(x: 160, y: 60)
        )
        #expect(anchor == path(1))
    }

    @Test func nearestToCenterBreaksTiesByTakingTheFirstCandidate() {
        // Two frames equidistant from the viewport center.
        let frames = [
            MediaGridZoomPolicy.TileFrame(indexPath: path(0), frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            MediaGridZoomPolicy.TileFrame(indexPath: path(1), frame: CGRect(x: 100, y: 0, width: 100, height: 100)),
        ]
        let viewportCenter = CGPoint(x: 100, y: 50) // equidistant from (50,50) and (150,50)
        let anchor = MediaGridZoomPolicy.nearestToCenter(frames: frames, viewportCenter: viewportCenter)
        #expect(anchor == path(0))

        // Same frames, reversed order — the first candidate in the array still wins,
        // proving the tie-break is order-stable rather than incidental.
        let reversed = Array(frames.reversed())
        let reversedAnchor = MediaGridZoomPolicy.nearestToCenter(frames: reversed, viewportCenter: viewportCenter)
        #expect(reversedAnchor == path(1))
    }

    // MARK: - MediaGridPinchZoomPolicy.consumeSteps

    @Test func consumeStepsPinchInRequestsMoreColumns() {
        let result = MediaGridPinchZoomPolicy.consumeSteps(accumulated: -0.3)
        #expect(result.netSteps == 1)
        #expect(result.remainder == 0)
    }

    @Test func consumeStepsCoalescesMultipleCrossingsIntoOneNetDelta() {
        let result = MediaGridPinchZoomPolicy.consumeSteps(accumulated: 1.0)
        #expect(result.netSteps == -3) // three whole 0.3 crossings
        #expect(abs(result.remainder - 0.1) < 0.0001)
    }

    @Test func consumeStepsRetainsSubThresholdRemainderForTheNextCall() {
        let first = MediaGridPinchZoomPolicy.consumeSteps(accumulated: 0.25)
        #expect(first.netSteps == 0)
        #expect(first.remainder == 0.25)

        // Feeding the retained remainder back in, plus a bit more, crosses the threshold.
        let second = MediaGridPinchZoomPolicy.consumeSteps(accumulated: first.remainder + 0.1)
        #expect(second.netSteps == -1)
    }
}

private func path(_ item: Int) -> IndexPath {
    IndexPath(item: item, section: 0)
}
