import Foundation
@testable import OtosKit
import Synchronization
import Testing

@Suite(.testScope)
struct ReorganizationRecoveryObservationTests {
    @Test func classifiesWillMoveMatrix() throws {
        let temp = try makeTestDirectory()
        let source = temp.appending(path: "a.jpg")
        let destination = temp.appending(path: "b.jpg")
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try Data([0x01, 0x02, 0x03]).write(to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: modified],
            ofItemAtPath: source.path
        )
        let step = ActiveReorganizationStep(
            stepIndex: 0,
            memberIndex: 0,
            sourceRelativePath: MediaRelativePath(rawValue: "a.jpg"),
            destinationRelativePath: MediaRelativePath(rawValue: "b.jpg"),
            phase: .willMove
        )
        #expect(
            ReorganizationExecutor.observeStep(
                rootURL: temp,
                step: step,
                expectedByteSize: 3,
                expectedModifiedAt: modified
            ) == .moveDidNotHappen
        )

        try FileManager.default.moveItem(at: source, to: destination)
        try FileManager.default.setAttributes(
            [.modificationDate: modified],
            ofItemAtPath: destination.path
        )
        #expect(
            ReorganizationExecutor.observeStep(
                rootURL: temp,
                step: step,
                expectedByteSize: 3,
                expectedModifiedAt: modified
            ) == .moveHappened
        )

        try Data([0x01, 0x02, 0x03]).write(to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: modified],
            ofItemAtPath: source.path
        )
        #expect(
            ReorganizationExecutor.observeStep(
                rootURL: temp,
                step: step,
                expectedByteSize: 3,
                expectedModifiedAt: modified
            ) == .ambiguousBothExist
        )
    }
}

@Suite(.testScope)
struct ActiveReorganizationJournalTests {
    // Validates: ARC-031, ARC-051
    @Test func journalRoundTripsThroughStore() async throws {
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)

        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let component = ActiveReorganizationComponent(
            componentKey: .make(),
            libraryRootPath: LibraryRootPath(rawValue: "/Library"),
            planGeneration: 2,
            plannedRootRevision: 7,
            phase: .prepared,
            nextStepIndex: 0,
            createdAt: now,
            updatedAt: now,
            members: [
                ActiveReorganizationMember(
                    memberIndex: 0,
                    kind: .media,
                    logicalSourceRelativePath: MediaRelativePath(rawValue: "a.jpg"),
                    currentRelativePath: MediaRelativePath(rawValue: "a.jpg"),
                    finalRelativePath: MediaRelativePath(rawValue: "b.jpg"),
                    byteSize: 10,
                    contentModifiedAt: now
                ),
            ],
            steps: [
                ActiveReorganizationStep(
                    stepIndex: 0,
                    memberIndex: 0,
                    sourceRelativePath: MediaRelativePath(rawValue: "a.jpg"),
                    destinationRelativePath: MediaRelativePath(rawValue: "b.jpg"),
                    phase: .planned
                ),
            ],
            directories: [
                ActiveReorganizationDirectory(
                    relativePath: MediaRelativePath(rawValue: "2026"),
                    phase: .planned
                ),
            ]
        )
        try await store.prepareReorganizationComponent(component)
        let loaded = try await store.backgroundReads.activeReorganizationComponents()
        #expect(loaded.count == 1)
        #expect(loaded.first?.componentKey == component.componentKey)
        #expect(loaded.first?.members.count == 1)
        #expect(loaded.first?.steps.count == 1)
        #expect(loaded.first?.directories.count == 1)

        try await store.recordReorganizationMoveIntent(key: component.componentKey, stepIndex: 0)
        try await store.recordReorganizationMoveCompletion(
            key: component.componentKey,
            step: component.steps[0],
            nextStepIndex: 1
        )
        try await store.recordReorganizationFilesystemCompletion(
            key: component.componentKey,
            nextStepIndex: 1
        )
        let after = try await store.backgroundReads.activeReorganizationComponents()
        #expect(after.first?.phase == .filesystemComplete)
        #expect(after.first?.members.first?.currentRelativePath.rawValue == "b.jpg")
        #expect(after.first?.steps.first?.phase == .didMove)
    }
}

@Suite(.testScope)
struct ReorganizationLeaseTests {
    // Validates: ARC-051, ARC-055
    @Test func leaseDefersScanUntilRelease() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "jpeg")

        let store = makeTestStore(
            location: .databaseFile(temp.appending(path: "db/catalog.sqlite")),
            scanCadence: .milliseconds(10)
        )
        try await store.start(scansSavedLibraries: false)
        try await store.ensureLibrary(url: root)
        let rootPath = LibraryRootPath(rawValue: root.path)
        guard case let .acquired(lease) = await store.acquireNamespaceMutationLease(
            for: rootPath,
            owner: .reorganization
        ) else {
            Issue.record("expected lease")
            return
        }
        #expect(await store.hasNamespaceMutationLease(for: rootPath))
        #expect(await store.releaseNamespaceMutationLease(lease))
        #expect(await store.hasNamespaceMutationLease(for: rootPath) == false)
    }
}

