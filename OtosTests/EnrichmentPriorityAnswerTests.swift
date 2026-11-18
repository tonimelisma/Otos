import Foundation
@testable import OtosKit
import Testing

/// ADR 0032 rule 8, ADR 0009: the rows on screen are claimed ahead of background work, so
/// every enrichment pass asks the Store which of them owe work. A row the Store answered owes
/// nothing is not asked of again until a write names it (`PriorityAnswers`): a pass woken by
/// anything else reads none of them, where every pass read every row on screen (1,084 reads in
/// the owner's ten-minute idle session).
@Suite(.testScope)
struct EnrichmentPriorityAnswerTests {
    private static let names = ["a.jpg", "b.jpg", "c.jpg"]

    /// Read transactions of the rows the priority claim reads.
    private static func assetReads(_ store: CatalogStore) -> Int {
        store.use().connections.holds.filter { $0.operation.hasPrefix("mediaAssets") }.reduce(0) { $0 + $1.count }
    }

    private static func enricher() -> MediaEnricher {
        MediaEnricher { id, _, size, mtime, _, _ in
            .complete(EnrichmentResult(
                id: id, metadata: AssetMetadata(), thumbnailPath: "thumb-\(id.relativePath.rawValue)",
                sourceSize: size, sourceMTimeSeconds: mtime, contentHash: .empty
            ))
        }
    }

    @Test func rowsOnScreenThatOweNothingAreReadOnceUntilAWriteNamesThem() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // File-backed: its connections account their transactions (`CatalogStore.use()`).
        let store = makeTestStore(location: .databaseFile(temp.appending(path: "catalog.sqlite")), scanner: fixedScanner(Self.names))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == Self.names.count }
        let ids = scanned.testAssets.map(\.id).sorted { $0.relativePath.rawValue < $1.relativePath.rawValue }

        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: Self.enricher(),
            materialize: { _ in .testMaterialized },
            originalStatus: { _ in .materialized }
        )
        await coordinator.updateViewport(ids)
        await coordinator.start()
        _ = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.testAssets.allSatisfy { !$0.needsEnrichment(.library) }
        }
        _ = try await coordinator.untilQuiescent()

        // Woken with nothing new, a pass reads none of the rows on screen.
        let settledReads = Self.assetReads(store)
        let settled = await coordinator.status.work
        for _ in 0 ..< 5 {
            await coordinator.ringIdle()
            _ = try await coordinator.untilQuiescent()
        }
        #expect(Self.assetReads(store) == settledReads)
        #expect(await coordinator.status.work.passes - settled.passes == 5)
        #expect(await coordinator.status.work.rows == settled.rows)

        // A write that names one row: that row alone is read again, once.
        await coordinator.noteStoreChange(.changed(.detail, rows: .rows([ids[0]])))
        _ = try await coordinator.untilQuiescent()
        #expect(Self.assetReads(store) == settledReads + 1)
        #expect(await coordinator.status.work.rows == settled.rows + 1)

        // A change that names no rows: every row on screen is read again, once.
        await coordinator.noteStoreChange(.changed(.detail, rows: .unnamed))
        _ = try await coordinator.untilQuiescent()
        await coordinator.ringIdle()
        _ = try await coordinator.untilQuiescent()
        #expect(Self.assetReads(store) == settledReads + 2)
        #expect(await coordinator.status.work.rows == settled.rows + 1 + ids.count)
        await coordinator.shutdown()
        await store.shutdown()
    }

    /// A change heard while the read of the rows is out may postdate what the read saw: the
    /// row it names is not held from that answer.
    @Test func aRowNamedWhileItsReadIsOutIsAskedAgain() {
        let id = MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/Pics/"), relativePath: MediaRelativePath(rawValue: "a.jpg"))
        let other = MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/Pics/"), relativePath: MediaRelativePath(rawValue: "b.jpg"))
        var answers = PriorityAnswers()
        answers.align(admission: .admitted, keeping: [id, other])
        answers.beginRead()
        answers.heard(.rows([id]))
        answers.endRead(nothingToClaim: [id, other])
        #expect(!answers.holds(id))
        #expect(answers.holds(other))

        answers.beginRead()
        answers.heard(.unnamed)
        answers.endRead(nothingToClaim: [id])
        #expect(!answers.holds(id))
        #expect(!answers.holds(other))
    }
}
