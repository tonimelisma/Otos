import Foundation
import GRDB
@testable import OtosKit
import Synchronization
import Testing

/// ADR 0005: a background owner of a derived product wakes on a change of a kind its
/// own SQL reads, never on its own writes, and never on a change of anything else. Its inputs
/// are derived from its statements (`CatalogOwnerInputs`), so these tests hold the derivation
/// to the schema and each owner to its wakes, with each change delivered in order through the
/// Store's own notifications (no time waited out).
@Suite(.testScope)
struct CatalogOwnerInputsTests {
    /// One owner: its inputs, the tables only it writes (whose rows no other owner reads),
    /// kinds its inputs must hold, and kinds they must not (its own writes, what it never reads).
    struct Owner: Sendable {
        let name: String
        let inputs: CatalogOwnerInputs
        var ownTables: Set<String> = []
        let wakes: CatalogChangedFacts
        let never: CatalogChangedFacts
    }

    static let owners = [
        Owner(
            name: "renderSignatures", inputs: RenderSignatureRefresher.inputs,
            wakes: [.membership, .images, .kindAndFormat],
            never: [.duplicateFacts, .placeNames, .faces, .detail, .searchContent, .choices, .copies]
        ),
        Owner(
            name: "previewFaces", inputs: PreviewFaceReader.inputs,
            wakes: [.membership, .images, .kindAndFormat],
            never: [.faces, .placeNames, .detail, .searchContent, .duplicateFacts, .copies]
        ),
        Owner(
            name: "placeNames", inputs: PlaceNameReader.inputs,
            wakes: [.location], never: [.placeNames, .images, .detail, .faces, .duplicateFacts, .copies]
        ),
        Owner(
            name: "searchIndex", inputs: PhotoSearchIndex.inputs,
            wakes: [.membership, .images, .grouping, .kindAndFormat],
            never: [.searchContent, .searchReadings, .placeNames, .faces, .detail, .duplicateFacts, .copies]
        ),
        Owner(
            name: "descriptions", inputs: PhotoDescriptionWriter.inputs, ownTables: ["photo_description"],
            wakes: [.membership, .faces, .placeNames, .captureDate, .images, .searchContent, .location],
            never: [.detail, .duplicateFacts, .choices, .copies]
        ),
    ]

    /// The oracle over the schema: every column of every table that an owner's statements
    /// read is one some kind of fact's writes change (`CatalogChangedFacts.writes`), or the
    /// owner's own. A column the table did not name would change with no owner told.
    @Test func everyColumnAnOwnerReadsIsNamedByAKindOfFact() async throws {
        let dbQueue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(dbQueue)
        try await dbQueue.read { db in
            let columns = try Row.fetchAll(db, sql: """
            SELECT m.name AS tableName, p.name AS columnName
            FROM sqlite_master AS m, pragma_table_xinfo(m.name) AS p
            WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%' AND m.name NOT LIKE 'grdb_%'
            """).map { (table: $0["tableName"] as String, column: $0["columnName"] as String) }
            for owner in Self.owners {
                let region = try owner.inputs.statements.reduce(into: DatabaseRegion()) { region, sql in
                    try region.formUnion(db.makeStatement(sql: sql).databaseRegion)
                }
                #expect(!region.isEmpty, "\(owner.name)")
                for (table, column) in columns where !owner.ownTables.contains(table) {
                    let event = DatabaseEventKind.update(tableName: table, columnNames: [column])
                    guard region.isModified(byEventsOfKind: event) else { continue }
                    #expect(Self.isNamed(table: table, column: column), "\(owner.name) reads \(table).\(column), which no kind names")
                }
            }
        }
    }

    private static func isNamed(table: String, column: String) -> Bool {
        CatalogChangedFacts.writes.contains { kind in
            kind.events.contains { written in
                if case let .update(writtenTable, writtenColumns) = written {
                    return writtenTable == table && writtenColumns.contains(column)
                }
                return false
            }
        }
    }

    /// What each owner's SQL reads, as derived: the kinds that move its work, and not its own
    /// writes or what it never reads.
    @Test func eachOwnersInputsAreWhatItsSQLReadsLessItsOwnWrites() async throws {
        let store = makeTestStore(location: .inMemory)
        try await store.start(scansSavedLibraries: false)
        for owner in Self.owners {
            let facts = await owner.inputs.facts(in: store, owner: owner.name)
            #expect(facts.isSuperset(of: owner.wakes), "\(owner.name): \(facts.diagnosticDescription)")
            #expect(facts.isDisjoint(with: owner.never), "\(owner.name): \(facts.diagnosticDescription)")
        }
        await store.shutdown()
    }

