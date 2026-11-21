import AppKit
import AVFoundation
import Foundation
import OSLog

/// Catalog window view-mode intents guide
///
/// Owns `viewMode`, loupe `focusedAssetID`, compare pair, and the
/// pane-preview request lifecycle. Every entry/exit/navigation rule is either a pure
/// `BrowserModePolicy` / `ComparePairPolicy` call or a thin intent that applies that
/// policy and reconciles pane slots via `refreshPanePreviews()` — `setFocus` runs it
/// for every focus change; pair and mode changes call it directly. Each `PaneSlot` has
/// at most one owned `paneRequestTasks` entry (request or downloading retry) at
/// `.userInitiated`; superseded requests cancel before enqueueing another decode.
/// Views stay passive.
extension CatalogWindowViewModel {
    /// Target long edge for loupe/compare decode (points × backing scale of the main
    /// display, clamped). Computed on the MainActor when a decode is requested.
    static func previewTargetLongEdge(screen: NSScreen? = NSScreen.main) -> Int {
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let scale = screen?.backingScaleFactor ?? 2
        let longEdge = max(frame.width, frame.height) * scale
        return max(1024, min(Int(longEdge.rounded()), 4096))
    }

    /// Single focus writer — every loupe focus change goes through here so
    /// `focusedAssetKind` stays consistent with `focusedAssetID` and views never
    /// guess kind. `nil` clears kind; a non-nil ID triggers an
    /// async detail read that updates kind only if focus has not moved.
    ///
    /// It also reconciles the pane slots, so no focus change can leave the loupe
    /// showing — or waiting on — another asset's decode. Set `viewMode` first when
    /// both change: the reconcile reads it.
    ///
    /// Every call is a new visit (`focusVisit`). A playing story's item is this focus, so
    /// every writer — the story's own moves, Move to Trash's successor, a reorganization's
    /// remap — moves the story by moving focus, and the story starts the visit over.
    func setFocus(_ id: MediaAssetID?) {
        focusedAssetID = id
        focusVisit &+= 1
        let visit = focusVisit
        focusedAssetKind = nil
        focusedLivePhotoMotion = nil
        resetLoupeZoomForFocusChange()
        refreshPanePreviews()
        beginStoryVisit()
        focusedKindTask?.cancel()
        guard let id else { return }
        let reader = tileDetailReader
        let store = catalogStore
        focusedKindTask = Task { [weak self] in
            let detail: MediaTileDetail?
            do {
                detail = try await reader.detail(for: id)
            } catch {
                // The kind stays unknown, as it has been since focus moved, and the next
                // focus change reads again.
                self?.storyStalled(visit: visit, reason: "kindReadFailed", error: error)
                return
            }
            guard let self, !Task.isCancelled, focusedAssetID == id else { return }
            focusedAssetKind = detail?.bestKind
            storyKindResolved(visit: visit)
            // Opening a video prepares it, exactly as opening an image decodes it: no
            // click stands between the user and a playable asset. Kind is only known
            // here, so this is the one place that can start it.
            if focusedAssetKind == .video, viewMode == .loupe {
                prepareLoupeVideo(id: id)
            }
            guard let kind = focusedAssetKind, kind != .video else { return }
            let motion: MediaAssetID?
            do {
                motion = try await store.windowReads.livePhotoMotion(of: id)
            } catch {
                // Not known to be a Live Photo, so nothing offers to play it; the next
                // focus change reads again.
                OtosLog.ui.errorOperation("loupe.livePhoto", phase: "readFailed", fields: [
                    "id": id.relativePath.rawValue, "error": String(describing: error),
                ])
                return
            }
            guard !Task.isCancelled, focusedAssetID == id else { return }
            focusedLivePhotoMotion = motion
        }
    }

    func setViewMode(_ mode: BrowserViewMode) {
        // The duplicates list has one presentation (ADR 0042); the picker and ⌘1/2/3 are
        // disabled there, and on the map before it has reported a viewport, and a stray
        // call changes nothing.
        guard canChangeViewMode else {
            return
        }
        // On the map a mode opens the area the map shows (ADR 0040).
        if sidebarSelection == .places {
            openVisibleMapArea(mode: mode)
            return
        }
        // The selected scope's state is not applied: the items held are not the user's to open
        // (APP-080): the mode is the selected scope's, and settles on its items as it arrives.
        guard showsSelectedScope else {
            enterModeForOpeningScope(mode)
            return
        }
        switch mode {
        case .grid:
            exitToGrid()
        case .loupe:
            openLoupe(id: nil)
        case .compare:
            enterCompare()
        }
    }

