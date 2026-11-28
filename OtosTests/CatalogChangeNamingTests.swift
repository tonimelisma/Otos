import CoreServices
import Foundation
import GRDB
@testable import OtosKit
import Testing

/// What each Store operation sends (ADR 0005): the kinds of fact its writes changed and the
/// rows where it knows them, the runtime state it reports when it wrote nothing, or nothing.
/// Only a removed library stands for every kind. The change-coverage guard every test's Store
/// carries proves no such change names less than its writes; these pin what each one says.
@Suite(.testScope)
struct CatalogChangeNamingTests {
    /// Every change one Store sends from its subscription on, counted against the Store's own
    /// tally (`CatalogChangeTally`), so the changes an awaited operation sent are known
    /// exactly once it returns.
    private final class SentChanges: Sendable {
        let store: CatalogStore
        private let recorder = AsyncValueRecorder<CatalogStoreChange>()
        private let recording: Task<Void, Never>
        private let base: Int

        private init(store: CatalogStore, stream: AsyncStream<CatalogStoreChange>) {
            self.store = store
            base = store.use().changes.notifications
            let recorder = recorder
            recording = Task {
                for await change in stream {
                    await recorder.append(change)
                }
            }
        }

        static func subscribing(to store: CatalogStore) async -> SentChanges {
            await SentChanges(store: store, stream: store.changeNotifications())
        }

        deinit {
            recording.cancel()
        }

        /// Every change the Store has sent since the subscription.
        func recorded() async -> [CatalogStoreChange] {
            let sentCount = store.use().changes.notifications - base
            return await recorder.waitForValues { $0.count >= sentCount }
        }

        /// The changes the Store sent while `body` ran.
        func sent(by body: () async throws -> Void) async throws -> [CatalogStoreChange] {
            let before = store.use().changes.notifications - base
            try await body()
            let after = store.use().changes.notifications - base
            let all = await recorder.waitForValues { $0.count >= after }
            return Array(all[before ..< after])
        }
    }

    private struct Library {
        let temp: URL
        let root: URL
        let path: LibraryRootPath
        let databaseURL: URL
        let ids: [MediaAssetID]
    }

