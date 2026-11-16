import Foundation
@testable import OtosKit
import Testing

@Suite(.testScope)
struct MediaOperationCoordinatorTests {
    @Test func repeatedIntentAndOccupancyChangeStartOneBatch() async throws {
        let temp = try makeTestDirectory()
        let destinationURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let sourceURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        for index in 0 ..< 12 {
            try Data(repeating: UInt8(index), count: 512 * 1024).write(
                to: sourceURL.appending(path: "image-\(index).jpg")
            )
        }
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destinationURL)
        let destination = try CatalogPath.normalizedDirectoryPath(for: destinationURL)
        try await store.attachRemovableVolume(
            mountURL: sourceURL,
            identity: .volume(uuid: "one-execution"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        let source = try CatalogPath.normalizedDirectoryPath(for: sourceURL)
        _ = try await waitForCatalogStoreState(store) { state in
            !state.isScanning && state.removableSources.first?.activity == .idle
        }
        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: tempDefaults,
            volumeCapacity: ampleVolumeCapacity
        )
        await coordinator.start()
        // Ready requires proven naming facts (ARC-057); stand in for the
        // enrichment coordinator these tests do not run.
        await markEnrichmentLookedAtEveryRow(store, root: source)
        await coordinator.setDestination(destination, for: source)
        _ = try await readyGeneration(coordinator, source: source)

        async let first: Void = coordinator.queueImport(for: source)
        async let second: Void = coordinator.queueImport(for: source)
        _ = await store.bumpNamespaceRevision(for: destination)
        _ = await (first, second)

        // The occupancy change can send the source back through planning before either
        // intent starts a run, and then neither call waits for it (`queueImport` waits only
        // for a run it starts): wait for the batch itself, then for the coordinator to
        // settle, so a second batch would have had every chance to appear.
        let landed = try await waitForValue {
            try await store.importBatches(counting: .every).first { $0.photoCount == 12 }
        }
        try await waitForCoordinatorQuiescence(coordinator)
        let batches = try await store.importBatches(counting: .every)
        #expect(batches.count == 1)
        #expect(batches.first == landed)
        await coordinator.shutdown()
    }

