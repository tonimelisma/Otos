import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// Derived image file store guide
///
/// The derived images of an asset are durable overlay kept as files on disk under
/// Application Support, never as bytes in the catalog: the 256 px grid thumbnail (8-bit
/// sRGB JPEG), for stills the 2560 px loupe preview (8-bit Display P3 HEIC, ADR 0035), and
/// for a video with faces its face frames (the sampled frames its faces were kept from, as
/// the images of one HEIC of the preview's size, ADR 0047). All live in one directory and
/// share every file mechanic here — staging,
/// promotion, move, delete, startup cleanup — because those work on names; only the
/// encoding and the name's extension differ. The catalog row stores each relative path;
/// this type owns the directory layout, the filenames, the formats, and the
/// read/write/delete mechanics.
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
/// good thumbnail. `load` decodes synchronously on its caller's thread (callers run it off the main actor) and
/// returns an immutable `CGImage` a layer shows without a copy (`DisplayImage`); the caller
/// only assigns it on the main actor.
/// `delete`/`deleteAll` are the purge side for proven deletion and library removal.
/// Staged files live in their own `.staging` subdirectory, on the same volume so promotion
/// is an atomic rename; `clearStaging` is startup hygiene for staged files abandoned by a
/// prior process, and lists only that subdirectory — never the thousands of finished
/// images beside it, and never media library roots. Catalog schema changes never purge thumbnails via a destructive
/// database reset — future/unrecognized schemas refuse to open instead.
nonisolated enum ThumbnailStore {
    /// 256 px long edge keeps a true grid thumbnail (max zoom loads originals, separately).
    static let maxPixelSize = 256

    /// The loupe preview's long edge (ADR 0035): the loupe's fit size on the screens
    /// measured, at about 0.4 MB per photo as HEIC.
    static let previewMaxPixelSize = 2560

    /// The deterministic relative filename for an asset's thumbnail.
    static func relativeName(for id: MediaAssetID) -> String {
        storageKey(for: id) + ".jpg"
    }

    /// The deterministic relative filename for an asset's loupe preview.
    static func previewRelativeName(for id: MediaAssetID) -> String {
        storageKey(for: id) + ".heic"
    }

    /// The deterministic relative filename for a video's face frames.
    static func faceFramesRelativeName(for id: MediaAssetID) -> String {
        storageKey(for: id) + ".faces.heic"
    }

    private static func storageKey(for id: MediaAssetID) -> String {
        storageDigest(for: id).map { String(format: "%02x", $0) }.joined()
    }

    /// The hash every derived name of `id` begins with, in hexadecimal.
    static func storageDigest(for id: MediaAssetID) -> SHA256.Digest {
        let identity = id.libraryRootPath.rawValue + "\u{0}" + id.relativePath.rawValue
        return SHA256.hash(data: Data(identity.utf8))
    }

    static func url(for relativeName: String, in directory: URL) -> URL {
        directory.appending(path: relativeName, directoryHint: .notDirectory)
    }

    /// Where images are written before promotion: a subdirectory of `directory`.
    static let stagingDirectoryName = ".staging"

    /// A fresh staged name for `finalRelativeName`, relative to `directory`, with the staging
    /// subdirectory created.
    private static func newStagedRelativeName(for finalRelativeName: String, in directory: URL) throws -> String {
        let staging = directory.appending(path: stagingDirectoryName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return stagingDirectoryName + "/" + finalRelativeName + "." + UUID().uuidString + ".tmp"
    }

    static func move(_ relativeName: String, to newRelativeName: String, in directory: URL) throws {
        guard relativeName != newRelativeName else {
            return
        }
        let sourceURL = url(for: relativeName, in: directory)
        let destinationURL = url(for: newRelativeName, in: directory)
        guard FileManager.default.fileExists(atPath: sourceURL.path(percentEncoded: false)) else {
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: sourceURL)
        } else {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        }
    }

    /// Writes `image` as a staged JPEG under `directory` and returns the staged/final names.
    /// The final deterministic name is not touched until `promote`, so a stale completion
    /// cannot replace the catalog-visible thumbnail before Store validates it.
    static func stage(
        _ image: CGImage,
        finalRelativeName: String,
        in directory: URL
    ) throws -> StagedDerivedImage {
        try stageEncoded([image], as: .jpeg, colorSpaceName: CGColorSpace.sRGB, finalRelativeName: finalRelativeName, in: directory)
    }

    /// Writes `image` as a staged 8-bit Display P3 HEIC preview. Eight bits on purpose:
    /// a deeper or HDR image encoded straight to HEIC misrenders (ADR 0009's rejected
    /// HEIC thumbnails), so the preview is normalized exactly as the thumbnail is.
    static func stagePreview(
        _ image: CGImage,
        finalRelativeName: String,
        in directory: URL
    ) throws -> StagedDerivedImage {
        try stageEncoded([image], as: .heic, colorSpaceName: CGColorSpace.displayP3, finalRelativeName: finalRelativeName, in: directory)
    }

    /// Writes `frames` as the images of one staged 8-bit Display P3 HEIC, in order, each
    /// scaled to the preview's long edge: a video's face frames (ADR 0047).
    static func stageFaceFrames(
        _ frames: [CGImage],
        finalRelativeName: String,
        in directory: URL
    ) throws -> StagedDerivedImage {
        try stageEncoded(
            frames.map { try scaled($0, toLongEdge: previewMaxPixelSize) },
            as: .heic, colorSpaceName: CGColorSpace.displayP3, finalRelativeName: finalRelativeName, in: directory
        )
    }

    /// `image` scaled so its long edge is at most `longEdge`, for the thumbnail drawn
    /// from a rendered preview.
    static func scaled(_ image: CGImage, toLongEdge longEdge: Int) throws -> CGImage {
        let scale = min(1, Double(longEdge) / Double(max(image.width, image.height)))
        guard scale < 1 else {
            return image
        }
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        return try normalizedImage(from: image, colorSpaceName: CGColorSpace.displayP3, width: width, height: height)
    }

    private static func stageEncoded(
        _ images: [CGImage],
        as type: UTType,
        colorSpaceName: CFString,
        finalRelativeName: String,
        in directory: URL
    ) throws -> StagedDerivedImage {
        let writeStart = ContinuousClock.now
        let signpost = OtosSignpost.thumbnails.beginInterval("ThumbnailWrite")
        defer {
            OtosSignpost.thumbnails.endInterval("ThumbnailWrite", signpost)
        }

        let normalized = try images.map { image in
            try normalizedImage(from: image, colorSpaceName: colorSpaceName, width: image.width, height: image.height)
        }
        let stagedRelativeName = try newStagedRelativeName(for: finalRelativeName, in: directory)
        let stagedURL = url(for: stagedRelativeName, in: directory)

        guard let destination = CGImageDestinationCreateWithURL(
            stagedURL as CFURL,
            type.identifier as CFString,
            normalized.count,
            nil
        ) else {
            throw ThumbnailStoreError.encoderUnavailable
        }
        let properties = [
            kCGImageDestinationLossyCompressionQuality: 0.85,
        ] as CFDictionary
        for image in normalized {
            CGImageDestinationAddImage(destination, image, properties)
        }
        guard CGImageDestinationFinalize(destination) else {
            do {
                try FileManager.default.removeItem(at: stagedURL)
            } catch where ErrorDiagnostics.isMissingFile(error) {
                // Already gone: the outcome this removal wanted.
            } catch {
                OtosLog.thumbnails.errorOperation("thumbnail.cleanup", phase: "removeFailed", fields: [
                    "path": stagedURL.path(percentEncoded: false),
                    "error": String(describing: error),
                ])
            }
            throw ThumbnailStoreError.writeFailed
        }

        let writeMs = DiagnosticsTiming.milliseconds(since: writeStart)
        OtosLog.thumbnails.info(
            """
            Thumbnail stage finished name=\(finalRelativeName, privacy: .public) \
            format=\(type.preferredFilenameExtension ?? type.identifier, privacy: .public) \
            images=\(normalized.count, privacy: .public) \
            width=\(normalized.first?.width ?? 0, privacy: .public) \
            height=\(normalized.first?.height ?? 0, privacy: .public) \
            writeMs=\(writeMs, privacy: .public)
            """
        )
        return StagedDerivedImage(
            finalRelativePath: finalRelativeName,
            stagedRelativePath: stagedRelativeName
        )
    }

    /// Stages an existing app-owned JPEG under the destination identity's
    /// deterministic name. This reads only Application Support overlay, never the
    /// user's source media, and uses the same atomic promotion path as generation.
    static func stageCopy(
        sourceRelativeName: String,
        destinationRelativeName finalRelativeName: String,
        in directory: URL
    ) throws -> StagedDerivedImage {
        guard !sourceRelativeName.contains("/"),
              !sourceRelativeName.isEmpty,
              sourceRelativeName != ".",
              sourceRelativeName != ".."
        else {
            throw ThumbnailStoreError.writeFailed
        }
        let sourceURL = url(for: sourceRelativeName, in: directory)
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
            throw ThumbnailStoreError.writeFailed
        }
        let stagedRelativeName = try newStagedRelativeName(for: finalRelativeName, in: directory)
        let stagedURL = url(for: stagedRelativeName, in: directory)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: stagedURL)
        } catch {
            do {
                try FileManager.default.removeItem(at: stagedURL)
            } catch where ErrorDiagnostics.isMissingFile(error) {
                // Already gone: the outcome this removal wanted.
            } catch {
                OtosLog.thumbnails.errorOperation("thumbnail.cleanup", phase: "removeFailed", fields: [
                    "path": stagedURL.path(percentEncoded: false),
                    "error": String(describing: error),
                ])
            }
            throw ThumbnailStoreError.writeFailed
        }
        return StagedDerivedImage(
            finalRelativePath: finalRelativeName,
            stagedRelativePath: stagedRelativeName
        )
    }

    /// Atomically promotes a staged thumbnail to its deterministic final name.
    @discardableResult
    static func promote(_ thumbnail: StagedDerivedImage, in directory: URL) throws -> String {
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

    /// Stages a camera-provided thumbnail for the same deterministic name real enrichment
    /// will later replace. `CatalogStore.applyProvisionalThumbnails` promotes it in the write
    /// that names it, only for a row with no thumbnail; it stamps no enrichment, and only
    /// gives the grid something truthful to show while staged bytes are still arriving.
    static func stageProvisionalJPEG(
        _ data: Data,
        finalRelativeName: String,
        in directory: URL
    ) throws -> StagedDerivedImage {
        let stagedName = try newStagedRelativeName(for: finalRelativeName, in: directory)
        try data.write(to: url(for: stagedName, in: directory), options: [.atomic])
        return StagedDerivedImage(finalRelativePath: finalRelativeName, stagedRelativePath: stagedName)
    }

    /// Removes a staged thumbnail that was never accepted by the catalog.
    static func discard(_ thumbnail: StagedDerivedImage, in directory: URL) {
        do {
            try FileManager.default.removeItem(at: url(for: thumbnail.stagedRelativePath, in: directory))
        } catch where ErrorDiagnostics.isMissingFile(error) {
            // Already gone: the outcome this removal wanted.
        } catch {
            OtosLog.thumbnails.errorOperation("thumbnail.cleanup", phase: "removeFailed", fields: [
                "path": url(for: thumbnail.stagedRelativePath, in: directory).path(percentEncoded: false),
                "error": String(describing: error),
            ])
        }
    }

    /// Decodes a stored image for display (`DisplayImage.decode`) at its stored size,
    /// synchronously on the calling thread; callers run it off the main actor. `nil` if the
    /// file is missing or unreadable (the tile then shows its placeholder). A stored thumbnail
    /// is never larger than a grid tile shows it, so it is decoded whole, as Image I/O returns
    /// it, and never drawn again: that is the one form a layer shows without a copy, and it
    /// costs less than any smaller decode of the same file would
    /// (`docs/research/2026-11-16-tile-images-shown-once.md`).
    static func load(_ relativeName: String, in directory: URL) -> CGImage? {
        let signpost = OtosSignpost.thumbnails.beginInterval("ThumbnailLoad")
        defer {
            OtosSignpost.thumbnails.endInterval("ThumbnailLoad", signpost)
        }
        guard let image = DisplayImage.decode(url(for: relativeName, in: directory), maxPixelEdge: .max) else {
            OtosLog.thumbnails.debug(
                "Thumbnail load failed name=\(relativeName, privacy: .public)"
            )
            return nil
        }
        return image
    }

    /// Deletes a thumbnail file. No-op if it is already absent.
    static func delete(_ relativeName: String, in directory: URL) {
        do {
            try FileManager.default.removeItem(at: url(for: relativeName, in: directory))
        } catch where ErrorDiagnostics.isMissingFile(error) {
            // Already gone: the outcome this removal wanted.
        } catch {
            OtosLog.thumbnails.errorOperation("thumbnail.cleanup", phase: "removeFailed", fields: [
                "path": url(for: relativeName, in: directory).path(percentEncoded: false),
                "error": String(describing: error),
            ])
        }
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
            do {
                try FileManager.default.removeItem(at: url)
            } catch where ErrorDiagnostics.isMissingFile(error) {
                // Already gone: the outcome this removal wanted.
            } catch {
                OtosLog.thumbnails.errorOperation("thumbnail.cleanup", phase: "removeFailed", fields: [
                    "path": url.path(percentEncoded: false),
                    "error": String(describing: error),
                ])
            }
        }
    }

    /// Deletes what a prior process left staged and never promoted: everything in the
    /// staging subdirectory. Finished images beside it are never listed. Runs before this
    /// process stages anything, so nothing it deletes is in use.
    @discardableResult
    static func clearStaging(in directory: URL) -> Int {
        let staging = directory.appending(path: stagingDirectoryName, directoryHint: .isDirectory)
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        } catch where ErrorDiagnostics.isMissingFile(error) {
            return 0
        } catch {
            OtosLog.thumbnails.errorOperation("thumbnail.staging", phase: "listFailed", fields: [
                "error": String(describing: error),
            ])
            return 0
        }
        var removedCount = 0
        for url in contents {
            do {
                try FileManager.default.removeItem(at: url)
                removedCount += 1
            } catch where ErrorDiagnostics.isMissingFile(error) {
                // Already gone: the outcome this removal wanted.
            } catch {
                OtosLog.thumbnails.errorOperation("thumbnail.staging", phase: "removeFailed", fields: [
                    "name": url.lastPathComponent,
                    "error": String(describing: error),
                ])
            }
        }
        return removedCount
    }

    /// Draws `image` into an opaque 8-bit context of `colorSpaceName` at `width`×`height`.
    private static func normalizedImage(
        from image: CGImage,
        colorSpaceName: CFString,
        width: Int,
        height: Int
    ) throws -> CGImage {
        guard image.width > 0, image.height > 0, width > 0, height > 0 else {
            throw ThumbnailStoreError.normalizationFailed
        }
        guard let colorSpace = CGColorSpace(name: colorSpaceName) else {
            throw ThumbnailStoreError.normalizationFailed
        }

        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ThumbnailStoreError.normalizationFailed
        }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
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
