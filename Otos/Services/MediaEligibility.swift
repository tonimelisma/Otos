import Foundation
import UniformTypeIdentifiers

/// Shared scan and UI policy for which filesystem items are Otos catalog media.
///
/// Scan-time membership uses only `NSURLContentTypeKey` (no byte reads). A file
/// catalogs when its UTType classifies as an image, raw still image, or movie.
/// Nil or non-conforming types are excluded. Decodability and enrichment
/// unsupported outcomes are separate.
nonisolated enum MediaEligibility {
    private static let ignoredDirectoryNames: Set<String> = [
        ".spotlight-v100",
        ".trashes",
        "avf_info",
    ]

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

    static func shouldSkipDirectory(name: String?) -> Bool {
        guard let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalizedName.isEmpty
        else {
            return false
        }
        return ignoredDirectoryNames.contains(normalizedName)
    }

    static func shouldSkipRelativePath(_ relativePath: MediaRelativePath) -> Bool {
        let components = relativePath.rawValue
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.lowercased() }
        guard !components.isEmpty else {
            return false
        }
        if components.last?.hasPrefix("._") == true {
            return true
        }
        if components.contains(where: { ignoredDirectoryNames.contains(String($0)) }) {
            return true
        }
        return zip(components, components.dropFirst()).contains { parent, child in
            parent == "m4root" && child == "sub"
        }
    }
}
