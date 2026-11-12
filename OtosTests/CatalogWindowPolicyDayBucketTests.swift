import Foundation
@testable import OtosKit
import Testing

/// `CatalogWindowPolicy.assetIDs` filters `orderedAssetIDs` by availability/scope
/// and must drop the paired `dayBuckets` entry in the same pass (DES-069) so the
/// two arrays never desync.
struct CatalogWindowPolicyDayBucketTests {
    private static let keptPath = LibraryRootPath(rawValue: "/Kept")
    private static let droppedPath = LibraryRootPath(rawValue: "/Dropped")

    @Test func filteringDropsPairedDayBucketAtTheSameIndex() {
        let dayOne = Date(timeIntervalSince1970: 0)
        let dayTwo = Date(timeIntervalSince1970: 86400)
        let kept = dayBucketAssetID(root: Self.keptPath, path: "a.jpg")
        let dropped = dayBucketAssetID(root: Self.droppedPath, path: "b.jpg")
        let keptAgain = dayBucketAssetID(root: Self.keptPath, path: "c.jpg")

        let result = CatalogWindowPolicy.assetIDs(
            for: .allMedia,
            orderedAssetIDs: [kept, dropped, keptAgain],
            dayBuckets: [dayOne, dayTwo, nil],
            availableLibraryPaths: [Self.keptPath, Self.droppedPath],
            rootsByPath: [
                Self.keptPath: dayBucketLibraryState(path: Self.keptPath, kind: .library),
                Self.droppedPath: dayBucketLibraryState(path: Self.droppedPath, kind: .deviceMTP),
            ]
        )

        #expect(result.ids == [kept, keptAgain])
        #expect(result.dayBuckets == [dayOne, nil])
    }
}

private func dayBucketAssetID(root: LibraryRootPath, path: String) -> MediaAssetID {
    MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: path))
}

private func dayBucketLibraryState(path: LibraryRootPath, kind: LibraryRootKind) -> CatalogLibraryState {
    CatalogLibraryState(
        root: LibraryRoot(path: path, kind: kind, deviceIdentity: nil, displayName: path.rawValue),
        availability: .available,
        activity: .idle,
        isEjectable: false
    )
}
