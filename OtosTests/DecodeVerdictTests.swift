import Foundation
import GRDB
@testable import OtosKit
import Testing

/// "Cannot decode" is the decoder's verdict, stored with the decoder that gave it, and a
/// still an earlier decoder could not read is tried again (ENR-029).
@Suite(.testScope)
struct DecodeVerdictTests {
    private static func id(_ name: String) -> MediaAssetID {
        MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/Pictures"), relativePath: MediaRelativePath(rawValue: name))
    }

    private static func enricher() throws -> MediaEnricher {
        try MediaEnricher.live(thumbnailDirectory: makeTestDirectory())
    }

    @Test func aStillNoDecoderCanReadNamesTheDecoderThatSaidSo() async throws {
        let directory = try makeTestDirectory()
        let broken = directory.appending(path: "broken.jpg")
        try Data("not an image".utf8).write(to: broken)

        let outcome = try await Self.enricher().enrich(
            Self.id("broken.jpg"), .localFile(broken), 12, 1000, [.rendering], nil
        )

        guard case let .complete(result) = outcome else {
            Issue.record("expected .complete, got \(outcome)")
            return
        }
        #expect(result.decodeVerdict == .undecodable(decoder: ImageRenderer.decoderIdentity))
        #expect(result.rendering?.generatedPreview == nil)
    }

    /// A still whose bytes cannot be read is not judged: nothing is stamped and the row is
    /// retried, rather than stamped with QuickLook's thumbnail and no preview, which would
    /// leave it with no faces (ADR 0047).
    @Test func aStillWhoseBytesCannotBeReadIsRetried() async throws {
        struct AlwaysLocal: EnrichmentReadinessChecking {
            func status(of url: URL) -> FileMaterializationStatus {
                .materialized
            }
        }
        let missing = try makeTestDirectory().appending(path: "gone.jpg")
        let enricher = try MediaEnricher.live(thumbnailDirectory: makeTestDirectory(), readinessChecker: AlwaysLocal())

        let outcome = await enricher.enrich(Self.id("gone.jpg"), .localFile(missing), 12, 1000, [.rendering], nil)

        guard case .transient = outcome else {
            Issue.record("expected .transient, got \(outcome)")
            return
        }
    }

    @Test func aStillTheDecoderReadsIsDecoded() async throws {
        let url = SourceTree.mediaFixtures.appending(path: "jpeg-exif-offset-date.jpg")

        let outcome = try await Self.enricher().enrich(Self.id("a.jpg"), .localFile(url), 100, 1000, [.rendering], nil)

        guard case let .complete(result) = outcome else {
            Issue.record("expected .complete, got \(outcome)")
            return
        }
        #expect(result.decodeVerdict == .decoded)
    }

    /// At launch a still another decoder could not read loses its rendering stamp, so
    /// enrichment tries it; one this decoder could not read keeps it, and a decoded still is
    /// untouched.
    @Test func launchReleasesOnlyStillsAnotherDecoderCouldNotRead() async throws {
        let databaseURL = try makeTestDirectory().appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fresh = makeTestStore(location: .databaseFile(databaseURL))
        try await fresh.start(scansSavedLibraries: false)
        await fresh.shutdown()
        try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).write { db in
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (1, '/Pictures', 'library')")
            let rows: [(String, String?)] = [
                ("earlierDecoder.jpg", "otos1-macos25A1"), ("thisDecoder.jpg", ImageRenderer.decoderIdentity),
                ("decoded.jpg", nil),
            ]
            for (path, undecodableBy) in rows {
                try Self.insertStampedStill(path, undecodableBy: undecodableBy, preview: nil, db: db)
            }
        }

        let store = makeTestStore(location: .databaseFile(databaseURL))
        try await store.start(scansSavedLibraries: false)
        await store.shutdown()

