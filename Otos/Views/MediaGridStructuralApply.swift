import AppKit
import Foundation
import OSLog

extension MediaGridViewController {
    struct StructuralApplyCompletionContext {
        let grid: CatalogMediaGridState
        let change: MediaGridMutationGate.QueryChange
        /// When the gate admitted the apply, so `applyMs` includes the off-main build.
        let applyStart: ContinuousClock.Instant
        let applyCallStart: ContinuousClock.Instant
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

    /// Everything a structural apply needs that is a pure function of values: the diffable
    /// snapshot, the day facts of its sections, and the diff summary against what is on
    /// screen. Built off the main actor by `buildStructure`, applied on it by
    /// `commitStructure`.
    ///
    /// Not `Sendable`: AppKit's snapshot is not. It crosses back to the main actor as a
    /// `sending` result, which the compiler accepts only because nothing else holds it.
    nonisolated struct BuiltStructure {
        let snapshot: NSDiffableDataSourceSnapshot<Section, MediaAssetID>
        let daySections: [MediaGridDayBarPolicy.Day?]
        let summary: MediaGridStructuralApplyPolicy
        let diffPolicyMs: Int
        let snapshotBuildMs: Int
    }

    /// The gate's `.apply` for `grid`. The gate has already marked the structural apply in
    /// flight, so until `completeStructuralApply` drains it no other exclusive mutation runs
    /// and `displayedOrderedIDs` does not change: the values handed to the build are still
    /// the ones on screen when its result is committed, and a grid arriving meanwhile parks
    /// as the gate's pending grid, applied after this one.
    ///
    /// The snapshot is built off the main actor because AppKit's snapshot copies its whole
    /// item set on every `appendItems`, and a day-grouped grid appends once per day: the
    /// build grows with days × items (`docs/research/2026-11-04-grid-snapshot-build-off-main.md`).
    /// One build at a time, by the gate's exclusivity; the task is cancelled only at teardown,
    /// and a cancelled build is never applied.
    func applyStructure(
        _ grid: CatalogMediaGridState,
        change: MediaGridMutationGate.QueryChange
    ) {
        let applyStart = ContinuousClock.now
        let previousOrderedIDs = mutationGate.displayedOrderedIDs
        let previousOrderedIDSet = mutationGate.displayedOrderedIDSet
        let descriptorChanged = change != .unchanged
        structureBuildTask = Task { [weak self, grid, change, previousOrderedIDs, previousOrderedIDSet] in
            let built = await Self.buildStructure(
                for: grid,
                descriptorChanged: descriptorChanged,
                previousOrderedIDs: previousOrderedIDs,
                previousOrderedIDSet: previousOrderedIDSet
            )
            guard let self, !Task.isCancelled else {
                return
            }
            structureBuildTask = nil
            commitStructure(built, grid: grid, change: change, applyStart: applyStart)
        }
    }

    /// The pure half of a structural apply, off the main actor.
    @concurrent
    nonisolated static func buildStructure(
        for grid: CatalogMediaGridState,
        descriptorChanged: Bool,
        previousOrderedIDs: [MediaAssetID],
        previousOrderedIDSet: Set<MediaAssetID>
    ) async -> sending BuiltStructure {
        let policyStart = ContinuousClock.now
        let summary = MediaGridStructuralApplyPolicy.summarize(
            previousOrderedIDs: previousOrderedIDs,
            previousOrderedIDSet: previousOrderedIDSet,
            nextOrderedIDs: grid.orderedAssetIDs,
            descriptorChanged: descriptorChanged
        )
        let diffPolicyMs = DiagnosticsTiming.milliseconds(since: policyStart)
        let snapshotStart = ContinuousClock.now
        let (snapshot, daySections) = mediaSnapshot(for: grid)
        return BuiltStructure(
            snapshot: snapshot,
            daySections: daySections,
            summary: summary,
            diffPolicyMs: diffPolicyMs,
            snapshotBuildMs: DiagnosticsTiming.milliseconds(since: snapshotStart)
        )
    }

