import AppKit
import SwiftUI

/// Loupe view guide
///
/// Passive composition: aspect-fit preview pane (upscaled 256 px thumbnail until the
/// full-size decode arrives, never blanking) plus a shared filmstrip. All mode and
/// focus changes call ViewModel intents; this view does not own selection or decode.
struct LoupeView: View {
    let grid: CatalogMediaGridState
    let focusedAssetID: MediaAssetID?
    let previewImage: CGImage?
    let previewIsDownloading: Bool
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
            if let previewImage {
                Image(decorative: previewImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let focusedAssetID {
                ThumbnailPlaceholderView(
                    id: focusedAssetID,
                    thumbnailDirectory: thumbnailDirectory,
                    detailReader: detailReader
                )
            } else {
                ContentUnavailableView("No Selection", systemImage: "photo")
            }
            if previewIsDownloading {
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
        .focusable()
        .onKeyPress(.escape) {
            onEscape()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            onStripArrow(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            onStripArrow(1)
            return .handled
        }
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
            onArrowKey: onStripArrow
        )
    }
}

/// Loads the enrichment thumbnail for the focused asset so loupe never starts blank
/// while the full-size decode is in flight.
private struct ThumbnailPlaceholderView: View {
    let id: MediaAssetID
    var thumbnailDirectory: URL?
    var detailReader: MediaTileDetailReader?
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
            }
        }
        .task(id: id) {
            guard let detailReader else {
                return
            }
            let details = await detailReader.details(for: [id])
            guard let detail = details[id] else {
                return
            }
            image = MediaAssetTilePresentation.loadImage(
                detail: detail,
                thumbnailDirectory: thumbnailDirectory
            ).image
        }
    }
}
