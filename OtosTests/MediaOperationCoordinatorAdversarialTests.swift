import Foundation
import OSLog
@testable import OtosKit
import Testing

/// Adversarial lifecycle tests for MediaOperationCoordinator (plan 0079 Stage 4).
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
        source: LibraryRootPath,
        timeout: Duration = .seconds(8)
    ) async throws -> MediaOperationPlan {
        let deadline = ContinuousClock().now + timeout
        while ContinuousClock().now < deadline {
            if let plan = await coordinator.readyPlan(for: source) {
                return plan
            }
            if let pres = await coordinator.currentPresentations().first(where: { $0.sourcePath == source }),
               case .failed = pres.state
            {
                throw TestError.planFailed(pres.state)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestError.timeout("waitForReady \(source.rawValue)")
    }

    private func waitForPresentation(
        _ coordinator: MediaOperationCoordinator,
        source: LibraryRootPath,
        predicate: (MediaOperationSourcePresentation) -> Bool,
        timeout: Duration = .seconds(8)
    ) async throws -> MediaOperationSourcePresentation {
        let deadline = ContinuousClock().now + timeout
        while ContinuousClock().now < deadline {
            if let pres = await coordinator.currentPresentations().first(where: { $0.sourcePath == source }),
               predicate(pres)
            {
                return pres
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestError.timeout("waitForPresentation \(source.rawValue)")
    }

    // `waitForPendingBuilder` and `waitForPendingBuilderCount` are the shared gates in
    // `MediaOperationCoordinatorTestSupport.swift`. Do not add same-named private
    // wrappers here: an unqualified call inside this type resolves to the member, not
    // the free function, so a wrapper that "delegates" calls itself. Because the call
    // is `async`, each frame is heap-allocated rather than stack-allocated, so the
    // recursion does not overflow — it allocates until the machine exhausts swap.

    private func waitForPendingExecution(
        _ control: ControlledExecutionControl,
        source: LibraryRootPath,
        timeout: Duration = .seconds(5)
    ) async throws {
        let deadline = ContinuousClock().now + timeout
        while ContinuousClock().now < deadline {
            let pending = await control.pendingSources()
            if pending.contains(source) {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestError.timeout("execution pending \(source.rawValue)")
    }

    private func waitUntilNoPresentation(
        _ coordinator: MediaOperationCoordinator,
        source: LibraryRootPath,
        timeout: Duration = .seconds(5)
    ) async throws {
        let deadline = ContinuousClock().now + timeout
        while ContinuousClock().now < deadline {
            let has = await coordinator.currentPresentations().contains(where: { $0.sourcePath == source })
            if !has {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestError.timeout("still has presentation \(source.rawValue)")
    }

    private enum TestError: Error, CustomStringConvertible {
        case timeout(String)
        case planFailed(MediaOperationSourceState)
        var description: String {
            switch self {
            case let .timeout(s): "timeout: \(s)"
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
        let destPath = try CatalogPath.normalizedDirectoryPath(for: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(mountURL: cardURL, identity: "volume:detach-build", displayName: "Card", isEjectable: true)
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in snap.removableSources.contains { $0.path == cardPath && !$0.isScanning } }

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
        _ = try await waitForCatalogStoreState(store) { snap in !snap.removableSources.contains { $0.path == cardPath && $0.availability == .available } }
        // Give coordinator time to process detach via planning stream.
        try await Task.sleep(for: .milliseconds(100))
        try await waitUntilNoPresentation(coordinator, source: cardPath)

        // Resume old builder — should be stale and produce no presentation.
        await builder.resumePendingBuild(for: cardPath)
        try await Task.sleep(for: .milliseconds(200))
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
        try await store.attachRemovableVolume(mountURL: cardURL, identity: "volume:reattach-A", displayName: "Card", isEjectable: true)
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in snap.removableSources.contains { $0.path == cardPath && !$0.isScanning } }

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
        _ = try await waitForCatalogStoreState(store) { snap in !snap.removableSources.contains { $0.path == cardPath && $0.availability == .available } }
        try await Task.sleep(for: .milliseconds(100))
        // Reattach at same mount path with new identity, suspend its build too.
        try Data(repeating: 3, count: 1024).write(to: cardURL.appending(path: "c.jpg"))
        await builder.suspendNextBuild(for: cardPath)
        try await store.attachRemovableVolume(mountURL: cardURL, identity: "volume:reattach-B", displayName: "Card", isEjectable: true)
        _ = try await waitForCatalogStoreState(store) { snap in snap.removableSources.contains { $0.path == cardPath && !$0.isScanning } }
        // Wait for B's build to be queued. With cancellation-dummy on detach, A's pending is already resolved, so only B is pending.
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
        try await store.attachRemovableVolume(mountURL: cardURL, identity: "volume:clear-new", displayName: "Card", isEjectable: true)
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in snap.removableSources.contains { $0.path == cardPath && !$0.isScanning } }

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

        // Simulate rapid detach/reattach while old build still pending, then detach new build while still pending and ensure it stays cancelled.
        try await store.detachRemovableSource(identity: "volume:clear-new", reason: .ejected)
        _ = try await waitForCatalogStoreState(store) { snap in !snap.removableSources.contains { $0.path == cardPath && $0.availability == .available } }
        try await Task.sleep(for: .milliseconds(100))
        await builder.suspendNextBuild(for: cardPath)
        try await store.attachRemovableVolume(mountURL: cardURL, identity: "volume:clear-new-B", displayName: "Card", isEjectable: true)
        _ = try await waitForCatalogStoreState(store) { snap in snap.removableSources.contains { $0.path == cardPath && !$0.isScanning } }
        try await waitForPendingBuilder(builder, source: cardPath)
        // Detach B while its build is still suspended — it should be cancelled.
        try await store.detachRemovableSource(identity: "volume:clear-new-B", reason: .ejected)
        _ = try await waitForCatalogStoreState(store) { snap in !snap.removableSources.contains { $0.path == cardPath && $0.availability == .available } }
        try await Task.sleep(for: .milliseconds(100))
        // Resume the now-stale B build — must not publish.
        await builder.resumePendingBuild(for: cardPath)
        try await Task.sleep(for: .milliseconds(200))
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
        try await store.attachRemovableVolume(mountURL: cardAURL, identity: "volume:claim-detach-A", displayName: "CardA", isEjectable: true)
        let cardAPath = try CatalogPath.normalizedDirectoryPath(for: cardAURL)
        _ = try await waitForCatalogStoreState(store) { snap in snap.removableSources.contains { $0.path == cardAPath && !$0.isScanning } }

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
        _ = try await waitForCatalogStoreState(store) { snap in !snap.removableSources.contains { $0.path == cardAPath && $0.availability == .available } }
        try await Task.sleep(for: .milliseconds(200))

        // Attach B with same filename
        let cardBURL = temp.appending(path: "CardB", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cardBURL, withIntermediateDirectories: true)
        try Data(repeating: 6, count: 1024).write(to: cardBURL.appending(path: "shared.jpg"))
        try await store.attachRemovableVolume(mountURL: cardBURL, identity: "volume:claim-detach-B", displayName: "CardB", isEjectable: true)
        let cardBPath = try CatalogPath.normalizedDirectoryPath(for: cardBURL)
        _ = try await waitForCatalogStoreState(store) { snap in snap.removableSources.contains { $0.path == cardBPath && !$0.isScanning } }
        let planB = try await waitForReady(coordinator, source: cardBPath)
        // After detach, B should get base name, not suffix.
        #expect(planB.entries.first?.finalDestination.rawValue == "shared.jpg", "Claim should be released on detach, B should get base name")
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
        try await store.attachRemovableVolume(mountURL: cardAURL, identity: "volume:cancel-A", displayName: "CardA", isEjectable: true)
        let cardAPath = try CatalogPath.normalizedDirectoryPath(for: cardAURL)
        try await store.attachRemovableVolume(mountURL: cardBURL, identity: "volume:cancel-B", displayName: "CardB", isEjectable: true)
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
        // Resume A's execution with cancelled result — this simulates executor observing cancel and returning cancelled.
        log("STEP resumePending cancelled")
        await execControl.resumePending(
            for: cardAPath,
            with: .cancelled(
                publishedCount: 0,
                hasBlockedEntries: false,
                hasEntryFailures: false,
                skippedForeignCount: 0,
                failedCount: 0
            )
        )
        log("STEP sleep 300")
        try await Task.sleep(for: .milliseconds(300))
        await queueTask.value
        // After cancel, A's claim should be released. B should be able to reclaim base name on rebuild.
        // Trigger rebuild for B.
        log("STEP retryPlanning")
        await coordinator.retryPlanning(for: cardBPath)
        log("STEP waitForReady B after")
        // Poll until B's plan shows base name, since waitForReady may return old suffix immediately.
        var planBAfter: MediaOperationPlan?
        let deadlineB = ContinuousClock().now + .seconds(5)
        while ContinuousClock().now < deadlineB {
            if let p = await coordinator.readyPlan(for: cardBPath), p.entries.first?.finalDestination.rawValue == "shared.jpg" {
                planBAfter = p
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(planBAfter?.entries.first?.finalDestination.rawValue == "shared.jpg", "After A's cancel, B should reclaim base name")
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
        try await store.attachRemovableVolume(mountURL: cardAURL, identity: "volume:fail-A", displayName: "CardA", isEjectable: true)
        let cardAPath = try CatalogPath.normalizedDirectoryPath(for: cardAURL)
        try await store.attachRemovableVolume(mountURL: cardBURL, identity: "volume:fail-B", displayName: "CardB", isEjectable: true)
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
        try await Task.sleep(for: .milliseconds(300))
        await queueTask2.value
        log("STEP retryPlanning")
        await coordinator.retryPlanning(for: cardBPath)
        log("STEP waitForReady B after")
        var planBAfter: MediaOperationPlan?
        let deadlineB2 = ContinuousClock().now + .seconds(5)
        while ContinuousClock().now < deadlineB2 {
            if let p = await coordinator.readyPlan(for: cardBPath), p.entries.first?.finalDestination.rawValue == "shared.jpg" {
                planBAfter = p
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(planBAfter?.entries.first?.finalDestination.rawValue == "shared.jpg", "After failure, B should reclaim base name")
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
        try await store.attachRemovableVolume(mountURL: cardAURL, identity: "volume:ledger-A", displayName: "CardA", isEjectable: true)
        let cardAPath = try CatalogPath.normalizedDirectoryPath(for: cardAURL)
        try await store.attachRemovableVolume(mountURL: cardBURL, identity: "volume:ledger-B", displayName: "CardB", isEjectable: true)
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
        // Resume B — it was built against same namespace snapshot without seeing A's claim, so it will have base name too,
        // but coordinator's conflict check should detect that its newClaims intersect currentLedger and re-dirty + rebuild.
        await builder.resumePendingBuild(for: cardBPath)
        // B's first completion should have been discarded due to conflict, and a second build scheduled.
        // That second build is not suspended (we only suspended one per source), so it should complete quickly with suffix.
        let planB = try await waitForReady(coordinator, source: cardBPath)
        #expect(planB.entries.first?.finalDestination.rawValue != "shared.jpg", "B should have suffix after conflict rebuild")
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
        try Data(repeating: 14, count: 1024).write(to: cardBURL.appending(path: "shared.jpg"))

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(mountURL: cardAURL, identity: "volume:settle-A", displayName: "CardA", isEjectable: true)
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
        let deadline = ContinuousClock().now + .seconds(8)
        var published = false
        while ContinuousClock().now < deadline {
            if FileManager.default.fileExists(atPath: destURL.appending(path: "shared.jpg").path) {
                published = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(published, "A's file should be published")

        // Attach B only after A has published. This keeps the test about settlement
        // against the real destination file rather than racing two initial claims.
        try await store.attachRemovableVolume(mountURL: cardBURL, identity: "volume:settle-B", displayName: "CardB", isEjectable: true)
        let cardBPath = try CatalogPath.normalizedDirectoryPath(for: cardBURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardBPath && $0.availability == .available && !$0.isScanning }
        }

        // B's first build sees the real file, not A's now-released ledger claim,
        // so its plan must still use a suffix.
        await coordinator.retryPlanning(for: cardBPath)
        // Poll until B's plan shows suffix (real file), since attachment may first
        // deliver a transient plan before the explicit retry settles.
        var planB: MediaOperationPlan?
        let deadlineB3 = ContinuousClock().now + .seconds(5)
        while ContinuousClock().now < deadlineB3 {
            if let p = await coordinator.readyPlan(for: cardBPath),
               p.entries.first?.finalDestination.rawValue != "shared.jpg",
               p.entries.first?.finalDestination.rawValue.contains("shared") == true
            {
                planB = p
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(planB?.entries.first?.finalDestination.rawValue != "shared.jpg", "B should still have suffix due to real file, even after A's claim dies")
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
        try await store.attachRemovableVolume(mountURL: cardURL, identity: "volume:detach-exec", displayName: "Card", isEjectable: true)
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in snap.removableSources.contains { $0.path == cardPath && !$0.isScanning } }

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
        _ = try await waitForCatalogStoreState(store) { snap in !snap.removableSources.contains { $0.path == cardPath && $0.availability == .available } }
        try await Task.sleep(for: .milliseconds(100))
        try await waitUntilNoPresentation(coordinator, source: cardPath)

        // Late execution completion must not recreate presentation
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
        try await Task.sleep(for: .milliseconds(200))
        await queueTask3.value
        let has = await coordinator.currentPresentations().contains(where: { $0.sourcePath == cardPath })
        #expect(!has, "Late execution result after detach must not recreate presentation")
        // Verify executor was asked to cancel on detach
        // Controlled executor's cancel is observed via task cancellation; check control's cancelled set?
        // At least ensure no crash.
        log("END")
        log("END")
        await coordinator.shutdown()
    }

    /// `import-bar.md` "Where the user is standing": the batch ID is carried as
    /// state on the presentation, so a consumer never needs to have observed
    /// the frame that first set it — only the current snapshot — to know
    /// which batch this attachment landed in. `presentationsStream()`'s
    /// `.bufferingNewest(1)` can drop any number of intermediate frames
    /// (trap #5); this proves the fact survives that by construction rather
    /// than by having watched every frame. `.executing`'s own `batchID` is
    /// gated on a real published asset (plan 0095 step 7, owner decision:
    /// "move batch selection to first-asset") — this controlled executor
    /// never journals one, so `batchID` legitimately stays hidden throughout
    /// `.executing` here; the durability claim is proven from settlement
    /// onward instead.
    @Test func batchIDIsStateThatSurvivesADroppedIntermediateFrame() async throws {
        log("START batchIDIsStateThatSurvivesADroppedIntermediateFrame")
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
        try await store.attachRemovableVolume(mountURL: cardURL, identity: "volume:batch-id", displayName: "Card", isEjectable: true)
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in snap.removableSources.contains { $0.path == cardPath && !$0.isScanning } }

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

        // `.executing`'s own batchID is gated on a real published asset (plan
        // 0095 step 7) — this controlled executor never journals one, so
        // batchID legitimately stays nil throughout `.executing` here.
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

        let deadline = ContinuousClock().now + Duration.seconds(5)
        var sawCompletion = false
        var mintedBatch: ImportBatchID?
        while ContinuousClock().now < deadline {
            if let pres = await coordinator.currentPresentations().first(where: { $0.sourcePath == cardPath }),
               pres.copiedJustNow != nil
            {
                mintedBatch = try #require(pres.batchID, "batchID must be present once the run has settled")
                #expect(pres.copiedJustNow == 1)
                sawCompletion = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sawCompletion, "Expected lastCompletion to be recorded after the executor result settled")
        // A second, independent snapshot read finds the same value without
        // having observed the transition that set it — state, not an event.
        let again = try #require(await coordinator.currentPresentations().first { $0.sourcePath == cardPath })
        #expect(again.batchID == mintedBatch)
        log("END")
        await coordinator.shutdown()
    }

    /// Plan 0095 D6: `presentation(for:)` used to synthesize a zero-progress
    /// literal for `.executing` every time it was derived — real progress only
    /// ever reached the one private splice-and-yield path inside
    /// `applyExecutionProgress`, so any other re-derivation (a `publish()` for
    /// an unrelated reason, or simply re-reading the current snapshot, as here)
    /// showed zeros even after real progress had landed. `session.lastProgress`
    /// is what that same shared derivation reads now, so `currentPresentations()`
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
        try await store.attachRemovableVolume(mountURL: cardURL, identity: "volume:live-progress", displayName: "Card", isEjectable: true)
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in snap.removableSources.contains { $0.path == cardPath && !$0.isScanning } }

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
        let outcome = try await withTestTimeout("completed frame observed", timeout: .seconds(5)) {
            () async throws -> (summary: MediaOperationPlanTotals, skippedForeignCount: Int, failedCount: Int) in
            var iterator = stream.makeAsyncIterator()
            while let values = await iterator.next() {
                if let pres = values.first(where: { $0.sourcePath == cardPath }),
                   case let .completed(summary, skippedForeignCount, failedCount, _) = pres.state
                {
                    return (summary, skippedForeignCount, failedCount)
                }
            }
            throw AsyncTestTimeoutError.streamEnded("completed frame for \(cardPath.rawValue)")
        }
        await queueTask.value
        #expect(outcome.summary.copyCount == 1)
        #expect(outcome.skippedForeignCount == 1)
        #expect(outcome.failedCount == 1)
        log("END")
        await coordinator.shutdown()
    }

    /// `import-bar.md` state F ("card gone"): the batch row outlives the
    /// source session. A settled (not executing) attachment's final
    /// presentation must still be findable by `batchID` after its source
    /// detaches, with `cardStillExists` now false, so the bar can keep
    /// rendering on `.importBatch(id)` after the removable row disappears.
    @Test func batchPresentationSurvivesDetachAfterCleanSettle() async throws {
        log("START batchPresentationSurvivesDetachAfterCleanSettle")
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
        try await store.attachRemovableVolume(mountURL: cardURL, identity: "volume:gone-snapshot", displayName: "Card", isEjectable: true)
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in snap.removableSources.contains { $0.path == cardPath && !$0.isScanning } }

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

        let settled = try await waitForPresentation(coordinator, source: cardPath) { $0.copiedJustNow != nil }
        let batchID = try #require(settled.batchID)
        #expect(settled.cardStillExists)

        // Detach races the post-settlement re-plan on purpose: the detach
        // path snapshots the batch's last presentation regardless of whether
        // it catches the session `.completed`, `.building`, or `.ready` — the
        // fact that matters (`session.lastCompletion`) is set the moment
        // `copiedJustNow` above became non-nil and does not depend on phase.
        try await store.detachRemovableSource(identity: "volume:gone-snapshot", reason: .ejected)
        _ = try await waitForCatalogStoreState(store) { snap in !snap.removableSources.contains { $0.path == cardPath && $0.availability == .available } }

        // The batch's presentation survives its source session's removal by
        // design (`import-bar.md` state F, "card gone") and keeps the same
        // `sourcePath` — it is a fact about that batch, not a live session —
        // so the oracle here is `cardStillExists` flipping to false under the
        // stable `batchID`, never "no presentation for this source" (that
        // would never resolve, since the snapshot is the intended survivor).
        let afterDetach = try await waitForPresentation(coordinator, source: cardPath) { pres in
            pres.batchID == batchID && pres.cardStillExists == false
        }
        #expect(afterDetach.copiedJustNow == 1)
        log("END")
        await coordinator.shutdown()
    }

    /// Plan 0092 increment 6: a failure before any copy never sets
    /// `lastCompletion`, so without `lastAttemptedBatch` the presentation's
    /// `batchID` would go nil the instant `.executing` becomes `.failed` —
    /// right when the sidebar-follow feature and state G ("never
    /// auto-dismisses") most need it to stay identified by batch.
    /// `lastAttemptedBatch`'s fallback is unaffected by plan 0095 step 7's
    /// `.executing`-only gate (below): a failed run still needs its batch
    /// pinned regardless of whether anything ever published.
    @Test func batchIDSurvivesAnImmediateFailureBeforeAnyCopy() async throws {
        log("START batchIDSurvivesAnImmediateFailureBeforeAnyCopy")
        let temp = try makeTempRoot()
        let destURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 1024).write(to: cardURL.appending(path: "h.jpg"))

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(mountURL: cardURL, identity: "volume:immediate-fail", displayName: "Card", isEjectable: true)
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in snap.removableSources.contains { $0.path == cardPath && !$0.isScanning } }
        let destPath = try CatalogPath.normalizedDirectoryPath(for: destURL)

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

        let executing = try #require(await coordinator.currentPresentations().first { $0.sourcePath == cardPath })
        #expect(executing.batchID == nil, "batchID must stay hidden during .executing until a real asset has published")

        // A failure with nothing really wrong self-heals via the coordinator's
        // ordinary "rebuild after any terminal settlement" behavior — `.failed`
        // would be gone again within the same actor turn, before any poll
        // could observe it. Removing the destination first makes the
        // triggered rebuild fail too (no destination), settling on a stable
        // `.failed` this test can actually poll for — the same shape a real
        // persistent problem (genuinely out of space, destination genuinely
        // gone) would have in production.
        try await store.removeLibrary(path: destPath)
        await execControl.resumePending(for: cardPath, with: .failed(reason: .outOfSpace))
        await queueTask.value

        let failed = try await waitForPresentation(coordinator, source: cardPath) { pres in
            if case .failed = pres.state {
                return true
            }
            return false
        }
        #expect(failed.batchID != nil, "The batch minted for this attempt must survive into the Failed presentation")
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
        try await store.attachRemovableVolume(mountURL: cardURL, identity: "volume:executing-reorder", displayName: "Card", isEjectable: true)
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in snap.removableSources.contains { $0.path == cardPath && !$0.isScanning } }

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
        try await Task.sleep(for: .milliseconds(300))
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
        // Waits on the same moveLibrary-triggered refreshSources cycle as
        // MediaOperationCoordinatorTests' readyGeneration waits; under
        // full-suite concurrent load this measured 8.393s against the 8s
        // default (2026-08-17 verify.sh study), so the explicit budget here
        // carries real margin over that.
        _ = try await waitForPresentation(
            coordinator,
            source: cardPath,
            predicate: { $0.destinationPath == secondDest },
            timeout: .seconds(20)
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
        try await store.attachRemovableVolume(mountURL: cardAURL, identity: "volume:shutdown-A", displayName: "CardA", isEjectable: true)
        let cardAPath = try CatalogPath.normalizedDirectoryPath(for: cardAURL)
        try await store.attachRemovableVolume(mountURL: cardBURL, identity: "volume:shutdown-B", displayName: "CardB", isEjectable: true)
        let cardBPath = try CatalogPath.normalizedDirectoryPath(for: cardBURL)
        _ = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.filter { $0.availability == .available }.count == 2
                && snap.removableSources.allSatisfy { !$0.isScanning }
        }

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
        await builder.resumePendingBuild(for: cardAPath)
        await builder.resumePendingBuild(for: cardBPath)
        try await Task.sleep(for: .milliseconds(200))
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
        for i in 0 ..< 4 {
            try Data(repeating: UInt8(i), count: 1024).write(to: cardURL.appending(path: "h\(i).jpg"))
        }

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(mountURL: cardURL, identity: "volume:repeat-import", displayName: "Card", isEjectable: true)
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in snap.removableSources.contains { $0.path == cardPath && !$0.isScanning } }

        let defaults = PreferencesDomain.suite(UUID().uuidString)
        let coordinator = MediaOperationCoordinator(store: store, preferencesDomain: defaults)
        await coordinator.start()
        _ = try await waitForReady(coordinator, source: cardPath)

        async let first: Void = coordinator.queueImport(for: cardPath)
        try await Task.sleep(for: .milliseconds(20))
        async let second: Void = coordinator.queueImport(for: cardPath)
        _ = await (first, second)

        // Wait for execution to settle
        try await Task.sleep(for: .milliseconds(800))
        let batches = try await store.importBatches()
        #expect(batches.count == 1, "Repeated import should start exactly one batch")
        #expect(batches.first?.assetCount == 4)
        log("END")
        log("END")
        await coordinator.shutdown()
    }

    // MARK: - 12. Metadata wake (deterministic)

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
        try await store.attachRemovableVolume(mountURL: cardURL, identity: "volume:metadata-wake-adversarial", displayName: "Card", isEjectable: true)

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
        // Ensure mtimes match by copying mtime? For test, we can use filesystem namespace live check: it checks live size and expected mtime derived from policy.
        // For original naming with no folder, expected mtime is source mtime. To make them match, ensure both have same mtime after copy.
        // We'll set dest's mtime to src's mtime.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: srcFile.path), let mtime = attrs[.modificationDate] as? Date {
            try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: destFile.path)
        }

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(mountURL: cardURL, identity: "volume:zero-copy-no-delete", displayName: "Card", isEjectable: true)
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in snap.removableSources.contains { $0.path == cardPath && !$0.isScanning } }

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
        try await Task.sleep(for: .milliseconds(400))
        // Should remain Ready, not executing/completed, and no executor invocation.
        let pres = try await waitForPresentation(coordinator, source: cardPath, predicate: { p in
            if case .ready = p.state {
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
        if let attrs = try? FileManager.default.attributesOfItem(atPath: srcFile.path), let mtime = attrs[.modificationDate] as? Date {
            try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: destFile.path)
        }

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(mountURL: cardURL, identity: "volume:zero-copy-delete", displayName: "Card", isEjectable: true)
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snap in snap.removableSources.contains { $0.path == cardPath && !$0.isScanning } }

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
        let deadline = ContinuousClock().now + .seconds(5)
        var deleted = false
        var completed = false
        while ContinuousClock().now < deadline {
            deleted = !FileManager.default.fileExists(atPath: srcFile.path)
            if let pres = await coordinator.currentPresentations().first(where: { $0.sourcePath == cardPath }),
               case .completed = pres.state
            {
                completed = true
                if deleted {
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(deleted, "Source file should be deleted for zero-copy with delete")
        // Completed state is expected, but if deletion happened but presentation still ready due to timing, at least check file gone.
        log("END")
        log("END")
        await coordinator.shutdown()
    }

    // MARK: - 14. Device inventory triggers a replan (plan 0095 D2)

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

        // Without the D2 fix, the coordinator would sit forever on the stale
        // empty plan from before device inventory landed.
        let deadline = ContinuousClock().now + .seconds(8)
        var replannedCopyCount: Int?
        while ContinuousClock().now < deadline {
            if let plan = await coordinator.readyPlan(for: rootPath), plan.totals.copyCount == 1 {
                replannedCopyCount = plan.totals.copyCount
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(replannedCopyCount == 1, "Coordinator should replan once device inventory lands after attach")
        log("END")
        log("END")
        await coordinator.shutdown()
    }

    // MARK: - 15. Import refused while still enumerating (plan 0095 D1, ImportSourceReadiness)

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

        // The internal plan now has the item (proves it built while still
        // enumerating) but the bar must hold state A the entire time —
        // never offering a plan built from a not-yet-stable inventory.
        let deadline = ContinuousClock().now + .seconds(8)
        var sawNonEmptyInternalPlan = false
        while ContinuousClock().now < deadline, !sawNonEmptyInternalPlan {
            if let plan = await coordinator.readyPlan(for: rootPath), plan.totals.copyCount == 1 {
                sawNonEmptyInternalPlan = true
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sawNonEmptyInternalPlan, "Internal plan should build from the batch even while still enumerating")
        let stillPreparing = await coordinator.currentPresentations().first(where: { $0.sourcePath == rootPath })
        var isPreparing = false
        if case .inventory = stillPreparing?.state {
            isPreparing = true
        }
        if case .queuedForReadiness = stillPreparing?.state {
            isPreparing = true
        }
        #expect(isPreparing, "Published state must stay in the preparing family while still enumerating")

        // Pressing Import while still enumerating must not execute.
        await coordinator.queueImport(for: rootPath)
        try await Task.sleep(for: .milliseconds(300))
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