    /// A mode chosen together with a scope that has not published yet — an area of the
    /// map. Its focus or pair cannot be chosen from items not yet known, so the mode is set
    /// now and they settle when the scope arrives (`reconcileFocusAfterGridChange`, scope
    /// changed), from the selection the opening intent chose.
    func enterModeForOpeningScope(_ mode: BrowserViewMode) {
        guard mode != .grid else {
            exitToGrid()
            return
        }
        comparePair = .empty
        lastReplacedComparePane = nil
        viewMode = mode
        OtosLog.ui.notice("op=viewMode.set mode=\(mode.rawValue, privacy: .public) pending=scope")
    }

    /// Enter loupe on `id` (double-click), or on the selection's active item / first
    /// selected / first in scope when `id` is nil (segment, ⌘2, Return). Nothing until the
    /// selected scope's state is applied: the photos held are not the user's to open
    /// (APP-080).
    func openLoupe(id: MediaAssetID?) {
        guard showsSelectedScope, let focus = BrowserModePolicy.loupeEntryFocus(
            preferredID: id,
            selection: gridSelection,
            orderedIDs: parts.mediaGrid.content
        ) else {
            return
        }
        if let id, id != focus {
            gridSelection = gridSelection.plainClick(id)
        } else if gridSelection.selection.isEmpty || !gridSelection.selection.contains(focus) {
            gridSelection = gridSelection.plainClick(focus)
        }
        comparePair = .empty
        lastReplacedComparePane = nil
        viewMode = .loupe
        setFocus(focus)
        OtosLog.ui.notice(
            "op=viewMode.set mode=loupe focus=\(focus.relativePath.rawValue, privacy: .public)"
        )
    }

    func enterCompare() {
        let ordered = parts.mediaGrid.orderedAssetIDs
        guard showsSelectedScope, !ordered.isEmpty else {
            return
        }
        let pair = ComparePairPolicy.entry(selection: gridSelection, orderedIDs: parts.mediaGrid.content)
        // viewMode must be .compare before applyComparePair → refreshPanePreviews,
        // otherwise expectedAsset(for: compare*) returns nil and no decode starts.
        viewMode = .compare
        activeComparePane = .right
        lastReplacedComparePane = .right
        applyComparePair(pair, orderedIDs: ordered)
        OtosLog.ui.notice(
            "op=viewMode.set mode=compare count=\(pair.members.count, privacy: .public)"
        )
    }

    func exitToGrid() {
        guard viewMode != .grid else {
            return
        }
        viewMode = .grid
        panePreviews = [:]
        downloadingSlots = []
        comparePair = .empty
        lastReplacedComparePane = nil
        cancelAllPaneRequestTasks()
        // No pane is left to return to a photo, so the loader lets go of what it held for one.
        previewLoader.releaseHeldPhotos()
        clearLoupeVideo()
        resetLoupeZoomForFocusChange()
        OtosLog.ui.notice("op=viewMode.set mode=grid")
    }

    /// The arrow key's step to the next photo, resolved against the order on screen at the
    /// press: the photo the full-size view now focuses, or nil when the step moved nothing
    /// (the last photo, or Compare, where it slides the pair).
    @discardableResult
    func focusNext() -> MediaAssetID? {
        focusNeighbor(delta: 1)
    }

    /// The step back, as `focusNext()`.
    @discardableResult
    func focusPrevious() -> MediaAssetID? {
        focusNeighbor(delta: -1)
    }

    func slideCompare(_ delta: Int) {
        guard viewMode == .compare else {
            return
        }
        let ordered = parts.mediaGrid.orderedAssetIDs
        let next = ComparePairPolicy.slide(delta, pair: comparePair, orderedIDs: ordered)
        lastReplacedComparePane = delta > 0 ? .right : .left
        activeComparePane = lastReplacedComparePane ?? .right
        applyComparePair(next, orderedIDs: ordered)
    }

    func applyCompareClick(
        _ id: MediaAssetID,
        replacing position: PanePosition,
        orderedIDs: [MediaAssetID]
    ) {
        let next = ComparePairPolicy.click(
            id,
            replacing: position,
            pair: comparePair,
            orderedIDs: orderedIDs
        )
        lastReplacedComparePane = position
        activeComparePane = position
        applyComparePair(next, orderedIDs: orderedIDs)
    }

    func activateComparePane(_ position: PanePosition) {
        guard viewMode == .compare else {
            return
        }
        activeComparePane = position
    }

