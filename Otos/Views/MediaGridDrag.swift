import AppKit
import Foundation

/// Grid drag-out guide
///
/// Dragging tiles out of the grid or filmstrip puts the originals' file URLs on the
/// drag pasteboard — one `public.fileURL` per asset in display order, references only
/// (ADR 0028, the same representation ⌘C writes under ADR 0012). Finder copies the
/// files, Mail and Messages attach them; Otos reads no bytes and requests no
/// materialization. A dataless cloud original is downloaded by the receiver, which is
/// the receiver's act on a file the user handed it.
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

    /// One file URL per asset, in the given order. The same objects ⌘C writes.
    static func pasteboardWriters(for ids: [MediaAssetID]) -> [NSURL] {
        ids.map { $0.fileURL as NSURL }
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
