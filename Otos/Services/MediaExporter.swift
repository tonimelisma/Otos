import CoreGraphics
import Foundation

/// Export guide
///
/// File ▸ Export… writes new files into a folder the person chose (ADR 0038). This is the
/// one owner of exporting one item; `CatalogWindowViewModelExport` runs a job of them in
/// order. For each item:
/// 1. A cloud-only original is downloaded first, unless that would take its volume below
///    the 5 GB floor (`FreeSpaceFloor`), which stops the job.
/// 2. The file is written into a scratch folder the system keeps on the destination's
///    volume (`itemReplacementDirectory`), never into the destination itself, so a crash
///    leaves nothing half-written or hidden in the person's folder:
///    - a photo as JPEG or HEIC: rendered with its edit, scaled down to the long edge when
///      one is set, through `MediaFileWriter` (the same writer a hand-off uses);
///    - a photo as Original, or an untrimmed video: the original's bytes;
///    - a trimmed video, or one whose location is removed: its range, without re-encoding.
///    Each write first checks the floor on the destination's volume.
/// 3. It is published under the original's name with the new extension. A name already
///    taken gets `_001`, `_002`… (`ImportNaming.suffixToken`, as import names them), and
///    `ExclusivePublication` makes the move, so an existing file is never overwritten.
///
/// Stateless: every function takes its inputs as values, and the blocking work runs in
/// `@concurrent` functions off any actor.
nonisolated enum ExportOutcome: Equatable, Sendable {
    case exported(URL)
    case failed
    /// The next write would take a volume below the free-space floor; the job stops.
    case belowFloor
    /// The destination folder is gone (deleted, or its disk ejected); the job stops.
    case folderUnavailable
    /// A write was refused because its volume is out of space; the job stops, because
    /// every later write would be refused too.
    case outOfSpace
}

