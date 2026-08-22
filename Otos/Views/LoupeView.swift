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
    var tileContentStore: TileContentStore?
    let focusedAssetID: MediaAssetID?
    let focusedAssetKind: MediaKind?
    let panePreview: PanePreview?
    let loupeVideoState: LoupeVideoState?
    let isDownloading: Bool
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
    var onDoubleClickPreview: () -> Void = {}
    var onPlayVideo: (MediaAssetID) -> Void = { _ in }
    var focusedMediaChoice: MediaChoice?
    var onPreviewMediaChoice: (MediaChoice) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            previewPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            FilmstripResizeHandle(
                stripTileEdge: stripTileEdge,
                setStripTileEdge: setStripTileEdge
            )
            filmstrip
                .frame(height: stripTileEdge + 12)
        }
    }

    private var previewPane: some View {
        MediaChoiceHoverRegion(
            currentChoice: focusedMediaChoice,
            onChoice: onPreviewMediaChoice
        ) {
            ZStack {
                Color.black.opacity(0.92)
                switch PanePresentation.display(
                    paneID: focusedAssetID,
                    preview: panePreview,
                    videoState: loupeVideoState
                ) {
                case let .video(state):
                    LoupeVideoPlayerView(state: state)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case let .full(image):
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityElement()
                        .accessibilityLabel(paneAccessibilityLabel)
                        .accessibilityAddTraits(.isImage)
                case let .thumbnail(id):
                    ZStack {
                        PaneThumbnailView(
                            id: id,
                            tileContentStore: tileContentStore,
                            thumbnailDirectory: thumbnailDirectory,
                            detailReader: detailReader
                        )
                        // Poster-first — keep the thumbnail until the player is ready.
                        // Retry affordance only: a video prepares itself on focus, so
                        // this glyph appears when preparation produced no player, and
                        // never beside the progress indicator that occupies its place.
                        if !isDownloading, shouldShowPlayAffordance(for: id) {
                            Image(systemName: "play.circle.fill")
                                .resizable()
                                .frame(width: 60, height: 60)
                                .foregroundStyle(.white.opacity(0.92))
                                .shadow(radius: 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard let focusedAssetID, focusedAssetKind == .video else {
                            return
                        }
                        onPlayVideo(focusedAssetID)
                    }
                case .empty:
                    ContentUnavailableView("No Selection", systemImage: "photo")
                }
                // Centered, where the play glyph sits (DES-086): the wait belongs on
                // the media the user is waiting for, not in a corner of the window.
                if isDownloading {
                    ProgressView()
                        .controlSize(.large)
                        .shadow(radius: 8)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onDoubleClickPreview)
        }
    }

    private func shouldShowPlayAffordance(for id: MediaAssetID) -> Bool {
        PanePresentation.shouldShowPlayAffordance(
            kind: focusedAssetKind,
            hasActiveVideo: loupeVideoState != nil,
            paneID: id,
            focusedID: focusedAssetID
        )
    }

    private var paneAccessibilityLabel: String {
        switch focusedAssetKind {
        case .video: "Video"
        case .raw: "RAW image"
        case .image: "Image"
        case .none: "Photo"
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
            presentation: .strip(tileEdge: stripTileEdge),
            onEscapeKey: onEscape,
            onArrowKey: onStripArrow,
            onMediaChoiceKey: onMediaChoiceKey,
            onMediaChoice: onMediaChoice,
            focusTargetID: focusedAssetID
        )
    }
}

/// Drag the top edge of the filmstrip to resize tile edge (drag up = larger).
struct FilmstripResizeHandle: View {
    let stripTileEdge: CGFloat
    let setStripTileEdge: (CGFloat) -> Void
    @State private var dragStartEdge: CGFloat?

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(height: 8)
            .contentShape(Rectangle())
            .overlay(ResizeCursorArea())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartEdge == nil {
                            dragStartEdge = stripTileEdge
                        }
                        guard let start = dragStartEdge else {
                            return
                        }
                        setStripTileEdge(start - value.translation.height)
                    }
                    .onEnded { _ in
                        dragStartEdge = nil
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Filmstrip Size")
            .accessibilityValue("\(Int(stripTileEdge)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: setStripTileEdge(stripTileEdge + 8)
                case .decrement: setStripTileEdge(stripTileEdge - 8)
                @unknown default: break
                }
            }
    }
}

/// A cursor rect rather than `NSCursor.push()/pop()` in `onHover`: SwiftUI does not
/// guarantee a trailing `onHover(false)` when the view is removed mid-hover (exit
/// loupe with ⌘1 while over the handle), which left the process-wide cursor stack
/// unbalanced.
private struct ResizeCursorArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        CursorView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class CursorView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeUpDown)
        }
    }
}