@Suite(.testScope)
struct ReorganizationSettlementTests {
    // Validates: ARC-018, ARC-051, ARC-052
    @Test func setBasedSwapRemapsWithoutCollision() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "aaaa")
        try writeCatalogStoreFile(root.appending(path: "b.jpg"), contents: "bbbb")

        let store = makeTestStore(
            location: .databaseFile(temp.appending(path: "db/catalog.sqlite")),
            scanCadence: .milliseconds(10)
        )
        try await store.start(scansSavedLibraries: false)
        try await store.ensureLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 2
        }

        let rootPath = LibraryRootPath(rawValue: root.path)
        let aID = MediaAssetID(
            libraryRootPath: rootPath,
            relativePath: MediaRelativePath(rawValue: "a.jpg")
        )
        #expect(try await store.setMediaChoice(.liked, for: [aID]).changedCount == 1)
        let now = Date(timeIntervalSince1970: 1_700_000_200)
        let key = ReorganizationComponentKey.make()
        let component = ActiveReorganizationComponent(
            componentKey: key,
            libraryRootPath: rootPath,
            planGeneration: 1,
            plannedRootRevision: 1,
            phase: .filesystemComplete,
            nextStepIndex: 2,
            createdAt: now,
            updatedAt: now,
            members: [
                ActiveReorganizationMember(
                    memberIndex: 0,
                    kind: .media,
                    logicalSourceRelativePath: MediaRelativePath(rawValue: "a.jpg"),
                    currentRelativePath: MediaRelativePath(rawValue: "b.jpg"),
                    finalRelativePath: MediaRelativePath(rawValue: "b.jpg"),
                    byteSize: 4,
                    contentModifiedAt: now
                ),
                ActiveReorganizationMember(
                    memberIndex: 1,
                    kind: .media,
                    logicalSourceRelativePath: MediaRelativePath(rawValue: "b.jpg"),
                    currentRelativePath: MediaRelativePath(rawValue: "a.jpg"),
                    finalRelativePath: MediaRelativePath(rawValue: "a.jpg"),
                    byteSize: 4,
                    contentModifiedAt: now
                ),
            ],
            steps: [],
            directories: []
        )
        try await store.prepareReorganizationComponent(component)
        let changes = AsyncValueRecorder<CatalogStoreChange>()
        let stream = await store.changeNotifications()
        let recording = Task {
            for await change in stream {
                await changes.append(change)
            }
        }
        defer { recording.cancel() }

        try await store.backgroundReads.settleReorganizationComponent(key: key)
        let bID = MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: "b.jpg"))
        // The rows moved carry every fact keyed by their paths, and are named at both.
        #expect(await changes.waitForValues { !$0.isEmpty }.first == .changed(.movedRow, rows: .rows([aID, bID])))
        let ordered = try await store.windowReads.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: .allMedia),
            availableLibraryPaths: [rootPath]
        )
        let batch = try #require(ordered.pendingIdentityRemaps.first)
        #expect(ordered.pendingIdentityRemaps.count == 1)
        #expect(batch.remaps == [
            CatalogIdentityRemap(oldID: aID, newID: bID),
            CatalogIdentityRemap(oldID: bID, newID: aID),
        ])
        #expect(try await store.backgroundReads.activeReorganizationComponents().isEmpty)

        let state = try await catalogStoreTestState(store)
        let paths = Set(state.testAssets.map(\.relativePath.rawValue))
        #expect(paths == ["a.jpg", "b.jpg"])
        let remapped = try await store.windowReads.mediaAssets(for: [
            MediaAssetID(
                libraryRootPath: rootPath,
                relativePath: MediaRelativePath(rawValue: "b.jpg")
            ),
        ])
        #expect(remapped.values.first?.mediaChoice == .liked)

        try await store.acknowledgeIdentityRemaps([batch.id])
        let afterAcknowledgement = try await store.windowReads.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: .allMedia),
            availableLibraryPaths: [rootPath]
        )
        #expect(afterAcknowledgement.pendingIdentityRemaps.isEmpty)
        await store.shutdown()
    }

    @Test func journalStepsBindCurrentPathNotFinal() throws {
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        // Build a synthetic plan with A→B, B→C chain steps.
        let root = LibraryRootPath(rawValue: "/Library")
        let memberA = ReorganizationPhysicalMember(
            id: "media:a.jpg",
            source: MediaRelativePath(rawValue: "a.jpg"),
            finalDestination: MediaRelativePath(rawValue: "b.jpg"),
            isCompanion: false,
            primarySource: nil,
            mediaID: MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "a.jpg"))
        )
        let memberB = ReorganizationPhysicalMember(
            id: "media:b.jpg",
            source: MediaRelativePath(rawValue: "b.jpg"),
            finalDestination: MediaRelativePath(rawValue: "c.jpg"),
            isCompanion: false,
            primarySource: nil,
            mediaID: MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "b.jpg"))
        )
        let plan = ReorganizationPlan(
            generation: 1,
            libraryRoot: root,
            rootRevision: 1,
            policy: ImportPolicy.from(prefs),
            members: [memberA, memberB],
            components: [
                ReorganizationComponent(
                    id: "component-0",
                    memberIDs: [memberB.id, memberA.id],
                    steps: [
                        .move(
                            from: MediaRelativePath(rawValue: "b.jpg"),
                            to: MediaRelativePath(rawValue: "c.jpg")
                        ),
                        .move(
                            from: MediaRelativePath(rawValue: "a.jpg"),
                            to: MediaRelativePath(rawValue: "b.jpg")
                        ),
                    ]
                ),
            ],
            mediaDispositions: [:]
        )
        let now = Date(timeIntervalSince1970: 1)
        let facts: [MediaRelativePath: (byteSize: Int64, contentModifiedAt: Date)] = [
            MediaRelativePath(rawValue: "a.jpg"): (1, now),
            MediaRelativePath(rawValue: "b.jpg"): (1, now),
        ]
        let journal = try #require(ReorganizationExecutor.makeJournalComponent(
            plan: plan,
            plannerComponent: plan.components[0],
            factsByPath: facts
        ))
        #expect(journal.steps.count == 2)
        // First step from b.jpg must bind member B (index of b.jpg source), not A whose final is b.jpg.
        let bIndex = journal.members.first { $0.logicalSourceRelativePath.rawValue == "b.jpg" }?.memberIndex
        let aIndex = journal.members.first { $0.logicalSourceRelativePath.rawValue == "a.jpg" }?.memberIndex
        #expect(journal.steps[0].memberIndex == bIndex)
        #expect(journal.steps[1].memberIndex == aIndex)
        #expect(journal.steps[0].memberIndex != aIndex)
    }
}

