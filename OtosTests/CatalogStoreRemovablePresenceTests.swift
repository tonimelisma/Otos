import Foundation
@testable import OtosKit
import Testing

/// APP-016–018 / ADR 0013: a card or camera shows what its current attachment has read,
/// as it reads it — never what it held last time — and an erase takes its files out of
/// the catalog as it takes them off the card.
@Suite(.testDirectory)
struct CatalogStoreRemovablePresenceTests {
    private let identity = DeviceIdentity.camera(id: "presence-serial")

    private func file(_ name: String) -> ScannedMediaFile {
        ScannedMediaFile(
            relativePath: MediaRelativePath(rawValue: "DCIM/\(name)"),
            name: name,
            contentTypeIdentifier: "public.jpeg",
            byteSize: 42,
            createdAt: Date(timeIntervalSince1970: 1000),
            contentModifiedAt: Date(timeIntervalSince1970: 1000)
        )
    }

    /// Attaches the camera and completes one enumeration holding `files`.
    private func attachEnumerated(
        _ store: CatalogStore,
        staging: URL,
        files: [ScannedMediaFile]
    ) async throws -> LibraryRootPath {
        let rootPath = try await store.attachDeviceMTP(
            stagingRootURL: staging, identity: identity, displayName: "Camera"
        )
        let scan = try await store.beginSourceListing(rootPath: rootPath)
        try await store.recordSourceListingBatch(files, scan: scan)
        try await store.completeSourceListing(scan: scan, observedPaths: Set(files.map(\.relativePath)))
        return rootPath
    }

    @Test func aReturningSourceShowsOnlyTheFilesItsCurrentReadHasSeen() async throws {
        let staging = try makeTestDirectory().appending(path: "DeviceStaging/Camera", directoryHint: .isDirectory)
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        let kept = file("IMG_0001.JPG"), erased = file("IMG_0002.JPG")
        let rootPath = try await attachEnumerated(store, staging: staging, files: [kept, erased])
        try await store.detachRemovableSource(identity: identity, reason: .disconnected)

        _ = try await store.attachDeviceMTP(stagingRootURL: staging, identity: identity, displayName: "Camera")
        // Attached, nothing read yet: the rows it held last time are not shown as present.
        #expect(try await visiblePaths(store, rootPath).isEmpty)
        let scan = try await store.beginSourceListing(rootPath: rootPath)
        try await store.recordSourceListingBatch([kept], scan: scan)
        // A file the read has reached shows at once, before the read completes.
        #expect(try await visiblePaths(store, rootPath) == [kept.relativePath.rawValue])
        try await store.completeSourceListing(scan: scan, observedPaths: [kept.relativePath])

        #expect(try await visiblePaths(store, rootPath) == [kept.relativePath.rawValue])
        #expect(try await store.catalogedAssetCount(for: .library(rootPath)) == 1)
        await store.shutdown()
    }

    @Test func aReadCutShortByDetachLeavesTheOfflineSourceShowingWhatItLastHeld() async throws {
        let staging = try makeTestDirectory().appending(path: "DeviceStaging/Camera", directoryHint: .isDirectory)
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        let first = file("IMG_0001.JPG"), second = file("IMG_0002.JPG")
        let rootPath = try await attachEnumerated(store, staging: staging, files: [first, second])
        try await store.detachRemovableSource(identity: identity, reason: .disconnected)

        _ = try await store.attachDeviceMTP(stagingRootURL: staging, identity: identity, displayName: "Camera")
        let scan = try await store.beginSourceListing(rootPath: rootPath)
        try await store.recordSourceListingBatch([first], scan: scan)
        try await store.detachRemovableSource(identity: identity, reason: .disconnected)

        // Nothing proved the second file gone, so the offline camera still holds both.
        #expect(try await store.catalogedAssetCount(for: .library(rootPath)) == 2)
        await store.shutdown()
    }

