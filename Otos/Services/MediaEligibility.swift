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

    /// Device-artifact and trash directory names ignored for all roots (inventory
    /// only — never deletions). Matches gomediaimport's ignore set plus existing
    /// Spotlight/trash exclusions.
    private static let ignoredTrashDirectoryPrefixes: [String] = [
        ".trash-",
        "$recycle.bin",
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
        if ignoredDirectoryNames.contains(normalizedName) {
            return true
        }
        return ignoredTrashDirectoryPrefixes.contains { normalizedName.hasPrefix($0) }
            || normalizedName == "$recycle.bin"
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
        if components.contains(where: { name in
            ignoredTrashDirectoryPrefixes.contains { name.hasPrefix($0) } || name == "$recycle.bin"
        }) {
            return true
        }
        // Sony camcorder artifact trees: M4ROOT/SUB (existing), M4ROOT/THMBNL,
        // and M4ROOT/CLIP/*.xml (XML clip metadata — not catalog media).
        if zip(components, components.dropFirst()).contains(where: { parent, child in
            parent == "m4root" && (child == "sub" || child == "thmbnl")
        }) {
            return true
        }
        if components.count >= 3,
           components[components.count - 3] == "m4root",
           components[components.count - 2] == "clip",
           components.last?.hasSuffix(".xml") == true {
            return true
        }
        return false
    }

    /// Recognized useful companions are inventoried separately from catalog media.
    static func isRecognizedCompanion(relativePath: MediaRelativePath) -> Bool {
        let ext = URL(fileURLWithPath: relativePath.rawValue).pathExtension
        return MediaCompanionKind.recognize(fileExtension: ext) != nil
    }
}
