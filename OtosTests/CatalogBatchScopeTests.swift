import Foundation
import GRDB
@testable import OtosKit
import Testing

/// An Imports row narrows by root *and* by batch stamp. These cover the seam where
/// those two dimensions used to be resolved separately: ordered IDs applied the
/// stamp, while counts quietly did not, so a batch whose rows an active filter
/// excluded reported "no media at all" and withheld Clear Filters.
///
/// Store answers *what the scope holds*; `CatalogWindowPolicy` turns that into
/// *what the window says*. They are tested at their own boundaries.
@Suite(.testScope)
struct CatalogBatchScopeTests {
    private static let batch = ImportBatchID(unixMilliseconds: 1_785_908_514_176)

    // Validates: ARC-022, ARC-044, APP-025
    /// Every scoped read agrees about the batch: ordering, both counts and the filter's
    /// choices, so a batch of videos offers no stills it does not hold (APP-025).
    @Test func everyScopedReadAppliesBatchMembership() async throws {
        let temp = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "clip-one.mp4"), contents: "one")
        try writeCatalogStoreFile(root.appending(path: "clip-two.mp4"), contents: "two")
        try writeCatalogStoreFile(root.appending(path: "earlier.heic"), contents: "still")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let store = makeTestStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 3 }
        try await stampBatch(databaseURL: databaseURL, relativePaths: ["clip-one.mp4", "clip-two.mp4"])
        let rootPath = try #require(await store.currentLibraries().first { $0.kind == .library }?.path)
        let available: Set<LibraryRootPath> = [rootPath]
        let batchScope = SidebarSelection.importBatch(Self.batch)

        let batchIDs = try await store.windowReads.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: batchScope),
            availableLibraryPaths: available
        ).ids
        let hiddenByFilter = try await store.windowReads.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: batchScope, filter: Self.heifOnly),
            availableLibraryPaths: available
        ).ids
        let batchVisibleCount = try await store.windowReads.visibleAssetCount(
            for: batchScope,
            availableLibraryPaths: available
        )
        let batchCatalogedCount = try await store.windowReads.catalogedAssetCount(for: batchScope)
        let libraryCatalogedCount = try await store.windowReads.catalogedAssetCount(for: .library(rootPath))
        // The options are the shown row's: the batch offers its clips' type alone, the
        // library every type it holds.
        let batchOptions = try await store.windowReads.filterOptionTally(for: batchScope, availableLibraryPaths: available, placeNameLanguages: []).options
        let options = try await store.windowReads.filterOptionTally(for: .library(rootPath), availableLibraryPaths: available, placeNameLanguages: []).options
        await store.shutdown()

        #expect(Set(batchIDs.map(\.relativePath.rawValue)) == ["clip-one.mp4", "clip-two.mp4"])
        #expect(hiddenByFilter.isEmpty)
        // Each of these was 0 / the whole library before the scope had one owner.
        #expect(batchVisibleCount == 2)
        #expect(batchCatalogedCount == 2)
        #expect(libraryCatalogedCount == 3)
        #expect(batchOptions.formatsByKind == [.video: [MediaFormatToken(rawValue: "MP4")]])
        #expect(options.formatsByKind[.video] == [MediaFormatToken(rawValue: "MP4")])
        #expect(options.formatsByKind[.image] == [MediaFormatToken(rawValue: "HEIF")])
    }

    private static let heifOnly = MediaFilter(fileTypes: [FilterFileType(kind: .image, format: MediaFormatToken(rawValue: "HEIF"))])

    // Validates: ARC-022, ARC-044
    /// The reported case: an active HEIC-only filter hides both imported clips. The
    /// batch is not empty, so the window must offer Clear Filters instead of telling
    /// the user to add a library.
    @Test func batchEmptiedByFilterReportsNoFilterMatches() {
        let descriptor = CatalogQueryDescriptor(
            scope: .importBatch(Self.batch),
            filter: Self.heifOnly
        )

        let emptyState = CatalogWindowPolicy.mediaEmptyState(
            for: descriptor,
            libraries: [libraryState(availability: .available)],
            allAssetCount: 2,
            unfilteredVisibleAssetCount: 2,
            selectedAssetCount: 0
        )

        #expect(emptyState == .noFilterMatches)
    }

    // Validates: ARC-044
    /// A batch spans the fixed libraries, so when they are unreachable its rows are
    /// unreachable rather than absent — the same distinction All Media draws.
    @Test func batchWithUnreachableLibrariesReportsUnavailableNotEmpty() {
        let descriptor = CatalogQueryDescriptor(scope: .importBatch(Self.batch))

        let unreachable = CatalogWindowPolicy.mediaEmptyState(
            for: descriptor,
            libraries: [libraryState(availability: .unavailable)],
            allAssetCount: 2,
            unfilteredVisibleAssetCount: 0,
            selectedAssetCount: 0
        )
        let stillChecking = CatalogWindowPolicy.mediaEmptyState(
            for: descriptor,
            libraries: [libraryState(availability: .unknown)],
            allAssetCount: 2,
            unfilteredVisibleAssetCount: 0,
            selectedAssetCount: 0
        )

        #expect(unreachable == .noAvailableMedia)
        #expect(stillChecking == .checkingLibraries)
    }

    // MARK: - Fixtures

    private func libraryState(availability: LibraryAvailability) -> CatalogLibraryState {
        CatalogLibraryState(
            root: LibraryRoot(
                path: LibraryRootPath(rawValue: "/Pictures"),
                kind: .library,
                deviceIdentity: nil,
                displayName: "Pictures"
            ),
            availability: availability,
            activity: .idle,
            isEjectable: false
        )
    }

    private func stampBatch(databaseURL: URL, relativePaths: [String]) async throws {
        try await makeTestDatabaseQueue(path: databaseURL.path(percentEncoded: false)).write { db in
            for relativePath in relativePaths {
                try db.execute(
                    sql: "UPDATE media_asset SET import_batch_unix_ms = ? WHERE relative_path = ?",
                    arguments: [Self.batch.unixMilliseconds, relativePath]
                )
            }
        }
    }
}
