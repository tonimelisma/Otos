import CoreGraphics
import Foundation
import OSLog

/// Thumbnail load guide
///
/// One item's enrichment thumbnail for a SwiftUI surface outside the grid — a Places stack
/// (DES-103), an On This Day card (`docs/design/on-this-day.md`). It reads the shared
/// `TileContentStore` first, so a thumbnail the grid already painted shows at once, and
/// otherwise reads the item's detail and decodes through the grid's own loader off the main
/// actor (ENR-010), then warms the store. A failure or a missing thumbnail answers nil and
/// the caller keeps whatever it shows; it never blanks a picture already painted.
enum ThumbnailLoad {
    /// `operation` names the surface in the log line a failed read writes.
    static func image(
        for id: MediaAssetID,
        tileContentStore: TileContentStore?,
        thumbnailDirectory: URL?,
        detailReader: MediaTileDetailReader?,
        operation: String
    ) async -> CGImage? {
        if let cached = tileContentStore?.image(for: id) {
            return cached
        }
        guard let detailReader else {
            return nil
        }
        let detail: MediaTileDetail?
        do {
            detail = try await detailReader.detail(for: id)
        } catch {
            OtosLog.ui.errorOperation(operation, phase: "detailFailed", fields: [
                "path": id.relativePath.rawValue,
                "error": String(describing: error),
            ])
            return nil
        }
        guard let detail, detail.thumbnailPath != nil, !Task.isCancelled else {
            return nil
        }
        guard let decoded = await ThumbnailDecode.decode(detail: detail, thumbnailDirectory: thumbnailDirectory),
              !Task.isCancelled
        else {
            return nil
        }
        tileContentStore?.warm(id: id, image: decoded, detail: detail)
        return decoded
    }
}

/// Decodes away from the main actor, through the grid's own loader so the surfaces cannot
/// disagree about where a thumbnail is.
private nonisolated enum ThumbnailDecode {
    @concurrent
    static func decode(detail: MediaTileDetail, thumbnailDirectory: URL?) async -> CGImage? {
        MediaAssetTilePresentation.decodedThumbnailImage(detail: detail, thumbnailDirectory: thumbnailDirectory)
    }
}
