import CoreGraphics
import Foundation
import GRDB

// Shared persistence value types used by `CatalogStore`, `CatalogQueryGateway`,
// and `EnrichmentClaimGateway`. Free (not nested under `CatalogStore`) so the
// gateways depend on SQL/mapping types rather than the actor type itself.
//
// SQLite row IDs stay confined to these stored records. Product identity remains
// `LibraryRootPath` / `MediaAssetID`; a row ID is only the compact foreign key.

/// What writing one observed file did to its row (`CatalogStore.upsertScannedFile`).
nonisolated enum ScannedFileUpsert: Equatable, Sendable {
    case unchanged
    /// A row that did not exist: it carries nothing Otos derives yet — no metadata (so
    /// no Live Photo pairing key), digest, rendering, faces, place or embedding.
    case inserted
    /// A row that existed, whose filesystem facts, presence or path changed.
    case updated
}

/// The rows one write changed, split by whether they existed before it. A write that
/// only inserted rows changed nothing any derived owner reads, so it is announced as
/// `.assetsAdded` and only what lists rows (the window, enrichment) takes it up; a change
/// to an existing row's filesystem facts, presence or path can move any fact derived from
/// it, so it is `.changed(.all)`.
nonisolated struct CatalogRowChanges: Equatable, Sendable {
    private(set) var inserted = 0
    private(set) var updated = 0

    mutating func record(_ upsert: ScannedFileUpsert) {
        switch upsert {
        case .unchanged:
            break
        case .inserted:
            inserted += 1
        case .updated:
            updated += 1
        }
    }

    /// Existing rows changed in a way `ScannedFileUpsert` does not describe: a source's
    /// hide, a reported size, a purge.
    mutating func recordUpdated(_ count: Int) {
        updated += count
    }

    var isEmpty: Bool {
        inserted == 0 && updated == 0
    }

    /// The change to announce, nil when the write changed nothing.
    var notification: CatalogStoreChange? {
        if isEmpty {
            nil
        } else if updated == 0 {
            .assetsAdded
        } else {
            .changed(.all)
        }
    }
}

nonisolated struct StoredAsset {
    let libraryRootID: Int64
    let relativePath: MediaRelativePath
    let name: String?
    let contentTypeIdentifier: String?
    let byteSize: Int64?
    let createdAt: Date?
    let contentModifiedAt: Date?
    var thumbnailPath: String?
    var captureLocalTime: CaptureLocalTime?
    var bestKind: MediaKind?
    var bestFormat: MediaFormatToken?
    var durationSeconds: Double?
    var metadataSourceSize: Int64?
    var metadataSourceMTimeSeconds: Int?
    var renderedSourceSize: Int64?
    var renderedSourceMTimeSeconds: Int?
    var contentHash: ContentDigest?
    var contentHashSourceSize: Int64?
    var contentHashSourceMTimeSeconds: Int?
    var facesSourceSize: Int64?
    var facesSourceMTimeSeconds: Int?
    var mediaChoice: MediaChoice = .default
}

/// Store-owned, one-settlement snapshot of a source row's products and the stamps that say
/// which bytes each was made from. It is never persisted as a second record and contains no
/// source history, claims, or identity.
nonisolated struct ReusableEnrichmentOverlay: Equatable, Sendable {
    /// The one stored timestamp truth, with its kind and format. The capture instant the
    /// destination row sorts by is projected from it at the write.
    let metadata: EnrichedMetadata?
    let metadataSourceSize: Int64?
    let metadataSourceMTimeSeconds: Int?
    let renderedSourceSize: Int64?
    let renderedSourceMTimeSeconds: Int?
    /// The edit revision the source's rendering was drawn with.
    let renderedRevision: Int64
    /// The source's saved edit, which the copy carries.
    let recipe: StoredEditRecipe?
    let thumbnailPath: String?
    let previewPath: String?

    /// Whether the metadata was read from the bytes `(size, mtime-seconds)` names.
    func metadataCurrent(size: Int64, mtimeSeconds: Int) -> Bool {
        metadata != nil && metadataSourceSize == size && metadataSourceMTimeSeconds == mtimeSeconds
    }

    /// Whether the rendering was made from the bytes `(size, mtime-seconds)` names.
    func renderingCurrent(size: Int64, mtimeSeconds: Int) -> Bool {
        renderedSourceSize == size && renderedSourceMTimeSeconds == mtimeSeconds
    }
}

nonisolated struct StoredTileDetail {
    let libraryRootID: Int64
    let relativePath: MediaRelativePath
    let byteSize: Int64?
    var thumbnailPath: String?
    var previewPath: String?
    var nativePixelSize: CGSize?
    var editRecipe: EditRecipe?
    var renderedRevision: Int64 = 0
    var bestKind: MediaKind?
    var durationSeconds: Double?
    var renderedSourceSize: Int64?
    var renderedSourceMTimeSeconds: Int?
    var mediaChoice: MediaChoice = .default
    var copyDigest: ContentDigest?
}

