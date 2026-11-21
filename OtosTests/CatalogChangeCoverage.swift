import GRDB
@testable import OtosKit
import Synchronization
import Testing

/// Change-coverage guard
///
/// Every test's Store carries one (`makeTestStore`, `TestScope`). It proves the one way a
/// narrowed change notification can fail: a background owner stops hearing a write it reads,
/// and its work stays owed with nothing logged (ADR 0005, plan 0117 step 3). It watches the
/// Store's writer from the writer's side, a GRDB `TransactionObserver` on the pool the Store
/// opens (`CatalogWriteAudit.writerOpened`), and hears every change the Store sends
/// (`CatalogWriteAudit.changeSent`).
///
/// **What a commit owes.** Each committed transaction owes the kinds of fact its events map
/// to through the Store's own table of which columns each kind stands for
/// (`CatalogChangedFacts.writes`): an inserted or deleted row its table's insert or delete
/// kinds, an updated row the kinds of every column its statement updated. Three writes owe
/// nothing of their own, because the write they belong to owes it:
/// - a column written into a row the same transaction inserted is part of that insert: a new
///   row is announced as its insert (`CatalogRowChanges`);
/// - a row inserted and deleted again in the same transaction was never written;
/// - a row a foreign key's `ON DELETE CASCADE` deletes with its parent is part of the
///   parent's delete (a deleted asset's metadata, search rows and faces; a deleted person's
///   summary), read from the schema as the writer opens.
/// The narrowings (`Narrowing`) take out what the Store decides by comparing values, or keeps
/// as one owner's own state, and nothing else does.
///
/// **The pairing rule.** A change the Store sends pays, on every commit that committed before
/// it was sent, the kinds it names (`.libraryRemoved` and `.all` name every kind,
/// `.assetsAdded` names membership). A commit is covered when every kind it owes has been
/// paid. A change sent after a commit is exactly what a keyed re-read needs: an owner that
/// hears the kind re-reads after the commit and sees the write. So a change sent at the end of
/// the same Store operation pays, and so does one a later operation of the same Store sends
/// (a source listing's `endSourceListing`, a removable attachment's
/// `finishRemovableRootAttachment`). A change sent before the commit pays nothing for it.
///
/// **When a commit must be covered.** By the end of the test case: the scope shuts the
/// test's Stores down, waits for the work each shutdown overtook to end — the Store's own tasks
/// it cancelled, and every write in flight with what its operation sends after it — and then
/// reports every commit still owed (`uncoveredOnceWorkEnds`), naming the
/// operation that wrote it (`CatalogWriter.write`'s `operation`), the columns and tables it
/// wrote, and the kinds no change named. Shutdown's own change follows no write and pays
/// nothing (`CatalogWriteAudit.shutDown`). A commit that lands after shutdown began, or in a
/// write still in flight when it began, is a write the shutdown overtook: its operation sends
/// its change only if it goes on (a scan batch that finds its lease gone does not), so it is
/// never reported. A change sent after shutdown began, by an operation still finishing, still
/// pays.
///
/// **Which statement wrote a column.** GRDB asks each observer, just before a statement runs,
/// whether it observes each kind of event the statement can make (its authorizer's), and
/// reports an update event by table and row only. The guard credits an update event with
/// the columns its statement's update kinds name for that table, which include the columns
/// the statement's triggers update: the copy-key and render-signature narrowings are the
/// triggers that matters for. A second observer, added after the first, is asked about every
/// statement after it, so its ask ends the statement (`StatementEnd`). A statement SQLite runs
/// inside another (FTS5's own tables) is asked about too, so a cascade is recognised by its
/// parent's delete earlier in the transaction, never by the statement's kinds.
///
/// **What it does not see.** A `WITHOUT ROWID` table gives SQLite's update hook nothing, so
/// its rows' events never arrive: of the tables `writes` names, `immich_mirror_pair`. A write
/// to it fires the copy-key triggers, whose own events the guard sees, and the statement's
/// kinds say it ran.
final class CatalogChangeCoverage: TransactionObserver, Sendable {
    /// What a Store decides by comparing values, or keeps as one owner's own state, and so
    /// names less than its columns map to. The only narrowings the guard allows: each says
    /// which writes it applies to and why. A new one is a decision recorded here with its
    /// reason.
    enum Narrowing: CaseIterable {
        /// An enrichment batch and a metadata refresh read the generated `best_*` columns,
        /// the grouping identifiers and the location before and after each row's write
        /// (`EnrichmentOverlayBeforeWrite.changedFacts(to:)`) and name a date, kind, grouping or
        /// location only when one moved: most batches write those columns and move none. A
        /// video's reading writes its face frames whatever it found, and names its images when
        /// they were read or the frames moved.
        case enrichmentOverlayComparison
        /// A digest write reads where each row stood before and after it (`DigestStanding`,
        /// ADR 0054) and names a row's own digest (detail), its copies and its choices only when
        /// they moved. The copy-key triggers (`media_asset_copy_*`, `immich_mirror_pair_*`)
        /// rewrite a row's copy key, shown copy, `has_copies` and its copies' choices whenever a
        /// row is inserted or deleted or a copy-key input is written, whatever the values; a
        /// write that fires them names copies when a row joined or left copies and choices when
        /// a copy took a choice (`CatalogSchema.choiceJoins`).
        case digestStanding
        /// `media_asset_render_signature_stale` clears a still's render signature in every write
        /// that changes what its thumbnail is; the Store names Duplicates' facts only for a
        /// photo Duplicates holds (`DuplicatesHoldSQL`).
        case renderSignatureTrigger
        /// A search write reads whether each row was left out of On This Day before and after
        /// it, and names the labels On This Day reads (`searchReadings`) only when that moved
        /// (`applySearchEmbeddings`).
        case onThisDayLabelComparison
        /// One owner's own state, which it reads only itself and never waits to hear of:
        /// `enrichment_claimed`, the claim owner's (`EnrichmentClaimGateway`); and a source's
        /// `last_synced_at`, which `ImmichAccounts` writes, reads once as it starts and holds
        /// after.
        case ownersOwnState

