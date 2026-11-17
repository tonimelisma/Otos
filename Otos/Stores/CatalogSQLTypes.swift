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

/// The rows one write changed, split by whether they existed before it. A new row carries
/// nothing Otos derives yet, so a write that only inserted rows is announced as
/// `.assetsAdded` and only what lists rows (the window, enrichment) takes it up — unless it
/// came with a fact an owner derives from, which is announced as what it changed, naming
/// those rows: a source's digest that makes the new row a copy of another (`.copies`,
/// `recordInserted(_:carrying:)`). A change to an existing row's filesystem facts, presence
/// or path can move any fact derived from it, so it is `.changed(.all)`, naming the rows
/// when every one of them is known (`CatalogChangedRows`).
nonisolated struct CatalogRowChanges: Equatable, Sendable {
    private(set) var inserted = 0
    /// The existing rows changed, by asset.
    private(set) var updatedRows: Set<MediaAssetID> = []
    /// Existing rows changed that the write cannot name (a size reported by source item).
    private(set) var unnamedUpdates = 0
    /// What new rows carried that an owner derives from, and those rows.
    private(set) var insertedFacts: CatalogChangedFacts = []
    private(set) var insertedFactRows: Set<MediaAssetID> = []

    var updated: Int {
        updatedRows.count + unnamedUpdates
    }

    mutating func record(_ upsert: ScannedFileUpsert, of id: MediaAssetID) {
        switch upsert {
        case .unchanged:
            break
        case .inserted:
            inserted += 1
        case .updated:
            updatedRows.insert(id)
        }
    }

    /// `id`'s existing row changed in a way `ScannedFileUpsert` does not describe (a source's
    /// hide or digest, a purge), when `count`, the statement's changes, says it did.
    mutating func recordUpdated(_ count: Int, of id: MediaAssetID) {
        if count > 0 {
            updatedRows.insert(id)
        }
    }

    /// A deleted row and the Live Photo partners it leaves (`AssetRowDeletion`).
    mutating func recordDeleted(_ deletion: AssetRowDeletion, of relativePath: MediaRelativePath, in root: LibraryRootPath) {
        updatedRows.formUnion(deletion.ids(of: relativePath, in: root))
    }

    /// `id`'s new row was written with `facts` an owner derives from (a digest that made it a
    /// copy); nothing when `facts` is empty.
    mutating func recordInserted(_ id: MediaAssetID, carrying facts: CatalogChangedFacts) {
        guard !facts.isEmpty else { return }
        insertedFacts.formUnion(facts)
        insertedFactRows.insert(id)
    }

    /// Existing rows changed that the write does not name.
    mutating func recordUnnamedUpdates(_ count: Int) {
        unnamedUpdates += count
    }

    var isEmpty: Bool {
        inserted == 0 && updated == 0
    }

    /// The changes to announce, in order; none when the write changed nothing.
    var notifications: [CatalogStoreChange] {
        if isEmpty {
            []
        } else if updated == 0 {
            insertedFacts.isEmpty ? [.assetsAdded] : [.assetsAdded, .changed(insertedFacts, rows: .rows(insertedFactRows))]
        } else {
            [.changed(.all, rows: unnamedUpdates == 0 ? .rows(updatedRows.union(insertedFactRows)) : .unnamed)]
        }
    }
}