nonisolated struct SQLQuery {
    let sql: String
    let arguments: StatementArguments
}

/// Every row dimension a `SidebarSelection` constrains, resolved once into one
/// value that all scoped reads consume.
///
/// A scope is not "a set of roots": an Imports row narrows by root *and* by batch
/// stamp. Splitting those dimensions across call sites is what let ordered IDs
/// honor batch membership while the count and filter-option queries silently did
/// not — an import batch whose rows were all excluded by an active filter then
/// reported zero unfiltered rows and rendered as an empty library instead of an
/// empty filter match. `RootRegistry.scopePredicate` is the only producer and no
/// read takes bare root IDs, so a new query cannot honor one dimension and forget
/// the other.
nonisolated struct CatalogScopePredicate: Equatable {
    /// What a scope requires of a row's stored primary location (ADR 0040).
    enum LocationConstraint: Equatable {
        /// Location plays no part.
        case any
        /// The row has a primary location: the Places map.
        case located
        /// The row's primary location lies in this box: the grid under the map.
        case within(MapArea)
    }

    /// Catalog roots the scope admits, ascending. Already narrowed to the kinds and
    /// availability the selection allows.
    /// What a scope requires of a row's content digest (ADR 0042).
    enum ContentConstraint: Equatable {
        case any
        /// The row's current digest is shared by another visible row — one in its own root
        /// while Duplicates compares within each library: Duplicates.
        case duplicated(DuplicatesReach)
        /// The row's current digest is exactly this: one group under Duplicates.
        case identical(ContentDigest)
        /// The row is one of these, by root row id and path: a same-photo group under
        /// Duplicates, or a stack opened from the map.
        case members([MemberKey])
        /// The row holds a face with a person: People (ADR 0047).
        case withPerson
        /// The row holds a face of this person, by row id: one person under People.
        case person(Int64)
    }

    struct MemberKey: Equatable, Encodable {
        let rootID: Int64
        let relativePath: String

        /// `[rootID, path]`: one element of the members read's argument.
        func encode(to encoder: any Encoder) throws {
            var row = encoder.unkeyedContainer()
            try row.encode(rootID)
            try row.encode(relativePath)
        }

        /// `[[rootID, path], …]`, the one argument the members read takes.
        static func json(_ keys: [MemberKey]) throws -> String {
            try String(decoding: JSONEncoder().encode(keys), as: UTF8.self)
        }
    }

    /// What a scope requires of a row's day bucket (ADR 0049).
    enum DateConstraint: Equatable {
        case any
        /// The row's day bucket has this day's month and day in an earlier year — or, when
        /// no row of the scope does, this day of the month in an earlier month: On This
        /// Day. The gateway decides which inside the read (`AnniversaryMatch`).
        case anniversary(CalendarDay)
    }

    let rootIDs: [Int64]
    /// Import-batch stamp the scope requires, when the selection is an Imports row.
    let importBatchUnixMs: Int64?
    let location: LocationConstraint
    let content: ContentConstraint
    let date: DateConstraint
    /// The scope shows one copy of each set of identical copies
    /// (`SidebarSelection.showsOneCopy`, ADR 0054).
    var showsOneCopy: Bool
    /// Every library and account root is in the scope, so a row's best copy is always in
    /// reach and the read need not ask whether a better copy is (ADR 0054). False unless the
    /// registry proved it: a scope that misses a root asks.
    var holdsEveryCopyRoot: Bool

    /// On This Day's scope, which picks its photos (`OnThisDayPicks`).
    var isAnniversary: Bool {
        if case .anniversary = date {
            return true
        }
        return false
    }

    init(
        rootIDs: [Int64],
        importBatchUnixMs: Int64? = nil,
        location: LocationConstraint = .any,
        content: ContentConstraint = .any,
        date: DateConstraint = .any,
        showsOneCopy: Bool = false,
        holdsEveryCopyRoot: Bool = false
    ) {
        self.rootIDs = rootIDs
        self.importBatchUnixMs = importBatchUnixMs
        self.location = location
        self.content = content
        self.date = date
        self.showsOneCopy = showsOneCopy
        self.holdsEveryCopyRoot = holdsEveryCopyRoot
    }

    /// Whether reads over this scope join `asset_metadata`, and so can carry each
    /// row's coordinate.
    var requiresLocation: Bool {
        location != .any
    }

    /// No root can satisfy the scope, so every read over it is empty without
    /// touching SQLite.
    var selectsNothing: Bool {
        rootIDs.isEmpty
    }

    static let nothing = CatalogScopePredicate(rootIDs: [])
}

// MARK: - Candidate walks (plan 0116)

/// The last row a walk over the asset key read; the next page starts after it.
nonisolated struct AssetKeyCursor: Equatable, Sendable {
    let rootID: Int64
    let relativePath: String
}

