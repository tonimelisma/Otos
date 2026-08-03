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
        let coordinator = MediaOperationCoordinator(store: store)
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

        let coordinator = MediaOperationCoordinator(store: store)
        await coordinator.start()
        defer { Task { await coordinator.shutdown() } }

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
            return
        }
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

        let coordinator = MediaOperationCoordinator(store: store)
        await coordinator.start()
        defer {
            Task { await coordinator.shutdown() }
        }

        await coordinator.setDestination(fixedPath, for: cardPath)
        try await Task.sleep(for: .milliseconds(250))
        await coordinator.queueImport(for: cardPath)
        try await Task.sleep(for: .milliseconds(400))

        let presentations = await coordinator.currentPresentations()
        let card = try #require(presentations.first { $0.sourcePath == cardPath })
        switch card.state {
        case .executionUnavailable, .queuedForReadiness, .waitingForMetadata, .ready, .planning:
            break
        default:
            Issue.record("Unexpected import presentation state \(card.state)")
        }
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

        let coordinator = MediaOperationCoordinator(store: store)
        await coordinator.start()
        defer {
            Task { await coordinator.shutdown() }
        }
        await coordinator.setDestination(fixedPath, for: cardPath)

        // The real bug's destination changes occupancy while scanning, which primes
        // the coordinator's occupancy memory for that root. Reproduce that priming
        // (an unseen root's first wake is conservatively treated as a possible
        // change) with one bump, then settle so the baseline is past it.
        _ = await store.bumpPlanRevision(for: fixedPath)
        try await Task.sleep(for: .milliseconds(150))
        let baseline = try await settledReadyGeneration(coordinator, source: cardPath)

        // No-op planRevision churn on the destination — the exact livelock trigger.
        for _ in 0 ..< 8 {
            _ = await store.bumpPlanRevision(for: fixedPath)
        }
        try await Task.sleep(for: .milliseconds(300))

        let afterChurn = try #require(
            await coordinator.currentPresentations().first { $0.sourcePath == cardPath }
        )
        guard case let .ready(_, churnGeneration, _) = afterChurn.state else {
            Issue.record("Expected .ready after planRevision churn, got \(afterChurn.state)")
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
              case let .ready(_, generation, _) = card.state
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