    /// ADR 0032 rule 4: a read that ends without completing proved neither presence nor
    /// absence, so the source shows the rows it last held rather than a fabricated
    /// partial — or empty — card.
    @Test func aReadThatEndsIncompleteShowsTheRowsTheSourceLastHeld() async throws {
        let staging = try makeTestDirectory().appending(path: "DeviceStaging/Camera", directoryHint: .isDirectory)
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        let first = file("IMG_0001.JPG"), second = file("IMG_0002.JPG")
        let rootPath = try await attachEnumerated(store, staging: staging, files: [first, second])
        try await store.detachRemovableSource(identity: identity, reason: .disconnected)
        _ = try await store.attachDeviceMTP(stagingRootURL: staging, identity: identity, displayName: "Camera")
        let scan = try await store.beginSourceListing(rootPath: rootPath)
        try await store.recordSourceListingBatch([first], scan: scan)

        await store.endSourceListing(scan: scan)

        #expect(try await visiblePaths(store, rootPath) == [first, second].map(\.relativePath.rawValue))
        await store.shutdown()
    }

    /// `.alreadyGone` removes a row and its overlay, so it needs proof: the card mounted
    /// and the path answering ENOENT. A card that is not mounted proves nothing.
    @Test func anEraseOnlyCallsAFileGoneWhenTheMountedCardSaysSo() async throws {
        let temp = try makeTestDirectory()
        let mounted = LibraryRootPath(rawValue: temp.appending(path: "Card").path(percentEncoded: false))
        try FileManager.default.createDirectory(at: mounted.url, withIntermediateDirectories: true)
        let unmounted = LibraryRootPath(rawValue: temp.appending(path: "Ejected").path(percentEncoded: false))
        let path = MediaRelativePath(rawValue: "DCIM/IMG_0001.JPG")
        func erase(_ root: LibraryRootPath) async -> SourceEraseOutcome {
            await SourceEraser.erase(
                kind: .removableVolume,
                identity: .volume(uuid: "presence-erase"),
                rootPath: root,
                relativePath: path,
                filesystemURL: root.url.appending(path: path.rawValue),
                cameraImport: nil
            )
        }

        #expect(await erase(mounted) == .alreadyGone)
        #expect(await erase(unmounted) == .failed)
    }

    @Test func aProcessThatEndedMidReadLeavesNoRowHiddenAtTheNextLaunch() async throws {
        let temp = try makeTestDirectory()
        let database = temp.appending(path: "catalog.sqlite")
        let staging = temp.appending(path: "DeviceStaging/Camera", directoryHint: .isDirectory)
        let first = CatalogStore(location: .databaseFile(database))
        try await first.start(scansSavedLibraries: false)
        let rootPath = try await attachEnumerated(first, staging: staging, files: [file("IMG_0001.JPG")])
        try await first.detachRemovableSource(identity: identity, reason: .disconnected)
        _ = try await first.attachDeviceMTP(stagingRootURL: staging, identity: identity, displayName: "Camera")
        await first.shutdown()

        let relaunched = CatalogStore(location: .databaseFile(database))
        try await relaunched.start(scansSavedLibraries: false)
        #expect(try await relaunched.catalogedAssetCount(for: .library(rootPath)) == 1)
        await relaunched.shutdown()
    }

    @Test func anErasedFileLeavesTheCatalogTogetherWithItsJournal() async throws {
        let staging = try makeTestDirectory().appending(path: "DeviceStaging/Camera", directoryHint: .isDirectory)
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        let kept = file("IMG_0001.JPG"), erased = file("IMG_0002.JPG")
        let rootPath = try await attachEnumerated(store, staging: staging, files: [kept, erased])
        let before = try #require(await store.planningRevisions(for: rootPath))
        let operation = ActiveSourceEraseOperation(
            key: .make(),
            sourceKind: .deviceMTP,
            sourceDeviceIdentity: identity,
            sourceRootPath: rootPath,
            sourceRelativePath: erased.relativePath,
            sourceByteSize: erased.byteSize,
            updatedAt: Date()
        )
        try await store.beginSourceEraseOperation(operation)

        try await store.recordSourceFileErased(operation)

        #expect(try await visiblePaths(store, rootPath) == [kept.relativePath.rawValue])
        #expect(try await store.catalogedAssetCount(for: .library(rootPath)) == 1)
        #expect(try await store.activeSourceEraseOperations().isEmpty)
        // The card's contents changed, so a plan built before the erase is stale.
        let after = try #require(await store.planningRevisions(for: rootPath))
        #expect(after.namespaceRevision > before.namespaceRevision)
        await store.shutdown()
    }

