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
/// photo, and the file is on this Mac when it is handed over (ADR 0012). Which file depends
/// on the photo (`HandOffForm`):
/// - **An unedited still that is not a RAW, or an untrimmed video:** the original itself.
///   An original that is not on this Mac — a cloud placeholder, or an original a source
///   stages (an Immich account's, a camera's) that it has not sent yet — is downloaded first,
///   as the user's work, so the app that receives it reads a file that is there and a
///   download that fails is Otos's to report (`Wanted.handOffFile`).
/// - **An edited still or any RAW:** a full-size JPEG rendered from the original with its
///   recipe (RAW9 defaults for an unedited RAW). It keeps the original's metadata, with
///   the orientation reset because the pixels are already upright.
/// - **A trimmed video:** the trimmed range, copied without re-encoding.
///
/// Two actions take another file (`Wanted`): a drag, which cannot wait, hands a cloud
/// placeholder over as it is, because a file promise is never fulfilled by Chrome; Reveal in
/// Finder shows the original, where the photo lives, whatever form a hand-off would give.
///
/// One answer says whether a photo's file is ready (`readyURL(for:as:)`): the status bar
/// counts what it does not answer, a drag hands over what it does, and `prepare(_:as:)`
/// returns it without work.
///
/// Prepared files go into one Otos-owned folder in Application Support, in a folder of this
/// launch's own (`launchDirectory`), at a path determined by the photo and its recipe
/// (`preparedURL`). A photo handed off twice in a launch reuses its file, which is also what
/// lets a later drag into Chrome (which never fulfils file promises) find one; a file an
/// earlier launch prepared is never taken for ready, since the previous launch's folders are
/// cleared once, before this launch's first preparation writes (`clearOnce`), when no reader
/// of an earlier file can remain. Nothing full-size is kept beyond that.
///
/// An actor is reentrant at every `await`, so two asks for one photo's file — a drag's
/// promise and a Copy — would otherwise both render it and race to move it into place. One
/// preparation runs per target path (`preparations`); a second ask joins it, and each asker
/// waits on its own continuation, so the one who cancels stops waiting at once and the
/// preparation is cancelled only when no one waits for it (ADR 0032). Rendering happens on
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
    /// Which file an action takes for a photo, and when that file counts as ready.
    enum Wanted: Equatable, Sendable {
        /// Copy, Share, Open, Open With: the file a hand-off gives (`HandOffForm`), with its
        /// bytes on this Mac. A cloud placeholder is downloaded first.
        case handOffFile
        /// A drag: the file a hand-off gives, but an original that is a cloud placeholder is
        /// handed over as it is, since a drag cannot wait and Chrome never fulfils the file
        /// promise that would (ADR 0037). The receiver downloads it.
        case draggedFile
        /// Reveal in Finder: the original, whatever its form, as Finder shows it: a cloud
        /// placeholder as it is, a staged original once its source has sent it.
        case original
    }

    /// Why a photo's file could not be had, each cause in its own terms. A cancelled
    /// preparation is no failure: it throws `CancellationError`.
    enum PrepareError: Error, Equatable {
        /// The original is not there and no source can send it: a file gone from its folder,
        /// or a volume that is not mounted.
        case originalMissing
        /// The original's provider was asked for it and did not deliver it.
        case downloadFailed
        /// The original is not on this Mac, and the source that holds it cannot send it
        /// now (ADR 0046 §6).
        case sourceUnavailable(SourceUnavailability)
        /// macOS could not fetch what its RAW decoder needs for the photo's camera
        /// (`ImageRenderer.RAWResourcesUnavailable`): no verdict on the file.
        case rawSupportUnavailable
        /// The original is here but could not be rendered or exported.
        case renderFailed
        /// The volume holding the hand-off folder refused the write for space.
        case outOfSpace
    }

    /// Why a source cannot send an original now, in the source's own terms.
    enum SourceUnavailability: Hashable, Sendable {
        /// An Immich account's server did not answer.
        case serverNotAnswering
        /// A camera's original was asked for while the camera is not connected.
        case cameraDisconnected
    }

    /// One photo's file being made, and everyone waiting for it.
    private struct Preparation {
        let serial: UInt64
        var task: Task<Void, Never>?
        var waiters: [UInt64: CheckedContinuation<URL, any Error>]
    }

    /// The hand-off folder: this launch's folder and the earlier launches' it clears.
    let directory: URL
    /// This launch's folder inside `directory`: what it prepares, and all a ready answer
    /// looks at.
    private let launchDirectory: URL
    private let materialization: any MaterializationRequesting
    /// The `SF_DATALESS` detector a ready answer reads an original's status with; a test
    /// stands in for a cloud placeholder through it.
    private let status: @Sendable (URL) -> FileMaterializationStatus
    /// The emptying of the previous launch's files, while it runs; every preparation waits
    /// for the same one before it writes.
    private var clearing: Task<Void, any Error>?
    private var cleared = false
    private var preparations: [URL: Preparation] = [:]
    private var nextSerial: UInt64 = 0

    init(
        directory: URL,
        materialization: any MaterializationRequesting,
        status: @escaping @Sendable (URL) -> FileMaterializationStatus = FileMaterialization.status(of:)
    ) {
        self.directory = directory
        launchDirectory = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        self.materialization = materialization
        self.status = status
    }

    /// The file `wanted` takes for `item`: ready already, or made ready now — the original
    /// downloaded, or a file rendered or exported.
    func prepare(_ item: EditedMediaItem, as wanted: Wanted = .handOffFile) async throws -> URL {
        if let ready = readyURL(for: item, as: wanted) {
            return ready
        }
        guard wanted != .original, item.handOffForm != .original else {
            return try await fetchOriginal(item)
        }
        let target = try Self.preparedURL(for: item, in: launchDirectory)
        return try await join(item, at: target)
    }

    /// The file `wanted` takes for `item` if it is ready now, or nil: the one answer to that
    /// question. Read without waiting, so the status bar can count the photos that take work
    /// and a drag can hand a ready file to a receiver that cannot wait for one.
    /// - the original, for `.original` and for a photo handed over as itself: there with its
    ///   bytes (`.handOffFile`), or there at all, a cloud placeholder included
    ///   (`.draggedFile`, `.original`);
    /// - otherwise the file this launch prepared for the photo and its recipe, in this
    ///   launch's folder, so an earlier launch's file is never taken for one.
    nonisolated func readyURL(for item: EditedMediaItem, as wanted: Wanted) -> URL? {
        guard wanted != .original, item.handOffForm != .original else {
            switch status(item.id.fileURL) {
            case .materialized:
                return item.id.fileURL
            case .dataless:
                return wanted == .handOffFile ? nil : item.id.fileURL
            case .unknown:
                return nil
            }
        }
        do {
            let url = try Self.preparedURL(for: item, in: launchDirectory)
            return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
        } catch {
            // The recipe could not be encoded into a path: nothing is ready, and preparing
            // reports the same error.
            return nil
        }
    }

    /// For each item, whether `prepare(_:as:)` has work to do for it: `readyURL` has no
    /// answer. Asked on the actor, off the main thread, since each answer reads the disk.
    func needsWork(_ items: [EditedMediaItem], as wanted: Wanted) -> [Bool] {
        items.map { readyURL(for: $0, as: wanted) == nil }
    }

    /// The original, downloaded when it is not on this Mac. A cloud placeholder is
    /// downloaded only for `.handOffFile`; `readyURL` has handed it over as it is otherwise.
    private func fetchOriginal(_ item: EditedMediaItem) async throws -> URL {
        let start = ContinuousClock.now
        try await ensureLocal(item)
        OtosLog.mediaIO.noticeOperation("handOff.prepare", phase: "finish", fields: [
            "id": item.id.relativePath.rawValue,
            "form": "fetchedOriginal",
            "elapsedMs": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
        return item.id.fileURL
    }

    /// Waits for the one preparation of `target`, starting it when none runs. A waiter
    /// cancelled stops waiting at once; the preparation stops when its last waiter left.
    private func join(_ item: EditedMediaItem, at target: URL) async throws -> URL {
        nextSerial &+= 1
        let token = nextSerial
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if preparations[target] == nil {
                    nextSerial &+= 1
                    let serial = nextSerial
                    preparations[target] = Preparation(serial: serial, task: nil, waiters: [:])
                    preparations[target]?.task = Task { [weak self] in
                        await self?.make(item, at: target, serial: serial)
                    }
                }
                preparations[target]?.waiters[token] = continuation
            }
        } onCancel: {
            Task { await self.leave(token, from: target) }
        }
    }

    /// How many asks wait for the preparation of `item`'s file now: the diagnostic read a
    /// test uses to see that two asks share one preparation.
    func waiterCount(for item: EditedMediaItem) throws -> Int {
        try preparations[Self.preparedURL(for: item, in: launchDirectory)]?.waiters.count ?? 0
    }

    /// A waiter that was cancelled leaves; the preparation is cancelled and forgotten once no
    /// one waits for it, so the next ask starts a fresh one.
    private func leave(_ token: UInt64, from target: URL) {
        guard let waiter = preparations[target]?.waiters.removeValue(forKey: token) else { return }
        waiter.resume(throwing: CancellationError())
        guard let preparation = preparations[target], preparation.waiters.isEmpty else { return }
        preparations[target] = nil
        preparation.task?.cancel()
        OtosLog.mediaIO.noticeOperation("handOff.prepare", phase: "abandonedByLastWaiter", fields: [
            "path": target.lastPathComponent,
        ])
    }

    /// Makes `target` and answers everyone waiting for it, if the preparation is still the
    /// one they wait for.
    private func make(_ item: EditedMediaItem, at target: URL, serial: UInt64) async {
        let result: Result<URL, any Error>
        do {
            try await render(item, to: target)
            result = .success(target)
        } catch {
            result = .failure(error)
        }
        guard let preparation = preparations[target], preparation.serial == serial else { return }
        preparations[target] = nil
        for waiter in preparation.waiters.values {
            waiter.resume(with: result)
        }
    }

    /// Renders or exports `item` into `target`, written beside it and moved into place, so a
    /// reader never sees half a file.
    private func render(_ item: EditedMediaItem, to target: URL) async throws {
        try await clearOnce()
        // A preparation that finished between this ask's ready check and its join left the
        // file in place: it is ready, and making it again would collide with it.
        guard !FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else { return }
        let start = ContinuousClock.now
        let staging = target.deletingLastPathComponent()
            .appending(path: ".\(UUID().uuidString).\(target.pathExtension)")
        do {
            try await ensureLocal(item)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            switch item.handOffForm {
            case .renderedStill:
                let rendered = try await ImageRenderer.interactive.render(
                    item.id.fileURL, longEdge: nil, recipe: item.recipe
                )
                try Task.checkCancellation()
                try await MediaFileWriter.writeImage(
                    rendered.image, as: .jpeg, quality: 0.92, metadataOf: item.id.fileURL, removingLocation: false, to: staging
                )
            case .trimmedVideo:
                try await MediaFileWriter.writeVideo(item.id.fileURL, recipe: item.recipe, removingLocation: false, to: staging)
            case .original:
                break
            }
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: staging, to: target)
        } catch {
            removeStaging(staging)
            guard let failure = Self.failure(for: error) else {
                OtosLog.mediaIO.noticeOperation("handOff.prepare", phase: "cancelled", fields: [
                    "id": item.id.relativePath.rawValue,
                ])
                throw error
            }
            OtosLog.mediaIO.errorOperation("handOff.prepare", phase: "failed", fields: [
                "id": item.id.relativePath.rawValue, "cause": "\(failure)", "error": String(describing: error),
            ])
            throw failure
        }
        OtosLog.mediaIO.noticeOperation("handOff.prepare", phase: "finish", fields: [
            "id": item.id.relativePath.rawValue,
            "form": item.handOffForm == .trimmedVideo ? "trimmedVideo" : "renderedStill",
            "elapsedMs": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
    }

    /// What a failed render or write is, in `PrepareError`'s terms; nil for a cancellation,
    /// which is rethrown as it is. Classified by type and by the error's typed chain, never
    /// by its text.
    nonisolated static func failure(for error: any Error) -> PrepareError? {
        if error is CancellationError {
            return nil
        }
        if let failure = error as? PrepareError {
            return failure
        }
        if MediaFileWriter.refusedForSpace(error) {
            return .outOfSpace
        }
        if error is ImageRenderer.RAWResourcesUnavailable {
            return .rawSupportUnavailable
        }
        return .renderFailed
    }

    private nonisolated func removeStaging(_ staging: URL) {
        guard FileManager.default.fileExists(atPath: staging.path(percentEncoded: false)) else { return }
        do {
            try FileManager.default.removeItem(at: staging)
        } catch {
            OtosLog.mediaIO.errorOperation("handOff.prepare", phase: "stagingNotRemoved", fields: [
                "path": staging.path(percentEncoded: false), "error": String(describing: error),
            ])
        }
    }

    /// Brings the original's bytes here as the user's work, or says why they cannot come.
    private func ensureLocal(_ item: EditedMediaItem) async throws {
        let outcome = await materialization.ensureLocal(.init(
            id: item.id, sourceSize: item.sourceSize, isVideo: item.isVideo, priority: .interactive
        ))
        try Task.checkCancellation()
        if let failure = Self.failure(for: outcome) {
            throw failure
        }
    }

    /// What an `ensureLocal` outcome that is not local means for a hand-off; nil when the
    /// bytes are here. A transfer cancelled because its asker left throws
    /// `CancellationError` above, never a failure.
    nonisolated static func failure(for outcome: EnsureLocalOutcome) -> PrepareError? {
        switch outcome {
        case .local:
            nil
        case .unreachable:
            .originalMissing
        case .notMaterialized(.serverUnreachable):
            .sourceUnavailable(.serverNotAnswering)
        case .notMaterialized(.deviceUnavailable):
            .sourceUnavailable(.cameraDisconnected)
        case .notMaterialized(.insufficientLocalSpace):
            .outOfSpace
        case .notMaterialized, .userWorkOnly:
            .downloadFailed
        }
    }

    /// `<directory>/<digest of path and recipe>/<original name>.jpg` (or `.mov`): one file
    /// per photo and recipe, named as the original so the receiver sees a familiar name.
    nonisolated static func preparedURL(for item: EditedMediaItem, in directory: URL) throws -> URL {
        let key = try item.id.fileURL.path(percentEncoded: false) + "\n" + CatalogStore.editRecipeJSON(item.recipe)
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return directory
            .appending(path: digest, directoryHint: .isDirectory)
            .appending(path: handOffFileName(for: item))
    }

    /// The name the receiver sees: the original's for a photo handed over as itself, else the
    /// original's stem with the prepared file's extension.
    nonisolated static func handOffFileName(for item: EditedMediaItem) -> String {
        let stem = item.id.fileURL.deletingPathExtension().lastPathComponent
        return switch item.handOffForm {
        case .original: item.id.fileURL.lastPathComponent
        case .renderedStill: "\(stem).jpg"
        case .trimmedVideo: "\(stem).mov"
        }
    }

    /// Clears the earlier launches' folders once, before this launch's first preparation
    /// writes. Concurrent first preparations wait for the same clearing; one that failed is
    /// tried again by the next preparation, since an error is not a fact (ADR 0032).
    private func clearOnce() async throws {
        guard !cleared else { return }
        let task: Task<Void, any Error>
        if let clearing {
            task = clearing
        } else {
            let directory = directory
            let keeping = launchDirectory.lastPathComponent
            task = Task { try await Self.removeContents(of: directory, keeping: keeping) }
            clearing = task
        }
        do {
            try await task.value
            cleared = true
        } catch {
            OtosLog.mediaIO.errorOperation("handOff.clear", phase: "failed", fields: [
                "error": String(describing: error),
            ])
            if clearing == task {
                clearing = nil
            }
            throw error
        }
    }

    @concurrent
    private static func removeContents(of directory: URL, keeping launchFolder: String) async throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path(percentEncoded: false)) else { return }
        for entry in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where entry.lastPathComponent != launchFolder
        {
            try manager.removeItem(at: entry)
        }
    }
}