/// What deleting one asset row changed (`CatalogStore.deleteAssetRow`): whether a row went,
/// and the Live Photo partners it leaves — a movie no longer paired, or its still — whose
/// pairing the deletion moved. An owner keeping a memory per asset cannot find them from a
/// row that is gone, so a deletion that names its rows names these too.
nonisolated struct AssetRowDeletion: Equatable, Sendable {
    let deleted: Bool
    let partners: [MediaRelativePath]

    static let nothing = AssetRowDeletion(deleted: false, partners: [])

    /// The deleted row and its partners in `root`, nothing when no row went.
    func ids(of relativePath: MediaRelativePath, in root: LibraryRootPath) -> Set<MediaAssetID> {
        guard deleted else { return [] }
        return Set(([relativePath] + partners).map { MediaAssetID(libraryRootPath: root, relativePath: $0) })
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

/// The asset columns a derived product's "is it owed" test reads (v65): what makes a row
/// visible and a Live Photo's movie (`LivePhotoSQL`), the stored thumbnail's and preview's
/// identity (`StoredThumbnailSQL`, the text and description sources), and what a description
/// waits for (`PreviewFaceSQL`). `indexName` holds them in the newest-first order, so the
/// search embedding, text and description walks, and the search index's reconcile, test and
/// stamp every row from the index and read no 2 KB asset row.
nonisolated enum ProductStampSQL {
    static let indexName = "idx_media_asset_product_stamps"

    static let columns = """
    pending_trash_batch_unix_ms, trash_path, kind, best_kind, content_identifier, parent_path, thumbnail_path, \
    preview_path, rendered_revision, rendered_source_size, rendered_source_mtime, source_products_size, \
    source_products_mtime, faces_source_size, faces_source_mtime, edit_revision
    """
}

/// An Immich account's rows owed their source's own thumbnail and preview (ADR 0046 §7): the
/// condition of `owedIndexName` (v65), which `CatalogStore.sourceProductCandidates` walks, so
/// an account whose images are current reads no row.
nonisolated enum SourceProductsSQL {
    static let owedIndexName = "idx_media_asset_source_products_owed"

    static let owedPredicate = """
    source_item_id IS NOT NULL
      AND hidden_by_source = 0
      AND byte_size IS NOT NULL
      AND \(CatalogStore.showsSourceProductsSQL)
      AND source_products_absent = 0
      AND (
          source_products_size IS NOT byte_size
          OR source_products_mtime IS NOT CAST(content_modified_at_unix AS INTEGER)
      )
    """

    /// One root's owed rows in path order after a path; binds the root, the path, the limit.
    static let candidatesSQL = """
    SELECT relative_path, source_item_id, kind, byte_size,
           CAST(content_modified_at_unix AS INTEGER) AS mtime
    FROM media_asset INDEXED BY \(owedIndexName)
    WHERE library_root_id = ?
      AND relative_path > ?
      AND \(owedPredicate)
    ORDER BY relative_path
    LIMIT ?
    """

    /// The owed rows among `count` paths of one root, by key; binds the root, then the paths.
    /// The rows on screen are asked for ahead of the walk (`ImmichCatalogSync.fetchVisibleProducts`).
    /// Pinned to the key: left to itself SQLite ranged the root's source-item index, every
    /// row of the account, and tested each against the paths, 406 ms for 120 rows on the
    /// owner's 147,293 against 24 ms by key (`docs/research/2026-11-16-idle-disk-read-attribution.md`).
    static func visibleCandidatesSQL(count: Int) -> String {
        """
        SELECT relative_path, source_item_id, kind, byte_size,
               CAST(content_modified_at_unix AS INTEGER) AS mtime
        FROM media_asset INDEXED BY sqlite_autoindex_media_asset_1
        WHERE library_root_id = ?
          AND relative_path IN (\(Array(repeating: "?", count: count).joined(separator: ",")))
          AND \(owedPredicate)
        """
    }
}

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
    /// The index a capture walk reads: the newest-first order over every root, with every
    /// column a walk tests and stamps a row by (`ProductStampSQL`).
    static let captureIndex = ProductStampSQL.indexName

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
        rows.reserveCapacity(limit)
        for rootID in rootIDs.sorted() where rootID >= (cursor?.rootID ?? Int64.min) {
            let after = cursor?.rootID == rootID ? cursor?.relativePath ?? "" : ""
            try appendPage(sql: sql, arguments: [rootID, after] + arguments + [limit - rows.count], to: &rows, db: db)
            if rows.count == limit, let last = rows.last {
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
        rows.reserveCapacity(limit)
        for phase in phases {
            try appendPage(sql: sql(phase.position, phase.order), arguments: arguments + phase.arguments + [limit - rows.count], to: &rows, db: db)
            if rows.count == limit, let last = rows.last {
                return (rows, CaptureOrderCursor(
                    captureLocal: last["best_capture_local"], rootID: last["library_root_id"], relativePath: last["relative_path"]
                ))
            }
        }
        return (rows, nil)
    }

    /// Appends one page's rows to `rows`, which holds room for the whole page: no array is
    /// grown and none made per page. Each walk's few statement texts are prepared once per
    /// connection.
    private static func appendPage(sql: String, arguments: StatementArguments, to rows: inout [Row], db: Database) throws {
        let cursor = try Row.fetchCursor(db.cachedStatement(sql: sql), arguments: arguments)
        while let row = try cursor.next() {
            rows.append(row.copy())
        }
    }
}

/// One media row's filesystem facts as a scan upsert compares them: the values it binds,
/// with each date at the whole second the upsert's `WHERE` compares
/// (`CatalogStore.upsertScannedFile`). Text compares byte for byte, as SQLite does: Swift's
/// `String ==` would call a precomposed and a decomposed spelling equal.
nonisolated struct ScanFactValues: Sendable {
    let pathKey: String?
    let nameSortKey: String?
    let name: String?
    let contentTypeIdentifier: String?
    let kind: String?
    let format: String?
    let byteSize: Int64?
    let createdSecond: Int64?
    let modifiedSecond: Int64?
    let fileIdentifier: Int64?

    /// The facts a scan upsert of `file` would write.
    init(_ file: ScannedMediaFile, capabilities: VolumeNamespaceCapabilities) {
        pathKey = FilesystemNamespaceSemantics.nameKey(relativePath: file.relativePath, capabilities: capabilities).rawValue
        nameSortKey = ScanFactValues.nameSortKey(of: file)
        name = file.name
        contentTypeIdentifier = file.contentTypeIdentifier
        kind = file.kind?.rawValue
        format = file.format?.rawValue
        byteSize = file.byteSize
        createdSecond = ScanFactValues.wholeSecond(file.createdAt?.timeIntervalSince1970)
        modifiedSecond = ScanFactValues.wholeSecond(file.contentModifiedAt?.timeIntervalSince1970)
        fileIdentifier = file.fileIdentifier.map { Int64(bitPattern: $0) }
    }

    init(
        pathKey: String?,
        nameSortKey: String?,
        name: String?,
        contentTypeIdentifier: String?,
        kind: String?,
        format: String?,
        byteSize: Int64?,
        createdSecond: Int64?,
        modifiedSecond: Int64?,
        fileIdentifier: Int64?
    ) {
        self.pathKey = pathKey
        self.nameSortKey = nameSortKey
        self.name = name
        self.contentTypeIdentifier = contentTypeIdentifier
        self.kind = kind
        self.format = format
        self.byteSize = byteSize
        self.createdSecond = createdSecond
        self.modifiedSecond = modifiedSecond
        self.fileIdentifier = fileIdentifier
    }

    /// The name a row sorts by: its file name when the filesystem reported none.
    static func nameSortKey(of file: ScannedMediaFile) -> String {
        MediaSortKey.naturalKey(file.name ?? file.relativePath.fileName)
    }

    /// `CAST(seconds AS INTEGER)`: toward zero.
    static func wholeSecond(_ seconds: Double?) -> Int64? {
        seconds.flatMap { Int64(exactly: $0.rounded(.towardZero)) }
    }

    func matches(_ other: ScanFactValues) -> Bool {
        Self.sameBytes(pathKey, other.pathKey)
            && Self.sameBytes(nameSortKey, other.nameSortKey)
            && Self.sameBytes(name, other.name)
            && Self.sameBytes(contentTypeIdentifier, other.contentTypeIdentifier)
            && Self.sameBytes(kind, other.kind)
            && Self.sameBytes(format, other.format)
            && byteSize == other.byteSize
            && createdSecond == other.createdSecond
            && modifiedSecond == other.modifiedSecond
            && fileIdentifier == other.fileIdentifier
    }

    static func sameBytes(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs?, rhs?):
            lhs.utf8.elementsEqual(rhs.utf8)
        default:
            false
        }
    }
}

