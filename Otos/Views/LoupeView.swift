import AppKit
import SwiftUI

/// Loupe view guide
///
/// Passive composition: aspect-fit preview pane (upscaled 256 px thumbnail until the
/// full-size decode arrives, never blanking, never showing another asset's image) plus
/// a shared filmstrip. All mode and focus changes call ViewModel intents; this view
/// does not own selection or decode.
struct LoupeView: View {
    let grid: CatalogMediaGridState
    let focusedAssetID: MediaAssetID?
    let panePreview: PanePreview?
    let isDownloading: Bool
    var thumbnailDirectory: URL?
    var detailReader: MediaTileDetailReader?
    var stallMonitor: MainRunLoopStallMonitor?
    var selectionHandlers: MediaGridSelectionHandlers = .init()
    var onViewportChanged: ([MediaAssetID]) -> Void = { _ in }
    var onStripArrow: (Int) -> Void = { _ in }
    var onEscape: () -> Void = {}
    var onDoubleClickPreview: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            previewPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            filmstrip
                .frame(height: MediaGridPresentation.defaultStripTileEdge + 12)
        }
    }

    private var previewPane: some View {
        ZStack {
            Color.black.opacity(0.92)
            switch PanePresentation.display(paneID: focusedAssetID, preview: panePreview) {
            case let .full(image):
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .thumbnail(id):
                PaneThumbnailView(
                    id: id,
                    thumbnailDirectory: thumbnailDirectory,
                    detailReader: detailReader
                )
            case .empty:
                ContentUnavailableView("No Selection", systemImage: "photo")
            }
            if isDownloading {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(16)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onDoubleClickPreview)
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
            focusTargetID: focusedAssetID
        )
    }
}
