import Foundation
@testable import OtosKit
import Testing

/// ADR 0052 through the Store: a RAW and its JPEG are read as one stack with the order,
/// whatever the filter, and the user's key choice is kept on the member it names.
@Suite(.testDirectory)
@MainActor
struct PhotoStackStoreTests {
    @Test func theOrderIsReadWithItsPairs() async throws {
        try await withLibrary(["a/DSC1.ARW", "a/DSC1.JPG", "a/DSC2.JPG", "b/DSC1.JPG"]) { library in
            let ordered = try await library.ordered()
            #expect(ordered.ids.count == 4)
            let pair = try #require(ordered.stacks.stack(containing: library.id("a/DSC1.ARW")))
            #expect(Set(pair.members) == [library.id("a/DSC1.ARW"), library.id("a/DSC1.JPG")])
            #expect(pair.key == library.id("a/DSC1.JPG"))
            #expect(ordered.stacks.stack(containing: library.id("b/DSC1.JPG")) == nil)
            #expect(ordered.stacks.stack(containing: library.id("a/DSC2.JPG")) == nil)
        }
    }

    /// A filter that shows only RAWs still reads the pair, so the RAW is known to be one.
    @Test func aFilterNeverUnpairs() async throws {
        try await withLibrary(["DSC1.ARW", "DSC1.JPG"]) { library in
            let ordered = try await library.ordered(kinds: [.raw])
            #expect(ordered.ids == [library.id("DSC1.ARW")])
            #expect(ordered.stacks.stack(containing: library.id("DSC1.ARW")) != nil)
        }
    }

    @Test func makeKeyPhotoIsKeptOnTheChosenMemberAndUndoes() async throws {
        try await withLibrary(["DSC1.ARW", "DSC1.JPG"]) { library in
            let raw = library.id("DSC1.ARW"), jpeg = library.id("DSC1.JPG")
            let previous = try await library.store.setStackKeyChoices([raw: 1000, jpeg: nil])
            #expect(previous == [raw: Int64?.none, jpeg: Int64?.none])
            #expect(try await library.ordered().stacks.stack(containing: jpeg)?.key == raw)

            _ = try await library.store.setStackKeyChoices(previous)
            #expect(try await library.ordered().stacks.stack(containing: jpeg)?.key == jpeg)
        }
    }

    private struct Library {
        let store: CatalogStore
        let rootPath: LibraryRootPath

        func id(_ path: String) -> MediaAssetID {
            MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: path))
        }

        func ordered(kinds: Set<MediaKind> = []) async throws -> CatalogOrderedAssets {
            try await store.orderedAssetIDs(
                for: CatalogQueryDescriptor(scope: .library(rootPath), filter: MediaFilter(kinds: kinds)),
                availableLibraryPaths: [rootPath]
            )
        }
    }

    private func withLibrary(_ files: [String], _ body: (Library) async throws -> Void) async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Photos", directoryHint: .isDirectory)
        for file in files {
            let url = root.appending(path: file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(file.utf8).write(to: url)
        }
        let databaseURL = temp.appending(path: "Catalog/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let store = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(5))
        do {
            try await store.addLibrary(url: root)
            let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning }
            try #require(scanned.testAssets.count == files.count)
            let rootPath = try CatalogPath.normalizedExistingDirectoryPath(for: root)
            try await body(Library(store: store, rootPath: rootPath))
        } catch {
            await store.shutdown()
            throw error
        }
        await store.shutdown()
    }
}
