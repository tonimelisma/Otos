import Foundation
import GRDB
@testable import OtosKit
import Testing

/// v76 changed what the order indexes carry and what the order read selects, never the order:
/// every sort under every filter returns the rows a plain reading of the table puts in that
/// order — the sort's key by SQLite's byte comparison, then the root and the path ascending
/// ("sort tie order unchanged") — and the same rows the v75 indexes returned. The names are a
/// corpus of what a library's file names hold: mixed case, accents written composed and
/// decomposed, digit runs of several widths, CJK and Arabic-Indic digits, and one name in two
/// folders and two roots.
@Suite(.testScope)
struct OrderReadDifferentialTests {
    static let names = [
        "IMG_0001.JPG", "img_0002.jpg", "IMG_10.jpg", "img2.jpg", "img02.jpg", "Img_0001.jpg",
        "École.jpg", "ecole.jpg", "E\u{301}cole.jpg", "Ärger.heic", "zebra.heic", "Zebra.HEIC",
        "写真.jpg", "東京 2024.heic", "صورة٣.jpg", "صورة١٢.jpg", "photo (1).jpg", "photo (12).jpg",
        "-dash.jpg", "_under.jpg", "9999999999999999999999.jpg", "a.mov", "B.MOV", "clip 3.mp4",
        "raw_1.ARW", "raw_01.ARW", "Raw_1.dng",
    ]

    struct Row {
        let rootID: Int64
        let path: String
        let key: String
        let kind: String
        let format: String
        let size: Int64?
        let capture: Double?
        let choice: String
        let shown: Bool
    }

    @Test func everyOrderIsTheTablesOrderAndTheV75IndexesOrder() async throws {
        let temp = try makeTestDirectory()
        let queue = try makeTestDatabaseQueue(path: temp.appending(path: "catalog.sqlite").path(percentEncoded: false))
        try CatalogStore.migrator.migrate(queue, upTo: CatalogSchema.rootChangeJournalMigrationIdentifier)
        let (first, second) = try await queue.write { db in try Self.insertCorpus(db) }
        let reads = Self.reads(first: first, second: second)
        let before = try await queue.read { db in try reads.map { try Self.ids($0.descriptor, $0.scope, db) } }
        try CatalogStore.migrator.migrate(queue)
        let after = try await queue.read { db in try reads.map { try Self.rows($0.descriptor, $0.scope, db) } }
        let table = try await queue.read { db in try Self.tableRows(db) }
        for (index, read) in reads.enumerated() {
            let expected = Self.expected(table, read.descriptor, read.scope)
            let ids = after[index].map { Self.key($0.libraryRootID, $0.relativePath.rawValue) }
            #expect(ids == expected, "\(read.name)")
            #expect(ids == before[index], "\(read.name)")
            #expect(!ids.isEmpty || read.descriptor.filter.choices == [.disliked], "\(read.name)")
            // The capture time comes back where the order is by date, and only there.
            let captures = Dictionary(uniqueKeysWithValues: table.map { (Self.key($0.rootID, $0.path), $0.capture) })
            for row in after[index] {
                let expectedCapture = read.descriptor.effectiveSort.field == .bestDate
                    ? captures[Self.key(row.libraryRootID, row.relativePath.rawValue)] ?? nil : nil
                #expect(row.captureLocalTime?.seconds == expectedCapture, "\(read.name)")
            }
        }
    }