    /// A library of `names`, scanned until it holds `assets` rows (every name by default).
    private static func makeLibrary(names: [String], assets: Int? = nil) async throws -> (Library, CatalogStore, SentChanges) {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in names {
            try writeCatalogStoreFile(root.appending(path: name), contents: "jpeg \(name)")
        }
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let store = makeTestStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        let sent = await SentChanges.subscribing(to: store)
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) {
            !$0.isScanning && $0.testAssets.count == (assets ?? names.count)
        }
        let ids = scanned.testAssets.map(\.id).sorted { $0.relativePath.rawValue < $1.relativePath.rawValue }
        let path = try CatalogPath.normalizedDirectoryPath(for: root)
        return (Library(temp: temp, root: root, path: path, databaseURL: databaseURL, ids: ids), store, sent)
    }

    private static let ownState = CatalogStoreChange.changed(.membership, rows: .none)

    // Validates: ARC-018
    /// The load names which roots the Store reaches, and no row; the shutdown, which ends every
    /// scan and watch and writes nothing, names the roots' own state.
    @Test func theLoadNamesReachAndTheShutdownTheRootsOwnState() async throws {
        let store = makeTestStore(location: .inMemory)
        let sent = await SentChanges.subscribing(to: store)
        #expect(try await sent.sent { try await store.start(scansSavedLibraries: false) } == [.changed(.membership)])
        #expect(try await sent.sent { await store.shutdown() } == [Self.ownState])
    }

    // Validates: ARC-018
    /// A library or an account added has no rows yet: its add names the roots' own state, and
    /// an empty library's first walk names nothing more.
    @Test func aLibraryOrAccountAddedWithNoRowsNamesNoRow() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Empty", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = makeTestStore(
            location: .inMemory, scanCadence: .milliseconds(10), stagingContainers: StagingContainers(base: temp)
        )
        let sent = await SentChanges.subscribing(to: store)
        try await store.start(scansSavedLibraries: false)
        let added = try await sent.sent {
            try await store.addLibrary(url: root)
            _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.libraries.count == 1 }
        }
        #expect(added.first == Self.ownState)
        #expect(added.allSatisfy { $0 == Self.ownState }, "\(added)")

        let account = try await sent.sent {
            _ = try await store.addImmichAccount(
                server: #require(URL(string: "https://photos.example.test")), userID: "user", displayName: "Photos"
            )
        }
        #expect(account == [Self.ownState])
        await store.shutdown()
    }

    // Validates: ARC-018
    /// A Trash mark and its clear name the presence of the rows they hid or showed, and the
    /// copy-key triggers' copies and choices; a mark that hides nothing sends nothing.
    @Test func aTrashMarkAndItsClearNameThePresenceOfTheirRows() async throws {
        let (library, store, sent) = try await Self.makeLibrary(names: ["a.jpg"])
        let id = library.ids[0]
        let batch = MediaTrashBatchID()
        #expect(try await sent.sent { _ = try await store.markPendingTrash([id], batch: batch) } == [
            .changed(.presence, rows: .rows([id])),
        ])
        #expect(try await sent.sent { _ = try await store.markPendingTrash([id], batch: batch) }.isEmpty)
        #expect(try await sent.sent { _ = try await store.clearPendingTrash([id]) } == [.changed(.presence, rows: .rows([id]))])
        await store.shutdown()
    }

    // Validates: ARC-018
    /// A file the Trash queue moved marks its row with its place in the Trash: its presence.
    @Test func aTrashReportNamesThePresenceOfItsRows() async throws {
        let (library, store, sent) = try await Self.makeLibrary(names: ["a.jpg"])
        let id = library.ids[0]
        let trash = library.temp.appending(path: "Trash", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let batch = MediaTrashBatchID()
        _ = try await store.markPendingTrash([id], batch: batch)
        guard case let .acquired(lease) = await store.acquireNamespaceMutationLease(for: library.path, owner: .mediaTrash) else {
            Issue.record("the root's lease was not free")
            return
        }
        let destination = trash.appending(path: "a.jpg")
        try FileManager.default.moveItem(at: library.root.appending(path: "a.jpg"), to: destination)
        let reported = try await sent.sent {
            await store.reconcileTrashedPaths([MediaTrashPathResult(
                id: id, rootPath: library.path, relativePath: id.relativePath, role: .primary, succeeded: true,
                trashURL: destination
            )], batch: batch, under: lease)
        }
        #expect(reported == [.changed(.presence)])
        #expect(await store.releaseNamespaceMutationLease(lease))
        await store.shutdown()
    }

    // Validates: ARC-018
    /// A rescan that finds a file's size and dates changed names its file's facts — its
    /// presence, the date and kind they stand for, and what is named beside them — and the
    /// row, never every kind: its faces, record, place and search readings stay.
    @Test func aRescannedFileThatChangedNamesItsFileFacts() async throws {
        let (library, store, _) = try await Self.makeLibrary(names: ["a.jpg", "b.jpg"])
        await store.shutdown()
        try writeCatalogStoreFile(library.root.appending(path: "a.jpg"), contents: "a longer jpeg than before")

        let rescanning = makeTestStore(location: .databaseFile(library.databaseURL), scanCadence: .milliseconds(10))
        let sent = await SentChanges.subscribing(to: rescanning)
        let changes = try await sent.sent {
            try await rescanning.start(scansSavedLibraries: true)
            _ = try await waitForCatalogStoreState(rescanning) {
                !$0.isScanning && $0.testAssets.first { $0.id == library.ids[0] }?.byteSize == 25
            }
        }
        #expect(changes.contains(.changed(.fileFacts, rows: .rows([library.ids[0]]))), "\(changes)")
        #expect(!changes.contains { $0.facts == .all }, "\(changes)")
        await rescanning.shutdown()
    }

    // Validates: ARC-018
    /// A removal whose delete fails leaves the library as it was and names the root's own
    /// state; it is rescanned, and its rows did not change.
    @Test func aRemovalThatFailsNamesTheRootsOwnState() async throws {
        let (library, store, sent) = try await Self.makeLibrary(names: ["a.jpg"])
        let blocker = try makeTestDatabaseQueue(path: library.databaseURL.path(percentEncoded: false))
        try await blocker.write { db in
            try db.execute(sql: """
            CREATE TRIGGER test_refuse_root_delete BEFORE DELETE ON library_root
            BEGIN SELECT RAISE(ABORT, 'refused by the test'); END
            """)
        }
        let failed = try await sent.sent {
            await #expect(throws: (any Error).self) { try await store.removeLibrary(path: library.path) }
        }
        #expect(failed.first == Self.ownState, "\(failed)")
        #expect(!failed.contains { $0.facts == .all }, "\(failed)")
        try await blocker.write { db in try db.execute(sql: "DROP TRIGGER test_refuse_root_delete") }
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        await store.shutdown()
    }

    // Validates: ARC-018
    /// A camera attached names its reach, unnamed; one that returns names its retained rows'
    /// presence too, and its detach names the root's own state.
    @Test func aCameraAttachNamesItsReachAndItsDetachItsOwnState() async throws {
        let temp = try makeTestDirectory()
        let stagingRoot = temp.appending(path: "DeviceStaging/Camera", directoryHint: .isDirectory)
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        let sent = await SentChanges.subscribing(to: store)
        try await store.start(scansSavedLibraries: false)
        var rootPath: LibraryRootPath?
        let attached = try await sent.sent {
            rootPath = try await store.attachDeviceMTP(stagingRootURL: stagingRoot, identity: .camera(id: "serial"), displayName: "Camera")
        }
        #expect(attached == [.changed(.membership)])
        let path = try #require(rootPath)
        let listing = try await store.beginSourceListing(rootPath: path)
        let file = ScannedMediaFile(
            relativePath: MediaRelativePath(rawValue: "DCIM/IMG_0001.JPG"), name: "IMG_0001.JPG", contentTypeIdentifier: "public.jpeg",
            byteSize: 42, createdAt: Date(timeIntervalSince1970: 1000), contentModifiedAt: Date(timeIntervalSince1970: 1000)
        )
        try await store.recordSourceListingBatch([file], scan: listing)
        try await store.completeSourceListing(scan: listing, observedPaths: [file.relativePath])

        let detached = try await sent.sent {
            try await store.detachRemovableSource(identity: .camera(id: "serial"), reason: .disconnected)
        }
        #expect(detached.contains(Self.ownState), "\(detached)")
        #expect(!detached.contains { $0.facts == .all }, "\(detached)")

        let returned = try await sent.sent {
            _ = try await store.attachDeviceMTP(stagingRootURL: stagingRoot, identity: .camera(id: "serial"), displayName: "Camera")
        }
        #expect(returned == [.changed(.presence)], "its retained row awaits the new listing")
        await store.shutdown()
    }

    // Validates: ARC-018
    /// A file erased from a camera leaves the catalog: its row's presence, unnamed, since the
    /// Live Photo partner it may leave is not read.
    @Test func anErasedFileNamesThePresenceOfItsRow() async throws {
        let temp = try makeTestDirectory()
        let stagingRoot = temp.appending(path: "DeviceStaging/Camera", directoryHint: .isDirectory)
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        let sent = await SentChanges.subscribing(to: store)
        try await store.start(scansSavedLibraries: false)
        let path = try await store.attachDeviceMTP(stagingRootURL: stagingRoot, identity: .camera(id: "serial"), displayName: "Camera")
        let file = ScannedMediaFile(
            relativePath: MediaRelativePath(rawValue: "DCIM/IMG_0001.JPG"), name: "IMG_0001.JPG", contentTypeIdentifier: "public.jpeg",
            byteSize: 42, createdAt: Date(timeIntervalSince1970: 1000), contentModifiedAt: Date(timeIntervalSince1970: 1000)
        )
        let listing = try await store.beginSourceListing(rootPath: path)
        try await store.recordSourceListingBatch([file], scan: listing)
        try await store.completeSourceListing(scan: listing, observedPaths: [file.relativePath])
        let operation = ActiveSourceEraseOperation(
            key: .make(), sourceKind: .deviceMTP, sourceDeviceIdentity: .camera(id: "serial"), sourceRootPath: path,
            sourceRelativePath: file.relativePath, sourceByteSize: file.byteSize, updatedAt: Date()
        )
        try await store.beginSourceEraseOperation(operation)
        #expect(try await sent.sent { try await store.recordSourceFileErased(operation) } == [.changed(.presence)])
        await store.shutdown()
    }

    // Validates: ARC-018
    /// A file event's reconcile names what it wrote: a file removed, its row's presence.
    @Test func aFileEventsReconcileNamesWhatItWrote() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "removed.jpg")
        try writeCatalogStoreFile(file, contents: "jpeg")
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = makeTestStore(location: .inMemory, filesystemWatcher: watcher, scanCadence: .milliseconds(10))
        let sent = await SentChanges.subscribing(to: store)
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let removed = try await sent.sent {
            try FileManager.default.removeItem(at: file)
            emit(FilesystemEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)))
            _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.isEmpty }
            try await waitUntil { await store.isFilesystemQuiescent }
        }
        #expect(removed.contains(.changed(.presence)), "\(removed)")
        #expect(!removed.contains { $0.facts == .all }, "\(removed)")
        await store.shutdown()
    }

    // Validates: ARC-018
    /// A walk that pairs a companion with its photo names which rows exist (a companion is a
    /// file a row lists with it), never every kind.
    @Test func aWalkThatPairsACompanionNamesMembership() async throws {
        let (_, store, sent) = try await Self.makeLibrary(names: ["a.jpg", "a.xmp"], assets: 1)
        let walked = await sent.recorded()
        #expect(walked.contains(.changed(.membership)), "\(walked)")
        #expect(!walked.contains { $0.facts == .all }, "\(walked)")
        await store.shutdown()
    }

    // Validates: ARC-018
    /// A settled import names what the copy carries: its row, batch and companions, its digest,
    /// choice and edit, and the products it took from its source, naming the copy.
    @Test func aSettledImportNamesWhatTheCopyCarries() async throws {
        let temp = try makeTestDirectory()
        let sourceRoot = temp.appending(path: "Source", directoryHint: .isDirectory)
        let destinationRoot = temp.appending(path: "Destination", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        try writeCatalogStoreFile(sourceRoot.appending(path: "source.jpg"), contents: "jpeg")
        let store = makeTestStore(location: .databaseFile(temp.appending(path: "db/catalog.sqlite")))
        let sent = await SentChanges.subscribing(to: store)
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: sourceRoot)
        try await store.addLibrary(url: destinationRoot)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let sourcePath = try CatalogPath.normalizedDirectoryPath(for: sourceRoot)
        let destinationPath = try CatalogPath.normalizedDirectoryPath(for: destinationRoot)
        let operation = ActiveFileOperation(
            operationKey: .make(), sourceKind: .library, sourceDeviceIdentity: nil, sourceRootPath: sourcePath,
            sourceRelativePath: MediaRelativePath(rawValue: "source.jpg"), destinationRootPath: destinationPath,
            destinationRelativePath: MediaRelativePath(rawValue: "imported.jpg"), stagingURL: nil, companionStagingURLs: [],
            contentHash: nil, importBatch: ImportBatchID(unixMilliseconds: 1), sourceByteSize: 4,
            sourceModifiedAt: Date(timeIntervalSince1970: 1_700_000_000), destinationModifiedAt: Date(timeIntervalSince1970: 1_700_000_001),
            phase: .publishedPendingSettlement, updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        try await store.beginImportOperation(operation)
        let settled = try await sent.sent {
            _ = try await store.backgroundReads.settleImportedAsset(
                operation: operation, byteSize: 4, contentModifiedAt: Date(timeIntervalSince1970: 1_700_000_001), companions: []
            )
        }
        let copy = MediaAssetID(libraryRootPath: destinationPath, relativePath: MediaRelativePath(rawValue: "imported.jpg"))
        #expect(settled == [.changed(.settledImport, rows: .rows([copy]))])
        await store.shutdown()
    }

    // Validates: ARC-018
    /// A Trash move undone puts the file back at its path: the reconcile names the row's file
    /// facts, never every kind.
    @Test func aTrashMoveUndoneNamesTheFileFactsOfItsRow() async throws {
        let (library, store, sent) = try await Self.makeLibrary(names: ["a.jpg"])
        let id = library.ids[0]
        let item = try #require(try await store.windowReads.mediaTrashItems(for: [id]).first)
        let trash = library.temp.appending(path: "Trash", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let batch = MediaTrashBatchID()
        _ = try await store.markPendingTrash([id], batch: batch)
        guard case let .acquired(lease) = await store.acquireNamespaceMutationLease(for: library.path, owner: .mediaTrash) else {
            Issue.record("the root's lease was not free")
            return
        }
        let file = library.root.appending(path: "a.jpg"), destination = trash.appending(path: "a.jpg")
        try FileManager.default.moveItem(at: file, to: destination)
        await store.reconcileTrashedPaths([MediaTrashPathResult(
            id: id, rootPath: library.path, relativePath: id.relativePath, role: .primary, succeeded: true, trashURL: destination
        )], batch: batch, under: lease)
        #expect(await store.releaseNamespaceMutationLease(lease))

        try FileManager.default.moveItem(at: destination, to: file)
        var back = false
        let restored = try await sent.sent {
            back = await store.windowReads.restoreTrashedItem(TrashedItem(
                item: item, members: item.members.map { TrashedMember(member: $0, trashURL: nil) }
            ))
        }
        #expect(back)
        #expect(restored == [.changed(.fileFacts)], "\(restored)")
        await store.shutdown()
    }

    // Validates: ARC-018
    /// The duplicates act names the moved copy's presence and the work it carried onto the
    /// kept copy, naming both; its undo names only the work it took back.
    @Test func aDuplicatesMoveAndItsUndoNameTheCarriedWork() async throws {
        let (library, store, sent) = try await Self.makeLibrary(names: ["a.jpg", "b.jpg"])
        let (moved, kept) = (library.ids[0], library.ids[1])
        var recipe = EditRecipe.neutral
        recipe.exposure = 0.5
        _ = try await store.setMediaChoice(.liked, for: [moved])
        _ = try await store.setEditRecipe(recipe, for: moved)
        let carried = CatalogChangedFacts.choices.union(.edit).union(.duplicateFacts)

        let batch = MediaTrashBatchID()
        let marked = try await sent.sent {
            _ = try await store.markPendingTrash([moved], batch: batch, carrying: [
                DuplicateCarry(from: moved, to: kept, work: .choice), DuplicateCarry(from: moved, to: kept, work: .edit),
            ])
        }
        #expect(marked == [.changed(CatalogChangedFacts.presence.union(carried), rows: .rows([moved, kept]))])
        _ = try await store.clearPendingTrash([moved])
        let reverted = try await sent.sent { try await store.revertCarriedWork(batch: batch, restored: [moved]) }
        #expect(reverted == [.changed(carried, rows: .rows([kept]))])
        await store.shutdown()
    }

    // Validates: ARC-018
    /// The duplicates act's carried work names what it wrote onto the kept copy: a choice is
    /// the user's choices, an edit an edit of a photo Duplicates holds.
    @Test func carriedWorkNamesWhatItWrote() {
        let from = MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/L"), relativePath: MediaRelativePath(rawValue: "a.jpg"))
        let to = MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/L"), relativePath: MediaRelativePath(rawValue: "b.jpg"))
        var choice = CarriedWorkWrite()
        choice.record(DuplicateCarryRecord(from: from, to: to, previous: .choice(.notRated)))
        #expect(choice.facts == .choices)
        #expect(choice.rows == [to])
        var edit = CarriedWorkWrite()
        edit.record(DuplicateCarryRecord(from: from, to: to, previous: .edit(nil)))
        #expect(edit.facts == CatalogChangedFacts.edit.union(.duplicateFacts))
    }
}
