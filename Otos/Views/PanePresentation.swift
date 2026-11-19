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

    /// What sits at the center of the pane, over its picture (DES-086): the one wait
    /// indicator while its photo's bytes or its video's player are coming, the reason a
    /// video cannot play once asking found no player, or nothing. Never two at once: a
    /// wait outranks an older failure, since the asking is still going on.
    nonisolated enum Overlay: Equatable, Sendable {
        case none
        case waiting
        case unavailable(LoupeVideoUnavailable)
    }

    /// `video` is the loupe video's asset and phase, lifted out of the `@MainActor`
    /// `LoupeVideo` so this decision stays pure; a phase for another asset than the
    /// pane's is stale and draws nothing.
    nonisolated static func overlay(
        paneID: MediaAssetID?,
        isDownloading: Bool,
        video: (id: MediaAssetID, phase: LoupeVideoPhase)?
    ) -> Overlay {
        let phase = video.flatMap { $0.id == paneID ? $0.phase : nil }
        if isDownloading || phase == .preparing {
            return .waiting
        }
        if case let .unavailable(reason) = phase {
            return .unavailable(reason)
        }
        return .none
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
