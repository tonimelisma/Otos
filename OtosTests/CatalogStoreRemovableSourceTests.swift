import Foundation
@testable import OtosKit
import Synchronization
import Testing

@Suite(.testScope)
struct CatalogStoreRemovableSourceTests {
    /// ADR 0013 / owner decision 2026-10-25: at launch a card or camera unseen for 90 days is
    /// forgotten, and detaching it records when it was last seen — 89 days after the detach
    /// keeps it although 94 have passed since it was attached.
    @Test func aSourceUnseenForNinetyDaysIsForgottenAtLaunch() async throws {
        let temp = try makeTestDirectory()
        let database = temp.appending(path: "catalog.sqlite")
        let day: TimeInterval = 24 * 60 * 60
        let attachedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let now = Mutex(attachedAt)
        let containers = StagingContainers(base: temp)
        let first = makeTestStore(
            location: .databaseFile(database), wallClock: { now.withLock { $0 } }, stagingContainers: containers
        )
        try await first.start(scansSavedLibraries: false)
        let rootPath = try await first.attachDeviceMTP(
            stagingRootURL: containers.sessionRoot(in: .device, identity: .camera(id: "serial")),
            identity: .camera(id: "serial"),
            displayName: "Camera"
        )
        now.withLock { $0 = attachedAt.addingTimeInterval(5 * day) }
        try await first.detachRemovableSource(identity: .camera(id: "serial"), reason: .disconnected)
        await first.shutdown()

        let kept = makeTestStore(
            location: .databaseFile(database),
            wallClock: { attachedAt.addingTimeInterval(94 * day) },
            stagingContainers: containers
        )
        try await kept.start(scansSavedLibraries: false)
        #expect(try await catalogStoreTestState(kept).removableSources.map(\.path) == [rootPath])
        await kept.shutdown()

        let expired = makeTestStore(
            location: .databaseFile(database),
            wallClock: { attachedAt.addingTimeInterval(96 * day) },
            stagingContainers: containers
        )
        try await expired.start(scansSavedLibraries: false)
        #expect(try await catalogStoreTestState(expired).removableSources.isEmpty)
        await expired.shutdown()
    }

    /// APP-018: a camera that returns without some of the files it had last time loses their
    /// rows once its new catalog is complete; the files it still has keep theirs.
    @Test func aCameraReturningWithoutSomeFilesLosesTheirRows() async throws {
        let temp = try makeTestDirectory()
        let stagingRoot = temp.appending(path: "DeviceStaging/Camera", directoryHint: .isDirectory)
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        func file(_ name: String) -> ScannedMediaFile {
            ScannedMediaFile(
                relativePath: MediaRelativePath(rawValue: "DCIM/\(name)"),
                name: name,
                contentTypeIdentifier: "public.jpeg",
                byteSize: 42,
                createdAt: Date(timeIntervalSince1970: 1000),
                contentModifiedAt: Date(timeIntervalSince1970: 1000)
            )
        }
        let kept = file("IMG_0001.JPG"), deleted = file("IMG_0002.JPG")

        let rootPath = try await store.attachDeviceMTP(
            stagingRootURL: stagingRoot, identity: .camera(id: "serial"), displayName: "Camera"
        )
        let firstScan = try await store.beginSourceListing(rootPath: rootPath)
        try await store.recordSourceListingBatch([kept, deleted], scan: firstScan)
        try await store.completeSourceListing(
            scan: firstScan, observedPaths: [kept.relativePath, deleted.relativePath]
        )
        #expect(try await store.catalogedAssetCount(for: .library(rootPath)) == 2)
        try await store.detachRemovableSource(identity: .camera(id: "serial"), reason: .disconnected)

        _ = try await store.attachDeviceMTP(
            stagingRootURL: stagingRoot, identity: .camera(id: "serial"), displayName: "Camera"
        )
        let secondScan = try await store.beginSourceListing(rootPath: rootPath)
        try await store.recordSourceListingBatch([kept], scan: secondScan)
        try await store.completeSourceListing(scan: secondScan, observedPaths: [kept.relativePath])

        let selected = try await waitForSelectedRelativePaths(
            store, rootPath: rootPath, expected: [kept.relativePath.rawValue]
        )
        #expect(selected == [kept.relativePath.rawValue])
        #expect(try await store.catalogedAssetCount(for: .library(rootPath)) == 1)
        await store.shutdown()
    }

