import CoreGraphics
import SwiftUI

/// Pure pane-content decision so the identity rule is unit-testable without views.
nonisolated enum PanePresentation {
    enum Display: Equatable {
        case full(CGImage)
        case thumbnail(MediaAssetID)
        case video(LoupeVideoState)
        case empty

        /// The media's pixel size when this display carries one, for placing the
        /// curation group on the image rather than in the pane's letterbox
        /// (DES-066). A video answers its measured display size; `.thumbnail`
        /// and a video whose size is unknown answer nil, and the group falls back
        /// to the pane's own corner rather than guessing a frame the media may not
        /// occupy.
        var mediaPixelSize: CGSize? {
            switch self {
            case let .full(image): CGSize(width: image.width, height: image.height)
            case let .video(state): state.displaySize
            case .thumbnail, .empty: nil
            }
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case let (.full(left), .full(right)):
                left === right
            case let (.thumbnail(left), .thumbnail(right)):
                left == right
            case let (.video(left), .video(right)):
                left.id == right.id
            case (.empty, .empty):
                true
            default:
                false
            }
        }
    }

    static func display(paneID: MediaAssetID?, preview: PanePreview?, videoState: LoupeVideoState? = nil) -> Display {
        guard let paneID else {
            return .empty
        }
        if let videoState, videoState.id == paneID {
            return .video(videoState)
        }
        if let preview, preview.id == paneID {
            return .full(preview.image)
        }
        return .thumbnail(paneID)
    }

    /// Pure play-affordance decision — extracted for testability so a view-private
    /// method does not hide the logic that once drew a play button on still photos
    /// `nil` kind renders no affordance (MED-002).
    /// `hasActiveVideo` is `loupeVideoState != nil` lifted to a Sendable Bool so this
    /// pure function can remain `nonisolated` despite `LoupeVideoState` being
    /// `@MainActor` (AVPlayer).
    nonisolated static func shouldShowPlayAffordance(
        kind: MediaKind?,
        hasActiveVideo: Bool,
        paneID: MediaAssetID,
        focusedID: MediaAssetID?
    ) -> Bool {
        guard !hasActiveVideo else { return false }
        guard paneID == focusedID else { return false }
        return kind == .video
    }
}

/// Shared enrichment-thumbnail fallback for loupe and compare panes.
struct PaneThumbnailView: View {
    let id: MediaAssetID
    var tileContentStore: TileContentStore?
    var thumbnailDirectory: URL?
    var detailReader: MediaTileDetailReader?
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .accessibilityElement()
                    .accessibilityLabel("Photo")
                    .accessibilityAddTraits(.isImage)
            } else {
                ProgressView()
            }
        }
        .task(id: id) {
            // Store hit: the filmstrip is already showing this asset, so the decoded
            // image is almost always present. Synchronous assignment, no I/O.
            if let hit = tileContentStore?.image(for: id) {
                image = hit
                return
            }
            // Miss: decode in a `Task.detached`, exactly as MediaGridBridge does.
            // The previous shape called the synchronous `loadImage` directly inside
            // this MainActor `.task`, decoding a full JPEG on the main thread on every
            // loupe entry and every arrow key.
            guard let detailReader, let thumbnailDirectory else { return }
            let detail: MediaTileDetail?
            do {
                detail = try await detailReader.detail(for: id)
            } catch {
                // Nothing is decoded; the spinner stays until this pane asks again.
                return
            }
            guard let detail else { return }
            let directory = thumbnailDirectory
            let decoded = await Task.detached(priority: .userInitiated) {
                MediaAssetTilePresentation.loadImage(detail: detail, thumbnailDirectory: directory)
            }.value
            guard !Task.isCancelled, let decodedImage = decoded.image else { return }
            tileContentStore?.warm(id: id, image: decodedImage, detail: detail)
            image = decodedImage
        }
    }
}