    func swapComparedPhotos() {
        guard viewMode == .compare, comparePair.members.count == 2 else {
            return
        }
        comparePair = ComparePairPolicy.swapped(comparePair)
        gridSelection = GridSelection(
            selection: Set(comparePair.members),
            anchor: comparePair.left,
            base: Set(comparePair.members)
        )
        let activePosition = activeComparePane
        // Compare panes are positional peers: swapping assets must leave the
        // keyboard target on the same left/right position.
        lastReplacedComparePane = activePosition
        refreshPanePreviews()
        OtosLog.ui.notice("op=compare.swap")
    }

    /// Structural-apply / query churn for loupe and compare. Only a scope change starts
    /// over at the first item; a filter or sort change keeps the focus or pair members
    /// that survive and moves a lost one to its nearest survivor.
    ///
    /// Every lookup goes through the contents' indexes, so this costs in the focus and the
    /// pair, not in the order's size.
    func reconcileFocusAfterGridChange(
        previousOrder: CatalogGridContent,
        scopeChanged: Bool
    ) {
        // A playing story keeps its item or moves focus to the survivor itself, and closes
        // when nothing remains (ADR 0049).
        if story != nil {
            reconcileStoryAfterGridChange(previousOrder: previousOrder)
            return
        }
        let order = parts.mediaGrid.content
        let ordered = order.orderedAssetIDs
        if ordered.isEmpty {
            if viewMode != .grid {
                exitToGrid()
            }
            return
        }
        switch viewMode {
        case .grid:
            return
        case .loupe:
            if scopeChanged {
                // A new scope opens on its first item.
                let first = ordered.first
                setFocus(first)
                if let focus = first {
                    gridSelection = gridSelection.plainClick(focus)
                }
                return
            }
            let next = BrowserModePolicy.pruneFocus(
                previous: focusedAssetID,
                previousOrderedIDs: previousOrder,
                survivingOrderedIDs: order
            )
            guard next != focusedAssetID else {
                return
            }
            setFocus(next)
            if let next {
                gridSelection = gridSelection.plainClick(next)
            }
        case .compare:
            if scopeChanged {
                let pair = ComparePairPolicy.entry(selection: gridSelection, orderedIDs: order)
                lastReplacedComparePane = .right
                activeComparePane = .right
                applyComparePair(pair, orderedIDs: ordered)
                return
            }
            let pruned = ComparePairPolicy.prune(
                pair: comparePair,
                previousOrderedIDs: previousOrder,
                survivingOrderedIDs: order
            )
            applyComparePair(pruned, orderedIDs: ordered)
        }
    }

    func applyComparePair(_ pair: ComparePair, orderedIDs _: [MediaAssetID]) {
        comparePair = pair
        gridSelection = GridSelection(
            selection: Set(pair.members),
            anchor: pair.left ?? pair.members.first,
            base: Set(pair.members)
        )
        // Compare must not retarget loupe focus — exit/re-enter loupe keeps
        // BrowserModePolicy.loupeEntryFocus / prior focusedAssetID semantics.
        refreshPanePreviews()
    }

    /// Single source for "which asset should this pane show right now".
    func expectedAsset(for slot: PaneSlot) -> MediaAssetID? {
        switch slot {
        case .loupe:
            viewMode == .loupe ? focusedAssetID : nil
        case .compareLeft:
            viewMode == .compare ? comparePair.left : nil
        case .compareRight:
            viewMode == .compare ? comparePair.right : nil
        }
    }

    /// Strip focus target in compare: the most recently replaced slot's asset.
    var compareStripFocusTargetID: MediaAssetID? {
        switch lastReplacedComparePane ?? .right {
        case .left:
            comparePair.left
        case .right:
            comparePair.right
        }
    }

    /// Idempotent reconciliation of all three slots against expectation. `setFocus`
    /// runs it for every focus change; call it after every pair/mode mutation — this
    /// is the only pane-request entry point.
    func refreshPanePreviews() {
        for slot in PaneSlot.allCases {
            let expected = expectedAsset(for: slot)
            if panePreviews[slot]?.id != expected {
                panePreviews[slot] = nil
                downloadingSlots.remove(slot)
            }
            if let expected, panePreviews[slot] == nil {
                requestPanePreview(expected, slot: slot)
            }
        }
        // Loupe video follows loupe focus; clear a stale one — being prepared, ready or
        // unavailable — when focus changed or mode left loupe. Compare never shows video.
        // Single owner is the ViewModel's `loupeVideo`; the loader is a stateless factory.
        if let video = loupeVideo, video.id != focusedAssetID || viewMode != .loupe {
            clearLoupeVideo()
        }
    }

