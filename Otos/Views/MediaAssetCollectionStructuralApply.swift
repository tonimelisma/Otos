import AppKit
import Foundation
import OSLog

extension MediaAssetCollectionViewController {
    struct StructuralApplyCompletionContext {
        let grid: CatalogMediaGridState
        let preservedSelection: Set<MediaAssetID>
        let resetSelection: Bool
        let resetScroll: Bool
        let applyStart: Date
        let insertedCount: Int
        let removedCount: Int
        let reorderOnly: Bool
        let largeApply: Bool
        let animatingDifferences: Bool
        let usesReloadDataFallback: Bool
        let signpost: OSSignpostIntervalState
    }

    func applyStructure(
        _ grid: CatalogMediaGridState,
        resetScroll: Bool,
        resetSelection: Bool
    ) {
        let operation = stallMonitor?.beginOperation("MediaAssetCollectionViewController.applyStructure")
        let applyStart = Date()
        let summary = MediaGridStructuralApplyPolicy.summarize(
            previousOrderedIDs: applyGate.displayedOrderedIDs,
            nextOrderedIDs: grid.orderedAssetIDs
        )
        // Snapshot the selected identities before the diffable apply can drop or shift
        // them. Query-descriptor changes are user context changes, so they intentionally
        // start from an empty selection instead of restoring surviving identities.
        let preservedSelection = resetSelection ? [] : selectedIdentities()

        // Identity order is the complete structural contract. Tile details are
        // read for visible identities after the structural apply, so thumbnail
        // or video-badge changes never require this O(n) diffable snapshot path.
        let snapshot = mediaSnapshot(for: grid.orderedAssetIDs)

        let signpost = OtosSignpost.ui.beginInterval("MediaGridStructuralApply")
        logStartedStructuralApply(grid, resetScroll: resetScroll, summary: summary)
        let stallMonitor = stallMonitor
        let diagnostics = diagnostics
        let context = StructuralApplyCompletionContext(
            grid: grid,
            preservedSelection: preservedSelection,
            resetSelection: resetSelection,
            resetScroll: resetScroll,
            applyStart: applyStart,
            insertedCount: summary.insertedCount,
            removedCount: summary.removedCount,
            reorderOnly: summary.reorderOnly,
            largeApply: summary.largeApply,
            animatingDifferences: summary.animatingDifferences,
            usesReloadDataFallback: summary.usesReloadDataFallback,
            signpost: signpost
        )
        let completion = { [weak self, operation, stallMonitor, diagnostics, context] in
            guard let self else {
                if let operation {
                    stallMonitor?.endOperation(operation)
                }
                return
            }
            completeStructuralApply(
                context,
                operation: operation,
                stallMonitor: stallMonitor,
                diagnostics: diagnostics
            )
        }
        applySnapshot(snapshot, summary: summary, completion: completion)
    }

    private func logStartedStructuralApply(
        _ grid: CatalogMediaGridState,
        resetScroll: Bool,
        summary: MediaGridStructuralApplyPolicy
    ) {
        OtosLog.ui.debug(
            """
            Media grid structural apply started items=\(grid.orderedAssetIDs.count, privacy: .public) \
            scope=\(grid.scope.diagnosticDescription, privacy: .public) \
            resetScroll=\(resetScroll, privacy: .public) \
            reorderOnly=\(summary.reorderOnly, privacy: .public) \
            largeApply=\(summary.largeApply, privacy: .public) \
            animating=\(summary.animatingDifferences, privacy: .public) \
            reloadDataFallback=\(summary.usesReloadDataFallback, privacy: .public)
            """
        )
    }

    /// The `animatingDifferences: false` branch is the measured reloadData-class fallback
    /// (spec 0039) and stays byte-for-byte as a plain `apply` call. Only the already-animating
    /// small-apply branch gets the tuned duration/timing curve, wrapped in an explicit
    /// `NSAnimationContext` group so it does not affect the fallback path (spec 0047).
    private func applySnapshot(
        _ snapshot: NSDiffableDataSourceSnapshot<Section, MediaAssetID>,
        summary: MediaGridStructuralApplyPolicy,
        completion: @escaping () -> Void
    ) {
        guard summary.animatingDifferences else {
            dataSource.apply(snapshot, animatingDifferences: false, completion: completion)
            return
        }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = MediaGridAnimation.applyDuration
        NSAnimationContext.current.timingFunction = MediaGridAnimation.applyTimingFunction
        dataSource.apply(snapshot, animatingDifferences: true, completion: completion)
        NSAnimationContext.endGrouping()
    }

    private func mediaSnapshot(
        for orderedIDs: [MediaAssetID]
    ) -> NSDiffableDataSourceSnapshot<Section, MediaAssetID> {
        var snapshot = NSDiffableDataSourceSnapshot<Section, MediaAssetID>()
        snapshot.appendSections([.media])
        snapshot.appendItems(orderedIDs, toSection: .media)
        return snapshot
    }

