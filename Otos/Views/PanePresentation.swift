import CoreGraphics
import SwiftUI

/// Pure pane-content decision so the identity rule is unit-testable without views.
nonisolated enum PanePresentation {
    enum Display: Equatable {
        case full(CGImage)
        case thumbnail(MediaAssetID)
        case empty

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case let (.full(l), .full(r)):
                l === r
            case let (.thumbnail(l), .thumbnail(r)):
                l == r
            case (.empty, .empty):
                true
            default:
                false
            }
        }
    }

    static func display(paneID: MediaAssetID?, preview: PanePreview?) -> Display {
        guard let paneID else {
            return .empty
        }
        if let preview, preview.id == paneID {
            return .full(preview.image)
        }
        return .thumbnail(paneID)
    }
}

/// Shared enrichment-thumbnail fallback for loupe and compare panes.
struct PaneThumbnailView: View {
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