    /// ARC-047: the coordinator must discover an attached source purely via
    /// the store's `RootPlanningChange` stream — no `setDestination`/`queueImport`
    /// intent. This pins the emit → subscribe → refreshSources chain that a field
    /// capture showed silent for six minutes; with the emit/receive diagnostics, a
    /// future capture can distinguish "no events emitted" (idle app awaiting user
    /// input) from "events not received" (broken subscription).
    @Test func planningChangeStreamDeliversAttachedSourceWithoutIntent() async throws {
        let temp = try makeTestDirectory()
        let fixedRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardRoot = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardRoot, withIntermediateDirectories: true)
        try writeCatalogStoreFile(cardRoot.appending(path: "card.jpg"), contents: "jpeg")

        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: fixedRoot)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }

        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: tempDefaults,
            volumeCapacity: ampleVolumeCapacity
        )
        await coordinator.start()

        // Attach AFTER start: the card's scan bumps occupancy and emits planning
        // changes. The coordinator (auto-mapping to the sole destination) must reach
        // `.ready` via the stream alone.
        try await store.attachRemovableVolume(
            mountURL: cardRoot,
            identity: .volume(uuid: "stream-card"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardRoot)
        // Ready requires proven naming facts (ARC-057). Waiting for the card's own
        // scan in the *store* and standing in for the enrichment coordinator does not
        // defeat this test's point — the coordinator still discovers the source and
        // reaches Ready through the planning-change stream alone, with no
        // `setDestination`/`queueImport` intent.
        _ = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.removableSources.contains {
                $0.path == cardPath && $0.availability == .available && !$0.isScanning
            }
        }
        await markEnrichmentLookedAtEveryRow(store, root: cardPath)
        // `.ready` must arrive via the planning-change stream alone, with no
        // precondition wait possible without defeating that.
        _ = try await readyGeneration(coordinator, source: cardPath)

        let presentation = try #require(
            await coordinator.currentPresentations().first { $0.sourcePath == cardPath }
        )
        guard case .ready = presentation.state else {
            Issue.record("Expected .ready via planning-change stream, got \(presentation.state)")
            await coordinator.shutdown()
            return
        }
        await coordinator.shutdown()
    }

    @Test func catalogChangeWakesWaitingForMetadataSource() async throws {
        let temp = try makeTestDirectory()
        let fixedRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardRoot = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardRoot, withIntermediateDirectories: true)
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardRoot)
        let relative = MediaRelativePath(rawValue: "undated.jpg")

        let scanner = CatalogScanner { rootPath, _, batchHandler in
            guard rootPath == cardPath else {
                return .empty
            }
            try await batchHandler([
                ScannedMediaFile(
                    relativePath: relative,
                    name: relative.rawValue,
                    contentTypeIdentifier: "public.jpeg",
                    byteSize: 10,
                    createdAt: nil,
                    contentModifiedAt: nil
                ),
            ])
            return .mediaOnly([relative])
        }
        let store = makeTestStore(
            location: .inMemory,
            scanner: scanner,
            scanCadence: .milliseconds(10)
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: fixedRoot)
        try await store.attachRemovableVolume(
            mountURL: cardRoot,
            identity: .volume(uuid: "metadata-wake"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )

        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: tempDefaults,
            volumeCapacity: ampleVolumeCapacity
        )
        await coordinator.start()

        // The source waits for metadata before enrichment.
        try await waitUntil(every: .milliseconds(25)) {
            let presentation = await coordinator.currentPresentations().first { $0.sourcePath == cardPath }
            if case .waitingForMetadata = presentation?.state {
                return true
            }
            return false
        }

        let captureDate = Date(timeIntervalSince1970: 1_767_279_600)
        let result = EnrichmentResult(
            id: MediaAssetID(libraryRootPath: cardPath, relativePath: relative),
            metadata: AssetMetadata(
                timestamps: [
                    CaptureTimestampRecord(
                        role: "original",
                        instant: captureDate,
                        utcOffsetSeconds: nil,
                        precision: "localFloating",
                        year: 2026,
                        month: 1,
                        day: 1,
                        hour: 12,
                        minute: 0,
                        second: 0
                    ),
                ]
            ),
            enrichedKind: nil,
            enrichedFormat: nil,
            thumbnailPath: nil,
            sourceSize: 10,
            sourceMTimeSeconds: nil,
            contentHash: nil
        )
        #expect(await store.applyEnrichmentBatch([result]) == .applied(count: 1))

        // Catalog enrichment wakes the waiting import source into a ready plan.
        try await waitUntil(every: .milliseconds(25)) {
            let presentation = await coordinator.currentPresentations().first { $0.sourcePath == cardPath }
            if case .ready = presentation?.state {
                return true
            }
            return false
        }
        await coordinator.shutdown()
    }

    /// Regression: an enriching cloud destination bumps `planRevision` every few
    /// seconds without changing occupancy. Planning must settle to `.ready` and
    /// stay there — never livelock back into `.planning` — while a real occupancy
    /// change still forces a replan.
    @Test func noOpPlanRevisionChurnDoesNotDisturbReadyPlan() async throws {
        let temp = try makeTestDirectory()
        let fixedRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardRoot = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardRoot, withIntermediateDirectories: true)
        try writeCatalogStoreFile(cardRoot.appending(path: "card.jpg"), contents: "jpeg-bytes")

        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: fixedRoot)
        let fixedPath = try CatalogPath.normalizedDirectoryPath(for: fixedRoot)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }

        try await store.attachRemovableVolume(
            mountURL: cardRoot,
            identity: .volume(uuid: "churn-card"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardRoot)
        _ = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.removableSources.contains {
                $0.path == cardPath && $0.availability == .available && !$0.isScanning
            }
        }

        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: tempDefaults,
            volumeCapacity: ampleVolumeCapacity
        )
        await coordinator.start()
        // Ready requires proven naming facts (ARC-057); stand in for the
        // enrichment coordinator these tests do not run.
        await markEnrichmentLookedAtEveryRow(store, root: cardPath)
        await coordinator.setDestination(fixedPath, for: cardPath)

        let baseline = try await settledReadyGeneration(coordinator, source: cardPath)

        // No-op planRevision churn on the destination — the exact livelock trigger. It wakes
        // no import plan: only reorganization reads `planRevision`.
        for _ in 0 ..< 8 {
            _ = await store.bumpPlanRevision(for: fixedPath)
        }
        // Wait deterministically for the coordinator to settle after no-op churn.
        // If it livelocks, the generation keeps churning and settledReadyGeneration never returns.
        _ = try await settledReadyGeneration(coordinator, source: cardPath)

        let afterChurn = try #require(
            await coordinator.currentPresentations().first { $0.sourcePath == cardPath }
        )
        guard case let .ready(_, churnGeneration, _, _) = afterChurn.state else {
            Issue.record("Expected .ready after planRevision churn, got \(afterChurn.state)")
            await coordinator.shutdown()
            return
        }
        #expect(churnGeneration == baseline)

        // A real occupancy change still forces a replan.
        _ = await store.bumpNamespaceRevision(for: cardPath)
        let replanned = try await readyGeneration(
            coordinator,
            source: cardPath,
            greaterThan: baseline
        )
        #expect(replanned > baseline)
        await coordinator.shutdown()
    }

    /// ARC-046's enrichment clause: "enrichment overlay writes ... never advance it,
    /// so planning settles while a large cloud destination keeps enriching."
    ///
    /// Enriching an asset already in the *destination* renames nothing on disk, and
    /// `fetchDestinationOccupants` never reads a capture wall, so a naming write
    /// there cannot change what the plan copies or where. Rebuilding on it would
    /// cost ~480 ms of enumerate+plan roughly once a second, for as long as the
    /// library kept enriching, each rebuild producing the identical answer.
    /// State A means "no plan has ever existed for this attachment", not "a newer
    /// plan is on its way" (ARC-047). A rebuild that overwrote `phase` with
    /// `.building` would destroy the `ReadyContext` the user is looking at, so the bar
    /// would fall back to "Checking the card…" on every re-plan — once a second, for
    /// as long as anything kept invalidating, each cycle ending in the identical count.
    @Test func aRebuildKeepsShowingThePlanItIsReplacing() async throws {
        let temp = try makeTestDirectory()
        let fixedRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardRoot = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardRoot, withIntermediateDirectories: true)
        try writeCatalogStoreFile(cardRoot.appending(path: "card.jpg"), contents: "jpeg-bytes")

        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: fixedRoot)
        let fixedPath = try CatalogPath.normalizedDirectoryPath(for: fixedRoot)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }

        try await store.attachRemovableVolume(
            mountURL: cardRoot,
            identity: .volume(uuid: "hold-last-plan"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardRoot)
        _ = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.removableSources.contains {
                $0.path == cardPath && $0.availability == .available && !$0.isScanning
            }
        }

        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: tempDefaults,
            volumeCapacity: ampleVolumeCapacity
        )
        await coordinator.start()
        await markEnrichmentLookedAtEveryRow(store, root: cardPath)
        await coordinator.setDestination(fixedPath, for: cardPath)
        let baseline = try await settledReadyGeneration(coordinator, source: cardPath)

        // Force a real rebuild and sample the presentation while it is in flight.
        // Whatever the coordinator is doing internally, what the user is shown must
        // never regress from a proven plan to "we know nothing".
        _ = await store.bumpNamespaceRevision(for: cardPath)
        // Sample every frame until the rebuild has returned.
        var sawNonReady = false
        try await waitUntil(every: .milliseconds(10)) {
            let quiescent = await coordinator.isQuiescent
            if let presentation = await coordinator.currentPresentations().first(where: { $0.sourcePath == cardPath }) {
                switch presentation.state {
                case .ready, .executionUnavailable:
                    break
                default:
                    sawNonReady = true
                }
            }
            return quiescent
        }
        #expect(!sawNonReady, "the bar fell back to a non-ready state during a rebuild")

        let settled = try await settledReadyGeneration(coordinator, source: cardPath)
        #expect(settled >= baseline)
        await coordinator.shutdown()
    }

    /// The held plan is the answer for a *refresh*, never for rows it did not see. A
    /// card enumerates in pieces, so a plan can be proven over the first few files and
    /// then the card gains rows whose naming facts are pending. Holding that plan across
    /// the rebuilds of the metadata wait drew it as Ready — and the sidebar row as its
    /// eject button — between every pair of Preparing frames (2026-10-04: a 75-item plan
    /// alternating with `waitingForMetadata(done:, total: 930)` once a second).
    @Test func aPlanProvenBeforeNewPendingRowsIsNotHeldThroughTheMetadataWait() async throws {
        let temp = try makeTestDirectory()
        let fixedRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardRoot = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardRoot, withIntermediateDirectories: true)
        try writeCatalogStoreFile(cardRoot.appending(path: "first.jpg"), contents: "jpeg-bytes")

        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = makeTestStore(
            location: .inMemory,
            filesystemWatcher: watcher,
            scanCadence: .milliseconds(10)
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: fixedRoot)
        let fixedPath = try CatalogPath.normalizedDirectoryPath(for: fixedRoot)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }

        try await store.attachRemovableVolume(
            mountURL: cardRoot,
            identity: .volume(uuid: "held-plan-metadata-wait"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardRoot)
        _ = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.removableSources.contains {
                $0.path == cardPath && $0.availability == .available && !$0.isScanning
            }
        }

        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: tempDefaults,
            volumeCapacity: ampleVolumeCapacity
        )
        await coordinator.start()
        await markEnrichmentLookedAtEveryRow(store, root: cardPath)
        await coordinator.setDestination(fixedPath, for: cardPath)
        _ = try await settledReadyGeneration(coordinator, source: cardPath)

        // The card gains a row enrichment has not read: the coordinator must park in
        // the metadata wait rather than offer the one-file plan.
        let second = cardRoot.appending(path: "second.jpg")
        try writeCatalogStoreFile(second, contents: "more-jpeg-bytes")
        emit(FilesystemEvent(path: second.path(percentEncoded: false), flags: 0))
        try await waitUntil(every: .milliseconds(10)) {
            let presentation = await coordinator.currentPresentations().first { $0.sourcePath == cardPath }
            if case .waitingForMetadata = presentation?.state {
                return true
            }
            return false
        }

        // A rebuild over the still-pending set must keep reporting the count, never
        // the plan proven before the new row existed.
        await coordinator.retryPlanning(for: cardPath)
        var sawReady = false
        var sawCount = false
        // Sample every frame until the rebuild has returned.
        try await waitUntil(every: .milliseconds(10)) {
            let quiescent = await coordinator.isQuiescent
            if let presentation = await coordinator.currentPresentations().first(where: { $0.sourcePath == cardPath }) {
                switch presentation.state {
                case .ready, .executionUnavailable:
                    sawReady = true
                case .waitingForMetadata:
                    sawCount = true
                default:
                    break
                }
            }
            return quiescent
        }
        #expect(!sawReady, "the plan proven before the pending row was held through the metadata wait")
        #expect(sawCount, "the source must keep reporting its naming count while it waits")
        await coordinator.shutdown()
    }

    /// A plan proven after a metadata wait replaces the wait's count. While the card is
    /// read again, the held plan cannot be offered, and a rebuild then showed the count
    /// from before the plan — "0 of 1 items" about a card whose every row had been read —
    /// because the count was kept beside the plan instead of being replaced by it.
    @Test func aRebuildWhileTheCardIsReadAgainShowsNoCountFromBeforeItsPlan() async throws {
        let temp = try makeTestDirectory()
        let fixedRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardRoot = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardRoot, withIntermediateDirectories: true)
        try writeCatalogStoreFile(cardRoot.appending(path: "first.jpg"), contents: "jpeg-bytes")

        // Holds the card's next read once the test arms it, so the card stays mid-read.
        let held = ArrivalGate()
        let hold = ScanHold(gate: held)
        let scanner = CatalogScanner(
            scanRoot: { root, cadence, batch in
                await hold.pass()
                return try await CatalogScanner.live.scanRoot(root, cadence, batch)
            },
            scanSubtree: { root, subtree, cadence, batch in
                await hold.pass()
                return try await CatalogScanner.live.scanSubtree(root, subtree, cadence, batch)
            },
            observeFile: { url, root in
                await hold.pass()
                return try await CatalogScanner.live.observeFile(url, root)
            }
        )
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = makeTestStore(
            location: .inMemory,
            scanner: scanner,
            filesystemWatcher: watcher,
            scanCadence: .milliseconds(10)
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: fixedRoot)
        let fixedPath = try CatalogPath.normalizedDirectoryPath(for: fixedRoot)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardRoot,
            identity: .volume(uuid: "count-before-plan"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardRoot)
        _ = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.removableSources.contains {
                $0.path == cardPath && $0.availability == .available && !$0.isScanning
            }
        }

        let builder = ControlledImportPlanBuilder()
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: PreferencesDomain.suite(UUID().uuidString),
            planBuilder: builder,
            volumeCapacity: ampleVolumeCapacity
        )
        await coordinator.start()
        // The first plan, into the default destination, waits for the card's one row.
        try await waitUntil {
            await coordinator.currentPresentations().first { $0.sourcePath == cardPath }?.state
                == .waitingForMetadata(done: 0, total: 1)
        }
        await markEnrichmentLookedAtEveryRow(store, root: cardPath)
        _ = try await settledReadyGeneration(coordinator, source: cardPath)

        // The card gains a file and is read again; the read is held.
        await hold.arm()
        let second = cardRoot.appending(path: "second.jpg")
        try writeCatalogStoreFile(second, contents: "more-jpeg-bytes")
        emit(FilesystemEvent(path: second.path(percentEncoded: false), flags: 0))
        await held.waitForArrivals(1)
        // A destination change rebuilds the plan while the card is mid-read.
        await builder.suspendNextBuild(for: cardPath)
        _ = await store.bumpNamespaceRevision(for: fixedPath)
        try await waitForPendingBuilder(builder, source: cardPath)
        let shown: MediaOperationSourceState = try await waitForValue {
            guard let state = await coordinator.currentPresentations().first(where: { $0.sourcePath == cardPath })?.state else {
                return nil
            }
            if case .ready = state {
                return nil
            }
            return state
        }
        #expect(shown == .planning, "the bar showed \(shown) for a card whose rows were all read")

        await held.open()
        await builder.resumePendingBuild(for: cardPath)
        await coordinator.shutdown()
    }

    /// A destination change is the rebuild whose inputs changed: the held plan's
    /// counts were measured against the previous library, so holding it across
    /// the rebuild (`aRebuildKeepsShowingThePlanItIsReplacing`) would draw those
    /// counts under the new library's name and offer an Import the click would
    /// not honour. The bar must never present the old plan after the pick: it
    /// returns to Checking until a plan built against the new destination lands.
    @Test func changingTheDestinationNeverPresentsThePlanBuiltForTheOldOne() async throws {
        let temp = try makeTestDirectory()
        let firstRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let secondRoot = temp.appending(path: "Camera Roll", directoryHint: .isDirectory)
        let cardRoot = temp.appending(path: "Card", directoryHint: .isDirectory)
        for root in [firstRoot, secondRoot, cardRoot] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        try writeCatalogStoreFile(cardRoot.appending(path: "card.jpg"), contents: "jpeg-bytes")

        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: firstRoot)
        try await store.addLibrary(url: secondRoot)
        let firstPath = try CatalogPath.normalizedDirectoryPath(for: firstRoot)
        let secondPath = try CatalogPath.normalizedDirectoryPath(for: secondRoot)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }

        try await store.attachRemovableVolume(
            mountURL: cardRoot,
            identity: .volume(uuid: "destination-change"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardRoot)
        _ = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.removableSources.contains {
                $0.path == cardPath && $0.availability == .available && !$0.isScanning
            }
        }

        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: tempDefaults,
            volumeCapacity: ampleVolumeCapacity
        )
        await coordinator.start()
        await markEnrichmentLookedAtEveryRow(store, root: cardPath)
        await coordinator.setDestination(firstPath, for: cardPath)
        let oldGeneration = try await settledReadyGeneration(coordinator, source: cardPath)

        await coordinator.setDestination(secondPath, for: cardPath)
        // Every frame from the pick onward is either not a plan at all, or a
        // plan built for the new destination. The first read is deliberately
        // immediate: the old plan's presentation would appear here if it were
        // still being held.
        // Waits for the plan built for the new destination, watching every frame on
        // the way for the previous destination's plan.
        var sawOldPlan = false
        try await waitUntil {
            let presentations = await coordinator.currentPresentations()
            guard let presentation = presentations.first(where: { $0.sourcePath == cardPath }) else {
                return false
            }
            #expect(presentation.destinationPath == secondPath)
            guard case let .ready(_, generation, _, _) = presentation.state else {
                return false
            }
            if generation <= oldGeneration {
                sawOldPlan = true
                return false
            }
            return true
        }
        #expect(!sawOldPlan, "the bar presented the plan built for the previous destination after the pick")
        await coordinator.shutdown()
    }

    @Test func destinationNamingChurnDoesNotDisturbReadyPlan() async throws {
        let temp = try makeTestDirectory()
        let fixedRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardRoot = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardRoot, withIntermediateDirectories: true)
        try writeCatalogStoreFile(cardRoot.appending(path: "card.jpg"), contents: "jpeg-bytes")

        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: fixedRoot)
        let fixedPath = try CatalogPath.normalizedDirectoryPath(for: fixedRoot)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }

        try await store.attachRemovableVolume(
            mountURL: cardRoot,
            identity: .volume(uuid: "naming-churn-card"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardRoot)
        _ = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.removableSources.contains {
                $0.path == cardPath && $0.availability == .available && !$0.isScanning
            }
        }

        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: tempDefaults,
            volumeCapacity: ampleVolumeCapacity
        )
        await coordinator.start()
        // Ready requires proven naming facts (ARC-057); stand in for the
        // enrichment coordinator these tests do not run.
        await markEnrichmentLookedAtEveryRow(store, root: cardPath)
        await coordinator.setDestination(fixedPath, for: cardPath)
        let baseline = try await settledReadyGeneration(coordinator, source: cardPath)

        // The destination library enriching in the background: capture walls change,
        // no file moves, and no import plan is woken.
        for _ in 0 ..< 8 {
            await store.recordNamingChange(for: fixedPath)
        }
        _ = try await settledReadyGeneration(coordinator, source: cardPath)

        let afterChurn = try #require(
            await coordinator.currentPresentations().first { $0.sourcePath == cardPath }
        )
        guard case let .ready(_, churnGeneration, _, _) = afterChurn.state else {
            Issue.record("Expected .ready after destination naming churn, got \(afterChurn.state)")
            await coordinator.shutdown()
            return
        }
        #expect(churnGeneration == baseline)

        // The destination's *namespace* changing is a real invalidation and still replans.
        _ = await store.bumpNamespaceRevision(for: fixedPath)
        let replanned = try await readyGeneration(coordinator, source: cardPath, greaterThan: baseline)
        #expect(replanned > baseline)
        await coordinator.shutdown()
    }

    /// The other half of the role split: the *source's* capture walls are what the
    /// date/time destination name is derived from, so a naming write there must
    /// replan. Without this edge a card planned from filesystem mtime would keep
    /// those names after enrichment supplied the real capture wall — which is how
    /// 23 videos were imported twice five minutes apart (field evidence).
    @Test func sourceNamingChangeReplansBecauseItRenamesTheCopy() async throws {
        let temp = try makeTestDirectory()
        let fixedRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardRoot = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardRoot, withIntermediateDirectories: true)
        try writeCatalogStoreFile(cardRoot.appending(path: "card.jpg"), contents: "jpeg-bytes")

        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: fixedRoot)
        let fixedPath = try CatalogPath.normalizedDirectoryPath(for: fixedRoot)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }

        try await store.attachRemovableVolume(
            mountURL: cardRoot,
            identity: .volume(uuid: "source-naming-card"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardRoot)
        _ = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.removableSources.contains {
                $0.path == cardPath && $0.availability == .available && !$0.isScanning
            }
        }

        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: tempDefaults,
            volumeCapacity: ampleVolumeCapacity
        )
        await coordinator.start()
        // Ready requires proven naming facts (ARC-057); stand in for the
        // enrichment coordinator these tests do not run.
        await markEnrichmentLookedAtEveryRow(store, root: cardPath)
        await coordinator.setDestination(fixedPath, for: cardPath)
        let baseline = try await settledReadyGeneration(coordinator, source: cardPath)

        await store.recordNamingChange(for: cardPath)
        let replanned = try await readyGeneration(coordinator, source: cardPath, greaterThan: baseline)
        #expect(replanned > baseline)
        await coordinator.shutdown()
    }

    @Test func destinationDefaultsToFirstAddedLibrary() async throws {
        let fixture = try await makeDestinationFixture(
            libraryNames: ["Zebra", "Alpha", "Middle"],
            identity: .volume(uuid: "first-added")
        )
        let defaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(
            store: fixture.store,
            preferencesDomain: defaults,
            volumeCapacity: ampleVolumeCapacity
        )
        await coordinator.start()

        _ = try await readyGeneration(coordinator, source: fixture.source)
        let presentation = try #require(
            await coordinator.currentPresentations().first { $0.sourcePath == fixture.source }
        )
        #expect(presentation.destinationPath == fixture.libraries[0])
        await coordinator.shutdown()
    }

    @Test func destinationDefaultSkipsUnavailableFirstLibrary() async throws {
        let temp = try makeTestDirectory()
        let firstURL = temp.appending(path: "Zebra", directoryHint: .isDirectory)
        let secondURL = temp.appending(path: "Alpha", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        for url in [firstURL, secondURL, cardURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let firstStore = makeTestStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: firstURL)
        try await firstStore.addLibrary(url: secondURL)
        _ = try await waitForCatalogStoreState(firstStore) { snapshot in
            snapshot.libraries.count == 2 && snapshot.libraries.allSatisfy { !$0.isScanning }
        }
        try FileManager.default.removeItem(at: firstURL)

        let store = makeTestStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await store.start()
        _ = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.libraries.count == 2
                && snapshot.libraries.contains { $0.path.rawValue == firstURL.path && $0.availability == .unavailable }
                && snapshot.libraries.contains { $0.path.rawValue == secondURL.path && $0.availability == .available }
        }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: .volume(uuid: "skip-unavailable"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        // See makeDestinationFixture's comment.
        _ = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.removableSources.first?.activity == .idle
        }
        let source = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        let defaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: defaults,
            volumeCapacity: ampleVolumeCapacity
        )
        await coordinator.start()
        _ = try await readyGeneration(coordinator, source: source)
        let presentation = try #require(
            await coordinator.currentPresentations().first { $0.sourcePath == source }
        )
        let secondPath = try CatalogPath.normalizedDirectoryPath(for: secondURL)
        #expect(presentation.destinationPath == secondPath)
        await coordinator.shutdown()
    }

    /// "Dragging a library to the top changes [the default destination]" —
    /// including for a card already attached, which is the deliberate
    /// consequence of following the order rather than a fixed pick: the
    /// re-plan against the new first library is the same one the destination
    /// pop-up already triggers.
    @Test func destinationFollowsUserReorderWhileAttached() async throws {
        let fixture = try await makeDestinationFixture(
            libraryNames: ["Zebra", "Alpha", "Middle"],
            identity: .volume(uuid: "reorder-attached")
        )
        let defaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(
            store: fixture.store,
            preferencesDomain: defaults,
            volumeCapacity: ampleVolumeCapacity
        )
        await coordinator.start()
        let baseline = try await readyGeneration(coordinator, source: fixture.source)
        let before = try #require(
            await coordinator.currentPresentations().first { $0.sourcePath == fixture.source }
        )
        #expect(before.destinationPath == fixture.libraries[0])

        // Move the last library ("Middle") to the front.
        try await fixture.store.moveLibrary(fixture.libraries[2], .before(fixture.libraries[0]))

        _ = try await readyGeneration(coordinator, source: fixture.source, greaterThan: baseline)
        let after = try #require(
            await coordinator.currentPresentations().first { $0.sourcePath == fixture.source }
        )
        #expect(after.destinationPath == fixture.libraries[2])
        await coordinator.shutdown()
    }

    /// A destination picked via the pop-up survives an ordinary refresh even
    /// while it stays available — the "must survive from the moment it is made
    /// until that run finishes" rule (`import-bar.md`) — unlike the default,
    /// which always tracks the first available library.
    @Test func explicitDestinationSurvivesReorderWhileStillAvailable() async throws {
        let fixture = try await makeDestinationFixture(
            libraryNames: ["Zebra", "Alpha", "Middle"],
            identity: .volume(uuid: "explicit-survives-reorder")
        )
        let defaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(
            store: fixture.store,
            preferencesDomain: defaults,
            volumeCapacity: ampleVolumeCapacity
        )
        await coordinator.start()
        let baseline = try await readyGeneration(coordinator, source: fixture.source)
        await coordinator.setDestination(fixture.libraries[1], for: fixture.source)
        _ = try await readyGeneration(coordinator, source: fixture.source, greaterThan: baseline)

        // Reorder without touching the explicitly chosen library at all.
        try await fixture.store.moveLibrary(fixture.libraries[2], .before(fixture.libraries[0]))
        try await waitForCoordinatorQuiescence(coordinator)

        let after = try #require(
            await coordinator.currentPresentations().first { $0.sourcePath == fixture.source }
        )
        #expect(after.destinationPath == fixture.libraries[1])
        await coordinator.shutdown()
    }

    /// An automatic fallback is not a continued user choice: once an explicit
    /// pick becomes unavailable and the session falls back to first-available,
    /// it must resume tracking the default — not stay pinned to whichever
    /// library happened to be first at the moment of the fallback.
    @Test func explicitDestinationResumesTrackingDefaultAfterItBecomesUnavailable() async throws {
        let fixture = try await makeDestinationFixture(
            libraryNames: ["Zebra", "Alpha", "Middle"],
            identity: .volume(uuid: "explicit-then-unavailable")
        )
        let defaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(
            store: fixture.store,
            preferencesDomain: defaults,
            volumeCapacity: ampleVolumeCapacity
        )
        await coordinator.start()
        let baseline = try await readyGeneration(coordinator, source: fixture.source)
        await coordinator.setDestination(fixture.libraries[2], for: fixture.source)
        let afterPick = try await readyGeneration(coordinator, source: fixture.source, greaterThan: baseline)

        // The explicitly chosen library ("Middle") goes away. The session
        // falls back to first-available ("Zebra").
        #expect(try await fixture.store.removeLibrary(path: fixture.libraries[2]) == .removed)
        _ = try await readyGeneration(
            coordinator,
            source: fixture.source,
            greaterThan: afterPick
        )
        let afterFallback = try #require(
            await coordinator.currentPresentations().first { $0.sourcePath == fixture.source }
        )
        #expect(afterFallback.destinationPath == fixture.libraries[0])

        // Reordering now must move the (no-longer-explicit) destination too.
        try await fixture.store.moveLibrary(fixture.libraries[0], .down)
        try await waitForCoordinatorQuiescence(coordinator)
        let afterReorder = try #require(
            await coordinator.currentPresentations().first { $0.sourcePath == fixture.source }
        )
        #expect(afterReorder.destinationPath == fixture.libraries[1])
        await coordinator.shutdown()
    }

    /// ARC-047: the destination picked for a source is remembered in
    /// `destinationBySource` and read back on every new attachment, so a
    /// re-attached source resumes at its remembered destination rather than
    /// defaulting to `fixedAvailable.first`.
    ///
    /// Runs the reattach through the live `ImportPlanBuilding` path, the one
    /// production takes, so a reattach that never reaches `.ready` parks this
    /// test instead of hiding behind a controlled builder.
    @Test func reattachedSourceGetsRememberedDestination() async throws {
        let fixture = try await makeDestinationFixture(
            libraryNames: ["Zebra", "Alpha", "Middle"],
            identity: .volume(uuid: "reattach-remembers")
        )
        let defaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(
            store: fixture.store,
            preferencesDomain: defaults,
            volumeCapacity: ampleVolumeCapacity
        )
        await coordinator.start()
        let baseline = try await readyGeneration(coordinator, source: fixture.source)
        await coordinator.setDestination(fixture.libraries[2], for: fixture.source)
        _ = try await readyGeneration(coordinator, source: fixture.source, greaterThan: baseline)

        try await fixture.store.detachRemovableSource(identity: fixture.identity, reason: .ejected)
        _ = try await waitForCatalogStoreState(fixture.store) { snap in
            !snap.removableSources.contains { $0.path == fixture.source && $0.availability == .available }
        }
        try await waitForCoordinatorQuiescence(coordinator)

        try await fixture.store.attachRemovableVolume(
            mountURL: URL(fileURLWithPath: fixture.source.rawValue),
            identity: fixture.identity,
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        _ = try await readyGeneration(coordinator, source: fixture.source)
        let presentation = try #require(
            await coordinator.currentPresentations().first { $0.sourcePath == fixture.source }
        )
        #expect(presentation.destinationPath == fixture.libraries[2])
        await coordinator.shutdown()
    }

    private struct DestinationFixture {
        let store: CatalogStore
        let libraries: [LibraryRootPath]
        let source: LibraryRootPath
        let identity: DeviceIdentity
    }

    private func makeDestinationFixture(
        libraryNames: [String],
        identity: DeviceIdentity
    ) async throws -> DestinationFixture {
        let temp = try makeTestDirectory()
        let libraryURLs = libraryNames.map { temp.appending(path: $0, directoryHint: .isDirectory) }
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        for url in libraryURLs + [cardURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        for url in libraryURLs {
            try await store.addLibrary(url: url)
        }
        _ = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.libraries.count == libraryURLs.count && snapshot.libraries.allSatisfy { !$0.isScanning }
        }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: identity,
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        // `.ready` requires the card's own scan to
        // reach `.idle` (ImportSourceReadiness), not just a plan build
        // completing. Proving that here — before the coordinator ever starts —
        // rather than racing the coordinator's own catalog-change refresh
        // against it, matches `repeatedIntentAndOccupancyChangeStartOneBatch`'s
        // existing pattern and avoids the coordinator missing a same-beat
        // scan-completion event under this file's parallel test execution.
        _ = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.removableSources.first?.activity == .idle
        }
        let source = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        let libraries = try libraryURLs.map { try CatalogPath.normalizedDirectoryPath(for: $0) }
        // Ready also requires every source row's naming fact (ARC-057) to
        // be proven — enrichment must have read the file. Production's enrichment
        // coordinator does that for an attached card; this store has none.
        await markEnrichmentLookedAtEveryRow(store, root: source)
        return DestinationFixture(store: store, libraries: libraries, source: source, identity: identity)
    }

    /// Waits for the source to reach `.ready` (optionally with a generation past
    /// `minimum`) and returns that generation.
    ///
    /// `.ready` requires `ImportSourceReadiness == .ready`, i.e. the source's *real*
    /// filesystem scan reaching `.idle` — not just a plan build completing, which can
    /// race ahead of it. The wait follows the coordinator's publication stream, which
    /// replays the current presentations on subscribe, so it wakes exactly when a
    /// presentation is published and cannot miss one published before it subscribed.
    /// It has no deadline (see `waitUntil`).
    private func readyGeneration(
        _ coordinator: MediaOperationCoordinator,
        source: LibraryRootPath,
        greaterThan minimum: UInt64? = nil
    ) async throws -> UInt64 {
        for await presentations in await coordinator.presentationsStream() {
            guard let presentation = presentations.first(where: { $0.sourcePath == source }),
                  case let .ready(_, generation, _, _) = presentation.state,
                  minimum.map({ generation > $0 }) ?? true
            else {
                continue
            }
            return generation
        }
        throw AsyncTestTimeoutError.streamEnded("ready plan for \(source.rawValue)")
    }

    /// Waits until the coordinator has handled every change and returned every build,
    /// then returns the source's ready generation — so a later assertion is not raced
    /// by planning churn. A coordinator that keeps rebuilding never gets here.
    private func settledReadyGeneration(
        _ coordinator: MediaOperationCoordinator,
        source: LibraryRootPath
    ) async throws -> UInt64 {
        try await waitForValue {
            guard await coordinator.isQuiescent else {
                return nil
            }
            return await currentReadyGeneration(coordinator, source: source)
        }
    }

    private func currentReadyGeneration(
        _ coordinator: MediaOperationCoordinator,
        source: LibraryRootPath
    ) async -> UInt64? {
        let presentations = await coordinator.currentPresentations()
        guard let card = presentations.first(where: { $0.sourcePath == source }),
              case let .ready(_, generation, _, _) = card.state
        else {
            return nil
        }
        return generation
    }
}

