import CoreGraphics
import Foundation
import OSLog

/// Loupe zoom and info intents guide
///
/// The ViewModel owns zoom intent, not zoom mechanics. The zoom view reports what it
/// measured (`loupeZoomReport`); every keyboard, menu and double-click path resolves
/// its target through `LoupeZoomPolicy` and issues one `LoupeZoomCommand` the view
/// applies once. View ▸ Zoom In / Zoom Out are the same menu items in every mode: the
/// grid's column count in grid, the image in loupe, nothing in compare.
///
/// Full resolution is a second `PreviewImageLoader` request for the same slot at the
/// `fullResolution` tier, issued once per focused asset when a report shows the held
/// decode is short of what the magnification displays. The fit-size decode stays
/// painted until the sharper one arrives — the no-blank rule applies to the loupe as
/// it does to the grid — and the same materialize-then-recheck gate (ARC-034) runs.
///
/// The info overlay reads facts the catalog already holds; nothing is fetched for it.
extension CatalogWindowViewModel {
    /// What the zoom view measured; `nil` outside loupe or before its first layout.
    func reportLoupeZoom(_ report: LoupeZoomReport) {
        guard viewMode == .loupe else { return }
        if loupeZoomReport != report {
            loupeZoomReport = report
        }
        requestFullResolutionIfNeeded()
    }

    var canZoom: Bool {
        switch viewMode {
        case .grid: true
        case .loupe: loupeZoomReport != nil
        case .compare: false
        }
    }

    /// View ▸ Zoom In (⌘=).
    func zoomIn() {
        switch viewMode {
        case .grid: zoomInGrid()
        case .loupe: stepLoupeZoom(1)
        case .compare: break
        }
    }

    /// View ▸ Zoom Out (⌘−).
    func zoomOut() {
        switch viewMode {
        case .grid: zoomOutGrid()
        case .loupe: stepLoupeZoom(-1)
        case .compare: break
        }
    }

    /// Double-click on the image and Z: fit ↔ 100 percent, about `anchor` when given.
    func toggleLoupeZoom(at anchor: CGPoint? = nil) {
        guard viewMode == .loupe, let report = loupeZoomReport else { return }
        let target = LoupeZoomPolicy.toggleTarget(current: report.magnification, fit: report.fit)
        issueLoupeZoom(target == report.fit ? .fit : .magnification(target), anchor: anchor)
    }

    /// Escape in loupe: disarm the white balance picker first, then back to fit, then out
    /// to the grid.
    func loupeEscape() {
        if isPickingNeutral {
            toggleNeutralPicker()
        } else if let report = loupeZoomReport, !report.isFit {
            issueLoupeZoom(.fit, anchor: nil)
        } else {
            exitToGrid()
        }
    }

    /// A focus change starts the next image at fit with nothing carried over.
    func resetLoupeZoomForFocusChange() {
        loupeZoomReport = nil
        loupeZoomCommand = nil
        fullResolutionRequestedIDs.removeAll()
        fullResolutionSkipLoggedID = nil
        refreshLoupeInfo()
    }

    private func stepLoupeZoom(_ direction: Int) {
        guard let report = loupeZoomReport else { return }
        let next = LoupeZoomPolicy.stepped(report.magnification, direction: direction, fit: report.fit)
        guard next != report.magnification else { return }
        issueLoupeZoom(LoupeZoomPolicy.isFit(next, fit: report.fit) ? .fit : .magnification(next), anchor: nil)
    }

    private func issueLoupeZoom(_ target: LoupeZoomCommand.Target, anchor: CGPoint?) {
        loupeZoomGeneration += 1
        loupeZoomCommand = LoupeZoomCommand(target: target, anchor: anchor, generation: loupeZoomGeneration)
        let description = switch target {
        case .fit: "fit"
        case let .magnification(value): String(format: "%.3f", value)
        }
        OtosLog.ui.notice("op=loupe.zoom target=\(description, privacy: .public)")
    }

    func requestFullResolutionIfNeeded() {
        guard viewMode == .loupe,
              let id = focusedAssetID,
              let preview = panePreviews[.loupe], preview.id == id,
              let native = preview.nativePixelSize,
              let report = loupeZoomReport
        else { return }
        let decodedLongEdge = max(preview.image.width, preview.image.height)
        let nativeLongEdge = Int(max(native.width, native.height))
        guard LoupeZoomPolicy.needsFullResolution(
            decodedLongEdge: decodedLongEdge,
            nativeLongEdge: nativeLongEdge,
            magnification: report.magnification
        ) else {
            logFullResolutionSufficient(id, decoded: decodedLongEdge, native: nativeLongEdge, report: report)
            return
        }
        guard !fullResolutionRequestedIDs.contains(id) else { return }
        fullResolutionRequestedIDs.insert(id)
        let name = id.relativePath.rawValue
        OtosLog.ui.notice(
            "op=loupe.fullRes id=\(name, privacy: .public) decoded=\(decodedLongEdge, privacy: .public) native=\(nativeLongEdge, privacy: .public)"
        )
        requestPanePreview(id, slot: .loupe, targetLongEdge: PreviewImageLoader.fullResolution)
    }

    /// Records, once per focus, that the held decode already covers what the pane
    /// displays — the expected reason a loupe image stays at its screen-sized decode.
    private func logFullResolutionSufficient(
        _ id: MediaAssetID,
        decoded: Int,
        native: Int,
        report: LoupeZoomReport
    ) {
        guard fullResolutionSkipLoggedID != id else { return }
        fullResolutionSkipLoggedID = id
        let displayed = Int((CGFloat(native) * report.magnification).rounded())
        OtosLog.ui.debugOperation("loupe.fullRes", phase: "skip", fields: [
            "reason": "decodeSufficient", "id": id.relativePath.rawValue,
            "decoded": "\(decoded)", "native": "\(native)", "displayed": "\(displayed)",
        ])
    }

    // MARK: - Info overlay

    /// View ▸ Show Info / Hide Info and I.
    func toggleLoupeInfo() {
        showsLoupeInfo.toggle()
        let shown = showsLoupeInfo
        OtosLog.ui.notice("op=loupe.info shown=\(shown, privacy: .public)")
        refreshLoupeInfo()
    }

    /// Rebuilds the overlay for the focused asset. Called on toggle, focus change, and
    /// when the loupe decode lands (that is when the native size becomes known).
    func refreshLoupeInfo() {
        loupeInfoTask?.cancel()
        guard showsLoupeInfo, viewMode == .loupe, let id = focusedAssetID else {
            loupeInfo = nil
            loupeInfoTask = nil
            return
        }
        let store = catalogStore
        loupeInfoTask = Task { [weak self] in
            let asset = try? await store.mediaAssets(for: [id])[id]
            guard !Task.isCancelled, let self, focusedAssetID == id, showsLoupeInfo else { return }
            let preview = panePreviews[.loupe]
            loupeInfo = LoupeInfoModel.make(
                id: id,
                asset: asset,
                kind: focusedAssetKind,
                nativePixelSize: preview?.id == id ? preview?.nativePixelSize : nil
            )
            loupeInfoTask = nil
        }
    }
}
