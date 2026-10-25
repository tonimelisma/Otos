import AppKit
import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import OSLog
import Synchronization
import UniformTypeIdentifiers

/// Hand-off guide
///
/// What Otos hands to another app when a photo is copied, dragged, shared or opened with
/// another app (plan 0108 increment 13). It behaves like Finder: one full-size file per
/// photo. Which file depends on the photo (`HandOffForm`):
/// - **An unedited still that is not a RAW, or an untrimmed video:** the original itself.
///   Nothing is read; a cloud-only original is downloaded by the app that reads it, as
///   with Finder.
/// - **An edited still or any RAW:** a full-size JPEG rendered from the original with its
///   recipe (RAW9 defaults for an unedited RAW). It keeps the original's metadata, with
///   the orientation reset because the pixels are already upright.
/// - **A trimmed video:** the trimmed range, copied without re-encoding.
///
/// Prepared files go into one Otos-owned folder in Application Support, at a path
/// determined by the photo and its recipe (`preparedURL`). A photo handed off twice reuses
/// its file, which is also what lets a later drag into Chrome (which never fulfils file
/// promises) find one. The folder is cleared once per launch, before the first hand-off,
/// when no reader of an earlier file can remain. Nothing full-size is kept beyond that.
///
/// An actor so preparations of one photo never overlap. Rendering happens on
/// `ImageRenderer`'s interactive lane, and encoding runs in `@concurrent` functions, so the
/// actor itself does no blocking work.
nonisolated struct HandOffItem: Equatable, Sendable {
    let id: MediaAssetID
    let isVideo: Bool
    /// The photo's saved edit; neutral when it was never edited.
    let recipe: EditRecipe
    let sourceSize: Int64?

    var form: HandOffForm {
        if isVideo {
            return recipe.trimStart != nil || recipe.trimEnd != nil ? .trimmedVideo : .original
        }
        return ImageRenderer.isRAW(id.fileURL) || !recipe.isNeutral ? .renderedStill : .original
    }
}

nonisolated enum HandOffForm: Equatable, Sendable {
    case original
    case renderedStill
    case trimmedVideo
}

actor HandOffPreparer {
    enum PrepareError: Error {
        case originalUnavailable
        case encodeFailed
        case exportFailed
    }

    let directory: URL
    private let materialization: MaterializationCoordinator?
    private var cleared = false

    init(directory: URL, materialization: MaterializationCoordinator?) {
        self.directory = directory
        self.materialization = materialization
    }

    /// The file to hand over for `item`: the original, or one prepared now or earlier in
    /// this launch.
    func prepare(_ item: HandOffItem) async throws -> URL {
        guard item.form != .original else {
            return item.id.fileURL
        }
        try await clearOnce()
        let target = try Self.preparedURL(for: item, in: directory)
        if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
            return target
        }
        let start = ContinuousClock.now
        guard await MaterializationCoordinator.makeLocal(
            item.id, sourceSize: item.sourceSize, isVideo: item.isVideo, via: materialization
        ) else {
            throw PrepareError.originalUnavailable
        }
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Written beside the target and moved into place, so a reader never sees half a file.
        let staging = target.deletingLastPathComponent()
            .appending(path: ".\(UUID().uuidString).\(target.pathExtension)")
        do {
            switch item.form {
            case .renderedStill:
                let rendered = try await ImageRenderer.interactive.render(
                    item.id.fileURL, longEdge: nil, recipe: item.recipe
                )
                try await Self.writeJPEG(rendered.image, metadataOf: item.id.fileURL, to: staging)
            case .trimmedVideo:
                try await Self.exportTrimmed(item.id.fileURL, recipe: item.recipe, to: staging)
            case .original:
                break
            }
            try FileManager.default.moveItem(at: staging, to: target)
        } catch {
            if FileManager.default.fileExists(atPath: staging.path(percentEncoded: false)) {
                do {
                    try FileManager.default.removeItem(at: staging)
                } catch let cleanup {
                    OtosLog.mediaIO.errorOperation("handOff.prepare", phase: "stagingNotRemoved", fields: [
                        "path": staging.path(percentEncoded: false), "error": String(describing: cleanup),
                    ])
                }
            }
            OtosLog.mediaIO.errorOperation("handOff.prepare", phase: "failed", fields: [
                "id": item.id.relativePath.rawValue, "error": String(describing: error),
            ])
            throw error
        }
        OtosLog.mediaIO.noticeOperation("handOff.prepare", phase: "finish", fields: [
            "id": item.id.relativePath.rawValue,
            "form": item.form == .trimmedVideo ? "trimmedVideo" : "renderedStill",
            "elapsedMs": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
        return target
    }

    /// The file already prepared for `item` this launch, or nil. Read without waiting, so a
    /// drag can hand a ready file to a receiver that cannot wait for one.
    nonisolated func readyURL(for item: HandOffItem) -> URL? {
        guard item.form != .original else {
            return item.id.fileURL
        }
        guard let url = try? Self.preparedURL(for: item, in: directory),
              FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        else {
            return nil
        }
        return url
    }

    /// `<directory>/<digest of path and recipe>/<original name>.jpg` (or `.mov`): one file
    /// per photo and recipe, named as the original so the receiver sees a familiar name.
    nonisolated static func preparedURL(for item: HandOffItem, in directory: URL) throws -> URL {
        let key = try item.id.fileURL.path(percentEncoded: false) + "\n" + CatalogStore.editRecipeJSON(item.recipe)
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let stem = item.id.fileURL.deletingPathExtension().lastPathComponent
        let fileExtension = item.form == .trimmedVideo ? "mov" : "jpg"
        return directory
            .appending(path: digest, directoryHint: .isDirectory)
            .appending(path: "\(stem).\(fileExtension)")
    }

    /// Clears the previous launch's files once, before this launch's first preparation.
    private func clearOnce() async throws {
        guard !cleared else { return }
        cleared = true
        try await Self.removeContents(of: directory)
    }

    @concurrent
    private static func removeContents(of directory: URL) async throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path(percentEncoded: false)) else { return }
        for entry in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try manager.removeItem(at: entry)
        }
    }

    /// A full-size JPEG with the original's Exif, GPS, TIFF and IPTC metadata. The pixels
    /// are already upright and may be cropped, so the orientation and pixel-size fields are
    /// reset rather than copied.
    @concurrent
    static func writeJPEG(_ image: CGImage, metadataOf original: URL, to url: URL) async throws {
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
        if let source = CGImageSourceCreateWithURL(original as CFURL, nil),
           let originalProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        {
            for key in [
                kCGImagePropertyExifDictionary,
                kCGImagePropertyGPSDictionary,
                kCGImagePropertyTIFFDictionary,
                kCGImagePropertyIPTCDictionary,
            ] {
                properties[key] = originalProperties[key]
            }
        }
        properties[kCGImagePropertyOrientation] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            properties[kCGImagePropertyExifDictionary] = exif
        }
        let type = UTType.jpeg.identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil)
        else {
            throw PrepareError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PrepareError.encodeFailed
        }
    }

    /// The recipe's trimmed range of a video, copied without re-encoding.
    @concurrent
    static func exportTrimmed(_ original: URL, recipe: EditRecipe, to url: URL) async throws {
        let asset = AVURLAsset(url: original)
        let duration = try await asset.load(.duration)
        let start = recipe.trimStart.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .zero
        let end = recipe.trimEnd.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? duration
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw PrepareError.exportFailed
        }
        session.timeRange = CMTimeRange(start: start, end: end)
        try await session.export(to: url, as: .mov)
    }
}

