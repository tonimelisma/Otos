import AppKit
import AVFoundation
import Foundation
@testable import OtosKit
import Testing

/// ADR 0037: a hand-off is one full-size file per photo — the original for an
/// unedited still or video, a rendered JPEG for an edited photo or a RAW, the trimmed range
/// of a trimmed video.
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
        #expect(HandOffFailures(outOfSpace: 0, other: 1).alertMessage
            == "One photo couldn’t be prepared, so nothing was handed over. Its original may be unavailable.")
        #expect(HandOffFailures(outOfSpace: 1, other: 0).alertMessage
            == "There isn’t enough disk space to prepare one photo, so nothing was handed over. Free up space and try again.")
        #expect(HandOffFailures(outOfSpace: 2, other: 1).alertMessage
            == "There isn’t enough disk space to prepare 2 photos, and one photo couldn’t be prepared because its "
            + "original may be unavailable. Nothing was handed over. Free up space and try again.")
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
        let preparer = HandOffPreparer(directory: directory.appending(path: "HandOff"), materialization: nil)
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
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/Media/mov-no-embedded-capture-date.mov")
        let output = directory.appending(path: "trimmed.mov")

        try await MediaFileWriter.writeVideo(
            fixture, recipe: EditRecipe(trimStart: 0.2, trimEnd: 0.6), removingLocation: false, to: output
        )

        let duration = try await AVURLAsset(url: output).load(.duration)
        #expect(abs(duration.seconds - 0.4) < 0.15)
    }
}