struct ImportBatchSidebarPolicyTests {
    @Test func missingBatchFallsBackToDefaultSelection() {
        let pictures = CatalogLibraryState(
            root: LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures")),
            availability: .available,
            activity: .idle
        )
        let resolved = CatalogWindowPolicy.resolvedSidebarSelection(
            .importBatch(ImportBatchID(unixMilliseconds: 1)),
            libraries: [pictures],
            removableSources: [],
            importBatches: []
        )
        #expect(resolved == .library(pictures.path))
    }

    /// The import counter stuttered: it stepped forward and then back, hundreds of times.
    ///
    /// `ByteProgressTracker` is monotonic where it computes a sample, so a decrease never
    /// means progress reversed. It means the sample lost its ordering in transit — the
    /// executor's callback fires on ~10 copy worker threads and each spawns its own `Task`
    /// to reach the coordinator, and nothing orders those hops. Measured on a 999-item card:
    /// 528 of 3,925 published samples (13.5%) carried a smaller count than the one before.
    @Test func aProgressSampleThatArrivedLateIsRecognisedAsStale() {
        let newer = MediaOperationProgress(
            completedCount: 13,
            totalCount: 999,
            completedBytes: 402_477_056,
            totalBytes: 38_044_791_876,
            elapsedMs: 6017
        )
        let older = MediaOperationProgress(
            completedCount: 10,
            totalCount: 999,
            completedBytes: 385_699_840,
            totalBytes: 38_044_791_876,
            elapsedMs: 5996
        )

        #expect(older.isStale(comparedTo: newer), "a sample behind on both counters is stale")
        #expect(!newer.isStale(comparedTo: older), "the newer sample must still be applied")
        #expect(!newer.isStale(comparedTo: newer), "a repeat of the current sample is not stale")
    }

