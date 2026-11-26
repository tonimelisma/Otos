import AppKit
import AVFoundation
import Foundation
@testable import OtosKit
import Synchronization
import Testing
import UniformTypeIdentifiers

/// ADR 0037: a hand-off is one full-size file per photo — the original for an
/// unedited still or video, a rendered JPEG for an edited photo or a RAW, the trimmed range
/// of a trimmed video.
/// The fixtures are local files, so nothing is ever fetched.
private let localOriginals = ClosureMaterializationRequester { _ in .cancelled }

@Suite(.testScope)
@MainActor
struct HandOffTests {
    @Test func eachPhotoIsHandedOverInTheFormItsEditCalls() {
        func form(_ name: String, video: Bool = false, _ recipe: EditRecipe = .neutral) -> HandOffForm {
            let id = MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/P"), relativePath: MediaRelativePath(rawValue: name))
            return EditedMediaItem(id: id, isVideo: video, recipe: recipe, sourceSize: nil).handOffForm
        }
        #expect(form("a.jpg") == .original)
        #expect(form("a.jpg", EditRecipe(exposure: 1)) == .renderedStill)
        #expect(form("b.arw") == .renderedStill)
        #expect(form("c.mov", video: true) == .original)
        #expect(form("c.mov", video: true, EditRecipe(trimEnd: 2)) == .trimmedVideo)
    }