        /// The kinds this narrowing takes out of what `write` owes in `transaction`.
        func waived(_ write: Write, in transaction: Transaction) -> CatalogChangedFacts {
            switch self {
            case .enrichmentOverlayComparison:
                if !transaction.isBy(Self.overlayComparingOperations) {
                    []
                } else if write == .column("media_asset", "face_frames_path") {
                    [.captureDate, .kindAndFormat, .grouping, .location, .images]
                } else {
                    [.captureDate, .kindAndFormat, .grouping, .location]
                }
            case .digestStanding:
                if Self.digestColumns.contains(write) {
                    [.detail, .copies, .choices]
                } else if transaction.firesCopyKeyTriggers, Self.copyKeyTriggerWrites.contains(write) {
                    [.copies, .choices]
                } else {
                    []
                }
            case .renderSignatureTrigger:
                transaction.firesRenderSignatureTrigger && Self.renderSignatureWrites.contains(write) ? .duplicateFacts : []
            case .onThisDayLabelComparison:
                transaction.isBy(["applySearchEmbeddings"]) && write == .column("search_embedding", "confident_labels")
                    ? .searchReadings : []
            case .ownersOwnState:
                Self.ownersOwnColumns.contains(write) ? .all : []
            }
        }

        /// The operations whose writes compare the overlay (`CatalogWriter.write`'s
        /// `operation`, without its labels).
        static let overlayComparingOperations: Set<String> = ["writeEnrichmentBatch", "applyMetadataRefresh"]
        /// A row's digest and the file facts it was read at.
        static let digestColumns: Set<Write> = [
            .column("media_asset", "content_sha1"), .column("media_asset", "content_hash_source_size"),
            .column("media_asset", "content_hash_source_mtime"),
        ]
        /// What fires the copy-key triggers on `media_asset` (`CatalogSchema`'s v79 inputs).
        static let copyKeyInputs: Set<String> = [
            "content_sha1", "content_hash_source_size", "content_hash_source_mtime", "byte_size",
            "content_modified_at_unix", "pending_trash_batch_unix_ms", "awaiting_presence", "hidden_by_source",
            "library_root_id", "relative_path",
        ]
        /// What the copy-key triggers write.
        static let copyKeyTriggerWrites: Set<Write> = [
            .column("media_asset", "copy_key"), .column("media_asset", "has_copies"),
            .column("media_asset", "shown_copy_root_id"), .column("media_asset", "media_choice"),
            .column("media_asset", "media_choice_sequence"), .column("choice_sequence", "value"),
            .column("choice_sequence", "joins"),
        ]
        /// What fires `media_asset_render_signature_stale`.
        static let renderSignatureInputs: Set<String> = [
            "thumbnail_path", "rendered_revision", "rendered_source_size", "rendered_source_mtime",
            "source_products_size", "source_products_mtime",
        ]
        /// What it writes.
        static let renderSignatureWrites: Set<Write> = [
            .column("media_asset", "render_dhash"), .column("media_asset", "render_signature_read"),
            .delete("render_signature"),
        ]
        static let ownersOwnColumns: Set<Write> = [
            .column("media_asset", "enrichment_claimed"), .column("library_root", "last_synced_at"),
        ]
    }

