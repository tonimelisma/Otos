import Foundation
import OSLog

extension MediaAssetCollectionViewController {
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
        restoreSelection(context.preservedSelection, in: context.grid.orderedAssetIDs)

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
            zeroDuration=\(context.usesZeroDurationAnimation, privacy: .public) \
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
        let usesZeroDurationAnimation = context.usesZeroDurationAnimation
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
                    "zeroDuration": "\(usesZeroDurationAnimation)",
                    "visibleDetailRequestCount": "\(visibleDetailRequestCount)",
                    "preheatCount": "\(preheatCount)",
                    "applyMs": "\(applyMs)",
                ]
            )
        }
    }
}
