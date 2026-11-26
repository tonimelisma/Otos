import Foundation
import GRDB
import OSLog

/// Operational work guide
///
/// Whether an import or a reorganization is in flight is a fact the catalog's journals hold:
/// a file operation that is not `abandoned` (an abandoned one is cleanup owed to the next
/// launch, not work), or a reorganization component (ADR 0020's busy predicate, which
/// `script/lib/operational-busy.sh` reads from outside the app). An update replaces the
/// running app, so it waits until the answer is no (`UpdateInstallGate`, ADR 0059).
///
/// The Store owns the answer and says when it changes. Every journal write commits through
/// `writeJournal`, which reads the answer inside the same transaction, so no write can change
/// it without the Store hearing; the open reads it once first. A subscriber gets the current
/// answer at once, then each change, newest wins.
extension CatalogStore {
    /// The answer as the journals hold it in `db`.
    nonisolated static func operationalWorkInFlight(_ db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS (SELECT 1 FROM active_file_operation WHERE phase != ?)
                OR EXISTS (SELECT 1 FROM active_reorganization_component)
            """,
            arguments: [ActiveFileOperationPhase.abandoned.rawValue]
        ) ?? false
    }

    /// Commits one journal write with full durability (`writeWithJournalDurability`) and
    /// publishes the operational answer that write's transaction left.
    func writeJournal<T>(
        _ dbWriter: CatalogWriter,
        operation: String = #function,
        _ body: (Database) throws -> T
    ) throws -> T {
        let (result, inFlight) = try Self.writeWithJournalDurability(dbWriter, operation: operation) { db in
            let result = try body(db)
            return try (result, Self.operationalWorkInFlight(db))
        }
        publishOperationalWork(inFlight, cause: operation)
        return result
    }

    /// The open's own read of the answer. A failed read publishes nothing: the answer stays
    /// unknown until the next journal write reads it, and a subscriber waits.
    func readOperationalWorkAtOpen(_ dbWriter: CatalogWriter) {
        do {
            // The open's own reads, before any lane exists.
            // swiftlint:disable:next read_outside_lane
            let inFlight = try dbWriter.reader.read { db in try Self.operationalWorkInFlight(db) }
            publishOperationalWork(inFlight, cause: "open")
        } catch {
            OtosLog.catalog.errorOperation("catalog.operationalWork", phase: "readFailed", fields: [
                "error": String(describing: error),
            ])
        }
    }

    /// The current answer at once, when it is known, then each change.
    func operationalWorkChanges() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        operationalWorkContinuations[id] = continuation
        if let operationalWork {
            continuation.yield(operationalWork)
        }
        continuation.onTermination = { [weak self] _ in
            // The same required actor hop as `changeNotifications`: termination is
            // synchronous, the continuations are actor state.
            Task {
                await self?.removeOperationalWorkContinuation(id)
            }
        }
        return stream
    }

    private func publishOperationalWork(_ inFlight: Bool, cause: String) {
        guard operationalWork != inFlight else { return }
        operationalWork = inFlight
        OtosLog.catalog.noticeOperation("catalog.operationalWork", phase: inFlight ? "inFlight" : "none", fields: [
            "cause": cause,
        ])
        for continuation in operationalWorkContinuations.values {
            continuation.yield(inFlight)
        }
    }

    private func removeOperationalWorkContinuation(_ id: UUID) {
        operationalWorkContinuations.removeValue(forKey: id)
    }
}