    /// The AppKit half of a structural apply, on the main actor and synchronous from here
    /// to the apply call, so the scroll anchor is read from the layout the apply replaces.
    private func commitStructure(
        _ built: BuiltStructure,
        grid: CatalogMediaGridState,
        change: MediaGridMutationGate.QueryChange,
        applyStart: ContinuousClock.Instant
    ) {
        let operation = stallMonitor?.beginOperation("MediaGridViewController.applyStructure")
        let summary = built.summary
        let scrollAnchor = captureScrollAnchor(change: change, nextOrderedIDs: grid.orderedAssetIDs)
        let signpost = OtosSignpost.ui.beginInterval("MediaGridStructuralApply")
        logStartedStructuralApply(grid, change: change, anchor: scrollAnchor, summary: summary)
        let stallMonitor = stallMonitor
        let applyCallStart = ContinuousClock.now
        let animationSuppressed = summary.animatingDifferences
            && suppressesApplyAnimation(anchor: scrollAnchor, nextOrderedIDs: grid.orderedAssetIDs)
        let context = StructuralApplyCompletionContext(
            grid: grid,
            change: change,
            applyStart: applyStart,
            applyCallStart: applyCallStart,
            diffPolicyMs: built.diffPolicyMs,
            snapshotBuildMs: built.snapshotBuildMs,
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
        // Assigned beside the apply, not in its completion: `dataSource.apply` updates the
        // layout synchronously and only *animates* items to their new frames (see
        // `restoreScrollAnchor`), and nothing suspends between this line and that call, so
        // no reader can observe this array and the layout disagreeing.
        appliedDaySections = built.daySections
        applySnapshot(
            built.snapshot,
            summary: summary,
            animationSuppressed: animationSuppressed,
            scrollAnchor: scrollAnchor,
            completion: completion
        )
        // Here rather than in the completion: the apply has already placed every surviving
        // header at its new section (`appliedDaySections` above documents why the layout is
        // current on return), and an animated apply's completion lands only after the
        // motion, so a header would show its old day for the length of it.
        renderVisibleDayHeaders()
    }

    /// An animated apply keeps its true-diff path but runs with a zero duration when the
    /// motion would be unwanted (Reduce Motion), invisible (live scrolling), or false (a
    /// strip restore that scrolls by exactly the distance the survivors would travel).
    private func suppressesApplyAnimation(anchor: ScrollAnchor?, nextOrderedIDs: [MediaAssetID]) -> Bool {
        if MediaGridAnimation.prefersReducedMotion
            || MediaGridAnimation.suppressesApplyAnimation(
                lastScrollTickAge: lastScrollTickAt.map { $0.duration(to: .now) }
            )
        {
            return true
        }
        guard presentation.isStrip, let anchor else {
            return false
        }
        return MediaGridAnimation.suppressesAnchoredStripAnimation(
            anchorID: anchor.id,
            previousOrderedIDs: mutationGate.displayedOrderedIDs,
            nextOrderedIDs: nextOrderedIDs
        )
    }

    private func logStartedStructuralApply(
        _ grid: CatalogMediaGridState,
        change: MediaGridMutationGate.QueryChange,
        anchor: ScrollAnchor?,
        summary: MediaGridStructuralApplyPolicy
    ) {
        OtosLog.ui.debug(
            """
            Media grid structural apply started items=\(grid.orderedAssetIDs.count, privacy: .public) \
            scope=\(grid.scope.diagnosticDescription, privacy: .public) \
            change=\(String(describing: change), privacy: .public) \
            anchor=\(anchor?.source.rawValue ?? "none", privacy: .public) \
            reorderOnly=\(summary.reorderOnly, privacy: .public) \
            largeApply=\(summary.largeApply, privacy: .public) \
            animating=\(summary.animatingDifferences, privacy: .public) \
            reloadDataFallback=\(summary.usesReloadDataFallback, privacy: .public)
            """
        )
    }

    /// Where the viewport sat before a structural apply, as an item plus the item's
    /// offset from the viewport's leading edge along the scroll axis (top for the grid,
    /// left for the strip) — not a raw scroll position, which means nothing once the
    /// content before it changes length.
    struct ScrollAnchor {
        let id: MediaAssetID
        let offsetFromViewportLeadingEdge: CGFloat
        let source: ScrollAnchorSource
    }

    /// Which on-screen fact chose a `ScrollAnchor` (diagnostics).
    enum ScrollAnchorSource: String {
        /// The leading item, unchanged by the apply.
        case leading
        /// The first visible item still selected after a filter or sort change.
        case selected
        /// The leading item's nearest survivor after a filter removed it.
        case survivor
    }

    /// Below this the grid counts as being at the top. One point, not a row height: the
    /// question is only whether the user parked at the top or moved away from it, and
    /// scroll elasticity can leave a sub-point residue at rest.
    static let scrollAnchorTopThreshold: CGFloat = 1

    /// Content inserted before the viewport displaces what the user is looking at.
    ///
    /// `NSScrollView` holds the scroll *offset* fixed, so items inserted before the viewport
    /// slide the content under a stationary window and the user drifts backwards through
    /// the library. The default order is `best_capture_unix DESC` and a card copies
    /// oldest-first, so during an import every newly published asset is newer than
    /// everything already in the batch and lands at index 0 — before the viewport, every
    /// time. Measured on a 999-item card: 273 applies inserting 2–10 items each, one about
    /// every 1.1 s for the whole five minutes.
    ///
    /// The grid skips anchoring at its top, and that exception is the point: it is the one
    /// place where letting arrivals push the content down reports that something is
    /// happening, and the one place where nothing the user was looking at gets displaced.
    /// The strip has no such place: its viewport holds the focused tile the loupe is
    /// showing, so arrivals at its leading edge would push that tile off screen. It is
    /// always anchored. `scrollToFocusTarget` still owns the strip's position when focus
    /// *changes*; the anchor only keeps the position it already has across an apply.
    /// Anchoring is skipped for a new scope, which starts at the top.
    ///
    /// A filter or sort change keeps the user's place in the same collection (APP-042).
    /// A visible tile that is still selected is what they were working on — in the strip,
    /// the focused tile — so it holds its on-screen position, even at the top of the grid:
    /// a sort would otherwise carry it away. Without one, the leading tile holds its
    /// position, and if the filter removed it, its nearest survivor in the order the user
    /// was looking at takes its place.
    func captureScrollAnchor(
        change: MediaGridMutationGate.QueryChange,
        nextOrderedIDs: [MediaAssetID]
    ) -> ScrollAnchor? {
        guard change != .scope, let layout = collectionView.collectionViewLayout else {
            return nil
        }
        let isStrip = presentation.isStrip
        let viewport = scrollView.documentVisibleRect
        let visible = itemsInScrollOrder(in: viewport, layout: layout, isStrip: isStrip)
        if change == .filterOrSort {
            // Already pruned to the survivors by `ViewModel.applyState`.
            let selected = selectionHandlers.currentSelection().selection
            if let item = visible.first(where: { selected.contains($0.id) }) {
                return ScrollAnchor(
                    id: item.id,
                    offsetFromViewportLeadingEdge: item.offset,
                    source: .selected
                )
            }
        }
        guard isStrip || viewport.minY > Self.scrollAnchorTopThreshold,
              let leading = visible.first
        else {
            return nil
        }
        guard change == .filterOrSort else {
            return ScrollAnchor(id: leading.id, offsetFromViewportLeadingEdge: leading.offset, source: .leading)
        }
        guard let survivor = BrowserModePolicy.nearestSurvivor(
            of: leading.id,
            previousOrderedIDs: mutationGate.displayedOrderedIDs,
            surviving: Set(nextOrderedIDs)
        ) else {
            return nil
        }
        return ScrollAnchor(
            id: survivor,
            offsetFromViewportLeadingEdge: leading.offset,
            source: survivor == leading.id ? .leading : .survivor
        )
    }

    /// The items intersecting `viewport` in scroll order (the grid: top-to-bottom, then
    /// left-to-right; the strip: left-to-right), each with its leading edge's offset from
    /// the viewport's leading edge.
    ///
    /// Asks the *layout* what occupies the viewport, not the collection view which cells
    /// it has realized. `indexPathsForVisibleItems()` reports realized cells, which is a
    /// rendering fact rather than a geometric one: it answered "index 0" for a grid
    /// scrolled 600 points down, because nothing had been realized yet. Anchoring on
    /// that pins the wrong item — and pins it silently, since index 0 is a plausible
    /// answer. The layout's own attributes are a pure function of geometry.
    private func itemsInScrollOrder(
        in viewport: NSRect,
        layout: NSCollectionViewLayout,
        isStrip: Bool
    ) -> [(id: MediaAssetID, offset: CGFloat)] {
        _ = layout.collectionViewContentSize
        return layout.layoutAttributesForElements(in: viewport)
            .filter { $0.representedElementCategory == .item }
            .sorted { lhs, rhs in
                if isStrip {
                    return lhs.frame.minX < rhs.frame.minX
                }
                return lhs.frame.minY == rhs.frame.minY
                    ? lhs.frame.minX < rhs.frame.minX
                    : lhs.frame.minY < rhs.frame.minY
            }
            .compactMap { attributes in
                guard let indexPath = attributes.indexPath,
                      let id = dataSource.itemIdentifier(for: indexPath)
                else {
                    return nil
                }
                let offset = isStrip
                    ? attributes.frame.minX - viewport.minX
                    : attributes.frame.minY - viewport.minY
                return (id, offset)
            }
    }

    /// Puts the anchored item back where it was on screen.
    ///
    /// Called immediately after the apply rather than from its completion: the apply
    /// updates the layout synchronously, so correcting the offset in the same run-loop
    /// turn moves the viewport before it is drawn. Correcting it from the completion would
    /// instead show the slide and then snap it back. An animated apply still moves the item
    /// *views* from their old frames to the new ones under the corrected viewport, which is
    /// why a strip apply this restore scrolls runs with a zero duration
    /// (`MediaGridAnimation.suppressesAnchoredStripAnimation`).
    ///
    /// A vanished anchor (its item removed by this very apply) leaves the scroll alone
    /// rather than guessing at a replacement.
    func restoreScrollAnchor(_ anchor: ScrollAnchor?) {
        guard let anchor, let layout = collectionView.collectionViewLayout else {
            return
        }
        // The layout's own content size, not the document view's bounds. The document view
        // is resized to content in a later layout pass, so its extent here can still answer
        // with the clip's — which clamps every restore to the leading edge, i.e. the exact
        // displacement this exists to prevent, wearing a different hat. Asking the layout
        // also settles it, so the item frame read next is the post-apply one.
        let contentSize = layout.collectionViewContentSize
        guard let indexPath = dataSource.indexPath(for: anchor.id),
              let frame = layout.layoutAttributesForItem(at: indexPath)?.frame
        else {
            return
        }
        let clip = scrollView.contentView
        let origin = clip.bounds.origin
        let target: NSPoint
        if presentation.isStrip {
            let maxX = max(0, contentSize.width - clip.bounds.width)
            let targetX = min(max(frame.minX - anchor.offsetFromViewportLeadingEdge, 0), maxX)
            target = NSPoint(x: targetX, y: origin.y)
        } else {
            let maxY = max(0, contentSize.height - clip.bounds.height)
            let targetY = min(max(frame.minY - anchor.offsetFromViewportLeadingEdge, 0), maxY)
            target = NSPoint(x: origin.x, y: targetY)
        }
        guard abs(target.x - origin.x) > 0.5 || abs(target.y - origin.y) > 0.5 else {
            return
        }
        clip.scroll(to: target)
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
    /// membership applies — AppKit's reloadData-class path. The position resets or is
    /// re-anchored on a descriptor change anyway; large membership diffs stay off the quadratic
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
    nonisolated static func mediaSnapshot(
        for grid: CatalogMediaGridState
    ) -> (NSDiffableDataSourceSnapshot<Section, MediaAssetID>, [MediaGridDayBarPolicy.Day?]) {
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
        return (snapshot, daySections)
    }

    func completeStructuralApply(
        _ context: StructuralApplyCompletionContext,
        operation: MainRunLoopOperationToken?,
        stallMonitor: MainRunLoopStallMonitor?
    ) {
        let applyCallMs = DiagnosticsTiming.milliseconds(since: context.applyCallStart)
        let completionStart = ContinuousClock.now
        OtosSignpost.ui.endInterval("MediaGridStructuralApply", context.signpost)
        stallMonitor?.completeIntentToPaint(appliedScope: context.grid.scope)

        if context.change == .scope {
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
