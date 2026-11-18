import Foundation
import GRDB
@testable import OtosKit
import SQLite3
import Synchronization
import Testing

/// What a listing batch costs the Store's writer, counted, never timed: the statements each
/// listed item runs, and the text of each. A cached statement is found by its SQL text, a
/// Swift string hashed whole at every execution; a character outside ASCII in it — a `§` in
/// an SQL comment — sends that hash through Unicode normalization, about ten times the cost.
/// The 2026-11-18 daily run flagged `immich.listing.batch500.of20k` at +13.5 % for one such
/// comment in the scan upsert, run for every item a listing or scan writes.
@Suite(.testScope)
struct CatalogSQLTextTests {
    /// The top-level statements a connection started, by text (`SQLITE_TRACE_STMT`; a
    /// trigger's own statements arrive as `-- TRIGGER` lines and are counted apart).
    private final class StatementTexts: Sendable {
        private let started = Mutex<[String]>([])

        func take() -> [String] {
            started.withLock { started in
                defer { started = [] }
                return started
            }
        }

        /// Installs on the Store's writer, reached as `StatementVisits` reaches it: the Store
        /// exposes no connection, and this count adds nothing to the product.
        func install(on store: CatalogStore) async throws {
            let writer = try #require(Mirror(reflecting: store).children.first { $0.label == "dbWriter" }?.value as? CatalogWriter)
            let pool = try #require(Mirror(reflecting: writer).children.first { $0.label == "pool" }?.value as? DatabasePool)
            try await pool.writeWithoutTransaction { db in
                sqlite3_trace_v2(db.sqliteConnection, UInt32(SQLITE_TRACE_STMT), { _, context, _, sql in
                    guard let context, let sql else { return 0 }
                    let text = String(cString: sql.assumingMemoryBound(to: CChar.self))
                    Unmanaged<StatementTexts>.fromOpaque(context).takeUnretainedValue().started.withLock { $0.append(text) }
                    return 0
                }, Unmanaged.passUnretained(self).toOpaque())
            }
        }
    }

    private static func items(_ range: Range<Int>) -> [SourceListedItem] {
        range.map { index in
            let folder = String(format: "asset-%06d", index)
            return SourceListedItem(
                file: ScannedMediaFile(
                    relativePath: MediaRelativePath(rawValue: "\(folder)/IMG_\(index).JPG"),
                    name: "IMG_\(index).JPG",
                    contentTypeIdentifier: "public.jpeg",
                    byteSize: 1000,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    contentModifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
                ),
                sourceItemID: folder,
                isHiddenBySource: false,
                sourceHasProducts: true
            )
        }
    }

    /// An account's listing of 100 new assets, then the same 100 listed again unchanged, as
    /// a resync lists them: every statement the writer runs for either is ASCII text, and the
    /// unchanged batch runs six statements an item — its two lookups, the put-back check, the
    /// upsert and the two source-fact writes, each of which writes nothing — and no trigger.
    @Test func aListingBatchsStatementsAreASCIIAndSixAnUnchangedItem() async throws {
        let temp = try makeTestDirectory()
        let store = makeTestStore(
            location: .databaseFile(temp.appending(path: "Catalog.sqlite")),
            stagingContainers: StagingContainers(base: temp)
        )
        try await store.start(scansSavedLibraries: false)
        let rootPath = try await store.addImmichAccount(
            server: #require(URL(string: "https://photos.example.com")), userID: "u1", displayName: "Family"
        )
        let texts = StatementTexts()
        try await texts.install(on: store)
        let listed = Self.items(0 ..< 100)
        let changes = SourceListingChanges(listed: listed, completeFolders: listed.map(\.sourceItemID))
        let scan = try await store.beginSourceListing(rootPath: rootPath)
        try await store.applySourceListingChanges(changes, scan: scan)
        let first = texts.take()
        try await store.applySourceListingChanges(changes, scan: scan)
        let again = texts.take()
        await store.endSourceListing(scan: scan)
        await store.shutdown()

        #expect(!first.isEmpty && !again.isEmpty)
        for text in Set(first + again) where !text.utf8.allSatisfy({ $0 < 0x80 }) {
            Issue.record("a statement outside ASCII: \(text.prefix(200))")
        }
        let triggers = again.filter { $0.hasPrefix("--") }
        #expect(triggers.isEmpty, "an unchanged item fires no trigger: \(Set(triggers))")
        let perItem = again.filter { !$0.hasPrefix("--") && !$0.hasPrefix("BEGIN") && !$0.hasPrefix("COMMIT") && !$0.hasPrefix("PRAGMA") }
        #expect(perItem.count <= 6 * listed.count, "\(perItem.count) statements for \(listed.count) unchanged items")
    }
}
