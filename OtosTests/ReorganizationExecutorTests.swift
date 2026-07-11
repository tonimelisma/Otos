import Foundation
@testable import Otos
import Testing

struct ReorganizationRecoveryObservationTests {
    @Test func classifiesWillMoveMatrix() throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
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

struct ActiveReorganizationJournalTests {
    @Test func journalRoundTripsThroughStore() async throws {
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
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
        try await store.insertActiveReorganizationComponent(component)
        let loaded = try await store.fetchActiveReorganizationComponents()
        #expect(loaded.count == 1)
        #expect(loaded.first?.componentKey == component.componentKey)
        #expect(loaded.first?.members.count == 1)
        #expect(loaded.first?.steps.count == 1)
        #expect(loaded.first?.directories.count == 1)

        try await store.markReorganizationStepWillMove(key: component.componentKey, stepIndex: 0)
        try await store.markReorganizationStepDidMove(
            key: component.componentKey,
            step: component.steps[0],
            nextStepIndex: 1
        )
        try await store.markReorganizationFilesystemComplete(
            key: component.componentKey,
            nextStepIndex: 1
        )
        let after = try await store.fetchActiveReorganizationComponents()
        #expect(after.first?.phase == .filesystemComplete)
        #expect(after.first?.members.first?.currentRelativePath.rawValue == "b.jpg")
        #expect(after.first?.steps.first?.phase == .didMove)
    }
}

struct ReorganizationLeaseTests {
    @Test func leaseDefersScanUntilRelease() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "jpeg")

        let store = CatalogStore(
            location: .databaseFile(temp.appending(path: "db/catalog.sqlite")),
            scanCadence: .milliseconds(10)
        )
        try await store.start(scansSavedLibraries: false)
        try await store.ensureLibrary(url: root)
        let rootPath = LibraryRootPath(rawValue: root.path)
        guard let lease = await store.acquireReorganizationLease(for: rootPath) else {
            Issue.record("expected lease")
            return
        }
        #expect(await store.hasReorganizationLease(for: rootPath))
        #expect(await store.releaseReorganizationLease(lease))
        #expect(await store.hasReorganizationLease(for: rootPath) == false)
    }
}

struct ReorganizationSettlementTests {
    @Test func setBasedSwapRemapsWithoutCollision() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "aaaa")
        try writeCatalogStoreFile(root.appending(path: "b.jpg"), contents: "bbbb")

        let store = CatalogStore(
            location: .databaseFile(temp.appending(path: "db/catalog.sqlite")),
            scanCadence: .milliseconds(10)
        )
        try await store.start(scansSavedLibraries: false)
        try await store.ensureLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 2
        }

        let rootPath = LibraryRootPath(rawValue: root.path)
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
        try await store.insertActiveReorganizationComponent(component)

        let remaps = [
            CatalogIdentityRemap(
                oldID: MediaAssetID(
                    libraryRootPath: rootPath,
                    relativePath: MediaRelativePath(rawValue: "a.jpg")
                ),
                newID: MediaAssetID(
                    libraryRootPath: rootPath,
                    relativePath: MediaRelativePath(rawValue: "b.jpg")
                )
            ),
            CatalogIdentityRemap(
                oldID: MediaAssetID(
                    libraryRootPath: rootPath,
                    relativePath: MediaRelativePath(rawValue: "b.jpg")
                ),
                newID: MediaAssetID(
                    libraryRootPath: rootPath,
                    relativePath: MediaRelativePath(rawValue: "a.jpg")
                )
            ),
        ]
        let batch = try await store.settleRelocationComponent(key: key, remaps: remaps)
        #expect(batch.remaps.count == 2)
        #expect(try await store.fetchActiveReorganizationComponents().isEmpty)

        let state = try await catalogStoreTestState(store)
        let paths = Set(state.testAssets.map(\.relativePath.rawValue))
        #expect(paths == ["a.jpg", "b.jpg"])
    }
}

struct ReorganizationExecutorMoveTests {
    @Test func executesSingleMoveAndMarksComplete() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let source = temp.appending(path: "old.jpg")
        let modified = Date(timeIntervalSince1970: 1_700_000_300)
        try Data([0x11, 0x22]).write(to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: modified],
            ofItemAtPath: source.path
        )

        let now = Date()
        let key = ReorganizationComponentKey.make()
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var willMove = 0
            private var didMove = 0
            private var complete = 0

            func bumpWillMove() {
                lock.lock()
                defer { lock.unlock() }
                willMove += 1
            }

            func bumpDidMove() {
                lock.lock()
                defer { lock.unlock() }
                didMove += 1
            }

            func bumpComplete() {
                lock.lock()
                defer { lock.unlock() }
                complete += 1
            }

            var counts: (Int, Int, Int) {
                lock.lock()
                defer { lock.unlock() }
                return (willMove, didMove, complete)
            }
        }
        let counter = Counter()
        let component = ActiveReorganizationComponent(
            componentKey: key,
            libraryRootPath: LibraryRootPath(rawValue: temp.path),
            planGeneration: 1,
            plannedRootRevision: 1,
            phase: .prepared,
            nextStepIndex: 0,
            createdAt: now,
            updatedAt: now,
            members: [
                ActiveReorganizationMember(
                    memberIndex: 0,
                    kind: .media,
                    logicalSourceRelativePath: MediaRelativePath(rawValue: "old.jpg"),
                    currentRelativePath: MediaRelativePath(rawValue: "old.jpg"),
                    finalRelativePath: MediaRelativePath(rawValue: "new.jpg"),
                    byteSize: 2,
                    contentModifiedAt: modified
                ),
            ],
            steps: [
                ActiveReorganizationStep(
                    stepIndex: 0,
                    memberIndex: 0,
                    sourceRelativePath: MediaRelativePath(rawValue: "old.jpg"),
                    destinationRelativePath: MediaRelativePath(rawValue: "new.jpg"),
                    phase: .planned
                ),
            ],
            directories: []
        )

        let outcome = await ReorganizationExecutor.executeComponent(
            component: component,
            rootURL: temp,
            markWillMove: { _ in counter.bumpWillMove() },
            markDidMove: { _, _ in counter.bumpDidMove() },
            markFilesystemComplete: { counter.bumpComplete() },
            ensureDirectory: { _ in .preexisting },
            shouldContinue: { true }
        )
        #expect(outcome == .filesystemComplete(key))
        let counts = counter.counts
        #expect(counts.0 == 1)
        #expect(counts.1 == 1)
        #expect(counts.2 == 1)
        #expect(FileManager.default.fileExists(atPath: temp.appending(path: "new.jpg").path))
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }
}