/// What a receiver that asked for a promised file shows when it cannot have it: a drag
/// has no alert of Otos's own, so the error says why, in the alert's terms.
extension HandOffPreparer.PrepareError: LocalizedError {
    nonisolated var errorDescription: String? {
        switch self {
        case .originalMissing:
            "The photo’s original isn’t where Otos last saw it."
        case .downloadFailed:
            "The photo’s original couldn’t be downloaded."
        case .sourceUnavailable(.serverNotAnswering):
            "The photo’s original isn’t on this Mac, and its Immich server isn’t answering."
        case .sourceUnavailable(.cameraDisconnected):
            "The photo’s original is on a camera that isn’t connected."
        case .rawSupportUnavailable:
            "macOS couldn’t download what it needs to develop this RAW photo."
        case .renderFailed:
            "The photo couldn’t be rendered from its original."
        case .outOfSpace:
            "There isn’t enough disk space to prepare the photo."
        }
    }
}

/// A photo a drag carries whose details the grid did not hold when the drag began. The
/// window reads them at once (`CatalogWindowViewModel.dragWriters(for:)`), off the main
/// actor, and resolves this with the item or with the read's error; the promise waits for
/// that answer before it names the file or prepares it, so the name and the file it writes
/// are always the same photo's hand-off file.
final nonisolated class PendingHandOffItem: Sendable {
    let id: MediaAssetID
    private let answer = Mutex<Result<EditedMediaItem, any Error>?>(nil)
    /// Signalled once the answer is in; each waiter passes it on, so every later wait
    /// returns at once.
    private let answered = DispatchSemaphore(value: 0)

    init(id: MediaAssetID) {
        self.id = id
    }

    /// Records the read's answer; the first one is kept.
    func resolve(_ result: Result<EditedMediaItem, any Error>) {
        let first = answer.withLock { stored in
            guard stored == nil else { return false }
            stored = result
            return true
        }
        if first {
            answered.signal()
        }
    }

    /// The read's answer, once it has come. Blocks the calling thread until then: the
    /// promise's own queue, or the thread a receiver asks for the name on, never the
    /// cooperative pool. The read never needs the main actor, so a wait on the main thread
    /// cannot hold up the answer it waits for.
    func wait() -> Result<EditedMediaItem, any Error> {
        answered.wait()
        answered.signal()
        return answer.withLock { stored in
            stored ?? .failure(CancellationError())
        }
    }
}

