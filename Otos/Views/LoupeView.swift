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
    var onPlayVideo: (MediaAssetID) -> Void = { _ in }
    var focusedMediaChoice: MediaChoice?
    var onPreviewMediaChoice: (MediaChoice) -> Void = { _ in }
    /// Context menu for the focused asset (pane) and the clicked tile (strip).
    var contextMenu: () -> NSMenu? = { nil }
    /// Zoom (APP-040): the ViewModel's pending command and where reports go.
    var loupeZoomCommand: LoupeZoomCommand?
    var onZoomReport: (LoupeZoomReport) -> Void = { _ in }
    var onZoomDoubleClick: (CGPoint) -> Void = { _ in }
    var isPickingNeutral = false
    var onPickNeutral: (CGPoint) -> Void = { _ in }
    /// While the crop tool is on: the whole frame it draws over, and the crop.
    var cropEditor: CropEditorInput?
    var videoTrimCommand: VideoTrimCommand?
    var onVideoTrimmed: @MainActor (MediaAssetID) -> Void = { _ in }
    /// The pane shows the photo without its edit (Show Original): marked, DES-098.
    var showsOriginal = false
    /// The focused photo is a Live Photo whose motion can play now (DES-106).
    var canPlayLivePhoto = false
    var onPlayLivePhoto: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let cropEditor {
                    CropEditorView(
                        image: cropEditor.image,
                        crop: cropEditor.crop,
                        fractionRatio: cropEditor.fractionRatio,
                        setCrop: cropEditor.setCrop,
                        isDrawingLine: cropEditor.isDrawingLine,
                        straighten: cropEditor.straighten,
                        escape: onEscape
                    )
                    .background(DesignPalette.content(for: colorScheme))
                } else {
                    previewPane
                }
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

    private var previewPane: some View {
        // Resolved once: the hover region needs the media's size to place the
        // curation group on the picture rather than in the pane's letterbox
        // (DES-066), and the content needs the same decision to render.
        let display = PanePresentation.display(
            paneID: focusedAssetID,
            preview: panePreview,
            videoState: loupeVideoState
        )
        return MediaChoiceHoverRegion(
            currentChoice: focusedMediaChoice,
            mediaPixelSize: display.mediaPixelSize,
            onChoice: onPreviewMediaChoice
        ) {
            ZStack {
                // The pane is content, not chrome (DES-022): one backdrop in every
                // state, so the thumbnail-to-full-decode swap changes only the image.
                DesignPalette.content(for: colorScheme)
                switch display {
                case let .video(state):
                    // Sized to the picture: AVKit paints its letterbox black, so the
                    // pane leaves it none and the backdrop stays `content` (DES-022).
                    if let displaySize = state.displaySize {
                        LoupeVideoPlayerView(state: state, trimCommand: videoTrimCommand, onTrimmed: onVideoTrimmed)
                            .aspectRatio(displaySize, contentMode: .fit)
                    } else {
                        LoupeVideoPlayerView(state: state, trimCommand: videoTrimCommand, onTrimmed: onVideoTrimmed)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case let .full(image):
                    if let focusedAssetID {
                        LoupeZoomView(
                            assetID: focusedAssetID,
                            image: image,
                            nativeLongEdge: panePreview?.nativePixelSize.map { max($0.width, $0.height) },
                            command: loupeZoomCommand,
                            onReport: onZoomReport,
                            onDoubleClick: onZoomDoubleClick,
                            isPicking: isPickingNeutral,
                            onPick: onPickNeutral
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityElement()
                        .accessibilityLabel(paneAccessibilityLabel)
                        .accessibilityValue(showsOriginal ? "Original, without edits" : "")
                        .accessibilityAddTraits(.isImage)
                    }
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
            // Top center, clear of the curation group's top-leading zone (DES-066).
            .overlay(alignment: .top) {
                if showsOriginal {
                    Text("Original")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .padding(12)
                        .allowsHitTesting(false)
                        // The picture's own value says it (above).
                        .accessibilityHidden(true)
                }
            }
            // Top trailing: clear of the curation group (top leading, DES-066) and the
            // Original mark (top center, DES-098).
            .overlay(alignment: .topTrailing) {
                if canPlayLivePhoto {
                    Button(action: onPlayLivePhoto) {
                        Label("Live", systemImage: "livephoto")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .help("Play Live Photo")
                    .accessibilityLabel("Play Live Photo")
                }
            }
            .overlay { ContextMenuHost(makeMenu: contextMenu) }
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
            contextMenu: contextMenu,
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

/// What the loupe needs to show the crop tool: the uncropped frame, the crop, the shape
/// it keeps while resized (width over height in fractions of the frame, or nil), and the
/// intent its moves report to.
struct CropEditorInput {
    let image: CGImage
    let crop: EditCrop
    let fractionRatio: Double?
    let setCrop: @MainActor (EditCrop, Bool) -> Void
    /// The straighten line is armed by the panel's ruler.
    let isDrawingLine: Bool
    /// A line drawn on the canvas, from and to, in its y-down space.
    let straighten: @MainActor (CGPoint, CGPoint) -> Void
}