    /// Synchronous from the press to the focus: the neighbour is read from the order the
    /// window shows in the same step that moves to it, so an order published later (a capture
    /// date arriving) cannot come between the two.
    private func focusNeighbor(delta: Int) -> MediaAssetID? {
        if viewMode == .compare {
            slideCompare(delta)
            return nil
        }
        guard viewMode == .loupe else {
            return nil
        }
        let ordered = parts.mediaGrid.orderedAssetIDs
        let next = BrowserModePolicy.neighbor(of: focusedAssetID, in: ordered, delta: delta)
        guard let next, next != focusedAssetID else {
            return nil
        }
        setFocus(next)
        gridSelection = gridSelection.plainClick(next)
        return next
    }

    /// `targetLongEdge` defaults to the screen-sized tier; the loupe passes
    /// `PreviewImageLoader.fullResolution` for its 100-percent decode (APP-040).
    func requestPanePreview(_ id: MediaAssetID, slot: PaneSlot, targetLongEdge: Int? = nil) {
        let loader = previewLoader
        let detailReader = tileDetailReader
        let target = targetLongEdge ?? Self.previewTargetLongEdge()
        paneRequestTasks[slot]?.cancel()
        // The spinner tracks an outstanding request, not a failed one. Interactive
        // materialization persists until the bytes arrive or this request is
        // cancelled (APP-023), so "still coming" is exactly "still asking" — there is
        // no failed attempt left to infer it from. It marks a pane waiting for its photo
        // (DES-086): a request that refines the photo the pane already shows — its
        // full-resolution decode, or an edit's new preview — leaves it off, as that photo
        // stays on screen meanwhile. Completion clears it either way.
        if editSession.displayedPanePreview(slot)?.id != id {
            downloadingSlots.insert(slot)
        }
        let visit = focusVisit
        paneRequestTasks[slot] = Task(priority: .userInitiated) { [weak self] in
            let detail: MediaTileDetail?
            do {
                detail = try await detailReader.detail(for: id)
            } catch {
                guard !Task.isCancelled, let self, expectedAsset(for: slot) == id else {
                    return
                }
                // Without its row a decode would drop the photo's edit and curation, so
                // nothing is decoded or published. This request has ended, so its spinner
                // goes. A screen-sized request leaves the slot empty, which
                // `refreshPanePreviews` asks again for; a full-resolution one forgets it
                // was asked, so the next zoom report asks again.
                downloadingSlots.remove(slot)
                if target == PreviewImageLoader.fullResolution {
                    fullResolutionRequestedIDs.remove(id)
                }
                if slot == .loupe {
                    storyStalled(visit: visit, reason: "paneDetailFailed", error: error)
                }
                return
            }
            guard !Task.isCancelled else {
                return
            }
            let outcome = await loader.preview(
                for: PreviewImageLoader.Request(
                    id: id,
                    detail: detail,
                    targetLongEdge: target
                )
            )
            guard !Task.isCancelled else {
                // Deliberately does not clear the slot. A cancelled request has almost
                // always been superseded, and its replacement already owns the spinner —
                // clearing here would blank the indicator for a request that is still
                // running. `refreshPanePreviews` clears the slot before re-requesting, and
                // `exitToGrid` clears them all; those are the owners.
                return
            }
            await MainActor.run {
                guard let self else {
                    return
                }
                // Sole staleness guard: asset identity vs current expectation.
                guard self.expectedAsset(for: slot) == id else {
                    OtosLog.ui.debugOperation("pane.preview", phase: "stale", fields: [
                        "slot": String(describing: slot),
                        "id": id.relativePath.rawValue,
                        "expected": self.expectedAsset(for: slot)?.relativePath.rawValue ?? "none",
                    ])
                    return
                }
                // Both outcomes are terminal for this request. The request itself persists
                // until the bytes arrive or it is cancelled, so there is nothing to retry;
                // a re-request here would restart the attempt and reset its poll from zero,
                // so an image slower than the retry period could never finish.
                self.downloadingSlots.remove(slot)
                if case let .image(image, nativePixelSize) = outcome {
                    self.panePreviews[slot] = PanePreview(
                        id: id,
                        image: image,
                        mediaChoice: detail?.mediaChoice,
                        uprightPixelSize: nativePixelSize,
                        editRecipe: detail?.editRecipe,
                        renderedRevision: detail?.renderedRevision ?? 0
                    )
                    if slot == .loupe {
                        self.requestFullResolutionIfNeeded()
                        self.storyPaneSettled(visit: visit, pane: .shown)
                    }
                } else if slot == .loupe {
                    self.storyPaneSettled(visit: visit, pane: .none)
                }
            }
        }
    }

