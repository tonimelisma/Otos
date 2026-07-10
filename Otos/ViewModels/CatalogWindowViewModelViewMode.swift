import AppKit
import Foundation
import OSLog

/// Catalog window view-mode intents guide
///
/// Owns session-only `viewMode`, loupe `focusedAssetID`, compare pair, and the
/// preview-loader lifetime. Every entry/exit/navigation rule from plan 0052 is either
/// a pure `BrowserModePolicy` / `ComparePairPolicy` call or a thin intent that applies
/// that policy and kicks preview decode. Views stay passive.
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
        compareRightPreviewImage = nil
        focusedAssetID = focus
        viewMode = .loupe
        previewGeneration &+= 1
        requestPreview(for: focus, generation: previewGeneration, slot: .loupe)
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
        applyComparePair(pair, orderedIDs: ordered)
        viewMode = .compare
        OtosLog.ui.notice(
            "op=viewMode.set mode=compare count=\(pair.members.count, privacy: .public)"
        )
    }

    func exitToGrid() {
        guard viewMode != .grid else {
            return
        }
        viewMode = .grid
        previewImage = nil
        compareRightPreviewImage = nil
        previewIsDownloading = false
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
                    previewGeneration &+= 1
                    requestPreview(for: focus, generation: previewGeneration, slot: .loupe)
                }
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
                previewGeneration &+= 1
                requestPreview(for: next, generation: previewGeneration, slot: .loupe)
            }
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
        focusedAssetID = panes.left
        previewGeneration &+= 1
        let generation = previewGeneration
        if let left = panes.left {
            requestPreview(for: left, generation: generation, slot: .compareLeft)
        } else {
            previewImage = nil
        }
        if let right = panes.right {
            requestPreview(for: right, generation: generation, slot: .compareRight)
        } else {
            compareRightPreviewImage = nil
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
        previewGeneration &+= 1
        requestPreview(for: next, generation: previewGeneration, slot: .loupe)
    }

    private enum PreviewSlot {
        case loupe
        case compareLeft
        case compareRight
    }

    private func requestPreview(for id: MediaAssetID, generation: UInt64, slot: PreviewSlot) {
        previewIsDownloading = false
        let loader = previewLoader
        let detailReader = tileDetailReader
        let target = Self.previewTargetLongEdge()
        Task { [weak self] in
            let details = await detailReader.details(for: [id])
            let detail = details[id]
            let result = await loader.preview(
                for: PreviewImageLoader.Request(
                    id: id,
                    detail: detail,
                    targetLongEdge: target,
                    generation: generation
                )
            )
            await MainActor.run {
                guard let self else {
                    return
                }
                guard result.generation == self.previewGeneration else {
                    return
                }
                switch slot {
                case .loupe:
                    guard self.viewMode == .loupe, self.focusedAssetID == id else {
                        return
                    }
                case .compareLeft, .compareRight:
                    guard self.viewMode == .compare, self.comparePair.members.contains(id) else {
                        return
                    }
                }
                switch result.outcome {
                case let .image(image):
                    switch slot {
                    case .loupe, .compareLeft:
                        self.previewImage = image
                    case .compareRight:
                        self.compareRightPreviewImage = image
                    }
                    self.previewIsDownloading = false
                case .downloading:
                    self.previewIsDownloading = true
                    Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(500))
                        await MainActor.run {
                            guard let self, result.generation == self.previewGeneration else {
                                return
                            }
                            self.previewGeneration &+= 1
                            self.requestPreview(for: id, generation: self.previewGeneration, slot: slot)
                        }
                    }
                case .unavailable:
                    self.previewIsDownloading = false
                }
            }
        }
    }
}
