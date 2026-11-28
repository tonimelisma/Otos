import Foundation
@testable import OtosKit
import Testing

/// ADR 0022: an item whose file the queue moved to the system Trash keeps its row — hidden,
/// with the file's place in the Trash — until the Trash no longer holds the file. Finder's
/// Put Back, even after a relaunch, shows the row again with its choice and edit; emptying
/// the Trash lets the next scan purge it; and the trash bar's Cancel withdraws what has not
/// moved yet from a queue that has no undo entry left.
@Suite("Trash put back", .testScope)
struct CatalogStoreTrashPutBackTests {
    private struct Library {
        let temp: URL
        let root: URL
        let trash: URL
        let databaseURL: URL
        let ids: [MediaAssetID]
    }

    private static func makeLibrary(names: [String]) async throws -> (Library, CatalogStore) {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let trash = temp.appending(path: "Trash", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        for name in names {
            try writeCatalogStoreFile(root.appending(path: name), contents: "jpeg \(name)")
        }
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let store = makeTestStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) {
            !$0.isScanning && $0.testAssets.count == names.count
        }
        let ids = scanned.testAssets.map(\.id).sorted { $0.relativePath.rawValue < $1.relativePath.rawValue }
        return (Library(temp: temp, root: root, trash: trash, databaseURL: databaseURL, ids: ids), store)
    }

    /// Moves each item's file into the test's Trash folder and reports it to the Store the
    /// way the queue does after `trashItem`: under the root's namespace lease, so no scan and
    /// no reconcile of the root runs between the moves and the report.
    private static func moveToTrash(
        _ ids: [MediaAssetID],
        in library: Library,
        store: CatalogStore,
        batch: MediaTrashBatchID
    ) async throws {
        let rootPath = try #require(ids.first?.libraryRootPath)
        let lease = try await acquireLease(rootPath, store: store)
        var results: [MediaTrashPathResult] = []
        for id in ids {
            let source = library.root.appending(path: id.relativePath.rawValue)
            let destination = library.trash.appending(path: id.relativePath.rawValue)
            try FileManager.default.moveItem(at: source, to: destination)
            results.append(MediaTrashPathResult(
                id: id,
                rootPath: id.libraryRootPath,
                relativePath: id.relativePath,
                role: .primary,
                succeeded: true,
                trashURL: destination
            ))
        }
        await store.reconcileTrashedPaths(results, batch: batch, under: lease)
        #expect(await store.releaseNamespaceMutationLease(lease))
    }

    private static func acquireLease(_ rootPath: LibraryRootPath, store: CatalogStore) async throws -> RootNamespaceMutationLease {
        guard case let .acquired(lease) = await store.acquireNamespaceMutationLease(for: rootPath, owner: .mediaTrash) else {
            throw LeaseUnavailable()
        }
        return lease
    }

    private struct LeaseUnavailable: Error {}

    /// A report from an owner that no longer holds the root marks nothing: only the lease that
    /// covered the moves keeps the root's own reconcile from purging a moved row before the
    /// row names the Trash.
    @Test func aTrashReportWithoutTheRootsLeaseMarksNothing() async throws {
        let (library, store) = try await Self.makeLibrary(names: ["a.jpg"])
        let id = library.ids[0]
        _ = try await store.markPendingTrash([id], batch: MediaTrashBatchID())
        let released = try await Self.acquireLease(id.libraryRootPath, store: store)
        #expect(await store.releaseNamespaceMutationLease(released))

        await store.reconcileTrashedPaths([MediaTrashPathResult(
            id: id,
            rootPath: id.libraryRootPath,
            relativePath: id.relativePath,
            role: .primary,
            succeeded: true,
            trashURL: library.trash.appending(path: "a.jpg")
        )], batch: MediaTrashBatchID(), under: released)

        #expect(try await store.windowReads.pendingTrashItems().map(\.item.id) == [id])
        await store.shutdown()
    }