    /// One thing a transaction wrote, as the writes table names it.
    enum Write: Hashable, Comparable, CustomStringConvertible {
        case insert(String)
        case delete(String)
        case column(String, String)

        var description: String {
            switch self {
            case let .insert(table): "insert \(table)"
            case let .delete(table): "delete \(table)"
            case let .column(table, column): "\(table).\(column)"
            }
        }
    }

    /// What one transaction wrote, as it commits.
    struct Transaction {
        var operation = "unnamed"
        var writes: Set<Write> = []
        /// A statement of the transaction inserted into or deleted from `immich_mirror_pair`,
        /// whose rows make no events (`WITHOUT ROWID`).
        var wroteMirrorPairs = false

        func isBy(_ operations: Set<String>) -> Bool {
            operations.contains(CatalogConnectionActivity.shortName(operation))
        }

        var firesCopyKeyTriggers: Bool {
            wroteMirrorPairs || writes.contains { write in
                switch write {
                case let .insert(table), let .delete(table): table == "media_asset"
                case let .column(table, column): table == "media_asset" && Narrowing.copyKeyInputs.contains(column)
                }
            }
        }

        var firesRenderSignatureTrigger: Bool {
            writes.contains { write in
                if case let .column("media_asset", column) = write {
                    return Narrowing.renderSignatureInputs.contains(column)
                }
                return false
            }
        }
    }

    /// A commit some kind of which no change has named yet.
    struct UncoveredWrite: CustomStringConvertible {
        let operation: String
        /// Each write and the kinds it owes.
        let owing: [(write: Write, facts: CatalogChangedFacts)]
        /// The kinds no change sent after the commit named.
        let missing: CatalogChangedFacts

        var description: String {
            let wrote = owing.map { "\($0.write)→\($0.facts.diagnosticDescription)" }.joined(separator: " ")
            return "a write no change announced: operation=\(operation) missing=\(missing.diagnosticDescription) wrote=\(wrote) "
                + "(CatalogChangeCoverage, ADR 0005)"
        }
    }

    fileprivate struct Debt {
        let operation: String
        let call: UInt64?
        /// Committed in a write the shutdown overtook: owed only until the guard reports, and
        /// then not reported.
        var overtaken = false
        let owing: [(write: Write, facts: CatalogChangedFacts)]
        var unpaid: CatalogChangedFacts
    }

    /// The state both observers touch, on the writer's queue, and the Store's actor and the
    /// test read.
    fileprivate final class Shared: Sendable {
        let state = Mutex(State())
    }