/// One companion row's facts as the companion upsert compares them (`upsertCompanion`).
nonisolated struct ScanCompanionFactValues: Sendable {
    let pathKey: String?
    let kind: String?
    let byteSize: Int64?
    let modifiedSecond: Int64?

    init(_ companion: ScannedCompanionFile, capabilities: VolumeNamespaceCapabilities) {
        pathKey = FilesystemNamespaceSemantics.nameKey(relativePath: companion.relativePath, capabilities: capabilities).rawValue
        kind = companion.kind.rawValue
        byteSize = companion.byteSize
        modifiedSecond = ScanFactValues.wholeSecond(companion.contentModifiedAt?.timeIntervalSince1970)
    }

    init(pathKey: String?, kind: String?, byteSize: Int64?, modifiedSecond: Int64?) {
        self.pathKey = pathKey
        self.kind = kind
        self.byteSize = byteSize
        self.modifiedSecond = modifiedSecond
    }

    func matches(_ other: ScanCompanionFactValues) -> Bool {
        ScanFactValues.sameBytes(pathKey, other.pathKey)
            && ScanFactValues.sameBytes(kind, other.kind)
            && byteSize == other.byteSize
            && modifiedSecond == other.modifiedSecond
    }
}

/// What the catalog held for a scan pass's scope (a root, or one subtree of it) as the pass
/// began, read once on a background lane before the walk (`fetchScanBaseline`). A file the
/// walk observes with the facts its row already holds needs no write, so only the files
/// that differ reach the writer, and a pass over an unchanged scope takes the writer for
/// nothing. The baseline only says what may be skipped: deletion is still decided from the
/// rows the pass's end reads, and the upsert's own `WHERE` still guards every write.
nonisolated struct ScanBaseline: Sendable {
    /// Settled rows only: a row awaiting presence or held in the Trash is absent, so
    /// observing it always writes.
    let media: [MediaRelativePath: ScanFactValues]
    let companions: [MediaRelativePath: ScanCompanionFactValues]
    let capabilities: VolumeNamespaceCapabilities

    /// The files of `batch` whose row is missing or holds other facts.
    func filesNeedingWrite(_ batch: [ScannedMediaFile]) -> [ScannedMediaFile] {
        batch.filter { file in
            guard let stored = media[file.relativePath] else {
                return true
            }
            return !stored.matches(ScanFactValues(file, capabilities: capabilities))
        }
    }

    /// Whether the companions a pass observed are exactly the ones the catalog holds for its
    /// scope, with the same facts. Pairing reads the companions and the scope's media rows,
    /// so a pass that changed no media row and observed matching companions would write
    /// back what is there.
    func companionsMatch(_ observed: [ScannedCompanionFile]) -> Bool {
        guard observed.count == companions.count else {
            return false
        }
        return observed.allSatisfy { companion in
            companions[companion.relativePath]?.matches(ScanCompanionFactValues(companion, capabilities: capabilities)) == true
        }
    }
}