    /// Rows only added wake no owner of a derived product; a removed library wakes every one.
    @Test func onlyAChangeOfAnInputTouchesAnOwner() {
        #expect(!CatalogStoreChange.assetsAdded.touches(.all))
        #expect(CatalogStoreChange.changed(.images).touches([.images, .faces]))
        #expect(!CatalogStoreChange.changed(.detail).touches([.images, .faces]))
        #expect(CatalogStoreChange.libraryRemoved(LibraryRootPath(rawValue: "/x/")).touches([.images]))
    }

    // MARK: - Each owner's wakes, delivered through the Store

    /// A change no input names (place names), the owner's own kind of write (a duplicates fact)
    /// and a change it reads (a library added), then a closing duplicates fact. Once the owner has
    /// heard every change a probe heard, it rang for exactly the changes that touch its inputs,
    /// and at least one did.
    @Test func theRenderSignatureRefresherWakesOnlyOnWhatItReads() async throws {
        let (store, library) = try await Self.store()
        let refresher = RenderSignatureRefresher(store: store, thumbnailDirectory: nil)
        await refresher.start()
        let probe = await ChangeProbe(store, heard: { await refresher.changesHeard }, wakes: { await refresher.wakes })
        try await Self.deliverChanges(to: store, library: library)
        try await probe.expectWakes(of: RenderSignatureRefresher.inputs, in: store)
        let inputs = await RenderSignatureRefresher.inputs.facts(in: store, owner: "test")
        #expect(!CatalogStoreChange.changed(.duplicateFacts).touches(inputs), "its own signature writes")
        await refresher.shutdown()
        await store.shutdown()
    }

    @Test func thePreviewFaceReaderWakesOnlyOnWhatItReads() async throws {
        let (store, library) = try await Self.store()
        let reader = PreviewFaceReader(store: store, thumbnailDirectory: nil) { _ in throw CocoaError(.featureUnsupported) }
        await reader.start()
        // The forwarder subscribes in its own task: its first drain says it has.
        try await waitUntil { await reader.drains >= 1 }
        let probe = await ChangeProbe(store, heard: { await reader.changesHeard }, wakes: { await reader.wakes })
        try await Self.deliverChanges(to: store, library: library)
        try await probe.expectWakes(of: PreviewFaceReader.inputs, in: store)
        let inputs = await PreviewFaceReader.inputs.facts(in: store, owner: "test")
        #expect(!CatalogStoreChange.changed([.faces, .detail]).touches(inputs), "its own face writes")
        await reader.shutdown()
        await store.shutdown()
    }

    /// The place name reader's own writes and a change it does not read ring nothing; a change
    /// of the user's locale, which the catalog does not hold, rings it.
    @Test func thePlaceNameReaderWakesOnItsInputsAndTheLocale() async throws {
        let (store, library) = try await Self.store()
        let (localeChanges, localeChanged) = AsyncStream<Void>.makeStream()
        let reader = PlaceNameReader(
            store: store, namer: PlaceNameReader.Namer { _, _ in .none }, localeChanges: { localeChanges }
        )
        await reader.start()
        let probe = await ChangeProbe(store, heard: { await reader.changesHeard }, wakes: { await reader.wakes })
        try await Self.deliverChanges(to: store, library: library)
        try await probe.expectWakes(of: PlaceNameReader.inputs, in: store, expectsAWake: false)
        let inputs = await PlaceNameReader.inputs.facts(in: store, owner: "test")
        #expect(!CatalogStoreChange.changed(.placeNames).touches(inputs), "its own name writes")
        let before = await reader.wakes
        localeChanged.yield()
        try await waitUntil { await reader.wakes > before }
        await reader.shutdown()
        await store.shutdown()
    }