/// The last row a newest-first walk read, in the capture order's own terms
/// (`best_capture_local DESC, library_root_id, relative_path`).
nonisolated struct CaptureOrderCursor: Equatable, Sendable {
    let captureLocal: Double?
    let rootID: Int64
    let relativePath: String
}

/// One page of a candidate walk, and where the next page starts: nil when this page read
/// the walk's last row. A page can hold fewer candidates than it read rows (a row the
/// caller passes over), and none, while the walk goes on.
nonisolated struct CandidatePage<Candidate: Sendable, Cursor: Sendable>: Sendable {
    let candidates: [Candidate]
    let next: Cursor?
}

extension CandidatePage: Equatable where Candidate: Equatable, Cursor: Equatable {}

/// How a background owner finds what it owes (plan 0116 stage 1): **one drain is one walk**.
/// The owner keeps the cursor of the walk it is in and asks for the page after it, so a drain
/// visits each row once rather than starting from the first row for every page. A row that
/// becomes owed behind the cursor is found by the next walk, which the change that made it
/// owed starts (ADR 0032: the change rings the owner's doorbell).
///
/// - A key walk visits each root on its own seek, `library_root_id = ? AND relative_path > ?`:
///   a row-value cursor over `library_root_id IN (…)` seeks only on the root and walks it from
///   its first row again (`docs/research/2026-11-16-plan-0116-due-diligence.md` §3).
/// - A capture walk reads the capture order newest first, as the window's date order does,
///   through its index, in three phases: the rows tied at the cursor's capture time after its
///   key, then every older capture time, then the rows with none (SQLite orders NULL last when
///   descending). Each phase is a range of the index, so no page sorts.
nonisolated enum CandidateWalk {
    /// The index a capture walk reads: the window's newest-first date order over every root.
    static let captureIndex = "idx_media_asset_best_capture_global_desc"

    /// Reads at most `limit` rows from `after` on, one root at a time, in `rootIDs`'s order.
    /// `sql` binds, in order: the root, the path its rows start after, then `arguments`, then
    /// the limit; it selects `relative_path`.
    static func keyPage(
        sql: String,
        rootIDs: [Int64],
        after cursor: AssetKeyCursor?,
        limit: Int,
        arguments: StatementArguments = StatementArguments(),
        db: Database
    ) throws -> (rows: [Row], next: AssetKeyCursor?) {
        var rows: [Row] = []
        for rootID in rootIDs.sorted() where rootID >= (cursor?.rootID ?? Int64.min) {
            let after = cursor?.rootID == rootID ? cursor?.relativePath ?? "" : ""
            let page = try Row.fetchAll(
                db,
                sql: sql,
                arguments: [rootID, after] + arguments + [limit - rows.count]
            )
            rows += page
            if rows.count == limit, let last = page.last {
                return (rows, AssetKeyCursor(rootID: rootID, relativePath: last["relative_path"]))
            }
        }
        return (rows, nil)
    }

    /// Reads at most `limit` rows from `after` on, newest capture first. `sql` builds the
    /// statement from the phase's position term over `row` and its `ORDER BY`; it binds
    /// `arguments` first, then the position's, then the limit, and selects
    /// `best_capture_local`, `library_root_id` and `relative_path` of `row`.
    static func capturePage(
        row: String,
        after cursor: CaptureOrderCursor?,
        limit: Int,
        arguments: StatementArguments,
        db: Database,
        sql: (_ position: String, _ order: String) -> String
    ) throws -> (rows: [Row], next: CaptureOrderCursor?) {
        let key = "(\(row).library_root_id, \(row).relative_path) > (?, ?)"
        let byKey = "ORDER BY \(row).library_root_id, \(row).relative_path"
        let newestFirst = "ORDER BY \(row).best_capture_local DESC, \(row).library_root_id, \(row).relative_path"
        let undated = "\(row).best_capture_local IS NULL AND \(key)"
        let phases: [(position: String, order: String, arguments: StatementArguments)] = switch cursor {
        case nil:
            [
                ("\(row).best_capture_local IS NOT NULL", newestFirst, []),
                (undated, byKey, [Int64.min, ""]),
            ]
        case let cursor? where cursor.captureLocal == nil:
            [(undated, byKey, [cursor.rootID, cursor.relativePath])]
        case let cursor?:
            [
                ("\(row).best_capture_local = ? AND \(key)", byKey, [cursor.captureLocal, cursor.rootID, cursor.relativePath]),
                ("\(row).best_capture_local < ?", newestFirst, [cursor.captureLocal]),
                (undated, byKey, [Int64.min, ""]),
            ]
        }
        var rows: [Row] = []
        for phase in phases {
            rows += try Row.fetchAll(
                db,
                sql: sql(phase.position, phase.order),
                arguments: arguments + phase.arguments + [limit - rows.count]
            )
            if rows.count == limit, let last = rows.last {
                return (rows, CaptureOrderCursor(
                    captureLocal: last["best_capture_local"], rootID: last["library_root_id"], relativePath: last["relative_path"]
                ))
            }
        }
        return (rows, nil)
    }
}
