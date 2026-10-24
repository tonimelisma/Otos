import Foundation
@testable import OtosKit
import Testing

/// A library of one-byte `.jpg` files in the test's directory, cataloged by an
/// in-memory store, for view-model tests that need real catalog rows behind real files.
/// Needs the `.testDirectory` trait.
struct CatalogedLibrary {
    let store: CatalogStore
    let root: URL
    let rootPath: LibraryRootPath
    /// One per file, in file-name order: `<prefix>-0.jpg`, `<prefix>-1.jpg`, …
    let ids: [MediaAssetID]

    func path(_ id: MediaAssetID) -> String {
        root.appending(path: id.relativePath.rawValue).path
    }
}

/// Runs `body` against a freshly cataloged library of `fileCount` files and shuts the
/// store down after it on every exit, so no store or scan outlives its test.
func withCatalogedLibrary(
    fileCount: Int,
    fileNamePrefix: String = "choice",
    isolation: isolated (any Actor)? = #isolation,
    _ body: (CatalogedLibrary) async throws -> Void
) async throws {
    let root = try makeTestDirectory()
    let names = (0 ..< fileCount).map { "\(fileNamePrefix)-\($0).jpg" }
    for name in names {
        try Data([0]).write(to: root.appending(path: name))
    }
    let rootPath = try CatalogPath.normalizedExistingDirectoryPath(for: root)
    let ids = names.map { MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: $0)) }
    let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(5))
    do {
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try #require(Set(scanned.testAssets.map(\.id)) == Set(ids), "the library scan cataloged \(scanned.testAssets.map(\.id))")
        try await body(CatalogedLibrary(store: store, root: root, rootPath: rootPath, ids: ids))
    } catch {
        await store.shutdown()
        throw error
    }
    await store.shutdown()
}