    fileprivate struct State {
        /// The operation of the write running on the writer (`CatalogWriteAudit.writeBegins`):
        /// a write without a transaction of its own may commit several.
        var operation = "unnamed"
        var transaction = Transaction()
        /// The rows, by table, the open transaction inserted and has not deleted again.
        var insertedRows: [String: Set<Int64>] = [:]
        /// The tables the open transaction deleted rows of, cascades included.
        var deletedTables: Set<String> = []
        /// The kinds of the statement now running: its own, its triggers' and its foreign
        /// keys' actions.
        var statementKinds: [DatabaseEventKind] = []
        /// The second observer was asked about the last statement: the next ask is a new one.
        var statementEnded = true
        var debts: [Debt] = []
        var shutDown = false
        /// For each table, the tables whose deletes cascade into it, directly or through
        /// another table.
        var cascadeAncestors: [String: Set<String>] = [:]
        /// The Store's own tasks its shutdown cancelled.
        var cancelled: [Task<Void, Never>] = []
        /// Awaited writes asked for that have not returned to the Store yet, and who waits for
        /// there to be none.
        var callsInFlight: Set<UInt64> = []
        var nextCall: UInt64 = 0
        /// The write call running on the writer, which the transactions that follow belong to.
        var call: UInt64?
        var idleWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let shared = Shared()
    private let statementEnd: StatementEnd
    /// Changes the guard does not hear, as if the Store had not sent them: the self-test's.
    private let dropping: @Sendable (CatalogStoreChange) -> Bool
    /// The kinds each table's inserts and deletes, and each column's updates, stand for.
    private static let insertFacts = factsByTable {
        if case let .insert(table) = $0 {
            [table]
        } else {
            []
        }
    }

    private static let deleteFacts = factsByTable {
        if case let .delete(table) = $0 {
            [table]
        } else {
            []
        }
    }

    private static let columnFacts: [String: CatalogChangedFacts] = CatalogChangedFacts.writes.reduce(into: [:]) { result, kind in
        for event in kind.events {
            if case let .update(table, columns) = event {
                for column in columns {
                    result["\(table.lowercased()).\(column.lowercased())", default: []].formUnion(kind.facts)
                }
            }
        }
    }

    private static func factsByTable(_ tables: (DatabaseEventKind) -> [String]) -> [String: CatalogChangedFacts] {
        CatalogChangedFacts.writes.reduce(into: [:]) { result, kind in
            for event in kind.events {
                for table in tables(event) {
                    result[table.lowercased(), default: []].formUnion(kind.facts)
                }
            }
        }
    }

    init(dropping: @escaping @Sendable (CatalogStoreChange) -> Bool = { _ in false }) {
        self.dropping = dropping
        statementEnd = StatementEnd(shared: shared)
    }

    /// The Store's seam into this guard.
    var audit: CatalogWriteAudit {
        CatalogWriteAudit(
            writerOpened: { [self] pool in opened(pool) },
            writeBegins: { [self] operation, call in
                shared.state.withLock { state in
                    state.operation = operation
                    state.call = call
                }
            },
            writeCalled: { [self] in
                shared.state.withLock { state in
                    state.nextCall &+= 1
                    state.callsInFlight.insert(state.nextCall)
                    return state.nextCall
                }
            },
            writeReturned: { [self] call in
                let idle = shared.state.withLock { state in
                    state.callsInFlight.remove(call)
                    guard state.callsInFlight.isEmpty else { return [CheckedContinuation<Void, Never>]() }
                    defer { state.idleWaiters.removeAll() }
                    return state.idleWaiters
                }
                idle.forEach { $0.resume() }
            },
            changeSent: { [self] change in heard(change) },
            shutDown: { [self] cancelling in
                shared.state.withLock { state in
                    state.shutDown = true
                    // A write in flight now has committed or will: the shutdown holds the actor
                    // its operation resumes on, so what it would send after the write, it sends
                    // only if it goes on, and a write the Store abandons owes nothing.
                    for index in state.debts.indices where state.debts[index].call.map(state.callsInFlight.contains) == true {
                        state.debts[index].overtaken = true
                    }
                    state.cancelled += cancelling
                }
            }
        )
    }

    /// Every commit still owed once the work the shutdown overtook has ended, removed from the
    /// guard: the Store's own tasks it cancelled (a filesystem pass, a scan, the reconcile
    /// loop) have ended, and no write of `store` is in flight. A write returns to its
    /// operation on the Store's actor, which then runs to its next suspension: to its change,
    /// or to its next write (`writeInPages`). So once none is in flight, one more turn on the
    /// actor finds every change for them sent, unless another write began meanwhile.
    func uncoveredOnceWorkEnds(of store: CatalogStore?) async -> [UncoveredWrite] {
        let cancelled = shared.state.withLock { state in
            defer { state.cancelled.removeAll() }
            return state.cancelled
        }
        for task in cancelled {
            await task.value
        }
        while true {
            await withCheckedContinuation { continuation in
                let idle = shared.state.withLock { state in
                    if !state.callsInFlight.isEmpty {
                        state.idleWaiters.append(continuation)
                    }
                    return state.callsInFlight.isEmpty
                }
                if idle {
                    continuation.resume()
                }
            }
            if let store {
                _ = await store.isFilesystemQuiescent
            }
            if shared.state.withLock({ $0.callsInFlight.isEmpty }) {
                return takeUncovered()
            }
        }
    }

    /// Every commit still owed now, removed from the guard.
    func takeUncovered() -> [UncoveredWrite] {
        shared.state.withLock { state in
            defer { state.debts.removeAll() }
            return state.debts.filter { !$0.overtaken }.map {
                UncoveredWrite(operation: $0.operation, owing: $0.owing, missing: $0.unpaid)
            }
        }
    }

    private func opened(_ pool: any DatabaseWriter) {
        do {
            let parents = try pool.read { db in
                var parents: [String: Set<String>] = [:]
                for table in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'") {
                    let rows = try Row.fetchAll(db, sql: "SELECT \"table\", on_delete FROM pragma_foreign_key_list(?)", arguments: [table])
                    for row in rows where (row["on_delete"] as String?)?.uppercased() == "CASCADE" {
                        parents[table.lowercased(), default: []].insert((row["table"] as String).lowercased())
                    }
                }
                return parents
            }
            var ancestors = parents
            var grew = true
            while grew {
                grew = false
                for (table, above) in ancestors {
                    let wider = above.union(above.flatMap { ancestors[$0] ?? [] })
                    if wider != above {
                        ancestors[table] = wider
                        grew = true
                    }
                }
            }
            shared.state.withLock { $0.cascadeAncestors = ancestors }
        } catch {
            Issue.record(error, "the change-coverage guard could not read the catalog's foreign keys")
        }
        pool.add(transactionObserver: self, extent: .observerLifetime)
        pool.add(transactionObserver: statementEnd, extent: .observerLifetime)
    }

