import AppKit
import AVFoundation
import Foundation
import OSLog

/// Catalog window view-mode intents guide
///
/// Owns session-only `viewMode`, loupe `focusedAssetID`, compare pair, and the
/// pane-preview request lifecycle. Every entry/exit/navigation rule is either a pure
/// `BrowserModePolicy` / `ComparePairPolicy` call or a thin intent that applies that
/// policy and reconciles pane slots via `refreshPanePreviews()`. Each `PaneSlot` has
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
    func setFocus(_ id: MediaAssetID?) {
        focusedAssetID = id
        focusedAssetKind = nil
        guard let id else { return }
        let reader = tileDetailReader
        Task { @MainActor [weak self] in
            let details = await reader.details(for: [id])
            guard let self, focusedAssetID == id else { return }
            focusedAssetKind = details[id]?.bestKind
            // Opening a video prepares it, exactly as opening an image decodes it: no
            // click stands between the user and a playable asset. Kind is only known
            // here, so this is the one place that can start it.
            if focusedAssetKind == .video, viewMode == .loupe {
                prepareLoupeVideo(id: id, startPlaying: false)
            }
        }
    }

    func setViewMode(_ mode: BrowserViewMode) {
        switch mode {
        case .grid:
            exitToGrid()
        case .loupe:
            openLoupe(id: nil)
        case .compare:
            enterCompare()
        }
    }

    /// Enter loupe on `id` (double-click), or on the selection's active item / first
    /// selected / first in scope when `id` is nil (segment, ⌘2, Return).
    func openLoupe(id: MediaAssetID?) {
        let ordered = state.mediaGrid.orderedAssetIDs
        guard let focus = BrowserModePolicy.loupeEntryFocus(
            preferredID: id,
            selection: gridSelection,
            orderedIDs: ordered
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
        setFocus(focus)
        viewMode = .loupe
        refreshPanePreviews()
        OtosLog.ui.notice(
            "op=viewMode.set mode=loupe focus=\(focus.relativePath.rawValue, privacy: .public)"
        )
    }

    func enterCompare() {
        let ordered = state.mediaGrid.orderedAssetIDs
        guard !ordered.isEmpty else {
            return
        }
        let pair = ComparePairPolicy.entry(selection: gridSelection, orderedIDs: ordered)
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
        clearLoupeVideo()
        OtosLog.ui.notice("op=viewMode.set mode=grid")
    }

    func focusNext() {
        focusNeighbor(delta: 1)
    }

    func focusPrevious() {
        focusNeighbor(delta: -1)
    }

    func slideCompare(_ delta: Int) {
        guard viewMode == .compare else {
            return
        }
        let ordered = state.mediaGrid.orderedAssetIDs
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

    /// Structural-apply / descriptor churn for loupe and compare.
    func reconcileFocusAfterGridChange(
        previousOrderedIDs: [MediaAssetID],
        descriptorChanged: Bool
    ) {
        let ordered = state.mediaGrid.orderedAssetIDs
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
            if descriptorChanged {
                let first = ordered.first
                setFocus(first)
                if let focus = first {
                    gridSelection = gridSelection.plainClick(focus)
                }
                refreshPanePreviews()
                return
            }
            let next = BrowserModePolicy.pruneFocus(
                previous: focusedAssetID,
                previousOrderedIDs: previousOrderedIDs,
                survivingOrderedIDs: ordered
            )
            guard next != focusedAssetID else {
                return
            }
            setFocus(next)
            if let next {
                gridSelection = gridSelection.plainClick(next)
            }
            refreshPanePreviews()
        case .compare:
            if descriptorChanged {
                let pair = ComparePairPolicy.entry(selection: .empty, orderedIDs: ordered)
                lastReplacedComparePane = .right
                activeComparePane = .right
                applyComparePair(pair, orderedIDs: ordered)
                return
            }
            let pruned = ComparePairPolicy.prune(
                pair: comparePair,
                previousOrderedIDs: previousOrderedIDs,
                survivingOrderedIDs: ordered
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

    /// Idempotent reconciliation of all three slots against expectation. Call after
    /// EVERY focus/pair/mode mutation — this is the only pane-request entry point.
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
        // Loupe video follows loupe focus; clear stale video when focus changed
        // or mode left loupe. Compare never shows video. Single owner is
        // ViewModel's `loupeVideoState`; loader is stateless factory.
        if loupeVideoState?.id != focusedAssetID || viewMode != .loupe {
            if let stale = loupeVideoState {
                loupeVideoPrepareTask?.cancel()
                loupeVideoPrepareTask = nil
                videoLoader.cleanup(stale)
            }
            loupeVideoState = nil
        }
    }

    private func focusNeighbor(delta: Int) {
        if viewMode == .compare {
            slideCompare(delta)
            return
        }
        guard viewMode == .loupe else {
            return
        }
        let ordered = state.mediaGrid.orderedAssetIDs
        let next = BrowserModePolicy.neighbor(of: focusedAssetID, in: ordered, delta: delta)
        guard let next, next != focusedAssetID else {
            return
        }
        setFocus(next)
        gridSelection = gridSelection.plainClick(next)
        refreshPanePreviews()
    }

    private func requestPanePreview(_ id: MediaAssetID, slot: PaneSlot) {
        let loader = previewLoader
        let detailReader = tileDetailReader
        let target = Self.previewTargetLongEdge()
        paneRequestTasks[slot]?.cancel()
        paneRequestTasks[slot] = Task(priority: .userInitiated) { [weak self] in
            let details = await detailReader.details(for: [id])
            guard !Task.isCancelled else {
                return
            }
            let detail = details[id]
            let outcome = await loader.preview(
                for: PreviewImageLoader.Request(
                    id: id,
                    detail: detail,
                    targetLongEdge: target
                )
            )
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                guard let self else {
                    return
                }
                // Sole staleness guard: asset identity vs current expectation.
                guard self.expectedAsset(for: slot) == id else {
                    return
                }
                switch outcome {
                case let .image(image):
                    self.panePreviews[slot] = PanePreview(
                        id: id,
                        image: image,
                        mediaChoice: detail?.mediaChoice
                    )
                    self.downloadingSlots.remove(slot)
                case .downloading:
                    self.downloadingSlots.insert(slot)
                    self.paneRequestTasks[slot] = Task(priority: .userInitiated) { [weak self] in
                        try? await Task.sleep(for: .milliseconds(500))
                        guard !Task.isCancelled else {
                            return
                        }
                        await MainActor.run {
                            guard let self, self.expectedAsset(for: slot) == id else {
                                return
                            }
                            self.requestPanePreview(id, slot: slot)
                        }
                    }
                case .unavailable:
                    self.downloadingSlots.remove(slot)
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
    /// calls it with `startPlaying: false` the moment the focused asset's kind resolves
    /// to video, so a video materializes by being opened, exactly like an image. The
    /// poster's play glyph — which appears only when preparation produced no player —
    /// calls the same function with `startPlaying: true`.
    ///
    /// This path deliberately does not touch `downloadingSlots`. The pane-preview
    /// request for the same asset is already awaiting the same materialization and is
    /// the single owner of the pane's progress indicator; a second writer could clear
    /// the spinner while the other fetch was still running.
    func prepareLoupeVideo(id: MediaAssetID, startPlaying: Bool) {
        guard viewMode == .loupe, focusedAssetID == id, loupeVideoState?.id != id else {
            return
        }
        let detailReader = tileDetailReader
        let loader = videoLoader
        loupeVideoPrepareTask?.cancel()
        loupeVideoPrepareTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let detail = await detailReader.details(for: [id])[id]
            guard !Task.isCancelled, detail?.bestKind == .video else { return }
            guard let state = await loader.preparePlayer(id: id, detail: detail) else {
                OtosLog.ui.notice(
                    "op=loupe.video phase=unavailable id=\(id.relativePath.rawValue, privacy: .public)"
                )
                return
            }
            // Revalidate after every await: focus may have moved while bytes arrived.
            guard !Task.isCancelled, focusedAssetID == id, viewMode == .loupe else {
                loader.cleanup(state)
                return
            }
            var prepared = state
            if startPlaying {
                state.player.play()
                prepared.isPlaying = true
            }
            loupeVideoState = prepared
            OtosLog.ui.notice(
                """
                op=loupe.video phase=\(startPlaying ? "play" : "ready", privacy: .public) \
                id=\(id.relativePath.rawValue, privacy: .public)
                """
            )
        }
    }

    /// Explicit play intent from the poster's play glyph — same path, playing.
    func playLoupeVideo(id: MediaAssetID) {
        prepareLoupeVideo(id: id, startPlaying: true)
    }

    private func clearLoupeVideo() {
        loupeVideoPrepareTask?.cancel()
        loupeVideoPrepareTask = nil
        if let state = loupeVideoState {
            videoLoader.cleanup(state)
        }
        loupeVideoState = nil
    }
}
