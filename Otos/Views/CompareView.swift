import AppKit
import SwiftUI

/// Compare view guide
///
/// Passive two-pane + filmstrip composition. No labels, buttons, or role chrome —
/// the pair is the capped selection; accent rings on the strip mark both members.
/// Each pane renders by identity: a full decode only when its `PanePreview.id`
/// matches the pane asset; otherwise the enrichment thumbnail.
struct CompareView: View {
    let grid: CatalogMediaGridState
    let leftID: MediaAssetID?
    let rightID: MediaAssetID?
    let leftPreview: PanePreview?
    let rightPreview: PanePreview?
    let leftIsDownloading: Bool
    let rightIsDownloading: Bool
    /// Newest pair member — centered in the strip on entry/replacement.
    var focusTargetID: MediaAssetID?
    var thumbnailDirectory: URL?
    var detailReader: MediaTileDetailReader?
    var stallMonitor: MainRunLoopStallMonitor?
    var selectionHandlers: MediaGridSelectionHandlers = .init()
    var onViewportChanged: ([MediaAssetID]) -> Void = { _ in }
    var onStripArrow: (Int) -> Void = { _ in }
    var onEscape: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                pane(id: leftID, preview: leftPreview, isDownloading: leftIsDownloading)
                pane(id: rightID, preview: rightPreview, isDownloading: rightIsDownloading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            filmstrip
                .frame(height: MediaGridPresentation.defaultStripTileEdge + 12)
        }
    }

    private func pane(id: MediaAssetID?, preview: PanePreview?, isDownloading: Bool) -> some View {
        ZStack {
            Color.black.opacity(0.92)
            switch PanePresentation.display(paneID: id, preview: preview) {
            case let .full(image):
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            case let .thumbnail(paneID):
                PaneThumbnailView(
                    id: paneID,
                    thumbnailDirectory: thumbnailDirectory,
                    detailReader: detailReader
                )
            case .empty:
                ContentUnavailableView("No Photo", systemImage: "photo")
                    .foregroundStyle(.secondary)
            }
            if isDownloading {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filmstrip: some View {
        MediaGridBridgeView(
            grid: grid,
            thumbnailDirectory: thumbnailDirectory,
            detailReader: detailReader,
            stallMonitor: stallMonitor,
            onViewportChanged: onViewportChanged,
            selectionHandlers: selectionHandlers,
            presentation: .strip(tileEdge: MediaGridPresentation.defaultStripTileEdge),
            onEscapeKey: onEscape,
            onArrowKey: onStripArrow,
            focusTargetID: focusTargetID
        )
    }
}
