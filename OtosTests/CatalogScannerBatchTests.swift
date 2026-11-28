import Foundation
@testable import OtosKit
import Testing

/// How a walk hands its files to the Store: its first `CatalogScanner.firstBatchCount` files
/// at once, the rest on the cadence, so a new library's first rows are written in tens of
/// milliseconds rather than after a cadence's worth of files
/// (`docs/research/2026-11-17-a-new-library-at-the-reference-size.md`).
@Suite(.testScope)
struct CatalogScannerBatchTests {
    // Validates: ARC-019
    /// With a cadence that never elapses, the first batch is cut by its count alone and the
    /// rest goes out at the walk's end: no time decides either.
    @Test func aWalksFirstBatchGoesOutAtItsCountAndTheRestOnTheCadence() async throws {
        let root = try makeTestDirectory().appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileCount = CatalogScanner.firstBatchCount + 44
        for index in 0 ..< fileCount {
            try writeCatalogStoreFile(root.appending(path: "photo-\(index).jpg"), contents: "jpeg")
        }
        let batches = BatchSizes()

        let observation = try await CatalogScanner.live.scanRoot(
            CatalogPath.normalizedDirectoryPath(for: root),
            .seconds(3600)
        ) { batch in
            await batches.record(batch.count)
        }

        #expect(observation.mediaPaths.count == fileCount)
        #expect(await batches.sizes == [CatalogScanner.firstBatchCount, 44])
    }

    // Validates: ARC-019
    /// A walk with fewer files than a first batch hands them over once, at its end.
    @Test func aWalkSmallerThanAFirstBatchHandsItsFilesOverOnce() async throws {
        let root = try makeTestDirectory().appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0 ..< 3 {
            try writeCatalogStoreFile(root.appending(path: "photo-\(index).jpg"), contents: "jpeg")
        }
        let batches = BatchSizes()

        _ = try await CatalogScanner.live.scanRoot(CatalogPath.normalizedDirectoryPath(for: root), .seconds(3600)) { batch in
            await batches.record(batch.count)
        }

        #expect(await batches.sizes == [3])
    }
}

private actor BatchSizes {
    private(set) var sizes: [Int] = []

    func record(_ size: Int) {
        sizes.append(size)
    }
}
