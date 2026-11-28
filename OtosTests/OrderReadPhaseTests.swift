import Foundation
import GRDB
@testable import OtosKit
import Testing

/// What each phase of All Media's order read costs on a catalog of the reference shape: the
/// SQL and its rows, the stack candidates and their rule, the rows made the window's IDs, the
/// collapse and the grid's position index. A measurement, not a benchmark: it runs at the
/// reference library's size only on demand (`OTOS_SCALE_TEST=1`), and writes
/// `build/order-read-phases/phases.txt`. Run unoptimized by `script/check.sh`, and with OtosKit
/// at `-O` by an `xcodebuild test` that sets the optimization per target (the research note
/// gives the command: the test target does not compile at `-O`).
/// (`docs/research/2026-11-16-window-reads-reference-catalog.md`). It asserts only that every
/// phase ran.
@Suite(.testScope, .serialized)
struct OrderReadPhaseTests {
    @Test(.enabled(if: StallReproductionTests.referenceSize))
    func eachPhaseOfAllMediasOrderReadIsMeasured() async throws {
        let catalog = try ReferenceShapedCatalog.make(in: makeTestDirectory(), scale: 1)
        let queue = try makeTestDatabaseQueue(path: catalog.databaseURL.path(percentEncoded: false))
        defer { try? queue.close() }
        var lines: [String] = []
        for round in 1 ... 3 {
            let phases = try await queue.read { db in try Self.phases(db: db) }
            lines.append("round=\(round) " + phases.map { "\($0.name)=\($0.ms)" }.joined(separator: " "))
            #expect(phases.allSatisfy { $0.ms >= 0 })
        }
        let directory = SourceTree.root.appending(path: "build/order-read-phases", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: directory.appending(path: "phases.txt"), atomically: true, encoding: .utf8
        )
    }

    private static func phases(db: Database) throws -> [(name: String, ms: Int)] {
        var rootPaths: [Int64: LibraryRootPath] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, path FROM library_root WHERE id IN (6, 7, 15)") {
            rootPaths[row[0]] = LibraryRootPath(rawValue: row[1])
        }
        let scope = CatalogScopePredicate(rootIDs: [6, 7, 15], showsOneCopy: true, holdsEveryCopyRoot: true)
        let descriptor = CatalogQueryDescriptor(scope: .allMedia)
        let clock = ContinuousClock()
        var phases: [(name: String, ms: Int)] = []
        func measure<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
            let start = clock.now
            let value = try work()
            phases.append((name, DiagnosticsTiming.milliseconds(start.duration(to: clock.now))))
            return value
        }
        let rows = try measure("sqlRowsMs") {
            try CatalogQueryGateway.fetchOrderedAssetIDRows(descriptor: descriptor, scope: scope, stacks: .readWhenNeeded(.paired), db: db)
        }
        let built = try measure("stacksMs") { try PhotoStackSQL.build(rootPaths: rootPaths, pairing: .paired, db: db) }
        phases.append(("stackReadMs", DiagnosticsTiming.milliseconds(built.readDuration)))
        phases.append(("stackRuleMs", DiagnosticsTiming.milliseconds(built.ruleDuration)))
        let ordered = measure("mapMs") {
            CatalogStore.orderedAssets(
                from: rows, stacks: built.stacks, rootPathsByRowID: rootPaths, scope: scope, groupsByDate: true
            )
        }
        let collapsed = measure("collapseMs") {
            PhotoStackCollapse.collapse(
                ids: ordered.ids, dayBuckets: ordered.dayBuckets, coordinates: ordered.coordinates,
                stacks: built.stacks, expanded: []
            )
        }
        measure("positionIndexMs") {
            CatalogGridContent(orderedAssetIDs: collapsed.ids, dayBuckets: collapsed.dayBuckets, stacks: collapsed.grid)
                .prepareIndex()
        }
        phases.append(("rows", rows.count))
        phases.append(("shown", collapsed.ids.count))
        return phases
    }
}
