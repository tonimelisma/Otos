import Foundation
@testable import OtosKit
import Testing

/// ARC-047: device inventory landing must trigger a replan.
/// `recordSourceListingBatch`/`completeSourceListing` bump the occupancy
/// revision and emit a `RootPlanningChange`; without that, a plan built the moment a
/// device root became available (from whatever rows were already persisted) would
/// never be invalidated once the live device inventory landed.
@Suite(.testDirectory)
struct CatalogStoreDeviceInventoryTests {
    @Test func changedBatchEmitsPlanningChangeForDeviceRoot() async throws {
        let temp = try makeTestDirectory()
        let stagingRoot = temp.appending(path: "DeviceStaging/Camera", directoryHint: .isDirectory)
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)

        let rootPath = try await store.attachDeviceMTP(
            stagingRootURL: stagingRoot,
            identity: .camera(id: "serial"),
            displayName: "Camera"
        )
        let changes = await store.planningChangeNotifications()
        var iterator = changes.makeAsyncIterator()

        let scan = try await store.beginSourceListing(rootPath: rootPath)
        let occupancyBeforeBatch = await store.namespaceRevision(for: rootPath)
        try await store.recordSourceListingBatch([
            ScannedMediaFile(
                relativePath: MediaRelativePath(rawValue: "DCIM/IMG_0001.JPG"),
                name: "IMG_0001.JPG",
                contentTypeIdentifier: "public.jpeg",
                byteSize: 42,
                createdAt: Date(timeIntervalSince1970: 1000),
                contentModifiedAt: Date(timeIntervalSince1970: 1000)
            ),
        ], scan: scan)

        let change = await iterator.next()
        #expect(change?.rootPath == rootPath)
        let occupancyAfterBatch = await store.namespaceRevision(for: rootPath)
        #expect(occupancyAfterBatch != occupancyBeforeBatch)
        #expect(change?.namespaceRevision == occupancyAfterBatch)
    }

    @Test func completionAlwaysEmitsPlanningChangeEvenWithoutRowChanges() async throws {
        let temp = try makeTestDirectory()
        let stagingRoot = temp.appending(path: "DeviceStaging/Camera", directoryHint: .isDirectory)
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)

        let rootPath = try await store.attachDeviceMTP(
            stagingRootURL: stagingRoot,
            identity: .camera(id: "serial"),
            displayName: "Camera"
        )
        let scan = try await store.beginSourceListing(rootPath: rootPath)
        // No batch recorded — an enumeration that observed nothing new still
        // must prove itself stable to whoever built a plan before it finished.
        let occupancyBeforeCompletion = await store.namespaceRevision(for: rootPath)

        let changes = await store.planningChangeNotifications()
        var iterator = changes.makeAsyncIterator()
        try await store.completeSourceListing(scan: scan, observedPaths: [])

        let change = await iterator.next()
        #expect(change?.rootPath == rootPath)
        let occupancyAfterCompletion = await store.namespaceRevision(for: rootPath)
        #expect(occupancyAfterCompletion != occupancyBeforeCompletion)
        #expect(change?.namespaceRevision == occupancyAfterCompletion)
    }
}