    /// Either counter regressing is enough. Bytes move on every callback while the item
    /// count only moves when a file settles, so a reordered pair often disagrees on just one
    /// of them — checking only bytes would let the item count walk backwards, which is the
    /// number the bar puts at L1.
    @Test func eitherCounterRegressingAloneIsStale() {
        let base = MediaOperationProgress(
            completedCount: 20,
            totalCount: 999,
            completedBytes: 1_000_000,
            totalBytes: 38_044_791_876,
            elapsedMs: 8000
        )
        let bytesBehind = MediaOperationProgress(
            completedCount: 20,
            totalCount: 999,
            completedBytes: 900_000,
            totalBytes: 38_044_791_876,
            elapsedMs: 7990
        )
        let countBehind = MediaOperationProgress(
            completedCount: 18,
            totalCount: 999,
            completedBytes: 1_000_000,
            totalBytes: 38_044_791_876,
            elapsedMs: 7990
        )

        #expect(bytesBehind.isStale(comparedTo: base))
        #expect(countBehind.isStale(comparedTo: base))
    }
}

/// Lets the Store's reads of a root through until armed, then holds each one at `gate`.
private actor ScanHold {
    private let gate: ArrivalGate
    private var armed = false

    init(gate: ArrivalGate) {
        self.gate = gate
    }

    func arm() {
        armed = true
    }

    func pass() async {
        guard armed else {
            return
        }
        await gate.arrive()
    }
}
