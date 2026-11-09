import AppKit
import AVFoundation
import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// ADR 0037: a hand-off is one full-size file per photo — the original for an
/// unedited still or video, a rendered JPEG for an edited photo or a RAW, the trimmed range
/// of a trimmed video.
/// The fixtures are local files, so nothing is ever fetched.
private let localOriginals = ClosureMaterializationRequester { _ in .cancelled }

@Suite(.testDirectory)
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

    /// The owner's acceptance case: several photos, some edited and some not, copied and
    /// pasted, arrive as one file per photo in display order — the edited one as its
    /// rendered JPEG, the others as their originals.
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

    /// A hand-off that failed for space says so, and never blames the original for it.
    @Test func aHandOffThatFailedForSpaceSaysSo() {
        #expect(HandOffFailures(outOfSpace: 0, other: 1).alertMessage(for: .openDefault)
            == "One photo couldn’t be prepared, so nothing was handed over. Its original may be unavailable.")
        #expect(HandOffFailures(outOfSpace: 1, other: 0).alertMessage(for: .openDefault)
            == "There isn’t enough disk space to prepare one photo, so nothing was handed over. Free up space and try again.")
        #expect(HandOffFailures(outOfSpace: 2, other: 1).alertMessage(for: .openDefault)
            == "There isn’t enough disk space to prepare 2 photos, and one photo couldn’t be prepared because its "
            + "original may be unavailable. Nothing was handed over. Free up space and try again.")
    }

    /// ADR 0046 §6: a source that cannot send an original is named, by the name the sidebar
    /// shows, in its own terms; other causes keep their own wording after it. A reveal says
    /// nothing was revealed.
    @Test func aHandOffThatFailedOfflineNamesTheSource() {
        let family = LibraryRootPath(rawValue: "/RemoteStaging/family")
        let camera = LibraryRootPath(rawValue: "/DeviceStaging/eos")
        var failures = HandOffFailures()
        failures.recordUnavailable(rootPath: family, name: "Family", reason: .serverNotAnswering)
        #expect(failures.alertMessage(for: .openDefault)
            == "“Family” isn’t answering, so one photo couldn’t be downloaded. Nothing was handed over.")
        #expect(failures.alertMessage(for: .revealInFinder)
            == "“Family” isn’t answering, so one photo couldn’t be downloaded. Nothing was revealed.")
        failures.recordUnavailable(rootPath: family, name: "Family", reason: .serverNotAnswering)
        failures.recordUnavailable(rootPath: camera, name: "EOS R5", reason: .cameraDisconnected)
        failures.other = 1
        #expect(failures.count == 4)
        #expect(failures.alertMessage(for: .openDefault)
            == "“Family” isn’t answering, so 2 photos couldn’t be downloaded. “EOS R5” isn’t connected, so one photo "
            + "couldn’t be copied from it. One photo couldn’t be prepared, so nothing was handed over. "
            + "Its original may be unavailable.")
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
        #expect(preparer.readyURL(for: item) == nil)

        await #expect(throws: HandOffPreparer.PrepareError.sourceUnavailable(.serverNotAnswering)) {
            try await preparer.prepare(item)
        }
        let promise = HandOffPromise(item: item, preparer: preparer, reader: nil)
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
        #expect(preparer.readyURL(for: item) == staged)
        #expect(await deliver() == nil)
        #expect(FileManager.default.contents(atPath: dropped.path(percentEncoded: false)) == Data("jpeg".utf8))
        // A staged original is fetched once; after that it is handed over as it is.
        #expect(requests.withLock { $0 } == 4)
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
        #expect(preparer.readyOriginalURL(for: item) == nil)

        await #expect(throws: HandOffPreparer.PrepareError.sourceUnavailable(.cameraDisconnected)) {
            try await preparer.original(for: item)
        }

        outcome.withLock { $0 = .materialized }
        #expect(try await preparer.original(for: item) == staged)
        #expect(preparer.readyOriginalURL(for: item) == staged)
        #expect(preparer.readyURL(for: item) == nil)
        #expect(!FileManager.default.fileExists(atPath: handOff.path(percentEncoded: false)))
    }

    /// A write that fails for a reason other than space keeps that reason: writing into a
    /// missing folder is not reported as a full disk.
    @Test func aWriteThatFailsForAnotherReasonIsNotAFullDisk() async throws {
        let image = try #require(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage())
        let missing = try makeTestDirectory().appending(path: "absent/edit.jpg")
        do {
            try await MediaFileWriter.writeImage(
                image, as: .jpeg, quality: 0.9, metadataOf: missing, removingLocation: false, to: missing
            )
            Issue.record("expected the write into a missing folder to fail")
        } catch {
            #expect(error as? MediaFileWriter.WriteError != .outOfSpace)
            #expect(!FreeSpaceFloor.refusedForSpace(error))
        }
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

        #expect(preparer.readyURL(for: item) == nil)
        let first = try await preparer.prepare(item)
        let second = try await preparer.prepare(item)
        #expect(first == second)
        #expect(preparer.readyURL(for: item) == first)
        let source = try #require(CGImageSourceCreateWithURL(first as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 96 && image.height == 64)

        let promise = HandOffPromise(item: item, preparer: preparer, reader: nil)
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
