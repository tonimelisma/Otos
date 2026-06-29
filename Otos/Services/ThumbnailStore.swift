import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Thumbnail file store guide
///
/// Thumbnails are durable overlay kept as files on disk under Application Support,
/// never as bytes in the catalog or in memory beyond the on-screen tiles. The catalog
/// row stores only the thumbnail's relative path; this type owns the directory layout,
/// the filename, and the read/write/delete mechanics.
///
/// The filename is a deterministic hash of the asset's filesystem identity, so
/// re-enrichment overwrites in place (no orphans) and the path can be recomputed without
/// a lookup. It is an opaque storage key, not asset identity — identity stays the
/// `(library_root_id, relative_path)` pair (ADR 0008), and the hash is allowed for the
/// same reason a SQLite row id is: it is a private storage detail.
///
/// `write` is atomic (temp file then replace) so a tile can never read a half-written
/// file while a re-enrichment overwrites it. `load` decodes off the main actor and
/// returns an immutable `CGImage`; the caller only assigns that already-decoded bitmap
/// on the main actor. `delete` is the purge side: reconciliation or library removal
/// removes the file when the asset row is purged.
nonisolated enum ThumbnailStore {
    /// 256 px long edge keeps a true grid thumbnail (max zoom loads originals, separately).
    static let maxPixelSize = 256

    /// The deterministic relative filename for an asset's thumbnail.
    static func relativeName(for id: MediaAssetID) -> String {
        let identity = id.libraryRootPath.rawValue + "\u{0}" + id.relativePath.rawValue
        let digest = SHA256.hash(data: Data(identity.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex + ".heic"
    }

    static func url(for relativeName: String, in directory: URL) -> URL {
        directory.appending(path: relativeName, directoryHint: .notDirectory)
    }

    /// Writes `image` as HEIC at `relativeName` under `directory`, atomically. Returns the
    /// relative name for storage in `thumbnail_path`.
    @discardableResult
    static func write(_ image: CGImage, named relativeName: String, in directory: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destinationURL = url(for: relativeName, in: directory)
        let tempURL = directory.appending(
            path: "." + relativeName + "." + UUID().uuidString + ".tmp",
            directoryHint: .notDirectory
        )

        guard let destination = CGImageDestinationCreateWithURL(
            tempURL as CFURL,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            throw ThumbnailStoreError.encoderUnavailable
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ThumbnailStoreError.writeFailed
        }

        // Atomic publish so a concurrent reader sees either the old or the new file,
        // never a partial one: replace an existing thumbnail in place, or move the temp
        // into place on the first write (where there is nothing to replace).
        if FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        }
        return relativeName
    }

    /// Loads and decodes a thumbnail off the main actor. `nil` if the file is missing or
    /// unreadable (the tile then shows its placeholder).
    static func load(_ relativeName: String, in directory: URL) -> CGImage? {
        let options = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url(for: relativeName, in: directory) as CFURL, options) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    /// Deletes a thumbnail file. No-op if it is already absent.
    static func delete(_ relativeName: String, in directory: URL) {
        try? FileManager.default.removeItem(at: url(for: relativeName, in: directory))
    }
}

nonisolated enum ThumbnailStoreError: Error {
    case encoderUnavailable
    case writeFailed
}
