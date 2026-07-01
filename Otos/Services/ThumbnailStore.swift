import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// Thumbnail file store guide
///
/// Thumbnails are durable overlay kept as files on disk under Application Support,
/// never as bytes in the catalog or in memory beyond the on-screen tiles. The catalog
/// row stores only the thumbnail's relative path; this type owns the directory layout,
/// the filename, the JPEG format, and the read/write/delete mechanics.
///
/// The filename is a deterministic hash of the asset's filesystem identity, so
/// re-enrichment overwrites in place (no orphans) and the path can be recomputed without
/// a lookup. It is an opaque storage key, not asset identity — identity stays the
/// `(library_root_id, relative_path)` pair (ADR 0008), and the hash is allowed for the
/// same reason a SQLite row id is: it is a private storage detail.
///
/// `stage` normalizes QuickLook output to an opaque 8-bit sRGB JPEG without making
/// it visible to the grid. `CatalogStore` promotes that staged file only after the
/// matching SQLite row validates, so stale enrichment work cannot overwrite the last
/// good thumbnail. `load` decodes off the main actor and returns an immutable
/// `CGImage`; the caller only assigns that already-decoded bitmap on the main actor.
/// `delete`/`deleteAll` are the purge side for proven deletion, library removal, and
/// clean pre-user schema reset.
nonisolated enum ThumbnailStore {
    /// 256 px long edge keeps a true grid thumbnail (max zoom loads originals, separately).
    static let maxPixelSize = 256

    /// The deterministic relative filename for an asset's thumbnail.
    static func relativeName(for id: MediaAssetID) -> String {
        let identity = id.libraryRootPath.rawValue + "\u{0}" + id.relativePath.rawValue
        let digest = SHA256.hash(data: Data(identity.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex + ".jpg"
    }

    static func url(for relativeName: String, in directory: URL) -> URL {
        directory.appending(path: relativeName, directoryHint: .notDirectory)
    }

    /// Writes `image` as a staged JPEG under `directory` and returns the staged/final names.
    /// The final deterministic name is not touched until `promote`, so a stale completion
    /// cannot replace the catalog-visible thumbnail before Store validates it.
    static func stage(
        _ image: CGImage,
        finalRelativeName: String,
        in directory: URL
    ) throws -> GeneratedThumbnail {
        let writeStart = Date()
        let signpost = OtosSignpost.thumbnails.beginInterval("ThumbnailWrite")
        defer {
            OtosSignpost.thumbnails.endInterval("ThumbnailWrite", signpost)
        }

        let jpegImage = try normalizedJPEGImage(from: image)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stagedRelativeName = "." + finalRelativeName + "." + UUID().uuidString + ".tmp"
        let stagedURL = url(for: stagedRelativeName, in: directory)

        guard let destination = CGImageDestinationCreateWithURL(
            stagedURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ThumbnailStoreError.encoderUnavailable
        }
        let properties = [
            kCGImageDestinationLossyCompressionQuality: 0.85,
        ] as CFDictionary
        CGImageDestinationAddImage(destination, jpegImage, properties)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: stagedURL)
            throw ThumbnailStoreError.writeFailed
        }

        let writeMs = DiagnosticsTiming.milliseconds(since: writeStart)
        OtosLog.thumbnails.info(
            """
            Thumbnail stage finished name=\(finalRelativeName, privacy: .public) \
            format=jpeg width=\(jpegImage.width, privacy: .public) \
            height=\(jpegImage.height, privacy: .public) \
            writeMs=\(writeMs, privacy: .public)
            """
        )
        return GeneratedThumbnail(
            finalRelativePath: finalRelativeName,
            stagedRelativePath: stagedRelativeName
        )
    }

    /// Atomically promotes a staged thumbnail to its deterministic final name.
    @discardableResult
    static func promote(_ thumbnail: GeneratedThumbnail, in directory: URL) throws -> String {
        let finalURL = url(for: thumbnail.finalRelativePath, in: directory)
        let stagedURL = url(for: thumbnail.stagedRelativePath, in: directory)
        if FileManager.default.fileExists(atPath: finalURL.path(percentEncoded: false)) {
            _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: stagedURL)
        } else {
            try FileManager.default.moveItem(at: stagedURL, to: finalURL)
        }
        OtosLog.thumbnails.info(
            "Thumbnail promote finished name=\(thumbnail.finalRelativePath, privacy: .public)"
        )
        return thumbnail.finalRelativePath
    }

    /// Removes a staged thumbnail that was never accepted by the catalog.
    static func discard(_ thumbnail: GeneratedThumbnail, in directory: URL) {
        try? FileManager.default.removeItem(at: url(for: thumbnail.stagedRelativePath, in: directory))
    }

    /// Loads and decodes a thumbnail off the main actor. `nil` if the file is missing or
    /// unreadable (the tile then shows its placeholder).
    static func load(_ relativeName: String, in directory: URL) -> CGImage? {
        let signpost = OtosSignpost.thumbnails.beginInterval("ThumbnailLoad")
        defer {
            OtosSignpost.thumbnails.endInterval("ThumbnailLoad", signpost)
        }
        let options = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url(for: relativeName, in: directory) as CFURL, options) else {
            OtosLog.thumbnails.debug(
                "Thumbnail load source unavailable name=\(relativeName, privacy: .public)"
            )
            return nil
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options) else {
            OtosLog.thumbnails.debug(
                "Thumbnail load decode failed name=\(relativeName, privacy: .public)"
            )
            return nil
        }
        return image
    }

    /// Deletes a thumbnail file. No-op if it is already absent.
    static func delete(_ relativeName: String, in directory: URL) {
        try? FileManager.default.removeItem(at: url(for: relativeName, in: directory))
    }

    /// Deletes every app-owned thumbnail file under `directory`. Originals never live
    /// here; this is used only when the app-owned catalog state that referenced these
    /// rebuildable products has been reset.
    static func deleteAll(in directory: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func normalizedJPEGImage(from image: CGImage) throws -> CGImage {
        guard image.width > 0, image.height > 0 else {
            throw ThumbnailStoreError.normalizationFailed
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ThumbnailStoreError.normalizationFailed
        }

        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ThumbnailStoreError.normalizationFailed
        }

        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        guard let normalized = context.makeImage() else {
            throw ThumbnailStoreError.normalizationFailed
        }
        return normalized
    }
}

nonisolated enum ThumbnailStoreError: Error {
    case encoderUnavailable
    case normalizationFailed
    case writeFailed
}
