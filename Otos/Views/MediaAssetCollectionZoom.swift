import AppKit
import OSLog

// Grid zoom guide
//
// User-adjustable column count (3–9, spec 0048). All zoom surfaces — the View menu,
// the toolbar slider, and this file's pinch gesture — drive one ViewModel intent
// (`CatalogWindowViewModel.setGridColumnCount`). The pinch gesture never mutates
// column-count truth or the collection view's layout directly: it only calls
// `onColumnCountChangeRequested`, and the swap happens only when the ViewModel's
// published value round-trips back into `updateNSViewController`, which calls
// `receiveColumnCount(_:)` on every SwiftUI update — the same call the menu and slider's
// requests arrive through. That one path is what keeps pinch, menu, and slider, and
// any future automation, from diverging.
//
// A zoom swap never overlaps a diffable structural apply, in either direction: the
// arbitration lives entirely in `MediaGridMutationGate`, which owns `installedColumnCount`
// and `requestedColumnCount` and hands back a `.zoomSwap` action only when no other
// exclusive mutation is in flight. `performZoomSwap(to:)` runs the animated layout swap
// and, on completion, calls `mutationGate.completeZoomSwap(installed:)` to drain any grid
// state that arrived mid-animation — that completion is what closes the reverse window
// (an apply requested during a swap).

extension MediaAssetCollectionViewController {
    func configurePinchZoomGesture() {
        let recognizer = NSMagnificationGestureRecognizer(
            target: self,
            action: #selector(handleMagnification(_:))
        )
        collectionView.addGestureRecognizer(recognizer)
    }

    @objc private func handleMagnification(_ recognizer: NSMagnificationGestureRecognizer) {
        switch recognizer.state {
        case .began:
            pinchAnchorIndexPath = collectionView.indexPathForItem(at: recognizer.location(in: collectionView))
            pinchAccumulatedMagnification = 0
        case .changed:
            // `magnification` is cumulative since the gesture began; resetting it to 0
            // after reading turns each `.changed` delivery into an incremental delta.
            pinchAccumulatedMagnification += recognizer.magnification
            recognizer.magnification = 0
            consumePinchSteps()
        case .ended, .cancelled, .failed:
            pinchAccumulatedMagnification = 0
            pinchAnchorIndexPath = nil
        default:
            break
        }
    }

    /// Requests the net column-count delta for every whole threshold crossing since the
    /// last consume, in one call — see `MediaGridPinchZoomPolicy` for why a burst of
    /// crossings is coalesced into one request rather than one request per crossing.
    /// The base is the gate's `requestedColumnCount` (the newest value the gate has
    /// accepted), not a controller-local count, so a rapid burst of steps accumulates
    /// correctly even before the ViewModel round-trip lands. This method never installs a
    /// layout itself.
    private func consumePinchSteps() {
        let result = MediaGridPinchZoomPolicy.consumeSteps(accumulated: pinchAccumulatedMagnification)
        pinchAccumulatedMagnification = result.remainder
        guard result.netSteps != 0 else {
            return
        }
        onColumnCountChangeRequested(mutationGate.requestedColumnCount + result.netSteps)
    }

    /// Installs a new column-count layout. Only ever reached through the gate's
    /// `.zoomSwap` action (via `perform(_:)`), so it never runs concurrently with a
    /// structural apply. On completion it calls `mutationGate.completeZoomSwap(installed:)`
    /// and executes whatever that drain returns.
    func performZoomSwap(to requested: Int) {
        let anchor = pinchAnchorIndexPath ?? centerAnchorIndexPath()
        let trigger = pinchAnchorIndexPath != nil ? "pinch" : "external"
        let oldCount = mutationGate.installedColumnCount
        let signpost = OtosSignpost.ui.beginInterval("MediaGridZoomApply")

        // Before the view is in a window (the first SwiftUI update installing a persisted
        // count), animating a not-yet-visible view is pointless work and makes launch
        // timing test-hostile: install the layout directly and complete synchronously.
        guard collectionView.window != nil else {
            collectionView.collectionViewLayout = Self.makeLayout(columnCount: requested)
            finishZoomSwap(
                signpost: signpost,
                oldCount: oldCount,
                newCount: requested,
                anchorPresent: anchor != nil,
                trigger: trigger
            )
            return
        }

        NSAnimationContext.runAnimationGroup { [weak self] context in
            guard let self else {
                return
            }
            context.duration = MediaGridAnimation.zoomDuration
            context.timingFunction = MediaGridAnimation.zoomTimingFunction
            collectionView.animator().collectionViewLayout = Self.makeLayout(columnCount: requested)
            if let anchor {
                collectionView.animator().scrollToItems(at: [anchor], scrollPosition: .centeredVertically)
            }
        } completionHandler: { [weak self] in
            self?.finishZoomSwap(
                signpost: signpost,
                oldCount: oldCount,
                newCount: requested,
                anchorPresent: anchor != nil,
                trigger: trigger
            )
        }
    }

    private func finishZoomSwap(
        signpost: OSSignpostIntervalState,
        oldCount: Int,
        newCount: Int,
        anchorPresent: Bool,
        trigger: String
    ) {
        OtosSignpost.ui.endInterval("MediaGridZoomApply", signpost)
        OtosLog.ui.info(
            """
            Media grid zoom applied columns=\(oldCount, privacy: .public)→\(newCount, privacy: .public) \
            anchorPresent=\(anchorPresent, privacy: .public) trigger=\(trigger, privacy: .public)
            """
        )
        // The viewport now holds a different identity set at a different size.
        _ = requestVisibleDetails(reason: "zoom")
        reportViewport()
        preheatLookahead(reason: "zoom")
        // Adopt the installed count and drain any grid state (or further zoom) that
        // arrived while this swap was animating — this closes the apply-during-zoom window.
        perform(mutationGate.completeZoomSwap(installed: newCount))
    }

    /// The visible tile whose frame center is nearest the viewport's center — "the
    /// middle row stays" across a zoom. `nil` for an empty grid.
    private func centerAnchorIndexPath() -> IndexPath? {
        let visibleRect = scrollView.contentView.bounds
        guard visibleRect.width > 0, visibleRect.height > 0,
              let attributes = collectionView.collectionViewLayout?.layoutAttributesForElements(in: visibleRect)
        else {
            return nil
        }
        let frames = attributes.compactMap { attribute -> MediaGridZoomPolicy.TileFrame? in
            guard let indexPath = attribute.indexPath else {
                return nil
            }
            return MediaGridZoomPolicy.TileFrame(indexPath: indexPath, frame: attribute.frame)
        }
        let viewportCenter = CGPoint(x: visibleRect.midX, y: visibleRect.midY)
        return MediaGridZoomPolicy.nearestToCenter(frames: frames, viewportCenter: viewportCenter)
    }
}
