import AppKit
import Foundation
import OSLog

/// Catalog window view-mode intents guide
///
/// Owns session-only `viewMode`, loupe `focusedAssetID`, compare pair, and the
/// pane-preview request lifecycle. Every entry/exit/navigation rule is either a pure
/// `BrowserModePolicy` / `ComparePairPolicy` call or a thin intent that applies that
/// policy and reconciles pane slots via `refreshPanePreviews()`. Views stay passive.
extension CatalogWindowViewModel {
    /// Target long edge for loupe/compare decode (points × backing scale of the main
    /// display, clamped). Computed on the MainActor when a decode is requested.
    static func previewTargetLongEdge(screen: NSScreen? = NSScreen.main) -> Int {
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let scale = screen?.backingScaleFactor ?? 2
        let longEdge = max(frame.width, frame.height) * scale
        return max(1024, min(Int(longEdge.rounded()), 4096))
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
        focusedAssetID = focus
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
        applyComparePair(next, orderedIDs: ordered)
    }

    func applyCompareClick(_ id: MediaAssetID, orderedIDs: [MediaAssetID]) {
        let next = ComparePairPolicy.click(id, pair: comparePair, orderedIDs: orderedIDs)
        applyComparePair(next, orderedIDs: orderedIDs)
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
                focusedAssetID = ordered.first
                if let focus = focusedAssetID {
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
            focusedAssetID = next
            if let next {
                gridSelection = gridSelection.plainClick(next)
            }
            refreshPanePreviews()
        case .compare:
            if descriptorChanged {
                let pair = ComparePairPolicy.entry(selection: .empty, orderedIDs: ordered)
                applyComparePair(pair, orderedIDs: ordered)
                return
            }
            let pruned = ComparePairPolicy.prune(pair: comparePair, survivingOrderedIDs: ordered)
            applyComparePair(pruned, orderedIDs: ordered)
        }
    }

    func applyComparePair(_ pair: ComparePair, orderedIDs: [MediaAssetID]) {
        comparePair = pair
        let panes = pair.panes(in: orderedIDs)
        gridSelection = GridSelection(
            selection: Set(pair.members),
            anchor: panes.left ?? pair.members.first,
            base: Set(pair.members)
        )
        // Compare must not retarget loupe focus — exit/re-enter loupe keeps
        // BrowserModePolicy.loupeEntryFocus / prior focusedAssetID semantics.
        refreshPanePreviews()
    }

    /// Single source for "which asset should this pane show right now".
    func expectedAsset(for slot: PaneSlot) -> MediaAssetID? {
        let ordered = state.mediaGrid.orderedAssetIDs
        switch slot {
        case .loupe:
            return viewMode == .loupe ? focusedAssetID : nil
        case .compareLeft:
            return viewMode == .compare ? comparePair.panes(in: ordered).left : nil
        case .compareRight:
            return viewMode == .compare ? comparePair.panes(in: ordered).right : nil
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
        focusedAssetID = next
        gridSelection = gridSelection.plainClick(next)
        refreshPanePreviews()
    }

    private func requestPanePreview(_ id: MediaAssetID, slot: PaneSlot) {
        let loader = previewLoader
        let detailReader = tileDetailReader
        let target = Self.previewTargetLongEdge()
        Task { [weak self] in
            let details = await detailReader.details(for: [id])
            let detail = details[id]
            let outcome = await loader.preview(
                for: PreviewImageLoader.Request(
                    id: id,
                    detail: detail,
                    targetLongEdge: target
                )
            )
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
                    self.panePreviews[slot] = PanePreview(id: id, image: image)
                    self.downloadingSlots.remove(slot)
                case .downloading:
                    self.downloadingSlots.insert(slot)
                    Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(500))
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
}
