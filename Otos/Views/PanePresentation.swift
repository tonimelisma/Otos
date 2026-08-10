import CoreGraphics
import SwiftUI

/// Pure pane-content decision so the identity rule is unit-testable without views.
nonisolated enum PanePresentation {
    enum Display: Equatable {
        case full(CGImage)
        case thumbnail(MediaAssetID)
        case video(LoupeVideoState)
        case empty

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case let (.full(l), .full(r)):
                l === r
            case let (.thumbnail(l), .thumbnail(r)):
                l == r
            case let (.video(l), .video(r)):
                l.id == r.id
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
    /// (plan 0073 D1). `nil` kind renders no affordance (MED-002).
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
            // Miss: decode off-main, exactly as MediaGridBridge.swift:938 does.
            // The previous shape called the synchronous `loadImage` directly inside
            // this MainActor `.task`, decoding a full JPEG on the main thread on every
            // loupe entry and every arrow key (plan 0073 D3).
            guard let detailReader, let thumbnailDirectory else { return }
            let details = await detailReader.details(for: [id])
            guard let detail = details[id] else { return }
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
