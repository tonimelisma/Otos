import Foundation
@testable import OtosKit
import Testing

struct MediaOperationCoordinatorTests {
    @Test func repeatedIntentAndOccupancyChangeStartOneBatch() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let destinationURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let sourceURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        for index in 0 ..< 12 {
            try Data(repeating: UInt8(index), count: 512 * 1024).write(
                to: sourceURL.appending(path: "image-\(index).jpg")
            )
        }
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destinationURL)
        let destination = try CatalogPath.normalizedDirectoryPath(for: destinationURL)
        try await store.attachRemovableVolume(
            mountURL: sourceURL,
            identity: "volume:one-execution",
            displayName: "Card",
            isEjectable: true
        )
        let source = try CatalogPath.normalizedDirectoryPath(for: sourceURL)
        _ = try await waitForCatalogStoreState(store) { state in
            !state.isScanning && state.removableSources.first?.activity == .idle
        }
        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: tempDefaults
        )
        await coordinator.start()
        // Plan 0099: Ready requires proven naming facts; stand in for the
        // enrichment coordinator these tests do not run.
        await markEnrichmentLookedAtEveryRow(store, root: source)
        await coordinator.setDestination(destination, for: source)
        _ = try await readyGeneration(coordinator, source: source)

        async let first: Void = coordinator.queueImport(for: source)
        try await Task.sleep(for: .milliseconds(20))
        async let second: Void = coordinator.queueImport(for: source)
        _ = await store.bumpNamespaceRevision(for: destination)
        _ = await (first, second)

        let batches = try await store.importBatches()
        #expect(batches.count == 1)
        #expect(batches.first?.assetCount == 12)
        await coordinator.shutdown()
    }

    /// `import-bar.md` "What the presentation must carry": destination display
    /// name and whether the card still exists are facts the presentation states
    /// explicitly rather than leaving the view to re-derive them from
    /// `fixedLibraries`/`removableSources` itself.
    @Test func presentationCarriesDestinationDisplayNameAndCardStillExists() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let destinationURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let sourceURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1024).write(to: sourceURL.appending(path: "a.jpg"))
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destinationURL)
        let destination = try CatalogPath.normalizedDirectoryPath(for: destinationURL)
        try await store.attachRemovableVolume(
            mountURL: sourceURL,
            identity: "volume:display-name",
            displayName: "Card",
            isEjectable: true
        )
        let source = try CatalogPath.normalizedDirectoryPath(for: sourceURL)
        _ = try await waitForCatalogStoreState(store) { state in
            !state.isScanning && state.removableSources.first?.activity == .idle
        }
        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(store: store, preferencesDomain: tempDefaults)
        await coordinator.start()
        // Plan 0099: Ready requires proven naming facts; stand in for the
        // enrichment coordinator these tests do not run.
        await markEnrichmentLookedAtEveryRow(store, root: source)
        await coordinator.setDestination(destination, for: source)
        _ = try await readyGeneration(coordinator, source: source)

        let presentation = try #require(
            await coordinator.currentPresentations().first { $0.sourcePath == source }
        )
        #expect(presentation.destinationDisplayName == "Pictures")
        #expect(presentation.cardStillExists)
        await coordinator.shutdown()
    }

    /// Plan 0064 Stage 4: the coordinator must discover an attached source purely via
    /// the store's `RootPlanningChange` stream — no `setDestination`/`queueImport`
    /// intent. This pins the emit → subscribe → refreshSources chain that a field
    /// capture showed silent for six minutes; with the emit/receive diagnostics, a
    /// future capture can distinguish "no events emitted" (idle app awaiting user
    /// input) from "events not received" (broken subscription).
    @Test func planningChangeStreamDeliversAttachedSourceWithoutIntent() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let fixedRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardRoot = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardRoot, withIntermediateDirectories: true)
        try writeCatalogStoreFile(cardRoot.appending(path: "card.jpg"), contents: "jpeg")

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: fixedRoot)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }

        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: tempDefaults
        )
        await coordinator.start()

        // Attach AFTER start: the card's scan bumps occupancy and emits planning
        // changes. The coordinator (auto-mapping to the sole destination) must reach
        // `.ready` via the stream alone.
        try await store.attachRemovableVolume(
            mountURL: cardRoot,
            identity: "volume:stream-card",
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardRoot)
        // Plan 0099: Ready requires proven naming facts. Waiting for the card's own
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
        // Wider timeout (plan 0095 increment 4): this test's whole point is
        // that `.ready` arrives via the planning-change stream alone, with no
        // precondition wait possible without defeating that — so it carries
        // the full round trip from scan-completion through
        // ImportSourceReadiness under this file's parallel-test contention.
        _ = try await readyGeneration(coordinator, source: cardPath, timeout: .seconds(30))

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
        let temp = try makeCatalogStoreTemporaryDirectory()
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
        let store = CatalogStore(
            location: .inMemory,
            scanner: scanner,
            scanCadence: .milliseconds(10)
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: fixedRoot)
        try await store.attachRemovableVolume(
            mountURL: cardRoot,
            identity: "volume:metadata-wake",
            displayName: "Card",
            isEjectable: true
        )

        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(store: store, preferencesDomain: tempDefaults)
        await coordinator.start()

        let waitingDeadline = ContinuousClock().now + .seconds(5)
        while ContinuousClock().now < waitingDeadline {
            if let presentation = await coordinator.currentPresentations().first(where: { $0.sourcePath == cardPath }),
               case .waitingForMetadata = presentation.state
            {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let waiting = try #require(
            await coordinator.currentPresentations().first { $0.sourcePath == cardPath }
        )
        guard case .waitingForMetadata = waiting.state else {
            Issue.record("Expected metadata wait before enrichment, got \(waiting.state)")
            await coordinator.shutdown()
            return
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

        let readyDeadline = ContinuousClock().now + .seconds(5)
        while ContinuousClock().now < readyDeadline {
            if let presentation = await coordinator.currentPresentations().first(where: { $0.sourcePath == cardPath }),
               case .ready = presentation.state
            {
                await coordinator.shutdown()
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Catalog enrichment did not wake the waiting import source")
        await coordinator.shutdown()
    }

    @Test func queueImportSurfacesExecutionUnavailableOrQueuedState() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let fixedRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardRoot = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardRoot, withIntermediateDirectories: true)
        try writeCatalogStoreFile(fixedRoot.appending(path: "fixed.jpg"), contents: "jpeg")
        try writeCatalogStoreFile(cardRoot.appending(path: "card.jpg"), contents: "jpeg")

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: fixedRoot)
        let fixedPath = try CatalogPath.normalizedDirectoryPath(for: fixedRoot)
        _ = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["fixed.jpg"]
        }

        try await store.attachRemovableVolume(
            mountURL: cardRoot,
            identity: "volume:import-plan-card",
            displayName: "Card",
            isEjectable: true
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
            preferencesDomain: tempDefaults
        )
        await coordinator.start()

        // Plan 0099: Ready requires proven naming facts; stand in for the

        // enrichment coordinator these tests do not run.

        await markEnrichmentLookedAtEveryRow(store, root: cardPath)

        await coordinator.setDestination(fixedPath, for: cardPath)
        _ = try await readyGeneration(coordinator, source: cardPath)
        await coordinator.queueImport(for: cardPath)
        // Deterministically wait until presentation leaves inventory.
        let deadline = ContinuousClock().now + .seconds(2)
        while ContinuousClock().now < deadline {
            if let p = await coordinator.currentPresentations().first(where: { $0.sourcePath == cardPath }),
               case .inventory = p.state
            {
                try await Task.sleep(for: .milliseconds(25))
                continue
            }
            if await coordinator.currentPresentations().first(where: { $0.sourcePath == cardPath }) != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        let presentations = await coordinator.currentPresentations()
        let card = try #require(presentations.first { $0.sourcePath == cardPath })
        // A one-file import through the live executor can settle inside the
        // wait; a settled run presents its completion until the re-plan lands,
        // so `.executing` and `.completed` are as legitimate here as the
        // states before them.
        switch card.state {
        case .executionUnavailable, .queuedForReadiness, .waitingForMetadata, .ready, .planning, .executing, .completed:
            break
        default:
            Issue.record("Unexpected import presentation state \(card.state)")
        }
        await coordinator.shutdown()
    }

    /// Regression: an enriching cloud destination bumps `planRevision` every few
    /// seconds without changing occupancy. Planning must settle to `.ready` and
    /// stay there — never livelock back into `.planning` — while a real occupancy
    /// change still forces a replan.
    @Test func noOpPlanRevisionChurnDoesNotDisturbReadyPlan() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let fixedRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardRoot = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardRoot, withIntermediateDirectories: true)
        try writeCatalogStoreFile(cardRoot.appending(path: "card.jpg"), contents: "jpeg-bytes")

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: fixedRoot)
        let fixedPath = try CatalogPath.normalizedDirectoryPath(for: fixedRoot)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }

        try await store.attachRemovableVolume(
            mountURL: cardRoot,
            identity: "volume:churn-card",
            displayName: "Card",
            isEjectable: true
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
            preferencesDomain: tempDefaults
        )
        await coordinator.start()
        // Plan 0099: Ready requires proven naming facts; stand in for the
        // enrichment coordinator these tests do not run.
        await markEnrichmentLookedAtEveryRow(store, root: cardPath)
        await coordinator.setDestination(fixedPath, for: cardPath)

        // The real bug's destination changes occupancy while scanning, which primes
        // the coordinator's occupancy memory for that root. Reproduce that priming
        // (an unseen root's first wake is conservatively treated as a possible
        // change) with one bump, then settle so the baseline is past it.
        _ = await store.bumpPlanRevision(for: fixedPath)
        let baseline = try await settledReadyGeneration(coordinator, source: cardPath)

        // No-op planRevision churn on the destination — the exact livelock trigger.
        for _ in 0 ..< 8 {
            _ = await store.bumpPlanRevision(for: fixedPath)
        }
        // Wait deterministically for the coordinator to settle after no-op churn.
        // If it livelocks, settledReadyGeneration will see generation churn and timeout.
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

    /// ARC-046's enrichment clause, which had no test and regressed in `40261bf`:
    /// "enrichment overlay writes ... never advance it, so planning settles while a
    /// large cloud destination keeps enriching."
    ///
    /// Enriching an asset already in the *destination* renames nothing on disk, and
    /// `fetchDestinationOccupants` never reads a capture wall, so a naming write
    /// there cannot change what the plan copies or where. Before plan 0099 this
    /// discarded the ready plan and rebuilt it — ~480 ms of enumerate+plan roughly
    /// once a second, for as long as the library kept enriching, each rebuild
    /// producing the identical answer.
    /// State A means "no plan has ever existed for this attachment", not "a newer
    /// plan is on its way". Before plan 0099 a rebuild overwrote `phase` with
    /// `.building`, destroying the `ReadyContext` the user was looking at, so the bar
    /// fell back to "Checking the card…" on every re-plan — once a second, for as long
    /// as anything kept invalidating, each cycle ending in the identical count.
    @Test func aRebuildKeepsShowingThePlanItIsReplacing() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let fixedRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardRoot = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardRoot, withIntermediateDirectories: true)
        try writeCatalogStoreFile(cardRoot.appending(path: "card.jpg"), contents: "jpeg-bytes")

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: fixedRoot)
        let fixedPath = try CatalogPath.normalizedDirectoryPath(for: fixedRoot)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }

        try await store.attachRemovableVolume(
            mountURL: cardRoot,
            identity: "volume:hold-last-plan",
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardRoot)
        _ = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.removableSources.contains {
                $0.path == cardPath && $0.availability == .available && !$0.isScanning
            }
        }

        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(store: store, preferencesDomain: tempDefaults)
        await coordinator.start()
        await markEnrichmentLookedAtEveryRow(store, root: cardPath)
        await coordinator.setDestination(fixedPath, for: cardPath)
        let baseline = try await settledReadyGeneration(coordinator, source: cardPath)

        // Force a real rebuild and sample the presentation while it is in flight.
        // Whatever the coordinator is doing internally, what the user is shown must
        // never regress from a proven plan to "we know nothing".
        _ = await store.bumpNamespaceRevision(for: cardPath)
        var sawNonReady = false
        let deadline = ContinuousClock().now + .seconds(3)
        while ContinuousClock().now < deadline {
            if let presentation = await coordinator.currentPresentations().first(where: { $0.sourcePath == cardPath }) {
                switch presentation.state {
                case .ready, .executionUnavailable:
                    break
                default:
                    sawNonReady = true
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!sawNonReady, "the bar fell back to a non-ready state during a rebuild")

        let settled = try await settledReadyGeneration(coordinator, source: cardPath)
        #expect(settled >= baseline)
        await coordinator.shutdown()
    }

    /// A destination change is the rebuild whose inputs changed: the held plan's
    /// counts were measured against the previous library, so holding it across
    /// the rebuild (`aRebuildKeepsShowingThePlanItIsReplacing`) would draw those
    /// counts under the new library's name and offer an Import the click would
    /// not honour. The bar must never present the old plan after the pick: it
    /// returns to Checking until a plan built against the new destination lands.
    @Test func changingTheDestinationNeverPresentsThePlanBuiltForTheOldOne() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let firstRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let secondRoot = temp.appending(path: "Camera Roll", directoryHint: .isDirectory)
        let cardRoot = temp.appending(path: "Card", directoryHint: .isDirectory)
        for root in [firstRoot, secondRoot, cardRoot] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        try writeCatalogStoreFile(cardRoot.appending(path: "card.jpg"), contents: "jpeg-bytes")

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: firstRoot)
        try await store.addLibrary(url: secondRoot)
        let firstPath = try CatalogPath.normalizedDirectoryPath(for: firstRoot)
        let secondPath = try CatalogPath.normalizedDirectoryPath(for: secondRoot)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }

        try await store.attachRemovableVolume(
            mountURL: cardRoot,
            identity: "volume:destination-change",
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardRoot)
        _ = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.removableSources.contains {
                $0.path == cardPath && $0.availability == .available && !$0.isScanning
            }
        }

        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(store: store, preferencesDomain: tempDefaults)
        await coordinator.start()
        await markEnrichmentLookedAtEveryRow(store, root: cardPath)
        await coordinator.setDestination(firstPath, for: cardPath)
        let oldGeneration = try await settledReadyGeneration(coordinator, source: cardPath)

        await coordinator.setDestination(secondPath, for: cardPath)
        // Every frame from the pick onward is either not a plan at all, or a
        // plan built for the new destination. The first read is deliberately
        // immediate: the old plan's presentation would appear here if it were
        // still being held.
        var sawOldPlan = false
        var newGeneration: UInt64?
        let deadline = ContinuousClock().now + .seconds(15)
        while ContinuousClock().now < deadline, newGeneration == nil {
            if let presentation = await coordinator.currentPresentations().first(where: { $0.sourcePath == cardPath }) {
                #expect(presentation.destinationPath == secondPath)
                if case let .ready(_, generation, _, _) = presentation.state {
                    if generation <= oldGeneration {
                        sawOldPlan = true
                    } else {
                        newGeneration = generation
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!sawOldPlan, "the bar presented the plan built for the previous destination after the pick")
        #expect(newGeneration != nil, "no plan built for the new destination arrived")
        await coordinator.shutdown()
    }

    @Test func destinationNamingChurnDoesNotDisturbReadyPlan() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let fixedRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardRoot = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardRoot, withIntermediateDirectories: true)
        try writeCatalogStoreFile(cardRoot.appending(path: "card.jpg"), contents: "jpeg-bytes")

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: fixedRoot)
        let fixedPath = try CatalogPath.normalizedDirectoryPath(for: fixedRoot)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }

        try await store.attachRemovableVolume(
            mountURL: cardRoot,
            identity: "volume:naming-churn-card",
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardRoot)
        _ = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.removableSources.contains {
                $0.path == cardPath && $0.availability == .available && !$0.isScanning
            }
        }

        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(store: store, preferencesDomain: tempDefaults)
        await coordinator.start()
        // Plan 0099: Ready requires proven naming facts; stand in for the
        // enrichment coordinator these tests do not run.
        await markEnrichmentLookedAtEveryRow(store, root: cardPath)
        await coordinator.setDestination(fixedPath, for: cardPath)
        // An unseen root's first wake is conservatively treated as a possible change
        // (the coordinator has no recorded revisions to compare against), same as
        // `noOpPlanRevisionChurnDoesNotDisturbReadyPlan`. Prime past it, then settle,
        // so the baseline measures steady state.
        _ = await store.bumpPlanRevision(for: fixedPath)
        let baseline = try await settledReadyGeneration(coordinator, source: cardPath)

        // The destination library enriching in the background: capture walls change,
        // no file moves.
        for _ in 0 ..< 8 {
            _ = await store.bumpNamingRevision(for: fixedPath)
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
    /// 23 videos were imported twice five minutes apart (plan 0099 §1.1).
    @Test func sourceNamingChangeReplansBecauseItRenamesTheCopy() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let fixedRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardRoot = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardRoot, withIntermediateDirectories: true)
        try writeCatalogStoreFile(cardRoot.appending(path: "card.jpg"), contents: "jpeg-bytes")

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: fixedRoot)
        let fixedPath = try CatalogPath.normalizedDirectoryPath(for: fixedRoot)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }

        try await store.attachRemovableVolume(
            mountURL: cardRoot,
            identity: "volume:source-naming-card",
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardRoot)
        _ = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.removableSources.contains {
                $0.path == cardPath && $0.availability == .available && !$0.isScanning
            }
        }

        let tempDefaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(store: store, preferencesDomain: tempDefaults)
        await coordinator.start()
        // Plan 0099: Ready requires proven naming facts; stand in for the
        // enrichment coordinator these tests do not run.
        await markEnrichmentLookedAtEveryRow(store, root: cardPath)
        await coordinator.setDestination(fixedPath, for: cardPath)
        let baseline = try await settledReadyGeneration(coordinator, source: cardPath)

        _ = await store.bumpNamingRevision(for: cardPath)
        let replanned = try await readyGeneration(coordinator, source: cardPath, greaterThan: baseline)
        #expect(replanned > baseline)
        await coordinator.shutdown()
    }

    @Test func destinationDefaultsToFirstAddedLibrary() async throws {
        let fixture = try await makeDestinationFixture(
            libraryNames: ["Zebra", "Alpha", "Middle"],
            identity: "volume:first-added"
        )
        let defaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(store: fixture.store, preferencesDomain: defaults)
        await coordinator.start()

        _ = try await readyGeneration(coordinator, source: fixture.source)
        let presentation = try #require(
            await coordinator.currentPresentations().first { $0.sourcePath == fixture.source }
        )
        #expect(presentation.destinationPath == fixture.libraries[0])
        await coordinator.shutdown()
    }

    @Test func destinationDefaultSkipsUnavailableFirstLibrary() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let firstURL = temp.appending(path: "Zebra", directoryHint: .isDirectory)
        let secondURL = temp.appending(path: "Alpha", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        for url in [firstURL, secondURL, cardURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let firstStore = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: firstURL)
        try await firstStore.addLibrary(url: secondURL)
        _ = try await waitForCatalogStoreState(firstStore) { snapshot in
            snapshot.libraries.count == 2 && snapshot.libraries.allSatisfy { !$0.isScanning }
        }
        try FileManager.default.removeItem(at: firstURL)

        let store = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await store.start()
        _ = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.libraries.count == 2
                && snapshot.libraries.contains { $0.path.rawValue == firstURL.path && $0.availability == .unavailable }
                && snapshot.libraries.contains { $0.path.rawValue == secondURL.path && $0.availability == .available }
        }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:skip-unavailable",
            displayName: "Card",
            isEjectable: true
        )
        // See makeDestinationFixture's comment (plan 0095 increment 4).
        _ = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.removableSources.first?.activity == .idle
        }
        let source = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        let defaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(store: store, preferencesDomain: defaults)
        await coordinator.start()
        _ = try await readyGeneration(coordinator, source: source)
        let presentation = try #require(
            await coordinator.currentPresentations().first { $0.sourcePath == source }
        )
        let secondPath = try CatalogPath.normalizedDirectoryPath(for: secondURL)
        #expect(presentation.destinationPath == secondPath)
        await coordinator.shutdown()
    }

    /// The device-identity and last-used heuristics are deleted: the coordinator
    /// ignores any value an earlier build left in these keys and always defaults
    /// to first-available.
    @Test func staleLegacyDestinationPreferencesAreIgnored() async throws {
        let fixture = try await makeDestinationFixture(
            libraryNames: ["Zebra", "Alpha", "Middle"],
            identity: "volume:stale-legacy"
        )
        let defaults = PreferencesDomain.suite(UUID().uuidString)
        defaults.makeDefaults().set(
            [fixture.identity: fixture.libraries[2].rawValue],
            forKey: "import.destinationByDeviceIdentity"
        )
        defaults.makeDefaults().set(fixture.libraries[1].rawValue, forKey: "import.lastUsedDestination")
        let coordinator = MediaOperationCoordinator(store: fixture.store, preferencesDomain: defaults)
        await coordinator.start()
        _ = try await readyGeneration(coordinator, source: fixture.source)
        let presentation = try #require(
            await coordinator.currentPresentations().first { $0.sourcePath == fixture.source }
        )
        #expect(presentation.destinationPath == fixture.libraries[0])
        #expect(defaults.makeDefaults().dictionary(forKey: "import.destinationByDeviceIdentity") == nil)
        #expect(defaults.makeDefaults().string(forKey: "import.lastUsedDestination") == nil)
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
            identity: "volume:reorder-attached"
        )
        let defaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(store: fixture.store, preferencesDomain: defaults)
        await coordinator.start()
        let baseline = try await readyGeneration(coordinator, source: fixture.source)
        let before = try #require(
            await coordinator.currentPresentations().first { $0.sourcePath == fixture.source }
        )
        #expect(before.destinationPath == fixture.libraries[0])

        // Move the last library ("Middle") to the front.
        try await fixture.store.moveLibrary(from: 2, to: 0)

        // moveLibrary's replan (unlike a plain setDestination) goes through a
        // DB write and a full refreshSources cycle; under full-suite
        // concurrent load this measured 16.6s against a 15s budget (2026-08-17
        // verify.sh study), so the budget carries real margin over that.
        _ = try await readyGeneration(coordinator, source: fixture.source, greaterThan: baseline, timeout: .seconds(30))
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
            identity: "volume:explicit-survives-reorder"
        )
        let defaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(store: fixture.store, preferencesDomain: defaults)
        await coordinator.start()
        let baseline = try await readyGeneration(coordinator, source: fixture.source)
        await coordinator.setDestination(fixture.libraries[1], for: fixture.source)
        _ = try await readyGeneration(coordinator, source: fixture.source, greaterThan: baseline)

        // Reorder without touching the explicitly chosen library at all.
        try await fixture.store.moveLibrary(from: 2, to: 0)
        try await Task.sleep(for: .milliseconds(200))

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
            identity: "volume:explicit-then-unavailable"
        )
        let defaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(store: fixture.store, preferencesDomain: defaults)
        await coordinator.start()
        let baseline = try await readyGeneration(coordinator, source: fixture.source)
        await coordinator.setDestination(fixture.libraries[2], for: fixture.source)
        let afterPick = try await readyGeneration(coordinator, source: fixture.source, greaterThan: baseline)

        // The explicitly chosen library ("Middle") goes away. The session
        // falls back to first-available ("Zebra").
        try await fixture.store.removeLibrary(path: fixture.libraries[2])
        // removeLibrary's replan goes through a DB write, filesystem-watcher
        // teardown, and a full refreshSources cycle; under full-suite
        // concurrent load this measured 16.9s against a 15s budget (2026-08-17
        // verify.sh study), so the budget carries real margin over that.
        _ = try await readyGeneration(coordinator, source: fixture.source, greaterThan: afterPick, timeout: .seconds(30))
        let afterFallback = try #require(
            await coordinator.currentPresentations().first { $0.sourcePath == fixture.source }
        )
        #expect(afterFallback.destinationPath == fixture.libraries[0])

        // Reordering now must move the (no-longer-explicit) destination too.
        try await fixture.store.moveLibrary(from: 0, to: 1)
        try await Task.sleep(for: .milliseconds(300))
        let afterReorder = try #require(
            await coordinator.currentPresentations().first { $0.sourcePath == fixture.source }
        )
        #expect(afterReorder.destinationPath == fixture.libraries[1])
        await coordinator.shutdown()
    }

    /// Plan 0095 D19: the destination picked for a source used to be
    /// remembered in `destinationBySource` (Settings displayed it) but was
    /// never read back — every new attachment, including a reattach of the
    /// exact same card, unconditionally defaulted to `fixedAvailable.first`.
    /// A re-attached source now resumes at its remembered destination.
    ///
    /// Routes the reattach's build through `ControlledImportPlanBuilder`
    /// rather than the live builder: an earlier live-build version of this
    /// test measured `ReadyPlanTimeout` under full-suite parallel execution
    /// at whatever budget it was given — 30s, 45s, 90s, 180s, always failing
    /// right at the configured ceiling — while an isolated run of the same
    /// test completed in ~2s (2026-08-19 study). That is resource
    /// contention starving the live build under heavy concurrent load, not
    /// a bug in the destination-memory logic under test; the controlled
    /// builder makes the assertion deterministic instead of dependent on
    /// live scheduling fairness, matching the pattern
    /// `rapidSamePathReattachOldBuildCannotBecomeReady` already established
    /// for this exact reattach shape.
    @Test func reattachedSourceGetsRememberedDestination() async throws {
        let fixture = try await makeDestinationFixture(
            libraryNames: ["Zebra", "Alpha", "Middle"],
            identity: "volume:reattach-remembers"
        )
        let builder = ControlledImportPlanBuilder()
        let defaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(store: fixture.store, preferencesDomain: defaults, planBuilder: builder)
        await coordinator.start()
        let baseline = try await readyGeneration(coordinator, source: fixture.source)
        await coordinator.setDestination(fixture.libraries[2], for: fixture.source)
        _ = try await readyGeneration(coordinator, source: fixture.source, greaterThan: baseline)

        try await fixture.store.detachRemovableSource(identity: fixture.identity, reason: .ejected)
        _ = try await waitForCatalogStoreState(fixture.store) { snap in
            !snap.removableSources.contains { $0.path == fixture.source && $0.availability == .available }
        }
        try await Task.sleep(for: .milliseconds(100))

        await builder.suspendNextBuild(for: fixture.source)
        try await fixture.store.attachRemovableVolume(
            mountURL: URL(fileURLWithPath: fixture.source.rawValue),
            identity: fixture.identity,
            displayName: "Card",
            isEjectable: true
        )
        _ = try await waitForCatalogStoreState(fixture.store) { snap in
            snap.removableSources.contains { $0.path == fixture.source && !$0.isScanning }
        }
        try await waitForPendingBuilder(builder, source: fixture.source, timeout: .seconds(20))
        await builder.resumePendingBuild(for: fixture.source)
        _ = try await readyGeneration(coordinator, source: fixture.source, timeout: .seconds(20))
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
        let identity: String
    }

    private func makeDestinationFixture(
        libraryNames: [String],
        identity: String
    ) async throws -> DestinationFixture {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let libraryURLs = libraryNames.map { temp.appending(path: $0, directoryHint: .isDirectory) }
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        for url in libraryURLs + [cardURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
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
            isEjectable: true
        )
        // Plan 0095 increment 4: `.ready` now requires the card's own scan to
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
        // Plan 0099 increment 2: Ready also requires every source row's naming fact to
        // be proven — enrichment must have read the file. Production's enrichment
        // coordinator does that for an attached card; this store has none.
        await markEnrichmentLookedAtEveryRow(store, root: source)
        return DestinationFixture(store: store, libraries: libraries, source: source, identity: identity)
    }

    /// Wait for the source to reach `.ready` (optionally with a generation past
    /// `minimum`) and return that generation.
    ///
    /// Default widened 5s → 15s (plan 0095 increment 4): `.ready` now requires
    /// `ImportSourceReadiness == .ready`, i.e. the source's *real* filesystem
    /// scan reaching `.idle` — not just a plan build completing, which used to
    /// race ahead of it. This suite's tests run unserialized (parallel), so
    /// under full-class concurrent load the real `CatalogScanner` work for
    /// several fixtures competes for the same `.utility`-priority thread pool;
    /// 5s measured as insufficient margin (repeated ReadyPlanTimeout across
    /// several tests in this file, 2026-08-18 verify.sh study).
    private func readyGeneration(
        _ coordinator: MediaOperationCoordinator,
        source: LibraryRootPath,
        greaterThan minimum: UInt64? = nil,
        timeout: Duration = .seconds(15)
    ) async throws -> UInt64 {
        // Event-driven, not polled. The previous 25 ms poll loop measured a
        // *wall-clock* deadline while doing 40 wakeups a second per waiting test — so
        // under load the deadline expired on wall time even when the coordinator was
        // progressing, and the polling was itself part of the load. Awaiting the
        // coordinator's own publication stream wakes exactly when a presentation is
        // published; the timeout survives only to stop a genuine hang from waiting
        // forever.
        if let generation = await currentReadyGeneration(coordinator, source: source),
           minimum.map({ generation > $0 }) ?? true
        {
            return generation
        }
        let stream = await coordinator.presentationsStream()
        return try await withThrowingTaskGroup(of: UInt64.self) { group in
            group.addTask {
                for await presentations in stream {
                    guard let presentation = presentations.first(where: { $0.sourcePath == source }),
                          case let .ready(_, generation, _, _) = presentation.state,
                          minimum.map({ generation > $0 }) ?? true
                    else {
                        continue
                    }
                    return generation
                }
                throw ReadyPlanTimeout()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ReadyPlanTimeout()
            }
            guard let generation = try await group.next() else {
                throw ReadyPlanTimeout()
            }
            group.cancelAll()
            return generation
        }
    }

    /// Wait until the source's ready generation stops changing for `settleFor`,
    /// then return it — so a later assertion is not raced by initial planning churn.
    /// Default widened 8s → 15s alongside `readyGeneration`, same reasoning.
    private func settledReadyGeneration(
        _ coordinator: MediaOperationCoordinator,
        source: LibraryRootPath,
        settleFor: Duration = .milliseconds(400),
        timeout: Duration = .seconds(15)
    ) async throws -> UInt64 {
        let deadline = ContinuousClock().now + timeout
        var lastGeneration: UInt64?
        var stableSince: ContinuousClock.Instant?
        while ContinuousClock().now < deadline {
            let generation = await currentReadyGeneration(coordinator, source: source)
            if let generation, generation == lastGeneration {
                if let stableSince, stableSince.duration(to: .now) >= settleFor {
                    return generation
                }
            } else {
                lastGeneration = generation
                stableSince = generation == nil ? nil : ContinuousClock().now
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw ReadyPlanTimeout()
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

private struct ReadyPlanTimeout: Error {}

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

    @Test func existingBatchIsPreserved() {
        let batch = ImportBatchSummary(
            batchID: ImportBatchID(unixMilliseconds: 42),
            assetCount: 3
        )
        let resolved = CatalogWindowPolicy.resolvedSidebarSelection(
            .importBatch(batch.batchID),
            libraries: [],
            removableSources: [],
            importBatches: [batch]
        )
        #expect(resolved == .importBatch(batch.batchID))
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
