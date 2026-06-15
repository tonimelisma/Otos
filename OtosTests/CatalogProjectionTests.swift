import Foundation
@testable import Otos
import Testing

struct CatalogProjectionTests {
    @Test func projectionSortsRootsAndAssets() async {
        let pictures = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures"))
        let archive = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Archive"))
        let projection = CatalogProjection(diagnostics: nil)
        let snapshot = CatalogSnapshot(
            roots: [pictures, archive],
            assets: [
                makeAsset(root: pictures, relativePath: "z.jpg"),
                makeAsset(root: archive, relativePath: "b.jpg"),
                makeAsset(root: archive, relativePath: "a.jpg"),
            ],
            scanningRootPaths: []
        )

        let sorted = await projection.sortedSnapshot(from: snapshot)

        #expect(sorted.roots.map(\.displayName) == ["Archive", "Pictures"])
        #expect(sorted.assets.map(\.relativePath.rawValue) == ["a.jpg", "b.jpg", "z.jpg"])
    }

    @Test func browserProjectionFiltersAssetsForSelection() async {
        let pictures = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures"))
        let archive = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Archive"))
        let projection = CatalogProjection(diagnostics: nil)
        let snapshot = await projection.sortedSnapshot(
            from: CatalogSnapshot(
                roots: [pictures, archive],
                assets: [
                    makeAsset(root: pictures, relativePath: "one.jpg"),
                    makeAsset(root: archive, relativePath: "two.jpg"),
                ],
                scanningRootPaths: []
            )
        )

        let browserProjection = await projection.browserProjection(
            snapshot: snapshot,
            selection: .library(pictures.path)
        )

        #expect(browserProjection.title == "Pictures")
        #expect(browserProjection.assetsForSelection.map(\.relativePath.rawValue) == ["one.jpg"])
    }

    @MainActor
    @Test func browserStateFallsBackWhenSelectedLibraryIsRemoved() {
        let projection = CatalogProjection(diagnostics: nil)
        let browserState = CatalogBrowserState(catalogProjection: projection)
        let pictures = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures"))

        browserState.selection = .library(pictures.path)
        browserState.update(snapshot: .empty)

        #expect(browserState.selection == .allMedia)
    }

    @MainActor
    @Test func browserStateKeepsLatestProjection() async throws {
        let projection = CatalogProjection(diagnostics: nil)
        let browserState = CatalogBrowserState(catalogProjection: projection)
        let pictures = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures"))
        let archive = LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Archive"))

        browserState.update(
            snapshot: CatalogSnapshot(
                roots: [pictures],
                assets: [makeAsset(root: pictures, relativePath: "old.jpg")],
                scanningRootPaths: []
            )
        )
        browserState.selection = .library(archive.path)
        browserState.update(
            snapshot: CatalogSnapshot(
                roots: [archive],
                assets: [makeAsset(root: archive, relativePath: "new.jpg")],
                scanningRootPaths: []
            )
        )

        let projected = try await waitForBrowserProjection(browserState) { projection in
            projection.assetsForSelection.map(\.relativePath.rawValue) == ["new.jpg"]
        }
        #expect(projected.title == "Archive")
    }
}

private func makeAsset(root: LibraryRoot, relativePath: String) -> MediaAsset {
    MediaAsset(
        libraryRootPath: root.path,
        libraryDisplayName: root.displayName,
        relativePath: MediaRelativePath(rawValue: relativePath),
        name: URL(fileURLWithPath: relativePath).lastPathComponent,
        contentTypeIdentifier: "public.jpeg",
        byteSize: 1,
        createdAt: Date(timeIntervalSince1970: 10),
        contentModifiedAt: Date(timeIntervalSince1970: 20)
    )
}

@MainActor
private func waitForBrowserProjection(
    _ browserState: CatalogBrowserState,
    predicate: (CatalogBrowserProjection) -> Bool
) async throws -> CatalogBrowserProjection {
    for _ in 0 ..< 100 {
        let projection = browserState.projection
        if predicate(projection) {
            return projection
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw CatalogProjectionTestError.timedOut
}

private enum CatalogProjectionTestError: Error {
    case timedOut
}