    /// A keyed re-read (`CatalogStore.orderedAssetIDs(ofRows:…)`) places a changed row by its
    /// capture time under the date order, the one order it answers: the rows it reads by their
    /// keys carry the time the whole order's read gives them.
    @Test func aKeyedReadCarriesTheCaptureTimeTheWholeOrderDoes() async throws {
        let temp = try makeTestDirectory()
        let queue = try makeTestDatabaseQueue(path: temp.appending(path: "catalog.sqlite").path(percentEncoded: false))
        try CatalogStore.migrator.migrate(queue)
        let (first, second) = try await queue.write { db in try Self.insertCorpus(db) }
        for sort in [MediaSortOrder.dateNewest, .dateOldest] {
            let descriptor = CatalogQueryDescriptor(scope: .allMedia, sort: sort)
            let scope = CatalogScopePredicate(rootIDs: [first, second], showsOneCopy: true, holdsEveryCopyRoot: true)
            let whole = try await queue.read { db in try Self.rows(descriptor, scope, db) }
            let changed = whole.enumerated().filter { $0.offset % 3 == 0 }.map(\.element)
            let members = CatalogScopePredicate(
                rootIDs: [first, second],
                content: .members(changed.map { .init(rootID: $0.libraryRootID, relativePath: $0.relativePath.rawValue) }),
                showsOneCopy: true,
                holdsEveryCopyRoot: true
            )
            let keyed = try await queue.read { db in try Self.rows(descriptor, members, db) }
            let keyedIDs = keyed.map { Self.key($0.libraryRootID, $0.relativePath.rawValue) }
            #expect(keyedIDs == changed.map { Self.key($0.libraryRootID, $0.relativePath.rawValue) })
            #expect(keyed.map(\.captureLocalTime?.seconds) == changed.map(\.captureLocalTime?.seconds))
            #expect(keyed.contains { $0.captureLocalTime != nil })
        }
    }

    struct Read {
        let name: String
        let descriptor: CatalogQueryDescriptor
        let scope: CatalogScopePredicate
    }

    static func reads(first: Int64, second: Int64) -> [Read] {
        let filters: [(String, MediaFilter)] = [
            ("none", .all), ("video", MediaFilter(kinds: [.video])), ("imageRaw", MediaFilter(kinds: [.image, .raw])),
            ("heif", MediaFilter(fileTypes: [FilterFileType(kind: .image, format: MediaFormatToken(rawValue: "HEIF"))])),
            ("notRated", MediaFilter(choices: [.notRated])), ("liked", MediaFilter(choices: [.liked])),
            ("likedOrNotRated", MediaFilter(choices: [.liked, .notRated])), ("disliked", MediaFilter(choices: [.disliked])),
        ]
        let scopes: [(String, CatalogScopePredicate)] = [
            ("allMedia", CatalogScopePredicate(rootIDs: [first, second], showsOneCopy: true, holdsEveryCopyRoot: true)),
            ("library", CatalogScopePredicate(rootIDs: [first])),
        ]
        let sorts: [MediaSortOrder] = [.dateNewest, .dateOldest, .filenameAscending, .filenameDescending, .sizeLargest, .sizeSmallest]
        return scopes.flatMap { scopeName, scope in
            filters.flatMap { filterName, filter in
                sorts.map { sort in
                    Read(
                        name: "\(scopeName).\(filterName).\(sort.field.rawValue)-\(sort.direction.rawValue)",
                        descriptor: CatalogQueryDescriptor(scope: .allMedia, filter: filter, sort: sort),
                        scope: scope
                    )
                }
            }
        }
    }