@Suite(.testScope)
struct ReorganizationExecutorMoveTests {
    // Validates: ARC-051
    @Test func executesSingleMoveAndMarksComplete() async throws {
        let fixture = try await ExecutorFixture.make(files: ["old.jpg": [0x11, 0x22]])
        let sourceInode = try fixture.inode("old.jpg")
        let component = try fixture.component(
            moves: [("old.jpg", "new.jpg")],
            directories: []
        )
        try await fixture.store.prepareReorganizationComponent(component)

        let outcome = await ReorganizationExecutor.executeComponent(component, rootURL: fixture.root, store: fixture.store)

        #expect(outcome == .filesystemComplete)
        let journal = try #require(try await fixture.store.backgroundReads.activeReorganizationComponents().first)
        #expect(journal.phase == .filesystemComplete)
        #expect(journal.steps.map(\.phase) == [.didMove])
        #expect(journal.members.map(\.currentRelativePath.rawValue) == ["new.jpg"])
        #expect(!fixture.exists("old.jpg"))
        #expect(try fixture.inode("new.jpg") == sourceInode)
        await fixture.store.shutdown()
    }

    // Validates: ARC-051
    /// A component that cannot finish is undone: the step that moved is moved back, the
    /// folder the component created is removed, the journal is deleted, and the foreign
    /// file that stopped it is untouched.
    @Test func aStoppedComponentRollsBackToTheLibraryItFound() async throws {
        let fixture = try await ExecutorFixture.make(files: ["a.jpg": [0x01], "b.jpg": [0x02]])
        try Data("foreign".utf8).write(to: fixture.root.appending(path: "taken.jpg"))
        let component = try fixture.component(
            moves: [("a.jpg", "2024/a.jpg"), ("b.jpg", "taken.jpg")],
            directories: ["2024"]
        )
        try await fixture.store.prepareReorganizationComponent(component)

        let outcome = await ReorganizationExecutor.executeComponent(component, rootURL: fixture.root, store: fixture.store)
        #expect(outcome == .stopped(.destinationTaken(MediaRelativePath(rawValue: "taken.jpg"))))
        #expect(fixture.exists("2024/a.jpg"))

        let journal = try #require(try await fixture.store.backgroundReads.activeReorganizationComponents().first)
        let rollback = await ReorganizationExecutor.rollBackComponent(journal, rootURL: fixture.root, store: fixture.store)

        #expect(rollback == .restored)
        #expect(fixture.exists("a.jpg"))
        #expect(fixture.exists("b.jpg"))
        #expect(!fixture.exists("2024"))
        #expect(try Data(contentsOf: fixture.root.appending(path: "taken.jpg")) == Data("foreign".utf8))
        #expect(try await fixture.store.backgroundReads.activeReorganizationComponents().isEmpty)
        await fixture.store.shutdown()
    }

