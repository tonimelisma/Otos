import Foundation
@testable import OtosKit
import Testing

/// End-to-end reorganization runs over a real catalog and a real library folder.
@Suite(.testDirectory)
struct LibraryReorganizationRunnerTests {
    /// A run that stops partway keeps every component that settled before the failure,
    /// rolls the failing one back, and leaves the settled remaps for the window to apply
    /// through the catalog — the same path a complete run takes.
    @Test func aRunThatStopsPartwayKeepsWhatSettledAndRestoresTheRest() async throws {
        let fixture = try await RunnerFixture.make(files: [
            ("a.jpg", Self.date(2023, 3, 15)),
            ("b.jpg", Self.date(2024, 5, 20)),
        ])
        // "2024" exists but cannot take a new folder, so b's component cannot create
        // "2024/05"; planning sees an existing folder and plans through it.
        let blocked = fixture.root.appending(path: "2024", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path) }

        let preview = await fixture.runner.preview(libraryRoot: fixture.rootPath)
        guard case let .needsConfirmation(summary) = preview else {
            Issue.record("Expected a plan to confirm, got \(preview)")
            return
        }
        #expect(summary.relocateCount == 2)

        let outcome = await fixture.runner.run(libraryRoot: fixture.rootPath, confirmedRevision: summary.rootRevision)