        let rows = try await Self.stamps(databaseURL)
        #expect(rows["earlierDecoder.jpg"] == Stamps(rendered: false, undecodableBy: nil))
        #expect(rows["thisDecoder.jpg"] == Stamps(rendered: true, undecodableBy: ImageRenderer.decoderIdentity))
        #expect(rows["decoded.jpg"] == Stamps(rendered: true, undecodableBy: nil))
    }

    /// At launch a video another frame reader could not decode loses its faces stamp, so
    /// enrichment reads its faces again (ENR-031); one this reader could not decode keeps it.
    /// Each kind is judged by its own decoder: a video's verdict never releases a still's
    /// rendering, nor a still's decoder a video's faces.
    @Test func launchReleasesOnlyVideosAnotherFrameReaderCouldNotDecode() async throws {
        let databaseURL = try makeTestDirectory().appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fresh = makeTestStore(location: .databaseFile(databaseURL))
        try await fresh.start(scansSavedLibraries: false)
        await fresh.shutdown()
        try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).write { db in
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (1, '/Pictures', 'library')")
            let videos: [(String, String?)] = [
                ("earlierReader.mov", "otos-video0-macos25A1"), ("thisReader.mov", VideoFaceReader.decoderIdentity),
                ("stillDecoder.mov", ImageRenderer.decoderIdentity), ("decoded.mov", nil),
            ]
            for (path, undecodableBy) in videos {
                try Self.insertStampedStill(path, undecodableBy: undecodableBy, preview: nil, kind: "video", db: db)
                try db.execute(
                    sql: "UPDATE media_asset SET faces_source_size = 10, faces_source_mtime = 20 WHERE relative_path = ?",
                    arguments: [path]
                )
            }
            try Self.insertStampedStill("videoReader.jpg", undecodableBy: VideoFaceReader.decoderIdentity, preview: nil, db: db)
        }

        let store = makeTestStore(location: .databaseFile(databaseURL))
        try await store.start(scansSavedLibraries: false)
        await store.shutdown()

        let rows = try await Self.stamps(databaseURL)
        let faces = try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
            try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT relative_path, faces_source_size FROM media_asset").map { row in
                (row["relative_path"] as String, (row["faces_source_size"] as Int64?) != nil)
            })
        }
        #expect(rows["earlierReader.mov"] == Stamps(rendered: true, undecodableBy: nil))
        #expect(faces["earlierReader.mov"] == false)
        #expect(rows["stillDecoder.mov"] == Stamps(rendered: true, undecodableBy: nil))
        #expect(faces["stillDecoder.mov"] == false)
        #expect(rows["thisReader.mov"] == Stamps(rendered: true, undecodableBy: VideoFaceReader.decoderIdentity))
        #expect(faces["thisReader.mov"] == true)
        #expect(rows["decoded.mov"] == Stamps(rendered: true, undecodableBy: nil))
        #expect(faces["decoded.mov"] == true)
        #expect(rows["videoReader.jpg"] == Stamps(rendered: false, undecodableBy: nil))
    }

    /// Before the verdict was stored, a still the renderer could not read was rendered
    /// from QuickLook's thumbnail: stamped, with no preview. The migration marks those as
    /// undecodable by Otos's first decoder, so launch tries each again; a still with a
    /// preview and a video are left as they were.
    @Test func theVerdictMigrationRetriesStillsRenderedWithoutAPreview() async throws {
        let databaseURL = try makeTestDirectory().appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fresh = makeTestStore(location: .databaseFile(databaseURL))
        try await fresh.start(scansSavedLibraries: false)
        await fresh.shutdown()
        try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).write { db in
            // Back to before v25, and v44, which indexes its column.
            try db.execute(sql: "DROP INDEX idx_media_asset_undecodable")
            try db.execute(sql: "ALTER TABLE media_asset DROP COLUMN undecodable_by")
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier IN (?, ?)",
                arguments: [CatalogSchema.decodeVerdictMigrationIdentifier, CatalogSchema.undecodableIndexMigrationIdentifier]
            )
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (1, '/Pictures', 'library')")
            try Self.insertStampedStill("fallback.jpg", undecodableBy: nil, preview: nil, db: db, withVerdictColumn: false)
            try Self.insertStampedStill("previewed.jpg", undecodableBy: nil, preview: "p.heic", db: db, withVerdictColumn: false)
            try Self.insertStampedStill("clip.mov", undecodableBy: nil, preview: nil, kind: "video", db: db, withVerdictColumn: false)
        }

        let store = makeTestStore(location: .databaseFile(databaseURL))
        try await store.start(scansSavedLibraries: false)
        await store.shutdown()

        let rows = try await Self.stamps(databaseURL)
        #expect(rows["fallback.jpg"] == Stamps(rendered: false, undecodableBy: nil))
        #expect(rows["previewed.jpg"] == Stamps(rendered: true, undecodableBy: nil))
        #expect(rows["clip.mov"] == Stamps(rendered: true, undecodableBy: nil))
    }

    private struct Stamps: Equatable {
        let rendered: Bool
        let undecodableBy: String?
    }

    private static func insertStampedStill(
        _ path: String,
        undecodableBy: String?,
        preview: String?,
        kind: String = "image",
        db: Database,
        withVerdictColumn: Bool = true
    ) throws {
        let verdictColumn = withVerdictColumn ? ", undecodable_by" : ""
        let verdictValue = withVerdictColumn ? ", ?" : ""
        var arguments: [(any DatabaseValueConvertible)?] = [path, path, path, path, kind, preview]
        if withVerdictColumn {
            arguments.append(undecodableBy)
        }
        try db.execute(
            sql: """
            INSERT INTO media_asset (library_root_id, relative_path, relative_path_key, name_sort_key,
                kind, preview_path, rendered_source_size, rendered_source_mtime
                \(verdictColumn))
            VALUES (1, ?, ?, ?, ?, ?, 10, 20\(verdictValue))
            """,
            arguments: StatementArguments(arguments)
        )
    }

    private static func stamps(_ databaseURL: URL) async throws -> [String: Stamps] {
        try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
            try Dictionary(uniqueKeysWithValues: Row.fetchAll(
                db,
                sql: "SELECT relative_path, rendered_source_size, undecodable_by FROM media_asset"
            ).map { row in
                (row["relative_path"] as String, Stamps(
                    rendered: (row["rendered_source_size"] as Int64?) != nil,
                    undecodableBy: row["undecodable_by"]
                ))
            })
        }
    }
}
