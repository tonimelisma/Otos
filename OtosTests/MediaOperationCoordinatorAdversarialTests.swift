import Foundation
import OSLog
@testable import OtosKit
import Testing

/// Adversarial lifecycle tests for MediaOperationCoordinator.
/// These prove stale-completion rejection, ledger release, and deterministic
/// execution boundaries via the controlled plan-builder and execution controls.
@Suite(.serialized)
struct MediaOperationCoordinatorAdversarialTests {
    // MARK: - Helpers

    private func log(_ msg: String) {
        OtosLog.catalog.notice("TEST \(msg)")
    }

    private func makeTempRoot() throws -> URL {
        try makeCatalogStoreTemporaryDirectory()
    }

    private func waitForReady(
        _ coordinator: MediaOperationCoordinator,
        source: LibraryRootPath
    ) async throws -> MediaOperationPlan {
        try await waitForValue(every: .milliseconds(20)) {
            if let plan = await coordinator.readyPlan(for: source) {
                return plan
            }
            if let pres = await coordinator.currentPresentations().first(where: { $0.sourcePath == source }) {
                switch pres.state {
                case .failed, .planningFailed:
                    throw TestError.planFailed(pres.state)
                default:
                    break
                }
            }
            return nil
        }
    }

    private func waitForPresentation(
        _ coordinator: MediaOperationCoordinator,
        source: LibraryRootPath,
        predicate: (MediaOperationSourcePresentation) -> Bool
    ) async throws -> MediaOperationSourcePresentation {
        try await waitForValue(every: .milliseconds(20)) {
            await coordinator.currentPresentations().first { $0.sourcePath == source && predicate($0) }
        }
    }

    // `waitForPendingBuilder` and `waitForPendingBuilderCount` are the shared gates in
    // `MediaOperationCoordinatorTestSupport.swift`. Do not add same-named private
    // wrappers here: an unqualified call inside this type resolves to the member, not
    // the free function, so a wrapper that "delegates" calls itself. Because the call
    // is `async`, each frame is heap-allocated rather than stack-allocated, so the
    // recursion does not overflow — it allocates until the machine exhausts swap.

    private func waitForPendingExecution(
        _ control: ControlledExecutionControl,
        source: LibraryRootPath
    ) async throws {
        try await waitUntil(every: .milliseconds(20)) { await control.pendingSources().contains(source) }
    }

    private func waitUntilNoPresentation(
        _ coordinator: MediaOperationCoordinator,
        source: LibraryRootPath
    ) async throws {
        try await waitUntil(every: .milliseconds(20)) {
            await !coordinator.currentPresentations().contains { $0.sourcePath == source }
        }
    }

    private enum TestError: Error, CustomStringConvertible {
        case planFailed(MediaOperationSourceState)
        var description: String {
            switch self {
            case let .planFailed(st): "plan failed state: \(st)"
            }
        }
    }

    // MARK: - 1. Detach during suspended build