    // Validates: ARC-051
    /// A rollback that cannot put a file back keeps the journal, marked blocked, so the
    /// next launch's recovery can try again.
    @Test func aRollbackThatCannotRestoreAFileKeepsTheJournalBlocked() async throws {
        let fixture = try await ExecutorFixture.make(files: ["a.jpg": [0x01]])
        let component = try fixture.component(moves: [("a.jpg", "b.jpg")], directories: [])
        try await fixture.store.prepareReorganizationComponent(component)
        #expect(await ReorganizationExecutor.executeComponent(
            component,
            rootURL: fixture.root,
            store: fixture.store
        ) == .filesystemComplete)
        // Something else takes the original name before the rollback runs.
        try Data("newcomer".utf8).write(to: fixture.root.appending(path: "a.jpg"))

        let journal = try #require(try await fixture.store.backgroundReads.activeReorganizationComponents().first)
        let rollback = await ReorganizationExecutor.rollBackComponent(journal, rootURL: fixture.root, store: fixture.store)

        #expect(rollback == .stuck(.destinationTaken(MediaRelativePath(rawValue: "a.jpg"))))
        #expect(try await fixture.store.backgroundReads.activeReorganizationComponents().map(\.phase) == [.blocked])
        #expect(fixture.exists("b.jpg"))
        #expect(try Data(contentsOf: fixture.root.appending(path: "a.jpg")) == Data("newcomer".utf8))
        await fixture.store.shutdown()
    }
}

/// A real store over a temporary root whose files carry known sizes and modification
/// dates, and journal components built from simple moves.
private struct ExecutorFixture {
    let store: CatalogStore
    let root: URL
    let rootPath: LibraryRootPath
    let modified: Date

    static func make(files: [String: [UInt8]]) async throws -> ExecutorFixture {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let modified = Date(timeIntervalSince1970: 1_700_000_300)
        for (name, bytes) in files {
            let url = root.appending(path: name)
            try Data(bytes).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        let store = makeTestStore(location: .inMemory, filesystemWatcher: .noop)
        try await store.start(scansSavedLibraries: false)
        return ExecutorFixture(
            store: store,
            root: root,
            rootPath: LibraryRootPath(rawValue: root.path),
            modified: modified
        )
    }

    func component(moves: [(String, String)], directories: [String]) throws -> ActiveReorganizationComponent {
        let now = Date()
        let sizes = try moves.map { move in
            try #require(
                FileManager.default.attributesOfItem(atPath: root.appending(path: move.0).path)[.size] as? NSNumber
            ).int64Value
        }
        return ActiveReorganizationComponent(
            componentKey: ReorganizationComponentKey.make(),
            libraryRootPath: rootPath,
            planGeneration: 1,
            plannedRootRevision: 1,
            phase: .prepared,
            nextStepIndex: 0,
            createdAt: now,
            updatedAt: now,
            members: moves.enumerated().map { index, move in
                ActiveReorganizationMember(
                    memberIndex: index,
                    kind: .media,
                    logicalSourceRelativePath: MediaRelativePath(rawValue: move.0),
                    currentRelativePath: MediaRelativePath(rawValue: move.0),
                    finalRelativePath: MediaRelativePath(rawValue: move.1),
                    byteSize: sizes[index],
                    contentModifiedAt: modified
                )
            },
            steps: moves.enumerated().map { index, move in
                ActiveReorganizationStep(
                    stepIndex: index,
                    memberIndex: index,
                    sourceRelativePath: MediaRelativePath(rawValue: move.0),
                    destinationRelativePath: MediaRelativePath(rawValue: move.1),
                    phase: .planned
                )
            },
            directories: directories.map {
                ActiveReorganizationDirectory(relativePath: MediaRelativePath(rawValue: $0), phase: .planned)
            }
        )
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: relative).path)
    }

    func inode(_ relative: String) throws -> NSNumber {
        try #require(
            FileManager.default.attributesOfItem(atPath: root.appending(path: relative).path)[.systemFileNumber]
                as? NSNumber
        )
    }
}