/// A dragged photo whose file is not ready: a file promise (ADR 0028, ADR 0037), which
/// prepares the file when the receiver asks. Finder, Mail, Messages and Safari wait for it.
/// Chrome never fulfils promises, so it receives such a photo only when its file is ready
/// when the drag begins, in which case the drag carries that file's URL instead
/// (`CatalogWindowViewModel.dragWriters(for:)`).
///
/// The receiver asks on `queue`, a dedicated serial queue. Preparing is async, so the
/// callback waits for it there; the copy into the receiver's folder then runs on that same
/// thread, never on a cooperative-pool thread, for as long as a large file takes. The file
/// is prepared as `Wanted.handOffFile`, so a cloud-only original is downloaded through the
/// shared coordinator first and the copy reads a file that is there. A photo that cannot be
/// prepared fails the promise with `PrepareError`'s description, which is what the receiver
/// shows.
final nonisolated class HandOffPromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    /// The photo the promise is for: known when the drag began, or read since.
    enum Subject: Sendable {
        case item(EditedMediaItem)
        case pending(PendingHandOffItem)

        var id: MediaAssetID {
            switch self {
            case let .item(item): item.id
            case let .pending(pending): pending.id
            }
        }
    }

    /// The details of a pending photo could not be read, so it is not known what to hand over.
    struct DetailsUnread: LocalizedError {
        var errorDescription: String? {
            "Otos couldn’t read this photo from its catalog."
        }
    }

    private let subject: Subject
    private let preparer: HandOffPreparer
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "net.melisma.Otos.handOff.promise"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(_ subject: Subject, preparer: HandOffPreparer) {
        self.subject = subject
        self.preparer = preparer
        super.init()
        fileType = Self.fileType(for: subject).identifier
        delegate = self
    }

    /// The type the drag declares when it begins. A pending photo's form is not known yet,
    /// so it declares what every form of it conforms to: an image or a movie.
    static func fileType(for subject: Subject) -> UTType {
        switch subject {
        case let .item(item):
            switch item.handOffForm {
            case .renderedStill: .jpeg
            case .trimmedVideo: .quickTimeMovie
            case .original: UTType(filenameExtension: item.id.fileURL.pathExtension) ?? .data
            }
        case let .pending(pending):
            switch UTType(filenameExtension: pending.id.fileURL.pathExtension) {
            case let type? where type.conforms(to: .movie): .movie
            case let type? where type.conforms(to: .image): .image
            default: .data
            }
        }
    }

    /// The photo, waiting for a pending one's details.
    private func resolvedItem() -> Result<EditedMediaItem, any Error> {
        switch subject {
        case let .item(item): .success(item)
        case let .pending(pending): pending.wait()
        }
    }

    func filePromiseProvider(_: NSFilePromiseProvider, fileNameForType _: String) -> String {
        switch resolvedItem() {
        case let .success(item):
            HandOffPreparer.handOffFileName(for: item)
        case .failure:
            // Nothing will be written under it: the write fails with the read's error.
            subject.id.fileURL.lastPathComponent
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
        let id = subject.id
        let item: EditedMediaItem
        switch resolvedItem() {
        case let .success(resolved):
            item = resolved
        case let .failure(error):
            OtosLog.ui.errorOperation("handOff.promise", phase: "failed", fields: [
                "id": id.relativePath.rawValue, "cause": "detailsUnread", "error": String(describing: error),
            ])
            completionHandler(DetailsUnread())
            return
        }
        let preparer = preparer
        let done = DispatchSemaphore(value: 0)
        let outcome = Mutex<Result<URL, any Error>?>(nil)
        // The bridge from this synchronous callback, on the promise's own queue, to the
        // async preparation; this thread waits, the preparation runs elsewhere.
        Task.detached(priority: .userInitiated) {
            let result: Result<URL, any Error>
            do {
                result = try await .success(preparer.prepare(item, as: .handOffFile))
            } catch {
                result = .failure(error)
            }
            outcome.withLock { $0 = result }
            done.signal()
        }
        done.wait()
        do {
            let prepared = try (outcome.withLock { $0 } ?? .failure(CancellationError())).get()
            try FileManager.default.copyItem(at: prepared, to: url)
            OtosLog.ui.noticeOperation("handOff.promise", phase: "fulfilled", fields: [
                "id": id.relativePath.rawValue,
            ])
            completionHandler(nil)
        } catch {
            OtosLog.ui.errorOperation("handOff.promise", phase: "failed", fields: [
                "id": id.relativePath.rawValue, "error": String(describing: error),
            ])
            completionHandler(error)
        }
    }
}