    @Test func detachDuringSuspendedBuildNoPresentationAfterResume() async throws {
        log("START detachDuringSuspendedBuildNoPresentationAfterResume")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1024).write(to: cardURL.appending(path: "a.jpg"))

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:detach-build",
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }

        let builder = ControlledImportPlanBuilder()
        await builder.suspendNextBuild(for: cardPath)
        let defaults = PreferencesDomain.suite(UUID().uuidString)
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        ImportPreferencesStore.save(prefs, defaults: defaults.makeDefaults())
        let coordinator = MediaOperationCoordinator(store: store, preferencesDomain: defaults, planBuilder: builder)
        await coordinator.start()
        try await waitForPendingBuilder(builder, source: cardPath)

        // Detach while build is suspended.
        try await store.detachRemovableSource(identity: "volume:detach-build", reason: .ejected)
        _ = try await waitForCatalogStoreState(store) { snap in
            !snap.removableSources.contains { $0.path == cardPath && $0.availability == .available }
        }
        try await waitUntilNoPresentation(coordinator, source: cardPath)

        // Resume old builder — should be stale and produce no presentation.
        await builder.resumePendingBuild(for: cardPath)
        try await waitForCoordinatorQuiescence(coordinator)
        let stillHas = await coordinator.currentPresentations().contains(where: { $0.sourcePath == cardPath })
        #expect(!stillHas, "Stale build after detach must not publish presentation")
        #expect(await coordinator.readyPlan(for: cardPath) == nil)
        log("END")
        log("END")
        await coordinator.shutdown()
    }

    // MARK: - 2. Rapid same-path reattach

    @Test func rapidSamePathReattachOldBuildCannotBecomeReady() async throws {
        log("START rapidSamePathReattachOldBuildCannotBecomeReady")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 1024).write(to: cardURL.appending(path: "b.jpg"))

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:reattach-A",
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }

        let builder = ControlledImportPlanBuilder()
        await builder.suspendNextBuild(for: cardPath)
        let defaults = PreferencesDomain.suite(UUID().uuidString)
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        ImportPreferencesStore.save(prefs, defaults: defaults.makeDefaults())
        let coordinator = MediaOperationCoordinator(store: store, preferencesDomain: defaults, planBuilder: builder)
        await coordinator.start()
        try await waitForPendingBuilder(builder, source: cardPath)

        // Detach A while its build is suspended.
        try await store.detachRemovableSource(identity: "volume:reattach-A", reason: .ejected)
        _ = try await waitForCatalogStoreState(store) { snap in
            !snap.removableSources.contains { $0.path == cardPath && $0.availability == .available }
        }
        try await waitForCoordinatorQuiescence(coordinator)
        // Reattach at same mount path with new identity, suspend its build too.
        try Data(repeating: 3, count: 1024).write(to: cardURL.appending(path: "c.jpg"))
        await builder.suspendNextBuild(for: cardPath)
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:reattach-B",
            displayName: "Card",
            isEjectable: true
        )
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }
        // Wait for B's build to be queued. With cancellation-dummy on detach, A's pending is already resolved, so only
        // B is pending.
        try await waitForPendingBuilderCount(builder, source: cardPath, count: 1)
        let pendingAfterA = await builder.pendingCount(for: cardPath)
        #expect(pendingAfterA == 1, "B's build should be pending")
        await builder.resumePendingBuild(for: cardPath)
        let plan = try await waitForReady(coordinator, source: cardPath)
        // The ready plan should be from B (contains c.jpg).
        let entryNames = plan.entries.map(\.source.relativePath.rawValue).sorted()
        #expect(entryNames.contains("c.jpg"))
        log("END")
        log("END")
        await coordinator.shutdown()
    }

    // MARK: - 3. Old completion cannot clear new task

    @Test func oldCompletionCannotClearNewTask() async throws {
        log("START oldCompletionCannotClearNewTask")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        try Data(repeating: 4, count: 1024).write(to: cardURL.appending(path: "d.jpg"))

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:clear-new",
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }

        let builder = ControlledImportPlanBuilder()
        await builder.suspendNextBuild(for: cardPath)
        let defaults = PreferencesDomain.suite(UUID().uuidString)
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        ImportPreferencesStore.save(prefs, defaults: defaults.makeDefaults())
        let coordinator = MediaOperationCoordinator(store: store, preferencesDomain: defaults, planBuilder: builder)
        await coordinator.start()
        try await waitForPendingBuilder(builder, source: cardPath)

        // Simulate rapid detach/reattach while old build still pending, then detach new build while still pending and
        // ensure it stays cancelled.
        try await store.detachRemovableSource(identity: "volume:clear-new", reason: .ejected)
        _ = try await waitForCatalogStoreState(store) { snap in
            !snap.removableSources.contains { $0.path == cardPath && $0.availability == .available }
        }
        try await waitForCoordinatorQuiescence(coordinator)
        await builder.suspendNextBuild(for: cardPath)
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:clear-new-B",
            displayName: "Card",
            isEjectable: true
        )
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }
        try await waitForPendingBuilder(builder, source: cardPath)
        // Detach B while its build is still suspended — it should be cancelled.
        try await store.detachRemovableSource(identity: "volume:clear-new-B", reason: .ejected)
        _ = try await waitForCatalogStoreState(store) { snap in
            !snap.removableSources.contains { $0.path == cardPath && $0.availability == .available }
        }
        try await waitForCoordinatorQuiescence(coordinator)
        // Resume the now-stale B build — must not publish.
        await builder.resumePendingBuild(for: cardPath)
        try await waitForCoordinatorQuiescence(coordinator)
        let has = await coordinator.currentPresentations().contains(where: { $0.sourcePath == cardPath })
        #expect(!has, "Detached B's stale build must not publish")
        let cancelled = await builder.recordedCancelled()
        // Cancellation should have been observed for the pending build.
        #expect(cancelled.contains(cardPath))
        log("END")
        log("END")
        await coordinator.shutdown()
    }

    // MARK: - 4. Claims release on detach

    @Test func claimsReleaseOnDetach() async throws {
        log("START claimsReleaseOnDetach")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardAURL = temp.appending(path: "CardA", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardAURL, withIntermediateDirectories: true)
        try Data(repeating: 5, count: 1024).write(to: cardAURL.appending(path: "shared.jpg"))

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardAURL,
            identity: "volume:claim-detach-A",
            displayName: "CardA",
            isEjectable: true
        )
        let cardAPath = try CatalogPath.normalizedDirectoryPath(for: cardAURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardAPath && !$0.isScanning }
        }

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        ImportPreferencesStore.save(prefs, defaults: defaults.makeDefaults())
        let coordinator = MediaOperationCoordinator(store: store, preferencesDomain: defaults)
        await coordinator.start()
        let planA = try await waitForReady(coordinator, source: cardAPath)
        #expect(planA.entries.first?.finalDestination.rawValue == "shared.jpg")
        // Detach A
        try await store.detachRemovableSource(identity: "volume:claim-detach-A", reason: .ejected)
        _ = try await waitForCatalogStoreState(store) { snap in
            !snap.removableSources.contains { $0.path == cardAPath && $0.availability == .available }
        }
        try await waitForCoordinatorQuiescence(coordinator)

        // Attach B with same filename
        let cardBURL = temp.appending(path: "CardB", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cardBURL, withIntermediateDirectories: true)
        try Data(repeating: 6, count: 1024).write(to: cardBURL.appending(path: "shared.jpg"))
        try await store.attachRemovableVolume(
            mountURL: cardBURL,
            identity: "volume:claim-detach-B",
            displayName: "CardB",
            isEjectable: true
        )
        let cardBPath = try CatalogPath.normalizedDirectoryPath(for: cardBURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardBPath && !$0.isScanning }
        }
        let planB = try await waitForReady(coordinator, source: cardBPath)
        // After detach, B should get base name, not suffix.
        #expect(
            planB.entries.first?.finalDestination.rawValue == "shared.jpg",
            "Claim should be released on detach, B should get base name"
        )
        log("END")
        log("END")
        await coordinator.shutdown()
    }

    // MARK: - 5. Claims release on cancel

    @Test func claimsReleaseOnCancel() async throws {
        log("START claimsReleaseOnCancel")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardAURL = temp.appending(path: "CardA", directoryHint: .isDirectory)
        let cardBURL = temp.appending(path: "CardB", directoryHint: .isDirectory)
        for url in [destURL, cardAURL, cardBURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try Data(repeating: 7, count: 512 * 1024).write(to: cardAURL.appending(path: "shared.jpg"))
        try Data(repeating: 8, count: 1024).write(to: cardBURL.appending(path: "shared.jpg"))

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardAURL,
            identity: "volume:cancel-A",
            displayName: "CardA",
            isEjectable: true
        )
        let cardAPath = try CatalogPath.normalizedDirectoryPath(for: cardAURL)
        try await store.attachRemovableVolume(
            mountURL: cardBURL,
            identity: "volume:cancel-B",
            displayName: "CardB",
            isEjectable: true
        )
        let cardBPath = try CatalogPath.normalizedDirectoryPath(for: cardBURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.filter { $0.availability == .available }.count == 2
                && snap.removableSources.allSatisfy { !$0.isScanning }
        }

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        ImportPreferencesStore.save(prefs, defaults: defaults.makeDefaults())

        let builder = ControlledImportPlanBuilder()
        await builder.suspendNextBuild(for: cardBPath)
        let execControl = ControlledExecutionControl()
        await execControl.suspendNextExecution(for: cardAPath)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: defaults,
            planBuilder: builder,
            makeExecutor: { source in
                if source == cardAPath {
                    ControlledImportExecutor(control: execControl)
                } else {
                    LiveImportExecutor(store: store)
                }
            }
        )
        await coordinator.start()
        log("STEP start done")
        // Ensure A builds first and gets base name, then B gets suffix.
        log("STEP waitForReady A")
        let planA = try await waitForReady(coordinator, source: cardAPath)
        #expect(planA.entries.first?.finalDestination.rawValue == "shared.jpg")
        await builder.resumePendingBuild(for: cardBPath)
        log("STEP waitForReady B")
        let planBBefore = try await waitForReady(coordinator, source: cardBPath)
        #expect(
            planBBefore.entries.first?.finalDestination.rawValue == "shared 2.jpg"
                || planBBefore.entries.first?.finalDestination.rawValue == "shared-2.jpg"
                || (planBBefore.entries.first?.finalDestination.rawValue.contains("shared") ?? false),
            "B should have suffix while A holds claim"
        )

        log("STEP queueImport")
        let queueTask = Task { await coordinator.queueImport(for: cardAPath) }
        log("STEP waitForPendingExecution")
        try await waitForPendingExecution(execControl, source: cardAPath)
        // Suspend A's next build after cancel so its claim stays released for B's retry.
        await builder.suspendNextBuild(for: cardAPath)
        // Now cancel A's execution via coordinator's cancelImport
        await coordinator.cancelImport(for: cardAPath)
        // Resume A's execution with cancelled result — this simulates executor observing cancel and returning
        // cancelled.
        log("STEP resumePending cancelled")
        await execControl.resumePending(
            for: cardAPath,
            with: .stopped(
                reason: .user,
                publishedCount: 0,
                hasBlockedEntries: false,
                hasEntryFailures: false,
                skippedForeignCount: 0,
                failedCount: 0
            )
        )
        // Settlement schedules A's rebuild, which the builder holds.
        try await waitForPendingBuilder(builder, source: cardAPath)
        await queueTask.value
        // After cancel, A's claim should be released. B should be able to reclaim base name on rebuild.
        // Trigger rebuild for B.
        log("STEP retryPlanning")
        await coordinator.retryPlanning(for: cardBPath)
        log("STEP waitForReady B after")
        // Poll until B's plan shows base name, since waitForReady may return old suffix immediately.
        // After A's cancel, B should reclaim base name.
        try await waitUntil(every: .milliseconds(50)) {
            await coordinator.readyPlan(for: cardBPath)?.entries.first?.finalDestination.rawValue == "shared.jpg"
        }
        log("END")
        log("END")
        await coordinator.shutdown()
    }

    // MARK: - 6. Claims release on failure

    @Test func claimsReleaseOnFailure() async throws {
        log("START claimsReleaseOnFailure")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardAURL = temp.appending(path: "CardA", directoryHint: .isDirectory)
        let cardBURL = temp.appending(path: "CardB", directoryHint: .isDirectory)
        for url in [destURL, cardAURL, cardBURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try Data(repeating: 9, count: 1024).write(to: cardAURL.appending(path: "shared.jpg"))
        try Data(repeating: 10, count: 1024).write(to: cardBURL.appending(path: "shared.jpg"))

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardAURL,
            identity: "volume:fail-A",
            displayName: "CardA",
            isEjectable: true
        )
        let cardAPath = try CatalogPath.normalizedDirectoryPath(for: cardAURL)
        try await store.attachRemovableVolume(
            mountURL: cardBURL,
            identity: "volume:fail-B",
            displayName: "CardB",
            isEjectable: true
        )
        let cardBPath = try CatalogPath.normalizedDirectoryPath(for: cardBURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.filter { $0.availability == .available }.count == 2
                && snap.removableSources.allSatisfy { !$0.isScanning }
        }

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        ImportPreferencesStore.save(prefs, defaults: defaults.makeDefaults())

        let builder2 = ControlledImportPlanBuilder()
        await builder2.suspendNextBuild(for: cardBPath)
        let execControl = ControlledExecutionControl()
        await execControl.suspendNextExecution(for: cardAPath)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: defaults,
            planBuilder: builder2,
            makeExecutor: { source in
                if source == cardAPath {
                    ControlledImportExecutor(control: execControl)
                } else {
                    LiveImportExecutor(store: store)
                }
            }
        )
        await coordinator.start()
        let planA = try await waitForReady(coordinator, source: cardAPath)
        #expect(planA.entries.first?.finalDestination.rawValue == "shared.jpg")
        await builder2.resumePendingBuild(for: cardBPath)
        log("STEP waitForReady B")
        let planBBefore = try await waitForReady(coordinator, source: cardBPath)
        #expect(planBBefore.entries.first?.finalDestination.rawValue != "shared.jpg")

        log("STEP queueImport")
        let queueTask2 = Task { await coordinator.queueImport(for: cardAPath) }
        log("STEP waitForPendingExecution")
        try await waitForPendingExecution(execControl, source: cardAPath)
        await builder2.suspendNextBuild(for: cardAPath)
        await execControl.resumePending(for: cardAPath, with: .failed(reason: .unexpected(detail: "injectedFailure")))
        // Settlement schedules A's rebuild, which the builder holds.
        try await waitForPendingBuilder(builder2, source: cardAPath)
        await queueTask2.value
        log("STEP retryPlanning")
        await coordinator.retryPlanning(for: cardBPath)
        log("STEP waitForReady B after")
        // After failure, B should reclaim base name.
        try await waitUntil(every: .milliseconds(50)) {
            await coordinator.readyPlan(for: cardBPath)?.entries.first?.finalDestination.rawValue == "shared.jpg"
        }
        log("END")
        log("END")
        await coordinator.shutdown()
    }

    // MARK: - 7. Current-ledger conflict

    @Test func currentLedgerConflictRebuildsWithDisjointName() async throws {
        log("START currentLedgerConflictRebuildsWithDisjointName")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardAURL = temp.appending(path: "CardA", directoryHint: .isDirectory)
        let cardBURL = temp.appending(path: "CardB", directoryHint: .isDirectory)
        for url in [destURL, cardAURL, cardBURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try Data(repeating: 11, count: 1024).write(to: cardAURL.appending(path: "shared.jpg"))
        try Data(repeating: 12, count: 1024).write(to: cardBURL.appending(path: "shared.jpg"))

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardAURL,
            identity: "volume:ledger-A",
            displayName: "CardA",
            isEjectable: true
        )
        let cardAPath = try CatalogPath.normalizedDirectoryPath(for: cardAURL)
        try await store.attachRemovableVolume(
            mountURL: cardBURL,
            identity: "volume:ledger-B",
            displayName: "CardB",
            isEjectable: true
        )
        let cardBPath = try CatalogPath.normalizedDirectoryPath(for: cardBURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.filter { $0.availability == .available }.count == 2
                && snap.removableSources.allSatisfy { !$0.isScanning }
        }

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        ImportPreferencesStore.save(prefs, defaults: defaults.makeDefaults())

        let builder = ControlledImportPlanBuilder()
        await builder.suspendNextBuild(for: cardAPath)
        await builder.suspendNextBuild(for: cardBPath)
        let coordinator = MediaOperationCoordinator(store: store, preferencesDomain: defaults, planBuilder: builder)
        await coordinator.start()
        try await waitForPendingBuilder(builder, source: cardAPath)
        try await waitForPendingBuilder(builder, source: cardBPath)

        // Resume A first — it should become Ready with base name.
        await builder.resumePendingBuild(for: cardAPath)
        let planA = try await waitForReady(coordinator, source: cardAPath)
        #expect(planA.entries.first?.finalDestination.rawValue == "shared.jpg")
        // Resume B — it was built against same namespace snapshot without seeing A's claim, so it will have base name
        // too,
        // but coordinator's conflict check should detect that its newClaims intersect currentLedger and re-dirty +
        // rebuild.
        await builder.resumePendingBuild(for: cardBPath)
        // B's first completion should have been discarded due to conflict, and a second build scheduled.
        // That second build is not suspended (we only suspended one per source), so it should complete quickly with
        // suffix.
        let planB = try await waitForReady(coordinator, source: cardBPath)
        #expect(
            planB.entries.first?.finalDestination.rawValue != "shared.jpg",
            "B should have suffix after conflict rebuild"
        )
        #expect(planB.entries.first?.finalDestination.rawValue.contains("shared") == true)
        // Verify A still holds base.
        let planAAfter = await coordinator.readyPlan(for: cardAPath)
        #expect(planAAfter?.entries.first?.finalDestination.rawValue == "shared.jpg")
        log("END")
        log("END")
        await coordinator.shutdown()
    }

    // MARK: - 8. Settlement conversion

    @Test func settlementConversionAfterPublishBStillSuffixDueToRealFile() async throws {
        log("START settlementConversionAfterPublishBStillSuffixDueToRealFile")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardAURL = temp.appending(path: "CardA", directoryHint: .isDirectory)
        let cardBURL = temp.appending(path: "CardB", directoryHint: .isDirectory)
        for url in [destURL, cardAURL, cardBURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try Data(repeating: 13, count: 1024).write(to: cardAURL.appending(path: "shared.jpg"))
        // B's file shares A's name but not its size, so it is a different file: the
        // planner must not skip it as already imported, and must name around A's.
        try Data(repeating: 14, count: 2048).write(to: cardBURL.appending(path: "shared.jpg"))

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardAURL,
            identity: "volume:settle-A",
            displayName: "CardA",
            isEjectable: true
        )
        let cardAPath = try CatalogPath.normalizedDirectoryPath(for: cardAURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardAPath && $0.availability == .available && !$0.isScanning }
        }

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        ImportPreferencesStore.save(prefs, defaults: defaults.makeDefaults())

        // Use live executor for A so it actually publishes a file.
        let coordinator = MediaOperationCoordinator(store: store, preferencesDomain: defaults)
        await coordinator.start()
        let planA = try await waitForReady(coordinator, source: cardAPath)
        #expect(planA.entries.first?.finalDestination.rawValue == "shared.jpg")
        await coordinator.queueImport(for: cardAPath)
        // Wait for import to complete and file to appear
        try await waitUntil(every: .milliseconds(50)) {
            FileManager.default.fileExists(atPath: destURL.appending(path: "shared.jpg").path)
        }

        // Attach B only after A has published. This keeps the test about settlement
        // against the real destination file rather than racing two initial claims.
        try await store.attachRemovableVolume(
            mountURL: cardBURL,
            identity: "volume:settle-B",
            displayName: "CardB",
            isEjectable: true
        )
        let cardBPath = try CatalogPath.normalizedDirectoryPath(for: cardBURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardBPath && $0.availability == .available && !$0.isScanning }
        }

        // B's first build sees the real file, not A's now-released ledger claim,
        // so its plan must still use a suffix.
        await coordinator.retryPlanning(for: cardBPath)
        // Poll until B's plan shows suffix (real file), since attachment may first
        // deliver a transient plan before the explicit retry settles.
        // B should still have a suffix due to the real file, even after A's claim dies.
        try await waitUntil(every: .milliseconds(50)) {
            let destination = await coordinator.readyPlan(for: cardBPath)?.entries.first?.finalDestination.rawValue
            return destination != "shared.jpg" && destination?.contains("shared") == true
        }
        log("END")
        log("END")
        await coordinator.shutdown()
    }

    // MARK: - 9. Detach during execution

    @Test func detachDuringExecutionNoRecreation() async throws {
        log("START detachDuringExecutionNoRecreation")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        try Data(repeating: 15, count: 1024).write(to: cardURL.appending(path: "e.jpg"))

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:detach-exec",
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        ImportPreferencesStore.save(prefs, defaults: defaults.makeDefaults())

        let execControl = ControlledExecutionControl()
        await execControl.suspendNextExecution(for: cardPath)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: defaults,
            makeExecutor: { _ in ControlledImportExecutor(control: execControl) }
        )
        await coordinator.start()
        _ = try await waitForReady(coordinator, source: cardPath)
        let queueTask3 = Task { await coordinator.queueImport(for: cardPath) }
        try await waitForPendingExecution(execControl, source: cardPath)

        // Detach while executing
        try await store.detachRemovableSource(identity: "volume:detach-exec", reason: .ejected)
        _ = try await waitForCatalogStoreState(store) { snap in
            !snap.removableSources.contains { $0.path == cardPath && $0.availability == .available }
        }
        // Cancellation settles the old batch as a source-removal failure, but
        // it must not recreate a presentation for the missing card: the bar is
        // drawn only on a live card's row.
        await queueTask3.value
        try await waitUntilNoPresentation(coordinator, source: cardPath)
        log("END")
        log("END")
        await coordinator.shutdown()
    }

    /// A settled run's outcome is carried as state on the presentation, so a
    /// consumer never needs to have observed the frame that first set it —
    /// only the current snapshot. `presentationsStream()`'s
    /// `.bufferingNewest(1)` can drop any number of intermediate frames
    /// (trap #5); this proves the fact survives that by construction. The
    /// batch ID is exposed only while executing, and only once a real asset
    /// has published — this controlled executor never journals one, so it
    /// stays hidden throughout.
    @Test func completionIsStateThatSurvivesADroppedIntermediateFrame() async throws {
        log("START completionIsStateThatSurvivesADroppedIntermediateFrame")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1024).write(to: cardURL.appending(path: "f.jpg"))

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:batch-id",
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        ImportPreferencesStore.save(prefs, defaults: defaults.makeDefaults())

        let execControl = ControlledExecutionControl()
        await execControl.suspendNextExecution(for: cardPath)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: defaults,
            makeExecutor: { _ in ControlledImportExecutor(control: execControl) }
        )
        await coordinator.start()
        _ = try await waitForReady(coordinator, source: cardPath)
        let queueTask = Task { await coordinator.queueImport(for: cardPath) }
        try await waitForPendingExecution(execControl, source: cardPath)

        // `.executing`'s batchID is gated on a real published asset — this
        // controlled executor never journals one, so it stays nil here.
        let executing = try #require(await coordinator.currentPresentations().first { $0.sourcePath == cardPath })
        guard case .executing = executing.state else {
            Issue.record("Expected .executing, got \(executing.state)")
            await coordinator.shutdown()
            return
        }
        #expect(executing.batchID == nil, "batchID must stay hidden until a real asset has published")

        // Resume straight to completion. Whatever progress frames the
        // executor's onProgress would have emitted are never observed by this
        // test — standing in for the dropped intermediate frames the real
        // stream's bufferingNewest(1) can lose.
        await execControl.resumePending(
            for: cardPath,
            with: .completed(
                publishedCount: 1,
                hasBlockedEntries: false,
                hasEntryFailures: false,
                skippedForeignCount: 0,
                failedCount: 0,
                incompleteItems: []
            )
        )
        await queueTask.value

        // lastCompletion is recorded once the executor result settles.
        let settled = try await waitForPresentation(coordinator, source: cardPath) { $0.copiedJustNow != nil }
        #expect(settled.copiedJustNow == 1)
        // A second, independent snapshot read finds the same value without
        // having observed the transition that set it — state, not an event.
        let again = try #require(await coordinator.currentPresentations().first { $0.sourcePath == cardPath })
        #expect(again.copiedJustNow == 1)
        #expect(again.batchID == nil, "a settled run exposes no batch")
        log("END")
        await coordinator.shutdown()
    }

    /// APP-029: `presentation(for:)` derives `.executing` from `session.lastProgress`,
    /// never a zero-progress literal, so every re-derivation — a `publish()` for an
    /// unrelated reason, or simply re-reading the current snapshot, as here — shows
    /// the progress that has landed, not only the private splice-and-yield path
    /// inside `applyExecutionProgress`. `currentPresentations()`
    /// — which exercises the identical `sortedPresentations()` path any
    /// `publish()` uses — reflects the live value regardless of what triggered it.
    @Test func executingPresentationCarriesLiveProgressNotZero() async throws {
        log("START executingPresentationCarriesLiveProgressNotZero")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1024).write(to: cardURL.appending(path: "f.jpg"))

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:live-progress",
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        ImportPreferencesStore.save(prefs, defaults: defaults.makeDefaults())

        let execControl = ControlledExecutionControl()
        await execControl.suspendNextExecution(for: cardPath)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: defaults,
            makeExecutor: { _ in ControlledImportExecutor(control: execControl) }
        )
        await coordinator.start()
        _ = try await waitForReady(coordinator, source: cardPath)
        let queueTask = Task { await coordinator.queueImport(for: cardPath) }
        try await waitForPendingExecution(execControl, source: cardPath)

        let liveProgress = MediaOperationProgress(
            completedCount: 1, totalCount: 1, completedBytes: 512, totalBytes: 1024, elapsedMs: 250
        )
        await execControl.sendProgress(liveProgress, for: cardPath)

        let observed = try await waitForPresentation(coordinator, source: cardPath, predicate: { pres in
            if case let .executing(progress) = pres.state, progress == liveProgress {
                return true
            }
            return false
        })
        guard case let .executing(progress) = observed.state else {
            Issue.record("Expected .executing, got \(observed.state)")
            await coordinator.shutdown()
            return
        }
        #expect(progress == liveProgress)

        // The other half of D6: `.completed` must also carry the real settled
        // outcome, not a zero-summary literal. `.completed` is transient by
        // design — `applyExecutionResult` schedules the post-settlement
        // rebuild synchronously right after publishing it, so a poll of
        // `currentPresentations()` reliably observes the *next* state instead
        // (the same reason other tests in this file assert on `copiedJustNow`,
        // not `.state`, for a settled run). An actively-consumed stream
        // subscription catches the frame instead of racing a fresh derivation
        // against it. Non-zero `skippedForeignCount`/`failedCount` rule out a
        // coincidental-zero pass.
        let stream = await coordinator.presentationsStream()
        await execControl.resumePending(
            for: cardPath,
            with: .completed(
                publishedCount: 1,
                hasBlockedEntries: false,
                hasEntryFailures: true,
                skippedForeignCount: 1,
                failedCount: 1,
                incompleteItems: []
            )
        )
        var completed: (summary: MediaOperationPlanTotals, skippedForeignCount: Int, failedCount: Int)?
        for await values in stream {
            if let pres = values.first(where: { $0.sourcePath == cardPath }),
               case let .completed(summary, skippedForeignCount, failedCount, _) = pres.state
            {
                completed = (summary, skippedForeignCount, failedCount)
                break
            }
        }
        let outcome = try #require(completed, "presentation stream ended before a completed frame")
        await queueTask.value
        #expect(outcome.summary.copyCount == 1)
        #expect(outcome.skippedForeignCount == 1)
        #expect(outcome.failedCount == 1)
        log("END")
        await coordinator.shutdown()
    }

    /// A settled attachment's status belongs to the card's row, so it leaves
    /// when the card does. The journaled batch remains the source of truth for
    /// the imported assets.
    @Test func settledPresentationIsDiscardedAfterDetach() async throws {
        log("START settledPresentationIsDiscardedAfterDetach")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 1024).write(to: cardURL.appending(path: "g.jpg"))

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:gone-snapshot",
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        ImportPreferencesStore.save(prefs, defaults: defaults.makeDefaults())

        let execControl = ControlledExecutionControl()
        await execControl.suspendNextExecution(for: cardPath)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: defaults,
            makeExecutor: { _ in ControlledImportExecutor(control: execControl) }
        )
        await coordinator.start()
        _ = try await waitForReady(coordinator, source: cardPath)
        let queueTask = Task { await coordinator.queueImport(for: cardPath) }
        try await waitForPendingExecution(execControl, source: cardPath)

        await execControl.resumePending(
            for: cardPath,
            with: .completed(
                publishedCount: 1,
                hasBlockedEntries: false,
                hasEntryFailures: false,
                skippedForeignCount: 0,
                failedCount: 0,
                incompleteItems: []
            )
        )
        await queueTask.value

        _ = try await waitForPresentation(coordinator, source: cardPath) { $0.copiedJustNow != nil }

        try await store.detachRemovableSource(identity: "volume:gone-snapshot", reason: .ejected)
        _ = try await waitForCatalogStoreState(store) { snap in
            !snap.removableSources.contains { $0.path == cardPath && $0.availability == .available }
        }

        try await waitUntilNoPresentation(coordinator, source: cardPath)
        #expect(await coordinator.currentPresentations().isEmpty, "a settled outcome leaves with its card")
        log("END")
        await coordinator.shutdown()
    }

    /// APP-029: a failed run stays Failed after the rebuild it schedules
    /// lands. The failure is a recorded fact about the last run; the rebuild
    /// replaces the *phase* and finds a Ready plan, which the presentation
    /// keeps behind state G until the user presses Try Again.
    @Test func aFailedRunStaysFailedAfterTheRebuildItSchedules() async throws {
        log("START aFailedRunStaysFailedAfterTheRebuildItSchedules")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        try Data(repeating: 4, count: 1024).write(to: cardURL.appending(path: "a.jpg"))

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:failed-stays",
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        ImportPreferencesStore.save(prefs, defaults: defaults.makeDefaults())

        let execControl = ControlledExecutionControl()
        await execControl.suspendNextExecution(for: cardPath)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: defaults,
            makeExecutor: { _ in ControlledImportExecutor(control: execControl) }
        )
        await coordinator.start()
        _ = try await waitForReady(coordinator, source: cardPath)
        let queueTask = Task { await coordinator.queueImport(for: cardPath) }
        try await waitForPendingExecution(execControl, source: cardPath)
        await execControl.resumePending(for: cardPath, with: .failed(reason: .destinationUnavailable))
        await queueTask.value

        _ = try await waitForPresentation(coordinator, source: cardPath) { pres in
            if case .failed = pres.state {
                return true
            }
            return false
        }
        // Let the post-settlement rebuild land — it does, and the plan is Ready
        // underneath — and the presentation is still Failed.
        // The rebuild after settlement still runs.
        try await waitUntil(every: .milliseconds(25)) { await coordinator.readyPlan(for: cardPath) != nil }
        let after = try #require(await coordinator.currentPresentations().first { $0.sourcePath == cardPath })
        guard case let .failed(reason, _) = after.state else {
            Issue.record("Expected the failure to survive the rebuild, got \(after.state)")
            return
        }
        #expect(reason == .destinationUnavailable)
        log("END")
        await coordinator.shutdown()
    }

    /// APP-029: `Try Again` is what leaves state G — it clears the
    /// recorded failure and re-plans, and the Ready the rebuild already found
    /// is what the user sees next.
    @Test func tryAgainLeavesTheFailedState() async throws {
        log("START tryAgainLeavesTheFailedState")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        try Data(repeating: 6, count: 1024).write(to: cardURL.appending(path: "a.jpg"))

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:try-again",
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        ImportPreferencesStore.save(prefs, defaults: defaults.makeDefaults())

        let execControl = ControlledExecutionControl()
        await execControl.suspendNextExecution(for: cardPath)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: defaults,
            makeExecutor: { _ in ControlledImportExecutor(control: execControl) }
        )
        await coordinator.start()
        _ = try await waitForReady(coordinator, source: cardPath)
        let queueTask = Task { await coordinator.queueImport(for: cardPath) }
        try await waitForPendingExecution(execControl, source: cardPath)
        await execControl.resumePending(for: cardPath, with: .failed(reason: .unexpected(detail: "test")))
        await queueTask.value
        _ = try await waitForPresentation(coordinator, source: cardPath) { pres in
            if case .failed = pres.state {
                return true
            }
            return false
        }

        await coordinator.retryPlanning(for: cardPath)
        let ready = try await waitForPresentation(coordinator, source: cardPath) { pres in
            if case .ready = pres.state {
                return true
            }
            return false
        }
        #expect(ready.batchID == nil, "no run is being presented once the failure is cleared")
        log("END")
        await coordinator.shutdown()
    }

    /// A destination folder that exists but cannot be listed is a missing
    /// observation, not a plan: the build is deferred with a bounded backoff
    /// and the last proven plan keeps presenting. On 2026-09-13 the blocked
    /// plan was promoted instead and drew `0 new items · Import 0 Items` over
    /// 368 items already in the library.
    @Test func anUnreadableDestinationFolderDefersTheBuildAndHoldsTheProvenPlan() async throws {
        log("START anUnreadableDestinationFolderDefersTheBuildAndHoldsTheProvenPlan")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        try Data(repeating: 8, count: 1024).write(to: cardURL.appending(path: "a.jpg"))

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:unreadable-defer",
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        ImportPreferencesStore.save(prefs, defaults: defaults.makeDefaults())

        let builder = UnreadableThenLivePlanBuilder(unreadableBuilds: 0)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: defaults,
            planBuilder: builder,
            unreadableRetryDelays: [.milliseconds(30), .milliseconds(30), .milliseconds(30)]
        )
        await coordinator.start()
        let proven = try await waitForReady(coordinator, source: cardPath)
        #expect(proven.totals.copyCount == 1)

        // The next two builds cannot read the destination; the third can.
        await builder.setUnreadableBuilds(2)
        await coordinator.retryPlanning(for: cardPath)
        var sawBlockedPlan = false
        var sawProvenPlan = false
        try await waitUntil {
            if let pres = await coordinator.currentPresentations().first(where: { $0.sourcePath == cardPath }),
               case let .ready(summary, _, _, attention) = pres.state
            {
                if summary.blockedCount > 0 || !attention.isEmpty {
                    sawBlockedPlan = true
                }
                if summary.copyCount == 1, attention.isEmpty {
                    sawProvenPlan = true
                }
            }
            return await builder.builds >= 4
        }
        #expect(!sawBlockedPlan, "a plan built on an unread folder is never presented")
        #expect(sawProvenPlan, "the last proven plan keeps presenting across the deferral")
        #expect(await builder.builds == 4, "one proven build, two deferred, one that read everything")
        let settled = try await waitForPresentation(coordinator, source: cardPath) { pres in
            if case let .ready(summary, _, _, attention) = pres.state {
                return summary.copyCount == 1 && attention.isEmpty
            }
            return false
        }
        #expect(settled.batchID == nil)
        log("END")
        await coordinator.shutdown()
    }

    /// Past the last backoff delay the condition is a planning failure the user
    /// can act on; `Try Again` restarts the backoff and, with the folder readable
    /// again, reaches Ready.
    @Test func anUnreadableDestinationThatPersistsBecomesAPlanningFailureThatTryAgainClears() async throws {
        log("START anUnreadableDestinationThatPersistsBecomesAPlanningFailureThatTryAgainClears")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 1024).write(to: cardURL.appending(path: "a.jpg"))

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:unreadable-persist",
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        ImportPreferencesStore.save(prefs, defaults: defaults.makeDefaults())

        let builder = UnreadableThenLivePlanBuilder(unreadableBuilds: 10)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: defaults,
            planBuilder: builder,
            unreadableRetryDelays: [.milliseconds(20)]
        )
        await coordinator.start()
        let failed = try await waitForPresentation(coordinator, source: cardPath) { pres in
            if case .planningFailed = pres.state {
                return true
            }
            return false
        }
        guard case let .planningFailed(reason) = failed.state else {
            Issue.record("Expected a planning failure, got \(failed.state)")
            return
        }
        #expect(reason == .destinationUnavailable)
        #expect(await builder.builds == 2, "the first build and one retry, then the backoff is exhausted")

        await builder.setUnreadableBuilds(0)
        await coordinator.retryPlanning(for: cardPath)
        let ready = try await waitForPresentation(coordinator, source: cardPath) { pres in
            if case let .ready(summary, _, _, _) = pres.state {
                return summary.copyCount == 1
            }
            return false
        }
        #expect(ready.stopReason == nil)
        log("END")
        await coordinator.shutdown()
    }

    /// After a completed run the coordinator dropped into `.building` while still
    /// holding the pre-run plan, so the bar drew `Ready · Import 368 Items` for
    /// 360 ms between two Done frames (observed 2026-09-13, 17:57:37). The plan a
    /// run executed from is dropped on settlement, and the settlement itself is
    /// what presents until the re-plan lands.
    @Test func aCompletedRunPresentsItsSettlementUntilTheRePlanLands() async throws {
        log("START aCompletedRunPresentsItsSettlementUntilTheRePlanLands")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 1024).write(to: cardURL.appending(path: "a.jpg"))

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:settlement-window",
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        ImportPreferencesStore.save(prefs, defaults: defaults.makeDefaults())

        let builder = ControlledImportPlanBuilder()
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: defaults,
            planBuilder: builder,
            makeExecutor: { _ in LiveImportExecutor(store: store) }
        )
        await coordinator.start()
        let proven = try await waitForReady(coordinator, source: cardPath)
        #expect(proven.totals.copyCount == 1)

        // Hold the post-settlement rebuild so the window between settling and
        // re-planning is observable instead of a few hundred milliseconds wide.
        await builder.suspendNextBuild(for: cardPath)
        await coordinator.queueImport(for: cardPath)
        try await waitUntil(every: .milliseconds(10)) { await builder.pendingCount(for: cardPath) != 0 }
        #expect(await builder.pendingCount(for: cardPath) == 1, "the post-settlement rebuild is in flight")
        let during = try #require(await coordinator.currentPresentations().first { $0.sourcePath == cardPath })
        guard case let .completed(summary, _, _, _) = during.state else {
            Issue.record("Expected the settlement to present while the re-plan is in flight, got \(during.state)")
            return
        }
        #expect(summary.copyCount == 1)
        #expect(during.copiedJustNow == 1)

        await builder.resumePendingBuild(for: cardPath)
        let after = try await waitForPresentation(coordinator, source: cardPath) { pres in
            if case let .ready(summary, _, _, _) = pres.state {
                return summary.copyCount == 0 && summary.skipCount == 1
            }
            return false
        }
        #expect(after.copiedJustNow == 1)
        #expect(after.isFullyClean == true)
        log("END")
        await coordinator.shutdown()
    }

    /// A run's outcome is a claim about the library it copied into. Change
    /// the destination and the outcome is withheld — otherwise the bar would
    /// read `1 copied just now · N items in <the other library>` — and it
    /// returns when the original library is picked again. The batch identity
    /// is not gated, so the batch row keeps its pin either way.
    @Test func aCompletionIsPresentedOnlyForTheLibraryItCopiedInto() async throws {
        log("START aCompletionIsPresentedOnlyForTheLibraryItCopiedInto")
        let temp = try makeTempRoot()
        let firstURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let secondURL = temp.appending(path: "Camera Roll", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        for url in [firstURL, secondURL, cardURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try Data(repeating: 2, count: 1024).write(to: cardURL.appending(path: "a.jpg"))

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: firstURL)
        try await store.addLibrary(url: secondURL)
        let firstPath = try CatalogPath.normalizedDirectoryPath(for: firstURL)
        let secondPath = try CatalogPath.normalizedDirectoryPath(for: secondURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:completion-scope",
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        ImportPreferencesStore.save(prefs, defaults: defaults.makeDefaults())

        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: defaults,
            makeExecutor: { _ in LiveImportExecutor(store: store) }
        )
        await coordinator.start()
        await coordinator.setDestination(firstPath, for: cardPath)
        _ = try await waitForReady(coordinator, source: cardPath)
        await coordinator.queueImport(for: cardPath)
        let settled = try await waitForPresentation(
            coordinator,
            source: cardPath,
            predicate: { $0.copiedJustNow == 1 }
        )
        #expect(settled.isFullyClean == true)

        await coordinator.setDestination(secondPath, for: cardPath)
        let elsewhere = try await waitForPresentation(coordinator, source: cardPath, predicate: { pres in
            if case .ready = pres.state, pres.destinationPath == secondPath {
                return true
            }
            return false
        })
        #expect(elsewhere.copiedJustNow == nil)
        #expect(elsewhere.isFullyClean == nil)

        await coordinator.setDestination(firstPath, for: cardPath)
        let back = try await waitForPresentation(coordinator, source: cardPath, predicate: { pres in
            if case .ready = pres.state, pres.destinationPath == firstPath {
                return true
            }
            return false
        })
        #expect(back.copiedJustNow == 1)
        #expect(back.isFullyClean == true)
        log("END")
        await coordinator.shutdown()
    }

    /// State C's "not everything will fit" line needs the destination's
    /// available capacity on the Ready presentation, sampled with the same
    /// reader the floor uses, and only where there is a plan to compare it to.
    @Test func aReadyPresentationCarriesTheDestinationsAvailableCapacity() async throws {
        log("START aReadyPresentationCarriesTheDestinationsAvailableCapacity")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 1024).write(to: cardURL.appending(path: "a.jpg"))

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:space-advisory",
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        ImportPreferencesStore.save(prefs, defaults: defaults.makeDefaults())

        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: defaults,
            volumeCapacity: { _ in FreeSpaceFloor.bytes + 100 }
        )
        await coordinator.start()
        let ready = try await waitForPresentation(coordinator, source: cardPath) { pres in
            if case .ready = pres.state {
                return true
            }
            return false
        }
        #expect(ready.destinationAvailableBytes == FreeSpaceFloor.bytes + 100)
        let drawn = ImportBarPresentation.map(presentation: ready, preferences: .default, sourceDisplayName: "Card")
        #expect(drawn.secondaryLine == .plain("Not everything will fit yet · 5.4 GB available"))
        #expect(drawn.primaryAction == .importNewItems)
        log("END")
        await coordinator.shutdown()
    }

    /// APP-029: a run that stops early settles as a partial success whose
    /// facts — why it stopped, what it copied, of what it planned — are
    /// published as state and survive the post-settlement re-plan, so state F's
    /// Stopped variant can render from them on either sidebar row. Never fully
    /// clean, so it neither auto-dismisses nor ejects.
    @Test func aStoppedRunPublishesItsStopFactsAcrossTheRePlan() async throws {
        log("START aStoppedRunPublishesItsStopFactsAcrossTheRePlan")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        for name in ["a.jpg", "b.jpg", "c.jpg"] {
            try Data(repeating: 5, count: 1024).write(to: cardURL.appending(path: name))
        }

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:stopped-run",
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        ImportPreferencesStore.save(prefs, defaults: defaults.makeDefaults())

        let execControl = ControlledExecutionControl()
        await execControl.suspendNextExecution(for: cardPath)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: defaults,
            makeExecutor: { _ in ControlledImportExecutor(control: execControl) }
        )
        await coordinator.start()
        let plan = try await waitForReady(coordinator, source: cardPath)
        #expect(plan.totals.copyCount == 3)
        let queueTask = Task { await coordinator.queueImport(for: cardPath) }
        try await waitForPendingExecution(execControl, source: cardPath)

        await execControl.resumePending(for: cardPath, with: .stopped(
            reason: .user,
            publishedCount: 1,
            hasBlockedEntries: false,
            hasEntryFailures: false,
            skippedForeignCount: 0,
            failedCount: 0
        ))
        await queueTask.value

        // The re-plan that follows settlement lands as Ready; the stop facts
        // must still be on that frame, not only on the settlement frame.
        let rePlanned = try await waitForPresentation(coordinator, source: cardPath) { pres in
            if case .ready = pres.state {
                return pres.stopReason != nil
            }
            return false
        }
        #expect(rePlanned.stopReason == .user)
        #expect(rePlanned.copiedJustNow == 1)
        #expect(rePlanned.plannedCount == 3)
        #expect(rePlanned.isFullyClean == false)
        log("END")
        await coordinator.shutdown()
    }

    /// ADR 0027 end to end through the real executor: a card that does not fit
    /// whole is copied up to the floor, settles as stopped with the floor as
    /// the reason, and the re-plan that follows offers exactly the remainder —
    /// resumption needs no code of its own because the plan is rebuilt from
    /// the filesystem and the landed entries are skips now.
    @Test func aCardThatDoesNotFitIsCopiedUpToTheFloorAndTheRePlanOffersTheRemainder() async throws {
        log("START aCardThatDoesNotFitIsCopiedUpToTheFloorAndTheRePlanOffersTheRemainder")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        for name in ["a.jpg", "b.jpg", "c.jpg"] {
            try Data(repeating: 7, count: 1024).write(to: cardURL.appending(path: name))
        }

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:disk-floor",
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        ImportPreferencesStore.save(prefs, defaults: defaults.makeDefaults())

        /// A volume with room for two of the three files above the floor,
        /// shrinking as copies land — what a real capacity figure does.
        @Sendable func bytesLanded() -> Int64 {
            guard let enumerator = FileManager.default.enumerator(
                at: destURL,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
            ) else {
                return 0
            }
            var total: Int64 = 0
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true {
                    total += Int64(values?.fileSize ?? 0)
                }
            }
            return total
        }
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: defaults,
            makeExecutor: { _ in
                LiveImportExecutor(store: store, volumeCapacity: { _ in FreeSpaceFloor.bytes + 2500 - bytesLanded() })
            }
        )
        await coordinator.start()
        let plan = try await waitForReady(coordinator, source: cardPath)
        #expect(plan.totals.copyCount == 3)
        await coordinator.queueImport(for: cardPath)

        let rePlanned = try await waitForPresentation(coordinator, source: cardPath) { pres in
            if case let .ready(summary, _, _, _) = pres.state {
                return pres.stopReason != nil && summary.copyCount == 1
            }
            return false
        }
        guard case .diskFloor = rePlanned.stopReason else {
            Issue.record("Expected a disk-floor stop, got \(String(describing: rePlanned.stopReason))")
            return
        }
        #expect(rePlanned.copiedJustNow == 2)
        #expect(rePlanned.plannedCount == 3)
        #expect(rePlanned.isFullyClean == false)
        if case let .ready(summary, _, _, _) = rePlanned.state {
            #expect(summary.skipCount == 2, "the two that landed are skips now")
        }
        #expect(try await store.importBatches().map(\.assetCount) == [2], "the stopped run's partial batch is real")
        for name in ["a.jpg", "b.jpg", "c.jpg"] {
            #expect(
                FileManager.default.fileExists(atPath: cardURL.appending(path: name).path),
                "nothing on the card is erased"
            )
        }
        log("END")
        await coordinator.shutdown()
    }

    /// A live execution's `ExecutionContext` (claims, namespace lease) already
    /// committed to a specific destination. Reordering libraries while that
    /// execution is in flight must not rewrite `session.destination` out from
    /// under it — only a session still on the default may track a reorder.
    @Test func executingDestinationSurvivesLibraryReorder() async throws {
        log("START executingDestinationSurvivesLibraryReorder")
        let temp = try makeTempRoot()
        let firstDestURL = temp.appending(path: "Zebra", directoryHint: .isDirectory)
        let secondDestURL = temp.appending(path: "Alpha", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        for url in [firstDestURL, secondDestURL, cardURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try Data(repeating: 9, count: 1024).write(to: cardURL.appending(path: "f.jpg"))

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: firstDestURL)
        try await store.addLibrary(url: secondDestURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.libraries.count == 2 && snap.libraries.allSatisfy { !$0.isScanning }
        }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:executing-reorder",
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        ImportPreferencesStore.save(prefs, defaults: defaults.makeDefaults())

        let execControl = ControlledExecutionControl()
        await execControl.suspendNextExecution(for: cardPath)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: defaults,
            makeExecutor: { _ in ControlledImportExecutor(control: execControl) }
        )
        await coordinator.start()
        _ = try await waitForReady(coordinator, source: cardPath)
        let firstDest = try CatalogPath.normalizedDirectoryPath(for: firstDestURL)
        let secondDest = try CatalogPath.normalizedDirectoryPath(for: secondDestURL)
        let beforeExec = try #require(await coordinator.currentPresentations().first { $0.sourcePath == cardPath })
        #expect(beforeExec.destinationPath == firstDest, "Default destination before execution")

        let queueTask = Task { await coordinator.queueImport(for: cardPath) }
        try await waitForPendingExecution(execControl, source: cardPath)
        let executing = try #require(await coordinator.currentPresentations().first { $0.sourcePath == cardPath })
        guard case .executing = executing.state else {
            Issue.record("Expected .executing, got \(executing.state)")
            await coordinator.shutdown()
            return
        }
        #expect(executing.destinationPath == firstDest)

        // Reorder while the execution is in flight.
        try await store.moveLibrary(from: 0, to: 1)
        try await waitForCoordinatorQuiescence(coordinator)
        let stillExecuting = try #require(await coordinator.currentPresentations().first { $0.sourcePath == cardPath })
        #expect(stillExecuting.destinationPath == firstDest, "Destination must not move mid-execution")

        await execControl.resumePending(
            for: cardPath,
            with: .completed(
                publishedCount: 1,
                hasBlockedEntries: false,
                hasEntryFailures: false,
                skippedForeignCount: 0,
                failedCount: 0,
                incompleteItems: []
            )
        )
        await queueTask.value

        // The controlled executor is a mock — it never touches the store, so
        // nothing occupancy-related naturally wakes the coordinator the way a
        // real settlement would. Simulate that wake directly: once no longer
        // executing, the next refresh is where a still-default destination
        // picks the reorder back up.
        _ = await store.bumpNamespaceRevision(for: cardPath)
        _ = try await waitForPresentation(
            coordinator,
            source: cardPath,
            predicate: { $0.destinationPath == secondDest }
        )
        log("END")
        await coordinator.shutdown()
    }

    // MARK: - 10. Shutdown

    @Test func shutdownWaitsForSuspendedWorkAndNoLaterPublication() async throws {
        log("START shutdownWaitsForSuspendedWorkAndNoLaterPublication")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardAURL = temp.appending(path: "CardA", directoryHint: .isDirectory)
        let cardBURL = temp.appending(path: "CardB", directoryHint: .isDirectory)
        for url in [destURL, cardAURL, cardBURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try Data(repeating: 16, count: 1024).write(to: cardAURL.appending(path: "f.jpg"))
        try Data(repeating: 17, count: 1024).write(to: cardBURL.appending(path: "g.jpg"))

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardAURL,
            identity: "volume:shutdown-A",
            displayName: "CardA",
            isEjectable: true
        )
        let cardAPath = try CatalogPath.normalizedDirectoryPath(for: cardAURL)
        try await store.attachRemovableVolume(
            mountURL: cardBURL,
            identity: "volume:shutdown-B",
            displayName: "CardB",
            isEjectable: true
        )
        let cardBPath = try CatalogPath.normalizedDirectoryPath(for: cardBURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.filter { $0.availability == .available }.count == 2
                && snap.removableSources.allSatisfy { !$0.isScanning }
        }

        // Ready requires proven naming facts (ARC-057); stand in for the enrichment

        // coordinator these tests do not run.

        await markEnrichmentLookedAtEveryRow(store, root: cardAPath)

        await markEnrichmentLookedAtEveryRow(store, root: cardBPath)

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        let builder = ControlledImportPlanBuilder()
        await builder.suspendNextBuild(for: cardAPath)
        await builder.suspendNextBuild(for: cardBPath)
        let execControl = ControlledExecutionControl()
        // We won't reach execution in this test, but need to test shutdown with builds suspended
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: defaults,
            planBuilder: builder,
            makeExecutor: { _ in ControlledImportExecutor(control: execControl) }
        )
        await coordinator.start()
        try await waitForPendingBuilder(builder, source: cardAPath)
        try await waitForPendingBuilder(builder, source: cardBPath)

        // Start shutdown while builds are suspended. It should cancel builds and return.
        log("END")
        log("END")
        await coordinator.shutdown()
        // After shutdown, no presentations should remain and no later publication after resuming old builds.
        let hasA = await coordinator.currentPresentations().contains(where: { $0.sourcePath == cardAPath })
        let hasB = await coordinator.currentPresentations().contains(where: { $0.sourcePath == cardBPath })
        #expect(!hasA && !hasB, "Shutdown should clear presentations")

        // Resume old builds — they should be stale and not publish after shutdown.
        // `shutdown()` cancelled and awaited both builds, so these resumes find
        // nothing to release and nothing can publish afterwards.
        await builder.resumePendingBuild(for: cardAPath)
        await builder.resumePendingBuild(for: cardBPath)
        let stillEmpty = await coordinator.currentPresentations().isEmpty
        #expect(stillEmpty, "No publication after shutdown even if old builds resume")
    }

    // MARK: - 11. Repeated import

    @Test func repeatedImportStartsExactlyOneBatch() async throws {
        log("START repeatedImportStartsExactlyOneBatch")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        for index in 0 ..< 4 {
            try Data(repeating: UInt8(index), count: 1024).write(to: cardURL.appending(path: "h\(index).jpg"))
        }

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:repeat-import",
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }

        // Ready requires proven naming facts (ARC-057); stand in for the enrichment
        // coordinator these tests do not run.
        await markEnrichmentLookedAtEveryRow(store, root: cardPath)
        let defaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(store: store, preferencesDomain: defaults)
        await coordinator.start()
        _ = try await waitForReady(coordinator, source: cardPath)

        async let first: Void = coordinator.queueImport(for: cardPath)
        async let second: Void = coordinator.queueImport(for: cardPath)
        _ = await (first, second)

        // Wait for the execution to settle.
        _ = try await waitForPresentation(coordinator, source: cardPath) { $0.copiedJustNow != nil }
        try await waitForCoordinatorQuiescence(coordinator)
        let batches = try await store.importBatches()
        #expect(batches.count == 1, "Repeated import should start exactly one batch")
        #expect(batches.first?.assetCount == 4)
        log("END")
        log("END")
        await coordinator.shutdown()
    }

    // MARK: - 12. Metadata wake (deterministic)

    /// C2. Preparing is the state that owns a count, and nothing held one across a
    /// rebuild: `.building` fell through to `.planning`, which draws no count and an
    /// indeterminate track. The live session alternated the two about once a second with
    /// the pair ~140 ms apart, so the bar's track could not hold still while a user watched
    /// it — the count vanished for a fraction of every cycle for the whole of preparation.
    ///
    /// A rebuild has no count of its own to offer, but the last one was already proven and
    /// published, so showing it asserts nothing new.
    @Test func aRebuildDuringPreparationKeepsTheProvenCount() async throws {
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        let relative = MediaRelativePath(rawValue: "undated.jpg")

        let scanner = CatalogScanner { rootPath, _, batchHandler in
            guard rootPath == cardPath else { return .empty }
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
        let store = CatalogStore(location: .inMemory, scanner: scanner, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        try await store.attachRemovableVolume(
            mountURL: cardURL, identity: "volume:c2-count-hold", displayName: "Card", isEjectable: true
        )

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(store: store, preferencesDomain: defaults)
        await coordinator.start()

        _ = try await waitForPresentation(coordinator, source: cardPath, predicate: { pres in
            if case .waitingForMetadata = pres.state {
                return true
            }
            return false
        })

        // Drive rebuilds while the naming fact is still unproven. Every frame this source
        // publishes must still carry a count; `.planning` is only correct before this
        // attachment has ever reported one.
        // `retryPlanning` is the user-facing intent that forces a rebuild without proving
        // any naming fact, so it reproduces exactly the situation that blanked the count:
        // a re-plan over a set whose rows enrichment has still not read.
        //
        // One rebuild, then a bounded observation. Two earlier shapes of this test hung the
        // suite and are recorded so neither is reintroduced: consuming the presentation
        // stream with an unbounded `await iterator.next()` cannot tell "no bad frame yet"
        // from "no frame is coming", and hammering `retryPlanning` in a tight loop queued
        // enough builds that `shutdown()` never drained. One rebuild is all the proof
        // needs — the defect was that *any* rebuild dropped the count.
        await coordinator.retryPlanning(for: cardPath)

        // Sample every frame until the rebuild has returned.
        var sawPlanning = false
        var sawCount = false
        try await waitUntil(every: .milliseconds(10)) {
            let quiescent = await coordinator.isQuiescent
            for pres in await coordinator.currentPresentations() where pres.sourcePath == cardPath {
                switch pres.state {
                case .planning: sawPlanning = true
                case .waitingForMetadata: sawCount = true
                default: break
                }
            }
            return quiescent
        }

        #expect(!sawPlanning, "a rebuild dropped the proven count back to an indeterminate Preparing")
        #expect(sawCount, "the source must keep reporting its proven count while preparing")

        await coordinator.shutdown()
    }

    /// J4 after an import: the card gains a file whose naming facts are pending. The
    /// settled run describes the card before that file, so holding it through the
    /// metadata wait drew Done — and the sidebar row its eject button — between
    /// Preparing frames. Every frame of the wait must carry the count.
    @Test func aCardThatGainsFilesAfterAnImportShowsOnlyTheCountWhileItWaits() async throws {
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 1024).write(to: cardURL.appending(path: "first.jpg"))

        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = CatalogStore(
            location: .inMemory,
            filesystemWatcher: watcher,
            scanCadence: .milliseconds(10),
            filesystemEventDebounce: .milliseconds(20)
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:gains-files-after-import",
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: defaults,
            makeExecutor: { _ in LiveImportExecutor(store: store) }
        )
        await coordinator.start()
        await markEnrichmentLookedAtEveryRow(store, root: cardPath)
        _ = try await waitForReady(coordinator, source: cardPath)
        await coordinator.queueImport(for: cardPath)
        _ = try await waitForPresentation(coordinator, source: cardPath, predicate: { pres in
            if case let .ready(summary, _, _, _) = pres.state {
                return summary.copyCount == 0 && pres.copiedJustNow == 1
            }
            return false
        })

        let second = cardURL.appending(path: "second.jpg")
        try Data(repeating: 4, count: 2048).write(to: second)
        emit(FilesystemEvent(path: second.path(percentEncoded: false), flags: 0))
        _ = try await waitForPresentation(coordinator, source: cardPath, predicate: { pres in
            if case .waitingForMetadata = pres.state {
                return true
            }
            return false
        })

        await coordinator.retryPlanning(for: cardPath)
        // Sample every frame until the rebuild has returned.
        var interrupted: MediaOperationSourceState?
        var sawCount = false
        try await waitUntil(every: .milliseconds(10)) {
            let quiescent = await coordinator.isQuiescent
            if let pres = await coordinator.currentPresentations().first(where: { $0.sourcePath == cardPath }) {
                if case .waitingForMetadata = pres.state {
                    sawCount = true
                } else {
                    interrupted = pres.state
                }
            }
            return quiescent
        }
        #expect(interrupted == nil, "the metadata wait was interrupted by \(String(describing: interrupted))")
        #expect(sawCount, "the card must keep reporting its naming count while it waits")
        await coordinator.shutdown()
    }

    @Test func catalogChangeWakesWaitingForMetadataSourceDeterministic() async throws {
        log("START catalogChangeWakesWaitingForMetadataSourceDeterministic")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        let relative = MediaRelativePath(rawValue: "undated.jpg")

        let scanner = CatalogScanner { rootPath, _, batchHandler in
            guard rootPath == cardPath else { return .empty }
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
        let store = CatalogStore(location: .inMemory, scanner: scanner, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:metadata-wake-adversarial",
            displayName: "Card",
            isEjectable: true
        )

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(store: store, preferencesDomain: defaults)
        await coordinator.start()

        // Wait for waitingForMetadata
        let waiting = try await waitForPresentation(coordinator, source: cardPath, predicate: { pres in
            if case .waitingForMetadata = pres.state {
                return true
            }
            return false
        })
        guard case .waitingForMetadata = waiting.state else {
            Issue.record("Expected waitingForMetadata")
            log("END")
            log("END")
            await coordinator.shutdown()
            return
        }

        let captureDate = Date(timeIntervalSince1970: 1_767_279_600)
        let result = EnrichmentResult(
            id: MediaAssetID(libraryRootPath: cardPath, relativePath: relative),
            metadata: AssetMetadata(timestamps: [
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
            ]),
            enrichedKind: nil,
            enrichedFormat: nil,
            thumbnailPath: nil,
            sourceSize: 10,
            sourceMTimeSeconds: nil,
            contentHash: nil
        )
        #expect(await store.applyEnrichmentBatch([result]) == .applied(count: 1))

        _ = try await waitForPresentation(coordinator, source: cardPath, predicate: { pres in
            if case .ready = pres.state {
                return true
            }
            return false
        })
        log("END")
        log("END")
        await coordinator.shutdown()
    }

    // MARK: - 13. Zero-copy without delete

    @Test func zeroCopyWithoutDeleteRemainsReadyWithoutExecutor() async throws {
        log("START zeroCopyWithoutDeleteRemainsReadyWithoutExecutor")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        // Create a file that already exists at destination as preexisting (same name, size, mtime)
        let srcFile = cardURL.appending(path: "already.jpg")
        let destFile = destURL.appending(path: "already.jpg")
        try Data(repeating: 18, count: 1024).write(to: srcFile)
        try Data(repeating: 18, count: 1024).write(to: destFile)
        // Ensure mtimes match by copying mtime? For test, we can use filesystem namespace live check: it checks live
        // size and expected mtime derived from policy.
        // For original naming with no folder, expected mtime is source mtime. To make them match, ensure both have same
        // mtime after copy.
        // We'll set dest's mtime to src's mtime.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: srcFile.path),
           let mtime = attrs[.modificationDate] as? Date
        {
            try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: destFile.path)
        }

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:zero-copy-no-delete",
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        prefs.deleteSourceAfterImport = false
        ImportPreferencesStore.save(prefs, defaults: defaults.makeDefaults())

        let execControl = ControlledExecutionControl()
        // No suspension for this test; we will check that executor is NOT invoked.
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: defaults,
            makeExecutor: { _ in ControlledImportExecutor(control: execControl) }
        )
        await coordinator.start()
        let plan = try await waitForReady(coordinator, source: cardPath)
        #expect(plan.totals.copyCount == 0, "Should be zero-copy")
        await coordinator.queueImport(for: cardPath)
        try await waitForCoordinatorQuiescence(coordinator)
        // Should remain Ready, not executing/completed, and no executor invocation.
        let pres = try await waitForPresentation(coordinator, source: cardPath, predicate: { presentation in
            if case .ready = presentation.state {
                return true
            }
            return false
        })
        guard case .ready = pres.state else {
            Issue.record("Expected to remain Ready for zero-copy without delete, got \(pres.state)")
            log("END")
            log("END")
            await coordinator.shutdown()
            return
        }
        let executed = await execControl.recordedExecuted()
        #expect(executed.isEmpty, "Executor should not be invoked for zero-copy without delete")
        log("END")
        log("END")
        await coordinator.shutdown()
    }

    // MARK: - 14. Zero-copy with delete

    @Test func zeroCopyWithDeleteExecutorRunsDeletionPath() async throws {
        log("START zeroCopyWithDeleteExecutorRunsDeletionPath")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        let srcFile = cardURL.appending(path: "already2.jpg")
        let destFile = destURL.appending(path: "already2.jpg")
        try Data(repeating: 19, count: 1024).write(to: srcFile)
        try Data(repeating: 19, count: 1024).write(to: destFile)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: srcFile.path),
           let mtime = attrs[.modificationDate] as? Date
        {
            try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: destFile.path)
        }

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:zero-copy-delete",
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        prefs.deleteSourceAfterImport = true
        ImportPreferencesStore.save(prefs, defaults: defaults.makeDefaults())

        // Use live executor for this test so deletion actually happens.
        let coordinator = MediaOperationCoordinator(store: store, preferencesDomain: defaults)
        await coordinator.start()
        let plan = try await waitForReady(coordinator, source: cardPath)
        #expect(plan.totals.copyCount == 0, "Should be zero-copy")
        await coordinator.queueImport(for: cardPath)
        // For zero-copy with delete, the executor should run and delete source.
        // Poll for source file deletion or for completed state.
        // Zero-copy with delete deletes the source file and settles as completed.
        try await waitUntil(every: .milliseconds(50)) {
            guard !FileManager.default.fileExists(atPath: srcFile.path) else {
                return false
            }
            let pres = await coordinator.currentPresentations().first { $0.sourcePath == cardPath }
            if case .completed = pres?.state {
                return true
            }
            return false
        }
        log("END")
        await coordinator.shutdown()
    }

    // MARK: - 14. Device inventory triggers a replan (ARC-047)

    @Test func deviceInventoryLandingAfterAttachTriggersReplan() async throws {
        log("START deviceInventoryLandingAfterAttachTriggersReplan")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let stagingRoot = temp.appending(path: "DeviceStaging/Camera", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }

        let rootPath = try await store.attachDeviceMTP(
            stagingRootURL: stagingRoot,
            identity: "camera:replan-adversarial",
            displayName: "Camera"
        )

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(store: store, preferencesDomain: defaults)
        await coordinator.start()

        // The session is created and reaches Ready the instant the device root
        // becomes available, before any device rows exist — exactly the D1/D2
        // repro shape: a plan built from whatever was there at attach.
        let emptyPlan = try await waitForReady(coordinator, source: rootPath)
        #expect(emptyPlan.totals.copyCount == 0)

        // Live device inventory lands after the session already reached Ready.
        let scan = try await store.beginDeviceCatalogEnumeration(rootPath: rootPath)
        let relativePath = MediaRelativePath(rawValue: "DCIM/IMG_0001.JPG")
        try await store.recordDeviceCatalogBatch([
            ScannedMediaFile(
                relativePath: relativePath,
                name: "IMG_0001.JPG",
                contentTypeIdentifier: "public.jpeg",
                byteSize: 42,
                createdAt: Date(timeIntervalSince1970: 1000),
                contentModifiedAt: Date(timeIntervalSince1970: 1000)
            ),
        ], scan: scan)
        try await store.completeDeviceCatalogEnumeration(scan: scan, observedPaths: [relativePath])
        // ARC-057: a camera is gated on proven naming facts exactly like
        // a card, and its bytes are staged locally so enrichment can supply them.
        // Nothing runs enrichment in this test, so stand in for it.
        await markEnrichmentLookedAtEveryRow(store, root: rootPath)

        // Without the D2 fix, the coordinator would sit forever on the stale
        // empty plan from before device inventory landed.
        // The coordinator replans once device inventory lands after attach.
        try await waitUntil(every: .milliseconds(20)) {
            await coordinator.readyPlan(for: rootPath)?.totals.copyCount == 1
        }
        log("END")
        log("END")
        await coordinator.shutdown()
    }

    // MARK: - 15. Import refused while still enumerating (ADR 0024, ImportSourceReadiness)

    @Test func importIsRefusedWhileDeviceIsStillEnumerating() async throws {
        log("START importIsRefusedWhileDeviceIsStillEnumerating")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let stagingRoot = temp.appending(path: "DeviceStaging/Camera", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }

        let rootPath = try await store.attachDeviceMTP(
            stagingRootURL: stagingRoot,
            identity: "camera:readiness-gate-adversarial",
            displayName: "Camera"
        )

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(store: store, preferencesDomain: defaults)
        await coordinator.start()
        _ = try await waitForReady(coordinator, source: rootPath)

        // Live device inventory lands while the session already has a plan
        // (D1's exact precondition) — enumeration is still in progress the
        // whole time; activity never flips idle here.
        let scan = try await store.beginDeviceCatalogEnumeration(rootPath: rootPath)
        let relativePath = MediaRelativePath(rawValue: "DCIM/IMG_0001.JPG")
        try await store.recordDeviceCatalogBatch([
            ScannedMediaFile(
                relativePath: relativePath,
                name: "IMG_0001.JPG",
                contentTypeIdentifier: "public.jpeg",
                byteSize: 64,
                createdAt: Date(timeIntervalSince1970: 1000),
                contentModifiedAt: Date(timeIntervalSince1970: 1000)
            ),
        ], scan: scan)
        // ARC-057: a camera is gated on proven naming facts like a card.
        // This test's subject is the *readiness* gate (ADR 0024) — that a plan built
        // from an unstable inventory is withheld — so satisfy the earlier naming gate
        // and let the readiness gate be what withholds it.
        await markEnrichmentLookedAtEveryRow(store, root: rootPath)

        // The internal plan now has the item (proves it built while still
        // enumerating) but the bar must hold state A the entire time —
        // never offering a plan built from a not-yet-stable inventory.
        // The internal plan builds from the batch even while still enumerating.
        try await waitUntil(every: .milliseconds(20)) {
            await coordinator.readyPlan(for: rootPath)?.totals.copyCount == 1
        }
        let stillPreparing = await coordinator.currentPresentations().first(where: { $0.sourcePath == rootPath })
        var isPreparing = false
        if case .inventory = stillPreparing?.state {
            isPreparing = true
        }
        #expect(isPreparing, "Published state must stay in the preparing family while still enumerating")

        // Pressing Import while still enumerating must not execute.
        await coordinator.queueImport(for: rootPath)
        try await waitForCoordinatorQuiescence(coordinator)
        let afterQueue = await coordinator.currentPresentations().first(where: { $0.sourcePath == rootPath })
        if case .executing = afterQueue?.state {
            Issue.record("Import executed while the device was still enumerating")
        }
        if case .completed = afterQueue?.state {
            Issue.record("Import completed while the device was still enumerating")
        }

        // Enumeration finishes: readiness flips .ready and the deferred request is
        // retried. This coordinator has no camera import access wired in, so
        // `isExecutableSource` fails and `markExecutionUnavailable` stops the run
        // rather than copying. Reaching that state at all is what this test
        // verifies — it proves the request made it past the readiness gate.
        //
        // The state is the typed `.executionUnavailable`, not
        // `.failed(.unexpected("executionUnavailable"))`. `.unexpected(detail:)`
        // is documented as the one case whose detail is for the log and never the
        // bar, so routing a known, named condition through it would publish an
        // internal string as a user-facing fact.
        try await store.completeDeviceCatalogEnumeration(scan: scan, observedPaths: [relativePath])
        let resolved = try await waitForPresentation(coordinator, source: rootPath, predicate: { pres in
            if case .executionUnavailable = pres.state {
                return true
            }
            return false
        })
        if case let .executionUnavailable(summary, _, attentionItems) = resolved.state {
            // The plan that could not execute is still the one the gate admitted:
            // the single enumerated file, with nothing needing attention.
            #expect(summary.copyCount == 1)
            #expect(attentionItems.isEmpty)
        } else {
            Issue.record("Expected executionUnavailable once readiness resolved, got \(resolved.state)")
        }
        log("END")
        log("END")
        await coordinator.shutdown()
    }
}