    @Test func theSearchIndexAsksForAPassOnlyOnWhatItReads() async throws {
        let (store, library) = try await Self.store()
        let index = try PhotoSearchIndex(
            store: store, thumbnailDirectory: nil, vectorDirectory: makeTestDirectory().appending(path: "SearchIndex"),
            bundle: Bundle(for: CatalogWindowViewModel.self),
            textReader: .readingNoText()
        )
        await index.start()
        let probe = await ChangeProbe(store, heard: { await index.changesHeard }, wakes: { await Int(index.requested) })
        try await Self.deliverChanges(to: store, library: library)
        try await probe.expectWakes(of: PhotoSearchIndex.inputs, in: store)
        let inputs = await PhotoSearchIndex.inputs.facts(in: store, owner: "test")
        #expect(!CatalogStoreChange.changed([.searchContent, .searchReadings]).touches(inputs), "its own search writes")
        await index.shutdown()
        await store.shutdown()
    }

    /// A description waits for its still's search readings, which the Store now announces
    /// (`.searchContent`), so the writer needs no word from the search index.
    @Test func theDescriptionWriterAsksForAWalkOnlyOnWhatItReads() async throws {
        let (store, library) = try await Self.store()
        let writer = PhotoDescriptionWriter(store: store, thumbnailDirectory: nil) { _, _ in .declined }
        await writer.start()
        // The first request is made once the forwarder holds the change stream.
        try await waitUntil { await writer.requested >= 1 }
        let probe = await ChangeProbe(store, heard: { await writer.changesHeard }, wakes: { await Int(writer.requested) })
        try await Self.deliverChanges(to: store, library: library)
        try await probe.expectWakes(of: PhotoDescriptionWriter.inputs, in: store)
        let inputs = await PhotoDescriptionWriter.inputs.facts(in: store, owner: "test")
        #expect(CatalogStoreChange.changed(.searchContent).touches(inputs))
        await writer.shutdown()
        await store.shutdown()
    }

    /// Place names, a duplicates fact, a library added, and the closing duplicates fact the
    /// probe waits for.
    private static func deliverChanges(to store: CatalogStore, library: URL) async throws {
        try await store.applyPlaceNames([PlaceCell(latitude: 1, longitude: 1): PlaceNames(country: "FI", town: nil)], language: .english)
        await store.setDuplicatesReach(.acrossLibraries)
        try await store.addLibrary(url: library)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        await store.setDuplicatesReach(.withinEachLibrary)
    }

    private static func store() async throws -> (CatalogStore, URL) {
        let library = try makeTestDirectory().appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let store = makeTestStore(location: .inMemory)
        try await store.start(scansSavedLibraries: false)
        return (store, library)
    }
}

/// Every change the Store announces from its making on, in order, to compare an owner's wakes
/// against: what the owner had heard and rung for when the probe began, and the closing
/// duplicates fact `deliverChanges` writes last.
private final class ChangeProbe: Sendable {
    private let heard = HeardChanges()
    private let task: Task<Void, Never>
    private let ownerHeard: @Sendable () async -> Int
    private let ownerWakes: @Sendable () async -> Int
    private let heardBefore: Int
    private let wakesBefore: Int

    init(
        _ store: CatalogStore,
        heard ownerHeard: @escaping @Sendable () async -> Int,
        wakes ownerWakes: @escaping @Sendable () async -> Int
    ) async {
        let changes = await store.changeNotifications()
        let heard = heard
        task = Task {
            for await change in changes {
                heard.changes.withLock { $0.append(change) }
            }
        }
        self.ownerHeard = ownerHeard
        self.ownerWakes = ownerWakes
        heardBefore = await ownerHeard()
        wakesBefore = await ownerWakes()
    }

    deinit {
        task.cancel()
    }

    /// Waits for the closing change, then for the owner to have heard as many changes since the
    /// probe began, and expects it rang for exactly those that touch its inputs.
    func expectWakes(of owner: CatalogOwnerInputs, in store: CatalogStore, expectsAWake: Bool = true) async throws {
        try await waitUntil {
            self.heard.changes.withLock { $0.count { $0 == .changed(.duplicateFacts) } } >= 2
        }
        let changes = heard.changes.withLock { $0 }
        let inputs = await owner.facts(in: store, owner: "test")
        try await waitUntil { await self.ownerHeard() - self.heardBefore >= changes.count }
        let touching = changes.count { $0.touches(inputs) }
        #expect(await ownerWakes() - wakesBefore == touching, "\(changes)")
        #expect(!expectsAWake || touching >= 1, "\(changes)")
    }
}

/// The changes a probe heard, in order.
private final class HeardChanges: Sendable {
    let changes = Mutex<[CatalogStoreChange]>([])
}

private extension PlaceNameLanguage {
    static let english = PlaceNameLanguage(Locale(identifier: "en"))
}
