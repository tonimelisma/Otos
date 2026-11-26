import AppKit
import Foundation

/// Grid drag-out guide
///
/// Dragging tiles out of the grid or filmstrip hands each asset over as ⌘C does (ADR 0028,
/// ADR 0012, ADR 0037): one writer per asset in display order, chosen by
/// `CatalogWindowViewModel.dragWriters(for:)`. That is the `public.file-url` of a file that
/// is ready — an unedited still or video's original (a cloud placeholder as it is, since a
/// drag cannot wait: the receiver downloads it), or a file already prepared this launch —
/// or a file promise that prepares the photo's file when the receiver asks.
///
/// Because `MediaGridCollectionView` owns `mouseDown` and never calls `super`, AppKit's
/// own drag initiation never runs; the view detects the drag itself and the controller
/// starts the session. Two Finder rules are kept: a drag that starts on a selected tile
/// carries the whole selection, and a plain click on a selected tile collapses the
/// selection only on mouse-up, so the mouse-down that begins a multi-item drag does not
/// first destroy the selection it is about to drag.
nonisolated enum MediaGridClickDecision: Equatable {
    /// Apply the click to the selection model now.
    case select
    /// A plain click on an already-selected tile: it may become a drag, so the
    /// selection change waits for mouse-up.
    case deferUntilMouseUp
    /// Apply the click, then open the item.
    case doubleClick
}

nonisolated enum MediaGridDragPolicy {
    /// Pointer travel before a mouse-down becomes a drag, in points.
    static let dragThreshold: CGFloat = 4

    static func decision(
        hasHit: Bool,
        hitIsSelected: Bool,
        isPlainClick: Bool,
        clickCount: Int
    ) -> MediaGridClickDecision {
        guard hasHit, isPlainClick else { return .select }
        if clickCount == 2 {
            return .doubleClick
        }
        return hitIsSelected && clickCount == 1 ? .deferUntilMouseUp : .select
    }

    /// The assets a drag from `hit` carries: the whole selection in display order when
    /// the hit is part of it, otherwise the hit alone.
    static func draggedIDs(
        hit: MediaAssetID,
        selection: Set<MediaAssetID>,
        orderedIDs: [MediaAssetID]
    ) -> [MediaAssetID] {
        guard selection.contains(hit) else { return [hit] }
        return orderedIDs.filter { selection.contains($0) }
    }
}

/// The drag source for grid and filmstrip sessions. Outside Otos a drop copies the
/// files; inside Otos there is nothing to drop onto, so the mask is empty and AppKit
/// draws the "no drop" cursor rather than pretending.
final class MediaGridDragSource: NSObject, NSDraggingSource {
    var onEnd: (NSDragOperation) -> Void = { _ in }

    nonisolated static func operationMask(for context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .outsideApplication: .copy
        case .withinApplication: []
        @unknown default: []
        }
    }

    func draggingSession(_: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        Self.operationMask(for: context)
    }

    func draggingSession(_: NSDraggingSession, endedAt _: NSPoint, operation: NSDragOperation) {
        onEnd(operation)
    }
}
