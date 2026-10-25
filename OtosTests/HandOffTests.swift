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
