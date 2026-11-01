import Foundation
import GRDB
import ImageIO
import MediaMetadata
@testable import OtosKit
import Testing

/// ADR 0039: a metadata record an older MediaMetadata revision produced is re-read from
/// local bytes only, and only for library rows whose enrichment is otherwise current.
@Suite(.testDirectory)
@MainActor
struct MetadataRefresherTests {
    @Test func aStaleRecordIsReReadWhenItsOriginalIsLocalAndLeftWhenItIsNot() async throws {
        // HEIF: its family's reading has changed since revisions began, so a record with no
        // revision is stale (a JPEG's has not: it is current at 0).
        try await withEditableLibrary(fileCount: 2, fileExtension: "heic", write: writeRotatedHEIC) { library in
            let state = try await catalogStoreTestState(library.store)
            let stale = try state.testAssets.map { asset in
                try EnrichmentResult(
                    id: asset.id,
                    metadata: AssetMetadata(family: "unknown", extractionRevision: nil),
                    thumbnailPath: nil,
                    sourceSize: #require(asset.byteSize),
                    sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
                    contentHash: .empty
                )
            }
            _ = await library.store.applyEnrichmentBatch(stale)
            let local = library.ids[0]
            let cloudOnly = library.ids[1]
            let refresher = MetadataRefresher(store: library.store, isLocal: { $0 == local.fileURL }, pageSize: 1)

            let summary = await refresher.refresh()

            #expect(summary == MetadataRefreshSummary(read: 1, written: 1, skipped: 1, failed: false))
            let rows = try await revisions(library.databaseURL)
            #expect(rows[local.relativePath.rawValue]?.revision == MediaMetadataReader.extractionRevision(for: .heif))
            #expect(rows[local.relativePath.rawValue]?.family == "heif")
            #expect(rows[cloudOnly.relativePath.rawValue]?.revision == nil)

            let again = await MetadataRefresher(store: library.store, isLocal: { _ in true }).refresh()
            #expect(again.written == 1)
            #expect(try await revisions(library.databaseURL)[cloudOnly.relativePath.rawValue]?.revision
                == MediaMetadataReader.extractionRevision(for: .heif))
        }
    }

    /// MediaMetadata 0.8.0 reads PNG as a family of its own. A PNG that 0.7.1 cataloged
    /// as `unknown` at revision 1 is older than `unknown`'s revision 2, so it is re-read
    /// from local bytes and becomes a `png` record at that family's revision.
    @Test func aPNGCatalogedAsUnknownIsReReadAsPNG() async throws {
        try await withEditableLibrary(fileCount: 1, fileExtension: "png", write: { url in
            let image = try #require(gradientImage(width: 96, height: 64))
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            try #require(CGImageDestinationFinalize(destination))
        }) { library in
            let state = try await catalogStoreTestState(library.store)
            let asset = try #require(state.testAssets.first)
            _ = try await library.store.applyEnrichmentBatch([
                EnrichmentResult(
                    id: asset.id,
                    metadata: AssetMetadata(family: "unknown", extractionRevision: 1),
                    thumbnailPath: nil,
                    sourceSize: asset.byteSize,
                    sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
                    contentHash: .empty
                ),
            ])

            let summary = await MetadataRefresher(store: library.store, isLocal: { _ in true }).refresh()

            #expect(summary == MetadataRefreshSummary(read: 1, written: 1, skipped: 0, failed: false))
            let row = try await revisions(library.databaseURL)[asset.id.relativePath.rawValue]
            #expect(row?.family == MediaFormat.Family.png.rawValue)
            #expect(row?.revision == MediaMetadataReader.extractionRevision(for: .png))
        }
    }

    /// Only library rows with a current enrichment and a record older than its family's
    /// current reading are candidates: a card row, a row already current, a row whose file
    /// changed (which enrichment re-reads anyway), and a family the library has not changed
    /// (JPEG, current at 0 with no revision) are not.
    @Test func candidatesAreLibraryRowsWithCurrentEnrichmentAndAnOlderRecord() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let creator = CatalogStore(location: .databaseFile(databaseURL))
        try await creator.start(scansSavedLibraries: false)
        await creator.shutdown()
        try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).write { db in
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (1, '/Pictures', 'library')")
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (2, '/Volumes/Card', 'removableVolume')")
            struct Fixture {
                let root: Int
                let path: String
                let enrichedMTime: Int
                let family: String
                let revision: Int?
            }
            let current = MediaMetadataReader.extractionRevision(for: .heif)
            for row in [
                Fixture(root: 1, path: "unknown.heic", enrichedMTime: 100, family: "heif", revision: nil),
                Fixture(root: 1, path: "older.heic", enrichedMTime: 100, family: "heif", revision: current - 1),
                Fixture(root: 1, path: "current.heic", enrichedMTime: 100, family: "heif", revision: current),
                Fixture(root: 1, path: "changed.heic", enrichedMTime: 99, family: "heif", revision: nil),
                Fixture(root: 1, path: "unchanged.jpg", enrichedMTime: 100, family: "jpeg", revision: nil),
                Fixture(root: 2, path: "card.heic", enrichedMTime: 100, family: "heif", revision: nil),
            ] {
                try db.execute(
                    sql: """
                    INSERT INTO media_asset (library_root_id, relative_path, relative_path_key, sort_key, name_sort_key,
                        kind, byte_size, content_modified_at_unix, metadata_source_size, metadata_source_mtime)
                    VALUES (?, ?, ?, ?, ?, 'image', 10, 100, 10, ?)
                    """,
                    arguments: [row.root, row.path, row.path, row.path, row.path, row.enrichedMTime]
                )
                try db.execute(
                    sql: "INSERT INTO asset_metadata (library_root_id, relative_path, family, extraction_revision) VALUES (?, ?, ?, ?)",
                    arguments: [row.root, row.path, row.family, row.revision]
                )
            }
        }
        let store = CatalogStore(location: .databaseFile(databaseURL))
        try await store.start(scansSavedLibraries: false)
        let candidates = try await store.metadataRefreshCandidates(after: nil, limit: 10)
        await store.shutdown()

        #expect(candidates.map(\.id.relativePath.rawValue) == ["older.heic", "unknown.heic"])
    }

    /// ADR 0041: a cloud-only, Apple-made record that predates the content identifier may be
    /// half of a Live Photo, so it is handed to enrichment, which downloads it once and
    /// writes every product from that one read — metadata, checksum and thumbnail. A
    /// non-Apple record is skipped and never downloaded, as ADR 0039 has it.
    @Test func aCloudOnlyAppleRecordIsDownloadedOnceAndFullyEnriched() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let store = CatalogStore(location: .inMemory, scanner: fixedScanner(["IMG_1.HEIC", "b.heic"]))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 2 }
        let apple = MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: "IMG_1.HEIC"))
        let other = MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: "b.heic"))
        let hash = try #require(XXH3Digest128(canonicalBytes: [UInt8](repeating: 7, count: 16)))
        _ = await store.applyEnrichmentBatch(scanned.testAssets.map { asset in
            EnrichmentResult(
                id: asset.id,
                metadata: AssetMetadata(family: "heif", cameraMake: asset.id == apple ? "Apple" : "Canon"),
                enrichedKind: .image,
                thumbnailPath: "old.jpg",
                sourceSize: asset.byteSize,
                sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
                contentHash: hash
            )
        })

        let summary = await MetadataRefresher(store: store, isLocal: { _ in false }).refresh()

        #expect(summary == MetadataRefreshSummary(read: 0, written: 0, skipped: 1, downloadsRequested: 1, failed: false))
        let handedOver = try await catalogStoreTestState(store).testAssets
        #expect(handedOver.first { $0.id == apple }?.needsEnrichment(everyProduct: true) == true)
        #expect(handedOver.first { $0.id == other }?.needsEnrichment(everyProduct: true) == false)

        let state = FakeMaterialization(dataless: [apple.fileURL.path(percentEncoded: false)])
        let downloads = TestCounter()
        let reads = TestRecorder<EnrichmentScope>()
        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: MediaEnricher { id, access, size, mtime, scope, _ in
                let url = access.localURL ?? id.fileURL
                if await state.isDataless(url.path(percentEncoded: false)) {
                    return .notMaterialized
                }
                reads.record(scope)
                return .complete(EnrichmentResult(
                    id: id,
                    metadata: AssetMetadata(
                        family: "heif",
                        cameraMake: "Apple",
                        contentIdentifier: "66E9019A-9CAF-4603-A6C3-2F22030B7C65",
                        extractionRevision: MediaMetadataReader.extractionRevision(for: .heif)
                    ),
                    enrichedKind: .image,
                    thumbnailPath: "new.jpg",
                    sourceSize: size,
                    sourceMTimeSeconds: mtime,
                    contentHash: hash
                ))
            },
            materialize: { url in
                downloads.increment()
                await state.materialize(url.path(percentEncoded: false))
                return .testMaterialized
            },
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized)
        )
        await coordinator.start()
        let enriched = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.testAssets.allSatisfy { !$0.needsEnrichment(everyProduct: true) }
        }
        await coordinator.shutdown()

        #expect(downloads.value == 1)
        #expect(reads.values == [[.metadata, .rendering]])
        #expect(enriched.testAssets.first { $0.id == apple }?.thumbnailPath == "new.jpg")
        #expect(enriched.testAssets.first { $0.id == other }?.thumbnailPath == "old.jpg")
        let stored = try await store.metadataRefreshCandidates(after: nil, limit: 10)
        #expect(stored.map(\.id) == [other])
    }

    private func revisions(_ databaseURL: URL) async throws -> [String: (revision: Int?, family: String?)] {
        try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
            var result: [String: (revision: Int?, family: String?)] = [:]
            for row in try GRDB.Row.fetchAll(db, sql: "SELECT relative_path, extraction_revision, family FROM asset_metadata") {
                result[row["relative_path"]] = (row["extraction_revision"], row["family"])
            }
            return result
        }
    }
}
