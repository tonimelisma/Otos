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
        /// The main thread's synchronous share of the apply: from taking the built
        /// structure to handing AppKit the reload or the batch, layout included. The
        /// completion is timed apart, as `completionMs`.
        let commit: CommitDuration
        let diffPolicyMs: Int
        let structureBuildMs: Int
        let batchUpdatesMs: Int
        let insertedCount: Int
        let removedCount: Int
        let reorderOnly: Bool
        let largeApply: Bool
        let animatingDifferences: Bool
        let animationSuppressed: Bool
        let usesReloadDataFallback: Bool
        let appliedBy: AppliedBy
        let sectionCount: Int
        let heldDuringScroll: Bool
        let signpost: OSSignpostIntervalState
    }

    /// The commit's end, taken when it returns or when its completion starts, whichever
    /// comes first: a reload calls the completion itself, and AppKit may run a batch's
    /// completion before `performBatchUpdates` returns, so either can be first.
    final class CommitDuration {
        private let start: ContinuousClock.Instant
        private var milliseconds: Int?

        init(start: ContinuousClock.Instant) {
            self.start = start
        }

        /// The commit's duration in milliseconds, fixed by the first call.
        @discardableResult
        func end() -> Int {
            if let milliseconds {
                return milliseconds
            }
            let measured = DiagnosticsTiming.milliseconds(since: start)
            milliseconds = measured
            return measured
        }
    }

    /// How the collection view took a new structure (diagnostics).
    enum AppliedBy: String {
        /// `reloadData`: every count re-read, every visible item re-requested.
        case reloadData
        /// `performBatchUpdates` with the derived `MediaGridBatchUpdates`: surviving items
        /// keep their views and move.
        case batchUpdates
        /// The batch was empty: the structure on screen already was the new one.
        case nothing
    }

    /// Everything a structural apply needs that is a pure function of values: the new
    /// structure, the diff summary against the structure on screen, and, when the apply
    /// animates, the batch that turns one into the other. Built off the main actor by
    /// `buildStructure`, applied on it by `commitStructure`.
    nonisolated struct BuiltStructure: Sendable {
        let structure: MediaGridStructure
        let summary: MediaGridStructuralApplyPolicy
        /// `nil` when the apply reloads: the summary chose the reloadData path, or no batch
        /// can describe the change (`MediaGridBatchUpdates.between`).
        let batchUpdates: MediaGridBatchUpdates?
        let diffPolicyMs: Int
        let structureBuildMs: Int
        let batchUpdatesMs: Int
    }

    /// The gate's `.apply` for `grid`. The gate has already marked the structural apply in
    /// flight, so until `completeStructuralApply` drains it no other exclusive mutation runs
    /// and `structure` does not change: the structure handed to the build is still the one
    /// on screen when its result is committed, and a grid arriving meanwhile parks as the
    /// gate's pending grid, applied after this one.
    ///
    /// The build is linear in items, but at a library's size that is still tens of
    /// milliseconds, so it runs off the main actor
    /// (`docs/research/2026-11-14-grid-structure-without-diffable-snapshot.md`). One build at
    /// a time, by the gate's exclusivity; the task is cancelled only at teardown, and a
    /// cancelled build is never applied.
    func applyStructure(
        _ grid: CatalogMediaGridState,
        change: MediaGridMutationGate.QueryChange
    ) {
        let applyStart = ContinuousClock.now
        let previous = structure
        let descriptorChanged = change != .unchanged
        structureBuildTask = Task { [weak self, grid, change, previous] in
            let built = await Self.buildStructure(
                for: grid,
                descriptorChanged: descriptorChanged,
                previous: previous
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
        previous: MediaGridStructure
    ) async -> BuiltStructure {
        // Identity order and day buckets are the complete structural contract. Tile
        // details are read for visible identities after the structural apply, so thumbnail
        // or video-badge changes never come through here. Selection truth lives in the
        // ViewModel and is already pruned/cleared in `applyState` before this apply runs;
        // completion only renders the model.
        let structureStart = ContinuousClock.now
        let structure = MediaGridStructure(grid: grid)
        let structureBuildMs = DiagnosticsTiming.milliseconds(since: structureStart)

        let policyStart = ContinuousClock.now
        let summary = MediaGridStructuralApplyPolicy.summarize(
            previous: previous,
            next: structure,
            descriptorChanged: descriptorChanged
        )
        let diffPolicyMs = DiagnosticsTiming.milliseconds(since: policyStart)

        let batchStart = ContinuousClock.now
        let batchUpdates = summary.animatingDifferences
            ? MediaGridBatchUpdates.between(previous, structure)
            : nil
        return BuiltStructure(
            structure: structure,
            summary: summary,
            batchUpdates: batchUpdates,
            diffPolicyMs: diffPolicyMs,
            structureBuildMs: structureBuildMs,
            batchUpdatesMs: DiagnosticsTiming.milliseconds(since: batchStart)
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
        let commitDuration = CommitDuration(start: .now)
        let summary = built.summary
        let scrollAnchor = captureScrollAnchor(change: change, nextOrderedIDs: grid.orderedAssetIDs)
        let signpost = OtosSignpost.ui.beginInterval("MediaGridStructuralApply")
        logStartedStructuralApply(grid, change: change, anchor: scrollAnchor, summary: summary)
        let stallMonitor = stallMonitor
        let applyCallStart = ContinuousClock.now
        let animationSuppressed = summary.animatingDifferences
            && suppressesApplyAnimation(anchor: scrollAnchor, nextOrderedIDs: grid.orderedAssetIDs)
        // A collection view outside a window has nothing on screen to move, so it reloads.
        let batchUpdates = collectionView.window == nil ? nil : built.batchUpdates
        let context = StructuralApplyCompletionContext(
            grid: grid,
            change: change,
            applyStart: applyStart,
            applyCallStart: applyCallStart,
            commit: commitDuration,
            diffPolicyMs: built.diffPolicyMs,
            structureBuildMs: built.structureBuildMs,
            batchUpdatesMs: built.batchUpdatesMs,
            insertedCount: summary.insertedCount,
            removedCount: summary.removedCount,
            reorderOnly: summary.reorderOnly,
            largeApply: summary.largeApply,
            animatingDifferences: summary.animatingDifferences,
            animationSuppressed: animationSuppressed,
            usesReloadDataFallback: summary.usesReloadDataFallback,
            appliedBy: batchUpdates.map { $0.isEmpty ? .nothing : .batchUpdates } ?? .reloadData,
            sectionCount: built.structure.numberOfSections,
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
        if batchUpdates?.isEmpty == true {
            // The new structure is the one on screen: nothing to reload, move or lay out.
            structure = built.structure
            completion()
            return
        }
        guard let batchUpdates else {
            structure = built.structure
            collectionView.reloadData()
            restoreScrollAnchor(scrollAnchor)
            renderVisibleDayHeaders()
            completion()
            return
        }
        applyBatch(
            batchUpdates,
            structure: built.structure,
            animationSuppressed: animationSuppressed,
            scrollAnchor: scrollAnchor,
            completion: completion
        )
        // Here rather than in the completion: the batch has already placed every surviving
        // header at its new section (the layout is current on return; see
        // `restoreScrollAnchor`), and an animated batch's completion lands only after the
        // motion, so a header would show its old day for the length of it.
        renderVisibleDayHeaders()
        commitDuration.end()
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
            previousOrderedIDs: structure.orderedIDs,
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
    /// the library. The default order is `best_capture_local DESC` and a card copies
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
            previousOrderedIDs: structure.orderedIDs,
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
                      let id = structure.id(at: indexPath)
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
        guard let indexPath = structure.indexPath(of: anchor.id),
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

    /// The animated branch: small insert/remove and same-query reorder-only applies (the
    /// enrichment trickle), which move surviving items instead of recreating them
    /// (ADR 0006), with tuned duration and timing from an explicit `NSAnimationContext`
    /// group. When the motion is unwanted or invisible (`animationSuppressed`: Reduce
    /// Motion, live scrolling, an anchored strip) the group runs with a zero duration, so
    /// surviving views still move rather than reload. Every other apply is `reloadData`
    /// (`commitStructure`): a query change resets or re-anchors the position anyway, and a
    /// large membership change would pay for every removed and inserted item.
    ///
    /// The structure changes inside the update block, where AppKit expects the data source
    /// to switch: it holds the old counts until the block runs and reads the new ones after.
    /// The layout is current when `performBatchUpdates` returns (only the item views animate
    /// to their frames), so the anchor restore right after it reads the new geometry.
    private func applyBatch(
        _ updates: MediaGridBatchUpdates,
        structure next: MediaGridStructure,
        animationSuppressed: Bool,
        scrollAnchor: ScrollAnchor?,
        completion: @escaping () -> Void
    ) {
        // A batch is relative to the counts the collection view holds. One that has not yet
        // asked for them would ask after the block, read the new structure as the old one,
        // and reject the batch; asking here, while `structure` is still the old value,
        // settles them first.
        _ = collectionView.numberOfSections
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = animationSuppressed
            ? 0
            : MediaGridAnimation.applyDuration
        NSAnimationContext.current.timingFunction = MediaGridAnimation.applyTimingFunction
        collectionView.animator().performBatchUpdates({ [weak self] in
            guard let self else {
                return
            }
            structure = next
            collectionView.deleteSections(updates.deletedSections)
            collectionView.insertSections(updates.insertedSections)
            collectionView.deleteItems(at: updates.deletedItems)
            collectionView.insertItems(at: updates.insertedItems)
            for move in updates.movedItems {
                collectionView.moveItem(at: move.from, to: move.to)
            }
        }, completionHandler: { _ in
            // AppKit runs a batch's completion on the main thread without annotating its
            // isolation; asserting that, rather than hopping through a task, completes this
            // apply before any other mutation can begin.
            MainActor.assumeIsolated {
                completion()
            }
        })
        restoreScrollAnchor(scrollAnchor)
        NSAnimationContext.endGrouping()
    }

    func completeStructuralApply(
        _ context: StructuralApplyCompletionContext,
        operation: MainRunLoopOperationToken?,
        stallMonitor: MainRunLoopStallMonitor?
    ) {
        let commitMs = context.commit.end()
        let applyCallMs = DiagnosticsTiming.milliseconds(since: context.applyCallStart)
        let completionStart = ContinuousClock.now
        OtosSignpost.ui.endInterval("MediaGridStructuralApply", context.signpost)
        stallMonitor?.completeIntentToPaint(appliedScope: context.grid.scope)

        if context.change == .scope {
            scrollToTop()
        }
        // Reorder-only applies keep identical membership by definition, so a prune would
        // only re-ask every stored entry a question whose answer cannot have changed.
        if !context.reorderOnly {
            tileContents.prune(keeping: structure.contains)
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
            commitMs: commitMs,
            applyCallMs: applyCallMs,
            completionMs: completionMs,
            visibleDetailRequestCount: visibleDetailRequestCount,
            preheatCount: preheatCount
        )
        recordStructuralApplyDiagnostics(
            context,
            applyMs: applyMs,
            commitMs: commitMs,
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
        // gate guarantees a layout swap never runs concurrently with a structural apply in
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
        commitMs: Int,
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
            structureBuildMs=\(context.structureBuildMs, privacy: .public) \
            batchUpdatesMs=\(context.batchUpdatesMs, privacy: .public) \
            appliedBy=\(context.appliedBy.rawValue, privacy: .public) \
            sections=\(context.sectionCount, privacy: .public) \
            commitMs=\(commitMs, privacy: .public) \
            applyCallMs=\(applyCallMs, privacy: .public) \
            completionMs=\(completionMs, privacy: .public) \
            applyMs=\(applyMs, privacy: .public)
            """
        )
    }

    private func recordStructuralApplyDiagnostics(
        _ context: StructuralApplyCompletionContext,
        applyMs: Int,
        commitMs: Int,
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
                "structureBuildMs": "\(context.structureBuildMs)",
                "batchUpdatesMs": "\(context.batchUpdatesMs)",
                "appliedBy": context.appliedBy.rawValue,
                "sections": "\(context.sectionCount)",
                "commitMs": "\(commitMs)",
                "applyCallMs": "\(applyCallMs)",
                "completionMs": "\(completionMs)",
                "applyMs": "\(applyMs)",
            ]
        )
    }
}