    /// Field trace 2026-11-06: an inserted card waited 12.8 s for a launch rescan of a
    /// 16,000-file library before its own one-second scan began.
    @Test func aCardIsReadWhileALibraryRescanHoldsTheLibraryLane() async throws {
        let temp = try makeTestDirectory()
        let libraryRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardRoot = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardRoot, withIntermediateDirectories: true)
        try writeCatalogStoreFile(cardRoot.appending(path: "card.jpg"), contents: "jpeg")
        let libraryPath = try CatalogPath.normalizedDirectoryPath(for: libraryRoot)
        let libraryScanHeld = ArrivalGate()
        let scanner = CatalogScanner { rootPath, cadence, batchHandler in
            if rootPath == libraryPath {
                await libraryScanHeld.arrive()
            }
            return try await CatalogScanner.live.scanRoot(rootPath, cadence, batchHandler)
        }
        let store = CatalogStore(location: .inMemory, scanner: scanner, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: libraryRoot)
        await libraryScanHeld.waitForArrivals(1)

        try await store.attachRemovableVolume(
            mountURL: cardRoot,
            identity: .volume(uuid: "presence-card"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardRoot)

        try await waitUntil { try await visiblePaths(store, cardPath) == ["card.jpg"] }
        #expect(await libraryScanHeld.arrivalCount == 1)
        await libraryScanHeld.open()
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        await store.shutdown()
    }

    /// A refused eject resumes a card whose scan the quiesce cancelled, and rows that scan
    /// had not reached are still waiting to be seen: the card is read again.
    @Test func aCardResumedAfterARefusedEjectIsReadAgain() async throws {
        let cardRoot = try makeTestDirectory().appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cardRoot, withIntermediateDirectories: true)
        try writeCatalogStoreFile(cardRoot.appending(path: "card.jpg"), contents: "jpeg")
        let cardScans = ArrivalGate()
        let scanner = CatalogScanner { rootPath, cadence, batchHandler in
            await cardScans.arrive()
            try Task.checkCancellation()
            return try await CatalogScanner.live.scanRoot(rootPath, cadence, batchHandler)
        }
        let store = CatalogStore(location: .inMemory, scanner: scanner, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        let card = DeviceIdentity.volume(uuid: "presence-resume")
        try await store.attachRemovableVolume(mountURL: cardRoot, identity: card, displayName: "Card", isEjectable: true, capabilities: .unknown)
        await cardScans.waitForArrivals(1)
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardRoot)

        // Quiescing withdraws the card from enrichment before it awaits the cancelled scan.
        let quiesce = Task { try await store.quiesceRemovableSource(identity: card) }
        try await waitUntil { await !store.enrichableRootPaths().contains(cardPath) }
        await cardScans.open()
        try await quiesce.value
        try await store.resumeRemovableSource(identity: card)

        await cardScans.waitForArrivals(2)
        try await waitUntil { try await visiblePaths(store, cardPath) == ["card.jpg"] }
        await store.shutdown()
    }
}

private func visiblePaths(_ store: CatalogStore, _ rootPath: LibraryRootPath) async throws -> [String] {
    let ids = try await store.orderedAssetIDs(for: .library(rootPath), availableLibraryPaths: [rootPath])
    return ids.map(\.relativePath.rawValue).sorted()
}
