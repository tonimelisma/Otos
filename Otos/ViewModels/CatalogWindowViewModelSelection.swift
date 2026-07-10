import AppKit
import Foundation
import OSLog

/// Catalog window selection ownership guide
///
/// `CatalogWindowViewModel` owns the pure `GridSelection` value (selection, ⇧-range
/// anchor, base islands) that is the single source of mouse-selection truth. The AppKit
/// grid and filmstrip are renderers of that value: they swallow `mouseDown`, forward
/// `(hit, modifiers)` synchronously into these intents, receive the updated model as the
/// return value, and write `selectionIndexPaths` from it as the last operation of the
/// gesture — same thread, same ordering, no SwiftUI round-trip on the write path.
///
/// Why the ViewModel owns selection rather than the collection-view controller: loupe and
/// compare both need the selection + anchor, and the AppKit controller deallocates when
/// SwiftUI swaps the detail surface. Two renderers of one selection truth means the truth
/// must live above both. Spec 0046's race-free property is preserved exactly — only the
/// owner of the value moved.
///
/// Native keyboard selection (⌘A, ⇧-arrows) still writes `selectionIndexPaths` directly;
/// the controller reconciles upward through `reconcileNativeSelection`, which is
/// idempotent when a programmatic delta write echoes an equal set (no feedback loop).
extension CatalogWindowViewModel {
    /// The ⇧-range / "active photo" anchor, if any.
    var selectionAnchor: MediaAssetID? {
        gridSelection.anchor
    }

    /// Selected identities in current display order.
    var orderedSelectedAssetIDs: [MediaAssetID] {
        GridSelection.orderedSelection(
            gridSelection.selection,
            in: state.mediaGrid.orderedAssetIDs
        )
    }

    /// Synchronous mouse-gesture intent. Reconciles any native keyboard selection that
    /// landed since the last model write, applies the gesture against the model alone,
    /// and returns the updated value so the controller can write `selectionIndexPaths`
    /// as the gesture's last operation.
    @discardableResult
    func applyGridClick(
        hit: MediaAssetID?,
        modifiers: NSEvent.ModifierFlags,
        orderedIDs: [MediaAssetID],
        liveSelection: Set<MediaAssetID>
    ) -> GridSelection {
        gridSelection = gridSelection.reconcilingSelection(liveSelection)

        let shift = modifiers.contains(.shift)
        let command = modifiers.contains(.command)

        guard let hit else {
            if !shift, !command {
                gridSelection = gridSelection.clearedBySpace()
            }
            return gridSelection
        }

        switch (shift, command) {
        case (false, false):
            gridSelection = gridSelection.plainClick(hit)
        case (false, true):
            gridSelection = gridSelection.commandClick(hit)
        case (true, false):
            gridSelection = gridSelection.shiftClick(hit, orderedIDs: orderedIDs)
        case (true, true):
            gridSelection = gridSelection.commandShiftClick(hit, orderedIDs: orderedIDs)
        }
        return gridSelection
    }

    /// Adopts a live AppKit selection written by native keyboard handling (⌘A,
    /// ⇧-arrows). Idempotent when `live` already equals `gridSelection.selection`.
    @discardableResult
    func reconcileNativeSelection(_ live: Set<MediaAssetID>) -> GridSelection {
        gridSelection = gridSelection.reconcilingSelection(live)
        return gridSelection
    }

    /// Structural-apply survivor prune. Reconciles against the pre-apply snapshot, then
    /// drops identities that left the display order (and clears anchor/base when the
    /// anchor itself left). An empty post-reconcile selection collapses to `.empty`.
    @discardableResult
    func pruneSelection(
        preserved: Set<MediaAssetID>,
        to orderedIDs: [MediaAssetID]
    ) -> GridSelection {
        let reconciled = gridSelection.reconcilingSelection(preserved)
        gridSelection = reconciled.selection.isEmpty
            ? GridSelection.empty
            : reconciled.pruned(to: orderedIDs)
        return gridSelection
    }

    /// Descriptor-change clear. Resets selection, anchor, and base unconditionally.
    func clearGridSelection(reason: String) {
        guard gridSelection != .empty else {
            return
        }
        gridSelection = .empty
        OtosLog.ui.debug(
            "Catalog selection cleared reason=\(reason, privacy: .public)"
        )
    }
}

/// Closure bundle the AppKit bridge injects so the controller never owns selection
/// truth. Every call is synchronous on the MainActor; the controller writes AppKit
/// selection from the returned model as the gesture's last operation.
struct MediaGridSelectionHandlers {
    var currentSelection: () -> GridSelection = { .empty }
    var applyClick: (
        _ hit: MediaAssetID?,
        _ modifiers: NSEvent.ModifierFlags,
        _ orderedIDs: [MediaAssetID],
        _ liveSelection: Set<MediaAssetID>
    ) -> GridSelection = { _, _, _, _ in .empty }
    var reconcileNative: (Set<MediaAssetID>) -> GridSelection = { _ in .empty }
    var prune: (
        _ preserved: Set<MediaAssetID>,
        _ orderedIDs: [MediaAssetID]
    ) -> GridSelection = { _, _ in .empty }
    var clear: (String) -> Void = { _ in }

    /// Wires the ViewModel's selection intents into the bridge.
    @MainActor
    static func from(_ viewModel: CatalogWindowViewModel) -> MediaGridSelectionHandlers {
        MediaGridSelectionHandlers(
            currentSelection: { viewModel.gridSelection },
            applyClick: { hit, modifiers, orderedIDs, live in
                viewModel.applyGridClick(
                    hit: hit,
                    modifiers: modifiers,
                    orderedIDs: orderedIDs,
                    liveSelection: live
                )
            },
            reconcileNative: { live in
                viewModel.reconcileNativeSelection(live)
            },
            prune: { preserved, ordered in
                viewModel.pruneSelection(preserved: preserved, to: ordered)
            },
            clear: { reason in
                viewModel.clearGridSelection(reason: reason)
            }
        )
    }
}
