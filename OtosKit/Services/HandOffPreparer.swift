import AppKit
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
/// another app (ADR 0037). It behaves like Finder: one full-size file per
/// photo. Which file depends on the photo (`HandOffForm`):
/// - **An unedited still that is not a RAW, or an untrimmed video:** the original itself.
///   Nothing is read; a cloud-only original is downloaded by the app that reads it, as
///   with Finder. An original a source stages (an Immich account's, a camera's) has no file
///   until Otos copies it, so one not yet staged — `locality(of:)` says `.fetchable` for a
///   path with no file — is fetched first, as the user's work (ADR 0046 §4). Reveal in
///   Finder takes this form for every photo (`Wanted.original`): it shows where the photo
///   lives, not what is handed over.
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
extension EditedMediaItem {
    /// What a hand-off gives another app for this item.
    nonisolated var handOffForm: HandOffForm {
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
    /// Which file an action takes for a photo.
    enum Wanted: Equatable, Sendable {
        /// The file a hand-off gives (`HandOffForm`): Copy, Share, Open, drag.
        case handOffFile
        /// The original, whatever its form: Reveal in Finder.
        case original
    }

    enum PrepareError: Error, Equatable {
        case originalUnavailable
        /// The volume holding the hand-off folder refused the write for space.
        case outOfSpace
        /// The original is not on this Mac, and the source that holds it cannot send it
        /// now (ADR 0046 §6).
        case sourceUnavailable(SourceUnavailability)
    }

    /// Why a source cannot send an original now, in the source's own terms.
    enum SourceUnavailability: Hashable, Sendable {
        /// An Immich account's server did not answer.
        case serverNotAnswering
        /// A camera's original was asked for while the camera is not connected.
        case cameraDisconnected
    }

    let directory: URL
    private let materialization: any MaterializationRequesting
    private var cleared = false

    init(directory: URL, materialization: any MaterializationRequesting) {
        self.directory = directory
        self.materialization = materialization
    }

    /// The file to hand over for `item`: the original, or one prepared now or earlier in
    /// this launch. With `.original`, always the original (`original(for:)`).
    func prepare(_ item: EditedMediaItem, as wanted: Wanted = .handOffFile) async throws -> URL {
        guard wanted == .handOffFile, item.handOffForm != .original else {
            return try await original(for: item)
        }
        try await clearOnce()
        let target = try Self.preparedURL(for: item, in: directory)
        if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
            return target
        }
        let start = ContinuousClock.now
        try await ensureLocal(item)
        // Written beside the target and moved into place, so a reader never sees half a file.
        let staging = target.deletingLastPathComponent()
            .appending(path: ".\(UUID().uuidString).\(target.pathExtension)")
        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            switch item.handOffForm {
            case .renderedStill:
                let rendered = try await ImageRenderer.interactive.render(
                    item.id.fileURL, longEdge: nil, recipe: item.recipe
                )
                try await MediaFileWriter.writeImage(
                    rendered.image, as: .jpeg, quality: 0.92, metadataOf: item.id.fileURL, removingLocation: false, to: staging
                )
            case .trimmedVideo:
                try await MediaFileWriter.writeVideo(item.id.fileURL, recipe: item.recipe, removingLocation: false, to: staging)
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
            let outOfSpace = MediaFileWriter.refusedForSpace(error)
            OtosLog.mediaIO.errorOperation("handOff.prepare", phase: "failed", fields: [
                "id": item.id.relativePath.rawValue,
                "cause": outOfSpace ? "outOfSpace" : "other",
                "error": String(describing: error),
            ])
            throw outOfSpace ? PrepareError.outOfSpace : error
        }
        OtosLog.mediaIO.noticeOperation("handOff.prepare", phase: "finish", fields: [
            "id": item.id.relativePath.rawValue,
            "form": item.handOffForm == .trimmedVideo ? "trimmedVideo" : "renderedStill",
            "elapsedMs": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
        return target
    }

    /// The original's file, whatever form a hand-off would give: what Reveal in Finder
    /// shows. A file that is there, a cloud placeholder included, is returned as it is, and
    /// so is a path with no file that no source can send: what Finder would do. Only a
    /// staged original its source has not sent yet is fetched, as the user's work.
    private func original(for item: EditedMediaItem) async throws -> URL {
        guard !Self.exists(item.id.fileURL),
              await materialization.locality(of: item.id).isFetchable(at: .interactive)
        else {
            return item.id.fileURL
        }
        let start = ContinuousClock.now
        try await ensureLocal(item)
        OtosLog.mediaIO.noticeOperation("handOff.prepare", phase: "finish", fields: [
            "id": item.id.relativePath.rawValue,
            "form": "fetchedOriginal",
            "elapsedMs": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
        return item.id.fileURL
    }

    /// Whether `prepare(_:as:)` has work to do for `item`: a file to render or copy, or a
    /// staged original to fetch. An original that is there, or that no source can send,
    /// takes none, so the status bar never counts it. Asks the same locality question
    /// `original(for:)` does, without waiting on any transfer.
    func needsPreparation(_ item: EditedMediaItem, as wanted: Wanted) async -> Bool {
        guard wanted == .handOffFile, item.handOffForm != .original else {
            guard !Self.exists(item.id.fileURL) else { return false }
            return await materialization.locality(of: item.id).isFetchable(at: .interactive)
        }
        return readyURL(for: item) == nil
    }

    /// Brings the original's bytes here as the user's work, or says why they cannot come.
    private func ensureLocal(_ item: EditedMediaItem) async throws {
        let outcome = await materialization.ensureLocal(.init(
            id: item.id, sourceSize: item.sourceSize, isVideo: item.isVideo, priority: .interactive
        ))
        switch outcome {
        case .local:
            return
        case .notMaterialized(.serverUnreachable):
            throw PrepareError.sourceUnavailable(.serverNotAnswering)
        case .notMaterialized(.deviceUnavailable):
            throw PrepareError.sourceUnavailable(.cameraDisconnected)
        case .unreachable, .notMaterialized, .userWorkOnly:
            throw PrepareError.originalUnavailable
        }
    }

    /// Whether a file is at `url`. A cloud placeholder is: the app that reads it downloads
    /// it. A staged original not yet copied is not.
    private nonisolated static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// The file to hand over for `item` if it is ready this launch, or nil: the original when
    /// it has a file, else the one prepared for it. Read without waiting, so a drag can hand
    /// a ready file to a receiver that cannot wait for one.
    nonisolated func readyURL(for item: EditedMediaItem) -> URL? {
        guard item.handOffForm != .original else {
            return Self.exists(item.id.fileURL) ? item.id.fileURL : nil
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
    nonisolated static func preparedURL(for item: EditedMediaItem, in directory: URL) throws -> URL {
        let key = try item.id.fileURL.path(percentEncoded: false) + "\n" + CatalogStore.editRecipeJSON(item.recipe)
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let stem = item.id.fileURL.deletingPathExtension().lastPathComponent
        let fileExtension = item.handOffForm == .trimmedVideo ? "mov" : "jpg"
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
}

/// What a receiver that asked for a promised file shows when it cannot have it: a drag
/// has no alert of Otos's own, so the error says why, in the alert's terms.
extension HandOffPreparer.PrepareError: LocalizedError {
    nonisolated var errorDescription: String? {
        switch self {
        case .sourceUnavailable(.serverNotAnswering):
            "The photo’s original isn’t on this Mac, and its Immich server isn’t answering."
        case .sourceUnavailable(.cameraDisconnected):
            "The photo’s original is on a camera that isn’t connected."
        case .outOfSpace:
            "There isn’t enough disk space to prepare the photo."
        case .originalUnavailable:
            "The photo couldn’t be prepared. Its original may be unavailable."
        }
    }
}

/// A dragged photo that must be prepared before it can be handed over: a file promise
/// (ADR 0028, ADR 0037). Finder, Mail, Messages and Safari wait for it. Chrome
/// never fulfils promises, so it receives such a photo only when its file was already
/// prepared earlier this launch, in which case the drag carries that file's URL instead
/// (`CatalogWindowViewModel.dragWriter(for:)`).
///
/// The receiver asks on `queue`, a dedicated serial queue: preparing is async, so the
/// callback waits for it there, never on a cooperative-pool thread. A photo whose details
/// the grid did not hold is read first, then handed over as `EditedMediaItem.handOffForm` says,
/// original included. A photo that cannot be prepared fails the promise with
/// `PrepareError`'s description, which is what the receiver shows.
final nonisolated class HandOffPromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    private let item: EditedMediaItem?
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

    init(item: EditedMediaItem?, id: MediaAssetID? = nil, preparer: HandOffPreparer, reader: MediaTileDetailReader?) {
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

    private static func fileType(for item: EditedMediaItem?, id: MediaAssetID) -> UTType {
        switch item?.handOffForm {
        case .renderedStill: .jpeg
        case .trimmedVideo: .quickTimeMovie
        default: UTType(filenameExtension: id.fileURL.pathExtension) ?? .data
        }
    }

    func filePromiseProvider(_: NSFilePromiseProvider, fileNameForType _: String) -> String {
        let stem = id.fileURL.deletingPathExtension().lastPathComponent
        return switch item?.handOffForm {
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
                let resolved: EditedMediaItem
                if let item {
                    resolved = item
                } else {
                    let detail = try await reader?.detail(for: id)
                    resolved = EditedMediaItem(id: id, detail: detail)
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