    // Validates: ARC-033
    @Test func putBackAfterARelaunchShowsTheItemWithItsChoiceAndEdit() async throws {
        let (library, store) = try await Self.makeLibrary(names: ["a.jpg", "b.jpg", "c.jpg"])
        let (putBack, emptied, stillInTrash) = (library.ids[0], library.ids[1], library.ids[2])
        _ = try await store.setMediaChoice(.liked, for: [putBack])
        _ = try await store.setEditRecipe(EditRecipe(shadows: 40), for: putBack)
        let batch = MediaTrashBatchID()
        _ = try await store.markPendingTrash(library.ids, batch: batch)
        try await Self.moveToTrash(library.ids, in: library, store: store, batch: batch)

        // Moved items are no longer waiting, and nothing of them shows, but their rows stay.
        #expect(try await store.windowReads.pendingTrashItems().isEmpty)
        #expect(try await store.windowReads.mediaAssets(for: library.ids).count == 3)
        await store.shutdown()

        // Between runs: Finder puts one back, and the Trash loses another.
        try FileManager.default.moveItem(
            at: library.trash.appending(path: "a.jpg"),
            to: library.root.appending(path: "a.jpg")
        )
        try FileManager.default.removeItem(at: library.trash.appending(path: "b.jpg"))

        let relaunched = makeTestStore(location: .databaseFile(library.databaseURL), scanCadence: .milliseconds(10))
        try await relaunched.start(scansSavedLibraries: true)
        let settled = try await waitForCatalogStoreState(relaunched) {
            !$0.isScanning && $0.testAssets.count == 1
        }
        #expect(settled.testAssets.map(\.id) == [putBack])
        #expect(try await relaunched.windowReads.mediaAssets(for: [putBack])[putBack]?.mediaChoice == .liked)
        #expect(
            try await relaunched.windowReads.editRecipe(for: putBack)
                == StoredEditRecipe(recipe: EditRecipe(shadows: 40), revision: 1)
        )
        // The Trash no longer holds the emptied one: proven deleted, purged.
        #expect(try await relaunched.windowReads.mediaAssets(for: [emptied]).isEmpty)
        // Still in the Trash: kept, hidden, and not offered to the queue again.
        #expect(try await relaunched.windowReads.mediaAssets(for: [stillInTrash]).keys.contains(stillInTrash))
        #expect(try await relaunched.windowReads.pendingTrashItems().isEmpty)
        await relaunched.shutdown()
    }

    @Test func clearingAPendingMarkNeverShowsAnItemWhoseFileIsInTheTrash() async throws {
        let (library, store) = try await Self.makeLibrary(names: ["a.jpg"])
        let id = library.ids[0]
        let batch = MediaTrashBatchID()
        _ = try await store.markPendingTrash([id], batch: batch)
        try await Self.moveToTrash([id], in: library, store: store, batch: batch)

        let shown = try await store.clearPendingTrash([id])

        #expect(shown.isEmpty)
        let snapshot = try await waitForCatalogStoreState(store) { !$0.isScanning }
        #expect(snapshot.testAssets.isEmpty)
        await store.shutdown()
    }

    @Test func cancelWithdrawsWhatAnEarlierRunLeftWaiting() async throws {
        let (library, store) = try await Self.makeLibrary(names: ["a.jpg", "b.jpg"])
        _ = try await store.markPendingTrash(library.ids, batch: MediaTrashBatchID())
        let coordinator = MediaTrashCoordinator(
            store: store,
            materializationRequester: nil,
            files: .refusing,
            volumeCapacity: ampleVolumeCapacity
        )

        let withdrawn = await coordinator.withdrawAllPending()

        #expect(Set(withdrawn) == Set(library.ids))
        #expect(try await store.windowReads.pendingTrashItems().isEmpty)
        let snapshot = try await waitForCatalogStoreState(store) { $0.testAssets.count == 2 }
        #expect(Set(snapshot.testAssets.map(\.id)) == Set(library.ids))
        await coordinator.shutdown()
        await store.shutdown()
    }
}