nonisolated enum MediaExporter {
    enum ExportError: Error {
        case originalUnavailable
        case belowFloor
        case folderUnavailable
        case namesExhausted
        case publishFailed(String)
    }

    /// The suffixes tried before a name counts as exhausted: `_001` through `_999`.
    private static let suffixes = 0 ..< 1000

    /// Whether `folder` exists as a folder now.
    @concurrent
    static func isAvailableFolder(_ folder: URL) async -> Bool {
        isDirectory(folder)
    }

    @concurrent
    static func export(
        _ item: EditedMediaItem,
        settings: ExportSettings,
        to folder: URL,
        materialization: MaterializationCoordinator?
    ) async -> ExportOutcome {
        let start = ContinuousClock.now
        let original = item.id.fileURL
        do {
            guard isDirectory(folder) else {
                throw ExportError.folderUnavailable
            }
            if FileMaterialization.status(of: original) == .dataless {
                try requireRoom(item.sourceSize ?? fileSize(original), onVolumeOf: original)
            }
            guard await MaterializationCoordinator.makeLocal(
                item.id, sourceSize: item.sourceSize, isVideo: item.isVideo, via: materialization
            ) else {
                throw ExportError.originalUnavailable
            }
            let scratch = try FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true
            )
            defer { removeScratch(scratch) }
            let (staged, fileExtension) = try await write(item, settings: settings, into: scratch, folder: folder)
            let published = try publish(
                staged, stem: original.deletingPathExtension().lastPathComponent, fileExtension: fileExtension, in: folder
            )
            OtosLog.mediaIO.noticeOperation("export.item", phase: "finish", fields: [
                "id": item.id.relativePath.rawValue,
                "format": settings.format.rawValue,
                "name": published.lastPathComponent,
                "elapsedMs": "\(DiagnosticsTiming.milliseconds(since: start))",
            ])
            return .exported(published)
        } catch ExportError.belowFloor {
            OtosLog.mediaIO.noticeOperation("export.item", phase: "belowFloor", fields: [
                "id": item.id.relativePath.rawValue,
            ])
            return .belowFloor
        } catch ExportError.folderUnavailable {
            OtosLog.mediaIO.noticeOperation("export.item", phase: "folderUnavailable", fields: [
                "folder": folder.path(percentEncoded: false),
            ])
            return .folderUnavailable
        } catch where MediaFileWriter.refusedForSpace(error) {
            OtosLog.mediaIO.errorOperation("export.item", phase: "outOfSpace", fields: [
                "id": item.id.relativePath.rawValue, "error": String(describing: error),
            ])
            return .outOfSpace
        } catch {
            OtosLog.mediaIO.errorOperation("export.item", phase: "failed", fields: [
                "id": item.id.relativePath.rawValue, "error": String(describing: error),
            ])
            return .failed
        }
    }

    /// Writes the item's file into `scratch` and returns it with the extension it is
    /// published under.
    private static func write(
        _ item: EditedMediaItem,
        settings: ExportSettings,
        into scratch: URL,
        folder: URL
    ) async throws -> (URL, String) {
        let original = item.id.fileURL
        if item.isVideo {
            let trimmed = item.recipe.trimStart != nil || item.recipe.trimEnd != nil
            if settings.shapesRenderedFile, trimmed || settings.removesLocation {
                // A range copied without re-encoding is never larger than the original.
                try requireRoom(item.sourceSize ?? fileSize(original), onVolumeOf: folder)
                let staged = scratch.appending(path: "export.mov")
                try await MediaFileWriter.writeVideo(
                    original, recipe: item.recipe, removingLocation: settings.removesLocation, to: staged
                )
                return (staged, "mov")
            }
        } else if let rendered = settings.format.renderedType {
            let image = try await ImageRenderer.background.render(
                original, longEdge: settings.outputLongEdge, recipe: item.recipe
            ).image
            // The uncompressed size bounds the encoded file from above.
            try requireRoom(Int64(image.width) * Int64(image.height) * 3, onVolumeOf: folder)
            let staged = scratch.appending(path: "export.\(rendered.fileExtension)")
            try await MediaFileWriter.writeImage(
                image,
                as: rendered.type,
                quality: settings.quality,
                metadataOf: original,
                removingLocation: settings.removesLocation,
                to: staged
            )
            return (staged, rendered.fileExtension)
        }
        try requireRoom(item.sourceSize ?? fileSize(original), onVolumeOf: folder)
        let staged = scratch.appending(path: "export")
        try FileManager.default.copyItem(at: original, to: staged)
        return (staged, original.pathExtension)
    }

    private static func publish(_ staged: URL, stem: String, fileExtension: String, in folder: URL) throws -> URL {
        for suffix in suffixes {
            let name = stem + ImportNaming.suffixToken(suffix) + (fileExtension.isEmpty ? "" : ".\(fileExtension)")
            let target = folder.appending(path: name)
            switch ExclusivePublication.publish(staging: staged, final: target) {
            case .published:
                return target
            case .destinationExists:
                continue
            case let .failed(failure):
                if failure.outOfSpace {
                    throw MediaFileWriter.WriteError.outOfSpace
                }
                throw ExportError.publishFailed(failure.detail)
            }
        }
        throw ExportError.namesExhausted
    }

    private static func requireRoom(_ bytes: Int64, onVolumeOf url: URL) throws {
        guard FreeSpaceFloor.admits(bytes, available: FreeSpaceFloor.availableBytes(onVolumeOf: url)) else {
            throw ExportError.belowFloor
        }
    }

    /// The file's logical size, which a cloud-only file reports without downloading.
    private static func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        guard let size = attributes[.size] as? NSNumber else {
            throw ExportError.originalUnavailable
        }
        return size.int64Value
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func removeScratch(_ scratch: URL) {
        do {
            try FileManager.default.removeItem(at: scratch)
        } catch {
            // The system clears its item-replacement folders itself; this says one was left.
            OtosLog.mediaIO.errorOperation("export.item", phase: "scratchNotRemoved", fields: [
                "path": scratch.path(percentEncoded: false), "error": String(describing: error),
            ])
        }
    }
}