/// A dragged photo that must be prepared before it can be handed over: a file promise
/// (ADR 0028, plan 0108 increment 13). Finder, Mail, Messages and Safari wait for it. Chrome
/// never fulfils promises, so it receives such a photo only when its file was already
/// prepared earlier this launch, in which case the drag carries that file's URL instead
/// (`CatalogWindowViewModel.dragWriter(for:)`).
///
/// The receiver asks on `queue`, a dedicated serial queue: preparing is async, so the
/// callback waits for it there, never on a cooperative-pool thread. A photo whose details
/// the grid did not hold is read first, then handed over as `HandOffItem.form` says,
/// original included.
final nonisolated class HandOffPromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    private let item: HandOffItem?
    private let id: MediaAssetID
    private let preparer: HandOffPreparer
    private let reader: MediaTileDetailReader?
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "net.melisma.Otos.handOff.promise"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(item: HandOffItem?, id: MediaAssetID? = nil, preparer: HandOffPreparer, reader: MediaTileDetailReader?) {
        self.item = item
        self.id = item?.id ?? id ?? MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/"),
            relativePath: MediaRelativePath(rawValue: "")
        )
        self.preparer = preparer
        self.reader = reader
        super.init()
        fileType = Self.fileType(for: item, id: self.id).identifier
        delegate = self
    }

    private static func fileType(for item: HandOffItem?, id: MediaAssetID) -> UTType {
        switch item?.form {
        case .renderedStill: .jpeg
        case .trimmedVideo: .quickTimeMovie
        default: UTType(filenameExtension: id.fileURL.pathExtension) ?? .data
        }
    }

    func filePromiseProvider(_: NSFilePromiseProvider, fileNameForType _: String) -> String {
        let stem = id.fileURL.deletingPathExtension().lastPathComponent
        return switch item?.form {
        case .renderedStill: "\(stem).jpg"
        case .trimmedVideo: "\(stem).mov"
        default: id.fileURL.lastPathComponent
        }
    }

    func operationQueue(for _: NSFilePromiseProvider) -> OperationQueue {
        queue
    }

    func filePromiseProvider(
        _: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        let item = item
        let id = id
        let preparer = preparer
        let reader = reader
        let done = DispatchSemaphore(value: 0)
        let outcome = Mutex<(any Error)?>(nil)
        // The bridge from this synchronous callback, on the promise's own queue, to the
        // async preparation; the queue thread waits, the preparation runs elsewhere.
        Task.detached(priority: .userInitiated) {
            do {
                let resolved: HandOffItem
                if let item {
                    resolved = item
                } else {
                    let detail = try await reader?.detail(for: id)
                    resolved = CatalogWindowViewModel.handOffItem(id, detail: detail)
                }
                let prepared = try await preparer.prepare(resolved)
                try FileManager.default.copyItem(at: prepared, to: url)
                OtosLog.ui.noticeOperation("handOff.promise", phase: "fulfilled", fields: [
                    "id": id.relativePath.rawValue,
                ])
            } catch {
                OtosLog.ui.errorOperation("handOff.promise", phase: "failed", fields: [
                    "id": id.relativePath.rawValue, "error": String(describing: error),
                ])
                outcome.withLock { $0 = error }
            }
            done.signal()
        }
        done.wait()
        completionHandler(outcome.withLock { $0 })
    }
}