    func completeStructuralApply(
        _ context: StructuralApplyCompletionContext,
        operation: MainRunLoopOperationToken?,
        stallMonitor: MainRunLoopStallMonitor?,
        diagnostics: CatalogDiagnostics?
    ) {
        OtosSignpost.ui.endInterval("MediaGridStructuralApply", context.signpost)
        OtosSignpost.ui.emitEvent("MediaGridStructuralApplyCompleted")

        if context.resetScroll {
            scrollToTop()
        }
        let visibleDetailRequestCount = requestVisibleDetails(reason: "structuralApply")
        reportViewport()
        let preheatCount = preheatLookahead(reason: "structuralApply")
        // A descriptor-changing apply is a user context change and must clear the
        // selection and shift-click anchor unconditionally, exactly like the
        // `.refreshVisible` descriptor-change path — `restoreSelection`'s anchor prune
        // only clears an anchor whose *asset* left the new ordered IDs, which is not the
        // same thing as "the descriptor changed" (the previously anchored asset can
        // still be present in a new scope/sort/filter's results).
        if context.resetSelection {
            clearSelection(reason: "descriptorChange")
        } else {
            restoreSelection(context.preservedSelection, in: context.grid.orderedAssetIDs)
        }

        let applyMs = DiagnosticsTiming.milliseconds(since: context.applyStart)
        logFinishedStructuralApply(
            context,
            applyMs: applyMs,
            visibleDetailRequestCount: visibleDetailRequestCount,
            preheatCount: preheatCount
        )
        recordStructuralApplyDiagnostics(
            context,
            diagnostics: diagnostics,
            applyMs: applyMs,
            visibleDetailRequestCount: visibleDetailRequestCount,
            preheatCount: preheatCount
        )
        if let operation {
            stallMonitor?.endOperation(operation)
        }
        performApplyGateAction(applyGate.complete(applied: context.grid))
        // A zoom requested while this apply was in flight is deferred exactly once here
        // (spec 0048) — never run a layout swap concurrently with a diffable apply.
        // `setColumnCount` re-defers on its own if `applyGate.complete` just started
        // another apply from a pending grid state.
        if let pendingColumnCount {
            self.pendingColumnCount = nil
            setColumnCount(pendingColumnCount)
        }
    }

    private func logFinishedStructuralApply(
        _ context: StructuralApplyCompletionContext,
        applyMs: Int,
        visibleDetailRequestCount: Int,
        preheatCount: Int
    ) {
        OtosLog.ui.info(
            """
            Media grid structural apply finished items=\(context.grid.orderedAssetIDs.count, privacy: .public) \
            scope=\(context.grid.scope.diagnosticDescription, privacy: .public) \
            inserted=\(context.insertedCount, privacy: .public) removed=\(context.removedCount, privacy: .public) \
            reorderOnly=\(context.reorderOnly, privacy: .public) \
            largeApply=\(context.largeApply, privacy: .public) \
            animating=\(context.animatingDifferences, privacy: .public) \
            reloadDataFallback=\(context.usesReloadDataFallback, privacy: .public) \
            visibleDetailRequestCount=\(visibleDetailRequestCount, privacy: .public) \
            preheatCount=\(preheatCount, privacy: .public) \
            applyMs=\(applyMs, privacy: .public)
            """
        )
    }

    private func recordStructuralApplyDiagnostics(
        _ context: StructuralApplyCompletionContext,
        diagnostics: CatalogDiagnostics?,
        applyMs: Int,
        visibleDetailRequestCount: Int,
        preheatCount: Int
    ) {
        let itemCount = context.grid.orderedAssetIDs.count
        let scopeDescription = context.grid.scope.diagnosticDescription
        let insertedCount = context.insertedCount
        let removedCount = context.removedCount
        let reorderOnly = context.reorderOnly
        let largeApply = context.largeApply
        let animatingDifferences = context.animatingDifferences
        let usesReloadDataFallback = context.usesReloadDataFallback
        Task {
            await diagnostics?.record(
                operation: "ui.mediaGrid.structuralApply",
                phase: "finish",
                fields: [
                    "items": "\(itemCount)",
                    "scope": scopeDescription,
                    "inserted": "\(insertedCount)",
                    "removed": "\(removedCount)",
                    "reorderOnly": "\(reorderOnly)",
                    "largeApply": "\(largeApply)",
                    "animatingDifferences": "\(animatingDifferences)",
                    "reloadDataFallback": "\(usesReloadDataFallback)",
                    "visibleDetailRequestCount": "\(visibleDetailRequestCount)",
                    "preheatCount": "\(preheatCount)",
                    "applyMs": "\(applyMs)",
                ]
            )
        }
    }
}
