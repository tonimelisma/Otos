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
        let snapshot = mediaSnapshot(for: grid)
        let snapshotBuildMs = DiagnosticsTiming.milliseconds(since: snapshotStart)

        let scrollAnchor = captureScrollAnchor(resetScroll: resetScroll)
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
            scrollAnchor: scrollAnchor,
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

    /// Where the viewport sat before a structural apply, as an item plus the item's
    /// offset from the viewport's top edge — not a raw scroll position, which means
    /// nothing once the content above it changes length.
    struct ScrollAnchor {
        let id: MediaAssetID
        let offsetFromViewportTop: CGFloat
    }

    /// Below this the grid counts as being at the top. One point, not a row height: the
    /// question is only whether the user parked at the top or moved away from it, and
    /// scroll elasticity can leave a sub-point residue at rest.
    static let scrollAnchorTopThreshold: CGFloat = 1

    /// Content inserted above the viewport displaces what the user is reading.
    ///
    /// `NSScrollView` holds the scroll *offset* fixed, so items inserted above slide the
    /// content down under a stationary window and the user drifts backwards through the
    /// grid. The default order is `best_capture_unix DESC` and a card copies oldest-first,
    /// so during an import every newly published asset is newer than everything already in
    /// the batch and lands at index 0 — above the viewport, every time. Measured on a
    /// 999-item card: 273 applies inserting 2–10 items each, one about every 1.1 s for the
    /// whole five minutes.
    ///
    /// Anchoring is skipped at the top of the grid, and that exception is the point: it is
    /// the one place where letting arrivals push the content down reports that something is
    /// happening, and the one place where nothing the user was looking at gets displaced.
    /// It is also skipped for a deliberate `resetScroll`, and for the strip, whose position
    /// is already owned by `scrollToFocusTarget`.
    func captureScrollAnchor(resetScroll: Bool) -> ScrollAnchor? {
        guard !resetScroll, !presentation.isStrip else {
            return nil
        }
        let viewport = scrollView.documentVisibleRect
        guard viewport.minY > Self.scrollAnchorTopThreshold,
              let layout = collectionView.collectionViewLayout
        else {
            return nil
        }
        // Ask the *layout* what occupies the viewport, not the collection view which cells
        // it has realized. `indexPathsForVisibleItems()` reports realized cells, which is a
        // rendering fact rather than a geometric one: it answered "index 0" for a grid
        // scrolled 600 points down, because nothing had been realized yet. Anchoring on
        // that pins the wrong item — and pins it silently, since index 0 is a plausible
        // answer. The layout's own attributes are a pure function of geometry.
        _ = layout.collectionViewContentSize
        let topmost = layout.layoutAttributesForElements(in: viewport)
            .filter { $0.representedElementCategory == .item }
            .min { lhs, rhs in
                lhs.frame.minY == rhs.frame.minY
                    ? lhs.frame.minX < rhs.frame.minX
                    : lhs.frame.minY < rhs.frame.minY
            }
        guard let topmost,
              let indexPath = topmost.indexPath,
              let id = dataSource.itemIdentifier(for: indexPath)
        else {
            return nil
        }
        return ScrollAnchor(id: id, offsetFromViewportTop: topmost.frame.minY - viewport.minY)
    }

    /// Puts the anchored item back where it was on screen.
    ///
    /// Called immediately after the apply rather than from its completion: an animated
    /// apply updates the layout synchronously and only *animates* items to the new frames,
    /// so correcting the offset in the same run-loop turn cancels the displacement before
    /// it is ever drawn. Correcting it from the completion would instead show the slide and
    /// then snap it back, which is the same defect with an extra step.
    ///
    /// A vanished anchor (its item removed by this very apply) leaves the scroll alone
    /// rather than guessing at a replacement.
    func restoreScrollAnchor(_ anchor: ScrollAnchor?) {
        guard let anchor, let layout = collectionView.collectionViewLayout else {
            return
        }
        // The layout's own content size, not the document view's bounds. The document view
        // is resized to content in a later layout pass, so its height here can still answer
        // with the clip's height — which clamps every restore to the top, i.e. the exact
        // displacement this exists to prevent, wearing a different hat. Asking the layout
        // also settles it, so the item frame read next is the post-apply one.
        let contentHeight = layout.collectionViewContentSize.height
        guard let indexPath = dataSource.indexPath(for: anchor.id),
              let frame = layout.layoutAttributesForItem(at: indexPath)?.frame
        else {
            return
        }
        let clip = scrollView.contentView
        let maxY = max(0, contentHeight - clip.bounds.height)
        let targetY = min(max(frame.minY - anchor.offsetFromViewportTop, 0), maxY)
        guard abs(targetY - clip.bounds.origin.y) > 0.5 else {
            return
        }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: targetY))
        scrollView.reflectScrolledClipView(clip)
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
        scrollAnchor: ScrollAnchor?,
        completion: @escaping () -> Void
    ) {
        guard summary.animatingDifferences else {
            dataSource.apply(snapshot, animatingDifferences: false, completion: completion)
            restoreScrollAnchor(scrollAnchor)
            return
        }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = animationSuppressed
            ? 0
            : MediaGridAnimation.applyDuration
        NSAnimationContext.current.timingFunction = MediaGridAnimation.applyTimingFunction
        dataSource.apply(snapshot, animatingDifferences: true, completion: completion)
        restoreScrollAnchor(scrollAnchor)
        NSAnimationContext.endGrouping()
    }

    /// Sections are rebuilt fresh from current identity + bucket data on every
    /// apply via `MediaGridSectionGroupingPolicy` (`MediaGridSupport.swift`,
    /// pure and independently tested); nothing here diffs against the previous
    /// snapshot's sections, so no separate section-level invalidation exists to
    /// go stale (`MediaGridStructuralApplyPolicy.summarize`, which does drive
    /// real diffing, works entirely off the flat ID list and needs no
    /// day-bucket awareness of its own).
    private func mediaSnapshot(
        for grid: CatalogMediaGridState
    ) -> NSDiffableDataSourceSnapshot<Section, MediaAssetID> {
        var snapshot = NSDiffableDataSourceSnapshot<Section, MediaAssetID>()
        let runs = MediaGridSectionGroupingPolicy.sectionRuns(
            orderedIDs: grid.orderedAssetIDs,
            dayBuckets: grid.dayBuckets
        )
        var daySections: [MediaGridDayBarPolicy.Day?] = []
        daySections.reserveCapacity(runs.count)
        for run in runs {
            snapshot.appendSections([run.section])
            snapshot.appendItems(run.ids, toSection: run.section)
            switch run.section {
            case .ungrouped:
                daySections.append(nil)
            case let .day(date):
                daySections.append(MediaGridDayBarPolicy.Day(date: date, itemCount: run.ids.count))
            }
        }
        // Recorded here, not in the apply's completion: `dataSource.apply` updates the
        // layout synchronously and only *animates* items to their new frames (see
        // `restoreScrollAnchor`), and nothing suspends between this line and that call,
        // so no reader can observe this array and the layout disagreeing.
        appliedDaySections = daySections
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
        // either direction (ARC-023).
        perform(mutationGate.completeStructuralApply(applied: context.grid))
    }

    /// Routes the visible-detail/preheat pass through the shared post-layout queue.
    /// Reload-class applies invalidate item layout without resolving it synchronously;
    /// the queue flushes layout when possible and coalesces one deferred pass until
    /// the next real layout.
    @discardableResult
    func runPostApplyDetailAndPreheatPass(
        reason: String
    ) -> (visibleDetailRequestCount: Int, preheatCount: Int) {
        var result = (visibleDetailRequestCount: 0, preheatCount: 0)
        postLayoutWorkQueue.submit(.detailAndPreheat, reason: reason) { [weak self] in
            guard let self else { return }
            result = runPostApplyDetailAndPreheatPassNow(reason: reason)
        }
        return result
    }

    private func runPostApplyDetailAndPreheatPassNow(
        reason: String
    ) -> (visibleDetailRequestCount: Int, preheatCount: Int) {
        collectionView.layoutSubtreeIfNeeded()
        tileContents.pinVisible(Set(visibleAssetIDs()))
        let visibleDetailRequestCount = requestVisibleDetails(reason: reason)
        // Rows moved under a possibly-stationary cursor and tiles were recycled,
        // so the tile showing the hovered asset is not the one that had the
        // control. Re-assert from the pointer's real position (`refreshHover`)
        // and then repaint the assignment onto whichever tiles now hold it.
        collectionView.refreshHover()
        applyHoverToVisibleTiles()
        updateDayBar()
        reportViewport()
        let preheatCount = switch preheatLookahead(reason: reason) {
        case let .started(count):
            count
        case .reused, .skipped:
            0
        }
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
