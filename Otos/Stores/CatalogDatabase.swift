import Foundation
import GRDB
import OSLog

/// CatalogDatabase — Stage 1 of plan 0076.
///
/// Owns the GRDB `DatabaseWriter`, migrations, and the `timedRead`/`timedWrite` wrappers
/// that are the sole SQLite serialization point (GRDB's `DatabaseWriter` already serializes
/// writes; the former `CatalogStore` actor added only a queue in front of it — §2).
/// Vend a `nonisolated` `CatalogReader` handle so components that only need SQLite plus an
/// immutable roots snapshot stay off any actor (decision 1, §3).
///
/// Task ownership: `database()` is called once per `CatalogStore` via `loadIfNeeded` and
/// `ensureStartedForMutation` (`CatalogStore.swift:1050`); no long-lived stream is held.
/// Cancellation is via `Task.sleep` in `CatalogStore` callers, not here.
actor CatalogDatabase {
    private var dbWriter: (any DatabaseWriter)?
    private let location: CatalogStore.Location
    private var databaseFileURL: URL?

    init(location: CatalogStore.Location) {
        self.location = location
    }

    func database() throws -> any DatabaseWriter {
        if let dbWriter {
            return dbWriter
        }
        let state = OtosSignpost.persistence.beginInterval("CatalogOpenDatabase")
        defer { OtosSignpost.persistence.endInterval("CatalogOpenDatabase", state) }
        let openResult = try openDatabaseWriter()
        let dbWriter = openResult.dbWriter
        let compatibility = try dbWriter.read { db in
            try CatalogStore.catalogSchemaCompatibility(db)
        }
        guard compatibility.isSupported else {
            OtosLog.persistence.error(
                "Catalog schema refused problem=\(compatibility.errorDescription, privacy: .public)"
            )
            OtosLog.catalog.error(
                "op=catalog.start phase=schemaRefused problem=\(String(describing: compatibility), privacy: .public)"
            )
            throw CatalogStoreError.unsupportedCatalogSchema(compatibility)
        }
        try CatalogStore.migrator.migrate(dbWriter)
        self.dbWriter = dbWriter
        databaseFileURL = openResult.openedFileURL
        return dbWriter
    }

    func reader() async throws -> CatalogReader {
        let writer = try database()
        return CatalogReader(writer: writer)
    }

    func timedRead<Value: Sendable>(
        _ dbWriter: any DatabaseWriter,
        _ body: @Sendable @escaping (Database) throws -> Value
    ) async throws -> DatabaseTimedValue<Value> {
        let start = Date()
        return try await dbWriter.read { db in
            let entered = Date()
            let value = try body(db)
            return DatabaseTimedValue(
                value: value,
                waitMs: DiagnosticsTiming.milliseconds(from: start, to: entered),
                execMs: DiagnosticsTiming.milliseconds(since: entered)
            )
        }
    }

    func timedWrite<Value: Sendable>(
        _ dbWriter: any DatabaseWriter,
        _ body: @Sendable @escaping (Database) throws -> Value
    ) async throws -> DatabaseTimedValue<Value> {
        let start = Date()
        return try await dbWriter.write { db in
            let entered = Date()
            let value = try body(db)
            return DatabaseTimedValue(
                value: value,
                waitMs: DiagnosticsTiming.milliseconds(from: start, to: entered),
                execMs: DiagnosticsTiming.milliseconds(since: entered)
            )
        }
    }

    struct DatabaseTimedValue<Value: Sendable>: Sendable {
        let value: Value
        let waitMs: Int
        let execMs: Int

        var totalMs: Int {
            waitMs + execMs
        }
    }

    struct DatabaseOpenResult {
        let dbWriter: any DatabaseWriter
        let storageKind: String
        let openedFileURL: URL?
    }

    private func openDatabaseWriter() throws -> DatabaseOpenResult {
        switch location {
        case let .application(bundleIdentifier):
            let databaseURL = try CatalogStore.applicationDatabaseURL(bundleIdentifier: bundleIdentifier)
            return try DatabaseOpenResult(
                dbWriter: DatabasePool(
                    path: databaseURL.path(percentEncoded: false),
                    configuration: CatalogStore.fileBackedDatabaseConfiguration()
                ),
                storageKind: "application",
                openedFileURL: databaseURL
            )
        case let .databaseFile(url):
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return try DatabaseOpenResult(
                dbWriter: DatabasePool(
                    path: url.path(percentEncoded: false),
                    configuration: CatalogStore.fileBackedDatabaseConfiguration()
                ),
                storageKind: "file",
                openedFileURL: url
            )
        case .inMemory:
            return try DatabaseOpenResult(
                dbWriter: DatabaseQueue(),
                storageKind: "memory",
                openedFileURL: nil
            )
        }
    }
}

/// Non-actor handle to the catalog database. Holds the GRDB `DatabaseWriter` which is
/// itself thread-safe and already serializes writes — the actor around it never added
/// serialization, only a queue in front of one that already existed (plan 0076 §2).
/// Components that read SQLite plus an immutable roots snapshot take this and stay off any actor.
nonisolated struct CatalogReader: Sendable {
    let writer: any DatabaseWriter

    func read<V: Sendable>(_ body: @Sendable @escaping (Database) throws -> V) async throws -> CatalogDatabase.DatabaseTimedValue<V> {
        let start = Date()
        return try await writer.read { db in
            let entered = Date()
            let value = try body(db)
            return CatalogDatabase.DatabaseTimedValue(
                value: value,
                waitMs: DiagnosticsTiming.milliseconds(from: start, to: entered),
                execMs: DiagnosticsTiming.milliseconds(since: entered)
            )
        }
    }

    func write<V: Sendable>(_ body: @Sendable @escaping (Database) throws -> V) async throws -> CatalogDatabase.DatabaseTimedValue<V> {
        let start = Date()
        return try await writer.write { db in
            let entered = Date()
            let value = try body(db)
            return CatalogDatabase.DatabaseTimedValue(
                value: value,
                waitMs: DiagnosticsTiming.milliseconds(from: start, to: entered),
                execMs: DiagnosticsTiming.milliseconds(since: entered)
            )
        }
    }
}