        #expect(outcome == .stopped(ReorganizationStop(
            fault: .folderUnavailable(MediaRelativePath(rawValue: "2024/05")),
            progress: ReorganizationStop.Progress(settledComponentCount: 1, componentCount: 2, relocatedCount: 1),
            libraryRestored: true
        )))
        #expect(fixture.exists("2023/03/a.jpg"))
        #expect(!fixture.exists("a.jpg"))
        #expect(fixture.exists("b.jpg"))
        #expect(try await fixture.store.activeReorganizationComponents().isEmpty)
        let ordered = try await fixture.orderedAssets()
        #expect(Set(ordered.ids.map(\.relativePath.rawValue)) == ["2023/03/a.jpg", "b.jpg"])
        #expect(ordered.pendingIdentityRemaps.flatMap(\.remaps) == [
            CatalogIdentityRemap(oldID: fixture.id("a.jpg"), newID: fixture.id("2023/03/a.jpg")),
        ])
        // The lease was released: the library accepts the next owner.
        guard case let .acquired(lease) = await fixture.store.acquireNamespaceMutationLease(
            for: fixture.rootPath,
            owner: .reorganization
        ) else {
            Issue.record("The library was left under a lease")
            return
        }
        _ = await fixture.store.releaseNamespaceMutationLease(lease)
        await fixture.store.shutdown()
    }

    /// Confirming runs the plan the user saw. When the library is no longer at the
    /// confirmed revision, the run moves nothing and reports the plan as it is now.
    @Test func aRunAgainstAnotherRevisionAsksAgainAndMovesNothing() async throws {
        let fixture = try await RunnerFixture.make(files: [("a.jpg", Self.date(2023, 3, 15))])
        guard case let .needsConfirmation(summary) = await fixture.runner.preview(libraryRoot: fixture.rootPath) else {
            Issue.record("Expected a plan to confirm")
            return
        }

        let outcome = await fixture.runner.run(
            libraryRoot: fixture.rootPath,
            confirmedRevision: summary.rootRevision &+ 1
        )

        #expect(outcome == .needsConfirmation(summary: summary))
        #expect(fixture.exists("a.jpg"))
        #expect(!fixture.exists("2023"))
        await fixture.store.shutdown()
    }

    /// A component journaled as moving when the process ended resumes at the next
    /// launch: the move that happened is recorded, the rest runs, and the catalog
    /// settles — the library is neither frozen nor left half-moved.
    @Test func recoveryResumesAComponentThatWasMovingWhenTheProcessEnded() async throws {
        let fixture = try await RunnerFixture.make(files: [
            ("a.jpg", Self.date(2023, 3, 15)),
            ("b.jpg", Self.date(2023, 3, 16)),
        ])
        let plan = try await fixture.readyPlan()
        let facts = try await fixture.memberFacts()
        let plannerComponent = try #require(plan.components.first)
        let component = try #require(ReorganizationExecutor.makeJournalComponent(
            plan: plan,
            plannerComponent: plannerComponent,
            factsByPath: facts
        ))
        try await fixture.store.prepareReorganizationComponent(component)
        // The process moved the first file and ended before journaling the move.
        let first = try #require(component.steps.first)
        try await fixture.store.recordReorganizationMoveIntent(key: component.componentKey, stepIndex: first.stepIndex)
        let parent = fixture.root.appending(path: first.destinationRelativePath.rawValue).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: fixture.root.appending(path: first.sourceRelativePath.rawValue),
            to: fixture.root.appending(path: first.destinationRelativePath.rawValue)
        )

        try await LibraryReorganizationRunner.recoverJournal(store: fixture.store)

        #expect(try await fixture.store.activeReorganizationComponents().isEmpty)
        let finals = Set(component.members.map(\.finalRelativePath.rawValue))
        for final in finals {
            #expect(fixture.exists(final))
        }
        let ordered = try await fixture.orderedAssets()
        #expect(Set(ordered.ids.map(\.relativePath.rawValue)).isSuperset(of: finals))
        #expect(await fixture.store.hasNamespaceMutationLease(for: fixture.rootPath) == false)
        await fixture.store.shutdown()
    }

    /// A component the last process left journaled holds its root from the moment the
    /// next process loads its catalog, before anyone runs recovery: a half-moved library is
    /// never scanned, reconciled or imported into first. Recovery adopts that hold,
    /// finishes the component and releases the root.
    @Test func aJournaledRootIsHeldFromLoadUntilItsRecoveryFinishesIt() async throws {
        let fixture = try await RunnerFixture.make(files: [
            ("a.jpg", Self.date(2023, 3, 15)),
            ("b.jpg", Self.date(2023, 3, 16)),
        ])
        let plan = try await fixture.readyPlan()
        let facts = try await fixture.memberFacts()
        let plannerComponent = try #require(plan.components.first)
        let component = try #require(ReorganizationExecutor.makeJournalComponent(
            plan: plan,
            plannerComponent: plannerComponent,
            factsByPath: facts
        ))
        try await fixture.store.prepareReorganizationComponent(component)
        await fixture.store.shutdown()

        let relaunched = CatalogStore(
            location: .databaseFile(fixture.root.deletingLastPathComponent().appending(path: "db/catalog.sqlite")),
            filesystemWatcher: .noop
        )
        try await relaunched.start()
        #expect(await relaunched.hasNamespaceMutationLease(for: fixture.rootPath))

        try await LibraryReorganizationRunner.recoverJournal(store: relaunched)

        #expect(try await relaunched.activeReorganizationComponents().isEmpty)
        #expect(await relaunched.hasNamespaceMutationLease(for: fixture.rootPath) == false)
        await relaunched.shutdown()
    }

    /// A reorganized photo's name key follows it to its new path (ARC-056): a new file that
    /// later appears at the path it left is a new photo, and what the user said about the
    /// moved one stays on it.
    @Test func aNewFileAtAReorganizedPhotosOldPathIsANewPhoto() async throws {
        let fixture = try await RunnerFixture.make(files: [("a.jpg", Self.date(2023, 3, 15))])
        _ = try await fixture.store.setMediaChoice(.liked, for: [fixture.id("a.jpg")])
        guard case let .needsConfirmation(summary) = await fixture.runner.preview(libraryRoot: fixture.rootPath) else {
            Issue.record("Expected a plan to confirm")
            return
        }
        let outcome = await fixture.runner.run(libraryRoot: fixture.rootPath, confirmedRevision: summary.rootRevision)
        #expect(outcome == .completed(relocatedCount: 1))
        try Data("another a.jpg".utf8).write(to: fixture.root.appending(path: "a.jpg"))
        await fixture.store.shutdown()

        let relaunched = CatalogStore(
            location: .databaseFile(fixture.root.deletingLastPathComponent().appending(path: "db/catalog.sqlite")),
            filesystemWatcher: .noop
        )
        try await relaunched.start()
        let moved = fixture.id("2023/03/a.jpg"), new = fixture.id("a.jpg")
        // The relaunch's scan has listed the new file; a regression shows in what follows,
        // not as a wait that never ends.
        _ = try await waitForCatalogStoreState(relaunched) { state in
            !state.isScanning && state.testAssets.contains { $0.id == new }
        }

        let assets = try await relaunched.mediaAssets(for: [moved, new])
        #expect(assets[moved]?.mediaChoice == .liked)
        #expect(assets[new]?.mediaChoice == .notRated)
        await relaunched.shutdown()
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return try #require(Calendar.current.date(from: components))
    }
}

