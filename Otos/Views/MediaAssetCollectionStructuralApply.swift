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
        requestVisibleDetails(reason: "structuralApply")
        reportViewport()
        restoreSelection(context.preservedSelection, in: context.grid.orderedAssetIDs)

        let applyMs = DiagnosticsTiming.milliseconds(since: context.applyStart)
        let visibleReloadsStarted = structuralApplyReloadsStarted
        countsStructuralApplyReloads = false
        logFinishedStructuralApply(context, applyMs: applyMs, visibleReloadsStarted: visibleReloadsStarted)
        recordStructuralApplyDiagnostics(
            context,
            diagnostics: diagnostics,
            applyMs: applyMs,
            visibleReloadsStarted: visibleReloadsStarted
        )
        if let operation {
            stallMonitor?.endOperation(operation)
        }
        performApplyGateAction(applyGate.complete(applied: context.grid))
    }

    private func logFinishedStructuralApply(
        _ context: StructuralApplyCompletionContext,
        applyMs: Int,
        visibleReloadsStarted: Int
    ) {
        OtosLog.ui.info(
            """
            Media grid structural apply finished items=\(context.grid.orderedAssetIDs.count, privacy: .public) \
            scope=\(context.grid.scope.diagnosticDescription, privacy: .public) \
            inserted=\(context.insertedCount, privacy: .public) removed=\(context.removedCount, privacy: .public) \
            visibleReloadsStarted=\(visibleReloadsStarted, privacy: .public) \
            applyMs=\(applyMs, privacy: .public)
            """
        )
    }

    private func recordStructuralApplyDiagnostics(
        _ context: StructuralApplyCompletionContext,
        diagnostics: CatalogDiagnostics?,
        applyMs: Int,
        visibleReloadsStarted: Int
    ) {
        let itemCount = context.grid.orderedAssetIDs.count
        let scopeDescription = context.grid.scope.diagnosticDescription
        let insertedCount = context.insertedCount
        let removedCount = context.removedCount
        Task {
            await diagnostics?.record(
                operation: "ui.mediaGrid.structuralApply",
                phase: "finish",
                fields: [
                    "items": "\(itemCount)",
                    "scope": scopeDescription,
                    "inserted": "\(insertedCount)",
                    "removed": "\(removedCount)",
                    "visibleReloadsStarted": "\(visibleReloadsStarted)",
                    "applyMs": "\(applyMs)",
                ]
            )
        }
    }
}
