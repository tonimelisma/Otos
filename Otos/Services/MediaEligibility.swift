import Foundation
import UniformTypeIdentifiers

/// Shared scan and UI policy for which filesystem items are Otos catalog media.
///
/// Scan-time membership uses only `NSURLContentTypeKey` (no byte reads). A file
/// catalogs when its UTType classifies as an image, raw still image, or movie.
/// Nil or non-conforming types are excluded. Decodability and enrichment
/// unsupported outcomes are separate.
nonisolated enum MediaEligibility {
    static func isCatalogMedia(contentType: UTType?) -> Bool {
        MediaKind.classify(contentType) != nil
    }

    static func isCatalogMedia(contentTypeIdentifier: String?) -> Bool {
        guard let contentTypeIdentifier else { return false }
        return isCatalogMedia(contentType: UTType(contentTypeIdentifier))
    }

    static func isVideo(contentTypeIdentifier: String?) -> Bool {
        guard let contentTypeIdentifier,
              let contentType = UTType(contentTypeIdentifier)
        else {
            return false
        }
        return MediaKind.classify(contentType) == .video
    }
}