/// A scanned library with a year/month folder policy and original names.
private struct RunnerFixture {
    let store: CatalogStore
    let runner: LibraryReorganizationRunner
    let root: URL
    let rootPath: LibraryRootPath

    static func make(files: [(String, Date)]) async throws -> RunnerFixture {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, modified) in files {
            let url = root.appending(path: name)
            try Data(name.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        let store = CatalogStore(location: .databaseFile(temp.appending(path: "db/catalog.sqlite")), filesystemWatcher: .noop)
        try await store.start(scansSavedLibraries: false)
        try await store.ensureLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == files.count }

        let domain = PreferencesDomain.suite(UUID().uuidString)
        var preferences = ImportPreferences.default
        preferences.destinationFolderPolicy = .yearMonth
        preferences.destinationNamePolicy = .original
        ImportPreferencesStore.save(preferences, defaults: domain.makeDefaults())
        return try RunnerFixture(
            store: store,
            runner: LibraryReorganizationRunner(store: store, preferencesDomain: domain),
            root: root,
            rootPath: CatalogPath.normalizedDirectoryPath(for: root)
        )
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: relative).path)
    }

    func id(_ relative: String) -> MediaAssetID {
        MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: relative))
    }

    func orderedAssets() async throws -> CatalogOrderedAssets {
        try await store.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: .allMedia),
            availableLibraryPaths: [rootPath]
        )
    }

    func readyPlan() async throws -> ReorganizationPlan {
        let media = try #require(await store.planningMedia(for: rootPath))
        let revision = try #require(await store.planRevision(for: rootPath))
        var preferences = ImportPreferences.default
        preferences.destinationFolderPolicy = .yearMonth
        preferences.destinationNamePolicy = .original
        let capabilities = FilesystemNamespaceSemantics.probeVolumeCapabilities(rootURL: root)
        let snapshot = ReorganizationPlanningSnapshot(
            libraryRoot: rootPath,
            capabilities: capabilities,
            generation: 1,
            rootRevision: revision,
            policy: ImportPolicy.from(preferences),
            calendar: .current,
            timeZone: .current,
            media: media
        )
        let namespace = FilesystemNamespaceSemantics.enumerateNamespace(
            root: rootPath,
            folders: ReorganizationPlanner.destinationFolders(for: snapshot),
            capabilities: capabilities
        )
        switch ReorganizationPlanner.plan(snapshot: snapshot, namespace: namespace) {
        case let .ready(plan):
            return plan
        case let .inconsistent(reason):
            throw RunnerFixtureError.planInconsistent(reason)
        }
    }

    func memberFacts() async throws -> [MediaRelativePath: (byteSize: Int64, contentModifiedAt: Date)] {
        let media = try #require(await store.planningMedia(for: rootPath))
        var facts: [MediaRelativePath: (byteSize: Int64, contentModifiedAt: Date)] = [:]
        for item in media {
            facts[item.relativePath] = try (#require(item.byteSize), #require(item.contentModifiedAt))
        }
        return facts
    }
}

private enum RunnerFixtureError: Error {
    case planInconsistent(String)
}