    /// A full disk is classified by the error's typed chain — Foundation's out-of-space
    /// code, a POSIX `ENOSPC` beneath another error, AVFoundation's `diskFull` — and never
    /// by its wording.
    @Test func aFullDiskIsRecognizedByItsErrorChain() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        #expect(FreeSpaceFloor.refusedForSpace(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)))
        #expect(FreeSpaceFloor.refusedForSpace(posix))
        #expect(FreeSpaceFloor.refusedForSpace(NSError(
            domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSUnderlyingErrorKey: posix]
        )))
        #expect(!FreeSpaceFloor.refusedForSpace(NSError(
            domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
            userInfo: [NSLocalizedDescriptionKey: "The disk is full"]
        )))
        #expect(MediaFileWriter.isDiskFull(AVError(.diskFull)))
        #expect(!MediaFileWriter.isDiskFull(AVError(.unknown)))
    }

    /// Every way a photo can fail a hand-off is classified by its type — never by its text —
    /// into its own cause, and a cancellation is no failure at all.
    @Test func aFailureIsClassifiedByItsType() {
        #expect(HandOffPreparer.failure(for: CancellationError()) == nil)
        #expect(HandOffPreparer.failure(for: ImageRenderer.RAWResourcesUnavailable(domain: "CIRAW", code: 4))
            == .rawSupportUnavailable)
        #expect(HandOffPreparer.failure(for: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError))
            == .outOfSpace)
        #expect(HandOffPreparer.failure(for: ImageRenderer.RenderError.unreadable) == .renderFailed)
        #expect(HandOffPreparer.failure(for: EnsureLocalOutcome.local) == nil)
        #expect(HandOffPreparer.failure(for: EnsureLocalOutcome.unreachable) == .originalMissing)
        #expect(HandOffPreparer.failure(for: EnsureLocalOutcome.notMaterialized(.requestFailed)) == .downloadFailed)
        #expect(HandOffPreparer.failure(for: EnsureLocalOutcome.notMaterialized(.timedOut)) == .downloadFailed)
        #expect(HandOffPreparer.failure(for: EnsureLocalOutcome.notMaterialized(.serverUnreachable))
            == .sourceUnavailable(.serverNotAnswering))
        #expect(HandOffPreparer.failure(for: EnsureLocalOutcome.notMaterialized(.deviceUnavailable))
            == .sourceUnavailable(.cameraDisconnected))
    }

    /// The alert names the one photo's cause in its own terms (ADR 0046 §6): a full disk as
    /// one, a folder's provider or a source by the name the sidebar shows, a RAW's missing
    /// camera support as macOS's, never "the original may be unavailable" for all of them.
    @Test func eachFailureSaysItsOwnCause() {
        func message(_ cause: HandOffPreparer.PrepareError, source: String = "Pictures") -> String {
            HandOffFailure.photo(cause, source: source).alertMessage(for: .openDefault)
        }
        #expect(message(.originalMissing) == "One photo’s original isn’t where Otos last saw it. Nothing was handed over.")
        #expect(message(.downloadFailed) == "One photo couldn’t be downloaded from “Pictures”. Nothing was handed over.")
        #expect(message(.sourceUnavailable(.serverNotAnswering), source: "Family")
            == "“Family” isn’t answering, so one photo couldn’t be downloaded. Nothing was handed over.")
        #expect(message(.sourceUnavailable(.cameraDisconnected), source: "EOS R5")
            == "“EOS R5” isn’t connected, so one photo couldn’t be copied from it. Nothing was handed over.")
        #expect(message(.rawSupportUnavailable)
            == "macOS couldn’t download what it needs to develop one RAW photo. Nothing was handed over.")
        #expect(message(.renderFailed) == "One photo couldn’t be rendered from its original. Nothing was handed over.")
        #expect(message(.outOfSpace)
            == "There isn’t enough disk space to prepare one photo. Nothing was handed over. Free up space and try again.")
        #expect(HandOffFailure.detailsUnread.alertMessage(for: .revealInFinder)
            == "Otos couldn’t read these photos from its catalog. Nothing was revealed.")
        #expect(HandOffFailure.photo(.downloadFailed, source: "Pictures").alertMessage(for: .revealInFinder)
            == "One photo couldn’t be downloaded from “Pictures”. Nothing was revealed.")
    }

    /// An original a source stages has no file until Otos copies it: one not yet staged is
    /// fetched as the user's work before it is handed over, and a drag promises it rather
    /// than offering a path with nothing there. A source that cannot send it fails the
    /// promise with a reason the receiver can show.
    @Test func aStagedOriginalIsFetchedBeforeItIsHandedOver() async throws {
        let directory = try makeTestDirectory()
        let staged = directory.appending(path: "a1/IMG_1.JPG")
        let id = try MediaAssetID(
            libraryRootPath: CatalogPath.normalizedExistingDirectoryPath(for: directory),
            relativePath: MediaRelativePath(rawValue: "a1/IMG_1.JPG")
        )
        let outcome = Mutex(MaterializationOutcome.serverUnreachable)
        let requests = Mutex(0)
        let source = ClosureMaterializationRequester(status: { url in
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? .materialized : .dataless
        }) { url in
            requests.withLock { $0 += 1 }
            let answer = outcome.withLock { $0 }
            if answer == .materialized {
                do {
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    try Data("jpeg".utf8).write(to: url)
                } catch {
                    return MaterializationResult(outcome: .requestFailed, rerequestCount: 0, elapsedMs: 0)
                }
            }
            return MaterializationResult(outcome: answer, rerequestCount: 0, elapsedMs: 0)
        }
        let preparer = HandOffPreparer(directory: directory.appending(path: "HandOff"), materialization: source)
        let item = EditedMediaItem(id: id, isVideo: false, recipe: .neutral, sourceSize: 4)
        #expect(item.handOffForm == .original)
        #expect(preparer.readyURL(for: item, as: .handOffFile) == nil)
        #expect(preparer.readyURL(for: item, as: .draggedFile) == nil)

        await #expect(throws: HandOffPreparer.PrepareError.sourceUnavailable(.serverNotAnswering)) {
            try await preparer.prepare(item)
        }
        let promise = HandOffPromise(.item(item), preparer: preparer)
        let dropped = directory.appending(path: "Dropped/IMG_1.JPG")
        try FileManager.default.createDirectory(at: dropped.deletingLastPathComponent(), withIntermediateDirectories: true)
        func deliver() async -> (any Error)? {
            await withCheckedContinuation { continuation in
                promise.operationQueue(for: promise).addOperation {
                    promise.filePromiseProvider(promise, writePromiseTo: dropped) { continuation.resume(returning: $0) }
                }
            }
        }
        let refused = await deliver()
        #expect(refused?.localizedDescription
            == "The photo’s original isn’t on this Mac, and its Immich server isn’t answering.")

        outcome.withLock { $0 = .deviceUnavailable }
        await #expect(throws: HandOffPreparer.PrepareError.sourceUnavailable(.cameraDisconnected)) {
            try await preparer.prepare(item)
        }

        outcome.withLock { $0 = .materialized }
        #expect(try await preparer.prepare(item) == staged)
        #expect(preparer.readyURL(for: item, as: .handOffFile) == staged)
        #expect(await deliver() == nil)
        #expect(FileManager.default.contents(atPath: dropped.path(percentEncoded: false)) == Data("jpeg".utf8))
        // A staged original is fetched once; after that it is handed over as it is.
        #expect(requests.withLock { $0 } == 4)
    }

    /// A cloud-only original is downloaded before Copy, Share or Open hands it over, so the
    /// receiver reads a file that is there (ADR 0012). A drag and a reveal take it as it is;
    /// a download the provider does not deliver fails with its own cause.
    @Test func aCloudPlaceholderIsDownloadedBeforeItIsHandedOver() async throws {
        let directory = try makeTestDirectory()
        let id = try makeLocalMediaIDs(["cloud.jpg"])[0]
        let downloaded = Mutex(false)
        let delivers = Mutex(false)
        let requests = Mutex(0)
        let status: @Sendable (URL) -> FileMaterializationStatus = { _ in
            downloaded.withLock { $0 } ? .materialized : .dataless
        }
        let source = ClosureMaterializationRequester(status: status) { _ in
            requests.withLock { $0 += 1 }
            guard delivers.withLock({ $0 }) else {
                return MaterializationResult(outcome: .requestFailed, rerequestCount: 0, elapsedMs: 0)
            }
            downloaded.withLock { $0 = true }
            return MaterializationResult(outcome: .materialized, rerequestCount: 0, elapsedMs: 0)
        }
        let preparer = HandOffPreparer(
            directory: directory.appending(path: "HandOff"), materialization: source, status: status
        )
        let item = EditedMediaItem(id: id, isVideo: false, recipe: .neutral, sourceSize: 4)

        #expect(preparer.readyURL(for: item, as: .handOffFile) == nil)
        #expect(preparer.readyURL(for: item, as: .draggedFile) == id.fileURL)
        #expect(preparer.readyURL(for: item, as: .original) == id.fileURL)
        await #expect(throws: HandOffPreparer.PrepareError.downloadFailed) {
            try await preparer.prepare(item)
        }

        delivers.withLock { $0 = true }
        #expect(try await preparer.prepare(item) == id.fileURL)
        #expect(requests.withLock { $0 } == 2)
        #expect(preparer.readyURL(for: item, as: .handOffFile) == id.fileURL)
    }

    /// Reveal in Finder takes the original, never the file a hand-off gives: an edited
    /// photo not yet staged is fetched as its original, and nothing is rendered for it.
    @Test func aRevealFetchesTheStagedOriginalOfAnEditedPhoto() async throws {
        let directory = try makeTestDirectory()
        let staged = directory.appending(path: "a1/IMG_2.JPG")
        let id = try MediaAssetID(
            libraryRootPath: CatalogPath.normalizedExistingDirectoryPath(for: directory),
            relativePath: MediaRelativePath(rawValue: "a1/IMG_2.JPG")
        )
        let outcome = Mutex(MaterializationOutcome.deviceUnavailable)
        let source = ClosureMaterializationRequester(status: { url in
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? .materialized : .dataless
        }) { url in
            let answer = outcome.withLock { $0 }
            if answer == .materialized {
                do {
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    try writeGradientJPEG(to: url)
                } catch {
                    return MaterializationResult(outcome: .requestFailed, rerequestCount: 0, elapsedMs: 0)
                }
            }
            return MaterializationResult(outcome: answer, rerequestCount: 0, elapsedMs: 0)
        }
        let handOff = directory.appending(path: "HandOff")
        let preparer = HandOffPreparer(directory: handOff, materialization: source)
        let item = EditedMediaItem(id: id, isVideo: false, recipe: EditRecipe(exposure: 1), sourceSize: nil)
        #expect(item.handOffForm == .renderedStill)
        #expect(preparer.readyURL(for: item, as: .original) == nil)

        await #expect(throws: HandOffPreparer.PrepareError.sourceUnavailable(.cameraDisconnected)) {
            try await preparer.prepare(item, as: .original)
        }

        outcome.withLock { $0 = .materialized }
        #expect(try await preparer.prepare(item, as: .original) == staged)
        #expect(preparer.readyURL(for: item, as: .original) == staged)
        #expect(preparer.readyURL(for: item, as: .handOffFile) == nil)
        #expect(!FileManager.default.fileExists(atPath: handOff.path(percentEncoded: false)))
    }

    /// One answer says whether a photo's file is ready, and the status bar counts what it
    /// does not answer. An original that is there is ready; an edit to render is not; an
    /// original missing from its folder is not either, and preparing it says why, for every
    /// action, rather than handing over a path with nothing there.
    @Test func aMissingOriginalIsNeverHandedOver() async throws {
        let directory = try makeTestDirectory()
        let root = try CatalogPath.normalizedExistingDirectoryPath(for: directory)
        try writeGradientJPEG(to: directory.appending(path: "here.jpg"))
        func item(_ name: String, _ recipe: EditRecipe = .neutral) -> EditedMediaItem {
            EditedMediaItem(
                id: MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: name)),
                isVideo: false, recipe: recipe, sourceSize: nil
            )
        }
        let preparer = HandOffPreparer(directory: directory.appending(path: "HandOff"), materialization: localOriginals)

        #expect(await preparer.needsWork([item("here.jpg"), item("gone.jpg"), item("here.jpg", EditRecipe(exposure: 1))],
                                         as: .handOffFile) == [false, true, true])
        #expect(await preparer.needsWork([item("here.jpg", EditRecipe(exposure: 1))], as: .original) == [false])
        for wanted in [HandOffPreparer.Wanted.handOffFile, .draggedFile, .original] {
            await #expect(throws: HandOffPreparer.PrepareError.originalMissing) {
                try await preparer.prepare(item("gone.jpg"), as: wanted)
            }
        }
    }

    /// An actor is reentrant, so two asks for one photo's file — a drag's promise and a
    /// Copy — each joined to the same preparation get the same file, rendered once, with
    /// nothing left behind beside it.
    @Test func twoAsksForOnePhotoShareOnePreparation() async throws {
        let directory = try makeTestDirectory()
        let url = directory.appending(path: "photo.jpg")
        try writeGradientJPEG(to: url)
        let id = try MediaAssetID(
            libraryRootPath: CatalogPath.normalizedExistingDirectoryPath(for: directory),
            relativePath: MediaRelativePath(rawValue: "photo.jpg")
        )
        let preparer = HandOffPreparer(directory: directory.appending(path: "HandOff"), materialization: localOriginals)
        let item = EditedMediaItem(id: id, isVideo: false, recipe: EditRecipe(exposure: 0.5), sourceSize: nil)

        async let first = preparer.prepare(item)
        async let second = preparer.prepare(item)
        let (a, b) = try await (first, second)

        #expect(a == b)
        let folder = a.deletingLastPathComponent()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) == ["photo.jpg"])
    }

    /// The one who cancels stops waiting at once; another ask for the same photo keeps its
    /// preparation, and receives the file when it is made. The work runs once.
    @Test func aCancelledAskLeavesThePreparationToTheOtherAsk() async throws {
        let directory = try makeTestDirectory()
        let url = directory.appending(path: "photo.jpg")
        try writeGradientJPEG(to: url)
        let id = try MediaAssetID(
            libraryRootPath: CatalogPath.normalizedExistingDirectoryPath(for: directory),
            relativePath: MediaRelativePath(rawValue: "photo.jpg")
        )
        let gate = DownloadGate { _ in true }
        let preparer = HandOffPreparer(
            directory: directory.appending(path: "HandOff"), materialization: gate.requester, status: gate.status
        )
        let item = EditedMediaItem(id: id, isVideo: false, recipe: EditRecipe(exposure: 0.5), sourceSize: nil)

        let cancelled = Task { try await preparer.prepare(item) }
        let kept = Task { try await preparer.prepare(item) }
        try await waitUntil { try await preparer.waiterCount(for: item) == 2 }
        try await waitUntil { gate.entered == 1 }

        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await preparer.waiterCount(for: item) == 1)

        gate.release()
        #expect(try await kept.value.lastPathComponent == "photo.jpg")
        #expect(gate.entered == 1)
    }

    /// Cancel stops the download in flight — the hand-off's work is cancelled, not only
    /// its bar hidden — and the lane goes on to the next hand-off. ⌘C claims the pasteboard
    /// at once, so a paste while the photo downloads pastes nothing, never what was there.
    @Test func cancelStopsAStuckDownloadAndTheLaneGoesOn() async throws {
        let gate = DownloadGate { $0.lastPathComponent.hasPrefix("cloud") }
        let ids = try makeLocalMediaIDs(["cloud.jpg"])
        let model = makeHandOffModel(gate: gate, ids: ids)
        defer { model.handOffTask?.cancel() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("handoff-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("copied before", forType: .string)
        model.selectAll()

        model.copyCurrentTargets(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == nil)
        try await waitUntil { model.handOffProgress?.total == 1 && gate.entered == 1 }
        model.cancelHandOff()
        try await waitUntil { model.hasSettledHandOffs }
        #expect(model.handOffProgress == nil)
        #expect(model.handOffAlertMessage == nil)
        #expect(pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?.isEmpty ?? true)

        gate.release()
        model.copyCurrentTargets(to: pasteboard)
        try await waitUntil { model.hasSettledHandOffs }
        #expect(pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] == [ids[0].fileURL])
    }

    /// The pasteboard is newest-wins: a Copy while another is still being prepared cancels
    /// it, and only the newer one is written.
    @Test func aNewerCopySupersedesOneStillBeingPrepared() async throws {
        let gate = DownloadGate { $0.lastPathComponent.hasPrefix("cloud") }
        let ids = try makeLocalMediaIDs(["cloud.jpg", "here.jpg"])
        let model = makeHandOffModel(gate: gate, ids: ids)
        defer { model.handOffTask?.cancel() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("handoff-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)
        model.copyCurrentTargets(to: pasteboard)
        try await waitUntil { gate.entered == 1 }
        _ = model.applyGridClick(hit: ids[1], modifiers: [], orderedIDs: ids)
        model.copyCurrentTargets(to: pasteboard)
        try await waitUntil { model.hasSettledHandOffs }

        #expect(pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] == [ids[1].fileURL])
        #expect(model.handOffAlertMessage == nil)
        #expect(gate.entered == 1)
    }

    /// A Copy that finishes after something else wrote the pasteboard leaves that alone:
    /// what the person copied since is what they paste.
    @Test func aCopyThatFinishesAfterAnotherWriteLeavesItAlone() async throws {
        let gate = DownloadGate { $0.lastPathComponent.hasPrefix("cloud") }
        let ids = try makeLocalMediaIDs(["cloud.jpg"])
        let model = makeHandOffModel(gate: gate, ids: ids)
        defer { model.handOffTask?.cancel() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("handoff-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        model.selectAll()

        model.copyCurrentTargets(to: pasteboard)
        try await waitUntil { gate.entered == 1 }
        pasteboard.clearContents()
        pasteboard.setString("copied later", forType: .string)
        gate.release()
        try await waitUntil { model.hasSettledHandOffs }

        #expect(pasteboard.string(forType: .string) == "copied later")
        #expect(pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?.isEmpty ?? true)
    }

    /// A promised photo the grid held no details for is named and written only once its
    /// details are read: an edited HEIC arrives as its rendered JPEG, under a JPEG's name,
    /// declared as an image when the drag began. A read that failed fails the promise.
    @Test func aPendingPromiseNamesTheFileItsDetailsCallFor() async throws {
        let directory = try makeTestDirectory()
        let preparer = HandOffPreparer(directory: directory.appending(path: "HandOff"), materialization: localOriginals)
        let id = MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/P"), relativePath: MediaRelativePath(rawValue: "IMG_1.HEIC"))
        let pending = PendingHandOffItem(id: id)
        let promise = HandOffPromise(.pending(pending), preparer: preparer)
        #expect(promise.fileType == UTType.image.identifier)

        pending.resolve(.success(EditedMediaItem(id: id, isVideo: false, recipe: EditRecipe(exposure: 1), sourceSize: nil)))
        #expect(promise.filePromiseProvider(promise, fileNameForType: UTType.image.identifier) == "IMG_1.jpg")

        let unread = PendingHandOffItem(id: id)
        let refused = HandOffPromise(.pending(unread), preparer: preparer)
        unread.resolve(.failure(CancellationError()))
        let delivered: (any Error)? = await withCheckedContinuation { continuation in
            refused.operationQueue(for: refused).addOperation {
                refused.filePromiseProvider(refused, writePromiseTo: directory.appending(path: "x.jpg")) {
                    continuation.resume(returning: $0)
                }
            }
        }
        #expect(delivered?.localizedDescription == "Otos couldn’t read this photo from its catalog.")
    }

    @Test func aMixedSelectionCopiesAsOneFilePerPhoto() async throws {
        try await withEditableLibrary(fileCount: 3) { library in
            let ids = library.ids
            _ = try await library.store.setEditRecipe(EditRecipe(exposure: 1), for: ids[1])
            let model = CatalogWindowViewModel(
                catalogStore: library.store,
                startsStallMonitor: false,
                startsEnrichment: false,
                startsSourceMonitoring: false,
                preferencesDomain: .suite(UUID().uuidString),
                volumeCapacity: ampleVolumeCapacity,
                trashFiles: .refusing
            )
            model.applyState(CatalogWindowState(
                title: "Hand-off",
                libraries: [],
                removableSources: [],
                mediaGrid: CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids),
                filterOptions: .empty,
                resolvedSidebarSelection: .allMedia,
                mediaEmptyState: .noMedia,
                deviceConnectionBanner: nil
            ))
            model.startHandOff(store: library.store)
            defer { model.handOffTask?.cancel() }
            model.selectAll()
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("handoff-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }

            model.copyCurrentTargets(to: pasteboard)
            try await waitUntil { model.hasSettledHandOffs }

            let urls = try #require(pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])
            #expect(urls.count == 3)
            #expect(urls[0] == ids[0].fileURL)
            #expect(urls[2] == ids[2].fileURL)
            #expect(urls[1].lastPathComponent == "edit-1.jpg")
            #expect(urls[1].path.hasPrefix(library.store.handOffDirectory.path))
            #expect(FileManager.default.fileExists(atPath: urls[1].path))
            #expect(model.handOffProgress == nil)
            #expect(model.handOffAlertMessage == nil)
        }
    }

    @Test func aPreparedFileIsReusedAndAPromiseDeliversIt() async throws {
        let directory = try makeTestDirectory()
        let url = directory.appending(path: "photo.jpg")
        try writeGradientJPEG(to: url)
        let id = try MediaAssetID(
            libraryRootPath: CatalogPath.normalizedExistingDirectoryPath(for: directory),
            relativePath: MediaRelativePath(rawValue: "photo.jpg")
        )
        let preparer = HandOffPreparer(directory: directory.appending(path: "HandOff"), materialization: localOriginals)
        let item = EditedMediaItem(id: id, isVideo: false, recipe: EditRecipe(exposure: 0.5), sourceSize: nil)

        #expect(preparer.readyURL(for: item, as: .handOffFile) == nil)
        let first = try await preparer.prepare(item)
        let second = try await preparer.prepare(item)
        #expect(first == second)
        #expect(preparer.readyURL(for: item, as: .handOffFile) == first)
        let source = try #require(CGImageSourceCreateWithURL(first as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 96 && image.height == 64)

        let promise = HandOffPromise(.item(item), preparer: preparer)
        let destination = directory.appending(path: "Dropped/photo.jpg")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        #expect(promise.filePromiseProvider(promise, fileNameForType: "public.jpeg") == "photo.jpg")
        let delivered: (any Error)? = await withCheckedContinuation { continuation in
            promise.operationQueue(for: promise).addOperation {
                promise.filePromiseProvider(promise, writePromiseTo: destination) { continuation.resume(returning: $0) }
            }
        }
        #expect(delivered == nil)
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func aTrimmedVideoIsHandedOverAsItsRange() async throws {
        let directory = try makeTestDirectory()
        let fixture = SourceTree.mediaFixtures.appending(path: "mov-no-embedded-capture-date.mov")
        let output = directory.appending(path: "trimmed.mov")

        try await MediaFileWriter.writeVideo(
            fixture, recipe: EditRecipe(trimStart: 0.2, trimEnd: 0.6), removingLocation: false, to: output
        )

        let duration = try await AVURLAsset(url: output).load(.duration)
        #expect(abs(duration.seconds - 0.4) < 0.15)
    }
}

/// A model whose hand-offs download through `gate`, over `ids`.
@MainActor
private func makeHandOffModel(gate: DownloadGate, ids: [MediaAssetID]) -> CatalogWindowViewModel {
    let store = makeTestStore(location: .inMemory)
    let model = CatalogWindowViewModel(
        catalogStore: store,
        startsStallMonitor: false,
        startsEnrichment: false,
        startsSourceMonitoring: false,
        preferencesDomain: .suite(UUID().uuidString),
        volumeCapacity: ampleVolumeCapacity,
        trashFiles: .refusing,
        handOffPreparer: HandOffPreparer(
            directory: store.handOffDirectory, materialization: gate.requester, status: gate.status
        )
    )
    model.applyState(CatalogWindowState(
        title: "Hand-off",
        libraries: [],
        removableSources: [],
        mediaGrid: CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids),
        filterOptions: .empty,
        resolvedSidebarSelection: .allMedia,
        mediaEmptyState: .noMedia,
        deviceConnectionBanner: nil
    ))
    model.startHandOff(store: store)
    return model
}

/// A cloud provider a test holds: every original `isCloud` names is a placeholder until
/// `release()`, and its download waits here until then, ending at once when its asker is
/// cancelled, as the coordinator's does.
private final class DownloadGate: Sendable {
    private struct State {
        var released = false
        var entered = 0
        var next: UInt64 = 0
        var waiters: [UInt64: CheckedContinuation<Bool, Never>] = [:]
    }

    private let state = Mutex(State())
    private let isCloud: @Sendable (URL) -> Bool

    init(isCloud: @escaping @Sendable (URL) -> Bool) {
        self.isCloud = isCloud
    }

    var entered: Int {
        state.withLock { $0.entered }
    }

    var status: @Sendable (URL) -> FileMaterializationStatus {
        { [self] url in
            guard isCloud(url), !state.withLock({ $0.released }) else {
                return FileMaterialization.status(of: url)
            }
            return .dataless
        }
    }

    var requester: ClosureMaterializationRequester {
        ClosureMaterializationRequester(status: status) { [self] _ in
            await pass()
                ? MaterializationResult(outcome: .materialized, rerequestCount: 0, elapsedMs: 0)
                : .cancelled
        }
    }

    func release() {
        let waiting = state.withLock { state in
            state.released = true
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        waiting.forEach { $0.resume(returning: true) }
    }

    private func pass() async -> Bool {
        let token = state.withLock { state in
            state.next += 1
            return state.next
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let now: Bool? = state.withLock { state in
                    state.entered += 1
                    if state.released {
                        return true
                    }
                    if Task.isCancelled {
                        return false
                    }
                    state.waiters[token] = continuation
                    return nil
                }
                if let now {
                    continuation.resume(returning: now)
                }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: token) }?.resume(returning: false)
        }
    }
}
