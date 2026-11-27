import Foundation
import GRDB
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
        #expect(try await store.windowReads.catalogedAssetCount(for: .library(rootPath)) == 2)
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
        #expect(try await store.windowReads.catalogedAssetCount(for: .library(rootPath)) == 1)
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
        let whileQuiesced = try await store.priorityEnrichmentCandidates([cardID], videoFaces: .admitted).claimed
        #expect(!whileQuiesced.contains { $0.asset.id.libraryRootPath == cardPath })

        // Enrichment's gate hears that the source is claimable again: a camera, which no
        // scan follows, would otherwise wait for an unrelated change.
        let changes = AsyncValueRecorder<CatalogStoreChange>()
        let stream = await store.changeNotifications()
        let recording = Task {
            for await change in stream {
                await changes.append(change)
            }
        }
        defer { recording.cancel() }
        try await store.resumeRemovableSource(identity: .volume(uuid: "test-card"))
        // The rescan the resume starts announces itself after anything the resume announced.
        let heard = await changes.waitForValues { $0.contains(.changed(.membership, rows: .none)) }
        #expect(heard.first == .changed(.detail))
        let afterResume = try await store.priorityEnrichmentCandidates([cardID], videoFaces: .admitted).claimed
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
        #expect(try await store.priorityEnrichmentCandidates([cardID], videoFaces: .admitted).claimed.map(\.asset.id) == [cardID])

        let batch = ImportBatchID()
        await store.beginImportSourceRead(batch, source: cardPath)
        #expect(await store.enrichableRootPaths() == [fixture.fixedRootPath])
        #expect(try await store.priorityEnrichmentCandidates([cardID], videoFaces: .admitted).claimed.isEmpty)
        let background = try await store.enrichmentCandidates(limit: 10, room: .unlimited, videoFaces: .admitted)
        #expect(background.allSatisfy { $0.asset.id.libraryRootPath == fixture.fixedRootPath })

        await store.endImportSourceRead(batch, source: cardPath)
        #expect(await store.enrichableRootPaths().contains(cardPath))
        // The claim taken before the import was released when it began.
        #expect(try await store.priorityEnrichmentCandidates([cardID], videoFaces: .admitted).claimed.map(\.asset.id) == [cardID])
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

        let candidates = try await store.priorityEnrichmentCandidates([cardID], videoFaces: .admitted).claimed
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
            ejectAttempts: { _ in { .busy } }
        )

        #expect(outcome == .busy(displayName: root.displayName))
        let afterRefusal = try await store.priorityEnrichmentCandidates([cardID], videoFaces: .admitted).claimed
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
        #expect(try await store.windowReads.catalogedAssetCount(for: .library(firstPath)) == 1)

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
        #expect(try await store.windowReads.catalogedAssetCount(for: .allMedia) == 0)
        #expect(try await store.windowReads.catalogedAssetCount(for: .library(rootPath)) == 1)

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
        #expect(try await store.windowReads.catalogedAssetCount(for: .library(rootPath)) == 1)
    }

    /// Plan 0117 step 1 (ADR 0032 rule 6): removing a camera deletes its staging folder off the
    /// Store's actor, while the removal still holds the root. The test holds the delete on its
    /// thread and asks the Store meanwhile: the answer comes, and still lists the camera. A
    /// delete run on the actor would block it, and this test would hang at that question,
    /// which the check reports as a hang naming it.
    @Test func removingACameraDeletesItsStagingFolderOffTheActor() async throws {
        let temp = try makeTestDirectory()
        let stagingRoot = temp.appending(path: "DeviceStaging/Camera", directoryHint: .isDirectory)
        let (reached, reach) = AsyncStream<LibraryRootPath>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let store = makeTestStore(location: .inMemory, stagingDeletionReached: { path in
            reach.yield(path)
            release.wait()
        })
        try await store.start(scansSavedLibraries: false)
        let rootPath = try await store.attachDeviceMTP(
            stagingRootURL: stagingRoot, identity: .camera(id: "serial"), displayName: "Camera"
        )
        try Data("staged".utf8).write(to: stagingRoot.appending(path: "IMG_0001.JPG"))

        let removal = Task { try await store.removeLibrary(path: rootPath) }
        var deletions = reached.makeAsyncIterator()
        #expect(await deletions.next() == rootPath)
        #expect(await store.currentLibraries().map(\.path) == [rootPath])
        release.signal()

        #expect(try await removal.value == .removed)
        #expect(!FileManager.default.fileExists(atPath: stagingRoot.path(percentEncoded: false)))
        #expect(await store.currentLibraries().isEmpty)
    }

    /// ADR 0013: the camera comes back while its removal deletes its staging folder. The
    /// re-attach waits for the removal's lease, and the folder it attaches at is made only once
    /// it holds the root: the removal's delete never takes the folder of the camera attached
    /// after it, so the Store's root and the disk agree.
    @Test func aCameraReattachedWhileItsRemovalDeletesItsStagingKeepsItsStagingFolder() async throws {
        let temp = try makeTestDirectory()
        let stagingRoot = temp.appending(path: "DeviceStaging/Camera", directoryHint: .isDirectory)
        let (deletions, reachDeletion) = AsyncStream<LibraryRootPath>.makeStream()
        let (points, reachPoint) = AsyncStream<NamespaceMutationPoint>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let store = makeTestStore(
            location: .inMemory,
            namespaceMutationReached: { point in reachPoint.yield(point) },
            stagingDeletionReached: { path in
                reachDeletion.yield(path)
                release.wait()
            }
        )
        try await store.start(scansSavedLibraries: false)
        let identity = DeviceIdentity.camera(id: "serial")
        let rootPath = try await store.attachDeviceMTP(
            stagingRootURL: stagingRoot, identity: identity, displayName: "Camera"
        )

        let removal = Task { try await store.removeLibrary(path: rootPath) }
        var deletionIterator = deletions.makeAsyncIterator()
        #expect(await deletionIterator.next() == rootPath)

        let reattach = Task {
            try await store.attachDeviceMTP(stagingRootURL: stagingRoot, identity: identity, displayName: "Camera")
        }
        var pointIterator = points.makeAsyncIterator()
        while let point = await pointIterator.next(), point != .attachmentWaits(rootPath) {}
        release.signal()

        #expect(try await removal.value == .removed)
        #expect(try await reattach.value == rootPath)
        #expect(await store.currentLibraries().map(\.path) == [rootPath], "the re-attached camera is a root")
        #expect(
            FileManager.default.fileExists(atPath: stagingRoot.path(percentEncoded: false)),
            "the re-attached camera's staging folder exists"
        )
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

    /// ADR 0013: a card the launch forgets for being unseen 90 days, and a different card that
    /// mounts at its mount point while the removal runs. The removal owns the old card's
    /// root from its start; the new card waits for it and attaches as a source of its own, so
    /// the catalog's rows and the Store's roots agree and the new card is kept.
    @Test func aCardAttachingWhileRetentionForgetsTheOldOneAtItsMountIsKept() async throws {
        let fixture = try await RetentionRaceFixture.make()
        let points = NamespacePoints()
        let store = fixture.launch(points)
        let launch = Task { try await store.start(scansSavedLibraries: false) }
        await points.waitFor { $0 == .point(.removalWillDelete(fixture.mountPath)) }

        let attach = Task { try await fixture.attachNewCard(to: store) }
        // The attachment has read the root at the mount: it writes, or waits for the removal.
        await points.waitFor { $0 == .point(.attachmentWillWrite(fixture.mountPath)) || $0 == .point(.attachmentWaits(fixture.mountPath)) }
        await points.openRemovals()
        try await launch.value
        await points.openAttachments()
        try await attach.value

        let sources = try await fixture.sources(in: store)
        #expect(sources.roots == sources.rows, "the Store's roots and the catalog's rows name the same sources")
        #expect(sources.rootAtMount == RetentionRaceFixture.newCard, "the new card is kept")
        #expect(sources.rowAtMount == RetentionRaceFixture.newCard, "the new card's row is kept")
    }

    /// The same two at the other order: the new card's attachment holds the mount's root when
    /// the launch's retention reaches it, so retention leaves it, and the new card is kept.
    @Test func retentionLeavesTheRootACardIsAttachingTo() async throws {
        let fixture = try await RetentionRaceFixture.make()
        let points = NamespacePoints()
        let store = fixture.launch(points)
        let attach = Task { try await fixture.attachNewCard(to: store) }
        await points.waitFor { $0 == .point(.attachmentWillWrite(fixture.mountPath)) }

        let launch = Task {
            do {
                try await store.start(scansSavedLibraries: false)
            } catch {
                await points.launchEnded()
                throw error
            }
            await points.launchEnded()
        }
        // Retention has run: it reached the removal, or it left the root and the launch ended.
        await points.waitFor { $0 == .point(.removalWillDelete(fixture.mountPath)) || $0 == .launchEnded }
        await points.openAttachments()
        try await attach.value
        await points.openRemovals()
        try await launch.value

        let sources = try await fixture.sources(in: store)
        #expect(sources.roots == sources.rows, "the Store's roots and the catalog's rows name the same sources")
        #expect(sources.rootAtMount == RetentionRaceFixture.newCard, "the new card is kept")
        #expect(sources.rowAtMount == RetentionRaceFixture.newCard, "the new card's row is kept")
    }
}

