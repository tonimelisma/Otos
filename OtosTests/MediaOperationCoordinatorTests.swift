import Foundation
@testable import Otos
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
        let tempDefaults = TemporaryDefaults()
        defer { tempDefaults.cleanUp() }
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: tempDefaults.domain
        )
        await coordinator.start()
        await coordinator.setDestination(destination, for: source)
        _ = try await readyGeneration(coordinator, source: source)

        async let first: Void = coordinator.queueImport(for: source)
        try await Task.sleep(for: .milliseconds(20))
        async let second: Void = coordinator.queueImport(for: source)
        _ = await store.bumpOccupancyRevision(for: destination)
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
        let tempDefaults = TemporaryDefaults()
        defer { tempDefaults.cleanUp() }
        let coordinator = MediaOperationCoordinator(store: store, preferencesDomain: tempDefaults.domain)
        await coordinator.start()
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

        let tempDefaults = TemporaryDefaults()
        defer { tempDefaults.cleanUp() }
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: tempDefaults.domain
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

        let tempDefaults = TemporaryDefaults()
        defer { tempDefaults.cleanUp() }
        let coordinator = MediaOperationCoordinator(store: store, preferencesDomain: tempDefaults.domain)
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
            timestampFacts: EnrichmentTimestampFacts(original: captureDate),
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

        let tempDefaults = TemporaryDefaults()
        defer { tempDefaults.cleanUp() }
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: tempDefaults.domain
        )
        await coordinator.start()

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
        switch card.state {
        case .executionUnavailable, .queuedForReadiness, .waitingForMetadata, .ready, .planning:
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

        let tempDefaults = TemporaryDefaults()
        defer { tempDefaults.cleanUp() }
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: tempDefaults.domain
        )
        await coordinator.start()
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
        _ = await store.bumpOccupancyRevision(for: cardPath)
        let replanned = try await readyGeneration(
            coordinator,
            source: cardPath,
            greaterThan: baseline
        )
        #expect(replanned > baseline)
        await coordinator.shutdown()
    }

    @Test func destinationDefaultsToFirstAddedLibrary() async throws {
        let fixture = try await makeDestinationFixture(
            libraryNames: ["Zebra", "Alpha", "Middle"],
            identity: "volume:first-added"
        )
        let defaults = TemporaryDefaults()
        defer { defaults.cleanUp() }
        let coordinator = MediaOperationCoordinator(store: fixture.store, preferencesDomain: defaults.domain)
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
        let source = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        let defaults = TemporaryDefaults()
        defer { defaults.cleanUp() }
        let coordinator = MediaOperationCoordinator(store: store, preferencesDomain: defaults.domain)
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
        let defaults = TemporaryDefaults()
        defer { defaults.cleanUp() }
        defaults.defaults.set(
            [fixture.identity: fixture.libraries[2].rawValue],
            forKey: "import.destinationByDeviceIdentity"
        )
        defaults.defaults.set(fixture.libraries[1].rawValue, forKey: "import.lastUsedDestination")
        let coordinator = MediaOperationCoordinator(store: fixture.store, preferencesDomain: defaults.domain)
        await coordinator.start()
        _ = try await readyGeneration(coordinator, source: fixture.source)
        let presentation = try #require(
            await coordinator.currentPresentations().first { $0.sourcePath == fixture.source }
        )
        #expect(presentation.destinationPath == fixture.libraries[0])
        #expect(defaults.defaults.dictionary(forKey: "import.destinationByDeviceIdentity") == nil)
        #expect(defaults.defaults.string(forKey: "import.lastUsedDestination") == nil)
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
        let defaults = TemporaryDefaults()
        defer { defaults.cleanUp() }
        let coordinator = MediaOperationCoordinator(store: fixture.store, preferencesDomain: defaults.domain)
        await coordinator.start()
        let baseline = try await readyGeneration(coordinator, source: fixture.source)
        let before = try #require(
            await coordinator.currentPresentations().first { $0.sourcePath == fixture.source }
        )
        #expect(before.destinationPath == fixture.libraries[0])

        // Move the last library ("Middle") to the front.
        try await fixture.store.moveLibrary(from: 2, to: 0)

        _ = try await readyGeneration(coordinator, source: fixture.source, greaterThan: baseline, timeout: .seconds(15))
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
        let defaults = TemporaryDefaults()
        defer { defaults.cleanUp() }
        let coordinator = MediaOperationCoordinator(store: fixture.store, preferencesDomain: defaults.domain)
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
        let defaults = TemporaryDefaults()
        defer { defaults.cleanUp() }
        let coordinator = MediaOperationCoordinator(store: fixture.store, preferencesDomain: defaults.domain)
        await coordinator.start()
        let baseline = try await readyGeneration(coordinator, source: fixture.source)
        await coordinator.setDestination(fixture.libraries[2], for: fixture.source)
        let afterPick = try await readyGeneration(coordinator, source: fixture.source, greaterThan: baseline)

        // The explicitly chosen library ("Middle") goes away. The session
        // falls back to first-available ("Zebra").
        try await fixture.store.removeLibrary(path: fixture.libraries[2])
        _ = try await readyGeneration(coordinator, source: fixture.source, greaterThan: afterPick, timeout: .seconds(15))
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
        let source = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        let libraries = try libraryURLs.map { try CatalogPath.normalizedDirectoryPath(for: $0) }
        return DestinationFixture(store: store, libraries: libraries, source: source, identity: identity)
    }

    /// Wait for the source to reach `.ready` (optionally with a generation past
    /// `minimum`) and return that generation.
    private func readyGeneration(
        _ coordinator: MediaOperationCoordinator,
        source: LibraryRootPath,
        greaterThan minimum: UInt64? = nil,
        timeout: Duration = .seconds(5)
    ) async throws -> UInt64 {
        let deadline = ContinuousClock().now + timeout
        while ContinuousClock().now < deadline {
            if let generation = await currentReadyGeneration(coordinator, source: source),
               minimum.map({ generation > $0 }) ?? true
            {
                return generation
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw ReadyPlanTimeout()
    }

    /// Wait until the source's ready generation stops changing for `settleFor`,
    /// then return it — so a later assertion is not raced by initial planning churn.
    private func settledReadyGeneration(
        _ coordinator: MediaOperationCoordinator,
        source: LibraryRootPath,
        settleFor: Duration = .milliseconds(400),
        timeout: Duration = .seconds(8)
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
}
