import CoreGraphics
import Foundation

/// Thumbnail load guide
///
/// One item's enrichment thumbnail for every SwiftUI surface outside the grid — a Places
/// stack (DES-103), an On This Day card (`docs/design/on-this-day.md`), a duplicate
/// (DES-107), the loupe, compare and story panes' fallback — so they cannot disagree about
/// where a thumbnail is or what a failure means. It reads the shared `TileContentStore`
/// first, so a thumbnail the grid already painted shows at once, and otherwise reads the
/// item's detail and decodes through the grid's own loader off the main actor (ENR-010),
/// then warms the store.
///
/// The answer is one of three facts. `decoded` is the picture. `unavailable` is a stored
/// thumbnail that does not decode: DES-063's slash glyph, since no later read of the same
/// rendering can change it. `notYet` is everything that leaves the question open — no
/// thumbnail stored yet, no reader or directory, a cancelled load, or a detail read that
/// failed — so the caller keeps whatever it shows and never blanks a picture already
/// painted. A failed read is an error, not a fact (ADR 0032 rule 4): the reader logs it
/// once, by error domain and code (`op=tileDetail.read phase=failed`).
enum ThumbnailLoad {
    case decoded(DisplayImage)
    /// The kind is the detail's, so a surface that knows no kind still draws the right glyph.
    case unavailable(kind: MediaKind?)
    case notYet

    static func load(
        for id: MediaAssetID,
        tileContentStore: TileContentStore?,
        thumbnailDirectory: URL?,
        detailReader: MediaTileDetailReader?
    ) async -> ThumbnailLoad {
        if let cached = tileContentStore?.currentImage(for: id) {
            return .decoded(cached)
        }
        guard let detailReader, let thumbnailDirectory else {
            return .notYet
        }
        let detail: MediaTileDetail?
        do {
            detail = try await detailReader.detail(for: id)
        } catch {
            // Logged by the reader; the question stays open for the surface's next load.
            return .notYet
        }
        guard let detail, !Task.isCancelled else {
            return .notYet
        }
        let loaded = await decoding(detail, thumbnailDirectory: thumbnailDirectory)
        guard !Task.isCancelled else {
            return .notYet
        }
        if case let .decoded(image) = loaded {
            tileContentStore?.warm(id: id, image: image, detail: detail)
        }
        return loaded
    }

    /// The answer one read detail gives: no stored thumbnail is `notYet`, a stored one that
    /// does not decode is `unavailable`.
    static func decoding(_ detail: MediaTileDetail, thumbnailDirectory: URL) async -> ThumbnailLoad {
        guard detail.thumbnailPath != nil else {
            return .notYet
        }
        guard let image = await ThumbnailDecode.decode(detail: detail, thumbnailDirectory: thumbnailDirectory) else {
            return .unavailable(kind: detail.bestKind)
        }
        return .decoded(image)
    }

    /// What a surface shows once `newer` lands: a picture already painted stays until a newer
    /// picture replaces it, and an open answer never replaces a known one.
    func updated(by newer: ThumbnailLoad) -> ThumbnailLoad {
        switch (self, newer) {
        case (_, .decoded): newer
        case (.decoded, _), (_, .notYet): self
        case (_, .unavailable): newer
        }
    }

    var image: DisplayImage? {
        if case let .decoded(image) = self {
            image
        } else {
            nil
        }
    }

    /// DES-063's glyph while there is no picture: the kind glyph, or its slash variant once
    /// the thumbnail is unavailable, for the kind its detail read names.
    func placeholderSystemName(for kind: MediaKind?) -> String {
        if case let .unavailable(read) = self {
            return MediaAssetTilePresentation.placeholderIconSystemName(
                for: read ?? kind, thumbnailUnavailable: true
            )
        }
        return MediaAssetTilePresentation.placeholderIconSystemName(for: kind, thumbnailUnavailable: false)
    }
}

/// Decodes away from the main actor, through the grid's own loader.
private nonisolated enum ThumbnailDecode {
    @concurrent
    static func decode(detail: MediaTileDetail, thumbnailDirectory: URL) async -> DisplayImage? {
        MediaAssetTilePresentation.decodedThumbnailImage(detail: detail, thumbnailDirectory: thumbnailDirectory)
    }
}
