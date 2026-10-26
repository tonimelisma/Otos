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
    var tileContentStore: TileContentStore?
    let leftID: MediaAssetID?
    let rightID: MediaAssetID?
    let leftPreview: PanePreview?
    let rightPreview: PanePreview?
    let leftIsDownloading: Bool
    let rightIsDownloading: Bool
    /// Most recently replaced slot's asset — centered in the strip.
    var focusTargetID: MediaAssetID?
    let stripTileEdge: CGFloat
    let setStripTileEdge: (CGFloat) -> Void
    var thumbnailDirectory: URL?
    var detailReader: MediaTileDetailReader?
    var stallMonitor: MainRunLoopStallMonitor?
    var selectionHandlers: MediaGridSelectionHandlers = .init()
    var onViewportChanged: ([MediaAssetID]) -> Void = { _ in }
    var onStripArrow: (Int) -> Void = { _ in }
    var onEscape: () -> Void = {}
    var onMediaChoiceKey: (MediaChoice) -> Void = { _ in }
    var onMediaChoice: (MediaAssetID, MediaChoice) -> Void = { _, _ in }
    var leftMediaChoice: MediaChoice?
    var rightMediaChoice: MediaChoice?
    var onPaneMediaChoice: (PanePosition, MediaChoice) -> Void = { _, _ in }
    /// The pane the Photo commands, the toolbar and the edit panel act on.
    var activePane: PanePosition = .right
    var onPaneActivated: (PanePosition) -> Void = { _ in }
    /// Context menu for the active pane's asset (pane) and the clicked tile (strip).
    /// A pane context click activates that pane first, so the menu describes it.
    var contextMenu: () -> NSMenu? = { nil }
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                pane(
                    position: .left,
                    id: leftID,
                    preview: leftPreview,
                    mediaChoice: leftMediaChoice,
                    isDownloading: leftIsDownloading
                )
                pane(
                    position: .right,
                    id: rightID,
                    preview: rightPreview,
                    mediaChoice: rightMediaChoice,
                    isDownloading: rightIsDownloading
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            FilmstripResizeHandle(
                stripTileEdge: stripTileEdge,
                setStripTileEdge: setStripTileEdge
            )
            filmstrip
                .frame(height: stripTileEdge + 12)
        }
    }

    private func pane(
        position: PanePosition,
        id: MediaAssetID?,
        preview: PanePreview?,
        mediaChoice: MediaChoice?,
        isDownloading: Bool
    ) -> some View {
        // Resolved once: the hover region needs the media's size to place the
        // curation group on the picture rather than in the pane's letterbox
        // (DES-066), and the content needs the same decision to render.
        let display = PanePresentation.display(paneID: id, preview: preview)
        return MediaChoiceHoverRegion(
            currentChoice: mediaChoice,
            mediaPixelSize: display.mediaPixelSize,
            onChoice: { choice in
                onPaneActivated(position)
                onPaneMediaChoice(position, choice)
            },
            content: {
                ZStack {
                    DesignPalette.content(for: colorScheme)
                    switch display {
                    case let .full(image):
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .accessibilityElement()
                            .accessibilityLabel(paneAccessibilityLabel(for: id))
                            .accessibilityAddTraits(.isImage)
                    case let .thumbnail(paneID):
                        PaneThumbnailView(
                            id: paneID,
                            thumbnailDirectory: thumbnailDirectory,
                            detailReader: detailReader
                        )
                    case .video:
                        // Compare stays poster-only by design; stale video never shows here.
                        Group {
                            if let fallbackID = id ?? preview?.id {
                                PaneThumbnailView(
                                    id: fallbackID,
                                    tileContentStore: tileContentStore,
                                    thumbnailDirectory: thumbnailDirectory,
                                    detailReader: detailReader
                                )
                            } else {
                                ContentUnavailableView("No Photo", systemImage: "photo")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    case .empty:
                        ContentUnavailableView("No Photo", systemImage: "photo")
                            .foregroundStyle(.secondary)
                    }
                    // The active pane's picture carries the grid's selection outline
                    // (DES-061, DES-096), on the media rather than the letterbox, the way
                    // the hover controls are placed (DES-066).
                    if position == activePane, id != nil {
                        GeometryReader { proxy in
                            let face = MediaAssetTilePresentation.contentRect(
                                imagePixelSize: display.mediaPixelSize,
                                bounds: CGRect(origin: .zero, size: proxy.size)
                            )
                            Rectangle()
                                .strokeBorder(
                                    Color.accentColor,
                                    lineWidth: MediaAssetTilePresentation.selectionBorderWidth
                                )
                                .frame(width: face.width, height: face.height)
                                .offset(x: face.minX, y: face.minY)
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                    // Centered like the loupe pane (DES-086) — one pane idiom for waiting.
                    if isDownloading {
                        ProgressView()
                            .controlSize(.large)
                            .shadow(radius: 8)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .accessibilityAddTraits(position == activePane ? .isSelected : [])
                .onTapGesture {
                    onPaneActivated(position)
                }
                .overlay {
                    ContextMenuHost(willOpen: { onPaneActivated(position) }, makeMenu: contextMenu)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        )
    }

    private func paneAccessibilityLabel(for id: MediaAssetID?) -> String {
        "Photo"
    }

    private var filmstrip: some View {
        MediaGridBridgeView(
            grid: grid,
            thumbnailDirectory: thumbnailDirectory,
            detailReader: detailReader,
            stallMonitor: stallMonitor,
            onViewportChanged: onViewportChanged,
            selectionHandlers: selectionHandlers,
            presentation: .strip(tileEdge: stripTileEdge),
            onEscapeKey: onEscape,
            onArrowKey: onStripArrow,
            onMediaChoiceKey: onMediaChoiceKey,
            onMediaChoice: onMediaChoice,
            contextMenu: contextMenu,
            focusTargetID: focusTargetID
        )
    }
}
