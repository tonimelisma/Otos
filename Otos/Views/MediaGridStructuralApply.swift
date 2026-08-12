import AppKit
import Foundation
import OSLog

extension MediaGridViewController {
    struct StructuralApplyCompletionContext {
        let grid: CatalogMediaGridState
        let resetScroll: Bool
        let applyStart: Date
        let applyCallStart: Date
        let diffPolicyMs: Int
        let snapshotBuildMs: Int
        let insertedCount: Int
        let removedCount: Int
        let reorderOnly: Bool
        let largeApply: Bool
        let animatingDifferences: Bool
        let animationSuppressed: Bool
        let usesReloadDataFallback: Bool
        let heldDuringScroll: Bool
        let signpost: OSSignpostIntervalState
    }

    func applyStructure(
        _ grid: CatalogMediaGridState,
        resetScroll: Bool,
        descriptorChanged: Bool
    ) {
        let operation = stallMonitor?.beginOperation("MediaGridViewController.applyStructure")
        let applyStart = Date()
        let policyStart = applyStart
        let summary = MediaGridStructuralApplyPolicy.summarize(
            previousOrderedIDs: mutationGate.displayedOrderedIDs,
            previousOrderedIDSet: mutationGate.displayedOrderedIDSet,
            nextOrderedIDs: grid.orderedAssetIDs,
            descriptorChanged: descriptorChanged
        )
        let diffPolicyMs = DiagnosticsTiming.milliseconds(since: policyStart)

        // Identity order is the complete structural contract. Tile details are
        // read for visible identities after the structural apply, so thumbnail
        // or video-badge changes never require this O(n) diffable snapshot path.
        // Selection truth lives in the ViewModel and is already pruned/cleared in
        // `applyState` before this apply runs; completion only renders the model.
        let snapshotStart = Date()
        let snapshot = mediaSnapshot(for: grid.orderedAssetIDs)
        let snapshotBuildMs = DiagnosticsTiming.milliseconds(since: snapshotStart)

        let signpost = OtosSignpost.ui.beginInterval("MediaGridStructuralApply")
        logStartedStructuralApply(grid, resetScroll: resetScroll, summary: summary)
        let stallMonitor = stallMonitor
        let applyCallStart = Date()
        let animationSuppressed = summary.animatingDifferences
            && (MediaGridAnimation.prefersReducedMotion
                || MediaGridAnimation.suppressesApplyAnimation(
                    lastScrollTickAge: Date().timeIntervalSince(lastScrollTickAt)
                ))
        let context = StructuralApplyCompletionContext(
            grid: grid,
            resetScroll: resetScroll,
            applyStart: applyStart,
            applyCallStart: applyCallStart,
            diffPolicyMs: diffPolicyMs,
            snapshotBuildMs: snapshotBuildMs,
            insertedCount: summary.insertedCount,
            removedCount: summary.removedCount,
            reorderOnly: summary.reorderOnly,
            largeApply: summary.largeApply,
            animatingDifferences: summary.animatingDifferences,
            animationSuppressed: animationSuppressed,
            usesReloadDataFallback: summary.usesReloadDataFallback,
            heldDuringScroll: mutationGate.lastDrainedHeldDuringScroll,
            signpost: signpost
        )
        let completion = { [weak self, operation, stallMonitor, context] in
            guard let self else {
                if let operation {
                    stallMonitor?.endOperation(operation)
                }
                return
            }
            completeStructuralApply(
                context,
                operation: operation,
                stallMonitor: stallMonitor
            )
        }
        applySnapshot(
            snapshot,
            summary: summary,
            animationSuppressed: animationSuppressed,
            completion: completion
        )
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

    /// Animated branch (`animatingDifferences: true`): small insert/remove and
    /// same-descriptor reorder-only applies (enrichment trickle). Tuned duration/
    /// timing via an explicit `NSAnimationContext` group. Moves surviving items
    /// instead of recreating them (ADR 0006). During live scrolling the group
    /// keeps `animatingDifferences: true` but sets `duration = 0` so completion
    /// semantics stay identical without feeding CA commit pressure.
    ///
    /// Unanimated branch (`false`): descriptor-changed reorders and large
    /// membership applies — AppKit's reloadData-class path. Scroll resets on
    /// descriptor change anyway; large membership diffs stay off the quadratic
    /// true-diff cliff (research harness: ~23–28 ms call-to-return for K = 1–3
    /// moves at n = 23k; cliff above ~1k movers).
    private func applySnapshot(
        _ snapshot: NSDiffableDataSourceSnapshot<Section, MediaAssetID>,
        summary: MediaGridStructuralApplyPolicy,
        animationSuppressed: Bool,
        completion: @escaping () -> Void
    ) {
        guard summary.animatingDifferences else {
            dataSource.apply(snapshot, animatingDifferences: false, completion: completion)
            return
        }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = animationSuppressed
            ? 0
            : MediaGridAnimation.applyDuration
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
        stallMonitor: MainRunLoopStallMonitor?
    ) {
        let applyCallMs = DiagnosticsTiming.milliseconds(since: context.applyCallStart)
        let completionStart = Date()
        OtosSignpost.ui.endInterval("MediaGridStructuralApply", context.signpost)
        stallMonitor?.completeIntentToPaint(appliedScope: context.grid.scope)

        if context.resetScroll {
            scrollToTop()
        }
        // Reorder-only applies keep identical membership by definition; prune's
        // Set(orderedAssetIDs) rebuild would be a ~27 ms no-op at 23k scale.
        if !context.reorderOnly {
            tileContents.prune(to: Set(context.grid.orderedAssetIDs))
        }
        let (visibleDetailRequestCount, preheatCount) = runPostApplyDetailAndPreheatPass(
            reason: "structuralApply"
        )
        // Model → view only. Prune/clear already ran in ViewModel.applyState.
        renderSelectionFromModel(reason: "structuralApply")
        if let pending = pendingFocusTargetID {
            scrollToFocusTarget(pending)
        }

        let completionMs = DiagnosticsTiming.milliseconds(since: completionStart)
        let applyMs = DiagnosticsTiming.milliseconds(since: context.applyStart)
        logFinishedStructuralApply(
            context,
            applyMs: applyMs,
            applyCallMs: applyCallMs,
            completionMs: completionMs,
            visibleDetailRequestCount: visibleDetailRequestCount,
            preheatCount: preheatCount
        )
        recordStructuralApplyDiagnostics(
            context,
            applyMs: applyMs,
            applyCallMs: applyCallMs,
            completionMs: completionMs,
            visibleDetailRequestCount: visibleDetailRequestCount,
            preheatCount: preheatCount
        )
        if let operation {
            stallMonitor?.endOperation(operation)
        }
        // Adopt this apply's identities/descriptor and drain any work parked while it ran:
        // a newer grid state (applied next, content-first) and/or a zoom requested during
        // the apply (a `.zoomSwap` the gate emits once the count actually differs). The
        // gate guarantees a layout swap never runs concurrently with a diffable apply in
        // either direction (spec 0048).
        perform(mutationGate.completeStructuralApply(applied: context.grid))
    }

    /// reloadData-class applies (`largeApply`/`reorderOnly == false`, `animatingDifferences:
    /// false`) invalidate item layout without resolving it synchronously — AppKit queues
    /// the recompute for the next layout pass. Querying `indexPathsForVisibleItems()`/
    /// `layoutAttributesForElements(in:)` immediately after `apply(...)`'s completion, as
    /// the pre-fix code did, therefore sees a stale/empty pass forever if nothing else
    /// (scroll, another apply) happens to re-trigger the query — `layoutSubtreeIfNeeded()`
    /// flushes it synchronously, mirroring `scrollToFocusTarget`'s fix for the same class of
    /// race. Separately, if the window hasn't completed its first non-zero layout yet
    /// (`collectionView.frame.width == 0`), this parks the reason in
    /// `pendingPostApplyDetailReason` for `viewDidLayout`'s retry — same pattern as
    /// `pendingFocusTargetID`.
    @discardableResult
    func runPostApplyDetailAndPreheatPass(
        reason: String
    ) -> (visibleDetailRequestCount: Int, preheatCount: Int) {
        guard view.window != nil, collectionView.frame.width > 0 else {
            pendingPostApplyDetailReason = reason
            return (0, 0)
        }
        collectionView.layoutSubtreeIfNeeded()
        tileContents.pinVisible(Set(visibleAssetIDs()))
        let visibleDetailRequestCount = requestVisibleDetails(reason: reason)
        reportViewport()
        let preheatCount = switch preheatLookahead(reason: reason) {
        case let .started(count):
            count
        case .reused, .skipped:
            0
        }
        pendingPostApplyDetailReason = nil
        return (visibleDetailRequestCount, preheatCount)
    }

    private func logFinishedStructuralApply(
        _ context: StructuralApplyCompletionContext,
        applyMs: Int,
        applyCallMs: Int,
        completionMs: Int,
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
            animationSuppressed=\(context.animationSuppressed, privacy: .public) \
            heldDuringScroll=\(context.heldDuringScroll, privacy: .public) \
            reloadDataFallback=\(context.usesReloadDataFallback, privacy: .public) \
            visibleDetailRequestCount=\(visibleDetailRequestCount, privacy: .public) \
            preheatCount=\(preheatCount, privacy: .public) \
            diffPolicyMs=\(context.diffPolicyMs, privacy: .public) \
            snapshotBuildMs=\(context.snapshotBuildMs, privacy: .public) \
            applyCallMs=\(applyCallMs, privacy: .public) \
            completionMs=\(completionMs, privacy: .public) \
            applyMs=\(applyMs, privacy: .public)
            """
        )
    }

    private func recordStructuralApplyDiagnostics(
        _ context: StructuralApplyCompletionContext,
        applyMs: Int,
        applyCallMs: Int,
        completionMs: Int,
        visibleDetailRequestCount: Int,
        preheatCount: Int
    ) {
        OtosLog.ui.noticeOperation(
            "ui.mediaGrid.structuralApply",
            phase: "finish",
            fields: [
                "items": "\(context.grid.orderedAssetIDs.count)",
                "scope": context.grid.scope.diagnosticDescription,
                "inserted": "\(context.insertedCount)",
                "removed": "\(context.removedCount)",
                "reorderOnly": "\(context.reorderOnly)",
                "largeApply": "\(context.largeApply)",
                "animatingDifferences": "\(context.animatingDifferences)",
                "animationSuppressed": "\(context.animationSuppressed)",
                "heldDuringScroll": "\(context.heldDuringScroll)",
                "reloadDataFallback": "\(context.usesReloadDataFallback)",
                "visibleDetailRequestCount": "\(visibleDetailRequestCount)",
                "preheatCount": "\(preheatCount)",
                "detailRefreshGeneration": "\(context.grid.detailRefreshGeneration)",
                "diffPolicyMs": "\(context.diffPolicyMs)",
                "snapshotBuildMs": "\(context.snapshotBuildMs)",
                "applyCallMs": "\(applyCallMs)",
                "completionMs": "\(completionMs)",
                "applyMs": "\(applyMs)",
            ]
        )
    }
}