/// A builder whose next `unreadableBuilds` results carry a destination folder
/// that could not be listed — the shape a cloud provider mid-sync produced on
/// 2026-09-13 — and live results otherwise.
private actor UnreadableThenLivePlanBuilder: ImportPlanBuilding {
    private var unreadableBuilds: Int
    private(set) var builds = 0

    init(unreadableBuilds: Int) {
        self.unreadableBuilds = unreadableBuilds
    }

    func setUnreadableBuilds(_ count: Int) {
        unreadableBuilds = count
    }

    func build(
        snapshot: ImportPlanningSnapshot,
        additionalReserved: Set<MediaRelativePath>
    ) async -> ImportPlanBuildResult {
        builds += 1
        if unreadableBuilds > 0 {
            unreadableBuilds -= 1
            let namespace = DestinationNamespace(
                entries: [:],
                enumeratedFolders: [],
                unreadableFolders: ["": "NSCocoaErrorDomain#256"],
                capabilities: snapshot.destinationCapabilities
            )
            let plan = MediaTransferPlanner.planImport(
                snapshot: snapshot,
                namespace: namespace,
                additionalReserved: additionalReserved
            )
            return ImportPlanBuildResult(plan: plan, namespace: namespace, enumerateMs: 0, planMs: 0)
        }
        return await LiveImportPlanBuilder().build(snapshot: snapshot, additionalReserved: additionalReserved)
    }
}