/// A catalog holding one card, unavailable and last seen 96 days before the launch the test
/// makes, at a mount point a different card is about to take.
private struct RetentionRaceFixture {
    let database: URL
    let mount: URL
    let mountPath: LibraryRootPath
    let launchedAt: Date
    static let oldCard = DeviceIdentity.volume(uuid: "old-card")
    static let newCard = DeviceIdentity.volume(uuid: "new-card")

    static func make() async throws -> RetentionRaceFixture {
        let temp = try makeTestDirectory()
        let database = temp.appending(path: "catalog.sqlite")
        let mount = temp.appending(path: "Untitled", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try writeCatalogStoreFile(mount.appending(path: "card.jpg"), contents: "jpeg")
        let seenAt = Date(timeIntervalSince1970: 1_800_000_000)
        let first = makeTestStore(location: .databaseFile(database), wallClock: { seenAt })
        try await first.start(scansSavedLibraries: false)
        try await first.attachRemovableVolume(
            mountURL: mount, identity: oldCard, displayName: "Old", isEjectable: true, capabilities: .unknown
        )
        _ = try await waitForCatalogStoreState(first) { !$0.isScanning }
        try await first.detachRemovableSource(identity: oldCard, reason: .unmounted)
        await first.shutdown()
        return try RetentionRaceFixture(
            database: database, mount: mount, mountPath: CatalogPath.normalizedDirectoryPath(for: mount),
            launchedAt: seenAt.addingTimeInterval(96 * 24 * 60 * 60)
        )
    }

    func launch(_ points: NamespacePoints) -> CatalogStore {
        let launchedAt = launchedAt
        return makeTestStore(
            location: .databaseFile(database), wallClock: { launchedAt },
            namespaceMutationReached: { await points.reach($0) }
        )
    }

    func attachNewCard(to store: CatalogStore) async throws {
        try await store.attachRemovableVolume(
            mountURL: mount, identity: Self.newCard, displayName: "New", isEjectable: true, capabilities: .unknown
        )
    }

    /// The sources the Store's roots and the catalog's `library_root` rows name, by path, and
    /// the identity each holds at the mount.
    struct Sources {
        let roots: Set<String>
        let rows: Set<String>
        let rootAtMount: DeviceIdentity?
        let rowAtMount: DeviceIdentity?
    }

    /// Reads `Sources`, then shuts the store down.
    func sources(in store: CatalogStore) async throws -> Sources {
        let roots = await store.currentLibraries()
        let rows = try await makeTestDatabaseQueue(path: database.path(percentEncoded: false)).read { db in
            try Row.fetchAll(db, sql: "SELECT path, device_identity FROM library_root").map {
                ($0["path"] as String, $0["device_identity"] as DeviceIdentity?)
            }
        }
        await store.shutdown()
        return Sources(
            roots: Set(roots.map(\.path.rawValue)), rows: Set(rows.map(\.0)),
            rootAtMount: roots.first { $0.path == mountPath }?.root.deviceIdentity,
            rowAtMount: rows.first { $0.0 == mountPath.rawValue }?.1
        )
    }
}

/// Where the Store's namespace mutations reached, and the launch's end, in order. A removal
/// about to delete and an attachment about to write park there until the test opens their kind.
private actor NamespacePoints {
    enum Reached: Equatable, Sendable {
        case point(NamespaceMutationPoint)
        case launchEnded
    }

    private var reached: [Reached] = []
    private var removalsOpen = false
    private var attachmentsOpen = false
    private var parkedRemovals: [CheckedContinuation<Void, Never>] = []
    private var parkedAttachments: [CheckedContinuation<Void, Never>] = []
    private var waiters: [(matches: @Sendable (Reached) -> Bool, continuation: CheckedContinuation<Void, Never>)] = []

    func reach(_ point: NamespaceMutationPoint) async {
        record(.point(point))
        switch point {
        case .removalWillDelete where !removalsOpen:
            await withCheckedContinuation { parkedRemovals.append($0) }
        case .attachmentWillWrite where !attachmentsOpen:
            await withCheckedContinuation { parkedAttachments.append($0) }
        default:
            return
        }
    }

    func launchEnded() {
        record(.launchEnded)
    }

    private func record(_ event: Reached) {
        reached.append(event)
        let resumed = waiters.filter { $0.matches(event) }
        waiters.removeAll { $0.matches(event) }
        resumed.forEach { $0.continuation.resume() }
    }

    /// Returns once an event `matches` has been reached.
    func waitFor(_ matches: @escaping @Sendable (Reached) -> Bool) async {
        guard !reached.contains(where: matches) else { return }
        await withCheckedContinuation { waiters.append((matches, $0)) }
    }

    func openRemovals() {
        removalsOpen = true
        parkedRemovals.forEach { $0.resume() }
        parkedRemovals.removeAll()
    }

    func openAttachments() {
        attachmentsOpen = true
        parkedAttachments.forEach { $0.resume() }
        parkedAttachments.removeAll()
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
    let ids = try await store.windowReads.orderedAssetIDs(for: .library(rootPath), availableLibraryPaths: [rootPath])
    let assetsByID = try await store.windowReads.mediaAssets(for: ids)
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