    /// The corpus in two roots: every name in the first root's two folders, and in the second
    /// root's one; sizes that tie, a size the filesystem did not report, choices, and one row
    /// waiting for the Trash, which no order shows.
    static func insertCorpus(_ db: Database) throws -> (Int64, Int64) {
        try db.execute(sql: "INSERT INTO library_root (path) VALUES ('/generated/first'), ('/generated/second')")
        let first = db.lastInsertedRowID - 1
        let second = db.lastInsertedRowID
        var index = 0
        for (rootID, folders) in [(first, ["2024/a/", "2024/b/"]), (second, [""])] {
            for folder in folders {
                for name in names {
                    let (type, kind, format) = Self.type(of: name)
                    let choice = ["notRated", "liked", "notRated", "disliked", "notRated"][index % 5]
                    try db.execute(
                        sql: """
                        INSERT INTO media_asset (
                            library_root_id, relative_path, name_sort_key, name, content_type_identifier, kind, format,
                            byte_size, created_at_unix, content_modified_at_unix, media_choice, pending_trash_batch_unix_ms,
                            capture_wall_compact
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            rootID, folder + name, MediaSortKey.naturalKey(name), name, type, kind, format,
                            index % 7 == 6 ? nil : Int64(1000 + (index % 4) * 10), 1_600_000_000.0 + Double(index % 9) * 3600,
                            1_600_000_100.0, choice, index == 11 ? 1_700_000_000_000 : nil,
                            // Capture walls that tie, and every ninth row without one.
                            index % 9 == 8 ? nil : Int64(20_240_601_120_000 + (index % 6) * 100),
                        ]
                    )
                    index += 1
                }
            }
        }
        return (first, second)
    }

    static func type(of name: String) -> (String, String, String) {
        let ext = (name as NSString).pathExtension.lowercased()
        return switch ext {
        case "heic": ("public.heic", "image", "HEIF")
        case "mov": ("com.apple.quicktime-movie", "video", "MOV")
        case "mp4": ("public.mpeg-4", "video", "MP4")
        case "arw": ("com.sony.arw-raw-image", "raw", "ARW")
        case "dng": ("com.adobe.raw-image", "raw", "DNG")
        default: ("public.jpeg", "image", "JPEG")
        }
    }

    static func rows(_ descriptor: CatalogQueryDescriptor, _ scope: CatalogScopePredicate, _ db: Database) throws
        -> [CatalogQueryGateway.OrderedAssetIDRow]
    {
        try CatalogQueryGateway.fetchOrderedAssetIDRows(descriptor: descriptor, scope: scope, db: db)
    }

    static func ids(_ descriptor: CatalogQueryDescriptor, _ scope: CatalogScopePredicate, _ db: Database) throws -> [Data] {
        try rows(descriptor, scope, db).map { key($0.libraryRootID, $0.relativePath.rawValue) }
    }

    /// A row's identity as its bytes: Swift compares strings by canonical equivalence, so a
    /// name written composed and the same name decomposed are equal strings and distinct rows.
    static func key(_ rootID: Int64, _ path: String) -> Data {
        Data("\(rootID)/\(path)".utf8)
    }

    /// Every row as the table holds it, read without any index.
    static func tableRows(_ db: Database) throws -> [Row] {
        try GRDB.Row.fetchAll(db, sql: """
        SELECT library_root_id, relative_path, name_sort_key, best_kind, best_format, byte_size, best_capture_local,
               media_choice, pending_trash_batch_unix_ms IS NULL AND awaiting_presence = 0 AND hidden_by_source = 0 AS shown
        FROM media_asset NOT INDEXED
        """).map { row in
            Row(
                rootID: row[0], path: row[1], key: row[2], kind: row[3], format: row[4], size: row[5],
                capture: row[6], choice: row[7], shown: row[8]
            )
        }
    }

    /// The order a plain reading of the table gives: the scope's shown rows that pass the
    /// filter, by the sort's key compared as SQLite compares it (bytes, NULL first ascending),
    /// then by root and path ascending.
    static func expected(_ table: [Row], _ descriptor: CatalogQueryDescriptor, _ scope: CatalogScopePredicate) -> [Data] {
        let filter = descriptor.filter
        let kept = table.filter { row in
            guard row.shown, scope.rootIDs.contains(row.rootID) else { return false }
            var media = filter.kinds.isEmpty && filter.fileTypes.isEmpty
            media = media || filter.kinds.contains { $0.rawValue == row.kind }
            media = media || filter.fileTypes.contains { $0.kind.rawValue == row.kind && $0.format.rawValue == row.format }
            let chosen = filter.choices.isEmpty || filter.choices.contains { $0.rawValue == row.choice }
            return media && chosen
        }
        let sort = descriptor.effectiveSort
        let descending = sort.direction == .descending
        func keyOrder(_ lhs: Row, _ rhs: Row) -> Bool? {
            switch sort.field {
            case .name:
                let left = Array(lhs.key.utf8), right = Array(rhs.key.utf8)
                return left == right ? nil : (descending ? right.lexicographicallyPrecedes(left) : left.lexicographicallyPrecedes(right))
            case .size:
                if (lhs.size == nil) != (rhs.size == nil) {
                    return lhs.size != nil
                }
                guard let left = lhs.size, let right = rhs.size, left != right else { return nil }
                return descending ? left > right : left < right
            case .bestDate, .likeness:
                if lhs.capture == rhs.capture {
                    return nil
                }
                guard let left = lhs.capture else { return !descending }
                guard let right = rhs.capture else { return descending }
                return descending ? left > right : left < right
            }
        }
        return kept.sorted { lhs, rhs in
            if let order = keyOrder(lhs, rhs) {
                return order
            }
            if lhs.rootID != rhs.rootID {
                return lhs.rootID < rhs.rootID
            }
            return Array(lhs.path.utf8).lexicographicallyPrecedes(Array(rhs.path.utf8))
        }.map { key($0.rootID, $0.path) }
    }
}