    private func heard(_ change: CatalogStoreChange) {
        guard !dropping(change) else { return }
        let named = change.facts
        shared.state.withLock { state in
            state.debts = state.debts.compactMap { debt in
                var debt = debt
                debt.unpaid.subtract(named)
                return debt.unpaid.isEmpty ? nil : debt
            }
        }
    }

    // MARK: TransactionObserver, on the writer's queue

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        shared.state.withLock { state in
            if state.statementEnded {
                state.statementKinds = []
                state.statementEnded = false
            }
            state.statementKinds.append(eventKind)
            switch eventKind {
            case let .insert(table), let .delete(table):
                if table.lowercased() == "immich_mirror_pair" {
                    state.transaction.wroteMirrorPairs = true
                }
            case .update:
                break
            }
        }
        return true
    }

    /// The second observer: GRDB asks it about each statement after the guard, so its ask
    /// says the statement's kinds are all known.
    private final class StatementEnd: TransactionObserver, Sendable {
        private let shared: Shared

        init(shared: Shared) {
            self.shared = shared
        }

        func observes(eventsOfKind _: DatabaseEventKind) -> Bool {
            shared.state.withLock { $0.statementEnded = true }
            return false
        }

        func databaseDidChange(with _: DatabaseEvent) {}
        func databaseDidCommit(_: Database) {}
        func databaseDidRollback(_: Database) {}
    }

    func databaseDidChange(with event: DatabaseEvent) {
        let table = event.tableName.lowercased()
        let kind = event.kind
        let rowID = event.rowID
        shared.state.withLock { state in
            switch kind {
            case .insert:
                state.insertedRows[table, default: []].insert(rowID)
            case .delete:
                if state.insertedRows[table]?.remove(rowID) != nil {
                    return
                }
                // A cascade's deletes follow its parent's, whose event came first.
                let cascaded = !(state.cascadeAncestors[table] ?? []).isDisjoint(with: state.deletedTables)
                state.deletedTables.insert(table)
                if !cascaded {
                    state.transaction.writes.insert(.delete(table))
                }
            case .update:
                guard state.insertedRows[table]?.contains(rowID) != true else { return }
                for case let .update(updated, columns) in state.statementKinds where updated.lowercased() == table {
                    for column in columns {
                        state.transaction.writes.insert(.column(table, column.lowercased()))
                    }
                }
            }
        }
    }

    func databaseDidCommit(_: Database) {
        shared.state.withLock { state in
            var transaction = state.transaction
            transaction.operation = state.operation
            for (table, rows) in state.insertedRows where !rows.isEmpty {
                transaction.writes.insert(.insert(table))
            }
            state.transaction = Transaction()
            state.insertedRows = [:]
            state.deletedTables = []
            guard !state.shutDown else { return }
            let call = state.call
            let owing = transaction.writes.sorted().compactMap { write -> (write: Write, facts: CatalogChangedFacts)? in
                var facts = Self.facts(of: write)
                for narrowing in Narrowing.allCases {
                    facts.subtract(narrowing.waived(write, in: transaction))
                }
                return facts.isEmpty ? nil : (write, facts)
            }
            let owed = owing.reduce(into: CatalogChangedFacts()) { $0.formUnion($1.facts) }
            if !owed.isEmpty {
                state.debts.append(Debt(operation: transaction.operation, call: call, owing: owing, unpaid: owed))
            }
        }
    }

    func databaseDidRollback(_: Database) {
        shared.state.withLock { state in
            state.transaction = Transaction()
            state.insertedRows = [:]
            state.deletedTables = []
        }
    }

    private static func facts(of write: Write) -> CatalogChangedFacts {
        switch write {
        case let .insert(table): insertFacts[table] ?? []
        case let .delete(table): deleteFacts[table] ?? []
        case let .column(table, column): columnFacts["\(table).\(column)"] ?? []
        }
    }
}