    @Test func quiesceKeepsRemovableSourceAvailableForSidebar() async throws {
        let fixture = try await makeRemountFixture()
        let store = fixture.store

        try await store.attachRemovableVolume(
            mountURL: fixture.firstMount,
            identity: .volume(uuid: "test-card"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        try await store.quiesceRemovableSource(identity: .volume(uuid: "test-card"))
        let quiesced = try await catalogStoreTestState(store)
        #expect(quiesced.removableSources.first?.availability == .available)
    }

    /// An ejecting card stays available for the sidebar but offers enrichment nothing
    /// new to claim — from the claim query or as a viewport priority — until it
    /// resumes, so the eject drain waits on finite work.
    @Test func quiescedSourceOffersNoEnrichmentClaimsUntilResumed() async throws {
        let fixture = try await makeRemountFixture()
        let store = fixture.store

        try await store.attachRemovableVolume(
            mountURL: fixture.firstMount,
            identity: .volume(uuid: "test-card"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: fixture.firstMount)
        _ = try await waitForSelectedRelativePaths(store, rootPath: cardPath, expected: ["card.jpg"])
        let cardID = MediaAssetID(libraryRootPath: cardPath, relativePath: MediaRelativePath(rawValue: "card.jpg"))

        try await store.quiesceRemovableSource(identity: .volume(uuid: "test-card"))
        let whileQuiesced = try await store.priorityEnrichmentCandidates([cardID], videoFaces: .admitted)
        #expect(!whileQuiesced.contains { $0.asset.id.libraryRootPath == cardPath })

        try await store.resumeRemovableSource(identity: .volume(uuid: "test-card"))
        let afterResume = try await store.priorityEnrichmentCandidates([cardID], videoFaces: .admitted)
        #expect(afterResume.contains { $0.asset.id == cardID })
    }

    /// ENR-017: while an import copies from a card, enrichment is offered nothing on it —
    /// claims taken before are released — and the fixed library keeps enriching. When the
    /// import ends, however it ended, the card is offered again.
    @Test func aCardBeingImportedOffersNoEnrichmentUntilTheImportEnds() async throws {
        let fixture = try await makeRemountFixture()
        let store = fixture.store
        try await store.attachRemovableVolume(
            mountURL: fixture.firstMount,
            identity: .volume(uuid: "test-card"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: fixture.firstMount)
        _ = try await waitForSelectedRelativePaths(store, rootPath: cardPath, expected: ["card.jpg"])
        let cardID = MediaAssetID(libraryRootPath: cardPath, relativePath: MediaRelativePath(rawValue: "card.jpg"))
        #expect(try await store.priorityEnrichmentCandidates([cardID], videoFaces: .admitted).map(\.asset.id) == [cardID])

        let batch = ImportBatchID()
        await store.beginImportSourceRead(batch, source: cardPath)
        #expect(await store.enrichableRootPaths() == [fixture.fixedRootPath])
        #expect(try await store.priorityEnrichmentCandidates([cardID], videoFaces: .admitted).isEmpty)
        let background = try await store.enrichmentCandidates(limit: 10, videoFaces: .admitted)
        #expect(background.allSatisfy { $0.asset.id.libraryRootPath == fixture.fixedRootPath })

        await store.endImportSourceRead(batch, source: cardPath)
        #expect(await store.enrichableRootPaths().contains(cardPath))
        // The claim taken before the import was released when it began.
        #expect(try await store.priorityEnrichmentCandidates([cardID], videoFaces: .admitted).map(\.asset.id) == [cardID])
    }

    /// Quiescence belongs to one attachment's pending unmount. A card quiesced at one
    /// mount and attached again at another is a new attachment: it offers enrichment
    /// again, and the root keeps the rest of what it was.
    @Test func aCardQuiescedAtOneMountIsNotQuiescedWhenItRemountsElsewhere() async throws {
        let fixture = try await makeRemountFixture()
        let store = fixture.store
        let identity = DeviceIdentity.volume(uuid: "test-card")
        try await store.attachRemovableVolume(
            mountURL: fixture.firstMount,
            identity: identity,
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        let firstPath = try CatalogPath.normalizedDirectoryPath(for: fixture.firstMount)
        _ = try await waitForSelectedRelativePaths(store, rootPath: firstPath, expected: ["card.jpg"])
        try await store.quiesceRemovableSource(identity: identity)

        try await store.attachRemovableVolume(
            mountURL: fixture.secondMount,
            identity: identity,
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        let secondPath = try CatalogPath.normalizedDirectoryPath(for: fixture.secondMount)
        _ = try await waitForSelectedRelativePaths(store, rootPath: secondPath, expected: ["card.jpg"])
        let cardID = MediaAssetID(libraryRootPath: secondPath, relativePath: MediaRelativePath(rawValue: "card.jpg"))

        let candidates = try await store.priorityEnrichmentCandidates([cardID], videoFaces: .admitted)
        #expect(candidates.contains { $0.asset.id == cardID })
    }

    /// APP-007: a removal waiting for the card follows it when it remounts at another
    /// path. The card at its new mount is held by nothing, so the removal runs there.
    @Test func aRemovalWaitingForACardFollowsItToItsNewMount() async throws {
        let fixture = try await makeRemountFixture()
        let store = fixture.store
        let identity = DeviceIdentity.volume(uuid: "test-card")
        try await store.attachRemovableVolume(
            mountURL: fixture.firstMount,
            identity: identity,
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        let firstPath = try CatalogPath.normalizedDirectoryPath(for: fixture.firstMount)
        _ = try await waitForSelectedRelativePaths(store, rootPath: firstPath, expected: ["card.jpg"])
        guard case let .acquired(lease) = await store.acquireNamespaceMutationLease(
            for: firstPath,
            owner: .sourceErase
        ) else {
            Issue.record("Expected to hold the card's namespace for this test")
            return
        }
        #expect(try await store.removeLibrary(path: firstPath) == .waiting(for: .sourceErase))

        try await store.attachRemovableVolume(
            mountURL: fixture.secondMount,
            identity: identity,
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        let removed = try await waitForCatalogStoreState(store) { $0.removableSources.isEmpty }
        #expect(removed.libraries.map(\.path) == [fixture.fixedRootPath])
        // The holder at the old mount finishes later; its release finds no root there.
        #expect(await store.releaseNamespaceMutationLease(lease))
        #expect(try await catalogStoreTestState(store).removableSources.isEmpty)
    }

    /// Otos's own eject reports its outcome, so a refused one resumes the card at once:
    /// it is still mounted, and its enrichment must not wait on a limit meant for ejects
    /// started elsewhere, which report nothing.
    @Test func aRefusedEjectResumesTheCardWithoutWaiting() async throws {
        let fixture = try await makeRemountFixture()
        let store = fixture.store
        try await store.attachRemovableVolume(
            mountURL: fixture.firstMount,
            identity: .volume(uuid: "test-card"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: fixture.firstMount)
        _ = try await waitForSelectedRelativePaths(store, rootPath: cardPath, expected: ["card.jpg"])
        let cardID = MediaAssetID(libraryRootPath: cardPath, relativePath: MediaRelativePath(rawValue: "card.jpg"))
        let root = try #require(try await catalogStoreTestState(store).removableSources.first?.root)

        let outcome = await CatalogWindowViewModel.performEjectRemovableSource(
            root,
            store: store,
            coordinator: nil,
            previewLoader: nil,
            retryDelays: [],
            eject: { _ in .busy }
        )

        #expect(outcome == .busy(displayName: root.displayName))
        let afterRefusal = try await store.priorityEnrichmentCandidates([cardID], videoFaces: .admitted)
        #expect(afterRefusal.contains { $0.asset.id == cardID })
    }

    @Test func removableVolumeRemountsByIdentityAndStaysOutOfAllMedia() async throws {
        let fixture = try await makeRemountFixture()
        let store = fixture.store

        try await store.attachRemovableVolume(
            mountURL: fixture.firstMount,
            identity: .volume(uuid: "test-card"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        let firstPath = try CatalogPath.normalizedDirectoryPath(for: fixture.firstMount)
        _ = try await waitForSelectedRelativePaths(store, rootPath: firstPath, expected: ["card.jpg"])
        let attached = try await catalogStoreTestState(store)
        #expect(attached.libraries.map(\.path) == [fixture.fixedRootPath])
        #expect(attached.removableSources.map(\.path) == [firstPath])
        #expect(attached.removableSources.first?.kind == .removableVolume)
        #expect(attached.removableSources.first?.isEjectable == true)
        #expect(attached.testAssets.map(\.relativePath.rawValue) == ["fixed.jpg"])

        try await store.detachRemovableSource(identity: .volume(uuid: "test-card"), reason: .unmounted)
        let detached = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.removableSources.first?.availability == .unavailable
        }
        #expect(detached.removableSources.first?.path == firstPath)
        #expect(try await store.catalogedAssetCount(for: .library(firstPath)) == 1)

        try await store.attachRemovableVolume(
            mountURL: fixture.secondMount,
            identity: .volume(uuid: "test-card"),
            displayName: "Card Renamed",
            isEjectable: false,
            capabilities: .unknown
        )
        let secondPath = try CatalogPath.normalizedDirectoryPath(for: fixture.secondMount)
        _ = try await waitForSelectedRelativePaths(store, rootPath: secondPath, expected: ["card.jpg"])
        let remounted = try await catalogStoreTestState(store)

        #expect(remounted.removableSources.map(\.path) == [secondPath])
        #expect(remounted.removableSources.first?.displayName == "Card Renamed")
        #expect(remounted.removableSources.first?.availability == .available)
        #expect(remounted.removableSources.first?.isEjectable == false)
        #expect(remounted.removableSources.first?.lastSeenAt != nil)
        #expect(!remounted.allSources.map(\.path).contains(firstPath))
        #expect(remounted.testAssets.map(\.relativePath.rawValue) == ["fixed.jpg"])
    }

    @Test func mtpCatalogRowsAreScopedToCameraAndStagingSurvivesDetach() async throws {
        let temp = try makeTestDirectory()
        let stagingRoot = temp.appending(path: "DeviceStaging/Camera", directoryHint: .isDirectory)
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)

        let rootPath = try await store.attachDeviceMTP(
            stagingRootURL: stagingRoot,
            identity: .camera(id: "serial"),
            displayName: "Camera"
        )
        let scan = try await store.beginSourceListing(rootPath: rootPath)
        let relativePath = MediaRelativePath(rawValue: "DCIM/IMG_0001.JPG")
        try await store.recordSourceListingBatch([
            ScannedMediaFile(
                relativePath: relativePath,
                name: "IMG_0001.JPG",
                contentTypeIdentifier: "public.jpeg",
                byteSize: 42,
                createdAt: Date(timeIntervalSince1970: 1000),
                contentModifiedAt: Date(timeIntervalSince1970: 1000)
            ),
        ], scan: scan)

        let selected = try await waitForSelectedRelativePaths(
            store,
            rootPath: rootPath,
            expected: [relativePath.rawValue]
        )
        let enumerating = try await catalogStoreTestState(store)
        #expect(selected == [relativePath.rawValue])
        #expect(enumerating.libraries.isEmpty)
        #expect(enumerating.removableSources.first?.kind == .deviceMTP)
        #expect(enumerating.removableSources.first?.activity == .enumerating)
        #expect(enumerating.testAssets.isEmpty)
        #expect(try await store.catalogedAssetCount(for: .allMedia) == 0)
        #expect(try await store.catalogedAssetCount(for: .library(rootPath)) == 1)

        try await store.completeSourceListing(scan: scan, observedPaths: [relativePath])
        let complete = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.removableSources.first?.activity == .idle
        }
        #expect(complete.removableSources.first?.availability == .available)

        try await store.detachRemovableSource(identity: .camera(id: "serial"), reason: .disconnected)
        let detached = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.removableSources.first?.availability == .unavailable
        }
        #expect(detached.removableSources.first?.path == rootPath)
        // Staged bytes survive an eject. They are already off the camera, so
        // discarding them here would re-download the whole device on the next
        // attach — tens of gigabytes for a full card. They are released at app close,
        // with a launch sweep as the crash-safe backstop (APP-018, owner decision
        // 2026-08-30, reversing the previous "only while connected" rule).
        #expect(FileManager.default.fileExists(atPath: stagingRoot.path(percentEncoded: false)))
        #expect(try await store.catalogedAssetCount(for: .library(rootPath)) == 1)
    }

    @Test func staleDeviceEnumerationCannotWriteOrReconcileNewerRows() async throws {
        let temp = try makeTestDirectory()
        let stagingRoot = temp.appending(path: "DeviceStaging/Camera", directoryHint: .isDirectory)
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)

        let rootPath = try await store.attachDeviceMTP(
            stagingRootURL: stagingRoot,
            identity: .camera(id: "serial"),
            displayName: "Camera"
        )
        let staleScan = try await store.beginSourceListing(rootPath: rootPath)
        let currentScan = try await store.beginSourceListing(rootPath: rootPath)
        let currentPath = MediaRelativePath(rawValue: "DCIM/current.JPG")
        try await store.recordSourceListingBatch([
            ScannedMediaFile(
                relativePath: currentPath,
                name: "current.JPG",
                contentTypeIdentifier: "public.jpeg",
                byteSize: 42,
                createdAt: Date(timeIntervalSince1970: 1000),
                contentModifiedAt: Date(timeIntervalSince1970: 1000)
            ),
        ], scan: currentScan)

        var staleBatchThrew = false
        do {
            try await store.recordSourceListingBatch([
                ScannedMediaFile(
                    relativePath: MediaRelativePath(rawValue: "DCIM/stale.JPG"),
                    name: "stale.JPG",
                    contentTypeIdentifier: "public.jpeg",
                    byteSize: 1,
                    createdAt: nil,
                    contentModifiedAt: nil
                ),
            ], scan: staleScan)
        } catch is CancellationError {
            staleBatchThrew = true
        }
        #expect(staleBatchThrew)

        var staleCompleteThrew = false
        do {
            try await store.completeSourceListing(scan: staleScan, observedPaths: [])
        } catch is CancellationError {
            staleCompleteThrew = true
        }
        #expect(staleCompleteThrew)

        let selected = try await selectedRelativePaths(store, rootPath: rootPath)
        #expect(selected == [currentPath.rawValue])
        try await store.completeSourceListing(scan: currentScan, observedPaths: [currentPath])
    }

    @Test func startWatchingIncludesAlreadyAttachedRemovableVolumes() async throws {
        let temp = try makeTestDirectory()
        let fixedRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardRoot = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardRoot, withIntermediateDirectories: true)

        let watcherHarness = CatalogFilesystemWatcher.testingWithRootInspection()
        let store = makeTestStore(
            location: .inMemory,
            filesystemWatcher: watcherHarness.watcher
        )
        try await store.addLibrary(url: fixedRoot)
        try await store.attachRemovableVolume(
            mountURL: cardRoot,
            identity: .volume(uuid: "card"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        try await store.start(scansSavedLibraries: false)

        let fixedPath = try CatalogPath.normalizedDirectoryPath(for: fixedRoot)
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardRoot)
        #expect(Set(watcherHarness.roots()) == Set([fixedPath, cardPath]))
    }
}

private struct RemovableRemountFixture {
    let store: CatalogStore
    let fixedRootPath: LibraryRootPath
    let firstMount: URL
    let secondMount: URL
}

private func makeRemountFixture() async throws -> RemovableRemountFixture {
    let temp = try makeTestDirectory()
    let fixedRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
    let firstMount = temp.appending(path: "Card-1", directoryHint: .isDirectory)
    let secondMount = temp.appending(path: "Card-2", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: fixedRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: firstMount, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondMount, withIntermediateDirectories: true)
    try writeCatalogStoreFile(fixedRoot.appending(path: "fixed.jpg"), contents: "jpeg")
    try writeCatalogStoreFile(firstMount.appending(path: "card.jpg"), contents: "jpeg")
    try writeCatalogStoreFile(secondMount.appending(path: "card.jpg"), contents: "jpeg")

    let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
    try await store.start(scansSavedLibraries: false)
    try await store.addLibrary(url: fixedRoot)
    _ = try await waitForCatalogStoreState(store) { snapshot in
        !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["fixed.jpg"]
    }
    return try RemovableRemountFixture(
        store: store,
        fixedRootPath: CatalogPath.normalizedDirectoryPath(for: fixedRoot),
        firstMount: firstMount,
        secondMount: secondMount
    )
}

private func selectedRelativePaths(
    _ store: CatalogStore,
    rootPath: LibraryRootPath
) async throws -> [String] {
    let ids = try await store.orderedAssetIDs(for: .library(rootPath), availableLibraryPaths: [rootPath])
    let assetsByID = try await store.mediaAssets(for: ids)
    return ids.compactMap { assetsByID[$0]?.relativePath.rawValue }
}

private func waitForSelectedRelativePaths(
    _ store: CatalogStore,
    rootPath: LibraryRootPath,
    expected: [String]
) async throws -> [String] {
    let changes = await store.changeNotifications()
    let initial = try await selectedRelativePaths(store, rootPath: rootPath)
    if initial == expected {
        return initial
    }
    for await _ in changes {
        let paths = try await selectedRelativePaths(store, rootPath: rootPath)
        if paths == expected {
            return paths
        }
    }
    throw AsyncTestTimeoutError.streamEnded("selected removable assets")
}