    private func cancelAllPaneRequestTasks() {
        for task in paneRequestTasks.values {
            task.cancel()
        }
        paneRequestTasks.removeAll()
    }

    // MARK: - Loupe video (prepared on focus, loupe only)

    /// The one implementation path for "make the focused video playable". `setFocus`
    /// calls it the moment the focused asset's kind resolves to video, so a video
    /// materializes by being opened, exactly like an image; the pane's Try Again calls it
    /// again after an attempt that found no player.
    ///
    /// `loupeVideo` turns `.preparing` in the frame of the call, so the pane shows its wait
    /// at once (DES-086), and ends `.ready` or `.unavailable` with the reason — never
    /// silently: a preparation that finds no player says so on the pane. This path does
    /// not touch `downloadingSlots`, which the pane-preview request for the same asset
    /// owns; the pane draws one indicator for either wait.
    func prepareLoupeVideo(id: MediaAssetID) {
        guard viewMode == .loupe, focusedAssetID == id, !isEjecting(id.libraryRootPath) else {
            return
        }
        // Already being prepared or playable: nothing to ask. An unavailable one asks again.
        if let video = loupeVideo, video.id == id, video.phase == .preparing || video.phase == .ready {
            return
        }
        let detailReader = tileDetailReader
        let loader = videoLoader
        let visit = focusVisit
        loupeVideoPrepareTask?.cancel()
        loupeVideo = .preparing(id)
        // `self` is weak across the awaits — a download can take as long as it takes — and
        // held only to apply what they answered.
        loupeVideoPrepareTask = Task { @MainActor [weak self] in
            let detail: MediaTileDetail?
            do {
                detail = try await detailReader.detail(for: id)
            } catch {
                guard let self, !Task.isCancelled, loupeVideo == .preparing(id) else { return }
                loupeVideo = .unavailable(id, .detailUnreadable)
                storyStalled(visit: visit, reason: "videoDetailFailed", error: error)
                return
            }
            let preparation = await loader.preparePlayer(id: id, detail: detail)
            // Revalidate after every await: focus may have moved while bytes arrived. A
            // preparation cancelled by a focus move found nothing out about this video.
            guard let self, !Task.isCancelled, focusedAssetID == id, viewMode == .loupe,
                  loupeVideo == .preparing(id)
            else {
                if case let .ready(state) = preparation {
                    loader.cleanup(state)
                }
                return
            }
            switch preparation {
            case let .ready(state):
                loupeVideo = .ready(state)
                storyVideoReady(state, visit: visit)
                OtosLog.ui.noticeOperation("loupe.video", phase: "ready", fields: [
                    "id": id.relativePath.rawValue,
                ])
            case let .unavailable(reason):
                loupeVideo = .unavailable(id, reason)
                OtosLog.ui.noticeOperation("loupe.video", phase: "unavailable", fields: [
                    "id": id.relativePath.rawValue, "reason": "\(reason)",
                ])
                storyVideoUnavailable(visit: visit)
            case .notVideo:
                loupeVideo = nil
            }
        }
    }

    /// The pane's Try Again: asks again for what the pane could not play — the focused
    /// video, or the Live Photo's motion — by the same path that asked the first time.
    func retryLoupeVideo() {
        guard case let .unavailable(id, _) = loupeVideo, id == focusedAssetID else { return }
        if focusedAssetKind == .video {
            prepareLoupeVideo(id: id)
        } else if focusedLivePhotoMotion != nil {
            loupeVideo = nil
            playLivePhoto()
        }
    }

    /// Whether the loupe can play the focused Live Photo's motion now: it shows one, and
    /// is not already preparing, playing or reporting it.
    var canPlayLivePhoto: Bool {
        viewMode == .loupe && story == nil && focusedLivePhotoMotion != nil && loupeVideo == nil
    }

