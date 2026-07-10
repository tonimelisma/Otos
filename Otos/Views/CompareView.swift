import AppKit
import SwiftUI

/// Compare view guide
///
/// Passive two-pane + filmstrip composition. No labels, buttons, or role chrome —
/// the pair is the capped selection; accent rings on the strip mark both members.
struct CompareView: View {
    let grid: CatalogMediaGridState
    let leftID: MediaAssetID?
    let rightID: MediaAssetID?
    let leftPreview: CGImage?
    let rightPreview: CGImage?
    let previewIsDownloading: Bool
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
                pane(id: leftID, preview: leftPreview)
                pane(id: rightID, preview: rightPreview)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            filmstrip
                .frame(height: MediaGridPresentation.defaultStripTileEdge + 12)
        }
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

    private func pane(id: MediaAssetID?, preview: CGImage?) -> some View {
        ZStack {
            Color.black.opacity(0.92)
            if let preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let id {
                CompareThumbnailPlaceholder(
                    id: id,
                    thumbnailDirectory: thumbnailDirectory,
                    detailReader: detailReader
                )
            } else {
                ContentUnavailableView("No Photo", systemImage: "photo")
                    .foregroundStyle(.secondary)
            }
            if previewIsDownloading {
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
            onArrowKey: onStripArrow
        )
    }
}

private struct CompareThumbnailPlaceholder: View {
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
