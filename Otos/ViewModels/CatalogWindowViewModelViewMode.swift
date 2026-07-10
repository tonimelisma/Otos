import AppKit
import Foundation
import OSLog

/// Catalog window view-mode intents guide
///
/// Owns session-only `viewMode`, loupe `focusedAssetID`, and the preview-loader
/// lifetime. Every entry/exit/navigation rule from plan 0052 is either a pure
/// `BrowserModePolicy` call or a thin intent that applies that policy and kicks
/// preview decode. Views stay passive.
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
            // Compare lands in Increment 3; until then route to loupe so ⌘3 is not a
            // dead control once the menu item exists. Increment 3 replaces this.
            openLoupe(id: nil)
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
            // Double-click selects the clicked asset as a plain click so selection
            // and focus agree.
            gridSelection = gridSelection.plainClick(id)
        } else if gridSelection.selection.isEmpty || !gridSelection.selection.contains(focus) {
            gridSelection = gridSelection.plainClick(focus)
        }
        focusedAssetID = focus
        viewMode = .loupe
        previewGeneration &+= 1
        requestPreview(for: focus, generation: previewGeneration)
        OtosLog.ui.notice(
            "op=viewMode.set mode=loupe focus=\(focus.relativePath.rawValue, privacy: .public)"
        )
    }

    func exitToGrid() {
        guard viewMode != .grid else {
            return
        }
        viewMode = .grid
        previewImage = nil
        previewIsDownloading = false
        OtosLog.ui.notice("op=viewMode.set mode=grid")
    }

    func focusNext() {
        focusNeighbor(delta: 1)
    }

    func focusPrevious() {
        focusNeighbor(delta: -1)
    }

    /// Structural-apply / descriptor churn: keep loupe when possible, move focus to a
    /// survivor; descriptor change clears selection today and resets focus to first.
    func reconcileFocusAfterGridChange(
        previousOrderedIDs: [MediaAssetID],
        descriptorChanged: Bool
    ) {
        guard viewMode == .loupe else {
            return
        }
        let ordered = state.mediaGrid.orderedAssetIDs
        if ordered.isEmpty {
            exitToGrid()
            return
        }
        if descriptorChanged {
            focusedAssetID = ordered.first
            if let focus = focusedAssetID {
                gridSelection = gridSelection.plainClick(focus)
                previewGeneration &+= 1
                requestPreview(for: focus, generation: previewGeneration)
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
            requestPreview(for: next, generation: previewGeneration)
        }
    }

    private func focusNeighbor(delta: Int) {
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
        requestPreview(for: next, generation: previewGeneration)
    }

    private func requestPreview(for id: MediaAssetID, generation: UInt64) {
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
                guard result.generation == self.previewGeneration,
                      self.focusedAssetID == id,
                      self.viewMode == .loupe
                else {
                    return
                }
                switch result.outcome {
                case let .image(image):
                    self.previewImage = image
                    self.previewIsDownloading = false
                case .downloading:
                    self.previewIsDownloading = true
                    // Retry once materialization may have completed.
                    Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(500))
                        await MainActor.run {
                            guard let self,
                                  self.focusedAssetID == id,
                                  self.viewMode == .loupe
                            else {
                                return
                            }
                            self.previewGeneration &+= 1
                            self.requestPreview(for: id, generation: self.previewGeneration)
                        }
                    }
                case .unavailable:
                    self.previewIsDownloading = false
                }
            }
        }
    }
}