    /// Plays the focused Live Photo's motion in place of its still, once, then shows the
    /// still again (ADR 0041). The movie is materialized at interactive priority like any
    /// video the loupe opens, and the pane shows the wait and any failure as it does a
    /// video's. Its player stands in the pane under the still's identity, so the existing
    /// focus rule tears it down when focus or mode moves; the still is the item, and
    /// nothing (trim, edit) can address the movie through it.
    func playLivePhoto() {
        guard canPlayLivePhoto, let still = focusedAssetID, let motion = focusedLivePhotoMotion,
              !isEjecting(still.libraryRootPath)
        else { return }
        let detailReader = tileDetailReader
        let loader = videoLoader
        loupeVideoPrepareTask?.cancel()
        loupeVideo = .preparing(still)
        loupeVideoPrepareTask = Task { @MainActor [weak self] in
            let detail: MediaTileDetail?
            do {
                detail = try await detailReader.detail(for: motion)
            } catch {
                OtosLog.ui.errorOperation("loupe.livePhoto", phase: "motionReadFailed", fields: [
                    "id": still.relativePath.rawValue, "error": String(describing: error),
                ])
                guard let self, !Task.isCancelled, loupeVideo == .preparing(still) else { return }
                loupeVideo = .unavailable(still, .detailUnreadable)
                return
            }
            let preparation = await loader.preparePlayer(id: motion, detail: detail)
            // `self` is held only for this applying step, not across the wait for the
            // movie's end below.
            guard let player = self?.applyLivePhotoMotion(preparation, still: still, cleanup: loader) else {
                return
            }
            // The movie reports its own end; the still comes back then. Observed before it
            // plays, so a short movie cannot end unseen. A focus or mode change meanwhile
            // tears the player down and cancels this task, which ends the wait.
            let ended = NotificationCenter.default.notifications(
                named: AVPlayerItem.didPlayToEndTimeNotification,
                object: player.currentItem
            )
            player.play()
            for await _ in ended {
                break
            }
            guard let self, !Task.isCancelled, loupeVideoState?.player === player else { return }
            OtosLog.ui.noticeOperation("loupe.livePhoto", phase: "ended", fields: [
                "id": still.relativePath.rawValue,
            ])
            clearLoupeVideo()
        }
    }

    /// Applies a Live Photo motion's preparation to the pane, if the still is still the one
    /// waiting for it: the player, paused for its caller to start, or why there is none.
    private func applyLivePhotoMotion(
        _ preparation: LoupeVideoPreparation,
        still: MediaAssetID,
        cleanup loader: VideoPreviewLoader
    ) -> AVPlayer? {
        guard !Task.isCancelled, focusedAssetID == still, viewMode == .loupe, loupeVideo == .preparing(still) else {
            if case let .ready(prepared) = preparation {
                loader.cleanup(prepared)
            }
            return nil
        }
        switch preparation {
        case let .ready(prepared):
            loupeVideo = .ready(LoupeVideoState(
                id: still, player: prepared.player, isPlaying: true, displaySize: prepared.displaySize
            ))
            OtosLog.ui.noticeOperation("loupe.livePhoto", phase: "play", fields: [
                "id": still.relativePath.rawValue,
            ])
            return prepared.player
        case let .unavailable(reason):
            loupeVideo = .unavailable(still, reason)
            OtosLog.ui.noticeOperation("loupe.livePhoto", phase: "unavailable", fields: [
                "id": still.relativePath.rawValue, "reason": "\(reason)",
            ])
        case .notVideo:
            loupeVideo = .unavailable(still, .downloadFailed)
            OtosLog.ui.noticeOperation("loupe.livePhoto", phase: "unavailable", fields: [
                "id": still.relativePath.rawValue, "reason": "motionNotVideo",
            ])
        }
        return nil
    }

    /// An eject of `root` is about to unmount it, and a player showing a file there holds
    /// that file open. The player, or its preparation, is released before the unmount.
    func releaseLoupeVideo(under root: LibraryRootPath) {
        guard focusedAssetID?.libraryRootPath == root || loupeVideo?.id.libraryRootPath == root else {
            return
        }
        OtosLog.ui.noticeOperation("loupe.video", phase: "released", fields: [
            "reason": "eject",
            "rootPath": root.rawValue,
        ])
        clearLoupeVideo()
    }

    private func isEjecting(_ root: LibraryRootPath) -> Bool {
        parts.removableSources.contains { source in
            source.path == root && source.root.deviceIdentity.map(ejectingSourceIdentities.contains) == true
        }
    }

    func clearLoupeVideo() {
        loupeVideoPrepareTask?.cancel()
        loupeVideoPrepareTask = nil
        if let state = loupeVideoState {
            videoLoader.cleanup(state)
        }
        loupeVideo = nil
    }
}
