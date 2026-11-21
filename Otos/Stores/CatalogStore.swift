import CoreGraphics
import Foundation
import GRDB
import MediaMetadata
import OSLog
import Synchronization

/// Store notifications remain cheap invalidation signals: each says which kinds of fact a
/// write touched, never the facts themselves. Root removal also carries its typed path,
/// because a remove followed by a same-path add can otherwise coalesce into a queried state
/// where Projection cannot observe that the selected library instance disappeared.
nonisolated enum CatalogStoreChange: Equatable, Sendable {
    /// Rows were inserted and nothing else changed (`CatalogRowChanges`). They carry
    /// nothing derived yet, so only the window and enrichment have new input; an owner
    /// of derived facts (duplicates, people, search, places, faces, render signatures)
    /// hears them when enrichment writes what it derives from them.
    case assetsAdded
    /// Facts of rows or roots that existed changed; `CatalogChangedFacts` says which kinds, and
    /// `rows` which assets' rows, when the write can name them.
    case changed(CatalogChangedFacts, rows: CatalogChangedRows = .unnamed)
    case libraryRemoved(LibraryRootPath)

    /// The kinds of fact the change touched: added rows are a membership change, and a
    /// removed library may have held any fact.
    var facts: CatalogChangedFacts {
        switch self {
        case .assetsAdded: .membership
        case let .changed(facts, _): facts
        case .libraryRemoved: .all
        }
    }

    /// The assets whose rows the change touched, when it names them; a removed library's are
    /// not named.
    var rows: CatalogChangedRows {
        switch self {
        case .assetsAdded, .libraryRemoved: .unnamed
        case let .changed(_, rows): rows
        }
    }

    /// Whether this change can move what an owner of a derived product reads, given its
    /// `inputs` (`CatalogOwnerInputs`). Rows only added carry nothing derived from them yet, so
    /// they move none; the owner hears them when enrichment writes what it derives. A root's own
    /// order or activity (`CatalogChangedRows.none`) moves no row and no root's reach, so it
    /// moves none either.
    func touches(_ inputs: CatalogChangedFacts) -> Bool {
        switch self {
        case .assetsAdded, .changed(_, rows: .none): false
        case let .changed(facts, _): !facts.isDisjoint(with: inputs)
        case .libraryRemoved: true
        }
    }
}

/// Which assets' rows one write changed or removed (ADR 0005, "Keyed re-reads"): what an owner that keeps
/// a memory per asset reconciles by key instead of reading the whole library again. A write
/// names the rows it wrote; a fact derived from rows it did not write (a Live Photo's pair, a
/// copy) is the owner's to resolve from them, except where the row it would resolve from is
/// gone: a deletion also names the Live Photo partners the deleted row leaves
/// (`AssetRowDeletion`).
///
/// Which rows are in reach is never a named change: a root that becomes available or
/// unavailable, or whose source stops or starts answering, changes what every read bound to
/// the roots read returns, so it is `unnamed`. A change that names no rows is `none`, which
/// only a root's own state takes (its order, a scan or listing starting or ending, a root
/// added with no rows yet, the Store's runtime work ending at its shutdown), and
/// `named` always names at least one (`CatalogNamedRows`), so "named, empty" cannot be said.
nonisolated enum CatalogChangedRows: Equatable, Sendable {
    /// The write does not name its rows (a root that went or came back, a migration, a bulk
    /// rewrite): any row may have changed.
    case unnamed
    /// No asset's row changed, nor which rows are in reach: a root's order or activity.
    case none
    case named(CatalogNamedRows)

    /// `ids` named, or `none` when there are none.
    static func rows(_ ids: Set<MediaAssetID>) -> CatalogChangedRows {
        CatalogNamedRows(ids).map(named) ?? .none
    }
}

/// The rows a change names: never none (`CatalogChangedRows.none` says that).
nonisolated struct CatalogNamedRows: Equatable, Sendable {
    let ids: Set<MediaAssetID>

    init?(_ ids: Set<MediaAssetID>) {
        guard !ids.isEmpty else { return nil }
        self.ids = ids
    }
}

/// What a background owner of a derived product wakes on (ADR 0005): the kinds of
/// fact whose writes could change what its candidate statements read, derived from their
/// SQL (`CatalogChangedFacts.read(by:)`), less the kinds its own writes name — no owner is rung
/// by its own write — and with the facts its SQL does not read but its work depends on (which
/// roots are reachable, held in the Store's memory and bound as arguments).
nonisolated struct CatalogOwnerInputs: Sendable {
    /// The owner's candidate statements, as it runs them (any placeholder count).
    let statements: [String]
    /// The kinds the owner's own writes name.
    let ownWrites: CatalogChangedFacts
    /// The kinds the owner's work depends on beyond its SQL.
    let beyondSQL: CatalogChangedFacts

    /// The inputs over `statements`' regions, read in `store`. A statement that cannot be
    /// prepared leaves the owner rung by every change, and is logged: waking too often is
    /// safe, and a missed wake would leave work owed.
    func facts(in store: CatalogStore, owner: String) async -> CatalogChangedFacts {
        do {
            let read = try await store.backgroundReads.factsRead(by: statements)
            let inputs = read.subtracting(ownWrites).union(beyondSQL)
            OtosLog.catalog.noticeOperation("owner.inputs", phase: "derived", fields: [
                "owner": owner, "inputs": inputs.diagnosticDescription,
            ])
            return inputs
        } catch {
            OtosLog.catalog.errorOperation("owner.inputs", phase: "failed", fields: [
                "owner": owner, "error": String(describing: error),
            ])
            return .all
        }
    }
}

/// What a catalog write touched, by the kind of fact (ADR 0005). The Store names it where
/// it writes, which is the one place that knows what changed; a reader repeats a read only
/// when a kind of fact the read depends on was touched (`CatalogProjectionReads`). A write
/// names the kinds it wrote, never more: a row's presence (`presence`), its file's facts
/// (`fileFacts`), its path (`movedRow`). A change that follows no write names the runtime
/// state it reports: a root's reach or its own state is `membership` (`CatalogChangedRows`),
/// and a Store that wrote and changed nothing sends nothing. Only a removed library's change
/// stands for every kind (`CatalogStoreChange.libraryRemoved`).
nonisolated struct CatalogChangedFacts: OptionSet, Hashable, Sendable {
    let rawValue: UInt32

    /// Which rows exist and are shown: rows added, removed, renamed or resized, moved to or
    /// from the Trash, seen or unseen by a source's attachment, hidden by a source; the
    /// roots, their order and availability; import batches.
    static let membership = CatalogChangedFacts(rawValue: 1 << 0)
    /// A row's best capture date: what the date order sorts by and On This Day matches.
    static let captureDate = CatalogChangedFacts(rawValue: 1 << 1)
    /// A row's best kind or format: what the filter offers and selects by.
    static let kindAndFormat = CatalogChangedFacts(rawValue: 1 << 2)
    /// What makes rows one item or one stack: the Live Photo and burst identifiers.
    static let grouping = CatalogChangedFacts(rawValue: 1 << 3)
    /// A row's location.
    static let location = CatalogChangedFacts(rawValue: 1 << 4)
    /// The names Maps gave the map's cells.
    static let placeNames = CatalogChangedFacts(rawValue: 1 << 5)
    /// Faces, and who they are.
    static let faces = CatalogChangedFacts(rawValue: 1 << 6)
    /// Which files are identical copies of which: the digests two or more copies share, and
    /// the shown copy and `has_copies` they decide. A digest no other copy holds is `.detail`.
    static let copies = CatalogChangedFacts(rawValue: 1 << 7)
    /// What search read of a row that decides where it shows: the labels On This Day
    /// leaves a photo out by.
    static let searchReadings = CatalogChangedFacts(rawValue: 1 << 8)
    /// What only a tile, a pane or enrichment reads: what enrichment owes and has claimed,
    /// its stamps, an original's locality. A write names it beside any other kind it
    /// touched, because a tile's detail refresh follows every change.
    static let detail = CatalogChangedFacts(rawValue: 1 << 9)
    /// The user's choices (Liked, Disliked) and stack keys: what the choices filter selects
    /// by, On This Day ranks by and a stack shows (ADR 0052).
    static let choices = CatalogChangedFacts(rawValue: 1 << 10)
    /// A row's stored images and what they show: its thumbnail (provisional or rendered), its
    /// preview, a video's face frames, and the edit they are rendered with. What a face's
    /// tile is cut from and what a render signature is current for.
    static let images = CatalogChangedFacts(rawValue: 1 << 11)
    /// What the bytes' metadata record says beyond the date, kind, grouping and location the
    /// other kinds name: dimensions, orientation, camera, lens and serial, the capture
    /// instant, the record itself. What the same-photo rule compares.
    static let mediaRecord = CatalogChangedFacts(rawValue: 1 << 12)
    /// What decides the stacks (ADR 0052) beyond which rows exist and the user's choices: the
    /// kind, capture time or burst identifier of a still that is, or was before the write, in
    /// a burst, or that shares its folder with a still it could pair with. A write that
    /// changes those facts of a row no stack can hold — an Immich asset alone in its folder, a
    /// video — does not name it, so the stacks stand
    /// (`EnrichmentOverlayBeforeWrite.changesStacks`).
    static let stacks = CatalogChangedFacts(rawValue: 1 << 13)
    /// What only Duplicates reads beyond which files are identical copies (ADR 0042): the reach
    /// it compares within, the copies kept together, the render signatures versions of one
    /// photo are found by, and a date, kind, record, image or edit of a row it compares or
    /// lists (`DuplicatesHoldSQL`), which each such write names beside its own kinds.
    static let duplicateFacts = CatalogChangedFacts(rawValue: 1 << 14)
    /// What search read of a row: its embedding, scene labels and text reading (ADR 0048).
    /// What a description waits for and is told (ADR 0053); the search index writes it.
    static let searchContent = CatalogChangedFacts(rawValue: 1 << 15)
    /// What a face's tile and its assignment read of a photo that holds a face (ADR 0047):
    /// its capture date, kind, grouping, or the stored images a tile is cut from. Named beside
    /// those kinds only when a written row holds a face, so a new photo's date, a render of a
    /// photo nobody is in, never wakes People (`PeopleAssignment.inputs`).
    static let faceTiles = CatalogChangedFacts(rawValue: 1 << 16)
    /// The People gallery's stored facts (`person_summary`, ADR 0047): each person's photo
    /// count and newest face, which People writes after a pass and only the gallery's read
    /// reads, so People's own write never wakes People.
    static let peopleGallery = CatalogChangedFacts(rawValue: 1 << 17)

    static let all: CatalogChangedFacts = [
        .membership, .captureDate, .kindAndFormat, .grouping, .location, .placeNames, .faces, .copies,
        .searchReadings, .detail, .choices, .images, .mediaRecord, .stacks, .duplicateFacts, .searchContent,
        .faceTiles, .peopleGallery,
    ]

    /// How many kinds there are: the bits `all` sets.
    static let bitCount = 18

    /// What a write of which existing rows are shown changes: a row deleted, marked for or
    /// moved to the Trash, put back, hidden or shown by its source, awaiting or seen by an
    /// attachment, or a new root's rows read. Which rows exist (`membership`); which files are
    /// copies, and the choices a copy takes, which the copy-key triggers rewrite whenever a
    /// row's presence is written (`CatalogSchema`'s v79 inputs) and this write does not
    /// compare (`DigestStanding`); and a tile's detail. A deleted row's metadata, faces and
    /// search rows go with it (`ON DELETE CASCADE`) and are part of its membership.
    static let presence: CatalogChangedFacts = [.membership, .copies, .choices, .detail]

    /// What a write of an existing row's filesystem facts changes (`ScannedFileUpsert.updated`,
    /// a source's size): its presence, and what the file's facts stand for until its bytes are
    /// read — its capture date (`best_capture_local` falls back to the file's dates), its kind
    /// and format (the file's type) — with what is named beside a date or kind: the stacks, a
    /// face's tile, and Duplicates' facts of a row it holds. Its stored images, faces, record,
    /// place and search readings stay: a changed file owes them again, which enrichment reads
    /// from the file's facts (`membership`).
    static let fileFacts: CatalogChangedFacts = presence.union([
        .captureDate, .kindAndFormat, .stacks, .faceTiles, .duplicateFacts,
    ])

    /// What a write that moves a row to another path changes (a respelling, a witnessed move, a
    /// reorganization): the path is the row's identity (ADR 0008), and every fact keyed by it
    /// moves with it (`ON UPDATE CASCADE`: its metadata, faces and the people they cover, search
    /// readings, render signature and images), with its name and folder (`grouping`). Only the
    /// names of the map's cells, keyed by place, stay.
    static let movedRow: CatalogChangedFacts = all.subtracting(.placeNames)

    /// What a write of a photo's edit changes (ADR 0036): the edit its images are rendered with,
    /// a face's tile cut from them, and a tile's detail. Duplicates' facts are named beside it
    /// for a photo Duplicates holds (`DuplicatesHoldSQL`).
    static let edit: CatalogChangedFacts = [.images, .faceTiles, .detail]

    /// What settling an imported copy changes beyond writing its own row (ADR 0009): the
    /// import batch it is in and its companions (`membership`), the digest, choice and edit it
    /// carries from its source, with the copies and choices the copy-key triggers rewrite, and
    /// the products it takes from the source — its metadata's date, kind, grouping, place and
    /// record, and its rendering — with what is named beside a date, kind or image: the stacks,
    /// a face's tile and Duplicates' facts. Its faces and search readings are owed, not carried.
    static let settledImport: CatalogChangedFacts = [
        .membership, .captureDate, .kindAndFormat, .grouping, .location, .mediaRecord, .images, .copies, .choices,
        .detail, .stacks, .faceTiles, .duplicateFacts,
    ]

    static let names: [(CatalogChangedFacts, String)] = [
        (.membership, "membership"), (.captureDate, "captureDate"), (.kindAndFormat, "kindAndFormat"),
        (.grouping, "grouping"), (.location, "location"), (.placeNames, "placeNames"), (.faces, "faces"),
        (.copies, "copies"), (.searchReadings, "searchReadings"), (.detail, "detail"), (.choices, "choices"),
        (.images, "images"), (.mediaRecord, "mediaRecord"), (.stacks, "stacks"), (.duplicateFacts, "duplicateFacts"),
        (.searchContent, "searchContent"), (.faceTiles, "faceTiles"), (.peopleGallery, "peopleGallery"),
    ]

    /// What each kind's writes change, as the database events they make (ADR 0005).
    /// A background owner's inputs are derived from it: the kinds whose events could change
    /// what its candidate statements read (`read(by:)`, over GRDB's `Statement.databaseRegion`),
    /// so no owner keeps a hand-written list of the facts its SQL reads, and an owner whose SQL
    /// changes wakes on what it reads now. A write names its kinds where it writes (ADR 0005);
    /// this is the one table of which columns each kind stands for.
    /// `CatalogOwnerInputsTests` proves every column an owner's statements read is named here or
    /// is the owner's own.
    static let writes: [(facts: CatalogChangedFacts, events: [DatabaseEventKind])] = [
        (.membership, [
            .insert(tableName: "media_asset"), .delete(tableName: "media_asset"),
            .update(tableName: "media_asset", columnNames: [
                "library_root_id", "relative_path", "relative_path_key", "name_sort_key", "name",
                "content_type_identifier", "byte_size", "created_at_unix", "content_modified_at_unix",
                "file_identifier", "pending_trash_batch_unix_ms", "trash_path", "awaiting_presence",
                "hidden_by_source", "source_item_id", "import_batch_unix_ms", "import_source_root_path",
                "import_source_relative_path", "import_source_byte_size", "import_source_modified_at_epoch",
                "import_destination_byte_size", "import_destination_modified_at_epoch",
            ]),
            .insert(tableName: "library_root"), .delete(tableName: "library_root"),
            .update(tableName: "library_root", columnNames: [
                "id", "path", "kind", "device_identity", "display_name", "last_seen_at", "sort_index",
                "case_sensitive_names", "device_model", "remote_base_url", "last_synced_at", "resync_owed",
            ]),
            .insert(tableName: "media_companion"), .delete(tableName: "media_companion"),
            .update(tableName: "media_companion", columnNames: [
                "library_root_id", "relative_path", "primary_relative_path", "kind", "byte_size",
                "content_modified_at", "relative_path_key",
            ]),
        ]),
        (.captureDate, [.update(tableName: "media_asset", columnNames: [
            "capture_wall_compact", "capture_wall_precision", "capture_instant_unix", "assumed_utc_offset_seconds",
            "best_capture_local", "capture_day", "capture_month",
        ])]),
        (.kindAndFormat, [.update(tableName: "media_asset", columnNames: [
            "kind", "format", "enriched_kind", "enriched_format", "best_kind", "best_format",
        ])]),
        (.grouping, [.update(tableName: "media_asset", columnNames: ["content_identifier", "burst_identifier", "parent_path"])]),
        // A record inserted or deleted carries its location with it.
        (.location, [
            .insert(tableName: "asset_metadata"), .delete(tableName: "asset_metadata"),
            .update(tableName: "asset_metadata", columnNames: [
                "primary_latitude", "primary_longitude", "primary_altitude_meters", "place_cell_latitude", "place_cell_longitude",
            ]),
        ]),
        (.placeNames, [
            .insert(tableName: "place_cell"), .delete(tableName: "place_cell"),
            .update(tableName: "place_cell", columnNames: ["cell_latitude", "cell_longitude", "country", "town", "language"]),
        ]),
        (.faces, [
            .update(tableName: "media_asset", columnNames: [
                "faces_source_size", "faces_source_mtime", "faces_read_source_size", "faces_read_source_mtime",
            ]),
            .insert(tableName: "face"), .delete(tableName: "face"),
            .update(tableName: "face", columnNames: [
                "library_root_id", "relative_path", "face_index", "box_x", "box_y", "box_width", "box_height", "landmarks",
                "quality", "analysis_revision", "person_id", "is_not_face", "assignment", "likeness",
                "is_key_photo", "frame_index",
            ]),
            .insert(tableName: "face_embedding"), .delete(tableName: "face_embedding"),
            .update(tableName: "face_embedding", columnNames: [
                "id", "library_root_id", "relative_path", "face_index", "embedding",
            ]),
            .insert(tableName: "face_rejection"), .delete(tableName: "face_rejection"),
            .update(tableName: "face_rejection", columnNames: ["library_root_id", "relative_path", "face_index", "person_id"]),
            .insert(tableName: "person"), .delete(tableName: "person"),
            .update(tableName: "person", columnNames: ["id", "name", "birthday", "is_hidden", "is_favorite"]),
        ]),
        (.copies, [
            .update(tableName: "media_asset", columnNames: [
                "content_sha1", "content_hash_source_size", "content_hash_source_mtime", "shown_copy_root_id",
                "source_path_sha1", "has_copies", "copy_key",
            ]),
            .insert(tableName: "immich_mirror"), .delete(tableName: "immich_mirror"),
            .update(tableName: "immich_mirror", columnNames: ["account_root_id", "library_root_id", "server_prefix"]),
            .insert(tableName: "immich_mirror_pair"), .delete(tableName: "immich_mirror_pair"),
            .update(tableName: "immich_mirror_pair", columnNames: [
                "library_root_id", "file_path", "account_root_id", "asset_path",
            ]),
        ]),
        (.searchReadings, [.update(tableName: "search_embedding", columnNames: ["confident_labels"])]),
        // A row's own digest is detail too: a digest no other copy holds makes no file a copy,
        // and its write names `.detail` alone (`DigestStanding`).
        (.detail, [.update(tableName: "media_asset", columnNames: [
            "metadata_source_size", "metadata_source_mtime", "enrichment_claimed", "undecodable_by", "duration_seconds",
            "content_sha1", "content_hash_source_size", "content_hash_source_mtime",
        ])]),
        (.choices, [
            .update(tableName: "media_asset", columnNames: [
                "media_choice", "media_choice_sequence", "stack_key_chosen_at_unix_ms", "burst_key_chosen_at_unix_ms",
            ]),
            .update(tableName: "choice_sequence", columnNames: ["value", "joins"]),
        ]),
        (.images, [.update(tableName: "media_asset", columnNames: [
            "thumbnail_path", "preview_path", "face_frames_path", "edit_recipe_json", "edit_revision", "rendered_revision",
            "rendered_source_size", "rendered_source_mtime", "source_products_size", "source_products_mtime",
            "source_products_absent",
        ])]),
        (.mediaRecord, [
            .insert(tableName: "asset_metadata"), .delete(tableName: "asset_metadata"),
            .update(tableName: "asset_metadata", columnNames: [
                "library_root_id", "relative_path", "family", "file_extension", "brand", "camera_make", "camera_model",
                "lens_model", "serial_number", "orientation", "pixel_width", "pixel_height", "duration_seconds", "frame_rate",
                "video_codec", "metadata_extra_json", "extraction_revision",
            ]),
        ]),
        (.duplicateFacts, [
            .update(tableName: "media_asset", columnNames: ["render_dhash", "render_signature_read"]),
            .insert(tableName: "render_signature"), .delete(tableName: "render_signature"),
            .update(tableName: "render_signature", columnNames: ["library_root_id", "relative_path", "gray"]),
            .insert(tableName: "duplicate_kept_pair"), .delete(tableName: "duplicate_kept_pair"),
        ]),
        (.searchContent, [
            .insert(tableName: "search_embedding"), .delete(tableName: "search_embedding"),
            .update(tableName: "search_embedding", columnNames: [
                "library_root_id", "relative_path", "source", "embedding", "labels", "confident_labels",
            ]),
            .insert(tableName: "search_text"), .delete(tableName: "search_text"),
            .update(tableName: "search_text", columnNames: ["library_root_id", "relative_path", "source", "lines"]),
            .insert(tableName: "search_text_folded"), .delete(tableName: "search_text_folded"),
            .update(tableName: "search_text_folded", columnNames: ["id", "library_root_id", "relative_path", "folded"]),
            .insert(tableName: "search_text_word"), .delete(tableName: "search_text_word"),
            .update(tableName: "search_text_word", columnNames: ["words"]),
        ]),
        (.peopleGallery, [
            .insert(tableName: "person_summary"), .delete(tableName: "person_summary"),
            .update(tableName: "person_summary", columnNames: [
                "person_id", "photos", "videos", "cover_library_root_id", "cover_relative_path", "cover_face_index",
            ]),
        ]),
    ]

    /// The kinds whose writes could change what `region` reads.
    static func read(by region: DatabaseRegion) -> CatalogChangedFacts {
        writes.reduce(into: []) { facts, kind in
            if kind.events.contains(where: region.isModified(byEventsOfKind:)) {
                facts.formUnion(kind.facts)
            }
        }
    }

    /// What a write of digests touched, from where its rows stood before and after it
    /// (`DigestStanding`): which files are copies only when a row joined or left copies, the
    /// rows' own digests otherwise (`.detail`: a tile's copy digest, Info's `Copies` row), and
    /// — when a copy that joined a photo took the photo's choice in the same write (ADR 0054,
    /// `CatalogSchema.choiceJoins`) — the choices. A write that moved no digest names nothing.
    static func digests(copiesChanged: Bool, digestsChanged: Bool, choicesJoined: Bool) -> CatalogChangedFacts {
        var facts: CatalogChangedFacts = []
        if digestsChanged {
            facts.insert(.detail)
        }
        if copiesChanged {
            facts.insert(.copies)
        }
        if choicesJoined {
            facts.insert(.choices)
        }
        return facts
    }

    /// What a digest write changed, from where each row it wrote stood before and after it,
    /// read in the same transaction.
    static func digests(from standings: [(before: DigestStanding, after: DigestStanding)], choicesJoined: Bool) -> CatalogChangedFacts {
        digests(
            copiesChanged: standings.contains { $0.before.changesCopies(to: $0.after) },
            digestsChanged: standings.contains { $0.before != $0.after },
            choicesJoined: choicesJoined
        )
    }

    /// The kinds by name, comma-separated, `all` or `none`: one log field.
    var diagnosticDescription: String {
        if self == .all {
            return "all"
        }
        let names = Self.names.filter { contains($0.0) }.map(\.1)
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }
}

/// Where one row stands among identical copies (ADR 0054), read inside a digest write before
/// and after it (`AssetRowSQL.digestStandingSQL`). Most digests a library's backlog brings
/// are of files nothing else holds: such a write changes the row's own digest and nothing
/// about which files are copies, so it must not wake what is built from copies — the
/// combined scopes' order and filter options, People and Duplicates (ADR 0054).
nonisolated struct DigestStanding: Equatable, Sendable {
    /// The stored digest and the file facts it was read at, whatever they say of currency.
    let storedDigest: Data?
    let storedSize: Int64?
    let storedMTime: Int64?
    /// The row's copy key (`PhotoCopySQL`): its current digest of some bytes in a library or
    /// an account, or the key its mirror pair gives it; nil when it is a copy of nothing.
    let copyKey: Data?
    /// Whether another row, of any presence, shares `copyKey`.
    let shared: Bool

    /// Where a row that did not exist stood: no digest, a copy of nothing.
    static let absent = DigestStanding(storedDigest: nil, storedSize: nil, storedMTime: nil, copyKey: nil, shared: false)

    static func read(libraryRootID: Int64, relativePath: String, db: Database) throws -> DigestStanding? {
        try Row.fetchOne(
            db.cachedStatement(sql: AssetRowSQL.digestStandingSQL),
            arguments: AssetKey(rootID: libraryRootID, path: MediaRelativePath(rawValue: relativePath)).arguments
        ).map { row in
            DigestStanding(
                storedDigest: row[0], storedSize: row[1], storedMTime: row[2], copyKey: row[3], shared: row[4]
            )
        }
    }

    /// Whether going from this standing to `after` changed which files are copies of which:
    /// the row joined or left a key another row holds, or another row joined or left its
    /// own — a mirrored asset whose key follows its file's digest. A key no other row holds,
    /// before or after, makes no file a copy.
    func changesCopies(to after: DigestStanding) -> Bool {
        (copyKey != after.copyKey || shared != after.shared) && (shared || after.shared)
    }
}

/// An asset the Store has claimed for enrichment, together with the claim-time scope —
/// decided once, by the owner of root kind, from the partial-index predicate the row was
/// claimed under and its staleness at that moment (ADR 0018). Carried rather than
/// re-derived downstream: a later re-derivation reads root kind from a possibly-staler
/// cache and can disagree with the predicate the row was actually claimed under.
nonisolated struct ClaimedEnrichmentCandidate: Sendable {
    let asset: MediaAsset
    let scope: EnrichmentScope

    /// The digest is the only product the row owes: its scope is the digest alone, and no
    /// video's faces wait behind a held admission (`EnrichmentClaim.admitting`). Such a row is
    /// never downloaded: its digest waits for local bytes (ADR 0009 §12).
    var owesOnlyDigest: Bool {
        scope == .hash && !asset.videoFacesStale
    }
}

/// What a priority claim answered of the rows it was asked about: the rows it claimed, and
/// the rows it read that have nothing to claim until a change names them — rows that owe
/// nothing under the claim their root is first enriched under (`EnrichmentClaim`, at the
/// video-faces admission asked), and rows whose digest waits for local bytes (ADR 0009 §12),
/// whose hold ends only in a write that names them or names none. Enrichment does not ask
/// of either again until then.
nonisolated struct PriorityEnrichmentClaims: Sendable {
    let claimed: [ClaimedEnrichmentCandidate]
    let owingNothing: Set<MediaAssetID>
    let digestsAwaitingLocalBytes: Set<MediaAssetID>

    init(
        claimed: [ClaimedEnrichmentCandidate],
        owingNothing: Set<MediaAssetID>,
        digestsAwaitingLocalBytes: Set<MediaAssetID> = []
    ) {
        self.claimed = claimed
        self.owingNothing = owingNothing
        self.digestsAwaitingLocalBytes = digestsAwaitingLocalBytes
    }

    /// The rows enrichment need not ask of again until a change names them.
    var nothingToClaim: Set<MediaAssetID> {
        owingNothing.union(digestsAwaitingLocalBytes)
    }
}

/// Catalog Store guide
///
/// This actor is the only runtime owner of catalog truth. SQLite provides durable
/// overlay storage and the per-asset working set; the actor keeps only root identity,
/// source metadata, per-root runtime facts via `RootRegistry` / `RootRuntimeState`,
/// scan/enumeration leases via `ScanLeaseController`, and notification state resident. Fixed libraries, removable
/// volumes, and MTP cameras share the root
/// table because the current filesystem or staging path remains the asset identity
/// boundary, while `LibraryRootKind` controls lifecycle rules such as All Media
/// membership, launch scans, detach, and Forget. Filesystem scans and device catalog
/// batches write SQLite and notify consumers only when those writes actually inserted,
/// updated, or deleted rows. While the app runs, `CatalogFilesystemWatcher` forwards
/// macOS events, in order, to one reconciliation pass per root via `FilesystemReconciler`
/// (pure batch classification) plus Store-owned execution: safe single-file
/// events update one row and unsafe events fall back to the full scan pipeline. Views
/// never access persistence directly. The app owns one Store for the process lifetime;
/// `shutdown()` is therefore a cancellation and watcher boundary, while the database
/// writer is released with the actor rather than through a partial mid-lifecycle close.
///
/// Why an actor: the database handle, root runtime state, scan lifecycle, and
/// background scans all touch the same catalog authority, and a scan streams in
/// thousands of files concurrently with user actions. Actor isolation serializes every access to that state
/// automatically, so the catalog cannot be corrupted by two operations at once and
/// we never reach for a lock. The cost is that `await` is a yield point — the actor
/// can run another message mid-operation — which is exactly why scans carry the
/// ownership lease described below.
///
/// Store notifications are intentionally lightweight. Each names the kinds of fact
/// its write touched (`CatalogChangedFacts`), which this actor knows at the write and
/// no reader could reconstruct; successful root removal additionally carries its typed
/// path so same-path replacement cannot hide selection invalidation. Projection pulls
/// cheap root state and, when a fact they depend on changed, descriptor-ordered asset
/// IDs and filter options on its background cadence, and owns presentation.
/// Initial loading is represented by one finite task so every concurrent caller
/// observes the same load instead of applying competing root sets. Awaited GRDB calls
/// make this actor reentrant, so active scans carry the root path, private root-row
/// instance, and in-memory lease generation they own and revalidate them after each
/// database await. `ScanLeaseController` holds the lease/queue bookkeeping; this actor
/// keeps one scan task per lane and all spawn/await orchestration. Completed scans reconcile missing paths; failed,
/// cancelled, or
/// stale scans preserve prior rows because incomplete observation cannot prove
/// removal. Device enumerations use the same process-local lease before they may
/// reconcile missing rows, so a stale camera flow cannot delete rows written by a
/// newer attach. A single regular-file remove
/// event proves deletion only after Store checks that exact path is absent under an
/// armed available root.
actor CatalogStore {
    private nonisolated static let slowQueryDiagnosticThresholdMs = 50

    enum Location: Sendable {
        case application(bundleIdentifier: String)
        case databaseFile(URL)
        case inMemory
    }

    struct StoredRoot {
        let id: Int64
        let path: LibraryRootPath
        let kind: LibraryRootKind
        let deviceIdentity: DeviceIdentity?
        let displayName: String?
        let lastSeenAt: Date?
        let sortIndex: Int64
        let capabilities: VolumeNamespaceCapabilities
        let deviceModel: String?
        let remoteBaseURL: URL?
    }

    struct ThumbnailPathMigration {
        let oldRelativeName: String
        let newRelativeName: String
    }

    /// This value is a process-local ownership lease, not durable scan identity.
    /// The normalized path identifies the domain root, the private row ID
    /// distinguishes a removed root from a later root added at the same path, and
    /// the in-memory generation distinguishes overlapping callbacks for the same
    /// root instance.
    struct ActiveScan: Equatable {
        let rootPath: LibraryRootPath
        let rootRowID: Int64
        let leaseGeneration: UInt64
        let startNamespaceMutationEpoch: UInt64
    }

    private struct RemovableRootAttachment {
        let kind: LibraryRootKind
        let path: LibraryRootPath
        let identity: DeviceIdentity
        let displayName: String
        let isEjectable: Bool
        let activity: CatalogLibraryActivity
        let enqueuesScan: Bool
        let capabilities: VolumeNamespaceCapabilities
        let deviceModel: String?
        let volumeFormat: String?

        func root(lastSeenAt: Date) -> LibraryRoot {
            LibraryRoot(
                path: path,
                kind: kind,
                deviceIdentity: identity,
                displayName: displayName,
                lastSeenAt: lastSeenAt
            )
        }
    }

    private struct EnrichmentBatchWriteOutcome {
        /// The rows the batch wrote: what its change names (`CatalogChangedRows`).
        var applied: Set<MediaAssetID> = []
        var appliedCount: Int {
            applied.count
        }

        /// The kinds of fact the applied results changed, from what SQLite stored before
        /// and after each write (`EnrichmentOverlayBeforeWrite.changedFacts(to:)`): a batch
        /// that moved no capture date, kind, format, grouping identifier or location is
        /// `.detail` (with `.faces` for what it read of them, and `.copies` when a digest it
        /// read made a file a copy or not, `DigestStanding`), and a reader
        /// of the order or the filter's options does not repeat its read for it (ADR 0005).
        var facts: CatalogChangedFacts = []
        var namingChangedRoots: Set<LibraryRootPath> = []
        var promotionFailed = false
        var discardedImages: [StagedDerivedImage] = []
        var supersededImagePaths: Set<String> = []
        /// The superseded names' deletes, counted out in the batch's write.
        var removal = DerivedRemoval.nothing
        var waitMs = 0
        var execMs = 0

        mutating func discard(_ images: [StagedDerivedImage]) {
            discardedImages.append(contentsOf: images)
        }

        mutating func failPromotion(_ images: [StagedDerivedImage]) {
            promotionFailed = true
            discard(images)
        }

        /// Records a stored derived image (thumbnail or preview) replaced by a new path,
        /// so its file is deleted once the batch commits.
        mutating func replaceImage(oldPath: String?, newPath: String?) {
            if let newPath {
                supersededImagePaths.remove(newPath)
            }
            if let oldPath, oldPath != newPath {
                supersededImagePaths.insert(oldPath)
            }
        }
    }

    /// Whether the row holds a face: one probe of the face table's key.
    private static func holdsFace(libraryRootID: Int64, relativePath: MediaRelativePath, db: Database) throws -> Bool {
        try Bool.fetchOne(
            db.cachedStatement(sql: PeopleSQL.holdsFaceSQL),
            arguments: AssetKey(rootID: libraryRootID, path: relativePath).arguments
        ) ?? false
    }

    /// The columns a reader's answer depends on, read before and after an enrichment
    /// overwrite, so the batch can say which kinds of fact it changed by comparing what
    /// SQLite stored — the generated `best_*` columns' own COALESCE chains, not a Swift guess
    /// at them (ADR 0005, ADR 0011).
    struct EnrichmentOverlayBeforeWrite {
        let bestCaptureLocal: Double?
        let bestKind: String?
        let bestFormat: String?
        let captureWallCompact: Int64?
        let thumbnailPath: String?
        let previewPath: String?
        let faceFramesPath: String?
        let contentIdentifier: String?
        let burstIdentifier: String?
        let latitude: Double?
        let longitude: Double?
        let parentPath: String?

        init(row: Row) {
            bestCaptureLocal = row[0]
            bestKind = row[1]
            bestFormat = row[2]
            captureWallCompact = row[3]
            thumbnailPath = row[4]
            previewPath = row[5]
            faceFramesPath = row[6]
            contentIdentifier = row[7]
            burstIdentifier = row[8]
            latitude = row[9]
            longitude = row[10]
            parentPath = row[11]
        }

        /// The kinds of fact the write changed besides its detail: the sort date; the kind
        /// and format filters; through the content identifier which movies a Live Photo
        /// hides (ADR 0041) and through the burst identifier which frames a burst collapses
        /// (ADR 0052); the location the map and the places filter read (ADR 0040).
        func changedFacts(to new: EnrichmentOverlayBeforeWrite) -> CatalogChangedFacts {
            var facts: CatalogChangedFacts = []
            if bestCaptureLocal != new.bestCaptureLocal {
                facts.insert(.captureDate)
            }
            if bestKind != new.bestKind || bestFormat != new.bestFormat {
                facts.insert(.kindAndFormat)
            }
            if contentIdentifier != new.contentIdentifier || burstIdentifier != new.burstIdentifier {
                facts.insert(.grouping)
            }
            if latitude != new.latitude || longitude != new.longitude {
                facts.insert(.location)
            }
            return facts
        }

        /// Whether a write that changed `facts` of this row can change a stack
        /// (`CatalogChangedFacts.stacks`): a capture date, kind or grouping of a still that
        /// carries, or carried, a burst identifier, or that shares its folder with a present
        /// still it could pair with — any other still for a RAW, another RAW for a processed
        /// image (`PhotoStackRule`). A still alone in its folder, as every Immich asset is in
        /// its own, is in no stack whatever its date. One probe of
        /// `idx_media_asset_stack_candidate`, asked only of a still whose date, kind or
        /// grouping moved.
        func changesStacks(
            to new: EnrichmentOverlayBeforeWrite,
            facts: CatalogChangedFacts,
            libraryRootID: Int64,
            relativePath: MediaRelativePath,
            db: Database
        ) throws -> Bool {
            guard !facts.isDisjoint(with: [.captureDate, .kindAndFormat, .grouping]) else {
                return false
            }
            let stills: Set<String> = [MediaKind.raw.rawValue, MediaKind.image.rawValue]
            let wasStill = bestKind.map(stills.contains) ?? false
            let isStill = new.bestKind.map(stills.contains) ?? false
            guard wasStill || isStill else {
                return false
            }
            if burstIdentifier != nil || new.burstIdentifier != nil {
                return true
            }
            guard let folder = new.parentPath ?? parentPath else {
                return false
            }
            let isOrWasRaw = bestKind == MediaKind.raw.rawValue || new.bestKind == MediaKind.raw.rawValue
            return try Bool.fetchOne(
                db,
                sql: AssetRowSQL.stackCandidateExistsSQL,
                arguments: [libraryRootID, folder, relativePath.rawValue, isOrWasRaw]
            ) ?? false
        }
    }

    nonisolated struct MediaChoiceMutationResult: Equatable, Sendable {
        let existingCount: Int
        let changedCount: Int
        /// The choice each existing row held before this write — catalog truth read in
        /// the same transaction, so a caller can register an exact inverse (APP-039).
        let previous: [MediaAssetID: MediaChoice]

        init(existingCount: Int, changedCount: Int, previous: [MediaAssetID: MediaChoice] = [:]) {
            self.existingCount = existingCount
            self.changedCount = changedCount
            self.previous = previous
        }

        var accepted: Bool {
            existingCount > 0
        }
    }

    /// One read's or write's value and where its time went, for the query's log line.
    /// `waitMs` is asked → the body runs: for a read, a free connection of its pool and that
    /// connection's queue, reached without the cooperative pool (`readFreeingConnection`); for
    /// a write, the writer, through GRDB's async access. `resumeMs` is the body ends → the
    /// Store continues: a cooperative-pool thread at `priority`, then the Store actor. Reads
    /// that hold every connection show in `waitMs` alone; a pool with no thread free at the
    /// caller's priority, or a busy Store, in `resumeMs`
    /// (`docs/research/2026-11-15-cooperative-pool-holders.md`). `lockMs` is the part of a
    /// read's `waitMs` spent on SQLite's locks once it had a connection (`ConnectionLockWait`);
    /// the rest of `waitMs` is the wait for the connection. Writes do not log it: the writer
    /// never waits on a lock, it fails.
    private struct DatabaseTimedValue<Value: Sendable> {
        let value: Value
        let waitMs: Int
        let execMs: Int
        var lockMs = 0
        var resumeMs = 0
        /// The caller's priority when it asked; nil for a value summed from several.
        var priority: TaskPriority?

        var totalMs: Int {
            waitMs + execMs
        }

        var priorityName: String {
            switch priority {
            case nil: "unknown"
            case .userInitiated?: "userInitiated"
            case .medium?: "medium"
            case .utility?: "utility"
            case .background?: "background"
            case let other?: "\(other.rawValue)"
            }
        }
    }

    private let location: Location
    /// The derived folder and this session's changes to it (`DerivedFolder`); nil for an
    /// in-memory catalog, which has none.
    nonisolated let derivedFolder: DerivedFolder?
    /// Which copies Duplicates compares (ADR 0042): every Duplicates read and the Duplicates
    /// scopes use this one value, so the groups and the rows the scopes hold agree. The user's
    /// preference, which the window's owner hands over before the catalog starts and on
    /// every change (`setDuplicatesReach`).
    private(set) var duplicatesReach: DuplicatesReach = .withinEachLibrary
    /// Whether a RAW and its processed file are one photo (ADR 0052, Settings ▸ General): every
    /// stack build reads this one value, so the grid, the counts, People and the imports agree.
    /// The user's preference, handed over before the catalog starts and on every change
    /// (`setRawPairing`).
    private(set) var rawPairing: RawPairing = .paired
    /// Bytes the WAL file may reach before a bulk write checkpoints it, and the size SQLite
    /// truncates it to when it restarts the log (64 MiB). While readers overlap one another
    /// back to back — the window, enrichment and the derived owners during a listing —
    /// SQLite's own checkpoint fell behind and the file grew without end (257 MB in the
    /// installed app, 250–357 MB in the listing probe,
    /// `docs/research/2026-11-12-listing-batch-cost.md`). A log SQLite resets stays near
    /// one batch's pages: 26 MB at its largest in the same probe with no reader.
    static let defaultWALByteBudget: Int64 = 64 * 1024 * 1024

    /// The WAL file size past which a bulk write checkpoints the log, and the writer's
    /// `journal_size_limit` (`boundWAL`).
    private let walByteBudget: Int64
    /// The largest WAL file size a sample has logged since the last checkpoint. A log
    /// SQLite keeps resetting is reused from its start and its file keeps its size, so a
    /// sample says something only when the file grew (`boundWAL`).
    private var walLoggedHighWater: Int64 = 0
    /// Where this catalog's staging roots live: the one answer every reader asks
    /// (`StagingContainers`). The app's are its bundle identifier's under Caches, a catalog
    /// file's sit beside it, and an in-memory catalog's in a temporary folder of its own. A
    /// camera's or an Immich account's root path is derived from it and the source's
    /// identity, and re-derived at every load (`normalizedLoadedRoot`), so no root keeps a
    /// folder another build owns (ADR 0046). `nonisolated` because it is immutable: the
    /// camera monitor, the sweeps and the import's release read it synchronously.
    nonisolated let stagingContainers: StagingContainers
    private let scanner: CatalogScanner
    private let filesystemWatcher: CatalogFilesystemWatcher
    /// How often a running scan flushes what it has found: at most once a second. A rate
    /// limit standing on a measurement: a 20,000-file scan took 8–9 s at 1 s, 11–12 s at
    /// 100 ms and over a minute flushing every file, since each flush is a write
    /// transaction and a change notification (`docs/research/2026-10-23-cadence-audit.md`).
    private let scanCadence: Duration
    /// Wall-clock time for persisted facts only: a removable source's last-seen date and
    /// the retention cutoff measured against it (ADR 0033: `Date` is for persisted and
    /// displayed timestamps). Injected so retention is testable without waiting 90 days.
    private let wallClock: @Sendable () -> Date
    private let initialLoadDidRead: (@Sendable () async -> Void)?
    /// Runs where a root's namespace mutation reaches each `NamespaceMutationPoint`: where a
    /// test parks it for a competing one to arrive (ADR 0032 rule 7). Nil in the app.
    private let namespaceMutationReached: (@Sendable (NamespaceMutationPoint) async -> Void)?
    /// Runs on the file-deletion queue just before a removed source's staging folder is
    /// deleted (`deleteStagingIfNeeded`): where a test holds the delete to see the Store answer
    /// meanwhile. Nil in the app.
    private let stagingDeletionReached: (@Sendable (LibraryRootPath) -> Void)?
    private let importJournalFailure: (@Sendable (ImportJournalTransition) throws -> Void)?
    /// What a test's change-coverage guard hears of every write and change (ADR 0005). Nil in
    /// the app.
    private let changeAudit: CatalogWriteAudit?
    private var dbWriter: CatalogWriter?
    /// What the open is doing, for the window while it waits (DES-121): one consumer, the
    /// main window's view model, which reads the newest value. `nonisolated` so it can be
    /// subscribed while the open holds this actor. Finished when the open ends.
    nonisolated let openings: AsyncStream<CatalogOpening>
    private nonisolated let openingContinuation: AsyncStream<CatalogOpening>.Continuation
    /// The newest value yielded to `openings`.
    private var reportedOpening = CatalogOpening()
    /// What this process's open spent on migrations, for `op=catalog.start`.
    private var migrationRun: MigrationRun?
    /// Who may enter the pool's readers for a background read (`CatalogReadAdmission`): at
    /// most `CatalogReadAdmission.backgroundReaders` at once, so a window read always finds
    /// one of the pool's `CatalogStore.readerCount` readers free (ADR 0002).
    private nonisolated let readAdmission = CatalogReadAdmission()
    /// The background admission as it is now: which background reads hold a turn and which
    /// wait for one.
    nonisolated var backgroundReadTurns: ReadAdmissionMachine {
        readAdmission.machine
    }

    /// What each of the catalog file's connections is doing, for the line a read that waited
    /// writes (`op=catalog.store.stall`). Every connection of the pool reports to it; an in-memory catalog's one
    /// connection does not.
    private nonisolated let connectionActivity: CatalogConnectionActivity
    /// The change notifications sent since launch, by kind of fact (`use`).
    private nonisolated let changeTally = CatalogChangeTally()

    /// What the connections and change notifications have carried since launch, for a
    /// resource checkpoint (`op=catalog.store.use`). Two locks; callable from any thread.
    nonisolated func use() -> CatalogStoreUse {
        CatalogStoreUse(connections: connectionActivity.use(), changes: changeTally.current, backgroundReads: readAdmission.use())
    }

    private var databaseFileURL: URL?
    private var started = false
    private var startupTask: Task<Void, Error>?
    private var unrequestedLoadedRootPaths: [LibraryRootPath] = []
    private var roots = RootRegistry()
    /// Rows whose bytes just became local and still owe a product, in landing order: copies
    /// an import settled, and originals a source's download staged (an Immich account's,
    /// ADR 0046 §7). Their bytes may not stay — a cloud-synced library evicts uploaded
    /// files, a staging folder is swept at launch — so background claims offer them before
    /// any other row, for every product their bytes can give (ADR 0009 §9). Runtime only:
    /// after a relaunch they wait in the ordinary order.
    private var localBytesAwaitingProducts: [MediaAssetID] = []
    /// What each duplicates Move to Trash carried onto kept copies, by its batch, so the
    /// command's undo puts back exactly what the kept copies held (ADR 0042). In memory:
    /// it lives as long as the undo stack that names the batch.
    private var carriedWorkByBatch: [MediaTrashBatchID: [DuplicateCarryRecord]] = [:]
    private var changeContinuations: [UUID: AsyncStream<CatalogStoreChange>.Continuation] = [:]
    private var planningChangeContinuations: [UUID: AsyncStream<RootPlanningChange>.Continuation] = [:]
    private var changeDeliveries: [UUID: DeliveryCount] = [:]
    private var planningChangeDeliveries: [UUID: DeliveryCount] = [:]
    private var scanLeases = ScanLeaseController()
    /// The filesystem walk each lane is running (`ScanLeaseController.ScanLane`): one
    /// for the fixed libraries, one per card. Each is cancelled when its root goes away,
    /// and every callback revalidates its `ActiveScan` lease before mutating actor state.
    private var scanTasks: [ScanLeaseController.ScanLane: Task<Void, Never>] = [:]
    private var filesystemWatchingStarted = false
    private var filesystemEventSink: AsyncStream<FilesystemWatcherDelivery>.Continuation?
    /// Each fixed library's change journal in this session (`RootChangeJournal`, ADR 0002
    /// "Change Journal"): how far its stream has delivered and what may be stored.
    private var changeJournals: [LibraryRootPath: RootChangeJournal] = [:]
    /// The positions the catalog held as it loaded, until each root's launch decides.
    private var loadedJournalPositions: [LibraryRootPath: FilesystemJournalPosition] = [:]
    /// The roots whose stream runs.
    private var watchedRoots: Set<LibraryRootPath> = []
    /// Why each queued full walk was asked for, and why each running one runs
    /// (`op=catalog.scan reason=`).
    private var pendingScanReasons: [LibraryRootPath: ScanReason] = [:]
    private var runningScanReasons: [LibraryRootPath: ScanReason] = [:]
    private var filesystemEventConsumer: Task<Void, Never>?
    /// The one owner of dirty-scope reconciliation and of starting the next queued
    /// full-root scan (ADR 0032). Anything that leaves reconcilable work — a scan or a
    /// lease ending, an event batch classified, an independent mutation settled — rings
    /// the doorbell; the loop drains every dirty root it may act on, then starts the
    /// next queued scan. One loop, so two drains of one root never interleave.
    private var reconcileLoop: Task<Void, Never>?
    private var reconcileDoorbell: AsyncStream<Void>.Continuation?
    /// Bumped by every ring; a pass covers the value it started from.
    private var reconcileRequested: UInt64 = 0
    private var reconcileCovered: UInt64 = 0
    /// True while the loop's pass runs, so a scan enqueued mid-pass waits for the pass
    /// to finish every dirty root. Written only by the loop.
    private var reconcilePassRunning = false
    private var filesystemWatchingArmed: Set<LibraryRootPath> = []
    /// One pass per root acts on that root's filesystem events. Events that arrive while
    /// it awaits join `filesystemEventBatches` and the same pass takes them next, so a
    /// burst is coalesced by the work itself, never by waiting for a quiet period.
    private var filesystemEventPasses: [LibraryRootPath: Task<Void, Never>] = [:]
    /// Which pass is current per root, so a pass that ends clears its entry only when a
    /// cancellation has not already replaced it.
    private var filesystemEventPassGenerations: [LibraryRootPath: UInt64] = [:]
    private var filesystemEventBatches: [LibraryRootPath: [FilesystemEvent]] = [:]
    /// Filesystem events this Store has handled — dropped, deferred or batched. With
    /// `isFilesystemQuiescent` it says what the Store did with an event, so a caller
    /// never has to guess how long event delivery and reconciliation take.
    private(set) var handledFilesystemEventCount = 0
    /// Filesystem events a pass has taken from its batch and classified, so a caller can
    /// wait for the dirt they record rather than for their intake alone.
    private(set) var classifiedFilesystemEventCount = 0
    /// Callers that found the initial load already running and awaited it instead of
    /// starting their own database read.
    private(set) var joinedInitialLoadCount = 0

    /// True when no filesystem event is being acted on or unprocessed in a batch, no scan is active or queued, and no dirty scope is retained: everything
    /// the Store was told about the filesystem has been acted on.
    var isFilesystemQuiescent: Bool {
        filesystemEventPasses.isEmpty
            && filesystemEventBatches.isEmpty
            && scanLeases.activeScans.isEmpty
            && scanLeases.pendingScanPaths.isEmpty
            && scanLeases.rescanAfterCurrentScan.isEmpty
            && filesystemDirty.isEmpty
            && reconcileRequested == reconcileCovered
            && !reconcilePassRunning
            && changeJournals.values.allSatisfy { !$0.isReplaying }
    }

    /// The change-journal position the catalog holds for `path` in this session.
    func storedJournalPosition(for path: LibraryRootPath) -> FilesystemJournalPosition? {
        changeJournals[path]?.stored
    }

    /// Per-root typed dirty-scope accumulator. Events that arrive while a lease
    /// owns the root retain file/subtree/root granularity here instead of being
    /// collapsed into an unconditional full-root rescan.
    private var filesystemDirty: [LibraryRootPath: FilesystemDirtyAccumulator] = [:]
    /// Last successful completed full-root reconciliation per root. Launch/add
    /// scans count; used only for the long-running-session integrity sweep.
    private var unreadableSourceIDs: Set<MediaAssetID> = []
    private var lastSuccessfulFullRootScanAt: [LibraryRootPath: ContinuousClock.Instant] = [:]
    private var integrityScanTask: Task<Void, Never>?
    private var knownMaterializationSuppression = KnownMaterializationSuppressionState()
    /// Typed namespace-mutation lease per root. Import publication, library
    /// reorganization, system Trash, a removal and a removable source's attachment share
    /// this one exclusion boundary; deferred dirty-only reconciliation runs when the owner
    /// releases it.
    private var namespaceMutationLeases: [LibraryRootPath: RootNamespaceMutationLease] = [:]
    /// Mutations waiting for a root's lease to be released (`untilNamespaceMutationLeaseReleased`):
    /// an attachment behind a removal or another attachment, a removal behind an attachment.
    /// Each is resumed in the step that drops the lease, and re-reads the catalog then.
    private var namespaceLeaseReleaseWaiters: [LibraryRootPath: [CheckedContinuation<Void, Never>]] = [:]
    private var nextNamespaceMutationLeaseGeneration: UInt64 = 0
    /// Roots whose reorganization lease the journal holds: installed at load for every
    /// root with a journaled component, so nothing touches a half-moved library before
    /// its recovery adopts the lease.
    private var journalHeldReorganizationRoots: Set<LibraryRootPath> = []
    /// Libraries the user asked to remove while another owner held them. The release of
    /// that owner's lease hands the root straight to a removal lease, so nothing else
    /// starts on it in between, and the reconcile loop then removes it. A request lives
    /// for this process: one whose holder never finishes here — the app quits mid-import
    /// — leaves the library in place, where the user sees it and can remove it again.
    private var deferredLibraryRemovals: Set<LibraryRootPath> = []
    /// Removal leases a release handed over, waiting for the reconcile loop to run them.
    private var handedOffLibraryRemovals: [LibraryRootPath: RootNamespaceMutationLease] = [:]

    /// Long-running-session integrity interval. Launch scans already repair after
    /// process death; this bounds residual FSEvents/provider misses while the app
    /// stays open. Chosen as 24h for measurement/review
    /// (docs/research/2026-07-11-onedrive-materialization-fsevents.md).
    static let integrityScanInterval: Duration = .seconds(60 * 60 * 24)
    static let integrityScanPollInterval: Duration = .seconds(60 * 15)

    init(
        location: Location,
        scanner: CatalogScanner = .live,
        filesystemWatcher: CatalogFilesystemWatcher = .live(),
        scanCadence: Duration = .seconds(1),
        wallClock: @escaping @Sendable () -> Date = { Date() },
        initialLoadDidRead: (@Sendable () async -> Void)? = nil,
        namespaceMutationReached: (@Sendable (NamespaceMutationPoint) async -> Void)? = nil,
        stagingDeletionReached: (@Sendable (LibraryRootPath) -> Void)? = nil,
        importJournalFailure: (@Sendable (ImportJournalTransition) throws -> Void)? = nil,
        walByteBudget: Int64 = CatalogStore.defaultWALByteBudget,
        stagingContainers: StagingContainers? = nil,
        stallThreshold: Duration = CatalogConnectionActivity.defaultStallThreshold,
        changeAudit: CatalogWriteAudit? = nil
    ) {
        self.walByteBudget = walByteBudget
        connectionActivity = CatalogConnectionActivity(stallThreshold: stallThreshold)
        (openings, openingContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.stagingContainers = stagingContainers ?? Self.stagingContainers(for: location)
        self.location = location
        derivedFolder = Self.thumbnailDirectory(for: location).map(DerivedFolder.init(directory:))
        self.scanner = scanner
        self.filesystemWatcher = filesystemWatcher
        self.scanCadence = scanCadence
        self.wallClock = wallClock
        self.initialLoadDidRead = initialLoadDidRead
        self.namespaceMutationReached = namespaceMutationReached
        self.stagingDeletionReached = stagingDeletionReached
        self.importJournalFailure = importJournalFailure
        self.changeAudit = changeAudit
    }

    /// A store released without `shutdown()` ends what it started. Its reconcile loop,
    /// filesystem-event consumer and integrity scheduler hold it weakly and would otherwise
    /// wait forever on a doorbell, an event or a 15-minute sleep that no one will ring, and its
    /// subscribers' streams would never end.
    deinit {
        reconcileDoorbell?.finish()
        reconcileLoop?.cancel()
        filesystemEventSink?.finish()
        filesystemEventConsumer?.cancel()
        integrityScanTask?.cancel()
        for task in scanTasks.values {
            task.cancel()
        }
        for continuation in changeContinuations.values {
            continuation.finish()
        }
        for continuation in planningChangeContinuations.values {
            continuation.finish()
        }
        openingContinuation.finish()
    }
}

extension CatalogStore {
    /// Counts the changes the Store has yielded to one subscriber, recorded in the same
    /// step as each yield. A subscriber that counts what it has handled can compare the
    /// two and know it has acted on every change, which the stream alone cannot say. Only a
    /// change its stream enqueued is counted: a stream its subscriber dropped (a `start()`
    /// that lost to a concurrent one) ends at once, before the Store forgets it, and what it
    /// is yielded meanwhile reaches no one.
    final nonisolated class DeliveryCount: Sendable {
        private let count = Mutex<UInt64>(0)

        var delivered: UInt64 {
            count.withLock { $0 }
        }

        func recordDelivery() {
            count.withLock { $0 += 1 }
        }
    }

    func changeNotifications(deliveries: DeliveryCount? = nil) -> AsyncStream<CatalogStoreChange> {
        let (stream, continuation) = AsyncStream<CatalogStoreChange>.makeStream(
            // Root-removal signals cannot be dropped: a same-path add may follow
            // before Projection gets another executor turn. Events are tiny and
            // Projection coalesces their expensive work on its existing cadence.
            bufferingPolicy: .unbounded
        )
        let id = UUID()
        changeContinuations[id] = continuation
        changeDeliveries[id] = deliveries
        continuation.onTermination = { [weak self] _ in
            // AsyncStream termination is synchronous, while the continuations
            // dictionary is actor state. This short task is the required actor
            // hop that removes the observer after the stream goes away.
            Task {
                await self?.removeChangeContinuation(id)
            }
        }
        return stream
    }

    /// Lossless planning-input revision stream (ARC-046). Separate from
    /// coarse `CatalogStoreChange` so thumbnail-only mutations do not replan.
    func planningChangeNotifications(deliveries: DeliveryCount? = nil) -> AsyncStream<RootPlanningChange> {
        let (stream, continuation) = AsyncStream<RootPlanningChange>.makeStream(
            bufferingPolicy: .unbounded
        )
        let id = UUID()
        planningChangeContinuations[id] = continuation
        planningChangeDeliveries[id] = deliveries
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removePlanningChangeContinuation(id)
            }
        }
        let listenerCount = planningChangeContinuations.count
        OtosLog.catalog.notice(
            "op=catalog.planningChange phase=subscribed listeners=\(listenerCount, privacy: .public)"
        )
        return stream
    }

    func planRevision(for rootPath: LibraryRootPath) -> UInt64? {
        roots[rootPath]?.planRevision
    }

    /// Assets whose bytes enrichment could not open. Process-local by design, and
    /// discarded for a root the moment that root detaches — so re-inserting a card
    /// re-evaluates every file rather than inheriting a verdict from the attachment
    /// that observed it. Without that boundary a single unreadable file would stay
    /// blocked for the lifetime of the process, even once it read cleanly again, and
    /// the set would grow without bound.
    ///
    /// On a removable volume nothing about the condition is transient — the bytes are
    /// local, so a failure to open them is a failing card or a file that vanished, not
    /// something to wait out (ARC-057).
    func markSourceUnreadable(_ id: MediaAssetID) {
        guard unreadableSourceIDs.insert(id).inserted else {
            return
        }
        OtosLog.metadata.notice(
            "op=enrichment.sourceUnreadable phase=record rootPath=\(id.libraryRootPath.rawValue, privacy: .public) relativePath=\(id.relativePath.rawValue, privacy: .public)"
        )
        recordNamingChange(for: id.libraryRootPath, reason: "sourceUnreadable")
    }

    /// Drops every unreadable verdict recorded under `rootPath`. Called where a root
    /// stops being attached, so the next attachment starts from observation rather
    /// than from memory.
    func forgetUnreadableSources(under rootPath: LibraryRootPath) {
        let before = unreadableSourceIDs.count
        unreadableSourceIDs = unreadableSourceIDs.filter { $0.libraryRootPath != rootPath }
        let dropped = before - unreadableSourceIDs.count
        guard dropped > 0 else {
            return
        }
        OtosLog.metadata.notice(
            "op=enrichment.sourceUnreadable phase=forget rootPath=\(rootPath.rawValue, privacy: .public) dropped=\(dropped, privacy: .public)"
        )
    }

    func namespaceRevision(for rootPath: LibraryRootPath) -> UInt64? {
        roots[rootPath]?.namespaceRevision
    }

    /// Moves when any fixed library's paths, sizes or dates may have changed, or a library
    /// came or went (`RootRegistry.libraryNamespaceRevision`): what an account's mirror
    /// pairing waits on beside its own listing (ADR 0054). A digest written to a library file
    /// pairs in its own write, so a digest moves nothing here.
    var libraryNamespaceRevision: UInt64 {
        roots.libraryNamespaceRevision
    }

    /// The pair an import plan's staleness is judged against, read in one actor hop
    /// so the two halves cannot be sampled across a suspension.
    func planningRevisions(for rootPath: LibraryRootPath) -> RootPlanningRevisions? {
        guard let state = roots[rootPath] else { return nil }
        return RootPlanningRevisions(
            namespaceRevision: state.namespaceRevision,
            namingRevision: state.namingRevision
        )
    }

    /// General planning revision bump for changes that may invalidate reorganization
    /// planning but change neither the occupied namespace nor naming (no-op rescans,
    /// event deferrals, watch arming). Reorganization reads it when it plans; no import
    /// plan reads it, so it wakes no one.
    @discardableResult
    func bumpPlanRevision(for path: LibraryRootPath) -> UInt64? {
        guard var state = roots[path] else {
            return nil
        }
        state.planRevision &+= 1
        upsert(state)
        OtosLog.catalog.notice(
            "op=catalog.planRevision phase=bump rootPath=\(path.rawValue, privacy: .public) planRevision=\(state.planRevision, privacy: .public)"
        )
        return state.planRevision
    }

    /// Namespace bump for a real change to which paths this root occupies (media
    /// added/removed/renamed/resized, companion inventory change, import/reorg
    /// settlement, foreign occupant). Also advances `planRevision` — a namespace
    /// change is a superset planning change — and wakes the import coordinator, which
    /// replans every session reading this root as source or destination.
    ///
    /// Only a root an import plans against wakes the coordinator (`LibraryRootKind.isImportPlanned`):
    /// an Immich account is neither a source nor a destination.
    @discardableResult
    func bumpNamespaceRevision(for path: LibraryRootPath, reason: String = "catalogChange") -> UInt64? {
        guard var state = roots[path] else {
            return nil
        }
        state.namespaceRevision &+= 1
        state.planRevision &+= 1
        upsert(state)
        if state.root.kind.isImportPlanned {
            emitPlanningChange(rootPath: path, state: state)
        }
        OtosLog.catalog.notice(
            "op=catalog.namespaceRevision phase=bump rootPath=\(path.rawValue, privacy: .public) reason=\(reason, privacy: .public) namespaceRevision=\(state.namespaceRevision, privacy: .public) planRevision=\(state.planRevision, privacy: .public)"
        )
        return state.namespaceRevision
    }

    /// Records an enrichment write that changed what Otos would call this root's assets
    /// (`capture_wall_compact`), for the readers that name by it:
    ///
    /// - An import **source** (a card or camera) advances `namingRevision` and wakes the
    ///   import coordinator, because the source's capture wall is what names the copy
    ///   (ARC-046, ARC-057).
    /// - A root that can be **reorganized** (a library) advances `planRevision`, which
    ///   reorganization reads when it plans by capture dates.
    ///
    /// No other reader names by it. A library is an import destination too, but no file
    /// moved, so a plan copying into it is untouched; an Immich account is read by neither,
    /// so its enrichment moves nothing and wakes no one.
    func recordNamingChange(for path: LibraryRootPath, reason: String = "enrichmentNaming") {
        guard var state = roots[path] else {
            return
        }
        let kind = state.root.kind
        guard kind.isImportSource || kind.supportsReorganization else {
            return
        }
        if kind.isImportSource {
            state.namingRevision &+= 1
        }
        if kind.supportsReorganization {
            state.planRevision &+= 1
        }
        upsert(state)
        if kind.isImportSource {
            emitPlanningChange(rootPath: path, state: state)
        }
        OtosLog.catalog.notice(
            "op=catalog.namingRevision phase=bump rootPath=\(path.rawValue, privacy: .public) reason=\(reason, privacy: .public) namingRevision=\(state.namingRevision, privacy: .public) planRevision=\(state.planRevision, privacy: .public)"
        )
    }

    /// Records a namespace mutation before its owner crosses a database await.
    /// The epoch invalidates any older destructive observation, scan or file reconcile,
    /// and the typed dirty scope is a reconcile request in the same step: the loop
    /// reconciles it once no lease holds the root, so a reconcile the epoch deferred
    /// is observed again without waiting for another event.
    private func recordIndependentNamespaceMutation(
        root: LibraryRootPath,
        scope: FilesystemDirtyScope,
        fileAction: SingleFileReconcileOperation? = nil,
        rootReason: ScanReason = .events
    ) {
        guard var state = roots[root] else {
            return
        }
        state.namespaceMutationEpoch &+= 1
        upsert(state)
        var dirty = filesystemDirty[root] ?? FilesystemDirtyAccumulator()
        dirty.insert(scope, fileAction: fileAction, rootReason: rootReason)
        filesystemDirty[root] = dirty
        OtosLog.catalog.debugOperation(
            "catalog.namespaceMutation",
            phase: "record",
            fields: [
                "rootPath": root.rawValue,
                "epoch": "\(state.namespaceMutationEpoch)",
                "scope": String(describing: scope),
            ]
        )
        requestReconcile()
    }

    /// Planning media facts for reorganization of one fixed library root.
    func planningMedia(for rootPath: LibraryRootPath, lane: CatalogReadLane) async -> [PlanningFileFacts]? {
        guard let state = roots[rootPath] else {
            return nil
        }
        do {
            let companions = try await reader(for: lane).readFreeingConnection { db in
                try Self.fetchCompanions(libraryRootID: state.rowID, db: db)
            }
            let companionsByPrimary = Dictionary(exactlyGrouping: companions) {
                $0.primaryRelativePath?.rawValue ?? ""
            }
            let unreadable = unreadableSourceIDs
            let rowID = state.rowID
            return try await reader(for: lane).readFreeingConnection { db in
                try MediaOperationGateway.fetchPlanningSourceMedia(
                    libraryRootID: rowID,
                    sourceRoot: rootPath,
                    companionsByPrimary: companionsByPrimary,
                    unreadableSourceIDs: unreadable,
                    db: db
                )
            }
        } catch {
            OtosLog.catalog.errorOperation(
                "reorganization.snapshot", phase: "failed",
                fields: ErrorDiagnostics.fields(for: error).merging(["rootPath": rootPath.rawValue]) { _, path in path }
            )
            return nil
        }
    }

    /// Immutable import planning snapshot for one source→destination pair.
    func importPlanningSnapshot(
        source: LibraryRootPath,
        destination: LibraryRootPath,
        policy: ImportPolicy,
        generation: UInt64,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current,
        lane: CatalogReadLane
    ) async throws -> ImportPlanningSnapshot? {
        guard let sourceState = roots[source],
              let destinationState = roots[destination]
        else {
            return nil
        }
        let sourceRowID = sourceState.rowID
        let destinationRowID = destinationState.rowID
        let companions = try await reader(for: lane).readFreeingConnection { db in
            try Self.fetchCompanions(libraryRootID: sourceRowID, db: db)
        }
        let companionsByPrimary = Dictionary(exactlyGrouping: companions) {
            $0.primaryRelativePath?.rawValue ?? ""
        }
        let unreadable = unreadableSourceIDs
        let sourceMedia = try await reader(for: lane).readFreeingConnection { db in
            try MediaOperationGateway.fetchPlanningSourceMedia(
                libraryRootID: sourceRowID,
                sourceRoot: source,
                companionsByPrimary: companionsByPrimary,
                unreadableSourceIDs: unreadable,
                db: db
            )
        }
        let destinationOccupants = try await reader(for: lane).readFreeingConnection { db in
            try MediaOperationGateway.fetchDestinationOccupants(
                libraryRootID: destinationRowID,
                db: db
            )
        }
        let libraryRowIDs = roots.availableFixedLibraryRowIDs()
        let pathsByRowID = roots.pathsByRowID
        let libraryContent = try await reader(for: lane).readFreeingConnection { db in
            try MediaOperationGateway.fetchLibraryContent(libraryRootIDs: libraryRowIDs, db: db)
        }.compactMapValues { pathsByRowID[$0] }
        let destinationCapabilities = await Self.probeCapabilities(of: destination)
        return ImportPlanningSnapshot(
            generation: generation,
            sourceRoot: source,
            destinationRoot: destination,
            sourceNamespaceRevision: sourceState.namespaceRevision,
            sourceNamingRevision: sourceState.namingRevision,
            destinationNamespaceRevision: destinationState.namespaceRevision,
            sourceMedia: sourceMedia,
            destinationOccupants: destinationOccupants,
            libraryContent: libraryContent,
            policy: policy,
            calendar: calendar,
            timeZone: timeZone,
            destinationCapabilities: destinationCapabilities
        )
    }

    /// The digests among `digests` that a fixed library still holds now: a row in an
    /// available library, not pending trash, with a digest current for its file. A card
    /// Erase asks this just before deleting items the plan skipped by content (ADR 0018).
    func librariesHoldContent(_ digests: Set<ContentDigest>, lane: CatalogReadLane) async throws -> Set<ContentDigest> {
        let libraryRowIDs = roots.availableFixedLibraryRowIDs()
        let held = try await reader(for: lane).readFreeingConnection { db in
            try MediaOperationGateway.fetchLibraryContent(libraryRootIDs: libraryRowIDs, db: db)
        }
        return digests.filter { held[$0] != nil }
    }

    /// The kind of a known root, so a caller can dispatch on what a root *is* rather
    /// than infer it from its path. Returns nil for a path this store does not know.
    func rootKind(for rootPath: LibraryRootPath) -> LibraryRootKind? {
        roots[rootPath]?.root.kind
    }

    /// The libraries once the initial load has applied, and nil before it: before the
    /// load the catalog's roots are unknown, which is not the same as having none
    /// (APP-044).
    func loadedLibraries() -> [CatalogLibraryState]? {
        started ? currentLibraries() : nil
    }

    func currentLibraries() -> [CatalogLibraryState] {
        roots.values
            .map { catalogLibraryState(from: $0) }
            .sorted {
                if $0.sortIndex != $1.sortIndex {
                    return $0.sortIndex < $1.sortIndex
                }
                return $0.path.rawValue < $1.path.rawValue
            }
    }

    /// Nonempty import batches newest-first, with photo counts for the batches `counting`
    /// names. Projection publishes these for the Imports
    /// sidebar section and All Imports. SQL lives in the gateway; Store owns `timedRead` and
    /// `roots` capture.
    func importBatches(counting: ImportBatchCounting, lane: CatalogReadLane) async throws -> [ImportBatchSummary] {
        let rootPaths = roots.pathsByRowID
        let pairing = rawPairing
        let timed = try await timedRead(reader(for: lane)) { db in
            try CatalogQueryGateway.fetchImportBatches(counting: counting, rootPaths: rootPaths, pairing: pairing, db: db)
        }
        OtosLog.catalog.debugOperation("catalog.store.importBatches", phase: "finish", fields: [
            "batches": "\(timed.value.count)",
            "counted": "\(timed.value.count { $0.photoCount != nil })",
            "waitMs": "\(timed.waitMs)",
            "execMs": "\(timed.execMs)",
        ])
        return timed.value
    }

    /// Surviving assets that carry the given import batch stamp, across fixed libraries.
    func assetIDs(inImportBatch batchID: ImportBatchID, lane: CatalogReadLane) async throws -> [MediaAssetID] {
        let pathsByRowID = roots.pathsByRowID
        return try await reader(for: lane).readFreeingConnection { db in
            try CatalogQueryGateway.fetchAssetIDs(inImportBatch: batchID, pathsByRowID: pathsByRowID, db: db)
        }
    }

    /// Reports cataloged assets that violate the total best-date invariant for
    /// planning (no embedded date and no filesystem/camera modification date).
    /// Camera items without any usable date are expected here and become
    /// `.blocked(.noUsableDate)` plan entries later — they are never silently dropped.
    func assetsMissingBestDateFacts(lane: CatalogReadLane) async throws -> [MediaAssetID] {
        let pathsByRowID = roots.pathsByRowID
        return try await reader(for: lane).readFreeingConnection { db in
            try CatalogQueryGateway.fetchAssetIDsMissingBestDate(pathsByRowID: pathsByRowID, db: db)
        }
    }

    /// Capture-wall naming fact for one asset, when enrichment selected a local-authority timestamp.
    func captureWall(for id: MediaAssetID, lane: CatalogReadLane) async throws -> CaptureWallClock.Selection? {
        guard let rootRowID = roots[id.libraryRootPath]?.rowID else {
            return nil
        }
        return try await reader(for: lane).readFreeingConnection { db in
            try CatalogQueryGateway.fetchCaptureWall(id: id, rootRowID: rootRowID, db: db)
        }
    }

    /// Companions inventoried under a root. Never appear in media queries.
    func companions(in rootPath: LibraryRootPath, lane: CatalogReadLane) async throws -> [MediaCompanion] {
        guard let rootRowID = roots[rootPath]?.rowID else {
            return []
        }
        return try await reader(for: lane).readFreeingConnection { db in
            try Self.fetchCompanions(libraryRootID: rootRowID, db: db)
        }
    }

    /// Whether `id`'s faces have been read and how many of its stored faces are still faces,
    /// whoever's they are, from one read, so the Info pane's `No Faces` and `Not Checked Yet`
    /// are the catalog's facts (APP-041). Nil when the asset is not cataloged.
    func facesRead(for id: MediaAssetID, lane: CatalogReadLane) async throws -> PhotoFacesRead? {
        guard let rootRowID = roots[id.libraryRootPath]?.rowID else {
            return nil
        }
        return try await reader(for: lane).readFreeingConnection { db -> PhotoFacesRead? in
            try Row.fetchOne(
                db,
                sql: PeopleSQL.facesReadSQL,
                arguments: AssetKey(rootID: rootRowID, path: id.relativePath).arguments
            ).map { row in
                PhotoFacesRead(photo: id, isRead: row["is_read"], faceCount: row["faces"])
            }
        }
    }

    /// The overlay the Info pane shows for `id` (APP-041): its companion files, the import it
    /// arrived in, whether it carries an edit, where its other copies are (ADR 0054), what
    /// search recognised in it — the confident
    /// scene labels of its current embedding row and the certain lines of its current text
    /// reading — and its current description (ADR 0053), each nil while owed. Nil when the
    /// asset is not cataloged.
    func photoInfoOverlay(for id: MediaAssetID, lane: CatalogReadLane) async throws -> PhotoInfoOverlay? {
        guard let rootRowID = roots[id.libraryRootPath]?.rowID else {
            return nil
        }
        let overlay = try await reader(for: lane).readFreeingConnection { db -> PhotoInfoOverlay? in
            let arguments = AssetKey(rootID: rootRowID, path: id.relativePath).arguments
            guard let asset = try Row.fetchOne(
                db,
                sql: AssetRowSQL.photoInfoAssetSQL,
                arguments: arguments
            ) else {
                return nil
            }
            let companions = try Row.fetchAll(
                db,
                sql: MediaCompanionSQL.companionsOfAssetSQL,
                arguments: arguments
            ).map { MediaRelativePath(rawValue: $0["relative_path"]).fileName }
            let batch: Int64? = asset["import_batch_unix_ms"]
            let hasDigest: Bool = asset["has_digest"]
            let isCopy: Bool = asset["is_copy"]
            // A row that is a copy of some photo lists its other copies; one with a digest
            // and no key has none; one with neither is not checked yet (its digest is owed).
            let copies = try isCopy ? String.fetchAll(
                db,
                sql: AssetRowSQL.photoInfoCopiesSQL,
                arguments: arguments
            ).map(LibraryRootPath.init(rawValue:)) : hasDigest ? [] : nil
            let labels = try Row.fetchOne(
                db,
                sql: SearchEmbeddingStorage.photoInfoLabelsSQL,
                arguments: arguments
            ).map { row -> [SceneLabel] in
                let scores = SearchEmbeddingStorage.labels(from: row[1])
                return SearchEmbeddingStorage.confidentLabels(from: row[0]).map { SceneLabel(identifier: $0, confidence: scores[$0]) }
            }
            let lines = try String.fetchOne(
                db,
                sql: SearchTextStorage.photoInfoLinesSQL,
                arguments: arguments
            )
            let description = try Row.fetchOne(db, sql: PhotoDescriptionStorage.currentRowSQL, arguments: arguments)
                .map { row -> PhotoDescriptionReading in
                    let text: String? = row["text"]
                    return text.map(PhotoDescriptionReading.written) ?? .declined
                }
            return try PhotoInfoOverlay(
                companionFileNames: companions,
                importedAt: batch.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                isEdited: asset["edited"],
                otherCopyRoots: copies,
                sceneLabels: labels,
                textLines: lines.map {
                    try SearchTextReading.shown(SearchTextStorage.reading(fromJSON: $0), sceneLabels: labels?.map(\.identifier) ?? [])
                },
                photoDescription: description
            )
        }
        guard roots[id.libraryRootPath]?.rowID == rootRowID else {
            return nil
        }
        return overlay
    }

    /// The faces stored for `id`, in the order its reading found them. Empty when the asset
    /// has none, has not been read for faces yet, or its library is no longer cataloged.
    func faces(of id: MediaAssetID, lane: CatalogReadLane) async throws -> [DetectedFace] {
        guard let rootRowID = roots[id.libraryRootPath]?.rowID else {
            return []
        }
        return try await reader(for: lane).readFreeingConnection { db in
            try Row.fetchAll(
                db,
                sql: PeopleSQL.photoFaceBoxesSQL,
                arguments: AssetKey(rootID: rootRowID, path: id.relativePath).arguments
            ).map { row in
                let landmarks: Data = row["landmarks"]
                guard let points = FaceStorage.landmarks(from: landmarks),
                      let vector = (row["embedding"] as Data?).flatMap(FaceStorage.embedding(from:))
                else {
                    throw CatalogStoreError.malformedFaceRow(id)
                }
                let quality: Double = row["quality"]
                return DetectedFace(
                    box: CGRect(x: row["box_x"] as Double, y: row["box_y"] as Double,
                                width: row["box_width"] as Double, height: row["box_height"] as Double),
                    landmarks: points,
                    quality: Float(quality),
                    embedding: vector
                )
            }
        }
    }

    // MARK: - People (ADR 0047)

    /// The roots of `availableLibraryPaths` whose faces Otos reads, by row ID.
    private func faceRootIDs(_ availableLibraryPaths: Set<LibraryRootPath>) -> [Int64] {
        availableLibraryPaths.compactMap { path in
            roots[path].flatMap { $0.root.kind.readsFaces ? $0.rowID : nil }
        }.sorted()
    }

    /// The unchecked tally alone (`PeopleSnapshot.unchecked`): what rows only added change.
    func uncheckedForFaces(availableLibraryPaths: Set<LibraryRootPath>, lane: CatalogReadLane) async throws -> MediaCount {
        let rootIDs = faceRootIDs(availableLibraryPaths)
        return try await reader(for: lane).readFreeingConnection { db in
            try Self.uncheckedForFaces(rootIDs: rootIDs, db: db)
        }
    }

    /// Everything assignment reads, in one transaction: each face with its photo's capture
    /// instant, its vector's number, whose word its person is and the user's acts on it, the
    /// people and the gallery facts stored for them. Never a vector — the face rows are narrow
    /// (v66), and `faceEmbeddings(after:limit:)` reads vectors apart — and never a tile, which
    /// the surfaces read by key. Faces of libraries no longer cataloged are left out. A photo
    /// with a face row no reading writes (no vector row, an assignment no case holds) is left
    /// out whole and owes its faces again (`oweFacesAgain`).
    ///
    /// With `photos`, only those photos' faces are read, each by key, with their copies and the
    /// stacks that hold them; the people, their stored facts and the key photos are read whole
    /// (they are few). What `PeopleAssignment` lays over the read it holds when a change named
    /// its rows (`PeopleSnapshot.replacing`), so a pass costs what changed.
    func peopleSnapshot(of photos: Set<MediaAssetID>? = nil, lane: CatalogReadLane) async throws -> PeopleSnapshot {
        let pathsByRowID = roots.pathsByRowID
        let rowIDs = roots.rowIDSnapshot()
        // The asked photos in the order a whole read gives them: by root row, then path.
        let asked = photos.map { photos in
            photos.compactMap { photo in rowIDs[photo.libraryRootPath].map { (rootID: $0, photo: photo) } }
                .sorted { PeopleSnapshot.isBefore(($0.rootID, $0.photo), ($1.rootID, $1.photo)) }
        }
        // Stacks of every root read for faces, mounted or not: a stack does not change when its
        // volume is unmounted, so availability never moves which file stands for a photo.
        let allFaceRootIDs = Set(roots.values.filter(\.root.kind.readsFaces).map(\.rowID))
        let accountRowIDs = Set(roots.values.filter { $0.root.kind == .immichAccount }.map(\.rowID))
        let operation = asked == nil ? "peopleSnapshot" : "peopleFaces"
        let pairing = rawPairing
        let (snapshot, malformed) = try await reader(for: lane).readFreeingConnection(operation: operation) { db -> (PeopleSnapshot, Set<AssetKey>) in
            var malformed: Set<AssetKey> = []
            var rejections: [FaceRowKey: Set<PersonID>] = [:]
            for row in try Row.fetchAll(db, sql: PeopleSQL.allFaceRejectionsSQL) {
                rejections[FaceRowKey(row), default: []].insert(PersonID(rawValue: row["person_id"]))
            }
            // Every face, built as `MappedArrayBuilder` says, then its columns at their length.
            var collected = MappedArrayBuilder<PeopleSnapshot.Face>()
            var keyPhotos: [PersonID: FaceID] = [:]
            // The digests of the files with a face and a present copy, whose copies follow.
            var copiedKeys: Set<Data> = []
            // A Live Photo's movie is one item with its still (ADR 0041), whose faces are its.
            // Read by position (`PeopleFaceColumn`): a name lookup scans the row's columns,
            // and at 18 columns over every face it was most of the read (bench
            // people.snapshot.10k, 2026-11-13). Stepped as a cursor, so one row is alive at a
            // time: every face's fetched row held at once was 84k arrays of values at the peak.
            let faceSQL = PeopleSQL.peopleFacesSQL
            // One path value per photo: a photo's faces come together in this order.
            var lastAsset: MediaAssetID?
            func take(_ row: Row) -> PeopleSnapshot.Face? {
                let rootID: Int64 = row[PeopleFaceColumn.rootID.rawValue]
                let pathText: String = row[PeopleFaceColumn.path.rawValue]
                if let digest = row[PeopleFaceColumn.copiedKey.rawValue] as Data? {
                    copiedKeys.insert(digest)
                }
                let path = lastAsset.flatMap { $0.relativePath.rawValue == pathText ? $0.relativePath : nil }
                    ?? MediaRelativePath(rawValue: pathText)
                let key = FaceRowKey(rootID: rootID, path: path, index: row[PeopleFaceColumn.faceIndex.rawValue])
                guard let rootPath = pathsByRowID[key.rootID], !malformed.contains(key.photo) else { return nil }
                let asset = lastAsset.flatMap { $0.libraryRootPath == rootPath && $0.relativePath == path ? $0 : nil }
                    ?? MediaAssetID(libraryRootPath: rootPath, relativePath: path)
                lastAsset = asset
                let vector: Int64? = row[PeopleFaceColumn.vector.rawValue]
                let person: Int64? = row[PeopleFaceColumn.personID.rawValue]
                guard let vector,
                      let assignment = try? FaceAssignmentColumn.assignment(
                          column: row[PeopleFaceColumn.assignment.rawValue], person: person
                      )
                else {
                    malformed.insert(key.photo)
                    return nil
                }
                let id = FaceID(asset: asset, index: key.index)
                if let person, (row[PeopleFaceColumn.isKeyPhoto.rawValue] as Int) != 0 {
                    keyPhotos[PersonID(rawValue: person)] = id
                }
                return PeopleSnapshot.Face(
                    id: id,
                    captureSeconds: row[PeopleFaceColumn.captureLocal.rawValue],
                    vector: vector,
                    assignment: assignment,
                    rejected: rejections[key] ?? [],
                    isInVideo: (row[PeopleFaceColumn.isVideo.rawValue] as Int) != 0,
                    likeness: (row[PeopleFaceColumn.likeness.rawValue] as Double?).map(Float.init)
                )
            }
            if let asked {
                let ofPhoto = try db.cachedStatement(sql: PeopleSQL.peopleFacesOfPhotoSQL)
                for (rootID, photo) in asked {
                    let rows = try Row.fetchCursor(
                        ofPhoto,
                        arguments: AssetKey(rootID: rootID, path: photo.relativePath).arguments
                    )
                    while let row = try rows.next() {
                        if let face = take(row) {
                            collected.append(face)
                        }
                    }
                }
                // Every key photo, not only the asked photos': they are few, from their index.
                keyPhotos = [:]
                for row in try Row.fetchAll(db, sql: PeopleSQL.keyPhotosSQL) {
                    if let face = Self.faceID(rootID: row[1], path: row[2], index: row[3], pathsByRowID: pathsByRowID) {
                        keyPhotos[PersonID(rawValue: row[0])] = face
                    }
                }
            } else {
                let rows = try Row.fetchCursor(db, sql: faceSQL + "\nORDER BY f.library_root_id, f.relative_path, f.face_index")
                while let row = try rows.next() {
                    if let face = take(row) {
                        collected.append(face)
                    }
                }
            }
            // The present copies of each photo with a face, by the key they share (ADR 0054).
            var copies: [[PeopleSnapshot.Copy]] = []
            let copiesOfKey = try db.cachedStatement(sql: PhotoFaceSQL.presentCopiesOfKey)
            for digest in copiedKeys {
                let photo = try Row.fetchAll(copiesOfKey, arguments: [digest]).compactMap { row -> PeopleSnapshot.Copy? in
                    let rootID: Int64 = row[0]
                    guard let rootPath = pathsByRowID[rootID] else { return nil }
                    return PeopleSnapshot.Copy(
                        asset: MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: row[1])),
                        rootID: rootID,
                        isAccount: accountRowIDs.contains(rootID)
                    )
                }
                if photo.count > 1 {
                    copies.append(photo)
                }
            }
            let people = try Row.fetchAll(
                db,
                sql: PeopleSQL.allPeopleSQL
            ).map(Self.person)
            let galleryFacts = try Self.storedGalleryFacts(db: db, pathsByRowID: pathsByRowID)
            let stackRoots = pathsByRowID.filter { allFaceRootIDs.contains($0.key) }
            let stacks: CatalogStacks
            if let asked {
                // The stacks that hold an asked photo, from the photos' own rows.
                let burst = try db.cachedStatement(sql: AssetRowSQL.askedPhotoBurstSQL)
                let rows = try Array(page: asked, atMost: asked.count) { rootID, photo in
                    try allFaceRootIDs.contains(rootID) ? CatalogQueryGateway.OrderedAssetIDRow(
                        libraryRootID: rootID, relativePath: photo.relativePath, captureLocalTime: nil, coordinate: nil,
                        burstIdentifier: String.fetchOne(
                            burst,
                            arguments: AssetKey(rootID: rootID, path: photo.relativePath).arguments
                        )
                    ) : nil
                }
                stacks = try PhotoStackSQL.build(rootPaths: stackRoots, holding: rows, pairing: pairing, db: db).stacks
            } else {
                stacks = try PhotoStackSQL.build(rootPaths: stackRoots, pairing: pairing, db: db).stacks
            }
            let photoOf = PeopleSnapshot.photos(stackKeys: stacks.keyOfMember, copies: copies)
            // A malformed row's photo is left out whole: its other faces were read before the
            // bad row was reached.
            let left = { (id: FaceID) in
                rowIDs[id.asset.libraryRootPath].map { !malformed.contains(AssetKey(rootID: $0, path: id.asset.relativePath)) } ?? true
            }
            var snapshot = PeopleSnapshot(
                faces: PeopleFaces(collected: collected) { malformed.isEmpty || left($0.id) },
                people: people,
                keyPhotos: keyPhotos.filter { left($0.value) },
                galleryFacts: galleryFacts,
                photoOf: photoOf,
                copies: PeopleSnapshot.ranked(copies),
                rootOrder: rowIDs
            )
            // In the same transaction as the faces: what this snapshot could have named.
            snapshot.vectorHorizon = try Int64.fetchOne(db, sql: PeopleSQL.vectorHorizonSQL) ?? 0
            return (snapshot, malformed)
        }
        if !malformed.isEmpty {
            let photos = malformed.compactMap { photo in
                pathsByRowID[photo.rootID].map { MediaAssetID(libraryRootPath: $0, relativePath: photo.path) }
            }
            try await oweFacesAgain(Set(photos))
        }
        return snapshot
    }

    /// Every person's gallery facts as stored (`person_summary`, v73).
    private static func storedGalleryFacts(
        db: Database, pathsByRowID: [Int64: LibraryRootPath]
    ) throws -> [PersonID: PersonGalleryFacts] {
        var facts: [PersonID: PersonGalleryFacts] = [:]
        for row in try Row.fetchAll(db, sql: PeopleSQL.personSummariesSQL) {
            facts[PersonID(rawValue: row[0])] = PersonGalleryFacts(
                media: MediaCount(photos: row[1], videos: row[2]),
                newestFace: Self.faceID(rootID: row[3], path: row[4], index: row[5], pathsByRowID: pathsByRowID)
            )
        }
        return facts
    }

    private static func faceID(rootID: Int64?, path: String?, index: Int?, pathsByRowID: [Int64: LibraryRootPath]) -> FaceID? {
        guard let rootID, let path, let index, let root = pathsByRowID[rootID] else { return nil }
        return FaceID(asset: MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: path)), index: index)
    }

    /// Writes each person's gallery facts that differ from what `stored` holds (ADR 0047,
    /// "What the People UI reads"): `computed` is every person's, from the same read. A
    /// background write in pages (`writeInPages`), announcing `.peopleGallery`, which only the
    /// gallery's read takes up, so the write never starts another assignment. A person deleted
    /// since the read is left alone, and a newest face deleted since is written as none, until
    /// the pass that deletion rings names another. Returns the people written.
    @discardableResult
    func writePeopleGalleryFacts(
        _ computed: [PersonID: PersonGalleryFacts],
        stored: [PersonID: PersonGalleryFacts]
    ) async throws -> Int {
        let rowIDs = roots.rowIDSnapshot()
        let writes = computed.compactMap { person, facts in
            stored[person] == facts ? nil : (person, facts)
        }.sorted { $0.0 < $1.0 }
        guard !writes.isEmpty else { return 0 }
        let (rows, _) = try await writeInPages(writes, state: 0, announcing: .peopleGallery) { write, _, db in
            let (person, facts) = write
            let cover = facts.newestFace.flatMap { face in
                rowIDs[face.asset.libraryRootPath].map { FaceRowKey(rootID: $0, path: face.asset.relativePath, index: face.index) }
            }
            // No newest face binds no key, and the join finds no face.
            try db.execute(
                sql: PeopleSQL.writePersonSummarySQL,
                arguments: [facts.media.photos, facts.media.videos]
                    + (cover?.photo.arguments ?? [nil, nil])
                    + [cover?.index, person.rawValue]
            )
            return db.changesCount
        }
        return rows
    }

    /// What the People gallery paints from (ADR 0047, "What the People UI reads"), in one
    /// transaction: every person with the gallery facts People stored for them and the tiles of
    /// their key photo and newest face, each read by key; the faces that define each person
    /// (`idx_face_anchor`); the unchecked tally of `availableLibraryPaths`; and whether any face
    /// is stored. Never a walk of every face. Nil while people exist and People has stored no
    /// facts for any of them: the gallery is not known yet.
    func peopleGallery(availableLibraryPaths: Set<LibraryRootPath>, lane: CatalogReadLane) async throws -> PeopleGalleryRead? {
        let pathsByRowID = roots.pathsByRowID
        let faceRootIDs = faceRootIDs(availableLibraryPaths)
        return try await reader(for: lane).readFreeingConnection { db -> PeopleGalleryRead? in
            let rows = try Row.fetchAll(db, sql: PeopleGallerySQL.people)
            guard rows.isEmpty || rows.contains(where: { ($0[5] as Int) != 0 }) else { return nil }
            let keyAt = PeopleGallerySQL.keyPhotoTileAt
            let coverAt = keyAt + FaceTileColumn.allCases.count
            let people = try rows.map { row -> PeopleGalleryRead.Person in
                let person = try Self.person(row)
                let isKnown = (row[5] as Int) != 0
                // A key photo counts while its face is still a face out of the Trash.
                let keyCounts = (row[8] as Int?).map { $0 != 0 } ?? false
                return PeopleGalleryRead.Person(
                    id: person.id, name: person.name, birthday: person.birthday,
                    isHidden: person.isHidden, isFavorite: person.isFavorite,
                    facts: isKnown ? PersonGalleryFacts(
                        media: MediaCount(photos: row[6], videos: row[7]),
                        newestFace: Self.faceTile(row, at: coverAt, pathsByRowID: pathsByRowID)?.id
                    ) : nil,
                    keyPhoto: keyCounts ? Self.faceTile(row, at: keyAt, pathsByRowID: pathsByRowID) : nil,
                    newest: Self.faceTile(row, at: coverAt, pathsByRowID: pathsByRowID)
                )
            }
            let userFaces = try Row.fetchAll(db, sql: PeopleGallerySQL.userFaces).compactMap { row -> PeopleGalleryRead.UserFace? in
                guard let root = pathsByRowID[row[1]] else { return nil }
                return PeopleGalleryRead.UserFace(
                    person: PersonID(rawValue: row[0]),
                    face: PersonAnchor(
                        photo: MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: row[2])),
                        isInVideo: (row[4] as Int) != 0,
                        captureSeconds: row[3]
                    )
                )
            }
            let hasFaces = try Bool.fetchOne(db, sql: PeopleGallerySQL.hasFaces) ?? false
            return try PeopleGalleryRead(
                people: people,
                userFaces: userFaces,
                unchecked: Self.uncheckedForFaces(rootIDs: faceRootIDs, db: db),
                hasFaces: hasFaces
            )
        }
    }

    /// Clears the faces stamp of each photo holding a face row no reading writes — found by the
    /// People read, or a vector whose bytes hold no embedding — so it is read for its faces
    /// again and the reading replaces the row (ADR 0047). A background write, in pages
    /// (`writeInPages`). Rings the change notifications only when a stamp was cleared, so the
    /// People read that found the rows does not start itself again. What it does on the actor
    /// does not grow with the photos beyond handing them to the pages: each photo is keyed in
    /// its page's write, and the call logs one line with their count and a few of them.
    func oweFacesAgain(_ photos: Set<MediaAssetID>) async throws {
        guard !photos.isEmpty else { return }
        let rowIDs = roots.rowIDSnapshot()
        let (cleared, _) = try await writeInPages(Array(photos), state: 0, announcing: [.faces, .detail], naming: .rows(photos)) { photo, _, db in
            guard let rootID = rowIDs[photo.libraryRootPath] else { return 0 }
            // One statement per photo: prepared once per connection, not once per photo (its
            // program, with every index of `media_asset` it keeps, is about 150 KB).
            try db.cachedStatement(sql: AssetEnrichmentSQL.oweFacesAgainSQL).execute(
                arguments: AssetKey(rootID: rootID, path: photo.relativePath).arguments
            )
            return db.changesCount
        }
        let sample = photos.prefix(Self.malformedFaceRowSample).map { "\($0.libraryRootPath.rawValue)/\($0.relativePath.rawValue)" }
        OtosLog.catalog.errorOperation("people.snapshot", phase: "malformedFaceRows", fields: [
            "photos": "\(photos.count)",
            "owedAgain": "\(cleared)",
            "sample": sample.joined(separator: ","),
        ])
        // A cleared stamp makes the photo one not yet checked for faces: People's tally, rung
        // by the pages that cleared one.
    }

    /// The most photos `oweFacesAgain`'s line names.
    static let malformedFaceRowSample = 5

    /// The vectors numbered above `vector`, in number order, at most `limit` of them: one short
    /// read of the vector table's primary key (`FaceEmbeddingSQL`). A row whose bytes are no
    /// embedding (not 512 values of unit length) comes back without one.
    func faceEmbeddings(after vector: Int64, limit: Int, lane: CatalogReadLane) async throws -> [FaceVectorStore.Read] {
        try await reader(for: lane).readFreeingConnection { db in
            try Array(page: Row.fetchCursor(
                db.cachedStatement(sql: PeopleSQL.embeddingsAfterSQL),
                arguments: [vector, limit]
            ), atMost: limit) { row in
                FaceVectorStore.Read(vector: row[0], embedding: FaceStorage.embedding(from: row[1]))
            }
        }
    }

    /// The hash of the assignment inputs whose assignment the catalog holds
    /// (`AssignmentInputs`); nil before any assignment has settled.
    func settledPeopleAssignment(lane: CatalogReadLane) async throws -> Data? {
        try await reader(for: lane).readFreeingConnection { db in
            try Data.fetchOne(db, sql: PeopleSQL.settledAssignmentInputsSQL)
        }
    }

    /// Records that the catalog holds assignment's output on the inputs hashed as `digest`. No
    /// change notification: nothing shown reads it.
    func recordSettledPeopleAssignment(_ digest: Data) async throws {
        _ = try await timedWrite(database()) { db in
            try db.execute(
                sql: PeopleSQL.writeSettledAssignmentInputsSQL,
                arguments: [digest]
            )
        }
    }

    /// The most rows one background write transaction changes (`writeInPages`): a few
    /// milliseconds of statements by key, so a write the user is waiting on — a Like, an act on
    /// a face — waits for at most one page of background work, never for all of it.
    static let backgroundWritePage = 256

    /// Writes `items` a page of `backgroundWritePage` at a time, each page its own named, timed
    /// transaction (`operation`), threading `state` from one page into the next. The one way a
    /// background owner writes many rows: one transaction for all of them held the writer for
    /// seconds while a Like queued behind it. Each item's write must stand on its own,
    /// re-checking in SQL what it depends on, since another write can land between two pages.
    /// When any page wrote a row, `announcing` is rung once, as the last page commits or as a
    /// later page fails: the pages that committed are catalog changes either way. Returns the
    /// rows the pages wrote and the state after the last. `rowsOf` is the most rows an item's
    /// write can change, its table's triggers' rows among them, so a page holds as many items
    /// as fit in `backgroundWritePage` rows.
    func writeInPages<Item: Sendable, State: Sendable>(
        _ items: [Item],
        state: State,
        announcing facts: CatalogChangedFacts,
        naming named: CatalogChangedRows = .unnamed,
        operation: String = #function,
        rowsOf: (Item) -> Int = { _ in 1 },
        _ write: @escaping @Sendable (Item, inout State, Database) throws -> Int
    ) async throws -> (rows: Int, state: State) {
        let dbWriter = try database()
        var rows = 0
        var state = state
        defer {
            if rows > 0 {
                notifyCatalogChanged(.changed(facts, rows: named))
            }
        }
        for bounds in Self.writePages(items.map(rowsOf)) {
            let page = Array(items[bounds])
            let pageState = state
            let written = try await timedWrite(dbWriter, operation: operation) { db -> (rows: Int, state: State) in
                var state = pageState
                var rows = 0
                for item in page {
                    rows += try write(item, &state, db)
                }
                return (rows, state)
            }
            rows += written.value.rows
            state = written.value.state
        }
        return (rows, state)
    }

    /// The pages `writeInPages` writes items in, given the most rows each changes: each page as
    /// many items, in order, as fit in `backgroundWritePage` rows, and at least one.
    static func writePages(_ rows: [Int]) -> [Range<Int>] {
        var pages: [Range<Int>] = []
        var start = 0
        while start < rows.count {
            var end = start + 1
            var pageRows = rows[start]
            while end < rows.count, pageRows + rows[end] <= backgroundWritePage {
                pageRows += rows[end]
                end += 1
            }
            pages.append(start ..< end)
            start = end
        }
        return pages
    }

    /// The faces of `files` and of their other present copies (ADR 0054) as the photo menus and
    /// the Info pane show them, read by key: each file's faces of visible people and its
    /// unidentified faces, in reading order, with their tiles; none marked not a face, none of
    /// a photo in the Trash or of a Live Photo's movie. `landedThrough` is stamped on the read
    /// as the caller's count of the People writes it had answered when it asked.
    func photoFaces(of files: [MediaAssetID], landedThrough: UInt64, lane: CatalogReadLane) async throws -> PhotoFaces {
        let pathsByRowID = roots.pathsByRowID
        let rowIDs = roots.rowIDSnapshot()
        let accountRowIDs = Set(roots.values.filter { $0.root.kind == .immichAccount }.map(\.rowID))
        let keys = Array(Set(files)).compactMap { file in
            rowIDs[file.libraryRootPath].map { (file, $0) }
        }
        guard !keys.isEmpty else {
            return PhotoFaces(photos: files, own: [:], landedThrough: landedThrough)
        }
        return try await reader(for: lane).readFreeingConnection { db in
            let facesOf = try db.cachedStatement(sql: PeopleSQL.photoFacesOfPhotoSQL)
            let digestOf = try db.cachedStatement(sql: AssetRowSQL.photoCopyKeySQL)
            let copiesOfKey = try db.cachedStatement(sql: PhotoFaceSQL.presentCopiesOfKey)
            var own: [MediaAssetID: [PhotoFace]] = [:]
            func read(_ file: MediaAssetID, rootID: Int64) throws {
                guard own[file] == nil else { return }
                own[file] = try Row.fetchAll(
                    facesOf,
                    arguments: AssetKey(rootID: rootID, path: file.relativePath).arguments
                ).compactMap { row in
                    Self.faceTile(row, at: 0, pathsByRowID: pathsByRowID).map {
                        PhotoFace(tile: $0, person: (row[FaceTileColumn.allCases.count] as Int64?).map(PersonID.init(rawValue:)))
                    }
                }
            }
            var copies: [MediaAssetID: [MediaAssetID]] = [:]
            for (file, rootID) in keys {
                try read(file, rootID: rootID)
                guard let digest = try Data.fetchOne(
                    digestOf,
                    arguments: AssetKey(rootID: rootID, path: file.relativePath).arguments
                ) else { continue }
                let group = try Row.fetchAll(copiesOfKey, arguments: [digest]).compactMap { row -> PeopleSnapshot.Copy? in
                    let copyRoot: Int64 = row[0]
                    guard let path = pathsByRowID[copyRoot] else { return nil }
                    return PeopleSnapshot.Copy(
                        asset: MediaAssetID(libraryRootPath: path, relativePath: MediaRelativePath(rawValue: row[1])),
                        rootID: copyRoot,
                        isAccount: accountRowIDs.contains(copyRoot)
                    )
                }
                guard group.count > 1 else { continue }
                let others = PeopleSnapshot.ranked([group])[0].filter { $0 != file }
                for (copy, copyRoot) in zip(group.map(\.asset), group.map(\.rootID)) where copy != file {
                    try read(copy, rootID: copyRoot)
                }
                copies[file] = others
            }
            return PhotoFaces(photos: files, own: own, copies: copies, landedThrough: landedThrough)
        }
    }

    /// Up to `limit` of `person`'s faces, newest first, one per photo — a photo's copies (ADR
    /// 0054) and a stack's files (ADR 0052) are one photo — out of the Trash and still faces:
    /// the row the Person sheet shows, read by key when it opens.
    func newestFaces(of person: PersonID, limit: Int, lane: CatalogReadLane) async throws -> [FaceTile] {
        let pathsByRowID = roots.pathsByRowID
        let faceRootPaths = pathsByRowID.filter { rowID, _ in
            roots.values.contains { $0.rowID == rowID && $0.root.kind.readsFaces }
        }
        let pairing = rawPairing
        return try await reader(for: lane).readFreeingConnection { db in
            let rows = try Row.fetchAll(db, sql: PeopleSQL.photoFaceTilesSQL, arguments: [person.rawValue])
            // One face of the person with what says which photo it is one of.
            struct Candidate {
                let tile: FaceTile
                let digest: Data?
                let rootID: Int64
                let burst: String?
            }
            let extra = FaceTileColumn.allCases.count
            var faces = rows.compactMap { row -> Candidate? in
                Self.faceTile(row, at: 0, pathsByRowID: pathsByRowID).map {
                    Candidate(tile: $0, digest: row[extra], rootID: row[FaceTileColumn.rootID.rawValue], burst: row[extra + 1])
                }
            }
            faces.sort { FaceTile.newestFirst($0.tile, $1.tile) }
            // Copies share their copy key; the files of a stack its key, from the stacks of the
            // newest files only, the ones the row can show.
            var seen: Set<Data> = []
            var byDigest = faces.filter { $0.digest.map { seen.insert($0).inserted } ?? true }
            byDigest = Array(byDigest.prefix(limit * 4))
            let stackRows = byDigest.map { face in
                CatalogQueryGateway.OrderedAssetIDRow(
                    libraryRootID: face.rootID, relativePath: face.tile.id.asset.relativePath,
                    captureLocalTime: face.tile.captureLocalTime, coordinate: nil, burstIdentifier: face.burst
                )
            }
            let stacks = try PhotoStackSQL.build(rootPaths: faceRootPaths, holding: stackRows, pairing: pairing, db: db).stacks.keyOfMember
            var photos: Set<MediaAssetID> = []
            return Array(byDigest.map(\.tile).filter { photos.insert(stacks[$0.id.asset] ?? $0.id.asset).inserted }.prefix(limit))
        }
    }

    /// The tile read from `row`'s `FaceTileColumn`s starting at `offset`; nil where the face is
    /// absent (an outer join that matched none) or its library is no longer cataloged.
    private static func faceTile(_ row: Row, at offset: Int, pathsByRowID: [Int64: LibraryRootPath]) -> FaceTile? {
        func column(_ column: FaceTileColumn) -> Int {
            offset + column.rawValue
        }
        guard let rootID = row[column(.rootID)] as Int64?, let root = pathsByRowID[rootID],
              let path = row[column(.path)] as String?, let index = row[column(.faceIndex)] as Int?
        else {
            return nil
        }
        let asset = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: path))
        return FaceTile(
            id: FaceID(asset: asset, index: index),
            box: CGRect(
                x: row[column(.boxX)] as Double,
                y: row[column(.boxY)] as Double,
                width: row[column(.boxWidth)] as Double,
                height: row[column(.boxHeight)] as Double
            ),
            preview: facePreview(row, at: offset, asset: asset),
            captureSeconds: row[column(.captureLocal)],
            isInVideo: (row[column(.isVideo)] as Int? ?? 0) != 0
        )
    }

    /// The stored image a face tile is cut from. A video's face: the image of its stored face
    /// frames it was read in, none for a face kept from an earlier reading. A still's: its
    /// stored preview, with the edit it shows, none before one is made, while a rendering of a
    /// newer edit is owed, or when the edit cannot be read (logged). The tile then shows its
    /// placeholder.
    private static func facePreview(_ row: Row, at offset: Int, asset: MediaAssetID) -> FacePreview? {
        func column(_ column: FaceTileColumn) -> Int {
            offset + column.rawValue
        }
        if let frameIndex = row[column(.frameIndex)] as Int? {
            return (row[column(.faceFramesPath)] as String?).map {
                FacePreview(name: $0, recipe: .neutral, image: frameIndex)
            }
        }
        guard let name: String = row[column(.previewPath)],
              (row[column(.previewEditIsKnown)] as Int? ?? 0) != 0
        else {
            return nil
        }
        let renderedRevision: Int64 = row[column(.renderedRevision)]
        do {
            let recipe = renderedRevision == 0
                ? .neutral
                : try editRecipe(json: row[column(.editRecipeJSON)]) ?? .neutral
            return FacePreview(name: name, recipe: recipe)
        } catch {
            OtosLog.catalog.errorOperation("people.faceTile", phase: "recipeUnreadable", fields: [
                "relativePath": asset.relativePath.rawValue, "error": String(describing: error),
            ])
            return nil
        }
    }

    private static func person(_ row: Row) throws -> PeopleSnapshot.Person {
        let id = PersonID(rawValue: row["id"])
        return try PeopleSnapshot.Person(
            id: id,
            name: row["name"],
            birthday: birthday(row["birthday"], of: id),
            isHidden: (row["is_hidden"] as Int) != 0,
            isFavorite: (row["is_favorite"] as Int) != 0
        )
    }

    /// A stored birthday; nil when the person has none. Every write stores a valid one.
    private static func birthday(_ text: String?, of person: PersonID) throws -> PersonBirthday? {
        guard let text else { return nil }
        guard let birthday = PersonBirthday(text) else { throw CatalogStoreError.malformedPersonRow(person) }
        return birthday
    }

    /// What is not yet read for faces (ADR 0047): stills whose stored preview is still to
    /// come, or whose faces were not read from the one they have, and videos of a library or
    /// an Immich account whose frames are not yet read. A Live Photo's movie is not counted: its still holds its faces.
    private static func uncheckedForFaces(rootIDs: [Int64], db: Database) throws -> MediaCount {
        guard !rootIDs.isEmpty else { return MediaCount() }
        let row = try Row.fetchOne(
            db,
            sql: PreviewFaceSQL.uncheckedSQL(rootCount: rootIDs.count),
            arguments: StatementArguments(Array(repeating: rootIDs, count: PreviewFaceSQL.uncheckedRootBindings).flatMap(\.self))
        )
        let owed: Int = row?[0] ?? 0
        let awaiting: Int = row?[1] ?? 0
        return MediaCount(photos: owed + awaiting, videos: row?[2] ?? 0)
    }

    /// Stills whose faces are owed from their stored preview (ADR 0047), in every library and
    /// Immich account: the preview's edit is known, and the faces stamp does not name the
    /// source that preview was made from. Videos are never read for faces. In catalog order,
    /// after `cursor`, from the partial index over the stills that owe them, so a catalog with
    /// nothing owed reads no row; a row whose edit cannot be read is passed over and logged.
    func previewFaceCandidates(after cursor: PreviewFaceCursor? = nil, limit: Int, lane: CatalogReadLane) async throws -> PreviewFacePage {
        let rootIDs = roots.values.filter(\.root.kind.readsFaces).map(\.rowID).sorted()
        guard !rootIDs.isEmpty else { return PreviewFacePage(candidates: [], next: nil) }
        let pathsByRowID = roots.pathsByRowID
        let arguments = StatementArguments(rootIDs) + [cursor?.rootID ?? Int64.min, cursor?.relativePath ?? "", limit]
        return try await reader(for: lane).readFreeingConnection { db in
            let rows = try Row.fetchAll(db, sql: PreviewFaceSQL.candidatesSQL(rootCount: rootIDs.count), arguments: arguments)
            let candidates = rows.compactMap { Self.previewFaceCandidate($0, pathsByRowID: pathsByRowID) }
            let next = rows.count < limit ? nil : rows.last.map {
                PreviewFaceCursor(rootID: $0["library_root_id"], relativePath: $0["relative_path"])
            }
            return PreviewFacePage(candidates: candidates, next: next)
        }
    }

    /// The stills of `ids` owed faces from their stored preview, by the same rule as the walk
    /// (`previewFaceCandidates(after:limit:lane:)`), in catalog order: what the reader reads for a
    /// change that names its rows and for the stills whose retry came due. Each is one seek of
    /// its own row, never a walk, so the read costs what was asked.
    func previewFaceCandidates(among ids: Set<MediaAssetID>, lane: CatalogReadLane) async throws -> [PreviewFaceCandidate] {
        let rootIDs = Set(roots.values.filter(\.root.kind.readsFaces).map(\.rowID))
        let rowIDs = roots.rowIDSnapshot()
        let pathsByRowID = roots.pathsByRowID
        let keys = ids.compactMap { id -> PreviewFaceCursor? in
            guard let rootID = rowIDs[id.libraryRootPath], rootIDs.contains(rootID) else { return nil }
            return PreviewFaceCursor(rootID: rootID, relativePath: id.relativePath.rawValue)
        }.sorted { ($0.rootID, $0.relativePath) < ($1.rootID, $1.relativePath) }
        var candidates: [PreviewFaceCandidate] = []
        var start = 0
        while start < keys.count {
            let batch = keys[start ..< min(start + Self.currentEmbeddingBatch, keys.count)]
            start += batch.count
            candidates += try await reader(for: lane).readFreeingConnection(operation: "previewFaceCandidatesByKey") { db in
                let statement = try db.cachedStatement(sql: PreviewFaceSQL.keyedCandidateSQL)
                return try batch.compactMap { key in
                    try Row.fetchOne(
                        statement,
                        arguments: AssetKey(rootID: key.rootID, path: MediaRelativePath(rawValue: key.relativePath)).arguments
                    )
                    .flatMap { Self.previewFaceCandidate($0, pathsByRowID: pathsByRowID) }
                }
            }
        }
        return candidates
    }

    /// One row of a preview face read as a candidate; nil for a root no longer held, or an edit
    /// that cannot be read (logged).
    private nonisolated static func previewFaceCandidate(_ row: Row, pathsByRowID: [Int64: LibraryRootPath]) -> PreviewFaceCandidate? {
        guard let root = pathsByRowID[row["library_root_id"]] else { return nil }
        let id = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: row["relative_path"]))
        let renderedRevision: Int64 = row["rendered_revision"]
        let recipe: EditRecipe
        do {
            recipe = renderedRevision == 0 ? .neutral : try Self.editRecipe(json: row["edit_recipe_json"]) ?? .neutral
        } catch {
            OtosLog.metadata.errorOperation("face.preview", phase: "recipeUnreadable", fields: [
                "relativePath": id.relativePath.rawValue, "error": String(describing: error),
            ])
            return nil
        }
        return PreviewFaceCandidate(
            id: id,
            previewPath: row["preview_path"],
            sourceSize: row["preview_source_size"],
            sourceMTimeSeconds: row["preview_source_mtime"],
            renderedRevision: renderedRevision,
            recipe: recipe
        )
    }

    /// Writes faces read from stored previews, for rows whose preview is still the one read;
    /// the faces are stamped with the preview's source stamp. Returns the rows written, and
    /// rings the change notifications when any was.
    @discardableResult
    func applyPreviewFaces(_ results: [PreviewFaceResult]) async throws -> Int {
        let rowIDs = roots.rowIDSnapshot()
        let written = try await database().write { db -> Set<MediaAssetID> in
            var written: Set<MediaAssetID> = []
            for result in results {
                guard let rootID = rowIDs[result.candidate.id.libraryRootPath] else { continue }
                // The preview file's name is the asset's own, so a new rendering keeps it: the
                // source stamp and the edit revision it shows say whether it is the one read.
                let current = try Row.fetchOne(
                    db,
                    sql: AssetEnrichmentSQL.previewFacesAreCurrentSQL,
                    arguments: AssetKey(rootID: rootID, path: result.candidate.id.relativePath).arguments
                        + [
                            result.candidate.previewPath,
                            result.candidate.sourceSize,
                            result.candidate.sourceMTimeSeconds,
                            result.candidate.renderedRevision,
                        ]
                )
                guard current != nil else { continue }
                try Self.writeFaces(
                    result.faces,
                    stamp: (result.candidate.sourceSize, result.candidate.sourceMTimeSeconds),
                    row: (rootID, result.candidate.id.relativePath),
                    db: db
                )
                written.insert(result.candidate.id)
            }
            return written
        }
        // People and the grid's faces read what was written, by key.
        if !written.isEmpty {
            notifyCatalogChanged(.changed([.faces, .detail], rows: .rows(written)))
        }
        return written.count
    }

    /// One write of an assignment plan, in the order `applyAssignment` writes them.
    private enum AssignmentWrite: Sendable {
        case lapse(FaceRowKey, PersonID)
        case seed(Int, FaceRowKey)
        case guess(FaceRowKey, FaceAssignmentResult.Person?)
        case likeness(FaceRowKey, Float?)
        case emptied(PersonID)

        /// The most rows the write changes: a face given or taken from a person also takes its
        /// photo out of the person it had and puts it in the one it has (`person_photo`, whose
        /// triggers write in the face's transaction); a seed may make its person.
        var mostRows: Int {
            switch self {
            case .lapse: 2
            case .guess: 3
            case .seed: 4
            case .likeness, .emptied: 1
            }
        }
    }

    /// What the pages of one plan carry from one to the next: each person the plan created,
    /// by its place in `newPeople`.
    private struct AssignmentPages: Sendable {
        var created: [Int: PersonID] = [:]
    }

    /// Writes what one assignment changed (ADR 0047), a page at a time (`writeInPages`): the
    /// lapsed seeds, then each new person with its seeds, the guesses, the likenesses and the
    /// people emptied. Each write stands on its own: a lapsed seed is released only while it is
    /// still that person's seed, and a guess or a seed is written only where the face is still
    /// Otos's to decide (none or a guess), so an act the user made since the snapshot, or
    /// between two pages, always wins; the next assignment sees it. A new person none of whose
    /// seeds could still be written is deleted again, and its guesses wait for the next
    /// assignment. A face whose library is no longer cataloged is skipped and counted. Returns
    /// the rows written; zero means the catalog already held the plan.
    @discardableResult
    func applyAssignment(_ plan: FaceAssignmentPlan) async throws -> Int {
        guard !plan.isEmpty else { return 0 }
        let rowIDs = roots.rowIDSnapshot()
        let key = { (face: FaceID) in try? FaceRowKey(face, rowIDs: rowIDs) }
        var writes: [AssignmentWrite] = []
        var skipped = 0
        func add(_ face: FaceID, _ write: (FaceRowKey) -> AssignmentWrite) {
            if let key = key(face) {
                writes.append(write(key))
            } else {
                skipped += 1
            }
        }
        for (face, person) in plan.lapsedSeeds {
            add(face) { .lapse($0, person) }
        }
        for (index, seeds) in plan.newPeople.enumerated() {
            for face in seeds {
                add(face) { .seed(index, $0) }
            }
        }
        for guess in plan.guesses {
            add(guess.face) { .guess($0, guess.person) }
        }
        for (face, likeness) in plan.likeness {
            add(face) { .likeness($0, likeness) }
        }
        writes += plan.emptied.map(AssignmentWrite.emptied)
        let skippedFaces = skipped
        let pageCount = Self.writePages(writes.map(\.mostRows)).count
        let (written, _) = try await writeInPages(
            writes, state: AssignmentPages(), announcing: .faces, naming: .rows(plan.photos),
            rowsOf: \.mostRows
        ) { write, pages, db in
            try Self.apply(write, pages: &pages, db: db)
        }
        OtosLog.catalog.debugOperation("people.applyAssignment", phase: "applied", fields: [
            "guesses": "\(plan.guesses.count)", "newPeople": "\(plan.newPeople.count)",
            "likeness": "\(plan.likeness.count)", "emptied": "\(plan.emptied.count)",
            "lapsedSeeds": "\(plan.lapsedSeeds.count)", "rows": "\(written)", "skippedFaces": "\(skippedFaces)",
            "pages": "\(pageCount)",
        ])
        return written
    }

    /// One write of a plan; returns the rows it changed, counting a created person once, when
    /// it keeps a seed.
    private static func apply(_ write: AssignmentWrite, pages: inout AssignmentPages, db: Database) throws -> Int {
        switch write {
        case let .lapse(key, person):
            try db.execute(
                sql: PeopleSQL.lapseFaceSQL,
                arguments: [FaceAssignmentColumn.open.rawValue]
                    + key.photo.arguments
                    + [key.index, FaceAssignmentColumn.seed.rawValue, person.rawValue]
            )
            return db.changesCount
        case let .seed(index, key):
            // A new person is made in the transaction of its first seed that lands, and
            // unmade there if it does not, so no page ever leaves a person with no face.
            let made = pages.created[index] == nil
            let person = try pages.created[index] ?? insertPerson(name: nil, birthday: nil, db: db)
            try db.execute(
                sql: PeopleSQL.seedFaceSQL,
                arguments: [person.rawValue, FaceAssignmentColumn.seed.rawValue] + key.photo.arguments + [key.index]
            )
            let seeded = db.changesCount
            guard seeded > 0 else {
                if made {
                    try db.execute(sql: PeopleSQL.deletePersonSQL, arguments: [person.rawValue])
                }
                return 0
            }
            pages.created[index] = person
            return seeded + (made ? 1 : 0)
        case let .guess(key, target):
            let person: PersonID?
            switch target {
            case let .existing(id): person = id
            case let .new(index):
                guard let id = pages.created[index] else { return 0 }
                person = id
            case nil: person = nil
            }
            try db.execute(
                sql: PeopleSQL.guessFaceSQL,
                arguments: [person?.rawValue, (person == nil ? FaceAssignmentColumn.open : .model).rawValue, person?.rawValue]
                    + key.photo.arguments
                    + [key.index, person?.rawValue, person?.rawValue]
            )
            return db.changesCount
        case let .likeness(key, likeness):
            try db.execute(
                sql: PeopleSQL.faceLikenessSQL,
                arguments: [likeness.map { Double($0) }] + key.photo.arguments + [key.index]
            )
            return db.changesCount
        case let .emptied(person):
            try db.execute(
                sql: PeopleSQL.deleteEmptyPersonSQL,
                arguments: [person.rawValue, person.rawValue]
            )
            return db.changesCount
        }
    }

    /// The one write path for what the user decides about faces and people (ADR 0047):
    /// performs one act in one transaction and returns what undoes it, with the person the
    /// act gave the faces to (for a merge, the person merged into). A refused act (a hard rule, `PeopleRuleViolation`) changes
    /// nothing.
    func perform(_ act: PeopleAct) async throws -> PeopleActOutcome {
        let rowIDs = roots.rowIDSnapshot()
        let pathsByRowID = roots.pathsByRowID
        let applied = try await database().write { db -> (restore: PeopleRestore, person: PersonID?) in
            let key = { (face: FaceID) throws -> FaceRowKey in try FaceRowKey(face, rowIDs: rowIDs) }
            let touched = try Self.touched(by: act, rowIDs: rowIDs, db: db)
            let before = try Self.restoreRecord(faces: touched.faces, people: touched.people, pathsByRowID: pathsByRowID, db: db)
            var created: [PersonID] = []
            var given: PersonID?
            switch act {
            case let .move(faces, person):
                given = person
                try Self.give(faces.map(key), to: person, db: db)
            case let .moveToNewPerson(faces, name, birthday):
                let keys = try faces.map(key)
                guard Set(keys.map(\.photo)).count == keys.count else { throw PeopleRuleViolation.twoFacesOfOnePhoto }
                if let name, try Int.fetchOne(db, sql: PeopleSQL.peopleNamedSQL, arguments: [name]) ?? 0 > 0 {
                    throw PeopleRuleViolation.nameTaken
                }
                let person = try Self.insertPerson(name: name, birthday: birthday, db: db)
                created.append(person)
                given = person
                try Self.give(keys, to: person, db: db)
            case let .removeName(faces):
                for face in try faces.map(key) {
                    try db.execute(
                        sql: PeopleSQL.rejectFaceNameSQL,
                        arguments: face.photo.arguments + [face.index]
                    )
                    try Self.setFace(face, person: nil, assignment: .held, db: db)
                }
            case let .notAFace(faces):
                for face in try faces.map(key) {
                    try Self.setFace(face, person: nil, assignment: .open, db: db)
                    try db.execute(
                        sql: PeopleSQL.markNotAFaceSQL,
                        arguments: face.photo.arguments + [face.index]
                    )
                }
            case let .edit(person, name, birthday):
                try Self.updatePerson(person, name: name, birthday: birthday, db: db)
            case let .merge(from, into):
                given = into
                try Self.mergePerson(from, into: into, pathsByRowID: pathsByRowID, db: db)
            case let .setHidden(person, hidden):
                try db.execute(sql: PeopleSQL.setPersonHiddenSQL, arguments: [hidden ? 1 : 0, person.rawValue])
            case let .setFavorite(person, favorite):
                try db.execute(sql: PeopleSQL.setPersonFavoriteSQL, arguments: [favorite ? 1 : 0, person.rawValue])
            case let .makeKeyPhoto(face, person):
                // Choosing a face as a person's cover is the user's word that it is them: the
                // face becomes theirs on the user's word, so a re-read carries the key photo
                // and assignment never moves it (ADR 0047).
                let face = try key(face)
                guard try Int64.fetchOne(
                    db,
                    sql: PeopleSQL.facePersonSQL,
                    arguments: face.photo.arguments + [face.index]
                ) == person.rawValue else { throw PeopleRuleViolation.unknownFace }
                try Self.give([face], to: person, db: db)
                try db.execute(sql: PeopleSQL.clearKeyPhotosOfPersonSQL, arguments: [person.rawValue])
                try db.execute(
                    sql: PeopleSQL.setKeyPhotoSQL,
                    arguments: face.photo.arguments + [face.index]
                )
            }
            var people = before.people
            for person in created {
                people[person] = .some(nil)
            }
            return (PeopleRestore(people: people, faces: before.faces, rejections: before.rejections), given)
        }
        let outcome = PeopleActOutcome(restore: applied.restore, person: applied.person)
        notifyCatalogChanged(.changed(.faces))
        OtosLog.catalog.noticeOperation("people.act", phase: "applied", fields: [
            "act": act.logName, "faces": "\(act.faceCount)",
        ])
        return outcome
    }

    /// Writes back what an act changed, undoing it, and returns what redoes the undo: the
    /// state the restore replaced. A face or rejection whose library is no longer cataloged has
    /// no row to write back: it is skipped, counted and logged (`op=people.restore`), as
    /// `applyAssignment` counts its skips.
    @discardableResult
    func restore(_ restore: PeopleRestore) async throws -> PeopleRestore {
        let rowIDs = roots.rowIDSnapshot()
        let pathsByRowID = roots.pathsByRowID
        let faces = restore.faces.compactMap { row in (try? FaceRowKey(row.face, rowIDs: rowIDs)).map { (row: row, key: $0) } }
        let rejections = restore.rejections.compactMap { rejection in
            (try? FaceRowKey(rejection.face, rowIDs: rowIDs)).map { (rejection: rejection, key: $0) }
        }
        let redo = try await database().write { db -> PeopleRestore in
            let faceKeys = faces.map(\.key)
            let people = Array(restore.people.keys)
            let current = try Self.restoreRecord(faces: faceKeys, people: people, pathsByRowID: pathsByRowID, db: db)
            // People first, so the faces and rejections below can name them.
            for (id, person) in restore.people {
                if let person {
                    try db.execute(
                        sql: PeopleSQL.restorePersonSQL,
                        arguments: [id.rawValue, person.name, person.birthday?.text, person.isHidden ? 1 : 0, person.isFavorite ? 1 : 0]
                    )
                }
            }
            // A person holds one key photo: clear theirs before writing back the one the
            // record holds.
            for row in restore.faces where row.isKeyPhoto {
                if let person = row.assignment.person {
                    try db.execute(sql: PeopleSQL.clearKeyPhotosOfPersonSQL, arguments: [person.rawValue])
                }
            }
            for (row, key) in faces {
                try db.execute(
                    sql: PeopleSQL.restoreFaceSQL,
                    arguments: [
                        row.assignment.person?.rawValue,
                        FaceAssignmentColumn(row.assignment).rawValue,
                        row.isNotFace ? 1 : 0,
                        row.isKeyPhoto ? 1 : 0,
                    ]
                        + key.photo.arguments
                        + [key.index]
                )
            }
            try Self.deleteRejections(faces: faceKeys, people: people, db: db)
            for (rejection, key) in rejections {
                // A face a new reading replaced is gone, and so is what was decided about it.
                try db.execute(
                    sql: PeopleSQL.restoreRejectionSQL,
                    arguments: key.photo.arguments
                        + [key.index, rejection.person.rawValue]
                        + key.photo.arguments
                        + [key.index, rejection.person.rawValue]
                )
            }
            // People the act created go last: deleting one clears what it held.
            for (id, person) in restore.people where person == nil {
                try db.execute(sql: PeopleSQL.deletePersonSQL, arguments: [id.rawValue])
            }
            // A person the act created exists now, so the redo re-creates them; a person it
            // removed does not, so the redo removes them again.
            return current
        }
        notifyCatalogChanged(.changed(.faces))
        // The libraries the skipped rows were in: few, since a restore is one act's faces.
        let skippedRoots = Set(restore.faces.map(\.face.asset.libraryRootPath) + restore.rejections.map(\.face.asset.libraryRootPath))
            .filter { rowIDs[$0] == nil }
        OtosLog.catalog.noticeOperation("people.restore", phase: "applied", fields: [
            "people": "\(restore.people.count)", "faces": "\(faces.count)", "rejections": "\(rejections.count)",
            "skippedFaces": "\(restore.faces.count - faces.count)",
            "skippedRejections": "\(restore.rejections.count - rejections.count)",
            "skippedRoots": skippedRoots.isEmpty ? "none" : skippedRoots.map(\.rawValue).sorted().joined(separator: ","),
        ])
        return redo
    }

    // MARK: People writes inside one transaction

    private static func insertPerson(name: String?, birthday: PersonBirthday?, db: Database) throws -> PersonID {
        try db.execute(sql: PeopleSQL.insertPersonSQL, arguments: [name, birthday?.text])
        return PersonID(rawValue: db.lastInsertedRowID)
    }

    /// Rename, Add Name and Set Birthday. A name another person holds is refused: the two
    /// are merged instead. A birthday after a photo the user gave the person is refused;
    /// Otos's own guesses and seeds from before it lose the person, and assignment gives
    /// those faces to someone else (`holdToBirthday`).
    private static func updatePerson(_ person: PersonID, name: String?, birthday: PersonBirthday?, db: Database) throws {
        if let name, try Int.fetchOne(
            db,
            sql: PeopleSQL.otherPeopleNamedSQL,
            arguments: [name, person.rawValue]
        ) ?? 0 > 0 {
            throw PeopleRuleViolation.nameTaken
        }
        try holdToBirthday(birthday, faces: [person], db: db)
        try db.execute(
            sql: PeopleSQL.setPersonNameAndBirthdaySQL,
            arguments: [name, birthday?.text, person.rawValue]
        )
    }

    /// The birthday rule on the faces of `people`, who are to have `birthday` (ADR 0047): a face
    /// from before it is never theirs. Refused when the user gave one of them such a face;
    /// every other such face, Otos's guess or seed, loses its person, for assignment to give
    /// out again. The one statement of the rule for Set Birthday and for a merge.
    /// The photos and videos `sql` lists, one row per item: its root, its path and whether it
    /// is a video. A refusal counts items, as its words do, never faces (`MediaCount`).
    private static func mediaCount(_ db: Database, sql: String, arguments: StatementArguments) throws -> MediaCount {
        var count = MediaCount()
        let rows = try Row.fetchCursor(db, sql: sql, arguments: arguments)
        while let row = try rows.next() {
            if (row[2] as Bool?) == true {
                count.videos += 1
            } else {
                count.photos += 1
            }
        }
        return count
    }

    /// In each photo where `from` and `into` both have a face the user gave or Otos seeded,
    /// keeps the face most like the person they become and holds the others (`.held`), and
    /// returns how many it held. Each was vouched for as that person and the photo holds them
    /// once, so it is no one Otos may name; left open, assignment would group such faces into
    /// a new person. "Most like" is assignment's likeness
    /// (`FaceAssignmentPolicy.likeness(of:toPersonWith:birthday:)`): the best similarity to
    /// both people's other defining faces within reach of the merged birthday. A face with no
    /// likeness ranks below one with any; on a tie, `into`'s face stays.
    private static func keepLikeliestFace(
        _ from: PersonID, into: PersonID, birthday: PersonBirthday?, pathsByRowID: [Int64: LibraryRootPath], db: Database
    ) throws -> Int {
        let shared = try Row.fetchAll(
            db,
            sql: PeopleSQL.photosAnchoringBothSQL,
            arguments: [from.rawValue, into.rawValue]
        ).map { AssetKey(rootID: $0["library_root_id"], path: MediaRelativePath(rawValue: $0["relative_path"])) }
        guard !shared.isEmpty else { return 0 }
        let sharedPhotos = Set(shared)
        struct Defining {
            let key: FaceRowKey
            let isInto: Bool
            let fact: FaceFact?
        }
        let defining = try Row.fetchAll(
            db,
            sql: PeopleSQL.definingFacesOfEitherSQL,
            arguments: [from.rawValue, into.rawValue]
        ).map { row -> Defining in
            let key = FaceRowKey(row)
            let person: Int64 = row["person_id"]
            let fact: FaceFact? = {
                guard let rootPath = pathsByRowID[key.rootID],
                      let embedding = (row["embedding"] as Data?).flatMap(FaceStorage.embedding(from:)),
                      let assignment = try? FaceAssignmentColumn.assignment(column: row["assignment"], person: person)
                else { return nil }
                return FaceFact(
                    id: FaceID(asset: MediaAssetID(libraryRootPath: rootPath, relativePath: key.path), index: key.index),
                    captureSeconds: row["best_capture_local"],
                    embedding: embedding,
                    assignment: assignment,
                    rejected: []
                )
            }()
            return Defining(key: key, isInto: person == into.rawValue, fact: fact)
        }
        let candidates = defining.filter { sharedPhotos.contains($0.key.photo) }
        let likeness = FaceAssignmentPolicy.likeness(
            of: candidates.compactMap(\.fact),
            toPersonWith: defining.compactMap(\.fact),
            birthday: birthday?.seconds
        )
        var held = 0
        for (_, faces) in Dictionary(exactlyGrouping: candidates, by: \.key.photo) where faces.count > 1 {
            let ranked = faces.sorted { lhs, rhs in
                let left = lhs.fact.flatMap { likeness[$0.id] } ?? -.infinity
                let right = rhs.fact.flatMap { likeness[$0.id] } ?? -.infinity
                if left != right {
                    return left > right
                }
                if lhs.isInto != rhs.isInto {
                    return lhs.isInto
                }
                return lhs.key.index < rhs.key.index
            }
            for face in ranked.dropFirst() {
                try setFace(face.key, person: nil, assignment: .held, db: db)
                held += 1
            }
        }
        return held
    }

    private static func holdToBirthday(_ birthday: PersonBirthday?, faces people: [PersonID], db: Database) throws {
        guard let birthdaySeconds = birthday?.seconds, !people.isEmpty else { return }
        let arguments = StatementArguments(people.map(\.rawValue)) + [birthdaySeconds]
        let earlier = try mediaCount(
            db,
            sql: PeopleSQL.confirmedBeforeBirthdaySQL(people: people.count),
            arguments: arguments
        )
        guard earlier.total == 0 else { throw PeopleRuleViolation.confirmedBeforeBirthday(earlier) }
        try db.execute(
            sql: PeopleSQL.openFacesBeforeBirthdaySQL(people: people.count),
            arguments: arguments
        )
    }

    /// Gives faces to a person on the user's word. Refused for two faces of one photo, a
    /// photo where the user already gave another face to the person, or a photo from before
    /// their birthday. Another face of the photo Otos had given the person loses them.
    private static func give(_ keys: [FaceRowKey], to person: PersonID, db: Database) throws {
        guard Set(keys.map(\.photo)).count == keys.count else { throw PeopleRuleViolation.twoFacesOfOnePhoto }
        guard let row = try Row.fetchOne(db, sql: PeopleSQL.personBirthdaySQL, arguments: [person.rawValue]) else {
            throw PeopleRuleViolation.unknownFace
        }
        let birthday = try Self.birthday(row["birthday"], of: person)?.seconds
        for key in keys {
            let others = try Int.fetchAll(
                db,
                sql: PeopleSQL.otherAssignmentsInPhotoSQL,
                arguments: key.photo.arguments + [person.rawValue, key.index]
            )
            guard !others.contains(FaceAssignmentColumn.user.rawValue) else { throw PeopleRuleViolation.personAlreadyInPhoto }
            if let birthday, let capture = try Double.fetchOne(
                db,
                sql: AssetRowSQL.photoCaptureLocalSQL,
                arguments: key.photo.arguments
            ), capture < birthday {
                throw PeopleRuleViolation.beforeBirthday
            }
        }
        for key in keys {
            try db.execute(
                sql: PeopleSQL.clearOtherFacesOfPersonSQL,
                arguments: key.photo.arguments + [person.rawValue, key.index]
            )
            try setFace(key, person: person, assignment: .user, db: db)
            try db.execute(
                sql: PeopleSQL.deleteFaceRejectionSQL,
                arguments: key.photo.arguments + [key.index, person.rawValue]
            )
        }
    }

    /// Sets a face's person and whose word it is; a face that changes person stops being its
    /// old person's key photo.
    private static func setFace(_ key: FaceRowKey, person: PersonID?, assignment: FaceAssignmentColumn, db: Database) throws {
        try db.execute(
            sql: PeopleSQL.setFaceSQL,
            arguments: [person?.rawValue, person?.rawValue, assignment.rawValue] + key.photo.arguments + [key.index]
        )
    }

    /// The first person's faces become the second's. Merging says the two are one person
    /// (owner, 2026-11-19: "If I merge, I know they're the same"), so every face of the
    /// person merged away stays the merged person's as an anchor: its guesses become seeds.
    /// Left as guesses, they would hang on the first person's anchors alone, and when those
    /// make way in a shared photo, the next assignment would group them into a new person
    /// again (owner's catalog, 2026-11-20). A photo both are in never
    /// refuses the merge: of the faces the user gave or Otos seeded for either in one photo,
    /// the one most like the merged person stays theirs and the others are held
    /// (`keepLikeliestFace`); the second person's guesses in a photo the first is in make way.
    /// Refused only when the user gave either a photo from before the merged birthday; Otos's
    /// guesses and seeds from before it lose their person (`holdToBirthday`).
    /// The second keeps its name, birthday and key photo, taking the first's where it
    /// has none, and is a favourite if either was.
    private static func mergePerson(
        _ from: PersonID, into: PersonID, pathsByRowID: [Int64: LibraryRootPath], db: Database
    ) throws {
        guard let target = try Row.fetchOne(db, sql: PeopleSQL.personSQL, arguments: [into.rawValue]).map(person),
              let source = try Row.fetchOne(db, sql: PeopleSQL.personSQL, arguments: [from.rawValue]).map(person)
        else {
            throw PeopleRuleViolation.unknownFace
        }
        let birthday = target.birthday ?? source.birthday
        try holdToBirthday(birthday, faces: [from, into], db: db)
        try db.execute(
            sql: PeopleSQL.demoteAnchorsToSeedsSQL,
            arguments: [from.rawValue]
        )
        // The second person's guesses in a photo the first is in: the first has only anchors.
        try db.execute(
            sql: PeopleSQL.openGuessesOfPersonSQL,
            arguments: [from.rawValue, into.rawValue, from.rawValue, into.rawValue]
        )
        let held = try keepLikeliestFace(from, into: into, birthday: birthday, pathsByRowID: pathsByRowID, db: db)
        OtosLog.catalog.noticeOperation("people.merge", phase: "applied", fields: [
            "from": "\(from.rawValue)",
            "into": "\(into.rawValue)",
            "held": "\(held)",
        ])
        let targetHasKeyPhoto = try Int.fetchOne(
            db, sql: PeopleSQL.keyPhotoCountSQL, arguments: [into.rawValue]
        ) ?? 0 > 0
        if targetHasKeyPhoto {
            try db.execute(sql: PeopleSQL.clearKeyPhotosOfPersonSQL, arguments: [from.rawValue])
        }
        try db.execute(sql: PeopleSQL.movePersonFacesSQL, arguments: [into.rawValue, from.rawValue])
        try db.execute(
            sql: PeopleSQL.moveRejectionsSQL,
            arguments: [into.rawValue, from.rawValue]
        )
        try db.execute(sql: PeopleSQL.deletePersonSQL, arguments: [from.rawValue])
        try db.execute(
            sql: PeopleSQL.setMergedPersonSQL,
            arguments: [target.name ?? source.name, birthday?.text, target.isFavorite || source.isFavorite ? 1 : 0, into.rawValue]
        )
    }

    /// The faces and people an act can change: every face of the photos it names, and every
    /// face of a person it merges or edits.
    private static func touched(
        by act: PeopleAct,
        rowIDs: [LibraryRootPath: Int64],
        db: Database
    ) throws -> (faces: [FaceRowKey], people: [PersonID]) {
        func faces(of people: [PersonID]) throws -> [FaceRowKey] {
            try people.flatMap { person in
                try Row.fetchAll(
                    db,
                    sql: PeopleSQL.facesOfPersonSQL,
                    arguments: [person.rawValue]
                ).map(FaceRowKey.init)
            }
        }
        func photos(_ faces: [FaceID]) throws -> [FaceRowKey] {
            try photosOf(faces.map { try FaceRowKey($0, rowIDs: rowIDs) })
        }
        func photosOf(_ keys: [FaceRowKey]) throws -> [FaceRowKey] {
            try Set(keys.map(\.photo)).flatMap { photo in
                try Row.fetchAll(
                    db,
                    sql: PeopleSQL.facesOfPhotoSQL,
                    arguments: photo.arguments
                ).map(FaceRowKey.init)
            }
        }
        func people(of keys: [FaceRowKey]) throws -> [PersonID] {
            try keys.compactMap { key in
                try Int64.fetchOne(
                    db,
                    sql: PeopleSQL.facePersonSQL,
                    arguments: key.photo.arguments + [key.index]
                ).map(PersonID.init(rawValue:))
            }
        }
        func keyPhotos(of people: [PersonID]) throws -> [FaceRowKey] {
            try people.flatMap { person in
                try Row.fetchAll(
                    db,
                    sql: PeopleSQL.keyPhotosOfPersonSQL,
                    arguments: [person.rawValue]
                ).map(FaceRowKey.init)
            }
        }
        switch act {
        case let .move(named, person):
            let keys = try photos(named)
            let involved = try [person] + people(of: keys)
            return try (keys + keyPhotos(of: involved), involved)
        case let .moveToNewPerson(named, _, _), let .removeName(named), let .notAFace(named):
            let keys = try photos(named)
            let involved = try people(of: keys)
            return try (keys + keyPhotos(of: involved), involved)
        case let .edit(person, _, _):
            return try (faces(of: [person]), [person])
        case let .merge(from, into):
            return try (photosOf(faces(of: [from, into])), [from, into])
        case let .setHidden(person, _), let .setFavorite(person, _):
            return ([], [person])
        case let .makeKeyPhoto(face, person):
            return try ([FaceRowKey(face, rowIDs: rowIDs)] + keyPhotos(of: [person]), [person])
        }
    }

    /// The rows `faces` and `people` hold now, and every rejection naming either.
    private static func restoreRecord(
        faces keys: [FaceRowKey],
        people: [PersonID],
        pathsByRowID: [Int64: LibraryRootPath],
        db: Database
    ) throws -> PeopleRestore {
        func faceID(_ key: FaceRowKey) -> FaceID? {
            pathsByRowID[key.rootID].map { FaceID(asset: MediaAssetID(libraryRootPath: $0, relativePath: key.path), index: key.index) }
        }
        var rows: [PeopleRestore.FaceRow] = []
        var rejections: Set<PeopleRestore.Rejection> = []
        for key in Set(keys) {
            guard let id = faceID(key), let row = try Row.fetchOne(
                db,
                sql: PeopleSQL.faceRestoreRecordSQL,
                arguments: key.photo.arguments + [key.index]
            ) else { continue }
            try rows.append(PeopleRestore.FaceRow(
                face: id,
                assignment: FaceAssignmentColumn.assignment(column: row["assignment"], person: row["person_id"]),
                isNotFace: (row["is_not_face"] as Int) != 0,
                isKeyPhoto: (row["is_key_photo"] as Int) != 0
            ))
            for person in try Int64.fetchAll(
                db,
                sql: PeopleSQL.faceRejectionPeopleSQL,
                arguments: key.photo.arguments + [key.index]
            ) {
                rejections.insert(.init(face: id, person: PersonID(rawValue: person)))
            }
        }
        var record: [PersonID: PeopleSnapshot.Person?] = [:]
        for person in Set(people) {
            let row = try Row.fetchOne(db, sql: PeopleSQL.personSQL, arguments: [person.rawValue])
            // `.some(nil)` keeps a missing person in the record: a plain nil would drop the key,
            // and the restore would forget to remove them.
            record[person] = try .some(row.map(Self.person))
            for row in try Row.fetchAll(
                db,
                sql: PeopleSQL.rejectionsOfPersonSQL,
                arguments: [person.rawValue]
            ) {
                if let id = faceID(FaceRowKey(row)) {
                    rejections.insert(.init(face: id, person: person))
                }
            }
        }
        return PeopleRestore(people: record, faces: rows, rejections: rejections)
    }

    /// Deletes every rejection naming one of `faces` or one of `people`: the scope a
    /// `PeopleRestore` records.
    private static func deleteRejections(faces keys: [FaceRowKey], people: [PersonID], db: Database) throws {
        for key in keys {
            try db.execute(
                sql: PeopleSQL.deleteFaceRejectionsSQL,
                arguments: key.photo.arguments + [key.index]
            )
        }
        for person in people {
            try db.execute(sql: PeopleSQL.deleteRejectionsOfPersonSQL, arguments: [person.rawValue])
        }
    }

    func skippedPackageCount(for rootPath: LibraryRootPath) -> Int {
        roots[rootPath]?.skippedPackageCount ?? 0
    }

    /// `dayBuckets` is empty unless `descriptor.effectiveSort.field == .bestDate`
    /// (day-contiguity — and so grouping — only holds under that sort), else
    /// index-paired with the returned IDs (DES-069; see
    /// `CatalogMediaGridState.dayBuckets`).
    ///
    /// `heldStacks`, when given, built over exactly the roots this read's stacks span and
    /// spanning them all (`PhotoStackSQL.Span.roots`), are used instead of reading the
    /// stack candidates again: the caller holds them while nothing they are built from moved
    /// (`CatalogChangedFacts.stackInputs`). Otherwise a narrow scope reads only its own
    /// folders' stacks (`PhotoStackSQL.build`). The stacks used, read or held, come back in
    /// `CatalogOrderedAssets.builtStacks`.
    func orderedAssetIDs(
        for descriptor: CatalogQueryDescriptor,
        availableLibraryPaths: Set<LibraryRootPath>,
        heldStacks: PhotoStackSQL.Built? = nil,
        lane: CatalogReadLane
    ) async throws -> CatalogOrderedAssets {
        let scope = scopePredicate(selection: descriptor.scope, availableLibraryPaths: availableLibraryPaths)
        guard !scope.selectsNothing else {
            var fields = [
                "scope": String(describing: descriptor.scope),
                "availablePaths": "\(availableLibraryPaths.count)",
            ]
            if case let .library(path) = descriptor.scope {
                fields["pathAvailable"] = "\(availableLibraryPaths.contains(path))"
                fields["pathRegistered"] = "\(roots[path] != nil)"
            }
            OtosLog.catalog.noticeOperation("catalog.store.query.order", phase: "selectsNothing", fields: fields)
            let pending = try await reader(for: lane).readFreeingConnection { db in
                try Self.fetchPendingIdentityRemapBatches(db: db)
            }
            return CatalogOrderedAssets(ids: [], dayBuckets: [], pendingIdentityRemaps: pending)
        }

        let signpost = OtosSignpost.persistence.beginInterval("CatalogStoreOrderedAssetIDQuery")
        // The stacks are built in the read with its rows, so every stack and row comes from
        // one snapshot (ADR 0052; `CatalogQueryGateway.readOrder`). Stacks the caller holds
        // over the same roots are used instead: it holds them only while nothing they are
        // built from has moved, so they are what this snapshot would build.
        let stackRootPaths = roots.pathsByRowID.filter { rowID, path in
            scope.rootIDs.contains(rowID) && availableLibraryPaths.contains(path)
        }
        // One read transaction: a row this read sees under a new identity always comes
        // with the pending batch that renamed it (ARC-052).
        let held = heldStacks.flatMap { $0.rootPaths == stackRootPaths && $0.span == .roots ? $0 : nil }
        // The rows become the window's IDs inside the read, on the connection's queue: at
        // 166,000 rows that is about half a second of work, and done here it held the Store
        // for it, so every read and intent behind it waited, a visible tile's among them
        // (`docs/research/2026-11-15-shared-reader-waits.md`).
        // `readDuration` is the order's read with its stacks'; `mapDuration` makes the rows
        // the window's IDs.
        let pairing = rawPairing
        let timedRows = try await timedRead(reader(for: lane)) { db in
            let readStart = ContinuousClock.now
            let order = try CatalogQueryGateway.readOrder(
                descriptor: descriptor,
                scope: scope,
                stackRootPaths: stackRootPaths,
                held: held,
                pairing: pairing,
                db: db
            )
            let mapStart = ContinuousClock.now
            let ordered = try Self.orderedAssets(
                from: order.rows,
                stacks: order.stacks.stacks,
                rootPathsByRowID: stackRootPaths,
                scope: scope,
                groupsByDate: descriptor.effectiveSort.field == .bestDate
            )
            return try (
                order: ordered,
                pending: Self.fetchPendingIdentityRemapBatches(db: db),
                stacks: order.stacks,
                readDuration: mapStart - readStart,
                mapDuration: ContinuousClock.now - mapStart
            )
        }
        OtosSignpost.persistence.endInterval("CatalogStoreOrderedAssetIDQuery", signpost)

        // A root that left while the read ran is no member of its answer.
        let rootPathsAfterRead = roots.pathsByRowID.filter { rowID, path in
            scope.rootIDs.contains(rowID) && availableLibraryPaths.contains(path)
        }
        var ids = timedRows.value.order.ids
        var dayBuckets = timedRows.value.order.dayBuckets
        var coordinates = timedRows.value.order.coordinates
        var captureSeconds = timedRows.value.order.captureSeconds
        if rootPathsAfterRead != stackRootPaths {
            let remaining = Set(rootPathsAfterRead.values)
            let kept = ids.indices.filter { remaining.contains(ids[$0].libraryRootPath) }
            ids = kept.map { ids[$0] }
            // Each is empty or index-paired with the order.
            dayBuckets = dayBuckets.isEmpty ? [] : kept.map { dayBuckets[$0] }
            coordinates = coordinates.isEmpty ? [] : kept.map { coordinates[$0] }
            captureSeconds = captureSeconds.isEmpty ? [] : kept.map { captureSeconds[$0] }
        }
        let queryMs = timedRows.totalMs
        // The log reports the stacks' read and rule apart from the order's own work (ADR 0052).
        let builtStacks = timedRows.value.stacks
        let catalogStacks = builtStacks.stacks
        // The order's own SQL: its read less the stacks' read and rule, which it includes.
        let stackMs = held == nil
            ? DiagnosticsTiming.milliseconds(builtStacks.readDuration) + DiagnosticsTiming.milliseconds(builtStacks.ruleDuration) : 0
        let orderSqlMs = max(0, DiagnosticsTiming.milliseconds(timedRows.value.readDuration) - stackMs)
        OtosLog.catalog.debug(
            """
            Catalog ordered asset IDs queried descriptor=\(descriptor.diagnosticDescription, privacy: .public) \
            roots=\(scope.rootIDs.count, privacy: .public) count=\(ids.count, privacy: .public) \
            waitMs=\(timedRows.waitMs, privacy: .public) \
            execMs=\(timedRows.execMs, privacy: .public) queryMs=\(queryMs, privacy: .public)
            """
        )
        if case let .anniversary(day) = scope.date {
            OtosLog.catalog.noticeOperation("onThisDay.query", phase: "finish", fields: [
                "day": day.diagnosticDescription,
                "count": "\(ids.count)",
                "queryMs": "\(queryMs)",
            ])
        }
        OtosLog.catalog.notice(
            "op=catalog.store.query.order phase=finish descriptor=\(descriptor.diagnosticDescription, privacy: .public) rootCount=\(scope.rootIDs.count, privacy: .public) count=\(ids.count, privacy: .public) stacks=\(held == nil ? "read" : "held", privacy: .public) stackSpan=\(builtStacks.span == .roots ? "roots" : "rows", privacy: .public) stackCandidates=\(held == nil ? builtStacks.candidateCount : 0, privacy: .public) stackReadMs=\(held == nil ? DiagnosticsTiming.milliseconds(builtStacks.readDuration) : 0, privacy: .public) stackRuleMs=\(held == nil ? DiagnosticsTiming.milliseconds(builtStacks.ruleDuration) : 0, privacy: .public) orderSqlMs=\(orderSqlMs, privacy: .public) mapMs=\(DiagnosticsTiming.milliseconds(timedRows.value.mapDuration), privacy: .public) waitMs=\(timedRows.waitMs, privacy: .public) execMs=\(timedRows.execMs, privacy: .public) lockMs=\(timedRows.lockMs, privacy: .public) resumeMs=\(timedRows.resumeMs, privacy: .public) priority=\(timedRows.priorityName, privacy: .public) queryMs=\(queryMs, privacy: .public)"
        )
        return CatalogOrderedAssets(
            ids: ids,
            dayBuckets: dayBuckets,
            coordinates: coordinates,
            pendingIdentityRemaps: timedRows.value.pending,
            stacks: catalogStacks,
            builtStacks: builtStacks,
            keys: captureSeconds.isEmpty ? nil : CatalogOrderKeys(
                captureSeconds: captureSeconds, rootIDs: Dictionary(uniqueKeysWithValues: rootPathsAfterRead.map { ($1, $0) })
            )
        )
    }

    /// The rows of `changed` that the scope of `descriptor` holds, in its order, with what the
    /// order sorts them by (`CatalogOrderedAssets.keys`): what a keyed re-read merges into the
    /// order it holds (`CatalogOrderPatch`). Each row is sought by its key, so the read costs
    /// the changed rows, not the scope. Nil for a scope the merge cannot answer: one not by
    /// date, or whose rows are named by anything but their roots, the filter and visibility.
    func orderedAssetIDs(
        ofRows changed: Set<MediaAssetID>,
        for descriptor: CatalogQueryDescriptor,
        availableLibraryPaths: Set<LibraryRootPath>,
        lane: CatalogReadLane
    ) async throws -> CatalogOrderedAssets? {
        let scope = scopePredicate(selection: descriptor.scope, availableLibraryPaths: availableLibraryPaths)
        guard descriptor.effectiveSort.field == .bestDate, scope.content == .any, scope.date == .any,
              scope.location == .any, scope.importBatchUnixMs == nil, !scope.selectsNothing
        else {
            return nil
        }
        let rootPaths = roots.pathsByRowID.filter { rowID, path in
            scope.rootIDs.contains(rowID) && availableLibraryPaths.contains(path)
        }
        let rowIDs = Dictionary(uniqueKeysWithValues: rootPaths.map { ($1, $0) })
        let keys = changed.compactMap { id in
            rowIDs[id.libraryRootPath].map { CatalogScopePredicate.MemberKey(rootID: $0, relativePath: id.relativePath.rawValue) }
        }
        let empty = CatalogOrderedAssets(
            ids: [], dayBuckets: [], pendingIdentityRemaps: [],
            keys: CatalogOrderKeys(captureSeconds: [], rootIDs: rowIDs)
        )
        guard !keys.isEmpty else {
            return empty
        }
        let members = CatalogScopePredicate(
            rootIDs: scope.rootIDs,
            content: .members(keys),
            showsOneCopy: scope.showsOneCopy,
            holdsEveryCopyRoot: scope.holdsEveryCopyRoot
        )
        let pairing = rawPairing
        let timed = try await timedRead(reader(for: lane)) { db in
            let rows = try CatalogQueryGateway.fetchOrderedAssetIDRows(
                descriptor: descriptor, scope: members, stacks: .readWhenNeeded(pairing), db: db
            )
            return Self.orderedAssets(from: rows, stacks: .empty, rootPathsByRowID: rootPaths, scope: members, groupsByDate: true)
        }
        OtosLog.catalog.noticeOperation("catalog.store.query.order", phase: "keyed", fields: [
            "descriptor": descriptor.diagnosticDescription,
            "changed": "\(changed.count)",
            "count": "\(timed.value.ids.count)",
            "waitMs": "\(timed.waitMs)",
            "execMs": "\(timed.execMs)",
        ])
        return CatalogOrderedAssets(
            ids: timed.value.ids,
            dayBuckets: timed.value.dayBuckets,
            pendingIdentityRemaps: [],
            keys: CatalogOrderKeys(captureSeconds: timed.value.captureSeconds, rootIDs: rowIDs)
        )
    }

    /// The window's order from the read's rows: each row whose root is one of the scope's
    /// as an ID, its capture day's start where the order groups by date, its coordinate where
    /// the scope requires a location. Pure, so it runs inside the read rather than on the Store.
    nonisolated static func orderedAssets(
        from rows: [CatalogQueryGateway.OrderedAssetIDRow],
        stacks: CatalogStacks,
        rootPathsByRowID: [Int64: LibraryRootPath],
        scope: CatalogScopePredicate,
        groupsByDate: Bool
    ) -> MappedOrder {
        // On This Day shows each day's Liked photos first (`OnThisDayPicks`).
        let orderedRows = scope.isAnniversary ? OnThisDayPicks.likedFirst(rows) : rows
        var ids: [MediaAssetID] = []
        var dayBuckets: [Date?] = []
        var dayStarts: [Int: Date] = [:]
        var coordinates: [PlaceCoordinate] = []
        var captureSeconds: [Double?] = []
        ids.reserveCapacity(orderedRows.count)
        if groupsByDate {
            dayBuckets.reserveCapacity(orderedRows.count)
            captureSeconds.reserveCapacity(orderedRows.count)
        }
        if scope.requiresLocation {
            coordinates.reserveCapacity(orderedRows.count)
        }
        // A date order hands over a root's rows and a day's rows together, so a row of the root
        // and the day before it costs two comparisons, not two dictionary lookups: those
        // lookups were most of the 2.8–3.5 s this loop took for All Media's 164,766 rows of a
        // generated owner-shaped catalog, unoptimized (`docs/research/2026-11-16-window-reads-owner-catalog.md`).
        var lastRoot: (id: Int64, path: LibraryRootPath?)?
        var lastDay: (number: Int, start: Date)?
        for row in orderedRows {
            if lastRoot?.id != row.libraryRootID {
                lastRoot = (row.libraryRootID, rootPathsByRowID[row.libraryRootID])
            }
            guard let rootPath = lastRoot?.path else {
                continue
            }
            if scope.requiresLocation {
                // The join guarantees a location on every row; a row without one would be
                // a query defect, not an item without a place, so it is not shown.
                guard let coordinate = row.coordinate else {
                    OtosLog.catalog.errorOperation("catalog.store.query.order", phase: "locationMissing", fields: [
                        "path": row.relativePath.rawValue,
                    ])
                    continue
                }
                coordinates.append(coordinate)
            }
            ids.append(MediaAssetID(libraryRootPath: rootPath, relativePath: row.relativePath))
            if groupsByDate {
                captureSeconds.append(row.captureLocalTime?.seconds)
                // The day the item was taken on (`CaptureLocalTime.dayNumber`), as the start
                // of that day here, which is what the header formats. A day's start is made
                // once per day, not once per row.
                dayBuckets.append(row.captureLocalTime.map { local in
                    let day = local.dayNumber
                    if let lastDay, lastDay.number == day {
                        return lastDay.start
                    }
                    let start = dayStarts[day] ?? Calendar.current.startOfDay(for: CaptureLocalTime(dayNumber: day).presentationDate())
                    dayStarts[day] = start
                    lastDay = (day, start)
                    return start
                })
            }
        }
        // On This Day judges a stack by its key: the SQL left out a Disliked key's row, and
        // its RAW twin or its burst's other frames leave with it (`OnThisDayPicks.shows`, the
        // rule its years-or-months match asks too).
        if scope.isAnniversary, !stacks.stacks.isEmpty {
            let kept = MappedArrayBuilder.collect(ids.indices) { OnThisDayPicks.shows(ids[$0], stacks: stacks) ? $0 : nil }
            if kept.count != ids.count {
                ids = kept.map { ids[$0] }
                // Each is empty or index-paired with the order.
                dayBuckets = dayBuckets.isEmpty ? [] : kept.map { dayBuckets[$0] }
                coordinates = coordinates.isEmpty ? [] : kept.map { coordinates[$0] }
                captureSeconds = captureSeconds.isEmpty ? [] : kept.map { captureSeconds[$0] }
            }
        }
        return MappedOrder(ids: ids, dayBuckets: dayBuckets, coordinates: coordinates, captureSeconds: captureSeconds)
    }

    /// The window's order as `orderedAssets(from:…)` makes it from the read's rows, each
    /// list empty or index-paired with `ids`. `captureSeconds` is each row's
    /// `best_capture_local` where the order is by date: what a keyed re-read places a changed
    /// row by (`CatalogOrderPatch`).
    struct MappedOrder {
        var ids: [MediaAssetID]
        var dayBuckets: [Date?]
        var coordinates: [PlaceCoordinate]
        var captureSeconds: [Double?]
    }

    func orderedAssetIDs(
        for selection: SidebarSelection,
        availableLibraryPaths: Set<LibraryRootPath>,

        lane: CatalogReadLane

    ) async throws -> [MediaAssetID] {
        try await orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: selection),
            availableLibraryPaths: availableLibraryPaths,
            lane: lane
        ).ids
    }

    /// Rows this scope holds regardless of whether their roots are reachable right
    /// now. Projection compares it against the visible count to tell "nothing was
    /// ever here" from "its libraries are offline", so it deliberately resolves
    /// against every known root.
    func catalogedAssetCount(for selection: SidebarSelection, lane: CatalogReadLane) async throws -> Int {
        let scope = scopePredicate(selection: selection, availableLibraryPaths: Set(roots.keys))
        guard !scope.selectsNothing else {
            return 0
        }
        let pairing = rawPairing
        let timedCount = try await timedRead(reader(for: lane)) { db in
            try CatalogQueryGateway.countAssets(scope: scope, pairing: pairing, db: db)
        }
        OtosLog.catalog.notice(
            "op=catalog.store.query.catalogedCount phase=finish selection=\(selection.diagnosticDescription, privacy: .public) rootCount=\(scope.rootIDs.count, privacy: .public) count=\(timedCount.value, privacy: .public) waitMs=\(timedCount.waitMs, privacy: .public) execMs=\(timedCount.execMs, privacy: .public) lockMs=\(timedCount.lockMs, privacy: .public) resumeMs=\(timedCount.resumeMs, privacy: .public) priority=\(timedCount.priorityName, privacy: .public) queryMs=\(timedCount.totalMs, privacy: .public)"
        )
        return timedCount.value
    }

    /// Rows this scope holds in currently reachable roots, under `filter` (the default
    /// ignores the user filter). Projection uses the unfiltered count to tell an empty
    /// scope from a scope the filter emptied, and the filtered All Media count to say
    /// how many items the Places map leaves out (ADR 0040).
    func visibleAssetCount(
        for selection: SidebarSelection,
        filter: MediaFilter = .all,
        availableLibraryPaths: Set<LibraryRootPath>,
        lane: CatalogReadLane
    ) async throws -> Int {
        let scope = scopePredicate(selection: selection, availableLibraryPaths: availableLibraryPaths)
        guard !scope.selectsNothing else {
            return 0
        }
        let pairing = rawPairing
        let timedCount = try await timedRead(reader(for: lane)) { db in
            try CatalogQueryGateway.countAssets(scope: scope, filter: filter, pairing: pairing, db: db)
        }
        OtosLog.catalog.notice(
            "op=catalog.store.query.visibleCount phase=finish selection=\(selection.diagnosticDescription, privacy: .public) filtered=\(filter.isActive, privacy: .public) rootCount=\(scope.rootIDs.count, privacy: .public) count=\(timedCount.value, privacy: .public) waitMs=\(timedCount.waitMs, privacy: .public) execMs=\(timedCount.execMs, privacy: .public) lockMs=\(timedCount.lockMs, privacy: .public) resumeMs=\(timedCount.resumeMs, privacy: .public) priority=\(timedCount.priorityName, privacy: .public) queryMs=\(timedCount.totalMs, privacy: .public)"
        )
        return timedCount.value
    }

    /// The options of `selection`'s sidebar row as each of its rows gives them
    /// (`CatalogFilterOptionTally`), with the names of the cells they give, by each cell's key,
    /// in the one language the catalog holds names in, when it holds them in one: the whole
    /// read, which a keyed re-read then patches (`filterOptionsOfRows`).
    func filterOptionTally(
        for selection: SidebarSelection,
        availableLibraryPaths: Set<LibraryRootPath>,
        placeNameLanguages: Set<PlaceNameLanguage>,
        lane: CatalogReadLane
    ) async throws -> CatalogFilterOptionTally {
        let row = selection.sidebarRow
        let language = placeNameLanguages.count == 1 ? placeNameLanguages.first : nil
        guard let scope = optionsScope(of: row, availableLibraryPaths: availableLibraryPaths) else {
            return CatalogFilterOptionTally(language: nil)
        }
        let pairing = rawPairing
        let timed = try await timedRead(reader(for: lane), operation: "filterOptions") { db in
            var tally = CatalogFilterOptionTally(language: language)
            // A scope that turns out to select nothing (a day with no photos) offers nothing.
            guard try CatalogQueryGateway.tallyFilterOptionRows(scope: scope, into: &tally, pairing: pairing, db: db) else {
                return CatalogFilterOptionTally(language: nil)
            }
            if let language {
                tally.names = try CatalogQueryGateway.placeCellNames(of: tally.cells, language: language, db: db)
            }
            return tally
        }
        OtosLog.catalog.noticeOperation("catalog.store.query.filterOptions", phase: "finish", fields: [
            "row": row.diagnosticDescription, "rootCount": "\(scope.rootIDs.count)", "rows": "\(timed.value.rowCount)",
            "types": "\(timed.value.typeCount)", "cells": "\(timed.value.cellCount)",
            "placeLanguage": language?.identifier ?? "none", "waitMs": "\(timed.waitMs)", "execMs": "\(timed.execMs)",
            "lockMs": "\(timed.lockMs)", "resumeMs": "\(timed.resumeMs)", "priority": timed.priorityName,
            "queryMs": "\(timed.totalMs)",
        ])
        return timed.value
    }

    /// What each of `changed` gives the options of `row` now, each by one seek of its key, and,
    /// in `language`, the names of the cells those rows give and of `renamed` (the held tally's
    /// cells, when the changes moved the cells' names), each by its key: what a change that
    /// names its rows re-reads (ADR 0005, "Keyed re-reads"). A changed row the scope does not
    /// count gives no fact; a key with no row gives nothing, since only a membership change
    /// removes a row and it reads the tally whole. Nil when the row's scope is not a whole set
    /// of roots (Places, a day, an import, a person), whose rows a key cannot test, and a whole
    /// read is owed.
    func filterOptionsOfRows(
        _ changed: Set<MediaAssetID>,
        namesIn language: PlaceNameLanguage?,
        renamed: Set<PlaceCell>,
        for row: SidebarSelection,
        availableLibraryPaths: Set<LibraryRootPath>,
        lane: CatalogReadLane
    ) async throws -> CatalogFilterOptionRows? {
        guard let scope = optionsScope(of: row, availableLibraryPaths: availableLibraryPaths),
              scope.content == .any, scope.date == .any, scope.location == .any, scope.importBatchUnixMs == nil
        else {
            return nil
        }
        let rootIDs = roots.rowIDSnapshot()
        let keys = changed.compactMap { id in
            rootIDs[id.libraryRootPath].flatMap { rootID in
                scope.rootIDs.contains(rootID) ? CatalogScopePredicate.MemberKey(rootID: rootID, relativePath: id.relativePath.rawValue) : nil
            }
        }
        let members = CatalogScopePredicate(
            rootIDs: scope.rootIDs,
            content: .members(keys),
            showsOneCopy: scope.showsOneCopy,
            holdsEveryCopyRoot: scope.holdsEveryCopyRoot
        )
        let pairing = rawPairing
        let timed = try await timedRead(reader(for: lane)) { db in
            var rows: [CatalogFilterOptionTally.Row] = []
            if !keys.isEmpty {
                rows = try CatalogQueryGateway.filterOptionRows(scope: members, pairing: pairing, db: db)
                let counted = Set(rows.map(\.rowID))
                let statement = try db.cachedStatement(sql: CatalogQueryGateway.rowIDOfKeySQL)
                for key in keys {
                    if let rowID = try Int64.fetchOne(
                        statement,
                        arguments: AssetKey(rootID: key.rootID, path: MediaRelativePath(rawValue: key.relativePath)).arguments
                    ), !counted.contains(rowID) {
                        rows.append(CatalogFilterOptionTally.Row(rowID: rowID, fact: nil))
                    }
                }
            }
            guard let language else {
                return CatalogFilterOptionRows(rows: rows, namedCells: [], names: [:])
            }
            let cells = renamed.union(rows.compactMap { $0.fact?.cell })
            let names = try CatalogQueryGateway.placeCellNames(of: cells, language: language, db: db)
            return CatalogFilterOptionRows(rows: rows, namedCells: cells, names: names)
        }
        OtosLog.catalog.noticeOperation("catalog.store.query.filterOptions", phase: "keyed", fields: [
            "row": row.diagnosticDescription, "changed": "\(changed.count)", "rows": "\(timed.value.rows.count)",
            "cells": "\(timed.value.namedCells.count)", "names": "\(timed.value.names.count)", "waitMs": "\(timed.waitMs)", "execMs": "\(timed.execMs)",
            "queryMs": "\(timed.totalMs)",
        ])
        return timed.value
    }

    /// The scope the options of `row` count: every copy of identical files, which share their
    /// bytes, so their kinds, formats and places (ADR 0054), so the options never depend on
    /// which file is a copy, a fact enrichment moves on almost every flush
    /// (`CatalogChangedFacts.filterOptionsInputs(of:)`). Nil for a scope that selects nothing.
    private func optionsScope(of row: SidebarSelection, availableLibraryPaths: Set<LibraryRootPath>) -> CatalogScopePredicate? {
        var scope = scopePredicate(selection: row, availableLibraryPaths: availableLibraryPaths)
        guard !scope.selectsNothing else {
            return nil
        }
        scope.showsOneCopy = false
        return scope
    }

    /// The languages the catalog holds place names in (ADR 0051): one once the reader has
    /// forgotten the others, none before anything is named. A held place filter lives only
    /// while its language is among them (`MediaFilter.keepingPlaces(namedIn:)`).
    func placeNameLanguages(lane: CatalogReadLane) async throws -> Set<PlaceNameLanguage> {
        try await reader(for: lane).readFreeingConnection { db in
            try Set(String.fetchAll(db, sql: CatalogQueryGateway.placeNameLanguagesSQL).map(PlaceNameLanguage.init(identifier:)))
        }
    }

    // MARK: - Place names (ADR 0040)

    /// Cells of the map holding a located item that Maps has not named in `language` yet,
    /// in cell order after `after` (from the first when nil), at most `limit`. Every located
    /// item counts, wherever it is cataloged, so a card's photos are named before they are
    /// imported. Walks `idx_asset_metadata_place_cell`.
    func unnamedPlaceCells(language: PlaceNameLanguage, after: PlaceCell? = nil, limit: Int, lane: CatalogReadLane) async throws -> [PlaceCell] {
        try await reader(for: lane).readFreeingConnection { db in
            try Row.fetchAll(
                db,
                sql: CatalogQueryGateway.unnamedPlaceCellsSQL(after: after != nil),
                arguments: StatementArguments(
                    (after.map { [$0.latitude, $0.longitude] as [any DatabaseValueConvertible] } ?? [])
                        + [language.identifier, limit]
                )
            ).map { PlaceCell(latitude: $0["place_cell_latitude"], longitude: $0["place_cell_longitude"]) }
        }
    }

    /// The cells of `ids` with no name in `language`, by key: the only cells a write that
    /// named its rows can have left unnamed (`PlaceNameReader`), read without walking every
    /// located record.
    func unnamedPlaceCells(language: PlaceNameLanguage, of ids: Set<MediaAssetID>, lane: CatalogReadLane) async throws -> [PlaceCell] {
        let rootIDs = roots.rowIDSnapshot()
        let byRoot = Dictionary(exactlyGrouping: ids, by: \.libraryRootPath).compactMap { path, rows in
            rootIDs[path].map { (rootID: $0, paths: rows.map(\.relativePath.rawValue)) }
        }
        guard !byRoot.isEmpty else {
            return []
        }
        return try await reader(for: lane).readFreeingConnection { db in
            var cells: Set<PlaceCell> = []
            for root in byRoot {
                let arguments: [any DatabaseValueConvertible] = [root.rootID] + root.paths + [language.identifier]
                try cells.formUnion(Row.fetchAll(
                    db,
                    sql: CatalogQueryGateway.unnamedPlaceCellsOfRowsSQL(count: root.paths.count),
                    arguments: StatementArguments(arguments)
                ).map { PlaceCell(latitude: $0["place_cell_latitude"], longitude: $0["place_cell_longitude"]) })
            }
            return cells.sorted { ($0.latitude, $0.longitude) < ($1.latitude, $1.longitude) }
        }
    }

    /// Stores what Maps named each cell in `language`. Only an answer reaches here, never a
    /// failed naming (`PlaceNameReader`), so a stored name is only ever replaced by another
    /// answer. A catalog change: the Places filter offers what was named.
    func applyPlaceNames(_ names: [PlaceCell: PlaceNames], language: PlaceNameLanguage) async throws {
        guard !names.isEmpty else { return }
        try await database().write { db in
            for (cell, name) in names {
                try db.execute(
                    sql: PlaceCellSQL.writeNamesSQL,
                    arguments: [cell.latitude, cell.longitude, name.country, name.town, language.identifier]
                )
            }
        }
        notifyCatalogChanged(.changed(.placeNames))
    }

    /// Forgets the names stored in any language but `language` (ADR 0051): the catalog keeps
    /// one language's names, so the filter never offers one place under two names, and a
    /// place held in the filter under its old name leaves the filter rather than match a
    /// dwindling share of its photos (`MediaFilter.keepingPlaces(namedIn:)`). Returns how
    /// many cells were forgotten; a catalog change when any.
    func forgetPlaceNames(notIn language: PlaceNameLanguage) async throws -> Int {
        let forgotten = try await database().write { db in
            try db.execute(sql: PlaceCellSQL.deleteOtherLanguagesSQL, arguments: [language.identifier])
            return db.changesCount
        }
        if forgotten > 0 {
            notifyCatalogChanged(.changed(.placeNames))
        }
        return forgotten
    }

    /// `askedAt` defaults to the instant the caller asks, before it reaches the Store.
    func mediaAssets(
        for ids: [MediaAssetID],
        askedAt: ContinuousClock.Instant = .now,
        lane: CatalogReadLane
    ) async throws -> [MediaAssetID: MediaAsset] {
        guard !ids.isEmpty else {
            return [:]
        }

        let storeMs = DiagnosticsTiming.milliseconds(since: askedAt)
        let signpost = OtosSignpost.persistence.beginInterval("CatalogStoreAssetsQuery")
        let rootIDsBeforeRead = roots.rowIDSnapshot()
        let timedAssets = try await timedRead(reader(for: lane), askedAt: askedAt) { db in
            try CatalogQueryGateway.fetchStoredAssets(ids: ids, rootIDsByPath: rootIDsBeforeRead, db: db)
        }
        OtosSignpost.persistence.endInterval("CatalogStoreAssetsQuery", signpost)

        var assetsByID: [MediaAssetID: MediaAsset] = [:]
        assetsByID.reserveCapacity(timedAssets.value.count)
        for storedAsset in timedAssets.value {
            guard let rootPath = roots.pathsByRowID[storedAsset.libraryRootID],
                  roots[rootPath]?.rowID == storedAsset.libraryRootID
            else {
                continue
            }
            let asset = mediaAsset(from: storedAsset, rootPath: rootPath)
            assetsByID[asset.id] = asset
        }

        if storeMs + timedAssets.totalMs > Self.slowQueryDiagnosticThresholdMs {
            recordSlowDetailQuery(
                operation: "catalog.store.query.assets",
                requestedCount: ids.count,
                returnedCount: assetsByID.count,
                storeMs: storeMs,
                timing: timedAssets
            )
        }
        return assetsByID
    }

    /// `askedAt` defaults to the instant the caller asks, before it reaches the Store.
    func mediaTileDetails(
        for ids: [MediaAssetID],
        askedAt: ContinuousClock.Instant = .now,
        lane: CatalogReadLane
    ) async throws -> [MediaAssetID: MediaTileDetail] {
        guard !ids.isEmpty else {
            return [:]
        }

        let storeMs = DiagnosticsTiming.milliseconds(since: askedAt)
        let signpost = OtosSignpost.persistence.beginInterval("CatalogStoreTileDetailQuery")
        let rootIDsBeforeRead = roots.rowIDSnapshot()
        let timedDetails = try await timedRead(reader(for: lane), askedAt: askedAt) { db in
            try CatalogQueryGateway.fetchStoredTileDetails(ids: ids, rootIDsByPath: rootIDsBeforeRead, db: db)
        }
        OtosSignpost.persistence.endInterval("CatalogStoreTileDetailQuery", signpost)

        var detailsByID: [MediaAssetID: MediaTileDetail] = [:]
        detailsByID.reserveCapacity(timedDetails.value.count)
        for storedDetail in timedDetails.value {
            guard let rootPath = roots.pathsByRowID[storedDetail.libraryRootID],
                  roots[rootPath]?.rowID == storedDetail.libraryRootID
            else {
                continue
            }
            let detail = mediaTileDetail(from: storedDetail, rootPath: rootPath)
            detailsByID[detail.id] = detail
        }

        let queryMs = timedDetails.totalMs
        OtosLog.catalog.debugOperation(
            "catalog.store.query.tileDetail",
            phase: "finish",
            fields: [
                "requested": "\(ids.count)",
                "returned": "\(detailsByID.count)",
                "storeMs": "\(storeMs)",
                "waitMs": "\(timedDetails.waitMs)",
                "execMs": "\(timedDetails.execMs)",
                "queryMs": "\(queryMs)",
            ]
        )
        if storeMs + queryMs > Self.slowQueryDiagnosticThresholdMs {
            recordSlowDetailQuery(
                operation: "catalog.store.query.tileDetail",
                requestedCount: ids.count,
                returnedCount: detailsByID.count,
                storeMs: storeMs,
                timing: timedDetails
            )
        }
        return detailsByID
    }

    /// Snapshots only catalog-proven physical members for explicit system-Trash
    /// commands. Device/MTP rows are intentionally excluded because they do not
    /// represent user-filesystem originals. Companion membership comes from the
    /// inventoried pairing table, never from a filename heuristic; a Live Photo's motion
    /// movie from the pair rule (ADR 0041).
    func mediaTrashItems(for ids: [MediaAssetID], lane: CatalogReadLane) async throws -> [MediaTrashItem] {
        var seen = Set<MediaAssetID>()
        let requested = ids.filter { seen.insert($0).inserted }
        let assets = try await mediaAssets(for: requested, lane: lane)
        var items: [MediaTrashItem] = []
        for id in requested {
            guard let rootState = roots[id.libraryRootPath],
                  rootState.root.kind.supportsMoveToTrash,
                  assets[id] != nil
            else {
                continue
            }
            let (companions, motion) = try await reader(for: lane).readFreeingConnection { db in
                try (
                    Self.fetchCompanions(libraryRootID: rootState.rowID, db: db)
                        .filter { $0.primaryRelativePath == id.relativePath },
                    CatalogQueryGateway.fetchLivePhotoMotions(
                        libraryRootID: rootState.rowID,
                        stillPaths: [id.relativePath],
                        db: db
                    )[id.relativePath]
                )
            }
            let members = companions.map {
                MediaTrashMember(relativePath: $0.relativePath, role: .companion, byteSize: $0.byteSize)
            } + [motion].compactMap(\.self).map {
                MediaTrashMember(relativePath: $0.relativePath, role: .livePhotoMotion, byteSize: $0.byteSize)
            } + [MediaTrashMember(relativePath: id.relativePath, role: .primary, byteSize: assets[id]?.byteSize)]
            items.append(MediaTrashItem(id: id, root: rootState.root, members: members))
        }
        return items
    }

    /// The motion movie of `id` when it is a Live Photo's still (ADR 0041), else nil.
    func livePhotoMotion(of id: MediaAssetID, lane: CatalogReadLane) async throws -> MediaAssetID? {
        guard let rootID = roots[id.libraryRootPath]?.rowID else { return nil }
        return try await reader(for: lane).readFreeingConnection { db in
            try CatalogQueryGateway.fetchLivePhotoMotions(
                libraryRootID: rootID,
                stillPaths: [id.relativePath],
                db: db
            )[id.relativePath]?.id(in: id.libraryRootPath)
        }
    }

    /// Hides the requested items behind one pending Move to Trash. Only existing,
    /// non-device rows that are not already pending are marked; the returned IDs are
    /// exactly the rows this call hid, in request order.
    /// Hides the items behind a pending Move to Trash. `carrying` is the authored work the
    /// duplicates act moves onto kept copies (ADR 0042): it is written in the same
    /// transaction, only for copies this call hid, and only where the kept copy lacks that
    /// work — so a move that hides nothing carries nothing. What it wrote is recorded under
    /// the batch for `revertCarriedWork`.
    func markPendingTrash(
        _ ids: [MediaAssetID],
        batch: MediaTrashBatchID,
        carrying carries: [DuplicateCarry] = []
    ) async throws -> [MediaAssetID] {
        try await setPendingTrash(ids, batch: batch, carrying: carries, operation: "mark")
    }

    /// Undo of a duplicates Move to Trash: puts back what the batch carried onto kept copies,
    /// for the moved copies that came back. Work carried from a copy still in the Trash stays
    /// on the kept copy, since its source is not back to hold it.
    func revertCarriedWork(batch: MediaTrashBatchID, restored: Set<MediaAssetID>) async throws {
        guard let records = carriedWorkByBatch[batch] else {
            return
        }
        let reverting = records.filter { restored.contains($0.from) }
        guard !reverting.isEmpty else {
            carriedWorkByBatch[batch] = nil
            return
        }
        let rootIDs = roots.rowIDSnapshot()
        let reverted = try await database().write { db in
            var reverted = CarriedWorkWrite()
            for record in reverting {
                guard let rootID = rootIDs[record.to.libraryRootPath] else {
                    continue
                }
                switch record.previous {
                case let .choice(previous):
                    try db.execute(
                        sql: AssetRowSQL.setChoiceSQL,
                        arguments: [previous.rawValue]
                            + AssetKey(rootID: rootID, path: record.to.relativePath).arguments
                    )
                    if db.changesCount > 0 {
                        reverted.record(record)
                    }
                case let .edit(previousJSON):
                    if try Self.replaceEditRecipe(
                        json: previousJSON,
                        rootID: rootID,
                        relativePath: record.to.relativePath.rawValue,
                        db: db
                    ) {
                        reverted.record(record)
                    }
                }
            }
            return reverted
        }
        // Forgotten only once written: a failed write leaves the record for a retry.
        carriedWorkByBatch[batch] = nil
        if !reverted.rows.isEmpty {
            notifyCatalogChanged(.changed(reverted.facts, rows: .rows(reverted.rows)))
        }
        OtosLog.catalog.noticeOperation("catalog.duplicateCarry", phase: "reverted", fields: [
            "batch": "\(batch.unixMilliseconds)",
            "records": "\(records.count)",
            "reverted": "\(reverted.rows.count)",
        ])
    }

    /// Ends a pending Move to Trash without moving anything: the items reappear.
    /// Returns exactly the rows this call un-hid.
    func clearPendingTrash(_ ids: [MediaAssetID]) async throws -> [MediaAssetID] {
        try await setPendingTrash(ids, batch: nil, carrying: [], operation: "clear")
    }

    private func setPendingTrash(
        _ ids: [MediaAssetID],
        batch: MediaTrashBatchID?,
        carrying carries: [DuplicateCarry],
        operation: String
    ) async throws -> [MediaAssetID] {
        var seen = Set<MediaAssetID>()
        let requested = ids.filter { seen.insert($0).inserted }
        let eligible = requested.compactMap { id -> (MediaAssetID, Int64)? in
            guard let rootState = roots[id.libraryRootPath], rootState.root.kind.supportsMoveToTrash else {
                return nil
            }
            return (id, rootState.rowID)
        }
        guard !eligible.isEmpty else {
            return []
        }
        let rootIDs = roots.rowIDSnapshot()
        let dbWriter = try database()
        let (changed, carried) = try await dbWriter.write { db in
            var changed: [MediaAssetID] = []
            for (id, rootID) in eligible {
                // Mark touches only visible rows; clear touches only pending ones whose file
                // has not moved yet — a row whose file is in the Trash shows again only when
                // the file comes back to its path.
                try db.execute(
                    sql: AssetRowSQL.setPendingTrashSQL,
                    arguments: [batch?.unixMilliseconds]
                        + AssetKey(rootID: rootID, path: id.relativePath).arguments
                        + [batch != nil]
                )
                if db.changesCount > 0 {
                    changed.append(id)
                }
            }
            let hidden = Set(changed)
            let carried = try carries.filter { hidden.contains($0.from) && !hidden.contains($0.to) }.compactMap { carry in
                try Self.carryWork(carry, rootIDs: rootIDs, db: db)
            }
            return (changed, carried)
        }
        if let batch, !carried.isEmpty {
            carriedWorkByBatch[batch] = carried
        }
        if !changed.isEmpty {
            // The rows it hid or showed, and the kept copies it carried work onto.
            var wrote = CarriedWorkWrite()
            for record in carried {
                wrote.record(record)
            }
            notifyCatalogChanged(.changed(
                CatalogChangedFacts.presence.union(wrote.facts),
                rows: .rows(Set(changed).union(wrote.rows))
            ))
        }
        OtosLog.catalog.noticeOperation(
            "catalog.pendingTrash",
            phase: operation,
            fields: [
                "batch": batch.map { "\($0.unixMilliseconds)" } ?? "none",
                "requested": "\(requested.count)",
                "changed": "\(changed.count)",
                "carried": "\(carried.count)",
            ]
        )
        return changed
    }

    /// Writes one carry inside the hiding transaction when the kept copy still lacks the work
    /// and the moved copy still holds it; returns what the kept copy held before.
    private nonisolated static func carryWork(
        _ carry: DuplicateCarry,
        rootIDs: [LibraryRootPath: Int64],
        db: Database
    ) throws -> DuplicateCarryRecord? {
        guard let fromRoot = rootIDs[carry.from.libraryRootPath], let toRoot = rootIDs[carry.to.libraryRootPath],
              let from = try Row.fetchOne(
                  db,
                  sql: AssetRowSQL.carriedWorkSQL,
                  arguments: AssetKey(rootID: fromRoot, path: carry.from.relativePath).arguments
              ),
              let to = try Row.fetchOne(
                  db,
                  sql: AssetRowSQL.carriedWorkSQL,
                  arguments: AssetKey(rootID: toRoot, path: carry.to.relativePath).arguments
              )
        else {
            return nil
        }
        switch carry.work {
        case .choice:
            let moved = MediaChoice(rawValue: from["media_choice"] ?? "") ?? .default
            let kept = MediaChoice(rawValue: to["media_choice"] ?? "") ?? .default
            guard moved != .notRated, kept == .notRated else {
                return nil
            }
            try db.execute(
                sql: AssetRowSQL.setChoiceSQL,
                arguments: [moved.rawValue] + AssetKey(rootID: toRoot, path: carry.to.relativePath).arguments
            )
            return DuplicateCarryRecord(from: carry.from, to: carry.to, previous: .choice(kept))
        case .edit:
            guard let movedJSON = from["edit_recipe_json"] as String?, (to["edit_recipe_json"] as String?) == nil else {
                return nil
            }
            guard try replaceEditRecipe(json: movedJSON, rootID: toRoot, relativePath: carry.to.relativePath.rawValue, db: db)
            else {
                return nil
            }
            return DuplicateCarryRecord(from: carry.from, to: carry.to, previous: .edit(nil))
        }
    }

    /// Re-catalogs an item undo moved back from the Trash. Its row never left the catalog
    /// (ADR 0022): it was kept, hidden, while the file sat in the Trash. Reconciling the
    /// returned paths from the filesystem — exactly as a file event would — sees the file at
    /// the row's own path, which shows the row again with everything Otos held for it.
    /// Returns whether the item is back: its row exists and is no longer hidden. A failed
    /// read is logged and answers false.
    func restoreTrashedItem(_ trashed: TrashedItem, lane: CatalogReadLane) async -> Bool {
        guard let rootRowID = roots[trashed.item.root.path]?.rowID else {
            return false
        }
        let root = trashed.item.root.path
        var changed: CatalogChangedFacts = []
        for restored in trashed.members {
            let path = restored.member.relativePath
            recordIndependentNamespaceMutation(root: root, scope: .file(path), fileAction: .upsert)
            if case let .changed(facts) = await reconcileFile(
                path,
                action: .upsert,
                root: root,
                rootRowID: rootRowID,
                witness: nil
            ) {
                changed.formUnion(facts)
            }
        }
        let primaryPath = trashed.item.id.relativePath.rawValue
        let isBack: Bool
        do {
            isBack = try await reader(for: lane).readFreeingConnection { db in
                try Bool.fetchOne(
                    db,
                    sql: AssetRowSQL.restoredRowIsBackSQL,
                    arguments: AssetKey(rootID: rootRowID, path: MediaRelativePath(rawValue: primaryPath)).arguments
                ) ?? false
            }
        } catch {
            OtosLog.catalog.errorOperation("mediaTrash.undo", phase: "restoreReadFailed", fields: [
                "path": primaryPath,
                "error": String(describing: error),
            ])
            isBack = false
        }
        // A row back by an earlier write was announced by that write.
        if !changed.isEmpty {
            notifyCatalogChanged(.changed(changed))
        }
        OtosLog.catalog.noticeOperation("mediaTrash.undo", phase: "restored", fields: [
            "path": primaryPath,
            "rowBack": "\(isBack)",
        ])
        return isBack
    }

    /// Every item still waiting to move to the Trash, oldest command first, each
    /// with its catalog-proven members. The durable queue `MediaTrashCoordinator`
    /// drains, including after relaunch.
    func pendingTrashItems(lane: CatalogReadLane) async throws -> [PendingTrashItem] {
        // Rows map to roots through the loaded registry; before the catalog's one load
        // the registry is empty and every pending row would be silently skipped.
        try await loadIfNeeded()
        let pathsByRowID = roots.pathsByRowID
        let rows: [(rootID: Int64, relativePath: String, batchMs: Int64)] = try await reader(for: lane).readFreeingConnection { db in
            try Row.fetchAll(
                db,
                sql: AssetRowSQL.pendingTrashOfBatchSQL
            ).map { row in
                (row["library_root_id"], row["relative_path"], row["pending_trash_batch_unix_ms"])
            }
        }
        var batches: [MediaAssetID: MediaTrashBatchID] = [:]
        var ordered: [MediaAssetID] = []
        for row in rows {
            guard let rootPath = pathsByRowID[row.rootID] else {
                continue
            }
            let id = MediaAssetID(
                libraryRootPath: rootPath,
                relativePath: MediaRelativePath(rawValue: row.relativePath)
            )
            batches[id] = MediaTrashBatchID(unixMilliseconds: row.batchMs)
            ordered.append(id)
        }
        return try await mediaTrashItems(for: ordered, lane: lane).compactMap { item in
            batches[item.id].map { PendingTrashItem(batch: $0, item: item) }
        }
    }

    /// Changes the authored choice for every existing requested asset in one SQLite
    /// transaction. A repeated choice is accepted with zero changed rows so the UI's
    /// optional advance policy can still treat `U` as a deliberate command.
    func setMediaChoice(
        _ choice: MediaChoice,
        for ids: [MediaAssetID]
    ) async throws -> MediaChoiceMutationResult {
        try await setMediaChoices(Dictionary(ids.map { ($0, choice) }, uniquingKeysWith: { _, last in last }))
    }

    /// One transaction assigning a possibly different choice per asset. Rows that no
    /// longer exist are skipped; the result reports each existing row's prior value.
    /// Writes each member's key-choice stamp (ADR 0052): Make Key Photo stamps the chosen
    /// member now and clears the stack's other members; undo writes back what it returns.
    /// Returns every member's previous stamp, for members that still exist; an empty result
    /// changed nothing.
    func setStackKeyChoices(
        _ stamps: [MediaAssetID: Int64?],
        kind: PhotoStackKind
    ) async throws -> [MediaAssetID: Int64?] {
        guard !stamps.isEmpty else { return [:] }
        let rootIDs = roots.rowIDSnapshot()
        let dbWriter = try database()
        let (previous, changed) = try await dbWriter.write { db -> ([MediaAssetID: Int64?], Int) in
            var previous: [MediaAssetID: Int64?] = [:]
            var changed = 0
            for (id, stamp) in stamps {
                guard let rootID = rootIDs[id.libraryRootPath],
                      let row = try Row.fetchOne(
                          db,
                          sql: AssetRowSQL.stackKeyChoiceSQL(kind),
                          arguments: AssetKey(rootID: rootID, path: id.relativePath).arguments
                      )
                else {
                    continue
                }
                previous[id] = row[0] as Int64?
                try db.execute(
                    sql: AssetRowSQL.setStackKeyChoiceSQL(kind),
                    arguments: [stamp] + AssetKey(rootID: rootID, path: id.relativePath).arguments + [stamp]
                )
                changed += db.changesCount
            }
            return (previous, changed)
        }
        OtosLog.catalog.noticeOperation("stack.key", phase: "written", fields: [
            "kind": kind.rawValue, "requested": "\(stamps.count)", "existing": "\(previous.count)", "changed": "\(changed)",
        ])
        if changed > 0 {
            notifyCatalogChanged(.changed(.choices))
        }
        return previous
    }

    func setMediaChoices(_ assignments: [MediaAssetID: MediaChoice]) async throws -> MediaChoiceMutationResult {
        guard !assignments.isEmpty else {
            return MediaChoiceMutationResult(existingCount: 0, changedCount: 0)
        }
        let rootIDs = roots.rowIDSnapshot()
        let dbWriter = try database()
        let result = try await dbWriter.write { db in
            var existingCount = 0
            var changedCount = 0
            var previous: [MediaAssetID: MediaChoice] = [:]
            for (id, choice) in assignments {
                guard let rootID = rootIDs[id.libraryRootPath] else {
                    continue
                }
                guard let current = try String.fetchOne(
                    db,
                    sql: AssetRowSQL.mediaChoiceSQL,
                    arguments: AssetKey(rootID: rootID, path: id.relativePath).arguments
                ) else {
                    continue
                }
                existingCount += 1
                previous[id] = MediaChoice(rawValue: current) ?? .default
                try db.execute(
                    sql: AssetRowSQL.changeMediaChoiceSQL,
                    arguments: [choice.rawValue]
                        + AssetKey(rootID: rootID, path: id.relativePath).arguments
                        + [choice.rawValue]
                )
                changedCount += db.changesCount
            }
            return MediaChoiceMutationResult(
                existingCount: existingCount,
                changedCount: changedCount,
                previous: previous
            )
        }
        if result.changedCount > 0 {
            notifyCatalogChanged(.changed(.choices))
        }
        OtosLog.catalog.noticeOperation(
            "catalog.mediaChoice",
            phase: "finish",
            fields: [
                "choices": Set(assignments.values).map(\.rawValue).sorted().joined(separator: "+"),
                "requested": "\(assignments.count)",
                "existing": "\(result.existingCount)",
                "changed": "\(result.changedCount)",
            ]
        )
        return result
    }

    /// The photo's current recipe, or nil when it was never edited (ADR 0036).
    func editRecipe(for id: MediaAssetID, lane: CatalogReadLane) async throws -> StoredEditRecipe? {
        guard let rootID = roots.rowIDSnapshot()[id.libraryRootPath] else {
            return nil
        }
        return try await reader(for: lane).readFreeingConnection { db in
            guard let row = try Row.fetchOne(
                db,
                sql: AssetRowSQL.editRecipeSQL,
                arguments: AssetKey(rootID: rootID, path: id.relativePath).arguments
            ) else {
                return nil
            }
            return try Self.storedEditRecipe(json: row["edit_recipe_json"], revision: row["edit_revision"])
        }
    }

    /// Saves `recipe` as the photo's current edit under the next revision and reports the
    /// recipe it replaced, so a caller can register the exact inverse (APP-039's pattern).
    /// Saving the recipe already current changes nothing and is reported as unchanged.
    func setEditRecipe(_ recipe: EditRecipe, for id: MediaAssetID) async throws -> EditRecipeMutationResult {
        guard let rootID = roots.rowIDSnapshot()[id.libraryRootPath] else {
            return EditRecipeMutationResult(exists: false, previous: nil, saved: nil)
        }
        let json = try Self.editRecipeJSON(recipe)
        let (result, held) = try await database().write { db -> (EditRecipeMutationResult, Bool) in
            guard let row = try Row.fetchOne(
                db,
                sql: AssetRowSQL.editRecipeRowSQL,
                arguments: AssetKey(rootID: rootID, path: id.relativePath).arguments
            ) else {
                return (EditRecipeMutationResult(exists: false, previous: nil, saved: nil), false)
            }
            let previous = try Self.storedEditRecipe(json: row["edit_recipe_json"], revision: row["edit_revision"])
            guard (previous?.recipe ?? .neutral) != recipe else {
                return (EditRecipeMutationResult(exists: true, previous: previous, saved: nil), false)
            }
            // An edit is a copy's work, which the keeper rule weighs (ADR 0042).
            let held = try DuplicatesHoldSQL.holds(libraryRootID: rootID, relativePath: id.relativePath.rawValue, db: db)
            let modified: Double? = row["content_modified_at_unix"]
            let isVideo = (row["best_kind"] as String?) == MediaKind.video.rawValue
            // The row's revision, not the saved edit's: a photo with no edit saved (a reset, an
            // undone first edit) still counts on from its last revision, so a revision never
            // names two edits and a rendering of one is never taken for the other.
            let revision = (row["edit_revision"] as Int64) + 1
            try Self.writeEditRecipe(
                json: json,
                revision: revision,
                isVideo: isVideo,
                rootID: rootID,
                relativePath: id.relativePath.rawValue,
                db: db
            )
            return (EditRecipeMutationResult(
                exists: true,
                previous: previous,
                saved: StoredEditRecipe(recipe: recipe, revision: revision),
                sourceSize: row["byte_size"],
                sourceMTimeSeconds: modified.map { Int($0.rounded(.down)) },
                isVideo: isVideo
            ), held)
        }
        if result.saved != nil {
            notifyCatalogChanged(.changed(held ? [.images, .faceTiles, .detail, .duplicateFacts] : [.images, .faceTiles, .detail], rows: .rows([id])))
        }
        OtosLog.catalog.noticeOperation("catalog.editRecipe", phase: "finish", fields: [
            "rootPath": id.libraryRootPath.rawValue,
            "relativePath": id.relativePath.rawValue,
            "exists": "\(result.exists)",
            "revision": result.saved.map { "\($0.revision)" } ?? "unchanged",
        ])
        return result
    }

    /// Promotes a thumbnail and preview rendered from recipe `revision` (ADR 0036) — only
    /// while that revision is still the photo's current edit and the file is the one it
    /// was rendered from; otherwise the staged files are discarded and a newer save's
    /// render, or enrichment, supplies them. Returns whether they were applied.
    func applyRenderedEditProducts(_ products: RenderedEditProducts) async -> Bool {
        let staged = [products.thumbnail, products.preview]
        guard let rootID = roots.rowIDSnapshot()[products.id.libraryRootPath], let derivedFolder else {
            discardStagedImages(staged)
            return false
        }
        let outcome: (applied: Bool, removal: DerivedRemoval, held: Bool)
        do {
            outcome = try await database().write { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: AssetEnrichmentSQL.renderedEditRowSQL,
                    arguments: AssetKey(rootID: rootID, path: products.id.relativePath).arguments
                ) else {
                    return (false, .nothing, false)
                }
                let revision: Int64 = row["edit_revision"]
                let byteSize: Int64? = row["byte_size"]
                let modified: Double? = row["content_modified_at_unix"]
                guard revision == products.revision,
                      byteSize == products.sourceSize,
                      modified.map({ Int($0.rounded(.down)) }) == products.sourceMTimeSeconds
                else {
                    return (false, .nothing, false)
                }
                // A new thumbnail leaves a compared still's signature stale (ADR 0042).
                let held = try DuplicatesHoldSQL.holds(
                    libraryRootID: rootID, relativePath: products.id.relativePath.rawValue, db: db
                )
                for image in staged {
                    try derivedFolder.promote(image, db: db)
                }
                try db.execute(
                    sql: AssetEnrichmentSQL.writeRenderedEditProductsSQL,
                    arguments: [products.thumbnail.finalRelativePath, products.preview.finalRelativePath, products.revision]
                        + AssetKey(rootID: rootID, path: products.id.relativePath).arguments
                )
                let oldPaths: [String?] = [row["thumbnail_path"], row["preview_path"]]
                let newPaths = Set(staged.map(\.finalRelativePath))
                let superseded = Set(oldPaths.compactMap(\.self)).subtracting(newPaths)
                return try (true, derivedFolder.unname(superseded, db: db), held)
            }
        } catch {
            OtosLog.catalog.errorOperation("catalog.editProducts", phase: "failed", fields: [
                "relativePath": products.id.relativePath.rawValue,
                "error": String(describing: error),
            ])
            discardStagedImages(staged)
            return false
        }
        if outcome.applied {
            let facts: CatalogChangedFacts = outcome.held ? [.images, .faceTiles, .detail, .duplicateFacts] : [.images, .faceTiles, .detail]
            notifyCatalogChanged(.changed(facts, rows: .rows([products.id])))
        } else {
            discardStagedImages(staged)
        }
        OtosLog.catalog.noticeOperation("catalog.editProducts", phase: outcome.applied ? "applied" : "stale", fields: [
            "relativePath": products.id.relativePath.rawValue,
            "revision": "\(products.revision)",
        ])
        // The write is applied and announced before the first suspension; its superseded
        // files go after, off the actor.
        await outcome.removal.perform()
        return outcome.applied
    }

    /// Hands a photo whose saved edit the edit panel could not render to enrichment, which
    /// renders thumbnails and previews with the current recipe (ADR 0036). A photo whose
    /// products already carry its edit is left alone.
    func handUnrenderedEditToEnrichment(_ id: MediaAssetID) async throws {
        guard let rootID = roots.rowIDSnapshot()[id.libraryRootPath] else {
            return
        }
        let released = try await database().write { db in
            try Self.releaseUnrenderedEdits(db: db, rootID: rootID, relativePath: id.relativePath)
        }
        OtosLog.catalog.noticeOperation("catalog.editProducts", phase: "handedToEnrichment", fields: [
            "relativePath": id.relativePath.rawValue,
            "released": "\(released)",
        ])
        if released {
            notifyCatalogChanged(.changed(.detail))
        }
    }

    /// Clears the rendering stamp of every photo — or the one named — whose saved edit is
    /// newer than its thumbnail and preview, so enrichment claims it again for a rendering
    /// alone: an edit changes neither the file's metadata nor its digest (ADR 0009).
    @discardableResult
    nonisolated static func releaseUnrenderedEdits(
        db: Database,
        rootID: Int64? = nil,
        relativePath: MediaRelativePath? = nil
    ) throws -> Bool {
        if let rootID, let relativePath {
            try db.execute(
                sql: AssetEnrichmentSQL.releaseUnrenderedEditSQL,
                arguments: AssetKey(rootID: rootID, path: relativePath).arguments
            )
        } else {
            try db.execute(sql: AssetEnrichmentSQL.releaseAllUnrenderedEditsSQL)
        }
        return db.changesCount > 0
    }

    /// The recipe as `edit_recipe_json` stores it: sorted-key JSON, so one recipe always
    /// encodes to the same text.
    /// Saves `json` (nil: no edit) as a photo's edit under the given revision. A video's
    /// products do not carry its edit, so they are current as soon as it is saved;
    /// otherwise enrichment would download the video again to re-render them.
    nonisolated static func writeEditRecipe(
        json: String?,
        revision: Int64,
        isVideo: Bool,
        rootID: Int64,
        relativePath: String,
        db: Database
    ) throws {
        try db.execute(
            sql: AssetRowSQL.writeEditRecipeSQL,
            arguments: [json, revision, isVideo, revision]
                + AssetKey(rootID: rootID, path: MediaRelativePath(rawValue: relativePath)).arguments
        )
    }

    /// Replaces a photo's edit with `json` (nil: no edit) under its next revision, inside a
    /// write. Returns false when the row is gone or already holds exactly that edit.
    nonisolated static func replaceEditRecipe(
        json: String?,
        rootID: Int64,
        relativePath: String,
        db: Database
    ) throws -> Bool {
        guard let row = try Row.fetchOne(
            db,
            sql: AssetRowSQL.replacedEditRecipeRowSQL,
            arguments: AssetKey(rootID: rootID, path: MediaRelativePath(rawValue: relativePath)).arguments
        ), (row["edit_recipe_json"] as String?) != json else {
            return false
        }
        let revision: Int64 = row["edit_revision"]
        try writeEditRecipe(
            json: json,
            revision: revision + 1,
            isVideo: (row["best_kind"] as String?) == MediaKind.video.rawValue,
            rootID: rootID,
            relativePath: relativePath,
            db: db
        )
        return true
    }

    nonisolated static func editRecipeJSON(_ recipe: EditRecipe) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let json = try String(bytes: encoder.encode(recipe), encoding: .utf8) else {
            throw EncodingError.invalidValue(recipe, EncodingError.Context(
                codingPath: [], debugDescription: "The encoded recipe is not UTF-8."
            ))
        }
        return json
    }

    /// The recipe `edit_recipe_json` holds, or nil when the photo was never edited.
    nonisolated static func editRecipe(json: String?) throws -> EditRecipe? {
        guard let json else {
            return nil
        }
        return try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
    }

    nonisolated static func storedEditRecipe(json: String?, revision: Int64) throws -> StoredEditRecipe? {
        try editRecipe(json: json).map { StoredEditRecipe(recipe: $0, revision: revision) }
    }

    /// A slow detail read's line. `storeMs` is asked → the Store ran it: the wait for the Store
    /// actor, which `waitMs` does not see.
    private func recordSlowDetailQuery(
        operation: String,
        requestedCount: Int,
        returnedCount: Int,
        storeMs: Int,
        timing: DatabaseTimedValue<some Any>
    ) {
        OtosLog.catalog.notice(
            "op=\(operation, privacy: .public) phase=finish requested=\(requestedCount, privacy: .public) returned=\(returnedCount, privacy: .public) storeMs=\(storeMs, privacy: .public) waitMs=\(timing.waitMs, privacy: .public) execMs=\(timing.execMs, privacy: .public) lockMs=\(timing.lockMs, privacy: .public) resumeMs=\(timing.resumeMs, privacy: .public) priority=\(timing.priorityName, privacy: .public) queryMs=\(timing.totalMs, privacy: .public) thresholdMs=\(Self.slowQueryDiagnosticThresholdMs, privacy: .public)"
        )
    }

    /// On-demand metadata read retained for the future tile/inspector metadata surface
    /// owned by ADR 0009. It is test-exercised today but stays out of the hot grid path.
    func metadata(for id: MediaAssetID, lane: CatalogReadLane) async throws -> AssetMetadata? {
        guard let rootID = roots[id.libraryRootPath]?.rowID else {
            return nil
        }

        let signpost = OtosSignpost.persistence.beginInterval("CatalogStoreMetadataQuery")
        let timedMetadata = try await timedRead(reader(for: lane)) { db in
            try CatalogQueryGateway.metadataExtra(libraryRootID: rootID, relativePath: id.relativePath, db: db)
        }
        OtosSignpost.persistence.endInterval("CatalogStoreMetadataQuery", signpost)

        guard roots[id.libraryRootPath]?.rowID == rootID else {
            return nil
        }
        let queryMs = timedMetadata.totalMs
        OtosLog.catalog.debug(
            """
            Catalog metadata queried returned=\(timedMetadata.value == nil ? 0 : 1, privacy: .public) \
            waitMs=\(timedMetadata.waitMs, privacy: .public) \
            execMs=\(timedMetadata.execMs, privacy: .public) queryMs=\(queryMs, privacy: .public)
            """
        )
        OtosLog.metadata.notice(
            "op=catalog.store.query.metadata phase=finish 0=1 returned=\(timedMetadata.value == nil ? "0" : "1", privacy: .public) waitMs=\(timedMetadata.waitMs, privacy: .public) execMs=\(timedMetadata.execMs, privacy: .public) lockMs=\(timedMetadata.lockMs, privacy: .public) resumeMs=\(timedMetadata.resumeMs, privacy: .public) priority=\(timedMetadata.priorityName, privacy: .public) queryMs=\(queryMs, privacy: .public)"
        )
        return timedMetadata.value
    }

    /// Claims the rows among `ids` that need enrichment on a root enrichment may read, in
    /// `ids` order. These are the rows the user is looking at and rows a download just made
    /// local; the coordinator claims them ahead of background work and outside its claim
    /// window, so the list's own length is the bound. While `videoFaces` is held, no row is
    /// claimed for a video's faces (`EnrichmentClaim.admitting`). The answer also names the
    /// rows read that owe nothing (`PriorityEnrichmentClaims`).
    func priorityEnrichmentCandidates(
        _ ids: [MediaAssetID],
        videoFaces: VideoFacesAdmission
    ) async throws -> PriorityEnrichmentClaims {
        var seen = Set<MediaAssetID>()
        let uniqueIDs = EnrichmentClaimGateway.unclaimedPriorityIDs(ids, claimedIDs: &seen)
        guard !uniqueIDs.isEmpty else {
            return PriorityEnrichmentClaims(claimed: [], owingNothing: [])
        }
        let queryStart = ContinuousClock.now
        let answer = try await priorityEnrichmentCandidates(ids: uniqueIDs, limit: uniqueIDs.count, videoFaces: videoFaces)
        await recordSlowEnrichmentCandidateQueryIfNeeded(
            priorityCount: uniqueIDs.count,
            returnedCount: answer.claims.value.count,
            waitMs: answer.claims.waitMs,
            execMs: answer.claims.execMs,
            queryStart: queryStart
        )
        return PriorityEnrichmentClaims(
            claimed: answer.claims.value,
            owingNothing: answer.owingNothing,
            digestsAwaitingLocalBytes: answer.digestsAwaitingLocalBytes
        )
    }

    /// Claims up to `limit` background rows: removable sources first, then libraries, each
    /// newest capture first (ADR 0013, ADR 0018). While `videoFaces` is held, no row is
    /// claimed for a video's faces (`EnrichmentClaim.admitting`), so a video that owes only
    /// them is not claimed at all.
    func enrichmentCandidates(limit: Int, videoFaces: VideoFacesAdmission) async throws -> [ClaimedEnrichmentCandidate] {
        guard limit > 0 else {
            return []
        }
        let queryStart = ContinuousClock.now
        let signpost = OtosSignpost.persistence.beginInterval("CatalogStoreEnrichmentCandidateQuery")
        defer {
            OtosSignpost.persistence.endInterval("CatalogStoreEnrichmentCandidateQuery", signpost)
        }
        // Each landed copy is offered once, ahead of the tiers; one not claimed now (already
        // claimed, or current) is enriched or done, and otherwise waits in the tiers' order.
        let landed = Array(localBytesAwaitingProducts.prefix(limit))
        localBytesAwaitingProducts.removeFirst(landed.count)
        let landedClaims = try await priorityEnrichmentCandidates(
            ids: landed, limit: landed.count, videoFaces: videoFaces, bytesAreLocal: true
        ).claims
        if !landed.isEmpty {
            // Whether a fresh copy was enriched while its bytes were local: each claim's
            // `enrichment.item` line names the file; this says the queue offered it first.
            OtosLog.catalog.noticeOperation("enrichment.candidates", phase: "landed", fields: [
                "offered": "\(landed.count)",
                "claimed": "\(landedClaims.value.count)",
                "waiting": "\(localBytesAwaitingProducts.count)",
            ])
        }
        var claims = landedClaims
        if landedClaims.value.count < limit {
            let tiers = try await claimedEnrichmentCandidates(
                limit: limit - landedClaims.value.count, videoFaces: videoFaces
            )
            claims = DatabaseTimedValue(
                value: landedClaims.value + tiers.value,
                waitMs: landedClaims.waitMs + tiers.waitMs,
                execMs: landedClaims.execMs + tiers.execMs
            )
        }
        await recordSlowEnrichmentCandidateQueryIfNeeded(
            priorityCount: landed.count,
            returnedCount: claims.value.count,
            waitMs: claims.waitMs,
            execMs: claims.execMs,
            queryStart: queryStart
        )
        return claims.value
    }

    private func recordSlowEnrichmentCandidateQueryIfNeeded(
        priorityCount: Int,
        returnedCount: Int,
        waitMs: Int,
        execMs: Int,
        queryStart: ContinuousClock.Instant
    ) async {
        guard waitMs + execMs > Self.slowQueryDiagnosticThresholdMs else {
            return
        }
        await recordSlowEnrichmentCandidateQuery(
            priorityCount: priorityCount,
            returnedCount: returnedCount,
            waitMs: waitMs,
            execMs: execMs,
            wallMs: DiagnosticsTiming.milliseconds(since: queryStart)
        )
    }

    private func recordSlowEnrichmentCandidateQuery(
        priorityCount: Int,
        returnedCount: Int,
        waitMs: Int,
        execMs: Int,
        wallMs: Int
    ) async {
        let queryMs = waitMs + execMs
        OtosLog.catalog.debug(
            """
            Catalog slow enrichment candidates query priority=\(priorityCount, privacy: .public) \
            returned=\(returnedCount, privacy: .public) \
            waitMs=\(waitMs, privacy: .public) execMs=\(execMs, privacy: .public) \
            queryMs=\(queryMs, privacy: .public) wallMs=\(wallMs, privacy: .public)
            """
        )
        OtosLog.catalog.notice(
            "op=catalog.store.query.enrichment phase=finish priority=\(priorityCount, privacy: .public) returned=\(returnedCount, privacy: .public) waitMs=\(waitMs, privacy: .public) execMs=\(execMs, privacy: .public) queryMs=\(queryMs, privacy: .public) wallMs=\(wallMs, privacy: .public) thresholdMs=\(Self.slowQueryDiagnosticThresholdMs, privacy: .public)"
        )
    }

    func releaseEnrichmentClaims(_ ids: [MediaAssetID]) async throws {
        guard !ids.isEmpty else {
            return
        }
        let rootIDsByPathBeforeWrite = roots.rowIDSnapshot()
        let dbWriter = try database()
        _ = try await timedWrite(dbWriter) { db in
            try EnrichmentClaimGateway.releaseEnrichmentClaims(
                ids: ids,
                rootIDsByPath: rootIDsByPathBeforeWrite,
                db: db
            )
        }
    }

    /// Of `ids`, the rows enrichment may still fetch bytes for — present under a root the
    /// Store holds, not in the Trash and not awaiting presence — each with its current byte
    /// size. The facts that end a materialization demand: a row this leaves out is gone, and
    /// a size that moved names other bytes (`EnrichmentSchedule.reconcile`).
    func enrichmentDemandSources(_ ids: [MediaAssetID], lane: CatalogReadLane) async throws -> [MediaAssetID: Int64?] {
        guard !ids.isEmpty else {
            return [:]
        }
        let rootIDsByPath = roots.rowIDSnapshot()
        let rows = try await reader(for: lane).readFreeingConnection { db in
            try EnrichmentClaimGateway.demandSources(ids: ids, rootIDsByPath: rootIDsByPath, db: db)
        }
        var sources: [MediaAssetID: Int64?] = [:]
        for row in rows {
            guard let rootPath = roots.pathsByRowID[row.rootID], roots[rootPath]?.rowID == row.rootID else {
                continue
            }
            sources[MediaAssetID(libraryRootPath: rootPath, relativePath: row.relativePath)] = .some(row.byteSize)
        }
        return sources
    }

    /// `bytesAreLocal` marks rows whose bytes just became local: a root first claimed for
    /// metadata alone (a card, a camera, an Immich account) is claimed for its rendering and
    /// digest too (`EnrichmentClaim.products`); a fixed library is claimed for its every
    /// product from the start (`EnrichmentClaim.library`); either, admitting `videoFaces`.
    /// Also returns the rows read that owe nothing under that claim, on any root: whether a
    /// row owes is its own stamps' answer, whatever its root's reach now.
    private func priorityEnrichmentCandidates(
        ids: [MediaAssetID],
        limit: Int,
        videoFaces: VideoFacesAdmission,
        bytesAreLocal: Bool = false
    ) async throws -> (
        claims: DatabaseTimedValue<[ClaimedEnrichmentCandidate]>,
        owingNothing: Set<MediaAssetID>,
        digestsAwaitingLocalBytes: Set<MediaAssetID>
    ) {
        // Enrichment's claim: a background owner's read.
        let priorityAssetsByID = try await mediaAssets(for: ids, lane: backgroundReads.lane)
        let rootIDsByPathBeforeWrite = roots.rowIDSnapshot()
        let dbWriter = try database()
        let firstClaim = { [roots] (path: LibraryRootPath) -> EnrichmentClaim in
            let first = roots[path]?.root.firstClaim ?? .metadata
            let claim = bytesAreLocal && (first == .metadata || first == .account) ? .products : first
            return claim.admitting(videoFaces)
        }
        let owingNothing = Set(priorityAssetsByID.values.filter { !$0.needsEnrichment(firstClaim($0.libraryRootPath)) }.map(\.id))
        let eligibleClaims = EnrichmentClaimGateway.priorityClaimInputs(
            ids: ids,
            assetsByID: priorityAssetsByID,
            rootIDsByPath: rootIDsByPathBeforeWrite,
            isRootEnrichable: { [roots] path in roots[path]?.isEnrichable == true },
            firstClaim: firstClaim
        )
        guard !eligibleClaims.isEmpty else {
            return (DatabaseTimedValue(value: [], waitMs: 0, execMs: 0), owingNothing, [])
        }
        let timedClaim = try await timedWrite(dbWriter) { db in
            var candidates: [ClaimedEnrichmentCandidate] = []
            var held: Set<MediaAssetID> = []
            candidates.reserveCapacity(min(limit, eligibleClaims.count))
            for (asset, rootID, claim) in eligibleClaims {
                guard candidates.count < limit else {
                    break
                }
                guard try EnrichmentClaimGateway.claimEnrichmentAsset(
                    libraryRootID: rootID,
                    relativePath: asset.relativePath,
                    claim: claim,
                    db: db
                ) else {
                    // Claimed by work in flight, which names the row when it writes, or held
                    // for local bytes, whose end names it too.
                    if try EnrichmentClaimGateway.holdsDigestHold(
                        libraryRootID: rootID, relativePath: asset.relativePath, db: db
                    ) {
                        held.insert(asset.id)
                    }
                    continue
                }
                candidates.append(ClaimedEnrichmentCandidate(
                    asset: asset,
                    scope: EnrichmentScope(claim: claim, asset: asset)
                ))
            }
            return (candidates, held)
        }
        var result = DatabaseTimedValue(
            value: timedClaim.value.0, waitMs: timedClaim.waitMs, execMs: timedClaim.execMs
        )
        result.lockMs = timedClaim.lockMs
        result.resumeMs = timedClaim.resumeMs
        result.priority = timedClaim.priority
        let digestsAwaitingLocalBytes = timedClaim.value.1
        if result.totalMs > Self.slowQueryDiagnosticThresholdMs {
            await recordSlowPriorityEnrichmentClaim(
                priorityCount: ids.count,
                eligibleCount: eligibleClaims.count,
                result: result
            )
        }
        return (result, owingNothing, digestsAwaitingLocalBytes)
    }

    private func recordSlowPriorityEnrichmentClaim(
        priorityCount: Int,
        eligibleCount: Int,
        result: DatabaseTimedValue<[ClaimedEnrichmentCandidate]>
    ) async {
        OtosLog.catalog.notice(
            "op=catalog.store.query.enrichment.priorityClaim phase=finish priority=\(priorityCount, privacy: .public) eligible=\(eligibleCount, privacy: .public) returned=\(result.value.count, privacy: .public) waitMs=\(result.waitMs, privacy: .public) execMs=\(result.execMs, privacy: .public) queryMs=\(result.totalMs, privacy: .public) thresholdMs=\(Self.slowQueryDiagnosticThresholdMs, privacy: .public)"
        )
    }

    private func claimedEnrichmentCandidates(limit: Int, videoFaces: VideoFacesAdmission) async throws
        -> DatabaseTimedValue<[ClaimedEnrichmentCandidate]>
    {
        let prioritizedRootIDs = roots.enrichableRootIDsByRemovablePriority()
        let (libraryRootIDs, accountRootIDs, metadataFirstRootIDs) = roots.enrichableRootIDsByFirstClaim()
        let cardRootIDs = roots.enrichableCardRootIDs()
        let dbWriter = try database()
        let timedStoredAssets = try await timedWrite(dbWriter) { db in
            var storedAssets: [(asset: StoredAsset, claim: EnrichmentClaim)] = []
            // The fallback spans roots of mixed kinds (ADR 0018): a fixed library's rows are
            // claimed for every product they owe at once (`EnrichmentClaim.library`), an Immich
            // account's for metadata and a video's faces (`.account`), and a card's and a
            // camera's for metadata first.
            // `INDEXED BY` forbids one statement across claims, so partition by claim within
            // each priority tier: removable roots first (ENR-011), then a card's
            // rendering-and-digest pass, then the fixed sources, sharing what is left.
            let removableRoots = Set(prioritizedRootIDs.removable)
            let fixedRoots = Set(prioritizedRootIDs.fixed)
            // A card's renderings and digests come in a pass of their own, offered only once
            // no row of that card still needs metadata, so developing and checksumming
            // every byte never delays the import (ADR 0009). Claimed under the broad
            // products, those rows' metadata is current, so their scope is the rendering and
            // the digest, made from one read.
            let cardsReadyForProducts = try cardRootIDs.filter { rootID in
                try !EnrichmentClaimGateway.hasRowsNeedingMetadata(rootID: rootID, db: db)
            }
            let priorityGroups: [(rootIDs: [Int64], claim: EnrichmentClaim)] = [
                (removableRoots.intersection(libraryRootIDs).sorted(), EnrichmentClaim.library.admitting(videoFaces)),
                (removableRoots.intersection(metadataFirstRootIDs).sorted(), .metadata),
                (removableRoots.intersection(accountRootIDs).sorted(), EnrichmentClaim.account.admitting(videoFaces)),
                (cardsReadyForProducts, .products),
            ]
            for group in priorityGroups where storedAssets.count < limit && !group.rootIDs.isEmpty {
                let claimed = try EnrichmentClaimGateway.fetchStoredAssetsNeedingEnrichment(
                    rootIDs: group.rootIDs,
                    limit: limit - storedAssets.count,
                    claim: group.claim,
                    db: db
                )
                storedAssets.append(contentsOf: claimed.map { (asset: $0, claim: group.claim) })
            }
            // Each fixed source gets its share of what is left, then any room a source did
            // not fill goes to the others in turn. A source whose rows wait on downloads (a
            // cloud library's videos, paced by the materialization budget) is claimed again
            // every pass; claimed first, it would fill every window and hold back a source
            // whose rows are readable now (an Immich account's, read in ranges).
            let fixedSources: [(rootID: Int64, claim: EnrichmentClaim)] =
                fixedRoots.intersection(libraryRootIDs).sorted().map { ($0, EnrichmentClaim.library.admitting(videoFaces)) }
                    + fixedRoots.intersection(metadataFirstRootIDs).sorted().map { ($0, .metadata) }
                    + fixedRoots.intersection(accountRootIDs).sorted().map { ($0, EnrichmentClaim.account.admitting(videoFaces)) }
            if storedAssets.count < limit, !fixedSources.isEmpty {
                let share = max(1, (limit - storedAssets.count) / fixedSources.count)
                for pass in [share, limit] {
                    for source in fixedSources where storedAssets.count < limit {
                        let claimed = try EnrichmentClaimGateway.fetchStoredAssetsNeedingEnrichment(
                            rootIDs: [source.rootID],
                            limit: min(pass, limit - storedAssets.count),
                            claim: source.claim,
                            db: db
                        )
                        storedAssets.append(contentsOf: claimed.map { (asset: $0, claim: source.claim) })
                    }
                }
            }
            return storedAssets
        }
        // `claim` here is the claim the row was just claimed under
        // (carried from the `claimGroups` entry above), not re-derived from current
        // root kind. A root's kind cannot change between the claim
        // above and this mapping since both run inside the same actor-isolated call, but
        // carrying the value keeps one owner rather than inviting a second opinion later.
        let candidates: [ClaimedEnrichmentCandidate] = timedStoredAssets.value.compactMap { entry in
            guard let rootPath = roots.pathsByRowID[entry.asset.libraryRootID],
                  roots[rootPath]?.rowID == entry.asset.libraryRootID,
                  roots[rootPath]?.availability == .available
            else {
                return nil
            }
            let asset = mediaAsset(from: entry.asset, rootPath: rootPath)
            return ClaimedEnrichmentCandidate(
                asset: asset,
                scope: EnrichmentScope(claim: entry.claim, asset: asset)
            )
        }
        let result = DatabaseTimedValue(
            value: candidates,
            waitMs: timedStoredAssets.waitMs,
            execMs: timedStoredAssets.execMs
        )
        if result.totalMs > Self.slowQueryDiagnosticThresholdMs {
            await recordSlowFallbackEnrichmentClaim(
                limit: limit,
                removableRootCount: prioritizedRootIDs.removable.count,
                fixedRootCount: prioritizedRootIDs.fixed.count,
                result: result
            )
        }
        return result
    }

    private func recordSlowFallbackEnrichmentClaim(
        limit: Int,
        removableRootCount: Int,
        fixedRootCount: Int,
        result: DatabaseTimedValue<[ClaimedEnrichmentCandidate]>
    ) async {
        OtosLog.catalog.notice(
            "op=catalog.store.query.enrichment.claim phase=finish limit=\(limit, privacy: .public) availableRootCount=\(removableRootCount + fixedRootCount, privacy: .public) removableRootCount=\(removableRootCount, privacy: .public) returned=\(result.value.count, privacy: .public) waitMs=\(result.waitMs, privacy: .public) execMs=\(result.execMs, privacy: .public) queryMs=\(result.totalMs, privacy: .public) thresholdMs=\(Self.slowQueryDiagnosticThresholdMs, privacy: .public)"
        )
    }

    func start(scansSavedLibraries: Bool = true) async throws {
        try await loadIfNeeded()
        await forgetRemovableSourcesUnseenForRetentionPeriod()
        startFilesystemWatchingIfNeeded()
        if scansSavedLibraries {
            requestLoadedRootScansIfNeeded()
        }
        watchUnwatchedRoots()
        startIntegrityScanSchedulerIfNeeded()
    }

    /// Registers an explicit provider materialization for known-event suppression.
    /// Identity must be the normalized catalog path (not a raw alias spelling).
    func beginKnownMaterialization(for id: MediaAssetID) {
        knownMaterializationSuppression.begin(id: id)
    }

    /// A download Otos asked for ended. One that made the original local ends the row's digest
    /// hold, if it holds one, and offers it ahead of other work while its bytes are here: the
    /// user's full-size view, an export or a Move to Trash downloaded it (ADR 0009 §12).
    func endKnownMaterialization(for id: MediaAssetID, success: Bool) async {
        guard success else {
            knownMaterializationSuppression.endFailure(id: id)
            return
        }
        knownMaterializationSuppression.endSuccess(id: id)
        await endDigestHold(id, reason: "downloaded")
    }

    // MARK: - Digests that wait for local bytes (ADR 0009 §12)

    /// Holds the rows the coordinator claimed whose only owed product is their digest and
    /// whose original is not local: no download is made for a digest alone. A held row is
    /// out of every claim, as a claimed one is, and is no work of the coordinator's; the Store
    /// ends the hold on the fact that ends the wait — an event on its file, Otos downloading
    /// it, a scan finding its facts moved (`upsertScannedFile`), or the next launch, which
    /// clears every claim. Returns the rows held.
    func holdDigestsForLocalBytes(_ ids: [MediaAssetID]) async throws -> [MediaAssetID] {
        guard !ids.isEmpty else { return [] }
        let rootIDsByPath = roots.rowIDSnapshot()
        let held = try await database().write { db in
            try EnrichmentClaimGateway.holdDigestsForLocalBytes(ids: ids, rootIDsByPath: rootIDsByPath, db: db)
        }
        OtosLog.catalog.noticeOperation("enrichment.digestHold", phase: "held", fields: [
            "asked": "\(ids.count)", "held": "\(held.count)",
        ])
        return held
    }

    /// Ends the digest holds of `ids` whose bytes the caller found local after it held them:
    /// a file the provider made local between the coordinator's locality read and its hold,
    /// whose event the Store saw before the hold was there to end.
    func endDigestHolds(_ ids: [MediaAssetID], reason: String) async {
        for id in ids {
            await endDigestHold(id, reason: reason)
        }
    }

    /// Rows whose digest waits for local bytes now: what `op=owners.held` reports.
    func digestHoldCount() async throws -> Int {
        try await reader(for: backgroundReads.lane).readFreeingConnection { db in
            try Int.fetchOne(db, sql: EnrichmentClaimGateway.digestHoldCountSQL) ?? 0
        }
    }

    /// Ends `id`'s digest hold, if it holds one, offers the row ahead of other work while its
    /// bytes are local (`localBytesAwaitingProducts`), and names it in a `.detail` change, so
    /// enrichment claims it. Nothing is written for a row of no root the Store holds; a failed
    /// write is logged and the hold stays until the next fact or launch.
    private func endDigestHold(_ id: MediaAssetID, reason: String) async {
        guard let rootID = roots[id.libraryRootPath]?.rowID else { return }
        let ended: Bool
        do {
            // Read first: every download Otos makes ends here, and almost none was held, so
            // the writer is taken only for a row that holds a hold.
            let holds = try await reader(for: backgroundReads.lane).readFreeingConnection { db in
                try EnrichmentClaimGateway.holdsDigestHold(libraryRootID: rootID, relativePath: id.relativePath, db: db)
            }
            guard holds else { return }
            ended = try await database().write { db in
                try EnrichmentClaimGateway.endDigestHold(libraryRootID: rootID, relativePath: id.relativePath, db: db)
            }
        } catch {
            OtosLog.catalog.errorOperation("enrichment.digestHold", phase: "endFailed", fields: [
                "reason": reason, "relativePath": id.relativePath.rawValue, "error": String(describing: error),
            ])
            return
        }
        guard ended else { return }
        digestHoldEnded(id, reason: reason)
    }

    /// A digest hold that ended in a write: logged, offered first, and announced.
    private func digestHoldEnded(_ id: MediaAssetID, reason: String) {
        OtosLog.catalog.noticeOperation("enrichment.digestHold", phase: "ended", fields: [
            "reason": reason, "rootPath": id.libraryRootPath.rawValue, "relativePath": id.relativePath.rawValue,
        ])
        if !localBytesAwaitingProducts.contains(id) {
            localBytesAwaitingProducts.append(id)
        }
        notifyCatalogChanged(.changed(.detail, rows: .rows([id])))
    }

    /// Every entry point that needs catalog truth awaits the same finite load.
    /// The task is installed before its first suspension, which closes the actor
    /// reentrancy window where two callers could read and later apply competing
    /// database loads.
    private func loadIfNeeded() async throws {
        if started {
            return
        }
        if let startupTask {
            joinedInitialLoadCount += 1
            OtosLog.persistence.debug("Catalog startup joined existing load")
            OtosLog.catalog.noticeOperation("catalog.start", phase: "coalesced")
            try await startupTask.value
            return
        }

        let task = Task {
            try await self.performInitialLoad()
        }
        startupTask = task
        do {
            try await task.value
            startupTask = nil
        } catch {
            startupTask = nil
            throw error
        }
    }

    private func performInitialLoad() async throws {
        let state = OtosSignpost.persistence.beginInterval("CatalogStart")
        OtosLog.catalog.noticeOperation("catalog.start", phase: "start")
        defer {
            OtosSignpost.persistence.endInterval("CatalogStart", state)
        }

        // Every step is timed into the finish line: the load sits between launch and the
        // first grid (`op=launch.firstGrid`), so where it spends its time must be readable from
        // the installed app's log. Each maintenance write is index-driven (v55), so none walks
        // the rows of the catalog.
        var phases = LoadPhaseTimer()
        let dbQueue = try database()
        phases.lap("openMs")
        // Before anything changes the derived folder: whether the last session left leftovers
        // possible, and this session's marker; then the moves a rename journaled and a crash
        // left undone. The window waits on the load: its first grid follows it.
        derivedFolder?.openSession()
        try await applyPendingDerivedRenames(lane: windowReads.lane)
        let (loadedRoots, assetRows, journalPositions) = try await reader(for: windowReads.lane).readFreeingConnection { db in
            try (
                Self.fetchRoots(db),
                Int.fetchOne(db, sql: AssetRowSQL.highestRowIDSQL) ?? 0,
                Self.fetchJournalPositions(db: db)
            )
        }
        // Sized before the first read makes the rows' IDs, so the session never rebuilds the
        // identity table's index under its lock while the window makes IDs (ADR 0005).
        MediaAssetIdentityTable.shared.reserve(assetRows + assetRows / 4)
        phases.lap("rootsMs")
        try await clearAbandonedEnrichmentClaims(dbQueue)
        phases.lap("claimsMs")
        // An edit saved but not yet rendered into its thumbnail and preview when the last
        // process ended is enrichment's to render (ADR 0036).
        // The load is a change to which roots the Store holds and reaches: every row's
        // reach (`membership`, no row named). What its own writes changed joins it.
        var loaded: CatalogChangedFacts = .membership
        if try await dbQueue.write({ db in try Self.releaseUnrenderedEdits(db: db) }) {
            // A render's stamp, which the render-signature trigger follows.
            loaded.formUnion([.images, .detail, .duplicateFacts])
        }
        phases.lap("editsMs")
        // A still or video no decoder could read was read by this build's decoder or an
        // earlier one; one an earlier decoder could not read is this decoder's to try
        // (ENR-029, ENR-031).
        let stillDecoder = ImageRenderer.decoderIdentity
        let videoDecoder = VideoFaceReader.decoderIdentity
        let releasedUndecodable = try await dbQueue.write { db in
            try Self.releaseUndecodedByAnotherDecoder(still: stillDecoder, video: videoDecoder, db: db)
        }
        phases.lap("undecodableMs")
        if releasedUndecodable.stills > 0 {
            loaded.formUnion([.images, .detail, .duplicateFacts])
        }
        if releasedUndecodable.videos > 0 {
            loaded.formUnion([.faces, .detail])
        }
        OtosLog.catalog.noticeOperation("catalog.start", phase: "undecodableReleased", fields: [
            "stills": "\(releasedUndecodable.stills)", "stillDecoder": stillDecoder,
            "videos": "\(releasedUndecodable.videos)", "videoDecoder": videoDecoder,
        ])
        // No card or camera is attached while the catalog loads; a process that ended
        // while one was being read left its unseen rows marked (ADR 0013). Before the first
        // grid: a marked row is hidden from every read.
        let clearedAwaiting = try await dbQueue.write { db in
            try Self.clearAllAwaitingPresence(db: db)
        }
        phases.lap("awaitingMs")
        if clearedAwaiting > 0 {
            loaded.formUnion(.presence)
            OtosLog.catalog.noticeOperation("catalog.start", phase: "clearedAwaitingPresence", fields: [
                "count": "\(clearedAwaiting)",
            ])
        }
        // Remap batches a previous process settled had a window that no longer exists;
        // no identity this process shows was ever under their old paths (ARC-052). Before
        // the first grid: the order read carries the pending batches.
        try await dbQueue.write { db in
            try Self.deleteAllPendingIdentityRemapBatches(db: db)
        }
        phases.lap("remapsMs")
        // Tests pause precisely at this real suspension boundary to prove that
        // concurrent mutation callers join this load. Production leaves the
        // hook nil and performs no additional work.
        await initialLoadDidRead?()
        let normalizedRoots = await normalizeLoadedRoots(loadedRoots, dbWriter: dbQueue)
        phases.lap("normalizeMs")
        // A root that moved renamed its rows' derived images (`updateLibraryRootPath`).
        if normalizedRoots.map(\.path) != loadedRoots.map(\.path) {
            loaded.insert(.images)
        }
        let journaledRoots = try await reader(for: windowReads.lane).readFreeingConnection { db in
            try Set(Self.fetchAllActiveReorganizationComponents(db: db).map(\.libraryRootPath))
        }
        phases.lap("journalMs")
        let applyState = OtosSignpost.catalog.beginInterval("CatalogApplyLoadedCatalog")
        applyLoadedCatalog(roots: normalizedRoots)
        holdJournaledReorganizationRoots(journaledRoots)
        unrequestedLoadedRootPaths = normalizedRoots
            .filter(\.kind.isUserChosenFolder)
            .map(\.path)
        loadedJournalPositions = Dictionary(uniqueKeysWithValues: unrequestedLoadedRootPaths.compactMap { path in
            roots[path].flatMap { journalPositions[$0.rowID] }.map { (path, $0) }
        })
        OtosSignpost.catalog.endInterval("CatalogApplyLoadedCatalog", applyState)
        started = true
        var fields = phases.fields
        fields["roots"] = "\(normalizedRoots.count)"
        fields["migrations"] = migrationRun.map { "\($0.applied)" } ?? "unknown"
        fields["migrationsMs"] = migrationRun.map { "\($0.milliseconds)" } ?? "unknown"
        OtosLog.catalog.noticeOperation("catalog.start", phase: "finish", fields: fields)
        ResourceCheckpoint.record("catalogOpen", storeUse: { self.use() })
        notifyCatalogChanged(.changed(loaded))
    }

    /// Times the catalog load's steps, each from the end of the one before.
    private struct LoadPhaseTimer {
        private let start = ContinuousClock.now
        private var lapStart = ContinuousClock.now
        private(set) var fields: [String: String] = [:]

        mutating func lap(_ name: String) {
            fields[name] = "\(DiagnosticsTiming.milliseconds(since: lapStart))"
            fields["ms"] = "\(DiagnosticsTiming.milliseconds(since: start))"
            lapStart = .now
        }
    }

    /// A root with a journaled reorganization component is half-moved until its recovery
    /// finishes. Its lease is held from the moment the catalog loads, so no scan, reconcile
    /// pass, import or Move to Trash acts on it first, whoever runs recovery and when.
    private func holdJournaledReorganizationRoots(_ journaledRoots: Set<LibraryRootPath>) {
        for root in journaledRoots.sorted(by: { $0.rawValue < $1.rawValue }) where roots[root] != nil {
            installNamespaceMutationLease(for: root, owner: .reorganization)
            journalHeldReorganizationRoots.insert(root)
            OtosLog.catalog.noticeOperation("reorganization.recover", phase: "held", fields: [
                "rootPath": root.rawValue,
            ])
        }
    }

    /// The lease the journal has held for `root` since load, handed to the recovery that
    /// finishes its component; `nil` when the journal holds none for it.
    func adoptJournalHeldReorganizationLease(for root: LibraryRootPath) -> RootNamespaceMutationLease? {
        guard journalHeldReorganizationRoots.remove(root) != nil else { return nil }
        return namespaceMutationLeases[root]
    }

    private func clearAbandonedEnrichmentClaims(_ dbQueue: CatalogWriter) async throws {
        let clearedCount = try await dbQueue.write { db in
            try EnrichmentClaimGateway.clearEnrichmentClaims(db: db)
        }
        guard clearedCount > 0 else {
            return
        }
        OtosLog.metadata.info(
            "Cleared abandoned enrichment claims count=\(clearedCount, privacy: .public)"
        )
        OtosLog.metadata.notice(
            "op=catalog.enrichment.claims phase=startupClear count=\(clearedCount, privacy: .public)"
        )
    }

    /// Writes a digest read on its own (`EnrichmentScope.hash`) while the row's file
    /// signature is still the one it was read at, and releases the row's claim whatever the
    /// answer (ADR 0018). A digest names no file, so no planning revision moves. A failed
    /// write publishes nothing and is logged; the row stays hash-stale and is claimed again.
    func applyContentHash(_ result: ContentHashResult) async -> EnrichmentApplyOutcome {
        guard let rootRowID = roots[result.id.libraryRootPath]?.rowID else {
            return .applied(count: 0)
        }
        let relativePath = result.id.relativePath.rawValue
        do {
            let (written, facts) = try await database().write { db -> (Int, CatalogChangedFacts) in
                let joinsBefore = try CatalogSchema.choiceJoins(db)
                let before = try DigestStanding.read(libraryRootID: rootRowID, relativePath: relativePath, db: db)
                try db.execute(
                    sql: AssetEnrichmentSQL.applyContentHashSQL,
                    arguments: [result.contentHash.data, result.sourceSize, result.sourceMTimeSeconds]
                        + AssetKey(rootID: rootRowID, path: MediaRelativePath(rawValue: relativePath)).arguments
                        + [result.sourceSize, result.sourceMTimeSeconds]
                )
                let written = db.changesCount
                if written == 0 {
                    // The file changed while it was read: the digest is for other bytes.
                    try db.execute(
                        sql: AssetEnrichmentSQL.releaseContentHashClaimSQL,
                        arguments: AssetKey(rootID: rootRowID, path: MediaRelativePath(rawValue: relativePath)).arguments
                    )
                }
                guard written > 0, let before,
                      let after = try DigestStanding.read(libraryRootID: rootRowID, relativePath: relativePath, db: db)
                else {
                    return (written, [])
                }
                return try (written, .digests(
                    from: [(before, after)], choicesJoined: CatalogSchema.choiceJoins(db) != joinsBefore
                ))
            }
            OtosLog.metadata.noticeOperation("enrichment.contentHash", phase: written > 0 ? "applied" : "stale", fields: [
                "rootPath": result.id.libraryRootPath.rawValue,
                "relativePath": relativePath,
                "facts": facts.diagnosticDescription,
            ])
            if !facts.isEmpty {
                notifyCatalogChanged(.changed(facts))
            }
            return .applied(count: written)
        } catch {
            OtosLog.metadata.errorOperation("enrichment.contentHash", phase: "writeFailed", fields: [
                "relativePath": relativePath,
                "error": String(describing: error),
            ])
            await releaseEnrichmentClaimsAfterBatch([result.id])
            return .writeFailed
        }
    }

    /// Applies a batch of completed enrichments in one transaction and one notification.
    /// The transaction also releases every row's enrichment claim, so the notification
    /// never reaches a claimant before the rows it settled are claimable again; a failed
    /// write rolls back and releases the claims on its own.
    /// Batching mirrors `recordScannedBatch`: a per-asset transaction across a whole
    /// library would crawl, and a notification per asset would re-sort the catalog in
    /// Projection per completion. Enrichment writes only enrichment columns/fields,
    /// disjoint from facts; a row that was proven-deleted or whose source facts changed
    /// between extraction and this write is skipped, so a removed or edited asset is never
    /// stamped current by stale work. Generated thumbnails are staged by the enricher and
    /// promoted here only for accepted rows, keeping derived files subordinate to Store's
    /// current SQLite truth.
    /// Applies a batch and reports the outcome so the coordinator can react correctly.
    /// `.applied(count:)` with `count < results.count` means some results were *validated*
    /// drops — proven-deleted, or stale because a scan observed newer bytes — which the
    /// coordinator should re-wake to retry. `.writeFailed` means the SQLite write or
    /// thumbnail promotion failed (disk full, corruption, permissions, missing staged file);
    /// the coordinator must *not* re-wake into a tight read/generate/fail loop and instead
    /// lets the recorded error back it off.
    @discardableResult
    func applyEnrichmentBatch(_ results: [EnrichmentResult]) async -> EnrichmentApplyOutcome {
        guard !results.isEmpty else {
            return .applied(count: 0)
        }
        let rootIDsByPathBeforeWrite = roots.rowIDSnapshot()
        guard results.contains(where: { rootIDsByPathBeforeWrite[$0.id.libraryRootPath] != nil }) else {
            discardStagedImages(results.flatMap(\.stagedImages))
            return .applied(count: 0)
        }
        let resultIDs = results.map(\.id)

        let state = OtosSignpost.persistence.beginInterval("CatalogEnrichmentBatchWrite")
        let writeOutcome: EnrichmentBatchWriteOutcome
        do {
            let dbQueue = try database()
            writeOutcome = try await writeEnrichmentBatch(
                results,
                rootIDsByPath: rootIDsByPathBeforeWrite,
                derivedFolder: derivedFolder,
                dbWriter: dbQueue
            )
        } catch {
            OtosSignpost.persistence.endInterval("CatalogEnrichmentBatchWrite", state)
            discardStagedImages(results.flatMap(\.stagedImages))
            await recordEnrichmentBatchError(error, count: results.count)
            await releaseEnrichmentClaimsAfterBatch(resultIDs)
            return .writeFailed
        }
        OtosSignpost.persistence.endInterval("CatalogEnrichmentBatchWrite", state)
        discardStagedImages(writeOutcome.discardedImages)
        await writeOutcome.removal.perform()

        await recordEnrichmentBatchWrite(resultsCount: results.count, writeOutcome: writeOutcome)
        await boundWAL(reason: "enrichmentBatch")
        if writeOutcome.appliedCount > 0 {
            for rootPath in writeOutcome.namingChangedRoots {
                recordNamingChange(for: rootPath)
            }
            // The change names what the batch changed, so a reader repeats only the reads
            // that depend on it: a batch that moved no capture date, kind, format, grouping
            // identifier or location leaves the window's order and options standing.
            notifyCatalogChanged(.changed(writeOutcome.facts, rows: .rows(writeOutcome.applied)))
        }
        if writeOutcome.promotionFailed {
            return .writeFailed
        }
        return .applied(count: writeOutcome.appliedCount)
    }

    private func recordEnrichmentBatchWrite(
        resultsCount: Int,
        writeOutcome: EnrichmentBatchWriteOutcome
    ) async {
        OtosLog.metadata.notice(
            "op=catalog.enrichment.batch phase=finish attempted=\(resultsCount, privacy: .public) count=\(writeOutcome.appliedCount, privacy: .public) namingChanged=\(writeOutcome.namingChangedRoots.count, privacy: .public) facts=\(writeOutcome.facts.diagnosticDescription, privacy: .public) rootPaths=\(writeOutcome.namingChangedRoots.map(\.rawValue).sorted().joined(separator: ","), privacy: .public) discardedImages=\(writeOutcome.discardedImages.count, privacy: .public) supersededImages=\(writeOutcome.supersededImagePaths.count, privacy: .public) promotionFailed=\(writeOutcome.promotionFailed, privacy: .public) waitMs=\(writeOutcome.waitMs, privacy: .public) execMs=\(writeOutcome.execMs, privacy: .public) writeMs=\(writeOutcome.waitMs + writeOutcome.execMs, privacy: .public)"
        )
    }

    private func releaseEnrichmentClaimsAfterBatch(_ resultIDs: [MediaAssetID]) async {
        do {
            try await releaseEnrichmentClaims(resultIDs)
        } catch {
            OtosLog.metadata.error(
                """
                Enrichment claim release failed count=\(resultIDs.count, privacy: .public) \
                error=\(String(describing: error), privacy: .public)
                """
            )
        }
    }

    private func writeEnrichmentBatch(
        _ results: [EnrichmentResult],
        rootIDsByPath: [LibraryRootPath: Int64],
        derivedFolder: DerivedFolder?,
        dbWriter: CatalogWriter
    ) async throws -> EnrichmentBatchWriteOutcome {
        let timedOutcome = try await timedWrite(dbWriter) { db in
            var outcome = EnrichmentBatchWriteOutcome()
            let joinsBefore = try CatalogSchema.choiceJoins(db)
            for result in results {
                try Self.applyEnrichmentResult(
                    result,
                    rootIDsByPath: rootIDsByPath,
                    derivedFolder: derivedFolder,
                    outcome: &outcome,
                    db: db
                )
            }
            // The names the batch stopped holding are counted out in it; their files go once
            // it commits.
            outcome.removal = try derivedFolder?.unname(outcome.supersededImagePaths, db: db) ?? .nothing
            // Released in the write that settles the rows, so no change notification can
            // reach a claimant while a row it is due to claim still reads as claimed.
            try EnrichmentClaimGateway.releaseEnrichmentClaims(
                ids: results.map(\.id),
                rootIDsByPath: rootIDsByPath,
                db: db
            )
            // A digest that joined a copy to a photo gave it the photo's choice (ADR 0054).
            if try CatalogSchema.choiceJoins(db) != joinsBefore {
                outcome.facts.insert(.choices)
            }
            return outcome
        }
        var outcome = timedOutcome.value
        outcome.waitMs = timedOutcome.waitMs
        outcome.execMs = timedOutcome.execMs
        return outcome
    }

    private static func applyEnrichmentResult(
        _ result: EnrichmentResult,
        rootIDsByPath: [LibraryRootPath: Int64],
        derivedFolder: DerivedFolder?,
        outcome: inout EnrichmentBatchWriteOutcome,
        db: Database
    ) throws {
        let staged = result.stagedImages
        guard let rootID = rootIDsByPath[result.id.libraryRootPath] else {
            outcome.discard(staged)
            return
        }
        guard staged.isEmpty || derivedFolder != nil else {
            outcome.failPromotion(staged)
            return
        }
        guard try enrichmentResultMatchesCurrentRow(result, libraryRootID: rootID, db: db) else {
            outcome.discard(staged)
            return
        }
        if let derivedFolder {
            for (index, image) in staged.enumerated() {
                do {
                    try derivedFolder.promote(image, db: db)
                } catch {
                    outcome.failPromotion(Array(staged[index...]))
                    return
                }
            }
        }
        let overlayColumnsSQL = AssetEnrichmentSQL.overlayBeforeWriteSQL
        let overlayColumnsArguments = AssetKey(rootID: rootID, path: result.id.relativePath).arguments
        let oldRow: EnrichmentOverlayBeforeWrite? = try Row.fetchOne(
            db,
            sql: overlayColumnsSQL,
            arguments: overlayColumnsArguments
        ).map(EnrichmentOverlayBeforeWrite.init(row:))
        let digestBefore = try result.contentHash == nil ? nil : DigestStanding.read(
            libraryRootID: rootID, relativePath: result.id.relativePath.rawValue, db: db
        )
        let heldBefore = try DuplicatesHoldSQL.holds(libraryRootID: rootID, relativePath: result.id.relativePath.rawValue, db: db)
        try writeEnrichmentOverlay(result, libraryRootID: rootID, db: db)
        // Ask SQLite what it actually stored for the STORED generated columns rather
        // than predicting it: the COALESCE chain lives once, in the schema
        // (CatalogStorePersistence.swift), and a batch that leaves `best_capture`/
        // `best_kind`/`best_format` unchanged (e.g. a first enrichment whose capture
        // date equals the filesystem date, or a no-op re-enrichment) is detail-only —
        // the projection can skip the full re-sort. Only an effective order/scope
        // change is structural.
        let newRow: EnrichmentOverlayBeforeWrite? = try Row.fetchOne(
            db,
            sql: overlayColumnsSQL,
            arguments: overlayColumnsArguments
        ).map(EnrichmentOverlayBeforeWrite.init(row:))
        outcome.facts.insert(.detail)
        var rowFacts: CatalogChangedFacts = []
        if let old = oldRow, let newRow {
            let changed = old.changedFacts(to: newRow)
            rowFacts.formUnion(changed)
            outcome.facts.formUnion(changed)
            if try old.changesStacks(
                to: newRow, facts: changed, libraryRootID: rootID, relativePath: result.id.relativePath, db: db
            ) {
                outcome.facts.insert(.stacks)
            }
        }
        if result.metadata != nil {
            rowFacts.insert(.mediaRecord)
            outcome.facts.insert(.mediaRecord)
        }
        // A video's reading writes its frames whatever it found: a reading with no face takes
        // the frames an earlier one stored, which the face tiles were cut from.
        if result.rendering != nil || result.provisionalThumbnail != nil || result.videoFaces?.frames != nil
            || oldRow?.faceFramesPath != newRow?.faceFramesPath
        {
            rowFacts.insert(.images)
            outcome.facts.insert(.images)
        }
        // People reads a photo's date, kind, grouping and images only through its faces.
        if !outcome.facts.contains(.faceTiles), !rowFacts.isDisjoint(with: [.captureDate, .kindAndFormat, .grouping, .images]),
           try Self.holdsFace(libraryRootID: rootID, relativePath: result.id.relativePath, db: db)
        {
            outcome.facts.insert(.faceTiles)
        }
        if try DuplicatesHoldSQL.changesDuplicates(
            rowFacts, heldBefore: heldBefore, libraryRootID: rootID, relativePath: result.id.relativePath.rawValue, db: db
        ) {
            outcome.facts.insert(.duplicateFacts)
        }
        if result.videoFaces != nil {
            outcome.facts.insert(.faces)
        }
        if let digestBefore,
           let digestAfter = try DigestStanding.read(libraryRootID: rootID, relativePath: result.id.relativePath.rawValue, db: db)
        {
            outcome.facts.formUnion(.digests(from: [(digestBefore, digestAfter)], choicesJoined: false))
        }
        if oldRow?.captureWallCompact != newRow?.captureWallCompact {
            outcome.namingChangedRoots.insert(result.id.libraryRootPath)
        }
        // A product the result does not carry keeps the row's file: only a rendering
        // replaces the preview, and a metadata-only result touches neither image.
        if result.rendering != nil || result.provisionalThumbnail != nil {
            outcome.replaceImage(oldPath: oldRow?.thumbnailPath, newPath: result.shownThumbnailPath)
        }
        if let rendering = result.rendering {
            outcome.replaceImage(oldPath: oldRow?.previewPath, newPath: rendering.previewPath)
        }
        if let videoFaces = result.videoFaces {
            outcome.replaceImage(oldPath: oldRow?.faceFramesPath, newPath: videoFaces.frames?.finalRelativePath)
        }
        outcome.applied.insert(result.id)
    }

    // MARK: - Metadata refresh (ADR 0039)

    /// Library rows whose metadata record an older reading of its format family produced
    /// (`MediaMetadataReader.extractionRevision(for:)`; a record with none counts as 0, as
    /// the library defines it), in path order after `cursor`. Only rows whose enrichment is
    /// current: a row that is stale anyway is re-read by enrichment, which stamps the
    /// revision itself. Card and camera rows are never listed.
    func metadataRefreshCandidates(
        after cursor: MediaAssetID?,
        limit: Int,
        lane: CatalogReadLane
    ) async throws -> [MetadataRefreshCandidate] {
        let rootsByID = roots.pathsByRowID
        let rootIDs = roots.values.filter(\.root.kind.isUserChosenFolder).map(\.rowID)
        let after = cursor.flatMap { cursor in
            roots[cursor.libraryRootPath].map { AssetKeyCursor(rootID: $0.rowID, relativePath: cursor.relativePath.rawValue) }
        }
        return try await reader(for: lane).readFreeingConnection { db in
            try Array(page: CandidateWalk.keyPage(
                sql: AssetEnrichmentSQL.metadataRefreshCandidatesSQL, rootIDs: rootIDs, after: after, limit: limit, db: db
            ).rows, atMost: limit) { row -> MetadataRefreshCandidate? in
                let rootID: Int64 = row["library_root_id"]
                guard let rootPath = rootsByID[rootID] else { return nil }
                return MetadataRefreshCandidate(
                    id: MediaAssetID(
                        libraryRootPath: rootPath,
                        relativePath: MediaRelativePath(rawValue: row["relative_path"])
                    ),
                    sourceSize: row["byte_size"],
                    sourceMTimeSeconds: row["metadata_source_mtime"],
                    mayCompleteLivePhoto: row["may_complete_live_photo"] ?? false
                )
            }
        }
    }

    /// Hands rows whose bytes are not local back to enrichment, which downloads each once
    /// and derives everything from that one read — metadata, checksum, thumbnail and
    /// preview — rather than a metadata read alone (ADR 0041). The row's metadata and
    /// rendering stamps are cleared, the facts enrichment claims on: its stored products
    /// describe a reading the current reader would extend. A row whose file changed or whose record
    /// was re-read meanwhile is left alone. Returns how many rows were handed over.
    ///
    /// The rendering stamp is part of what a stored thumbnail is (`StoredThumbnailSQL`), so the
    /// write is an image change of the rows it names: it clears their render signatures
    /// (`CatalogSchema.renderSignatureStaleTrigger`) and leaves their embeddings and
    /// descriptions read from another thumbnail, and it names what a face's tile, Duplicates
    /// and those owners read, as every write of the stamp does.
    @discardableResult
    func requestEnrichmentDownload(_ candidates: [MetadataRefreshCandidate]) async throws -> Int {
        guard !candidates.isEmpty else { return 0 }
        let rootIDs = roots.rowIDSnapshot()
        let dbWriter = try database()
        let (requested, facts) = try await dbWriter.write { db -> (Set<MediaAssetID>, CatalogChangedFacts) in
            var requested: Set<MediaAssetID> = []
            var facts: CatalogChangedFacts = [.detail, .images]
            for candidate in candidates {
                guard let rootID = rootIDs[candidate.id.libraryRootPath] else { continue }
                let relativePath = candidate.id.relativePath.rawValue
                let heldBefore = try DuplicatesHoldSQL.holds(libraryRootID: rootID, relativePath: relativePath, db: db)
                try db.execute(
                    sql: AssetEnrichmentSQL.requestEnrichmentDownloadSQL,
                    arguments: AssetKey(rootID: rootID, path: MediaRelativePath(rawValue: relativePath)).arguments
                        + [candidate.sourceSize, candidate.sourceSize, candidate.sourceMTimeSeconds]
                )
                guard db.changesCount > 0 else { continue }
                requested.insert(candidate.id)
                if !facts.contains(.duplicateFacts), try DuplicatesHoldSQL.changesDuplicates(
                    .images, heldBefore: heldBefore, libraryRootID: rootID, relativePath: relativePath, db: db
                ) {
                    facts.insert(.duplicateFacts)
                }
                if !facts.contains(.faceTiles), try Self.holdsFace(libraryRootID: rootID, relativePath: candidate.id.relativePath, db: db) {
                    facts.insert(.faceTiles)
                }
            }
            return (requested, facts)
        }
        OtosLog.metadata.noticeOperation("metadata.refresh", phase: "downloadRequested", fields: [
            "candidates": "\(candidates.count)", "requested": "\(requested.count)",
        ])
        if !requested.isEmpty {
            notifyCatalogChanged(.changed(facts, rows: .rows(requested)))
        }
        return requested.count
    }

    /// Writes re-read metadata records (ADR 0039). Each one lands only while its row still
    /// has the file signature it was read at and its stored record is still older than the
    /// current reading of the stored record's own family — the test that made it a
    /// candidate. Revisions are numbered per family, so the stored record is never compared
    /// with the new one's: a re-read can change family (0.7.1's `unknown` 1 is 0.8.0's
    /// `png` 0). A file that changed meanwhile, or a row enrichment re-stamped at its
    /// family's current revision, keeps what it has. Only the metadata and the columns
    /// derived from it change; thumbnails and previews do not.
    func applyMetadataRefresh(_ refreshes: [MetadataRefresh]) async throws -> Int {
        guard !refreshes.isEmpty else { return 0 }
        let rootIDsByPath = roots.rowIDSnapshot()
        let dbWriter = try database()
        let timed = try await timedWrite(dbWriter) { db in
            var outcome = EnrichmentBatchWriteOutcome()
            for refresh in refreshes {
                guard let rootID = rootIDsByPath[refresh.id.libraryRootPath] else { continue }
                let arguments = AssetKey(rootID: rootID, path: refresh.id.relativePath).arguments
                guard try Row.fetchOne(
                    db,
                    sql: AssetEnrichmentSQL.metadataRefreshStillOwedSQL,
                    arguments: arguments + [refresh.sourceSize, refresh.sourceSize, refresh.sourceMTimeSeconds]
                ) != nil else { continue }
                let overlaySQL = AssetEnrichmentSQL.overlayBeforeWriteSQL
                let oldRow = try Row.fetchOne(db, sql: overlaySQL, arguments: arguments)
                    .map(EnrichmentOverlayBeforeWrite.init(row:))
                let heldBefore = try DuplicatesHoldSQL.holds(
                    libraryRootID: rootID, relativePath: refresh.id.relativePath.rawValue, db: db
                )
                try Self.writeMetadataProjection(
                    refresh.metadata,
                    enrichedKind: refresh.enrichedKind,
                    enrichedFormat: refresh.enrichedFormat,
                    sourceMTimeSeconds: refresh.sourceMTimeSeconds,
                    libraryRootID: rootID,
                    relativePath: refresh.id.relativePath,
                    db: db
                )
                let newRow = try Row.fetchOne(db, sql: overlaySQL, arguments: arguments)
                    .map(EnrichmentOverlayBeforeWrite.init(row:))
                outcome.facts.formUnion([.detail, .mediaRecord])
                var rowFacts: CatalogChangedFacts = .mediaRecord
                if let oldRow, let newRow {
                    let changed = oldRow.changedFacts(to: newRow)
                    rowFacts.formUnion(changed)
                    outcome.facts.formUnion(changed)
                    if try oldRow.changesStacks(
                        to: newRow, facts: changed, libraryRootID: rootID, relativePath: refresh.id.relativePath, db: db
                    ) {
                        outcome.facts.insert(.stacks)
                    }
                }
                if try DuplicatesHoldSQL.changesDuplicates(
                    rowFacts, heldBefore: heldBefore, libraryRootID: rootID, relativePath: refresh.id.relativePath.rawValue, db: db
                ) {
                    outcome.facts.insert(.duplicateFacts)
                }
                if oldRow?.captureWallCompact != newRow?.captureWallCompact {
                    outcome.namingChangedRoots.insert(refresh.id.libraryRootPath)
                }
                outcome.applied.insert(refresh.id)
            }
            return outcome
        }
        let outcome = timed.value
        OtosLog.metadata.noticeOperation("metadata.refresh.write", phase: "finish", fields: [
            "attempted": "\(refreshes.count)",
            "applied": "\(outcome.appliedCount)",
            "facts": outcome.facts.diagnosticDescription,
            "writeMs": "\(timed.waitMs + timed.execMs)",
        ])
        if outcome.appliedCount > 0 {
            for rootPath in outcome.namingChangedRoots {
                recordNamingChange(for: rootPath, reason: "metadataRefresh")
            }
            notifyCatalogChanged(.changed(outcome.facts, rows: .rows(outcome.applied)))
        }
        return outcome.appliedCount
    }

    private func discardStagedImages(_ images: [StagedDerivedImage]) {
        guard let thumbnailDirectory else {
            return
        }
        for image in images {
            ThumbnailStore.discard(image, in: thumbnailDirectory)
        }
    }

    private func recordEnrichmentBatchError(_ error: Error, count: Int) async {
        OtosLog.metadata.error(
            """
            Enrichment batch persist failed count=\(count, privacy: .public) \
            error=\(String(describing: error), privacy: .public)
            """
        )
        OtosLog.metadata.error(
            "op=catalog.enrichment.batch phase=error count=\(count, privacy: .public) error=\(String(describing: error), privacy: .public)"
        )
    }

    func addLibrary(url: URL) async throws {
        let path = try CatalogPath.normalizedExistingDirectoryPath(for: url)
        try await ensureStartedForMutation()
        let capabilities = await Self.probeCapabilities(of: path)
        try validateNoOverlap(path)
        try await insertLibraryRootAndStartScan(path, capabilities: capabilities, operation: "catalog.library.add")
    }

    func ensureLibrary(url: URL) async throws {
        let path = try CatalogPath.normalizedExistingDirectoryPath(for: url)
        try await ensureStartedForMutation()
        OtosLog.catalog.notice(
            "op=catalog.library.ensure phase=start rootPath=\(path.rawValue, privacy: .public)"
        )
        if roots[path] != nil {
            OtosLog.catalog.info("Smoke library root already saved path=\(path.rawValue, privacy: .public)")
            OtosLog.catalog.notice(
                "op=catalog.library.ensure phase=exists rootPath=\(path.rawValue, privacy: .public)"
            )
            return
        }
        let capabilities = await Self.probeCapabilities(of: path)
        guard roots[path] == nil else { return }
        try validateNoOverlap(path)
        try await insertLibraryRootAndStartScan(
            path,
            capabilities: capabilities,
            operation: "catalog.library.ensure",
            recordsStart: false
        )
    }

    /// Removes a library from the catalog: now when no other owner holds it, otherwise as
    /// soon as the import, reorganization or Move to Trash holding it releases it. The
    /// outcome says which, and names the holder the removal waits for.
    func removeLibrary(path: LibraryRootPath) async throws -> LibraryRemovalOutcome {
        try await ensureStartedForMutation()
        // An attachment holds a root for a few writes, never for work the user waits on: the
        // removal waits for it and then removes what the root has become.
        while namespaceMutationLeases[path]?.owner == .sourceAttachment {
            await untilNamespaceMutationLeaseReleased(at: path)
        }
        guard let rootState = roots[path] else {
            return .notInCatalog
        }
        if let holder = namespaceMutationLeases[path] {
            // A removal that already holds the root will remove it; nothing to record.
            if holder.owner != .libraryRemoval {
                deferredLibraryRemovals.insert(path)
            }
            OtosLog.catalog.noticeOperation("catalog.library.remove", phase: "deferred", fields: [
                "rootPath": path.rawValue,
                "heldBy": holder.owner.rawValue,
            ])
            return .waiting(for: holder.owner)
        }
        try await removeLibrary(rootState, holding: installNamespaceMutationLease(for: path, owner: .libraryRemoval))
        return .removed
    }

    /// The removal owns the root's namespace from the moment it starts: no import,
    /// reorganization or Move to Trash can begin on it, and the reconcile loop leaves its
    /// dirt alone. It stops watching the root and cancels its scan; a batch that scan
    /// delivers later is refused, because the scan no longer owns the root. If the delete
    /// fails the library stays, watched again and rescanned, and the error is thrown.
    private func removeLibrary(_ rootState: RootRuntimeState, holding lease: RootNamespaceMutationLease) async throws {
        let path = rootState.path
        deferredLibraryRemovals.remove(path)
        let root = rootState.root
        let rootRowID = rootState.rowID
        let state = OtosSignpost.persistence.beginInterval("CatalogRemoveRoot")
        defer { OtosSignpost.persistence.endInterval("CatalogRemoveRoot", state) }
        OtosLog.catalog.notice(
            "op=catalog.library.remove phase=start rootPath=\(path.rawValue, privacy: .public)"
        )

        stopWatching(path)
        filesystemWatchingArmed.remove(path)
        cancelRuntimeWork(for: path)

        let removal: DerivedRemoval
        do {
            let dbQueue = try database()
            // The user's removal, which the window shows as it lands.
            let purgedThumbnails = try await reader(for: windowReads.lane).readFreeingConnection { db in
                try Self.fetchExistingAssetRows(libraryRootID: rootRowID, db: db)
            }.flatMap(\.derivedImagePaths)
            let derivedFolder = derivedFolder
            await namespaceMutationReached?(.removalWillDelete(path))
            removal = try await dbQueue.write { db in
                try Self.deleteLibraryRoot(rootRowID: rootRowID, db: db)
                return try derivedFolder?.unname(purgedThumbnails, db: db) ?? .nothing
            }
        } catch {
            OtosLog.catalog.errorOperation("catalog.library.remove", phase: "failed", fields: [
                "rootPath": path.rawValue,
                "error": String(describing: error),
            ])
            restoreAfterFailedRemoval(lease)
            throw error
        }

        // The files go, off the actor, while the removal still holds the root: until its lease
        // drops and the root leaves, an attachment of the same source waits rather than take
        // the path whose staging folder is being deleted, and makes its own folder only after.
        await removal.perform()
        await deleteStagingIfNeeded(root)
        dropNamespaceMutationLease(at: path)
        removeRoot(path: path)
        OtosLog.catalog.notice(
            "op=catalog.library.remove phase=finish rootPath=\(path.rawValue, privacy: .public)"
        )
        notifyCatalogChanged(.libraryRemoved(path))
        startNextScanIfNeeded()
    }

    /// Hands a library the user asked to remove to a removal lease the moment no other
    /// owner holds it, and rings the reconcile loop that runs the removal. Taking the
    /// lease here, synchronously with the release that freed the root, is what keeps a
    /// new import or Move to Trash from starting on it first.
    @discardableResult
    private func handOffDeferredLibraryRemoval(_ path: LibraryRootPath) -> Bool {
        guard deferredLibraryRemovals.contains(path),
              roots[path] != nil,
              namespaceMutationLeases[path] == nil
        else {
            return false
        }
        deferredLibraryRemovals.remove(path)
        handedOffLibraryRemovals[path] = installNamespaceMutationLease(for: path, owner: .libraryRemoval)
        OtosLog.catalog.noticeOperation("catalog.library.remove", phase: "handedOff", fields: [
            "rootPath": path.rawValue,
        ])
        requestReconcile()
        return true
    }

    /// Runs the removals a release handed over; each already holds its lease. A root that
    /// moved away from its lease's path since then is no longer under it, so that lease is
    /// dropped and the request has already followed the root (`moveRootRuntimeState`).
    private func runHandedOffLibraryRemovals() async {
        while let path = handedOffLibraryRemovals.keys.min(by: { $0.rawValue < $1.rawValue }),
              let lease = handedOffLibraryRemovals.removeValue(forKey: path)
        {
            guard let rootState = roots[path], ownsNamespaceMutationLease(lease) else {
                if namespaceMutationLeases[path]?.generation == lease.generation {
                    dropNamespaceMutationLease(at: path)
                }
                continue
            }
            do {
                try await removeLibrary(rootState, holding: lease)
            } catch {
                OtosLog.catalog.errorOperation("catalog.library.remove", phase: "deferredFailed", fields: [
                    "rootPath": path.rawValue,
                    "error": String(describing: error),
                ])
            }
        }
    }

    /// A removal that could not delete the root's rows leaves the library as it was: its
    /// lease is released, it is watched again, and a full scan restores whatever changed
    /// while it was not watched.
    private func restoreAfterFailedRemoval(_ lease: RootNamespaceMutationLease) {
        let path = lease.libraryRootPath
        guard namespaceMutationLeases[path]?.generation == lease.generation else { return }
        dropNamespaceMutationLease(at: path)
        filesystemWatchingArmed.insert(path)
        watchRoot(path)
        enqueueScans([path], reason: .requested)
        // The root's own state moved (its removal ended); no row did.
        notifyCatalogChanged(.changed(.membership, rows: .none))
    }

    /// Reorders library-kind roots, moving the one at `sourceIndex` (within the
    /// library-only, currently-displayed order) to `destinationIndex`. Settings →
    /// Libraries' drag, `Move Up`/`Move Down`, and ⌘↑/⌘↓ all call this one intent —
    /// one user action, one path. The first entry in the
    /// result becomes the deterministic import destination
    /// (`MediaOperationCoordinator.refreshSources`).
    /// Moves one library within the user's order. The move names libraries, not
    /// positions, and is applied to the order this actor holds now, so two quick moves
    /// compose and a move made against a list that changed since it was drawn still
    /// moves the library the user pointed at. A move that names a library no longer
    /// present, or that would not change the order, changes nothing.
    func moveLibrary(_ path: LibraryRootPath, _ move: LibraryOrderMove) async throws {
        try await ensureStartedForMutation()
        let current = currentLibraries().filter(\.kind.isInLibrariesSection).map(\.path)
        guard let orderedPaths = move.reordering(current, moving: path), orderedPaths != current else {
            OtosLog.catalog.noticeOperation("catalog.library.reorder", phase: "unchanged", fields: [
                "path": path.rawValue,
                "move": String(describing: move),
            ])
            return
        }

        // Apply to in-memory state before the write suspends, not after: a
        // concurrent second call must compute its own reorder against this
        // one's result, not against the pre-move snapshot it would otherwise
        // still see while this call awaits the DB write.
        for (index, path) in orderedPaths.enumerated() {
            guard var state = roots[path] else { continue }
            state.sortIndex = Int64(index)
            roots.upsert(state)
        }
        let dbQueue = try database()
        try await dbQueue.write { db in
            try Self.writeLibraryRootSortIndexes(orderedPaths, db: db)
        }
        OtosLog.catalog.notice(
            "op=catalog.library.reorder phase=finish count=\(orderedPaths.count, privacy: .public)"
        )
        // The root's own state moved (its order, a scan or listing starting or ending);
        // no row did, and the rows a scan changed or deleted were announced with them.
        notifyCatalogChanged(.changed(.membership, rows: .none))
    }

    private func rootForDeviceIdentity(_ identity: DeviceIdentity) -> LibraryRoot? {
        roots.rootForDeviceIdentity(identity)
    }

    /// Returns the scan task it cancelled, if the root's scan was running, so a caller
    /// that must know the root's files are no longer being read can await its exit.
    @discardableResult
    private func cancelRuntimeWork(for path: LibraryRootPath) -> Task<Void, Never>? {
        unrequestedLoadedRootPaths.removeAll { $0 == path }
        cancelFilesystemEventPass(for: path)
        filesystemDirty.removeValue(forKey: path)
        lastSuccessfulFullRootScanAt.removeValue(forKey: path)
        knownMaterializationSuppression.removeAll(under: path)
        guard let lane = scanLeases.cancelWork(for: path) else {
            return nil
        }
        let cancelledScan = scanTasks.removeValue(forKey: lane)
        cancelledScan?.cancel()
        return cancelledScan
    }

    private func releaseEnrichmentClaimsForRoot(_ rootRowID: Int64) async {
        guard let dbWriter else {
            return
        }
        do {
            try await dbWriter.write { db in
                try EnrichmentClaimGateway.releaseEnrichmentClaims(rootID: rootRowID, db: db)
            }
        } catch {
            OtosLog.metadata.error(
                "Root enrichment claim release failed error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Deletes the staging folder of a removed source that stages its originals, on the
    /// file-deletion queue (`FileDeletion`): thousands of staged files take the volume seconds
    /// to delete, and the actor is not held for them.
    private func deleteStagingIfNeeded(_ root: LibraryRoot) async {
        guard root.kind.stagesOriginals else {
            return
        }
        let reached = stagingDeletionReached
        await FileDeletion.run {
            reached?(root.path)
            do {
                try FileManager.default.removeItem(at: root.path.url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                return
            } catch {
                // The staging folder is Otos's own; a removal that fails leaves it for the
                // launch-time staging sweep, and is logged so the leftover is explained.
                OtosLog.fileAccess.errorOperation("source.staging", phase: "removeFailed", fields: [
                    "rootPath": root.path.rawValue,
                    "error": String(describing: error),
                ])
            }
        }
    }

    /// Attaches a card, a camera or a phone. A source Otos knows by its identity, or a new one
    /// mounted where an unavailable source's root still is (a card swapped at the same
    /// `/Volumes/…`), takes over that root's row: a mutation of the root's namespace, so it
    /// holds the root's lease (`sourceAttachment`) from its decision through its writes. While a
    /// removal or another attachment holds that root, it waits for it to be released and
    /// decides again: after a removal, the source is a new root. When another owner (an
    /// import, a Trash move, an erase) holds the root, it attaches without the lease, and each
    /// write re-checks that the root is still the row it read; a root removed meanwhile is
    /// decided again. A camera's or phone's staging folder is made only after that decision,
    /// so a removal of the same source that it waited for never deletes the folder it attaches
    /// at. Releasing the lease and making the source available are one step, so retention,
    /// which leaves a root under a lease, never meets it half attached.
    private func attachRemovableRoot(_ attachment: RemovableRootAttachment) async throws {
        let lastSeenAt = wallClock()
        let dbQueue = try database()
        var lease: RootNamespaceMutationLease?
        // What the attachment's writes changed beyond the root itself, which it announces as it
        // finishes: a root that moved renamed its rows' derived images.
        var wrote: CatalogChangedFacts = []
        defer {
            // Reached only on a throw: the attachment releases its lease before it finishes.
            if let lease {
                releaseNamespaceMutationLease(lease)
            }
        }
        while true {
            let identified = rootForDeviceIdentity(attachment.identity).flatMap { roots[$0.path] }
            guard let existing = identified ?? roots[attachment.path] else {
                try makeStagingFolderIfNeeded(for: attachment)
                try await insertRemovableRoot(attachment, lastSeenAt: lastSeenAt, dbWriter: dbQueue)
                break
            }
            if let holder = namespaceMutationLeases[existing.path],
               holder.owner == .libraryRemoval || holder.owner == .sourceAttachment
            {
                OtosLog.catalog.noticeOperation("catalog.removable.attach", phase: "waits", fields: [
                    "rootPath": existing.path.rawValue, "heldBy": holder.owner.rawValue,
                ])
                await namespaceMutationReached?(.attachmentWaits(existing.path))
                await untilNamespaceMutationLeaseReleased(at: existing.path)
                continue
            }
            if namespaceMutationLeases[existing.path] == nil {
                lease = installNamespaceMutationLease(for: existing.path, owner: .sourceAttachment)
            }
            try makeStagingFolderIfNeeded(for: attachment)
            let tookOver = if identified != nil {
                try await updateExistingRemovableRoot(attachment, existing: existing, lastSeenAt: lastSeenAt, dbWriter: dbQueue)
            } else {
                try await reuseRemovableRoot(existing, for: attachment, lastSeenAt: lastSeenAt, dbWriter: dbQueue)
            }
            if existing.path != attachment.path {
                // Written whether or not the root was still the row once the move was written.
                wrote.insert(.images)
            }
            if tookOver {
                break
            }
            // The root was removed while this attachment wrote: decide again.
            if let held = lease {
                releaseNamespaceMutationLease(held)
                lease = nil
            }
        }
        if await markRetainedRowsAwaitingPresence(attachment, dbWriter: dbQueue) > 0 {
            wrote.formUnion(.presence)
        }
        if let held = lease {
            lease = nil
            releaseNamespaceMutationLease(held)
        }
        await finishRemovableRootAttachment(attachment, wrote: wrote)
    }

    /// Makes the staging folder of a source that stages its originals, the folder its root is.
    /// The attachment makes it once it has decided which root the source is and no removal
    /// holds that root, never before: a removal deletes the staging folder while its lease
    /// still holds the root, so a folder made before the attachment waited out that lease
    /// would be the one the removal deletes.
    private func makeStagingFolderIfNeeded(for attachment: RemovableRootAttachment) throws {
        guard attachment.kind.stagesOriginals else {
            return
        }
        try FileManager.default.createDirectory(at: attachment.path.url, withIntermediateDirectories: true)
    }

    /// Whether `rowID` is still the root at `path`: what an attachment re-reads after each of
    /// its writes before it applies one.
    private func rootStill(_ rowID: Int64, at path: LibraryRootPath) -> Bool {
        roots[path]?.rowID == rowID
    }

    /// A source of a different identity mounted where an unavailable source's root still is:
    /// it takes over that row. False when the row was gone by the time the write ran.
    private func reuseRemovableRoot(
        _ existing: RootRuntimeState,
        for attachment: RemovableRootAttachment,
        lastSeenAt: Date,
        dbWriter: CatalogWriter
    ) async throws -> Bool {
        try validateNoOverlap(attachment.path, ignoring: existing.rowID)
        await namespaceMutationReached?(.attachmentWillWrite(attachment.path))
        let updated = try await dbWriter.write { db in
            try db.execute(
                sql: LibraryRootSQL.updateIdentitySQL,
                arguments: [
                    attachment.identity,
                    attachment.displayName,
                    lastSeenAt.timeIntervalSince1970,
                    attachment.capabilities.storedCaseSensitiveColumn,
                    attachment.deviceModel,
                    existing.rowID,
                ]
            )
            return db.changesCount > 0
        }
        guard updated, rootStill(existing.rowID, at: existing.path) else {
            return false
        }
        moveRootRuntimeState(
            oldPath: existing.path,
            newRoot: attachment.root(lastSeenAt: lastSeenAt),
            rootRowID: existing.rowID
        )
        return true
    }

    /// What the source held when it was last read is not what it holds now: a card may
    /// have been erased, formatted or filled in a camera since. Its retained rows keep
    /// every overlay (ADR 0008) but stay out of sight until this attachment's scan or
    /// enumeration sees each file, so the grid fills as the source is read and never
    /// shows what it held last time. The completed read deletes what it never saw. A
    /// failed write is logged and the attachment goes on: the rows then show as last held.
    /// Returns how many rows it marked.
    private func markRetainedRowsAwaitingPresence(
        _ attachment: RemovableRootAttachment,
        dbWriter: CatalogWriter
    ) async -> Int {
        guard let rootRowID = roots[attachment.path]?.rowID else {
            return 0
        }
        let marked: Int
        do {
            marked = try await dbWriter.write { db in
                try Self.setAwaitingPresence(true, rootRowID: rootRowID, db: db)
            }
        } catch {
            OtosLog.catalog.errorOperation("catalog.removable.attach", phase: "awaitingPresenceFailed", fields: [
                "rootPath": attachment.path.rawValue,
                "error": String(describing: error),
            ])
            return 0
        }
        OtosLog.catalog.noticeOperation("catalog.removable.attach", phase: "awaitingPresence", fields: [
            "rootPath": attachment.path.rawValue,
            "kind": attachment.kind.rawValue,
            "count": "\(marked)",
        ])
        return marked
    }

    /// A source Otos knows by its identity, at its root's path or a new one. False when the
    /// root was removed by the time a write ran.
    private func updateExistingRemovableRoot(
        _ attachment: RemovableRootAttachment,
        existing: RootRuntimeState,
        lastSeenAt: Date,
        dbWriter: CatalogWriter
    ) async throws -> Bool {
        let rootRowID = existing.rowID
        let oldPath = existing.path
        try validateNoOverlap(attachment.path, ignoring: rootRowID)
        if oldPath != attachment.path {
            let derivedFolder = derivedFolder
            try await dbWriter.write { db in
                let migrations = try Self.updateLibraryRootPath(rootRowID: rootRowID, path: attachment.path, db: db)
                try derivedFolder?.journalRenames(migrations.map { ($0.oldRelativeName, $0.newRelativeName) }, db: db)
            }
            try await applyPendingDerivedRenames(lane: backgroundReads.lane)
            guard rootStill(rootRowID, at: oldPath) else { return false }
        }
        let updated = try await dbWriter.write { db in
            try Self.updateLibraryRootSourceFacts(
                rootRowID: rootRowID,
                path: attachment.path,
                displayName: attachment.displayName,
                lastSeenAt: lastSeenAt,
                capabilities: attachment.capabilities,
                deviceModel: attachment.deviceModel,
                db: db
            )
            return db.changesCount > 0
        }
        guard updated, rootStill(rootRowID, at: oldPath) else {
            return false
        }
        moveRootRuntimeState(
            oldPath: oldPath,
            newRoot: attachment.root(lastSeenAt: lastSeenAt),
            rootRowID: rootRowID
        )
        return true
    }

    private func insertRemovableRoot(
        _ attachment: RemovableRootAttachment,
        lastSeenAt: Date,
        dbWriter: CatalogWriter
    ) async throws {
        try validateNoOverlap(attachment.path)
        let storedRoot = try await dbWriter.write { db in
            try Self.insertLibraryRoot(
                path: attachment.path,
                kind: attachment.kind,
                deviceIdentity: attachment.identity,
                displayName: attachment.displayName,
                lastSeenAt: lastSeenAt,
                capabilities: attachment.capabilities,
                deviceModel: attachment.deviceModel,
                db: db
            )
        }
        let root = libraryRoot(from: storedRoot)
        upsert(RootRuntimeState(
            root: root,
            rowID: storedRoot.id,
            sortIndex: storedRoot.sortIndex,
            availability: .unknown,
            activity: .idle,
            isEjectable: false,
            capabilities: storedRoot.capabilities
        ))
    }

    /// Makes the attached source available, announcing what `wrote` names with it.
    private func finishRemovableRootAttachment(_ attachment: RemovableRootAttachment, wrote: CatalogChangedFacts) async {
        guard var state = roots[attachment.path] else {
            return
        }
        state.availability = .available
        state.activity = attachment.activity
        state.isEjectable = attachment.isEjectable
        state.attachmentGeneration &+= 1
        state.capabilities = attachment.capabilities
        // Quiescence belongs to one attachment's pending unmount; a new attachment
        // starts unquiesced.
        state.isQuiesced = false
        upsert(state)
        if attachment.kind.hasFilesystemNamespace {
            watchRoot(attachment.path)
        }
        OtosLog.catalog.info(
            """
            Removable source attached kind=\(attachment.kind.rawValue, privacy: .public) \
            identity=\(attachment.identity, privacy: .public) path=\(attachment.path.rawValue, privacy: .public)
            """
        )
        OtosLog.catalog.notice(
            "op=catalog.removable.attach phase=finish kind=\(attachment.kind.rawValue, privacy: .public) identity=\(attachment.identity, privacy: .public) rootPath=\(attachment.path.rawValue, privacy: .public) displayName=\(attachment.displayName, privacy: .public) capabilities=\(String(describing: attachment.capabilities), privacy: .public) deviceModel=\(attachment.deviceModel ?? "unknown", privacy: .public) volumeFormat=\(attachment.volumeFormat ?? "unknown", privacy: .public)"
        )
        // The root's row and its reach: every row it holds is in reach again (`membership`,
        // no row named), with what the attachment's writes changed.
        notifyCatalogChanged(.changed(CatalogChangedFacts.membership.union(wrote)))
        if attachment.enqueuesScan {
            enqueueScans([attachment.path], priority: .front, reason: .removable)
        }
    }

    private func moveRootRuntimeState(oldPath: LibraryRootPath, newRoot: LibraryRoot, rootRowID: Int64) {
        let previous = roots[oldPath]
        removeRoot(path: oldPath)
        filesystemWatchingArmed.remove(oldPath)
        scanLeases.removeRescanDeferral(oldPath)
        filesystemEventBatches.removeValue(forKey: oldPath)
        filesystemDirty.removeValue(forKey: oldPath)
        lastSuccessfulFullRootScanAt.removeValue(forKey: oldPath)
        // The root keeps every runtime fact it had (quiescence, epoch, revisions) and
        // changes only where it is. Moving it changes its namespace, so the revisions
        // and the mutation epoch advance: an observation taken before the move is stale.
        var state = previous ?? RootRuntimeState(
            root: newRoot,
            rowID: rootRowID,
            sortIndex: 0,
            availability: .unknown,
            activity: .idle,
            isEjectable: false,
            capabilities: .unknown
        )
        state.root = newRoot
        state.rowID = rootRowID
        state.planRevision &+= 1
        state.namespaceRevision &+= 1
        state.namespaceMutationEpoch &+= 1
        upsert(state)
        // A removal the user asked for follows the root to where it now is.
        if deferredLibraryRemovals.remove(oldPath) != nil {
            deferredLibraryRemovals.insert(newRoot.path)
            handOffDeferredLibraryRemoval(newRoot.path)
        }
    }

    /// A root's case sensitivity, read off this actor and before any write: the read is a
    /// filesystem call that can stall on a slow volume, and neither the actor nor the
    /// database's write lock is held across it.
    @concurrent
    private static func probeCapabilities(of path: LibraryRootPath) async -> VolumeNamespaceCapabilities {
        FilesystemNamespaceSemantics.probeVolumeCapabilities(rootURL: path.url)
    }

    private func insertLibraryRootAndStartScan(
        _ path: LibraryRootPath,
        capabilities: VolumeNamespaceCapabilities,
        operation: String,
        recordsStart: Bool = true
    ) async throws {
        let dbQueue = try database()

        let state = OtosSignpost.persistence.beginInterval("CatalogAddRoot")
        defer {
            OtosSignpost.persistence.endInterval("CatalogAddRoot", state)
        }
        if recordsStart {
            OtosLog.catalog.notice(
                "op=\(operation, privacy: .public) phase=start rootPath=\(path.rawValue, privacy: .public)"
            )
        }
        let storedRoot = try await dbQueue.write { db in
            try Self.insertLibraryRoot(
                path: path,
                capabilities: capabilities,
                db: db
            )
        }

        let root = libraryRoot(from: storedRoot)
        upsert(RootRuntimeState(
            root: root,
            rowID: storedRoot.id,
            sortIndex: storedRoot.sortIndex,
            availability: .available,
            activity: .idle,
            isEjectable: false,
            capabilities: storedRoot.capabilities
        ))
        OtosLog.catalog.info("Library root added path=\(root.path.rawValue, privacy: .public)")
        let message = "op=\(operation) phase=finish "
            + "rootPath=\(root.path.rawValue) "
            + "capabilities=\(storedRoot.capabilities)"
        OtosLog.catalog.notice("\(message, privacy: .public)")
        // A root added with no rows yet: no row changed, nor which rows are in reach.
        notifyCatalogChanged(.changed(.membership, rows: .none))
        watchRoot(root.path)
        enqueueScans([root.path], reason: .firstWalk)
    }

    func attachRemovableVolume(
        mountURL: URL,
        identity: DeviceIdentity,
        displayName: String,
        isEjectable: Bool,
        capabilities: VolumeNamespaceCapabilities,
        deviceModel: String? = nil,
        volumeFormat: String? = nil
    ) async throws {
        let path = try CatalogPath.normalizedExistingDirectoryPath(for: mountURL)
        try await ensureStartedForMutation()
        try await attachRemovableRoot(RemovableRootAttachment(
            kind: .removableVolume,
            path: path,
            identity: identity,
            displayName: displayName,
            isEjectable: isEjectable,
            activity: .idle,
            enqueuesScan: true,
            capabilities: capabilities,
            deviceModel: deviceModel,
            volumeFormat: volumeFormat
        ))
    }

    @discardableResult
    func attachDeviceMTP(
        stagingRootURL: URL,
        identity: DeviceIdentity,
        displayName: String
    ) async throws -> LibraryRootPath {
        let path = try CatalogPath.normalizedDirectoryPath(for: stagingRootURL)
        try await ensureStartedForMutation()
        try await attachRemovableRoot(RemovableRootAttachment(
            kind: .deviceMTP,
            path: path,
            identity: identity,
            displayName: displayName,
            isEjectable: false,
            activity: .enumerating,
            enqueuesScan: false,
            capabilities: .unknown,
            deviceModel: nil,
            volumeFormat: nil
        ))
        return path
    }

    /// Adds one Immich account as a library (ADR 0046 §2): a root whose path is its own
    /// staging folder, named by the account's identity, and whose rows will come from its
    /// server's listing. Adding the same account again returns its existing root.
    @discardableResult
    func addImmichAccount(
        server: URL,
        userID: String,
        displayName: String
    ) async throws -> LibraryRootPath {
        guard let identity = DeviceIdentity.immichAccount(server: server, userID: userID),
              let serverURL = ImmichServerAddress.normalized(server)
        else {
            throw CatalogStoreError.invalidRemoteServer
        }
        try await ensureStartedForMutation()
        if let existing = roots.rootForDeviceIdentity(identity) {
            return existing.path
        }
        let stagingURL = stagingContainers.sessionRoot(in: .remote, identity: identity)
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        let path = try CatalogPath.normalizedDirectoryPath(for: stagingURL)
        try validateNoOverlap(path)
        let storedRoot = try await database().write { db in
            try Self.insertLibraryRoot(
                path: path,
                kind: .immichAccount,
                deviceIdentity: identity,
                displayName: displayName,
                // Otos lays the staging folder out by asset ID and probes no volume for it:
                // unknown keys compare case-insensitively, the choice that never splits a name.
                capabilities: .unknown,
                remoteBaseURL: serverURL,
                db: db
            )
        }
        upsert(RootRuntimeState(
            root: libraryRoot(from: storedRoot),
            rowID: storedRoot.id,
            sortIndex: storedRoot.sortIndex,
            availability: LibraryRootKind.immichAccount.availabilityAtLaunch { false },
            activity: .idle,
            isEjectable: false,
            capabilities: storedRoot.capabilities
        ))
        OtosLog.catalog.noticeOperation("catalog.immich.add", phase: "finish", fields: [
            "rootPath": path.rawValue,
            "server": serverURL.absoluteString,
        ])
        // A root added with no rows yet: no row changed, nor which rows are in reach.
        notifyCatalogChanged(.changed(.membership, rows: .none))
        return path
    }

    /// A source is last seen when it leaves, not only when it arrives: a card left in for
    /// weeks was seen all that time. Attach stamps the arrival; this stamps the departure.
    /// A source still attached when Otos quits keeps its arrival stamp, so retention can
    /// count from up to one session early — it would take a session 90 days long with
    /// the source attached throughout for that to forget a source too soon.
    private func recordLastSeen(of root: LibraryRoot, rootRowID: Int64) async {
        let lastSeenAt = wallClock()
        do {
            try await database().write { db in
                try Self.updateLibraryRootLastSeen(rootRowID: rootRowID, lastSeenAt: lastSeenAt, db: db)
            }
        } catch {
            OtosLog.catalog.errorOperation("catalog.removable.lastSeen", phase: "failed", fields: [
                "rootPath": root.path.rawValue,
                "error": String(describing: error),
            ])
            return
        }
        guard var state = roots[root.path], state.rowID == rootRowID else {
            return
        }
        state.root = LibraryRoot(
            path: state.root.path,
            kind: state.root.kind,
            deviceIdentity: state.root.deviceIdentity,
            displayName: state.root.displayNameOverride,
            lastSeenAt: lastSeenAt
        )
        upsert(state)
    }

    /// Ends the wait for a source's unseen files without the read that would have
    /// settled them (ADR 0013). On detach no attachment awaits them; when a read fails or
    /// ends incomplete it proved neither their presence nor their absence (ADR 0032 rule
    /// 4). Either way the source shows the rows it last held, as an offline card does.
    /// A failed write leaves them hidden until the next attach or launch, and is logged.
    private func releaseAwaitingPresence(of rootPath: LibraryRootPath, rootRowID: Int64, reason: String) async {
        do {
            let released = try await database().write { db in
                try Self.setAwaitingPresence(false, rootRowID: rootRowID, db: db)
            }
            if released > 0 {
                OtosLog.catalog.noticeOperation("catalog.removable.awaitingPresence", phase: "released", fields: [
                    "rootPath": rootPath.rawValue,
                    "reason": reason,
                    "count": "\(released)",
                ])
                bumpNamespaceRevision(for: rootPath)
                notifyCatalogChanged(.changed(.membership))
            }
        } catch {
            OtosLog.catalog.errorOperation("catalog.removable.awaitingPresence", phase: "releaseFailed", fields: [
                "rootPath": rootPath.rawValue,
                "reason": reason,
                "error": String(describing: error),
            ])
        }
    }

    /// Forgets every card and camera Otos has not seen for
    /// `RemovableSourceRetention.unseenPeriod`, exactly as Settings' Forget does: the
    /// source, its rows, its likes and its thumbnails (owner decision 2026-10-25,
    /// ADR 0013). It runs at launch, before any source re-attaches, so a source
    /// present now is judged by its stamp from an earlier session. A source with no
    /// last-seen stamp is kept: nothing says how long it has been away. Each removal
    /// re-reads its root and takes its lease in one step, so a root that a source attached
    /// to meanwhile — available, stamped now, or a different row — or that any owner holds,
    /// an attachment among them, is left; a source that attaches while the removal runs waits
    /// for it and attaches as a new source.
    func forgetRemovableSourcesUnseenForRetentionPeriod() async {
        let cutoff = wallClock().addingTimeInterval(-RemovableSourceRetention.unseenPeriod)
        func isExpired(_ state: RootRuntimeState) -> Bool {
            state.root.kind.isRemovable
                && state.availability != .available
                && (state.root.lastSeenAt.map { $0 < cutoff } ?? false)
        }
        let expired = roots.values.filter(isExpired).map { ($0.root, $0.rowID) }
        for (root, rowID) in expired.sorted(by: { $0.0.path.rawValue < $1.0.path.rawValue }) {
            guard let state = roots[root.path], state.rowID == rowID, isExpired(state) else {
                continue
            }
            if let holder = namespaceMutationLeases[root.path] {
                OtosLog.catalog.noticeOperation("catalog.removable.retention", phase: "left", fields: [
                    "rootPath": root.path.rawValue, "heldBy": holder.owner.rawValue,
                ])
                continue
            }
            do {
                try await removeLibrary(state, holding: installNamespaceMutationLease(for: root.path, owner: .libraryRemoval))
                OtosLog.catalog.noticeOperation("catalog.removable.retention", phase: "forgotten", fields: [
                    "rootPath": root.path.rawValue,
                    "kind": root.kind.rawValue,
                    "lastSeenAt": root.lastSeenAt.map { "\(Int64($0.timeIntervalSince1970))" } ?? "none",
                ])
            } catch {
                OtosLog.catalog.errorOperation("catalog.removable.retention", phase: "failed", fields: [
                    "rootPath": root.path.rawValue,
                    "error": String(describing: error),
                ])
            }
        }
    }

    func detachRemovableSource(identity: DeviceIdentity, reason: RemovableSourceDetachReason) async throws {
        try await ensureStartedForMutation()
        guard let root = rootForDeviceIdentity(identity),
              root.kind.isRemovable,
              let rootRowID = roots[root.path]?.rowID
        else {
            return
        }
        if identity.isTransient {
            // A transient identity never comes back, so its source goes: now, or once the
            // import holding it releases it.
            _ = try await removeLibrary(path: root.path)
            return
        }

        cancelRuntimeWork(for: root.path)
        stopWatching(root.path)
        filesystemWatchingArmed.remove(root.path)
        if var state = roots[root.path] {
            state.isEjectable = false
            state.activity = .idle
            upsert(state)
        }
        await releaseEnrichmentClaimsForRoot(rootRowID)
        await recordLastSeen(of: root, rootRowID: rootRowID)
        await releaseAwaitingPresence(of: root.path, rootRowID: rootRowID, reason: "detached")
        forgetUnreadableSources(under: root.path)
        setAvailability(.unavailable, for: root.path)
        // Detach keeps the staged bytes: they are already off the camera, and
        // discarding them here re-downloads the whole device on the next attach.
        // They are cleared at app close instead (APP-018).
        OtosLog.catalog.info(
            """
            Removable source detached identity=\(identity, privacy: .public) \
            reason=\(reason.rawValue, privacy: .public)
            """
        )
        OtosLog.catalog.notice(
            "op=catalog.removable.detach phase=finish identity=\(identity, privacy: .public) rootPath=\(root.path.rawValue, privacy: .public) kind=\(root.kind.rawValue, privacy: .public) reason=\(reason.rawValue, privacy: .public)"
        )
        // The root's own state moved: its activity, ejectability and last-seen stamp. Its
        // reach and the rows it released announced themselves (`setAvailability`,
        // `releaseAwaitingPresence`).
        notifyCatalogChanged(.changed(.membership, rows: .none))
        startNextScanIfNeeded()
    }

    func quiesceRemovableSource(identity: DeviceIdentity) async throws {
        try await ensureStartedForMutation()
        guard let root = rootForDeviceIdentity(identity),
              root.kind.isRemovable,
              let rootRowID = roots[root.path]?.rowID
        else {
            return
        }
        let cancelledScan = cancelRuntimeWork(for: root.path)
        if var state = roots[root.path] {
            state.activity = .idle
            state.isQuiesced = true
            upsert(state)
        }
        // The eject that follows needs the card's files closed: wait for the cancelled
        // scan to stop reading rather than assume it has.
        await cancelledScan?.value
        await releaseEnrichmentClaimsForRoot(rootRowID)
        forgetUnreadableSources(under: root.path)
        OtosLog.catalog.notice(
            "op=catalog.removable.quiesce phase=finish identity=\(identity, privacy: .public) rootPath=\(root.path.rawValue, privacy: .public) kind=\(root.kind.rawValue, privacy: .public)"
        )
    }

    /// An import batch starts copying from `source`. For a card this stops enrichment
    /// reading it until `endImportSourceRead`: no new claims there, and the claims already
    /// handed out are released, so the coordinator drops the work it queued for them
    /// (`EnrichmentCoordinator.dequeueEnrichmentWork`). Work already reading finishes.
    func beginImportSourceRead(_ batch: ImportBatchID, source: LibraryRootPath) async {
        guard var state = roots[source] else {
            return
        }
        let wasEnrichable = state.isEnrichable
        state.importingBatches.insert(batch)
        upsert(state)
        let paused = wasEnrichable && !state.isEnrichable
        if paused {
            await releaseEnrichmentClaimsForRoot(state.rowID)
            notifyCatalogChanged(.changed(.detail))
        }
        OtosLog.catalog.noticeOperation("import.sourceRead", phase: "begin", fields: [
            "rootPath": source.rawValue,
            "batch": "\(batch.unixMilliseconds)",
            "kind": state.root.kind.rawValue,
            "enrichmentPaused": "\(state.isCardBeingImported)",
        ])
    }

    /// The batch stopped copying from `source`, however it ended. When it was the last
    /// import reading a card, enrichment may claim the card again.
    func endImportSourceRead(_ batch: ImportBatchID, source: LibraryRootPath) async {
        guard let state = roots[source], state.importingBatches.contains(batch) else {
            return
        }
        let resumed = changeEnrichability(of: source) { $0.importingBatches.remove(batch) }
        OtosLog.catalog.noticeOperation("import.sourceRead", phase: "end", fields: [
            "rootPath": source.rawValue,
            "batch": "\(batch.unixMilliseconds)",
            "kind": state.root.kind.rawValue,
            "enrichmentResumed": "\(resumed)",
        ])
    }

    /// Changes what decides whether enrichment may claim on `path` (`RootRuntimeState.isEnrichable`):
    /// a root that becomes claimable again is announced (`.detail`, what enrichment's gate
    /// hears), so a camera, which no scan follows, is read again without another change.
    /// Returns whether it became claimable.
    @discardableResult
    private func changeEnrichability(of path: LibraryRootPath, _ change: (inout RootRuntimeState) -> Void) -> Bool {
        guard var state = roots[path] else { return false }
        let wasEnrichable = state.isEnrichable
        change(&state)
        upsert(state)
        guard !wasEnrichable, state.isEnrichable else { return false }
        notifyCatalogChanged(.changed(.detail))
        return true
    }

    /// The roots enrichment may claim on now: one answer, read by the claim queries and
    /// by the coordinator's queue alike.
    /// Offers a row whose original a source's download just staged to enrichment ahead of
    /// other work, for every product it still owes (ADR 0046 §7): its rendering — RAW9
    /// for a RAW, lazily, when the user's work downloaded it — and its digest.
    func originalBecameLocal(_ id: MediaAssetID) {
        guard !localBytesAwaitingProducts.contains(id) else {
            return
        }
        localBytesAwaitingProducts.append(id)
        OtosLog.catalog.noticeOperation("enrichment.candidates", phase: "originalLocal", fields: [
            "rootPath": id.libraryRootPath.rawValue, "relativePath": id.relativePath.rawValue,
        ])
        notifyCatalogChanged(.changed(.detail))
    }

    /// Records whether the source behind `path` answers reads now (`RootRuntimeState.isSourceAnswering`).
    /// A source that stops answering has its enrichment claims released, so no read
    /// waits on it; one that answers again is claimable at the next pass.
    func setSourceAnswering(_ answering: Bool, for path: LibraryRootPath) async {
        guard var state = roots[path], state.isSourceAnswering != answering else {
            return
        }
        state.isSourceAnswering = answering
        upsert(state)
        OtosLog.catalog.noticeOperation("catalog.source.answering", phase: "changed", fields: [
            "rootPath": path.rawValue, "answering": "\(answering)",
        ])
        if !answering {
            await releaseEnrichmentClaimsForRoot(state.rowID)
        }
        notifyCatalogChanged(.changed(.membership))
    }

    func enrichableRootPaths() -> Set<LibraryRootPath> {
        Set(roots.values.filter(\.isEnrichable).map(\.path))
    }

    func resumeRemovableSource(identity: DeviceIdentity) async throws {
        try await ensureStartedForMutation()
        guard let root = rootForDeviceIdentity(identity),
              root.kind.isRemovable
        else {
            return
        }
        setAvailability(.available, for: root.path)
        if roots[root.path]?.isQuiesced == true {
            changeEnrichability(of: root.path) { $0.isQuiesced = false }
        }
        // The quiesce cancelled any scan reading the card, and rows that scan had not
        // reached are still awaiting presence; a card that stays mounted is read again.
        if root.kind.hasFilesystemNamespace {
            enqueueScans([root.path], priority: .front, reason: .removable)
        }
        OtosLog.catalog.notice(
            "op=catalog.removable.resume phase=finish identity=\(identity, privacy: .public) rootPath=\(root.path.rawValue, privacy: .public) kind=\(root.kind.rawValue, privacy: .public)"
        )
    }

    func beginSourceListing(rootPath: LibraryRootPath) async throws -> ActiveScan {
        guard roots[rootPath]?.root.kind.rowsComeFromSourceListing == true,
              roots[rootPath]?.availability == .available,
              let rootRowID = roots[rootPath]?.rowID
        else {
            throw CancellationError()
        }
        let scan = scanLeases.makeActiveScan(
            rootPath: rootPath,
            rootRowID: rootRowID,
            startNamespaceMutationEpoch: roots[rootPath]?.namespaceMutationEpoch ?? 0
        )
        scanLeases.beginListingScan(scan)
        if var state = roots[rootPath] {
            state.activity = .enumerating
            upsert(state)
        }
        // The root's own state moved (its order, a scan or listing starting or ending);
        // no row did, and the rows a scan changed or deleted were announced with them.
        notifyCatalogChanged(.changed(.membership, rows: .none))
        return scan
    }

    func recordSourceListingBatch(_ batch: [ScannedMediaFile], scan: ActiveScan) async throws {
        try await ensureStartedForMutation()
        guard owns(scan),
              roots[scan.rootPath]?.root.kind.rowsComeFromSourceListing == true,
              roots[scan.rootPath]?.availability == .available
        else {
            throw CancellationError()
        }
        let dbQueue = try database()
        let scanCapabilities = roots[scan.rootPath]?.capabilities ?? .unknown
        let timed = try await timedWrite(dbQueue) { db in
            var rows = CatalogRowChanges()
            for file in batch {
                try rows.record(Self.upsertScannedFile(
                    file,
                    libraryRootPath: scan.rootPath,
                    libraryRootID: scan.rootRowID,
                    capabilities: scanCapabilities,
                    db: db
                ), of: MediaAssetID(libraryRootPath: scan.rootPath, relativePath: file.relativePath))
            }
            return rows
        }
        guard owns(scan) else {
            throw CancellationError()
        }
        let announced = timed.value.notifications
        if !announced.isEmpty {
            // A device batch that actually changed rows is a real import-occupancy
            // change — same rule as the fixed/removable scan path (D2, D1: a plan
            // built from persisted rows before this fires is stale, and never
            // reprocessed without this bump).
            bumpNamespaceRevision(for: scan.rootPath)
            announced.forEach(notifyCatalogChanged)
        }
        OtosLog.catalog.notice(
            "op=catalog.source.listing.batch phase=finish rootPath=\(scan.rootPath.rawValue, privacy: .public) count=\(batch.count, privacy: .public) inserted=\(timed.value.inserted, privacy: .public) updated=\(timed.value.updated, privacy: .public) waitMs=\(timed.waitMs, privacy: .public) execMs=\(timed.execMs, privacy: .public) resumeMs=\(timed.resumeMs, privacy: .public) priority=\(timed.priorityName, privacy: .public)"
        )
        await boundWAL(reason: "deviceListingBatch")
    }

    func completeSourceListing(
        scan: ActiveScan,
        observedPaths: Set<MediaRelativePath>,
        companions: [MediaCompanion] = []
    ) async throws {
        guard owns(scan),
              roots[scan.rootPath]?.root.kind.rowsComeFromSourceListing == true,
              roots[scan.rootPath]?.availability == .available
        else {
            throw CancellationError()
        }
        do {
            _ = try await reconcileMissingAssets(
                scan: scan,
                observedPaths: observedPaths
            )
            let dbQueue = try database()
            let scanCapabilities = roots[scan.rootPath]?.capabilities ?? .unknown
            _ = try await timedWrite(dbQueue) { db in
                var changed = 0
                for companion in companions {
                    let companionChanged = try Self.upsertCompanion(
                        companion,
                        libraryRootID: scan.rootRowID,
                        capabilities: scanCapabilities,
                        db: db
                    )
                    changed += companionChanged ? 1 : 0
                }
                changed += try Self.reconcileMissingCompanions(
                    libraryRootID: scan.rootRowID,
                    observedPaths: Set(companions.map(\.relativePath)),
                    capabilities: scanCapabilities,
                    db: db
                )
                return changed
            }
        } catch {
            OtosLog.catalog.error(
                "Device catalog reconciliation failed error=\(String(describing: error), privacy: .public)"
            )
            throw error
        }
        guard owns(scan) else {
            throw CancellationError()
        }
        // Always bump on completion, regardless of whether this run's reconciliation
        // changed any row: completion is the proof-of-stability signal the import
        // readiness gate depends on (ADR 0024) — a plan built while the device
        // was still enumerating must always be revalidated once enumeration proves
        // stable, even if it turns out nothing changed.
        bumpNamespaceRevision(for: scan.rootPath)
        await endSourceListing(scan: scan)
    }

    /// Applies one batch of a source's change stream under its listing lease, in one
    /// transaction (ADR 0046 §5): listed items are upserted, keeping a stored size the
    /// report does not carry; reported sizes update their item; a deleted item's rows and
    /// overlay are purged, as proof of deletion. Nothing unlisted is touched: an
    /// incremental report proves nothing about items it does not name. A full resync
    /// completes through `completeSourceListing`, which does.
    func applySourceListingChanges(_ changes: SourceListingChanges, scan: ActiveScan) async throws {
        try await ensureStartedForMutation()
        guard owns(scan),
              roots[scan.rootPath]?.root.kind.rowsComeFromSourceListing == true,
              roots[scan.rootPath]?.availability == .available
        else {
            throw CancellationError()
        }
        guard !changes.isEmpty else {
            return
        }
        let dbQueue = try database()
        let scanCapabilities = roots[scan.rootPath]?.capabilities ?? .unknown
        let rootRowID = scan.rootRowID
        let rootPath = scan.rootPath
        let derivedFolder = derivedFolder
        let timed = try await timedWrite(dbQueue) { db in
            let written = try Self.writeSourceListingChanges(
                changes, rootRowID: rootRowID, rootPath: rootPath, capabilities: scanCapabilities, db: db
            )
            return try (rows: written.rows, removal: derivedFolder?.unname(written.purgedImages, db: db) ?? .nothing)
        }
        // The rows are gone whether or not the scan is still this Store's: their files go too,
        // off the actor, once the write is applied and announced.
        guard owns(scan) else {
            await timed.value.removal.perform()
            throw CancellationError()
        }
        let announced = timed.value.rows.notifications
        if !announced.isEmpty {
            bumpNamespaceRevision(for: scan.rootPath)
            announced.forEach(notifyCatalogChanged)
        }
        await timed.value.removal.perform()
        OtosLog.catalog.noticeOperation("catalog.source.changes", phase: "finish", fields: [
            "rootPath": scan.rootPath.rawValue,
            "listed": "\(changes.listed.count)",
            "completeFolders": "\(changes.completeFolders.count)",
            "sizes": "\(changes.sizesBySourceItem.count)",
            "deleted": "\(changes.deletedSourceItems.count)",
            "inserted": "\(timed.value.rows.inserted)",
            "updated": "\(timed.value.rows.updated)",
            "waitMs": "\(timed.waitMs)",
            "execMs": "\(timed.execMs)",
        ])
        await boundWAL(reason: "sourceListingBatch")
    }

    /// The transaction of `applySourceListingChanges`: rows changed, and the derived
    /// images of purged rows, to delete once the transaction commits.
    private nonisolated static func writeSourceListingChanges(
        _ changes: SourceListingChanges,
        rootRowID: Int64,
        rootPath: LibraryRootPath,
        capabilities: VolumeNamespaceCapabilities,
        db: Database
    ) throws -> (rows: CatalogRowChanges, purgedImages: [String]) {
        var rows = CatalogRowChanges()
        // Every statement a listed item runs is cached: preparing a write on media_asset
        // compiles the upkeep of each of its indexes, and costs more than the write itself.
        for item in changes.listed {
            let file = try keepingStoredSize(item.file, libraryRootID: rootRowID, db: db)
            let upsert = try upsertScannedFile(
                file, libraryRootPath: rootPath, libraryRootID: rootRowID, capabilities: capabilities, db: db
            )
            let id = MediaAssetID(libraryRootPath: rootPath, relativePath: file.relativePath)
            rows.record(upsert, of: id)
            try db.cachedStatement(sql: AssetRowSQL.sourceHiddenSQL).execute(
                arguments: [item.isHiddenBySource]
                    + AssetKey(rootID: rootRowID, path: file.relativePath).arguments
                    + [item.isHiddenBySource]
            )
            // A new row's hide is part of the new row; an existing one's is a change to it.
            if upsert != .inserted {
                rows.recordChanged(db.changesCount, of: id, facts: .presence)
            }
            // The source's own facts of the row, none of them shown: its name for the item;
            // where it holds the item on its server, what a mirrored library file finds it by
            // (ADR 0054); and whether it has its own images of it, what the product pass asks
            // for and an empty search counts (`assetsWithNoThumbnailComing`). An existing row's
            // are announced as the kinds they are; a new row's are part of the new row. One
            // statement, one seek of the row: each statement a listed item runs is one more
            // seek for every item of every batch.
            try db.cachedStatement(sql: AssetRowSQL.sourceItemFactsSQL).execute(
                arguments: [item.sourceItemID, item.sourcePathChecksum?.data, !item.sourceHasProducts]
                    + AssetKey(rootID: rootRowID, path: file.relativePath).arguments
                    + [item.sourceItemID, item.sourcePathChecksum?.data, !item.sourceHasProducts]
            )
            if upsert != .inserted {
                rows.recordChanged(db.changesCount, of: id, facts: [.membership, .copies, .images, .detail])
            }
            // The source's digest of the item's bytes is the row's (ADR 0054), stamped with
            // the facts this listing wrote: the source lists the item again when its bytes
            // change. Which copy shows can move with it, so an existing row's is a change, and
            // a new row's is when it makes the row a copy of one the catalog holds (a library
            // file this asset was uploaded from): Duplicates and People read that.
            if let digest = item.sourceDigest {
                try db.cachedStatement(sql: AssetRowSQL.sourceDigestSQL).execute(
                    arguments: [digest.data]
                        + AssetKey(rootID: rootRowID, path: file.relativePath).arguments
                        + [digest.data]
                )
                if upsert != .inserted {
                    // Its digest, and which files are copies and the choice a copy takes,
                    // which the copy-key triggers rewrite with it.
                    rows.recordChanged(
                        db.changesCount, of: id,
                        facts: .digests(copiesChanged: true, digestsChanged: true, choicesJoined: true)
                    )
                } else if db.changesCount > 0,
                          let after = try DigestStanding.read(libraryRootID: rootRowID, relativePath: file.relativePath.rawValue, db: db)
                {
                    let facts = CatalogChangedFacts.digests(from: [(.absent, after)], choicesJoined: false)
                    rows.recordInserted(id, carrying: facts.contains(.copies) ? facts : [])
                }
            }
        }
        for (item, size) in changes.sizesBySourceItem {
            try db.cachedStatement(sql: AssetRowSQL.writeSourceByteSizeSQL).execute(
                arguments: [size, rootRowID, item, size]
            )
            // A size is which rows exist as they are, and a copy-key input.
            rows.recordUnnamedUpdates(db.changesCount, facts: [.membership, .copies, .choices, .detail])
            // A digest the source stated before it reported the size was stamped with no
            // size (-1); the size it reports now is of the same bytes.
            try db.cachedStatement(sql: AssetEnrichmentSQL.restampDigestSizeSQL).execute(
                arguments: [rootRowID, item]
            )
            rows.recordUnnamedUpdates(db.changesCount, facts: .digests(copiesChanged: true, digestsChanged: true, choicesJoined: true))
        }
        var purged: [ExistingAssetRow] = []
        let listedPaths = Set(changes.listed.map(\.file.relativePath))
        for folder in changes.completeFolders {
            purged += try fetchExistingAssetRows(
                libraryRootID: rootRowID, underSubtree: MediaRelativePath(rawValue: folder), db: db
            ).filter { !listedPaths.contains($0.relativePath) }
        }
        for item in changes.deletedSourceItems {
            let named = try String.fetchAll(
                db,
                sql: AssetRowSQL.pathOfSourceItemSQL,
                arguments: [rootRowID, item]
            )
            for path in [item] + named {
                purged += try fetchExistingAssetRows(
                    libraryRootID: rootRowID, underSubtree: MediaRelativePath(rawValue: path), db: db
                )
            }
        }
        var purgedImages: [String] = []
        var purgedPaths: Set<MediaRelativePath> = []
        for row in purged where purgedPaths.insert(row.relativePath).inserted {
            purgedImages += row.derivedImagePaths
            try rows.recordDeleted(
                deleteAssetRow(rootRowID: rootRowID, relativePath: row.relativePath, db: db),
                of: row.relativePath, in: rootPath
            )
        }
        return (rows, purgedImages)
    }

    /// When the source at `rootPath` last listed in full (an Immich account's last complete
    /// pass, ADR 0046 §6); nil when it never has, or when the root is gone.
    func sourceLastSynced(rootPath: LibraryRootPath, lane: CatalogReadLane) async throws -> Date? {
        guard let rootID = roots.rowIDSnapshot()[rootPath] else {
            return nil
        }
        return try await reader(for: lane).readFreeingConnection { db in
            try Double.fetchOne(
                db, sql: LibraryRootSQL.lastSyncedAtSQL, arguments: [rootID]
            ).map(Date.init(timeIntervalSince1970:))
        }
    }

    /// Records that the source at `rootPath` listed in full at `date`.
    func recordSourceSynced(at date: Date, rootPath: LibraryRootPath) async throws {
        guard let rootID = roots.rowIDSnapshot()[rootPath] else {
            return
        }
        try await database().write { db in
            try db.execute(
                sql: LibraryRootSQL.setLastSyncedAtSQL,
                arguments: [date.timeIntervalSince1970, rootID]
            )
        }
    }

    /// The full resync a source owes: its server reset the cursor, or a new session began,
    /// and no pass has read the stream from zero to its end since (ADR 0046 §5). Nil when
    /// none is owed, or for a root the catalog does not hold.
    func sourceResyncOwed(rootPath: LibraryRootPath, lane: CatalogReadLane) async throws -> SourceResyncDebt? {
        guard let rootID = roots.rowIDSnapshot()[rootPath] else {
            return nil
        }
        let revision = try await reader(for: lane).readFreeingConnection { db in
            try Int64.fetchOne(db, sql: LibraryRootSQL.resyncOwedSQL, arguments: [rootID])
        }
        return revision.flatMap { $0 > 0 ? SourceResyncDebt(revision: $0) : nil }
    }

    /// Records that a source owes a full resync, as a request newer than any before it, so a
    /// resync already running settles only the debt it started from. Nil for a root the
    /// catalog does not hold.
    @discardableResult
    func requestSourceResync(rootPath: LibraryRootPath) async throws -> SourceResyncDebt? {
        guard let rootID = roots.rowIDSnapshot()[rootPath] else {
            return nil
        }
        let revision = try await database().write { db in
            try db.execute(sql: LibraryRootSQL.oweResyncSQL, arguments: [rootID])
            return try Int64.fetchOne(db, sql: LibraryRootSQL.resyncOwedSQL, arguments: [rootID])
        }
        OtosLog.catalog.noticeOperation("catalog.source.resync", phase: "requested", fields: [
            "rootPath": rootPath.rawValue, "revision": revision.map { "\($0)" } ?? "none",
        ])
        return revision.map(SourceResyncDebt.init(revision:))
    }

    /// Ends a source's full resync: a listing read from zero to its end under `scan`, which
    /// proves every row it did not observe deleted (ADR 0046 §1, §5). One transaction purges
    /// those rows with their overlay and settles `debt` when it is still the newest request,
    /// so the purge and the settling never part: neither a crash nor a failed write between
    /// them leaves the debt settled with rows unpurged, or the reverse.
    func completeSourceResync(
        scan: ActiveScan,
        observedPaths: Set<MediaRelativePath>,
        settling debt: SourceResyncDebt
    ) async throws {
        try await ensureStartedForMutation()
        guard owns(scan),
              roots[scan.rootPath]?.root.kind.rowsComeFromSourceListing == true,
              roots[scan.rootPath]?.availability == .available,
              scanCanDelete(scan)
        else {
            throw CancellationError()
        }
        let capabilities = roots[scan.rootPath]?.capabilities ?? .unknown
        let rootRowID = scan.rootRowID
        let rootPath = scan.rootPath
        let observedKeys = Set(observedPaths.map {
            FilesystemNamespaceSemantics.nameKey(relativePath: $0, capabilities: capabilities)
        })
        let derivedFolder = derivedFolder
        let timed = try await timedWrite(database()) { db in
            let missing = try Self.fetchExistingAssetRows(libraryRootID: rootRowID, underSubtree: nil, db: db)
                .filter {
                    !observedKeys.contains(
                        FilesystemNamespaceSemantics.nameKey(relativePath: $0.relativePath, capabilities: capabilities)
                    )
                }
            var rows = CatalogRowChanges()
            for row in missing {
                try rows.recordDeleted(
                    Self.deleteAssetRow(rootRowID: rootRowID, relativePath: row.relativePath, db: db),
                    of: row.relativePath, in: rootPath
                )
            }
            try db.execute(
                sql: LibraryRootSQL.settleResyncSQL,
                arguments: [rootRowID, debt.revision]
            )
            let settled = db.changesCount > 0
            let removal = try derivedFolder?.unname(missing.flatMap(\.derivedImagePaths), db: db) ?? .nothing
            return (removal: removal, purged: missing.count, settled: settled, rows: rows)
        }
        guard owns(scan) else {
            await timed.value.removal.perform()
            throw CancellationError()
        }
        OtosLog.catalog.noticeOperation("catalog.source.resync", phase: "complete", fields: [
            "rootPath": scan.rootPath.rawValue,
            "observed": "\(observedPaths.count)",
            "purged": "\(timed.value.purged)",
            "revision": "\(debt.revision)",
            "settled": "\(timed.value.settled)",
            "waitMs": "\(timed.waitMs)",
            "execMs": "\(timed.execMs)",
        ])
        bumpNamespaceRevision(for: scan.rootPath)
        // The rows the resync purged, and the Live Photo partners they leave.
        timed.value.rows.notifications.forEach(notifyCatalogChanged)
        // The purged rows' files go off the actor, after the purge is announced and while
        // the scan still holds the root.
        await timed.value.removal.perform()
        await endSourceListing(scan: scan)
    }

    /// Records that the source answered it holds no images of these rows (ADR 0046 §7), so
    /// no product pass asks for them again until a later listing says it has them. A row
    /// that holds no thumbnail then gets none coming, which an empty search counts
    /// (`assetsWithNoThumbnailComing`), so the rows it marks are announced as their images.
    func recordSourceProductsAbsent(_ paths: [MediaRelativePath], rootPath: LibraryRootPath) async throws {
        guard !paths.isEmpty, let rootID = roots.rowIDSnapshot()[rootPath] else {
            return
        }
        let marked = try await database().write { db -> Set<MediaAssetID> in
            var marked: Set<MediaAssetID> = []
            for path in paths {
                try db.execute(
                    sql: AssetEnrichmentSQL.sourceProductsAbsentSQL,
                    arguments: AssetKey(rootID: rootID, path: path).arguments
                )
                if db.changesCount > 0 {
                    marked.insert(MediaAssetID(libraryRootPath: rootPath, relativePath: path))
                }
            }
            return marked
        }
        if !marked.isEmpty {
            notifyCatalogChanged(.changed([.images, .detail], rows: .rows(marked)))
        }
    }

    /// The source's own ID for the item `id` is (ADR 0046 §2), which a request for its
    /// bytes names; nil for a row the source never listed.
    func sourceItemID(for id: MediaAssetID, lane: CatalogReadLane) async throws -> String? {
        guard let rootID = roots.rowIDSnapshot()[id.libraryRootPath] else {
            return nil
        }
        return try await reader(for: lane).readFreeingConnection { db in
            try String.fetchOne(
                db,
                sql: AssetRowSQL.sourceItemIDSQL,
                arguments: AssetKey(rootID: rootID, path: id.relativePath).arguments
            )
        }
    }

    /// The rows of `rootPath` named by each of `sourceItemIDs`, by that ID: where an item
    /// a source reports apart from its folder's own line already lives, and whether its
    /// source hides it.
    func sourceItemRows(
        _ sourceItemIDs: Set<String>,
        in rootPath: LibraryRootPath,
        lane: CatalogReadLane
    ) async throws -> [String: SourceItemRow] {
        guard let rootID = roots.rowIDSnapshot()[rootPath], !sourceItemIDs.isEmpty else {
            return [:]
        }
        let ids = sourceItemIDs.sorted()
        return try await reader(for: lane).readFreeingConnection { db in
            var rows: [String: SourceItemRow] = [:]
            for row in try Row.fetchAll(
                db,
                sql: AssetRowSQL.rowsOfSourceItemsSQL(count: ids.count),
                arguments: StatementArguments([rootID] as [any DatabaseValueConvertible] + ids)
            ) {
                rows[row["source_item_id"]] = SourceItemRow(
                    relativePath: MediaRelativePath(rawValue: row["relative_path"]),
                    isHiddenBySource: row["hidden_by_source"]
                )
            }
            return rows
        }
    }

    /// Rows of `rootPath` owed their source's own thumbnail and preview: visible, sized,
    /// showing the source's images (never edited, not yet rendered by Otos), and with no
    /// source products or older ones than the file (ADR 0046 §7). In path order after `cursor`,
    /// so a caller pages through them, from the partial index of exactly those rows
    /// (`SourceProductsSQL`): an account whose images are current reads none.
    func sourceProductCandidates(
        rootPath: LibraryRootPath,
        after cursor: MediaRelativePath?,
        limit: Int,
        lane: CatalogReadLane
    ) async throws -> [SourceProductCandidate] {
        guard let rootID = roots.rowIDSnapshot()[rootPath] else {
            return []
        }
        return try await reader(for: lane).readFreeingConnection { db in
            try Row.fetchAll(
                db,
                sql: SourceProductsSQL.candidatesSQL,
                arguments: [rootID, cursor?.rawValue ?? "", limit]
            ).map { row in
                let kind: String? = row["kind"]
                return SourceProductCandidate(
                    id: MediaAssetID(
                        libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: row["relative_path"])
                    ),
                    sourceItemID: row["source_item_id"],
                    kind: kind.flatMap(MediaKind.init(rawValue:)),
                    byteSize: row["byte_size"],
                    contentModifiedAtSeconds: row["mtime"]
                )
            }
        }
    }

    /// Of `ids`, the rows of `rootPath` owed their source's own images, by key: what the rows
    /// on screen ask for ahead of the walk. Empty for a root the Store does not hold.
    func sourceProductCandidates(
        rootPath: LibraryRootPath,
        among ids: [MediaAssetID],
        lane: CatalogReadLane
    ) async throws -> [SourceProductCandidate] {
        let paths = ids.filter { $0.libraryRootPath == rootPath }.map(\.relativePath.rawValue)
        guard let rootID = roots.rowIDSnapshot()[rootPath], !paths.isEmpty else {
            return []
        }
        let statementArguments: StatementArguments = [rootID] + StatementArguments(paths)
        let sql = SourceProductsSQL.visibleCandidatesSQL(count: paths.count)
        return try await reader(for: lane).readFreeingConnection { db in
            try Row.fetchAll(db, sql: sql, arguments: statementArguments).map { row in
                let kind: String? = row["kind"]
                return SourceProductCandidate(
                    id: MediaAssetID(
                        libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: row["relative_path"])
                    ),
                    sourceItemID: row["source_item_id"],
                    kind: kind.flatMap(MediaKind.init(rawValue:)),
                    byteSize: row["byte_size"],
                    contentModifiedAtSeconds: row["mtime"]
                )
            }
        }
    }

    /// `file` with the size its row already holds when the report carries none.
    private nonisolated static func keepingStoredSize(
        _ file: ScannedMediaFile,
        libraryRootID: Int64,
        db: Database
    ) throws -> ScannedMediaFile {
        guard file.byteSize == nil,
              let stored = try Int64.fetchOne(
                  db.cachedStatement(sql: AssetRowSQL.storedByteSizeSQL),
                  arguments: AssetKey(rootID: libraryRootID, path: file.relativePath).arguments
              )
        else {
            return file
        }
        return ScannedMediaFile(
            relativePath: file.relativePath,
            name: file.name,
            contentTypeIdentifier: file.contentTypeIdentifier,
            byteSize: stored,
            createdAt: file.createdAt,
            contentModifiedAt: file.contentModifiedAt,
            kind: file.kind,
            format: file.format,
            fileIdentifier: file.fileIdentifier
        )
    }

    func endSourceListing(scan: ActiveScan) async {
        guard scanLeases.isCurrentListingScan(scan) else {
            return
        }
        scanLeases.endListingScan(scan)
        if var state = roots[scan.rootPath], state.root.kind.rowsComeFromSourceListing {
            state.activity = .idle
            upsert(state)
            // The root's own state moved (its order, a scan or listing starting or ending);
            // no row did, and the rows a scan changed or deleted were announced with them.
            notifyCatalogChanged(.changed(.membership, rows: .none))
        }
        // A completed enumeration has already deleted what it never saw; one that ended
        // without completing leaves its unseen rows to be shown as last held. Only a removable
        // source's rows wait for an attachment to see them (`markRetainedRowsAwaitingPresence`),
        // so an account's listing has none to release, and writes nothing.
        if roots[scan.rootPath]?.rowID == scan.rootRowID, roots[scan.rootPath]?.root.kind.isRemovable == true {
            await releaseAwaitingPresence(of: scan.rootPath, rootRowID: scan.rootRowID, reason: "enumerationEnded")
        }
    }

    /// A camera's own thumbnails, staged: each is promoted and named in one write, and only
    /// for a row that has no thumbnail yet, so it never replaces one Otos rendered and never
    /// lands in the derived folder without a row that names it. What is not taken is
    /// discarded from staging.
    func applyProvisionalThumbnails(_ stagedByID: [MediaAssetID: StagedDerivedImage]) async throws {
        guard !stagedByID.isEmpty else {
            return
        }
        guard let derivedFolder else {
            return
        }
        let thumbnailDirectory = derivedFolder.directory
        let rootIDsByPathBeforeWrite = roots.rowIDSnapshot()
        let dbQueue = try database()
        let taken: Set<MediaAssetID>
        do {
            taken = try await timedWrite(dbQueue) { db in
                var taken = Set<MediaAssetID>()
                for (id, staged) in stagedByID {
                    guard let rootID = rootIDsByPathBeforeWrite[id.libraryRootPath],
                          try Self.lacksThumbnail(libraryRootID: rootID, relativePath: id.relativePath, db: db)
                    else {
                        continue
                    }
                    try derivedFolder.promote(staged, db: db)
                    try Self.updateThumbnailPath(
                        staged.finalRelativePath,
                        libraryRootID: rootID,
                        relativePath: id.relativePath,
                        onlyWhenMissing: true,
                        db: db
                    )
                    taken.insert(id)
                }
                return taken
            }.value
        } catch {
            for staged in stagedByID.values {
                ThumbnailStore.discard(staged, in: thumbnailDirectory)
            }
            throw error
        }
        for (id, staged) in stagedByID where !taken.contains(id) {
            ThumbnailStore.discard(staged, in: thumbnailDirectory)
        }
        if !taken.isEmpty {
            notifyCatalogChanged(.changed([.images, .detail], rows: .rows(taken)))
        }
    }

    func shutdown() {
        // The coverage guard waits for the Store's own work this cancels: what it wrote before
        // the shutdown overtook it is announced as that work ends.
        changeAudit?.shutDown(
            [reconcileLoop, filesystemEventConsumer, integrityScanTask].compactMap(\.self)
                + Array(scanTasks.values) + Array(filesystemEventPasses.values)
        )
        reconcileDoorbell?.finish()
        reconcileDoorbell = nil
        reconcileLoop?.cancel()
        reconcileLoop = nil
        reconcileCovered = reconcileRequested
        reconcilePassRunning = false
        deferredLibraryRemovals.removeAll()
        for (path, lease) in handedOffLibraryRemovals
            where namespaceMutationLeases[path]?.generation == lease.generation
        {
            namespaceMutationLeases.removeValue(forKey: path)
        }
        handedOffLibraryRemovals.removeAll()
        // A mutation waiting for a lease goes on and finds the Store shut down.
        let waiting = namespaceLeaseReleaseWaiters.values.flatMap(\.self)
        namespaceLeaseReleaseWaiters.removeAll()
        waiting.forEach { $0.resume() }
        for task in scanTasks.values {
            task.cancel()
        }
        scanTasks.removeAll()
        integrityScanTask?.cancel()
        integrityScanTask = nil
        scanLeases.resetAll()
        cancelAllFilesystemEventPasses()
        filesystemDirty.removeAll()
        lastSuccessfulFullRootScanAt.removeAll()
        knownMaterializationSuppression.clear()
        filesystemWatcher.stop()
        watchedRoots.removeAll()
        changeJournals.removeAll()
        loadedJournalPositions.removeAll()
        pendingScanReasons.removeAll()
        runningScanReasons.removeAll()
        filesystemEventSink?.finish()
        filesystemEventSink = nil
        filesystemEventConsumer?.cancel()
        filesystemEventConsumer = nil
        filesystemWatchingStarted = false
        filesystemWatchingArmed.removeAll()
        // This change follows no write: the roots' own state moved, every scan and watch
        // ended, and no row changed. The coverage guard heard the shutdown, and does not hear
        // this as a change announcing a write (`CatalogWriteAudit.shutDown`).
        deliver(.changed(.membership, rows: .none))
    }
}

extension CatalogStore {
    /// Where thumbnail files live, derived from the catalog location: beside the
    /// catalog in Application Support, or beside an explicit database file. In-memory
    /// catalogs have no thumbnail directory (nothing to purge).
    ///
    /// `nonisolated` because it reads only the immutable `location`: the ViewModel needs
    /// it synchronously to build the enricher, and tiles need it to resolve thumbnails.
    /// It lives in an internal (not `private`) extension so those owners can read it.
    nonisolated var thumbnailDirectory: URL? {
        Self.thumbnailDirectory(for: location)
    }

    nonisolated static func thumbnailDirectory(for location: Location) -> URL? {
        switch location {
        case let .application(bundleIdentifier):
            Self.applicationThumbnailDirectory(bundleIdentifier: bundleIdentifier)
        case let .databaseFile(url):
            url.deletingLastPathComponent().appending(path: "Thumbnails", directoryHint: .isDirectory)
        case .inMemory:
            nil
        }
    }

    /// Where the search index keeps its vector file (ADR 0048): beside the thumbnails in
    /// Application Support, or beside an explicit database file. An in-memory catalog has
    /// none. Derived overlay, never in a media folder.
    nonisolated var searchIndexDirectory: URL? {
        switch location {
        case let .application(bundleIdentifier):
            URL.applicationSupportDirectory
                .appending(path: bundleIdentifier, directoryHint: .isDirectory)
                .appending(path: "SearchIndex", directoryHint: .isDirectory)
        case let .databaseFile(url):
            url.deletingLastPathComponent().appending(path: "SearchIndex", directoryHint: .isDirectory)
        case .inMemory:
            nil
        }
    }

    /// The staging containers a catalog at `location` owns when none is given.
    nonisolated static func stagingContainers(for location: Location) -> StagingContainers {
        switch location {
        case let .application(bundleIdentifier):
            .application(bundleIdentifier: bundleIdentifier)
        case let .databaseFile(url):
            StagingContainers(base: url.deletingLastPathComponent().appending(path: "Staging", directoryHint: .isDirectory))
        case .inMemory:
            StagingContainers(base: URL.temporaryDirectory.appending(path: "OtosStaging-\(UUID().uuidString)", directoryHint: .isDirectory))
        }
    }

    /// Where hand-offs put the full-size files they render (ADR 0037): beside
    /// the thumbnails in Application Support, never in a media folder. Its contents last
    /// until the next launch clears them. An in-memory catalog uses the temporary folder.
    nonisolated var handOffDirectory: URL {
        switch location {
        case let .application(bundleIdentifier):
            URL.applicationSupportDirectory
                .appending(path: bundleIdentifier, directoryHint: .isDirectory)
                .appending(path: "HandOff", directoryHint: .isDirectory)
        case let .databaseFile(url):
            url.deletingLastPathComponent().appending(path: "HandOff", directoryHint: .isDirectory)
        case .inMemory:
            URL.temporaryDirectory.appending(path: "OtosHandOff", directoryHint: .isDirectory)
        }
    }

    /// Holds one of the pool's readers on its snapshot, in `lane`, until `hold` returns, as a
    /// long read does (a People snapshot, a duplicates build): what a test stands one in with,
    /// to show what such a read holds up and what it does not (ARC-063, ADR 0002).
    func holdRead(_ hold: @escaping @Sendable () -> Void, lane: CatalogReadLane) async throws {
        try await reader(for: lane).readFreeingConnection { db in
            _ = try Int.fetchOne(db, sql: LibraryRootSQL.countSQL)
            hold()
        }
    }

    /// What a launch's look at the derived folder found (`reconcileDerivedFilesIfOwed`).
    enum DerivedFolderOutcome: Equatable, Sendable {
        /// Nothing said leftovers could exist: the stored counters, read without a listing.
        case counted(DerivedFileReconciliation.Census)
        /// A reconciliation ran: why, the census it took after its deletes, and what it removed.
        case reconciled(reason: String, census: DerivedFileReconciliation.Census, removed: DerivedFileReconciliation.Census)
    }

    /// Moves to their new names, a page at a time, the files a root's rename journaled
    /// (`DerivedFolder.journalRenames`). The moves run off the Store and outside the writer;
    /// each page's journal rows and counter change are one short write after it. A root's
    /// rename journals two or three names per row it holds, so a card of 4,000 photos is about
    /// 8,000 renames in sixteen pages; no page holds the writer for more than its row deletes.
    func applyPendingDerivedRenames(lane: CatalogReadLane) async throws {
        guard let derivedFolder else {
            return
        }
        let dbWriter = try database()
        let laneReader = try reader(for: lane)
        let pageSize = Self.derivedRenamePageSize
        var moved = 0
        var failures = 0
        while true {
            let page = try await laneReader.readFreeingConnection { db in
                try DerivedFileReconciliation.pendingRenames(limit: pageSize, db: db)
            }
            guard !page.isEmpty else {
                break
            }
            let result = await Self.moveDerivedFiles(page, in: derivedFolder)
            do {
                try await timedWrite(dbWriter, operation: "applyPendingDerivedRenames") { db in
                    for move in page {
                        try db.execute(sql: AssetEnrichmentSQL.deleteDerivedRenameSQL, arguments: [move.old, move.new])
                    }
                    try DerivedFolderCounters.apply(result.change, db: db)
                }
            } catch {
                derivedFolder.endOutsideWrite(failed: true)
                throw error
            }
            derivedFolder.endOutsideWrite(failed: result.failures > 0)
            moved += page.count
            failures += result.failures
        }
        if moved > 0 {
            OtosLog.thumbnails.noticeOperation("derived.rename", phase: "finish", fields: [
                "moved": "\(moved)", "failures": "\(failures)",
            ])
        }
    }

    /// Journaled moves per page: each page's renames run outside the writer.
    static let derivedRenamePageSize = 500

    @concurrent
    private nonisolated static func moveDerivedFiles(
        _ moves: [(old: String, new: String)],
        in folder: DerivedFolder
    ) async -> (change: DerivedFileReconciliation.Census, failures: Int) {
        folder.moveJournaled(moves)
    }

    /// The derived folder's stored counters, or nil while they are unknown.
    func derivedFolderCounters(lane: CatalogReadLane) async throws -> DerivedFileReconciliation.Census? {
        try await reader(for: lane).readFreeingConnection { db in
            try DerivedFolderCounters.read(db: db)
        }?.normalized
    }

    /// Rows per page of the protected-names read, and files per page of the folder stream and
    /// of each delete batch: each page is one short read or write.
    static let derivedReconcilePageSize = 2000

    /// Reconciles the derived folder when a fact says leftovers can exist — the previous
    /// session ended without closing (`DerivedFolder.openSession`), or the counters are
    /// unknown — and otherwise only reads the stored counters. Logs the folder's files and
    /// bytes by kind either way (`op=derived.folder phase=counted`). Nil for a catalog without
    /// a derived folder. The window runs it once a launch, as an admitted load.
    @discardableResult
    func reconcileDerivedFilesIfOwed(lane: CatalogReadLane) async throws -> DerivedFolderOutcome? {
        guard let derivedFolder else {
            return nil
        }
        let dbWriter = try database()
        let laneReader = try reader(for: lane)
        let stored = try await laneReader.readFreeingConnection { db in
            try DerivedFolderCounters.read(db: db)
        }
        let reason: String? = if derivedFolder.previousSessionUnclean {
            "uncleanExit"
        } else if stored == nil {
            "countersUnknown"
        } else {
            nil
        }
        guard let reason else {
            let counted = (stored ?? DerivedFileReconciliation.Census()).normalized
            OtosLog.thumbnails.noticeOperation("derived.folder", phase: "counted", fields: counted.fields.merging([
                "source": "counters",
            ]) { $1 })
            return .counted(counted)
        }
        return try await reconcileDerivedFiles(
            reason: reason, stored: stored, folder: derivedFolder, laneReader: laneReader, dbWriter: dbWriter
        )
    }

    private func reconcileDerivedFiles(
        reason: String,
        stored: DerivedFileReconciliation.Census?,
        folder: DerivedFolder,
        laneReader: CatalogLaneReader,
        dbWriter: CatalogWriter
    ) async throws -> DerivedFolderOutcome {
        let start = ContinuousClock.now
        let pageSize = Self.derivedReconcilePageSize
        folder.startNoting()
        defer { folder.stopNoting() }
        // 1. The protected names, a page of rows at a time.
        var protected = DerivedFileReconciliation.ProtectedNames()
        var after: Int64 = 0
        var rows = 0
        while true {
            let from = after
            let page = try await laneReader.readFreeingConnection { db in
                try DerivedFileReconciliation.namedRows(after: from, limit: pageSize, db: db)
            }
            guard let last = page.last else {
                break
            }
            for row in page {
                protected.insert(identity: row.id)
                row.names.forEach { protected.insert(name: $0) }
            }
            rows += page.count
            after = last.rowID
        }
        // A rename's journaled moves not yet done: both names stay until the move is.
        let pending = try await laneReader.readFreeingConnection { db in
            try DerivedFileReconciliation.pendingRenames(limit: Int.max, db: db)
        }
        for move in pending {
            protected.insert(name: move.old)
            protected.insert(name: move.new)
        }
        // 2. The folder as a stream; its unprotected files are deleted a page at a time, each
        // in one short write that leaves out every name written since noting began.
        let listed = try await Self.streamDerivedFolder(folder.directory, protected: protected, pageSize: pageSize)
        var removed = DerivedFileReconciliation.Census()
        for page in listed.candidatePages {
            let gone = try await timedWrite(dbWriter, operation: "reconcileDerivedFiles") { _ in
                let noted = folder.noted()
                return DerivedFileReconciliation.delete(page.filter { !noted.contains($0.name) }, in: folder.directory)
            }.value
            gone.forEach { removed.add($0) }
        }
        // 3. The counters take the census, less what went.
        var census = listed.census
        census.add(removed.negated)
        let counted = census.normalized
        try await timedWrite(dbWriter, operation: "reconcileDerivedFiles") { db in
            try DerivedFolderCounters.replace(with: counted, db: db)
        }
        let diagnostics = DerivedFileReconciliation.removeRetiredDiagnostics(besides: folder.directory)
        var fields = removed.normalized.fields(prefix: "removed")
        fields.merge(counted.fields) { $1 }
        if let stored {
            var drift = counted
            drift.add(stored.negated)
            fields.merge(drift.normalized.fields(prefix: "drift")) { $1 }
        } else {
            fields["drift"] = "unknown"
        }
        fields.merge([
            "reason": reason,
            "rows": "\(rows)",
            "protected": "\(protected.count)",
            "retiredDiagnosticsFiles": "\(diagnostics.files)",
            "retiredDiagnosticsBytes": "\(diagnostics.bytes)",
            "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
        ]) { $1 }
        OtosLog.thumbnails.noticeOperation("derived.reconcile", phase: "finish", fields: fields)
        OtosLog.thumbnails.noticeOperation("derived.folder", phase: "counted", fields: counted.fields.merging([
            "source": "census",
        ]) { $1 })
        return .reconciled(reason: reason, census: counted, removed: removed.normalized)
    }

    /// Streams the derived folder off the Store actor: its census, and its unprotected files
    /// in pages. Only names and sizes are kept, never a URL or a resource cache.
    @concurrent
    private nonisolated static func streamDerivedFolder(
        _ directory: URL,
        protected: DerivedFileReconciliation.ProtectedNames,
        pageSize: Int
    ) async throws -> (census: DerivedFileReconciliation.Census, candidatePages: [[DerivedFileReconciliation.Entry]]) {
        var census = DerivedFileReconciliation.Census()
        var pages: [[DerivedFileReconciliation.Entry]] = []
        var candidates: [DerivedFileReconciliation.Entry] = []
        try DerivedFileReconciliation.stream(directory, pageSize: pageSize) { page in
            for entry in page {
                census.add(entry)
                guard !protected.protects(entry.name) else {
                    continue
                }
                candidates.append(entry)
                if candidates.count == pageSize {
                    pages.append(candidates)
                    candidates = []
                }
            }
        }
        if !candidates.isEmpty {
            pages.append(candidates)
        }
        return (census, pages)
    }
}

private extension CatalogStore {
    /// The connections a read of `lane` uses (`CatalogReadLanes`): the one pool, entered at
    /// once by a window read and through the background admission by a background read. The
    /// only way a Store read reaches a connection, apart from the open's own reads.
    func reader(for lane: CatalogReadLane) throws -> CatalogLaneReader {
        try CatalogLaneReader(pool: database().reader, lane: lane, admission: readAdmission)
    }

    /// `operation` names the read for a stall line (`CatalogConnectionActivity`); `askedAt`
    /// is when its caller asked, before it reached the Store.
    private func timedRead<Value: Sendable>(
        _ laneReader: CatalogLaneReader,
        operation: String = #function,
        askedAt: ContinuousClock.Instant = .now,
        _ body: @Sendable @escaping (Database) throws -> Value
    ) async throws -> DatabaseTimedValue<Value> {
        let priority = Task.currentPriority
        let start = ContinuousClock.now
        let (timed, left) = try await laneReader.readFreeingConnection(operation: operation, askedAt: askedAt) { db in
            let entered = ContinuousClock.now
            let lockMs = ConnectionLockWait.takeWaitMs(from: db, askedAt: start)
            let value = try body(db)
            let left = ContinuousClock.now
            return (
                DatabaseTimedValue(
                    value: value,
                    waitMs: DiagnosticsTiming.milliseconds(from: start, to: entered),
                    execMs: DiagnosticsTiming.milliseconds(from: entered, to: left),
                    lockMs: lockMs,
                    priority: priority
                ),
                left
            )
        }
        var resumed = timed
        resumed.resumeMs = DiagnosticsTiming.milliseconds(since: left)
        return resumed
    }

    /// `operation` names the write on the writer's connection for a stall line
    /// (`CatalogConnectionActivity`).
    private func timedWrite<Value: Sendable>(
        _ dbWriter: CatalogWriter,
        operation: String = #function,
        _ body: @Sendable @escaping (Database) throws -> Value
    ) async throws -> DatabaseTimedValue<Value> {
        let priority = Task.currentPriority
        let start = ContinuousClock.now
        let (timed, left) = try await dbWriter.write(operation: operation) { db in
            let entered = ContinuousClock.now
            let value = try body(db)
            let left = ContinuousClock.now
            return (
                DatabaseTimedValue(
                    value: value,
                    waitMs: DiagnosticsTiming.milliseconds(from: start, to: entered),
                    execMs: DiagnosticsTiming.milliseconds(from: entered, to: left),
                    priority: priority
                ),
                left
            )
        }
        var resumed = timed
        resumed.resumeMs = DiagnosticsTiming.milliseconds(since: left)
        if resumed.waitMs >= Self.writeWaitLogThresholdMs {
            OtosLog.catalog.noticeOperation("catalog.store.writeWait", phase: "waited", fields: [
                "operation": CatalogConnectionActivity.shortName(operation),
                "waitMs": "\(resumed.waitMs)",
                "execMs": "\(resumed.execMs)",
                "priority": resumed.priorityName,
            ])
        }
        return resumed
    }

    /// A named write that waited this long for the writer says so (`op=catalog.store.writeWait`).
    /// time: measurement — a threshold on a wait already measured; nothing waits on it.
    static let writeWaitLogThresholdMs = 100

    private func ensureStartedForMutation() async throws {
        try await loadIfNeeded()
    }

    private func database() throws -> CatalogWriter {
        if let dbWriter {
            return dbWriter
        }

        let state = OtosSignpost.persistence.beginInterval("CatalogOpenDatabase")
        defer {
            OtosSignpost.persistence.endInterval("CatalogOpenDatabase", state)
        }
        do {
            // The open's own transactions are accounted to it: no caller names them.
            let dbWriter = try connectionActivity.naming("catalogOpen") { try openAndMigrateDatabase() }
            // The load's own reads follow; the window says the catalog is opening until
            // its first state arrives.
            reportedOpening.phase = .opening
            openingContinuation.yield(reportedOpening)
            openingContinuation.finish()
            return dbWriter
        } catch {
            // The window learns of a failed load from `start()` itself, which also fails
            // when a read after the open does.
            openingContinuation.finish()
            throw error
        }
    }

    /// Opens the file, refuses a schema this build does not know, reports the roots the
    /// sidebar's fixed rows stand for, and applies pending migrations one at a time.
    /// Every step is timed into `op=catalog.database.open`, so its
    /// `ms` is explained by the fields beside it; each migration has its own line
    /// (`op=catalog.migration`). SQLite recovers a write-ahead log left by the last process
    /// on the first read (`schemaMs`); nothing here checkpoints, checks integrity or
    /// analyzes, so no other step reads the whole file.
    private func openAndMigrateDatabase() throws -> CatalogWriter {
        var timer = LoadPhaseTimer()
        let openResult = try openDatabaseWriter()
        let dbWriter = openResult.dbWriter
        timer.lap("poolMs")
        // The log the last process left, which SQLite recovers on the first read.
        let walBytesAtOpen = Self.walFileSizeBytes(of: openResult.openedFileURL)
        // The open's own reads, before any lane exists.
        // swiftlint:disable:next read_outside_lane
        let compatibility = try dbWriter.read { db in
            try Self.catalogSchemaCompatibility(db)
        }
        timer.lap("schemaMs")
        guard compatibility.isSupported else {
            OtosLog.persistence.error(
                "Catalog schema refused problem=\(compatibility.errorDescription, privacy: .public)"
            )
            OtosLog.catalog.error(
                "op=catalog.start phase=schemaRefused problem=\(String(describing: compatibility), privacy: .public)"
            )
            throw CatalogStoreError.unsupportedCatalogSchema(compatibility)
        }
        // swiftlint:disable:next read_outside_lane
        reportedOpening.memberRootCount = try dbWriter.read { db in
            try Self.memberRootCount(db)
        }
        openingContinuation.yield(reportedOpening)
        timer.lap("rootsMs")
        let roots = reportedOpening.memberRootCount
        let continuation = openingContinuation
        let migrations = try Self.applyPendingMigrations(dbWriter) { step, total in
            continuation.yield(CatalogOpening(phase: .updating(step: step, of: total), memberRootCount: roots))
        }
        migrationRun = migrations
        timer.lap("migrationsMs")
        if let fileURL = openResult.openedFileURL {
            let compaction = try Self.compactIfOwed(dbWriter, fileURL: fileURL) {
                continuation.yield(CatalogOpening(phase: .compacting, memberRootCount: roots))
            }
            compaction.log()
        }
        timer.lap("compactionMs")
        performThumbnailStoreStartupMaintenance()
        timer.lap("thumbnailsMs")
        let writer = CatalogWriter(dbWriter, audit: changeAudit)
        self.dbWriter = writer
        databaseFileURL = openResult.openedFileURL
        var fields = timer.fields
        fields["migrations"] = "\(migrations.applied)"
        fields["walBytesAtOpen"] = walBytesAtOpen.map { "\($0)" } ?? "unknown"
        recordDatabaseOpenDiagnostics(dbWriter: dbWriter, storageKind: openResult.storageKind, fields: fields)
        OtosLog.persistence.info(
            "Catalog database opened storage=\(openResult.storageKind, privacy: .public)"
        )
        return writer
    }

    private struct DatabaseOpenResult {
        let dbWriter: any DatabaseWriter
        let storageKind: String
        let openedFileURL: URL?
    }

    private func openDatabaseWriter() throws -> DatabaseOpenResult {
        switch location {
        case let .application(bundleIdentifier):
            let databaseURL = try Self.applicationDatabaseURL(bundleIdentifier: bundleIdentifier)
            return try DatabaseOpenResult(
                dbWriter: DatabasePool(
                    path: databaseURL.path(percentEncoded: false),
                    configuration: Self.fileBackedDatabaseConfiguration(activity: connectionActivity, walByteLimit: walByteBudget)
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
                    configuration: Self.fileBackedDatabaseConfiguration(activity: connectionActivity, walByteLimit: walByteBudget)
                ),
                storageKind: "file",
                openedFileURL: url
            )
        case .inMemory:
            let queue = try DatabaseQueue()
            try Self.emptyCatalogAtCurrentSchema.get().backup(to: queue)
            return DatabaseOpenResult(
                dbWriter: queue,
                storageKind: "memory",
                openedFileURL: nil
            )
        }
    }

    private func performThumbnailStoreStartupMaintenance() {
        guard let thumbnailDirectory else {
            return
        }
        let removed = ThumbnailStore.clearStaging(in: thumbnailDirectory)
        guard removed > 0 else {
            return
        }
        recordDiagnostic(
            operation: "catalog.thumbnails.staging",
            phase: "cleared",
            fields: ["count": "\(removed)"]
        )
    }

    private func recordDatabaseOpenDiagnostics(
        dbWriter: any DatabaseWriter,
        storageKind: String,
        fields openFields: [String: String]
    ) {
        // The open's diagnostics, on the connection it just opened.
        // swiftlint:disable:next read_outside_lane
        let synchronousValue = (try? dbWriter.read { db in
            try Int.fetchOne(db, sql: "PRAGMA synchronous") ?? -1
        }) ?? -1
        let synchronousLabel = Self.sqliteSynchronousLabel(synchronousValue)
        OtosLog.persistence.info(
            """
            Catalog database pragmas storage=\(storageKind, privacy: .public) \
            synchronous=\(synchronousLabel, privacy: .public)(\(synchronousValue, privacy: .public))
            """
        )
        recordDiagnostic(
            operation: "catalog.database.open",
            phase: "finish",
            fields: openFields.merging([
                "storage": storageKind,
                "synchronous": synchronousLabel,
                "synchronousValue": "\(synchronousValue)",
            ]) { _, pragma in pragma }
        )
    }

    private static func sqliteSynchronousLabel(_ value: Int) -> String {
        switch value {
        case 0:
            "OFF"
        case 1:
            "NORMAL"
        case 2:
            "FULL"
        case 3:
            "EXTRA"
        default:
            "unknown"
        }
    }

    private func applyLoadedCatalog(roots storedRoots: [StoredRoot]) {
        roots.removeAll()

        for storedRoot in storedRoots {
            let root = libraryRoot(from: storedRoot)
            // SQLite proves that a root was saved, not that it is reachable now. A folder the
            // user chose answers that with one `stat` of the folder, here, so its rows show in
            // the first publication and its launch scan only reconciles them (ADR 0008): a
            // reachable library's rows are never hidden until its scan, queued behind the
            // other libraries' on one lane, starts. Every other kind knows its own rule.
            roots.upsert(RootRuntimeState(
                root: root,
                rowID: storedRoot.id,
                sortIndex: storedRoot.sortIndex,
                availability: root.kind.availabilityAtLaunch { rootIsAvailable(root.path) },
                activity: .idle,
                isEjectable: false,
                capabilities: storedRoot.capabilities
            ))
        }
    }

    private func normalizeLoadedRoots(
        _ roots: [StoredRoot],
        dbWriter: CatalogWriter
    ) async -> [StoredRoot] {
        var normalizedRoots: [StoredRoot] = []
        for storedRoot in roots {
            let normalizedRoot = await normalizedLoadedRoot(storedRoot, dbWriter: dbWriter)
            normalizedRoots.append(normalizedRoot)
        }
        return normalizedRoots
    }

    /// The path `storedRoot` is at in this process: a user-chosen folder's spelling as the
    /// filesystem normalizes it, and a staging root's path derived from this build's
    /// containers and its identity (`StagingContainers`), so a root stored by another build,
    /// or before the containers were named by bundle identifier, moves into this build's own.
    /// A move keeps the root's row, so every overlay its assets hold — faces, people, search
    /// readings, edits, keyed by the row and the relative path — moves with it; derived images
    /// take the new identity's names, and an import or erase journaled against the old path
    /// follows it. Nothing on disk moves: staged bytes are a cache, re-fetched on demand, and
    /// the old folder is its own build's to sweep.
    private func loadedPath(of storedRoot: StoredRoot) -> LibraryRootPath? {
        if storedRoot.kind.isUserChosenFolder {
            return try? CatalogPath.normalizedExistingDirectoryPath(for: storedRoot.path.url)
        }
        guard let container = storedRoot.kind.stagingContainer, let identity = storedRoot.deviceIdentity else {
            return nil
        }
        return try? CatalogPath.normalizedDirectoryPath(
            for: stagingContainers.sessionRoot(in: container, identity: identity)
        )
    }

    private func normalizedLoadedRoot(
        _ storedRoot: StoredRoot,
        dbWriter: CatalogWriter
    ) async -> StoredRoot {
        guard let normalizedPath = loadedPath(of: storedRoot), normalizedPath != storedRoot.path else {
            return storedRoot
        }
        do {
            let oldPath = storedRoot.path
            let derivedFolder = derivedFolder
            let thumbnailMigrations = try await dbWriter.write { db in
                let migrations = try Self.updateLibraryRootPath(rootRowID: storedRoot.id, path: normalizedPath, db: db)
                try Self.moveJournaledSourceRoot(from: oldPath, to: normalizedPath, db: db)
                // The files' moves are journaled in the write that renames the rows.
                try derivedFolder?.journalRenames(migrations.map { ($0.oldRelativeName, $0.newRelativeName) }, db: db)
                return migrations
            }
            try await applyPendingDerivedRenames(lane: windowReads.lane)
            OtosLog.persistence.info(
                """
                Library root normalized oldPath=\(storedRoot.path.rawValue, privacy: .public) \
                path=\(normalizedPath.rawValue, privacy: .public) \
                thumbnailMigrations=\(thumbnailMigrations.count, privacy: .public)
                """
            )
            OtosLog.catalog.notice(
                "op=catalog.library.normalize phase=finish kind=\(storedRoot.kind.rawValue, privacy: .public) oldRootPath=\(storedRoot.path.rawValue, privacy: .public) rootPath=\(normalizedPath.rawValue, privacy: .public) thumbnailMigrations=\(thumbnailMigrations.count, privacy: .public)"
            )
            return StoredRoot(
                id: storedRoot.id,
                path: normalizedPath,
                kind: storedRoot.kind,
                deviceIdentity: storedRoot.deviceIdentity,
                displayName: storedRoot.displayName,
                lastSeenAt: storedRoot.lastSeenAt,
                sortIndex: storedRoot.sortIndex,
                capabilities: storedRoot.capabilities,
                deviceModel: storedRoot.deviceModel,
                remoteBaseURL: storedRoot.remoteBaseURL
            )
        } catch {
            await recordRootNormalizationFailure(storedRoot, normalizedPath: normalizedPath, error: error)
            return storedRoot
        }
    }

    private func recordRootNormalizationFailure(
        _ storedRoot: StoredRoot,
        normalizedPath: LibraryRootPath,
        error: Error
    ) async {
        OtosLog.persistence.error(
            """
            Library root normalization failed oldPath=\(storedRoot.path.rawValue, privacy: .public) \
            path=\(normalizedPath.rawValue, privacy: .public) \
            error=\(String(describing: error), privacy: .public)
            """
        )
        OtosLog.catalog.error(
            "op=catalog.library.normalize phase=error oldRootPath=\(storedRoot.path.rawValue, privacy: .public) rootPath=\(normalizedPath.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)"
        )
    }

    private func mediaAsset(from storedAsset: StoredAsset, rootPath: LibraryRootPath) -> MediaAsset {
        MediaAsset(
            libraryRootPath: rootPath,
            relativePath: storedAsset.relativePath,
            name: storedAsset.name,
            contentTypeIdentifier: storedAsset.contentTypeIdentifier,
            byteSize: storedAsset.byteSize,
            createdAt: storedAsset.createdAt,
            contentModifiedAt: storedAsset.contentModifiedAt,
            thumbnailPath: storedAsset.thumbnailPath,
            captureLocalTime: storedAsset.captureLocalTime,
            bestKind: storedAsset.bestKind,
            bestFormat: storedAsset.bestFormat,
            durationSeconds: storedAsset.durationSeconds,
            metadataSourceSize: storedAsset.metadataSourceSize,
            metadataSourceMTimeSeconds: storedAsset.metadataSourceMTimeSeconds,
            renderedSourceSize: storedAsset.renderedSourceSize,
            renderedSourceMTimeSeconds: storedAsset.renderedSourceMTimeSeconds,
            contentHash: storedAsset.contentHash,
            contentHashSourceSize: storedAsset.contentHashSourceSize,
            contentHashSourceMTimeSeconds: storedAsset.contentHashSourceMTimeSeconds,
            facesSourceSize: storedAsset.facesSourceSize,
            facesSourceMTimeSeconds: storedAsset.facesSourceMTimeSeconds,
            mediaChoice: storedAsset.mediaChoice
        )
    }

    private func mediaTileDetail(from storedDetail: StoredTileDetail, rootPath: LibraryRootPath) -> MediaTileDetail {
        MediaTileDetail(
            libraryRootPath: rootPath,
            relativePath: storedDetail.relativePath,
            byteSize: storedDetail.byteSize,
            thumbnailPath: storedDetail.thumbnailPath,
            previewPath: storedDetail.previewPath,
            nativePixelWidth: storedDetail.nativePixelSize.map { Int($0.width) },
            nativePixelHeight: storedDetail.nativePixelSize.map { Int($0.height) },
            editRecipe: storedDetail.editRecipe,
            renderedRevision: storedDetail.renderedRevision,
            bestKind: storedDetail.bestKind,
            durationSeconds: storedDetail.durationSeconds,
            renderedSourceSize: storedDetail.renderedSourceSize,
            renderedSourceMTimeSeconds: storedDetail.renderedSourceMTimeSeconds,
            mediaChoice: storedDetail.mediaChoice,
            copyKey: storedDetail.copyKey
        )
    }

    private func upsert(_ state: RootRuntimeState) {
        roots.upsert(state)
    }

    private func removeRoot(path: LibraryRootPath) {
        _ = roots.remove(path: path)
        scanLeases.removeListingScan(for: path)
    }

    private func catalogLibraryState(from state: RootRuntimeState) -> CatalogLibraryState {
        CatalogLibraryState(
            root: state.root,
            sortIndex: state.sortIndex,
            availability: state.availability,
            activity: activity(for: state.path),
            isEjectable: state.isEjectable,
            attachmentGeneration: state.attachmentGeneration
        )
    }

    private func activity(for path: LibraryRootPath) -> CatalogLibraryActivity {
        // Pending full-root scans must read as scanning. clearCurrentScan clears the
        // active lease before the reconcile loop starts the next pending root; without
        // this, waiters can observe a false idle gap and race.
        if scanLeases.hasActiveFilesystemScan(for: path)
            || scanLeases.pendingScanPaths.contains(path)
        {
            return .scanning
        }
        return roots[path]?.activity ?? .idle
    }

    private func libraryRoot(from storedRoot: StoredRoot) -> LibraryRoot {
        LibraryRoot(
            path: storedRoot.path,
            kind: storedRoot.kind,
            deviceIdentity: storedRoot.deviceIdentity,
            displayName: storedRoot.displayName,
            lastSeenAt: storedRoot.lastSeenAt,
            remoteBaseURL: storedRoot.remoteBaseURL
        )
    }

    private func scopePredicate(
        selection: SidebarSelection,
        availableLibraryPaths: Set<LibraryRootPath>
    ) -> CatalogScopePredicate {
        roots.scopePredicate(
            selection: selection,
            availableLibraryPaths: availableLibraryPaths,
            duplicatesReach: duplicatesReach
        )
    }

    private func validateNoOverlap(_ path: LibraryRootPath, ignoring existingRootRowID: Int64? = nil) throws {
        try roots.validateNoOverlap(path, ignoring: existingRootRowID)
    }

    /// Queues a full walk of each root, saying why (`reason`). A walk is owed in the root's
    /// journal until one completes, so no position is stored ahead of it.
    private func enqueueScans(
        _ paths: [LibraryRootPath],
        priority: ScanLeaseController.QueuePriority = .normal,
        reason: ScanReason
    ) {
        for path in paths where roots[path] != nil {
            if pendingScanReasons[path] == nil {
                pendingScanReasons[path] = reason
            }
            changeJournals[path]?.oweWalk()
        }
        scanLeases.enqueue(paths, priority: priority) { roots[$0] != nil }
        startNextScanIfNeeded()
    }

    /// The lane a root's filesystem walks take (`ScanLeaseController.ScanLane`).
    private func scanLane(for path: LibraryRootPath) -> ScanLeaseController.ScanLane {
        roots[path]?.root.kind.isUserChosenFolder == true ? .fixedLibraries : .removableSource(path)
    }

    /// Starts every queued scan whose lane is free, in queue order: a card attached while
    /// a library rescans is read at once in its own lane.
    private func startNextScanIfNeeded() {
        guard !reconcilePassRunning else {
            return
        }
        while true {
            let busyLanes = Set(scanLeases.activeScans.keys)
            guard let nextPath = scanLeases.takeFirstPending(where: { !busyLanes.contains(scanLane(for: $0)) }) else {
                return
            }
            guard roots[nextPath] != nil,
                  let rootRowID = roots[nextPath]?.rowID
            else {
                continue
            }
            if namespaceMutationLeases[nextPath] != nil {
                // Defer until lease release; do not spin the pending queue.
                scanLeases.markRescanAfterCurrentScan(nextPath)
                continue
            }
            guard rootIsAvailable(nextPath) else {
                markRootUnavailableBeforeScan(nextPath)
                continue
            }
            setAvailability(.available, for: nextPath)
            let lane = scanLane(for: nextPath)
            let scan = scanLeases.makeActiveScan(
                rootPath: nextPath,
                rootRowID: rootRowID,
                startNamespaceMutationEpoch: roots[nextPath]?.namespaceMutationEpoch ?? 0
            )
            scanLeases.beginFilesystemScan(scan, lane: lane)
            filesystemWatchingArmed.insert(nextPath)
            watchRoot(nextPath)
            let reason = pendingScanReasons.removeValue(forKey: nextPath) ?? .requested
            runningScanReasons[nextPath] = reason
            changeJournals[nextPath]?.walkStarted()
            // The root's own state moved (its order, a scan or listing starting or ending);
            // no row did, and the rows a scan changed or deleted were announced with them.
            notifyCatalogChanged(.changed(.membership, rows: .none))
            OtosLog.catalog.info("Catalog scan started path=\(nextPath.rawValue, privacy: .public)")
            recordDiagnostic(
                operation: "catalog.scan",
                phase: "start",
                fields: [
                    "rootPath": nextPath.rawValue, "lane": lane.diagnosticName, "reason": reason.rawValue,
                    "priority": "\(lane.taskPriority.rawValue)",
                ]
            )
            scanTasks[lane] = Task.detached(priority: lane.taskPriority) { [scanner, scanCadence] in
                do {
                    let baseline = try await self.scanBaseline(scan: scan, underSubtree: nil)
                    let tally = ScanWriteTally()
                    let observation = try await scanner.scanRoot(nextPath, scanCadence) { batch in
                        // Compared here, off the Store actor: only what differs reaches it.
                        try await self.recordScannedBatch(
                            baseline.filesNeedingWrite(batch), observedCount: batch.count, tally: tally, scan: scan
                        )
                    }
                    await self.scanCompleted(scan: scan, observation: observation, baseline: baseline, tally: tally)
                } catch is CancellationError {
                    await self.scanCancelled(scan: scan)
                } catch {
                    await self.scanFailed(scan: scan, error: error)
                }
            }
        }
    }

    /// What the catalog holds for a pass's scope before it walks (`ScanBaseline`), read on a
    /// background lane. A failed read fails the pass: it is never taken as an empty catalog.
    private func scanBaseline(scan: ActiveScan, underSubtree: MediaRelativePath?) async throws -> ScanBaseline {
        guard owns(scan) else {
            throw CancellationError()
        }
        let capabilities = roots[scan.rootPath]?.capabilities ?? .unknown
        let rootRowID = scan.rootRowID
        return try await reader(for: backgroundReads.lane).readFreeingConnection { db in
            try Self.fetchScanBaseline(
                libraryRootID: rootRowID,
                underSubtree: underSubtree,
                capabilities: capabilities,
                db: db
            )
        }
    }

    /// Writes the files of one scan batch whose rows differ from the pass's baseline
    /// (`candidates`, of the `observedCount` files the walk observed). A batch with none
    /// takes no write transaction: an unchanged walk holds the writer for nothing.
    private func recordScannedBatch(
        _ candidates: [ScannedMediaFile],
        observedCount: Int,
        tally: ScanWriteTally,
        scan: ActiveScan
    ) async throws {
        guard owns(scan) else {
            await recordIgnoredStaleCallback(scan, callback: "batch.beforeWrite")
            throw CancellationError()
        }
        tally.observed(observedCount)
        guard !candidates.isEmpty else {
            OtosLog.catalog.notice(
                "op=catalog.scan.batch phase=finish rootPath=\(scan.rootPath.rawValue, privacy: .public) count=\(observedCount, privacy: .public) candidates=0 changed=false changedCount=0 inserted=0 updated=0 writeMs=0"
            )
            return
        }
        let batch = candidates

        let dbQueue = try database()
        let scanCapabilities = roots[scan.rootPath]?.capabilities ?? .unknown
        let state = OtosSignpost.persistence.beginInterval("CatalogScanBatchWrite")
        let timedRows = try await timedWrite(dbQueue) { db in
            var rows = CatalogRowChanges()
            for file in batch {
                try rows.record(Self.upsertScannedFile(
                    file,
                    libraryRootPath: scan.rootPath,
                    libraryRootID: scan.rootRowID,
                    capabilities: scanCapabilities,
                    db: db
                ), of: MediaAssetID(libraryRootPath: scan.rootPath, relativePath: file.relativePath))
            }
            return rows
        }
        OtosSignpost.persistence.endInterval("CatalogScanBatchWrite", state)
        let rows = timedRows.value

        // The store actor can process remove/cancel messages while SQLite is
        // writing. Recheck ownership before notifying from this batch.
        guard owns(scan) else {
            await recordIgnoredStaleCallback(scan, callback: "batch.afterWrite")
            throw CancellationError()
        }

        // SQLite reported whether this batch inserted a new row or changed existing
        // filesystem facts. Identical rescans publish nothing; changed dates still
        // count because Date sort and enrichment priority fall back to them. A
        // changed batch is a real import-occupancy change (added row or resized
        // file), so it advances the occupancy revision; identical rescans do not,
        // which is what lets import planning settle against a churning cloud root.
        let announced = rows.notifications
        if !announced.isEmpty {
            bumpNamespaceRevision(for: scan.rootPath)
            announced.forEach(notifyCatalogChanged)
        }
        tally.wrote(rows.inserted + rows.updated)
        recordScanBatchWrite(scan: scan, scannedCount: observedCount, candidates: batch.count, timed: timedRows)
        await boundWAL(reason: "scanBatch")
    }

    private func recordScanBatchWrite(
        scan: ActiveScan,
        scannedCount: Int,
        candidates: Int,
        timed timing: DatabaseTimedValue<CatalogRowChanges>
    ) {
        let rows = timing.value
        let visibleChange = !rows.isEmpty
        let changedCount = rows.inserted + rows.updated
        OtosLog.catalog.debug(
            """
            Catalog scan batch path=\(scan.rootPath.rawValue, privacy: .public) \
            count=\(scannedCount, privacy: .public) changed=\(visibleChange, privacy: .public) \
            waitMs=\(timing.waitMs, privacy: .public) \
            execMs=\(timing.execMs, privacy: .public) \
            writeMs=\(timing.totalMs, privacy: .public)
            """
        )
        OtosLog.catalog.notice(
            "op=catalog.scan.batch phase=finish rootPath=\(scan.rootPath.rawValue, privacy: .public) count=\(scannedCount, privacy: .public) candidates=\(candidates, privacy: .public) changed=\(visibleChange, privacy: .public) changedCount=\(changedCount, privacy: .public) inserted=\(rows.inserted, privacy: .public) updated=\(rows.updated, privacy: .public) waitMs=\(timing.waitMs, privacy: .public) execMs=\(timing.execMs, privacy: .public) resumeMs=\(timing.resumeMs, privacy: .public) priority=\(timing.priorityName, privacy: .public) writeMs=\(timing.totalMs, privacy: .public)"
        )
    }

    private func scanCompleted(
        scan: ActiveScan,
        observation: CatalogScanObservation,
        baseline: ScanBaseline,
        tally: ScanWriteTally
    ) async {
        guard owns(scan) else {
            await recordIgnoredStaleCallback(scan, callback: "completion")
            return
        }

        do {
            let deletedCount = try await reconcileMissingAssets(
                scan: scan,
                observedPaths: observation.mediaPaths
            )
            let canReconcileCompanionDeletions = scanCanDelete(scan)
            // Pairing reads the companions and the root's media rows: when the walk changed
            // neither, it would write back what the catalog holds, so it takes no writer.
            let companionChanged = if tally.rowsWritten == 0, deletedCount == 0,
                                      baseline.companionsMatch(observation.companions)
            {
                false
            } else {
                try await applyAndReconcileCompanions(
                    scan: scan,
                    companions: observation.companions,
                    reconcileMissing: canReconcileCompanionDeletions && scanCanDelete(scan)
                )
            }
            if var state = roots[scan.rootPath] {
                state.skippedPackageCount = observation.skippedPackageCount
                upsert(state)
            }
            // Media additions/resizes already advanced occupancy per changed batch.
            // Deletions and companion-inventory changes surface only at completion,
            // so bump occupancy here for those; an identical rescan (no deletions,
            // no companion change) advances only the general planRevision, which the
            // import coordinator treats as a cheap no-op wake.
            if deletedCount > 0 || companionChanged {
                bumpNamespaceRevision(for: scan.rootPath)
            } else {
                bumpPlanRevision(for: scan.rootPath)
            }
            // Companions are which files a row lists with it; the packages a walk skipped
            // are the root's own state.
            if companionChanged {
                notifyCatalogChanged(.changed(.membership))
            } else if observation.skippedPackageCount > 0 {
                notifyCatalogChanged(.changed(.membership, rows: .none))
            }
            OtosLog.catalog.info(
                """
                Catalog scan completed path=\(scan.rootPath.rawValue, privacy: .public) \
                observed=\(observation.mediaPaths.count, privacy: .public) \
                companions=\(observation.companions.count, privacy: .public) \
                deleted=\(deletedCount, privacy: .public) \
                skippedPackages=\(observation.skippedPackageCount, privacy: .public)
                """
            )
            let reason = (runningScanReasons[scan.rootPath] ?? .requested).rawValue
            OtosLog.catalog.notice(
                "op=catalog.scan phase=finish rootPath=\(scan.rootPath.rawValue, privacy: .public) reason=\(reason, privacy: .public) directoriesRead=\(observation.directoriesRead, privacy: .public) filesStatted=\(observation.itemsStatted, privacy: .public) observed=\(observation.mediaPaths.count, privacy: .public) rowsWritten=\(tally.rowsWritten, privacy: .public) companionCount=\(observation.companions.count, privacy: .public) companionsChanged=\(companionChanged, privacy: .public) deleted=\(deletedCount, privacy: .public) skippedPackageCount=\(observation.skippedPackageCount, privacy: .public)"
            )
            // A walk that deleted what it did not find reconciled the whole root: what its
            // journal owed when it started is settled. One whose deletions a mutation
            // suppressed did not, and leaves it owed.
            if canReconcileCompanionDeletions, scanCanDelete(scan) {
                changeJournals[scan.rootPath]?.walkCompleted()
            } else {
                changeJournals[scan.rootPath]?.walkEnded()
            }
            if !canReconcileCompanionDeletions || !scanCanDelete(scan) {
                let dirty = filesystemDirty[scan.rootPath]
                recordDiagnostic(
                    operation: "catalog.scan.reconcile",
                    phase: "deferredStaleObservation",
                    fields: [
                        "rootPath": scan.rootPath.rawValue,
                        "rootRowID": "\(scan.rootRowID)",
                        "leaseGeneration": "\(scan.leaseGeneration)",
                        "startEpoch": "\(scan.startNamespaceMutationEpoch)",
                        "currentEpoch": "\(roots[scan.rootPath]?.namespaceMutationEpoch ?? 0)",
                        "fileScopeCount": "\(dirty?.fileCount ?? 0)",
                        "subtreeScopeCount": "\(dirty?.subtreeCount ?? 0)",
                        "rootScopeCount": dirty?.isRootDirty == true ? "1" : "0",
                    ]
                )
            }
            lastSuccessfulFullRootScanAt[scan.rootPath] = .now
        } catch is CancellationError {
            await recordIgnoredStaleCallback(scan, callback: "reconciliation")
            return
        } catch {
            OtosLog.catalog.error(
                """
                Catalog scan reconciliation failed path=\(scan.rootPath.rawValue, privacy: .public) \
                error=\(String(describing: error), privacy: .public)
                """
            )
            OtosLog.catalog.error(
                "op=catalog.scan.reconcile phase=error rootPath=\(scan.rootPath.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }

        clearCurrentScan(scan, armFilesystemWatching: true)
    }

    private func applyAndReconcileCompanions(
        scan: ActiveScan,
        companions: [ScannedCompanionFile],
        underSubtree: MediaRelativePath? = nil,
        reconcileMissing: Bool = true
    ) async throws -> Bool {
        guard owns(scan) else {
            throw CancellationError()
        }
        if reconcileMissing {
            guard scanCanDelete(scan) else {
                return false
            }
        }
        let dbQueue = try database()
        let scanCapabilities = roots[scan.rootPath]?.capabilities ?? .unknown
        let timed = try await timedWrite(dbQueue) { db in
            let upserted = try Self.applyScannedCompanions(
                companions,
                libraryRootID: scan.rootRowID,
                capabilities: scanCapabilities,
                db: db
            )
            let deleted = if reconcileMissing {
                try Self.reconcileMissingCompanions(
                    libraryRootID: scan.rootRowID,
                    observedPaths: Set(companions.map(\.relativePath)),
                    capabilities: scanCapabilities,
                    underSubtree: underSubtree,
                    db: db
                )
            } else {
                0
            }
            return upserted + deleted
        }
        guard owns(scan) else {
            throw CancellationError()
        }
        return timed.value > 0
    }

    /// Reconciliation changes durable membership as one actor-owned operation.
    /// Projection validates membership directly through Store queries, so Store does not
    /// maintain a second per-asset cache-invalidation fact alongside SQLite.
    private func reconcileMissingAssets(
        scan: ActiveScan,
        observedPaths: Set<MediaRelativePath>,
        underSubtree: MediaRelativePath? = nil
    ) async throws -> Int {
        guard owns(scan) else {
            throw CancellationError()
        }
        guard scanCanDelete(scan) else {
            return 0
        }
        let scanCapabilities = roots[scan.rootPath]?.capabilities ?? .unknown
        let dbQueue = try database()
        let existingRows = try await reader(for: backgroundReads.lane).readFreeingConnection { db in
            try Self.fetchExistingAssetRows(
                libraryRootID: scan.rootRowID,
                underSubtree: underSubtree,
                db: db
            )
        }
        guard owns(scan) else {
            throw CancellationError()
        }
        guard scanCanDelete(scan) else {
            return 0
        }
        let observedKeys = Set(observedPaths.map {
            FilesystemNamespaceSemantics.nameKey(relativePath: $0, capabilities: scanCapabilities)
        })
        // A row whose file is in the system Trash is missing from its path but not proven
        // deleted: it stays until the Trash no longer holds the file (ADR 0022).
        let missingRows = existingRows.filter {
            !observedKeys.contains(
                FilesystemNamespaceSemantics.nameKey(relativePath: $0.relativePath, capabilities: scanCapabilities)
            ) && !Self.isHeldInTrash(trashPath: $0.trashPath)
        }
        guard !missingRows.isEmpty else {
            return 0
        }
        guard scanCanDelete(scan) else {
            return 0
        }
        // Capture the thumbnail files of soon-to-be-purged assets before their rows are
        // removed, so overlay is purged with the item (ADR 0008): the catalog rows and
        // thumbnail file all go together on proven deletion.
        let purgedThumbnails: [String] = missingRows.flatMap(\.derivedImagePaths)
        let loggedRows = Array(missingRows.prefix(20))
        for row in loggedRows {
            OtosLog.catalog.notice(
                "op=catalog.scan.reconcile phase=delete rootPath=\(scan.rootPath.rawValue, privacy: .public) relativePath=\(row.relativePath.rawValue, privacy: .public) derivedImages=\(row.derivedImagePaths.count, privacy: .public) hadEnrichment=\(row.hadEnrichment, privacy: .public)"
            )
        }
        let message = "op=catalog.scan.reconcile phase=deleteSummary "
            + "rootPath=\(scan.rootPath.rawValue) "
            + "count=\(missingRows.count) "
            + "logged=\(loggedRows.count)"
        OtosLog.catalog.notice("\(message, privacy: .public)")
        let state = OtosSignpost.persistence.beginInterval("CatalogScanReconcile")
        defer { OtosSignpost.persistence.endInterval("CatalogScanReconcile", state) }

        let derivedFolder = derivedFolder
        let (deleted, removal) = try await dbQueue.write { db in
            var rows = CatalogRowChanges()
            for row in missingRows {
                try rows.recordDeleted(
                    Self.deleteAssetRow(rootRowID: scan.rootRowID, relativePath: row.relativePath, db: db),
                    of: row.relativePath, in: scan.rootPath
                )
            }
            return try (rows.updatedRows, derivedFolder?.unname(purgedThumbnails, db: db) ?? .nothing)
        }
        // Removal and same-path replacement can run while GRDB owns the writer.
        // Never treat an old row's reconciliation as proof about the replacement root.
        // The deleted rows' files go either way, off the actor, after this check and the
        // announcement: no suspension stands between the write and either.
        guard owns(scan) else {
            await removal.perform()
            throw CancellationError()
        }
        // The deletion names its rows and the Live Photo partners they leave, so an owner
        // that keeps a memory per asset lets go of these alone and asks the partners again;
        // the scan's end announces only that the root is idle again.
        notifyCatalogChanged(.changed(.presence, rows: .rows(deleted)))
        await removal.perform()
        return missingRows.count
    }

    private func scanCancelled(scan: ActiveScan) async {
        guard owns(scan) else {
            await recordIgnoredStaleCallback(scan, callback: "cancellation")
            return
        }
        OtosLog.catalog.info("Catalog scan cancelled path=\(scan.rootPath.rawValue, privacy: .public)")
        OtosLog.catalog.notice(
            "op=catalog.scan phase=cancel rootPath=\(scan.rootPath.rawValue, privacy: .public)"
        )
        clearCurrentScan(scan, armFilesystemWatching: false)
    }

    private func scanFailed(scan: ActiveScan, error: Error) async {
        guard owns(scan) else {
            await recordIgnoredStaleCallback(scan, callback: "failure")
            return
        }
        let errorDescription = if case CatalogScanError.filesystemErrorsEncountered = error {
            "filesystemErrorsEncountered"
        } else {
            String(describing: error)
        }
        let isStillAvailable = rootIsAvailable(scan.rootPath)
        if !isStillAvailable {
            setAvailability(.unavailable, for: scan.rootPath)
            OtosLog.catalog.error(
                "Catalog scan failed because root is unavailable path=\(scan.rootPath.rawValue, privacy: .public)"
            )
            OtosLog.catalog.notice(
                "op=catalog.library.availability phase=unavailable rootPath=\(scan.rootPath.rawValue, privacy: .public)"
            )
        } else {
            OtosLog.catalog.error(
                """
                Catalog scan failed path=\(scan.rootPath.rawValue, privacy: .public) \
                error=\(errorDescription, privacy: .public)
                """
            )
        }
        var diagnosticFields = [
            "rootPath": scan.rootPath.rawValue,
            "error": errorDescription,
        ]
        if case let CatalogScanError.filesystemErrorsEncountered(count, summaries) = error {
            OtosLog.fileAccess.error("Filesystem scan errors count=\(count, privacy: .public)")
            diagnosticFields["issueCount"] = "\(count)"
            for (index, summary) in summaries.enumerated() {
                let prefix = "issue\(index)"
                diagnosticFields["\(prefix).kind"] = summary.kind
                diagnosticFields["\(prefix).error"] = summary.errorDescription
                diagnosticFields["\(prefix).count"] = "\(summary.count)"
                diagnosticFields["\(prefix).examples"] = summary.examplePaths.joined(separator: " | ")
            }
        }
        OtosLog.catalog.error(
            "op=catalog.scan phase=error \(otosLogFields(diagnosticFields), privacy: .public)"
        )
        clearCurrentScan(scan, armFilesystemWatching: true)
        if roots[scan.rootPath]?.root.kind.isRemovable == true, roots[scan.rootPath]?.rowID == scan.rootRowID {
            await releaseAwaitingPresence(of: scan.rootPath, rootRowID: scan.rootRowID, reason: "scanFailed")
        }
    }

    private func clearCurrentScan(_ scan: ActiveScan, armFilesystemWatching: Bool) {
        guard scanLeases.isCurrentFilesystemScan(scan) else {
            return
        }
        let rootPath = scan.rootPath
        guard let cleared = scanLeases.clearFilesystemScan(scan) else {
            return
        }
        let needsRescan = cleared.needsRescan
        scanTasks.removeValue(forKey: cleared.lane)
        changeJournals[rootPath]?.walkEnded()
        runningScanReasons.removeValue(forKey: rootPath)

        if armFilesystemWatching, roots[rootPath] != nil {
            filesystemWatchingArmed.insert(rootPath)
        }

        if needsRescan {
            // Reorganization (and other independently verified owners) still use
            // rescanAfterCurrentScan for an unconditional full-root follow-up.
            filesystemEventBatches.removeValue(forKey: rootPath)
            filesystemDirty[rootPath, default: FilesystemDirtyAccumulator()].insertRoot(reason: .requested)
            enqueueScans([rootPath], reason: .requested)
        }

        // The root's own state moved (its order, a scan or listing starting or ending);
        // no row did, and the rows a scan changed or deleted were announced with them.
        notifyCatalogChanged(.changed(.membership, rows: .none))
        // Drain every dirty root before starting the next queued full-root scan:
        // subtree/root dirt waits while any scan holds the global lease, so starting B
        // first would leave A's retained dirt waiting behind B.
        requestReconcile()
    }

    /// Rings the reconcile loop, starting it if this Store has none yet. The loop starts
    /// on first request rather than in `start()` because a Store that only adds and
    /// scans libraries still needs its queued scans advanced. It holds the Store weakly
    /// and ends when the Store does; after `shutdown()` no root is armed and no scan is
    /// queued, so a request then reconciles nothing. Each ring first runs the library
    /// removals a lease release handed over: like held-back dirt, they are work a lease
    /// kept from running, and a removed root has no dirt left to reconcile.
    private func requestReconcile() {
        reconcileRequested &+= 1
        if reconcileLoop == nil {
            let (bell, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            reconcileDoorbell = continuation
            reconcileLoop = Task { [weak self] in
                for await _ in bell {
                    guard let self else { return }
                    await runHandedOffLibraryRemovals()
                    await runReconcilePass()
                }
            }
        }
        reconcileDoorbell?.yield(())
    }

    private func runReconcilePass() async {
        guard reconcileRequested != reconcileCovered else {
            return
        }
        let startedFrom = reconcileRequested
        reconcilePassRunning = true
        for root in filesystemDirty.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            await drainDirtyReconcile(for: root)
        }
        await storeAppliedJournalPositions()
        reconcilePassRunning = false
        reconcileCovered = startedFrom
        startNextScanIfNeeded()
        if reconcileRequested != reconcileCovered {
            reconcileDoorbell?.yield(())
        }
    }

    /// Stores, for each root whose every delivered event is applied, the position its journal
    /// has reached (`RootChangeJournal.positionToStore`). Run by the reconcile loop after it
    /// drains, so the position is stored only once what it vouches for is in the catalog; a
    /// failed write is logged and leaves the older position, which only replays more.
    private func storeAppliedJournalPositions() async {
        for root in changeJournals.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let journal = changeJournals[root], journal.canVouch, let rowID = roots[root]?.rowID else {
                continue
            }
            let isApplied = filesystemEventBatches[root]?.isEmpty != false
                && filesystemEventPasses[root] == nil
                && filesystemDirty[root]?.isEmpty != false
                && !scanLeases.hasActiveFilesystemScan(for: root)
                && !scanLeases.pendingScanPaths.contains(root)
                && !scanLeases.rescanAfterCurrentScan.contains(root)
                && namespaceMutationLeases[root] == nil
            guard isApplied, journal.hasNewPosition,
                  let position = journal.positionToStore(isApplied: isApplied, probe: filesystemWatcher.probe(root))
            else {
                continue
            }
            do {
                let dbWriter = try database()
                _ = try await timedWrite(dbWriter) { db in
                    try Self.storeJournalPosition(position, rootRowID: rowID, db: db)
                }
                guard roots[root]?.rowID == rowID else {
                    continue
                }
                changeJournals[root]?.didStore(position)
                OtosLog.catalog.noticeOperation("catalog.journal", phase: "stored", fields: [
                    "rootPath": root.rawValue, "eventID": "\(position.eventID)",
                ])
            } catch {
                OtosLog.catalog.errorOperation("catalog.journal", phase: "storeFailed", fields: [
                    "rootPath": root.rawValue, "error": String(describing: error),
                ])
            }
        }
    }

    private func notifyCatalogChanged(_ change: CatalogStoreChange) {
        changeAudit?.changeSent(change)
        deliver(change)
    }

    /// Yields `change` to every subscriber and counts it.
    private func deliver(_ change: CatalogStoreChange) {
        let state = OtosSignpost.catalog.beginInterval("CatalogChangeNotify")
        defer {
            OtosSignpost.catalog.endInterval("CatalogChangeNotify", state)
        }
        changeTally.record(change)
        for (id, continuation) in changeContinuations {
            if case .enqueued = continuation.yield(change) {
                changeDeliveries[id]?.recordDelivery()
            }
        }
    }

    private func emitPlanningChange(rootPath: LibraryRootPath, state: RootRuntimeState) {
        let change = RootPlanningChange(
            rootPath: rootPath,
            namespaceRevision: state.namespaceRevision,
            namingRevision: state.namingRevision
        )
        // Emit-side observability: a silence on the coordinator
        // side can now be attributed to "no events emitted" vs "events not received"
        // by matching this line against the coordinator's receive/refresh lines.
        let listenerCount = planningChangeContinuations.count
        OtosLog.catalog.noticeOperation(
            "catalog.planningChange",
            phase: "emit",
            fields: [
                "rootPath": rootPath.rawValue,
                "namespaceRevision": "\(state.namespaceRevision)",
                "namingRevision": "\(state.namingRevision)",
                "listeners": "\(listenerCount)",
            ]
        )
        for (id, continuation) in planningChangeContinuations {
            if case .enqueued = continuation.yield(change) {
                planningChangeDeliveries[id]?.recordDelivery()
            }
        }
    }

    private func removeChangeContinuation(_ id: UUID) {
        changeContinuations.removeValue(forKey: id)
        changeDeliveries.removeValue(forKey: id)
    }

    private func removePlanningChangeContinuation(_ id: UUID) {
        planningChangeContinuations.removeValue(forKey: id)
        planningChangeDeliveries.removeValue(forKey: id)
    }

    private func rootIsAvailable(_ path: LibraryRootPath) -> Bool {
        let state = OtosSignpost.fileAccess.beginInterval("CatalogRootAvailabilityCheck")
        defer {
            OtosSignpost.fileAccess.endInterval("CatalogRootAvailabilityCheck", state)
        }
        do {
            let values = try path.url.resourceValues(forKeys: [.isDirectoryKey])
            return values.isDirectory == true
        } catch where ErrorDiagnostics.isMissingFile(error) {
            // Nothing is there (a volume not mounted, a folder moved away): unavailable is the
            // fact the error states.
            OtosLog.fileAccess.debugOperation("catalog.root.availability", phase: "missing", fields: ["rootPath": path.rawValue])
            return false
        } catch {
            // Something is there that Otos cannot read (no permission, an I/O error): it cannot
            // scan or watch it, so it is unavailable, and the error says why by its domain and code.
            OtosLog.fileAccess.errorOperation(
                "catalog.root.availability", phase: "unreadable",
                fields: ErrorDiagnostics.fields(for: error).merging(["rootPath": path.rawValue]) { _, path in path }
            )
            return false
        }
    }

    /// The one way a root's availability changes. Which rows are in reach moved when it did,
    /// so the change is announced here, naming no rows (`CatalogChangedRows`): an owner whose
    /// reads are bound to the roots read reads them again.
    private func setAvailability(_ availability: LibraryAvailability, for path: LibraryRootPath) {
        guard roots.setAvailability(availability, for: path) else { return }
        OtosLog.catalog.noticeOperation("catalog.library.availability", phase: "changed", fields: [
            "rootPath": path.rawValue, "availability": "\(availability)",
        ])
        notifyCatalogChanged(.changed(.membership))
    }

    private func markRootUnavailableBeforeScan(_ path: LibraryRootPath) {
        setAvailability(.unavailable, for: path)
        OtosLog.catalog.info("Library root unavailable before scan path=\(path.rawValue, privacy: .public)")
        recordDiagnostic(
            operation: "catalog.library.availability",
            phase: "unavailable",
            fields: ["rootPath": path.rawValue]
        )
    }

    /// Draining only the roots restored by the initial read keeps two automatic
    /// behaviors distinct: launch scans happen once, while a newly added root is
    /// scanned by its add intent and is never duplicated by a later `start()`.
    private func requestLoadedRootScansIfNeeded() {
        guard !unrequestedLoadedRootPaths.isEmpty else {
            return
        }
        let paths = unrequestedLoadedRootPaths
        unrequestedLoadedRootPaths.removeAll(keepingCapacity: false)
        for path in paths {
            reconcileAtLaunch(path)
        }
    }

    /// A restored fixed library at launch: its stream replays the volume's history since the
    /// stored position, and only what that names is reconciled; or, when the journal cannot
    /// vouch for the root (`JournalLaunchDecision`), its stream starts now and the root is
    /// walked. The source wins either way: the journal is the filesystem's own record, and a
    /// walk is what stands in for it when it has none to give.
    private func reconcileAtLaunch(_ path: LibraryRootPath) {
        let stored = loadedJournalPositions.removeValue(forKey: path)
        guard rootIsAvailable(path) else {
            enqueueScans([path], reason: .unreadable)
            return
        }
        let probe = filesystemWatcher.probe(path)
        let decision = JournalLaunchDecision.decide(stored: stored, probe: probe)
        var fields = [
            "rootPath": path.rawValue,
            "storedEventID": stored.map { "\($0.eventID)" } ?? "none",
            "currentEventID": probe.map { "\($0.currentEventID)" } ?? "none",
        ]
        switch decision {
        case let .replay(since):
            fields["mode"] = "replay"
            fields["since"] = "\(since)"
            recordDiagnostic(operation: "catalog.scan", phase: "decide", fields: fields)
            guard let stored else {
                return
            }
            startJournal(.replaying(from: stored), for: path)
            setAvailability(.available, for: path)
            filesystemWatchingArmed.insert(path)
        case let .walk(reason):
            fields["mode"] = "walk"
            fields["reason"] = reason.rawValue
            recordDiagnostic(operation: "catalog.scan", phase: "decide", fields: fields)
            if let probe {
                startJournal(.walking(probe: probe, stored: stored), for: path)
            } else {
                watchRoot(path)
            }
            enqueueScans([path], reason: reason)
        }
    }

    /// Starts `journal`'s stream for `path`, from its position, replacing a stream that
    /// started without one.
    private func startJournal(_ journal: RootChangeJournal, for path: LibraryRootPath) {
        if watchedRoots.remove(path) != nil {
            filesystemWatcher.unwatch(path)
        }
        changeJournals[path] = journal
        filesystemWatcher.watch(path, journal.streamStart)
        watchedRoots.insert(path)
    }

    /// Watches `path` if nothing does yet. A fixed library whose journal can be read gets
    /// one from now (`RootChangeJournal.walking`): its callers are about to walk it, or owe
    /// it a walk this session has not run. Any other root is watched from now with none.
    private func watchRoot(_ path: LibraryRootPath) {
        guard !watchedRoots.contains(path) else {
            return
        }
        if roots[path]?.root.kind.isUserChosenFolder == true, let probe = filesystemWatcher.probe(path) {
            startJournal(.walking(probe: probe, stored: loadedJournalPositions[path]), for: path)
            return
        }
        filesystemWatcher.watch(path, nil)
        watchedRoots.insert(path)
    }

    /// Every root the Store watches that no launch decision or add has watched yet. A
    /// restored library still waiting for its launch decision is watched from now without a
    /// journal; its decision replaces that stream.
    private func watchUnwatchedRoots() {
        for path in watchedRootPaths where !watchedRoots.contains(path) {
            if unrequestedLoadedRootPaths.contains(path) {
                filesystemWatcher.watch(path, nil)
                watchedRoots.insert(path)
            } else {
                watchRoot(path)
            }
        }
    }

    private func stopWatching(_ path: LibraryRootPath) {
        if watchedRoots.remove(path) != nil {
            filesystemWatcher.unwatch(path)
        }
        changeJournals.removeValue(forKey: path)
        pendingScanReasons.removeValue(forKey: path)
        runningScanReasons.removeValue(forKey: path)
    }

    private func startFilesystemWatchingIfNeeded() {
        guard !filesystemWatchingStarted else {
            return
        }
        filesystemWatchingStarted = true
        // FSEvents reaches us through a synchronous C callback. Events travel one
        // ordered stream to one consumer on this actor (ADR 0032), which holds the Store
        // weakly while it waits and ends with it.
        let (deliveries, sink) = AsyncStream<FilesystemWatcherDelivery>.makeStream(bufferingPolicy: .unbounded)
        filesystemEventSink = sink
        filesystemEventConsumer = Task { [weak self] in
            for await delivery in deliveries {
                guard let self else {
                    return
                }
                await handleFilesystemDelivery(delivery)
            }
        }
        filesystemWatcher.start { delivery in
            sink.yield(delivery)
        }
    }

    private func handleFilesystemDelivery(_ delivery: FilesystemWatcherDelivery) {
        switch delivery {
        case let .event(event):
            handleFilesystemEvent(event)
        case let .historyDone(root):
            handleHistoryDone(root)
        }
    }

    /// The root's stream has delivered every event recorded before it started. For a replay,
    /// the launch's reconciliation of the root is now the events it delivered, which are
    /// already in the root's batch: none means nothing changed while Otos was not running,
    /// and nothing is walked. The journal vouched for the whole root, so the integrity walk's
    /// clock starts here as it does at a completed walk.
    private func handleHistoryDone(_ root: LibraryRootPath) {
        guard var journal = changeJournals[root] else {
            return
        }
        let wasReplaying = journal.isReplaying
        journal.endHistory()
        changeJournals[root] = journal
        // What the history held that the catalog already reflected, for a replay and for a
        // walking root alike: the chunk `FullHistory` delivers from before the start.
        OtosLog.catalog.noticeOperation("catalog.journal", phase: "historyDone", fields: [
            "rootPath": root.rawValue, "mode": wasReplaying ? "replay" : "walk", "since": "\(journal.start)",
            "alreadyReflected": "\(journal.reflectedEvents)",
        ])
        if wasReplaying {
            lastSuccessfulFullRootScanAt[root] = .now
            if journal.replayedEvents == 0 {
                OtosLog.catalog.noticeOperation("catalog.scan", phase: "skip", fields: [
                    "rootPath": root.rawValue, "reason": ScanReason.noChanges.rawValue,
                    "directoriesRead": "0", "filesStatted": "0", "rowsWritten": "0",
                ])
            } else {
                OtosLog.catalog.noticeOperation("catalog.scan", phase: "replayed", fields: [
                    "rootPath": root.rawValue, "reason": ScanReason.events.rawValue,
                    "events": "\(journal.replayedEvents)",
                ])
            }
        }
        requestReconcile()
    }

    private var watchedRootPaths: [LibraryRootPath] {
        roots.watchedRootPaths
    }

    private func handleFilesystemEvent(_ event: FilesystemEvent) {
        let signpost = OtosSignpost.catalog.beginInterval("FilesystemEventIntake")
        defer {
            handledFilesystemEventCount += 1
            OtosSignpost.catalog.endInterval("FilesystemEventIntake", signpost)
        }

        guard let root = CatalogPath.owningRoot(for: event.path, among: roots.keys) else {
            recordFilesystemEventDrop(path: event.path, root: nil, reason: "outsideRoots")
            return
        }
        // History the catalog already reflects (behind the stored position, or behind the
        // probe a walk started after): `FullHistory` delivers it, and nothing reads it again.
        if changeJournals[root]?.reflects(eventID: event.id) == true {
            changeJournals[root]?.skipReflected()
            return
        }
        // Delivered, whatever is done with it: an event this pass drops leaves a walk owed
        // (`recordFilesystemEventDrop`), so no position is stored past it unwalked.
        changeJournals[root]?.deliver(eventID: event.id)

        let hasActiveScan = scanLeases.hasActiveFilesystemScan(for: root)
        // Arm watching as soon as the root is known and available, and never
        // drop events while a scan lease owns the root (ARC-041).
        if !filesystemWatchingArmed.contains(root) {
            if hasActiveScan || roots[root]?.availability == .available {
                filesystemWatchingArmed.insert(root)
                bumpPlanRevision(for: root)
            } else {
                recordFilesystemEventDrop(path: event.path, root: root, reason: "unarmed")
                return
            }
        }

        OtosLog.catalog.debug(
            "Filesystem event received path=\(event.path, privacy: .public) root=\(root.rawValue, privacy: .public)"
        )
        if namespaceMutationLeases[root] != nil {
            markNamespaceMutationLeaseDirty(for: root)
            bumpPlanRevision(for: root)
            filesystemEventBatches.removeValue(forKey: root)
            OtosLog.catalog.debug(
                "Filesystem reconcile deferred under reorganization lease path=\(root.rawValue, privacy: .public)"
            )
            return
        }
        filesystemEventBatches[root, default: []].append(event)
        startFilesystemEventPassIfIdle(for: root)
    }

    private func recordFilesystemEventDrop(path: String, root: LibraryRootPath?, reason: String) {
        if let root {
            changeJournals[root]?.oweWalk()
            OtosLog.catalog.debug(
                """
                Filesystem event ignored path=\(path, privacy: .public) \
                root=\(root.rawValue, privacy: .public) reason=\(reason, privacy: .public)
                """
            )
        } else {
            OtosLog.fileAccess.debug(
                "Filesystem event ignored outside library roots path=\(path, privacy: .public)"
            )
        }
        var fields: [String: String] = [
            "path": path,
            "reason": reason,
        ]
        if let root {
            fields["rootPath"] = root.rawValue
        }
        recordDiagnostic(
            operation: "catalog.filesystemEvent",
            phase: "drop",
            fields: fields
        )
    }

    private func startFilesystemEventPassIfIdle(for root: LibraryRootPath) {
        guard filesystemEventPasses[root] == nil else {
            return
        }
        let generation = (filesystemEventPassGenerations[root] ?? 0) &+ 1
        filesystemEventPassGenerations[root] = generation
        filesystemEventPasses[root] = Task { [root] in
            while !Task.isCancelled, filesystemEventBatches[root]?.isEmpty == false {
                await processFilesystemEventBatch(for: root)
            }
            // Checked and cleared with no await between them: an event that arrives
            // after this either finds the pass gone and starts one, or was taken above.
            if filesystemEventPassGenerations[root] == generation {
                filesystemEventPasses.removeValue(forKey: root)
            }
        }
    }

    /// Best-effort boundary log from synchronous Store branches. Captures only
    /// scalar strings — never catalog state or asset batches.
    private func recordDiagnostic(
        operation: String,
        phase: String,
        fields: [String: String] = [:]
    ) {
        OtosLog.catalog.notice(
            "op=\(operation, privacy: .public) phase=\(phase, privacy: .public) \(otosLogFields(fields), privacy: .public)"
        )
    }

    /// Keeps the WAL bounded after a bulk write. A log SQLite keeps resetting is reused
    /// from its start and its file stays near one write's pages; a starved one only
    /// grows, so the file's size is the fact that says so, and reading it costs a `stat`.
    /// Past `walByteBudget`, a passive checkpoint on the writer copies every frame no reader
    /// still needs into the database. It waits for no reader and holds none: a read in flight
    /// keeps its snapshot, and the frames it pins stay in the log. Once the frames are all
    /// copied and the last reader of the old snapshot has finished, the next write restarts
    /// the log from its start, and its commit truncates the file to `walByteBudget`
    /// (`journal_size_limit`, set on the writer), or to its own frames if they are more. So the file peaks at the budget plus what is
    /// written during the longest read in flight, and returns to the budget after it. A failed
    /// checkpoint is logged and leaves the log as it was; the next bulk write tries again.
    private func boundWAL(reason: String) async {
        guard databaseFileURL != nil, let walBytes = walFileSizeBytes() else {
            return
        }
        guard walBytes > walByteBudget else {
            // A file that did not grow is a log SQLite is reusing: nothing new to say.
            if walBytes > walLoggedHighWater {
                walLoggedHighWater = walBytes
                OtosLog.catalog.noticeOperation("catalog.database.wal", phase: "grew", fields: [
                    "reason": reason,
                    "walBytes": "\(walBytes)",
                    "budgetBytes": "\(walByteBudget)",
                ])
            }
            return
        }
        do {
            let dbWriter = try database()
            let start = ContinuousClock.now
            let checkpoint = try await dbWriter.writeWithoutTransaction { db in
                try db.checkpoint(.passive)
            }
            walLoggedHighWater = 0
            OtosLog.catalog.noticeOperation("catalog.database.wal", phase: "checkpointed", fields: [
                "reason": reason,
                "walBytesBefore": "\(walBytes)",
                "walBytes": "\(walFileSizeBytes() ?? -1)",
                "walFrames": "\(checkpoint.walFrameCount)",
                "copiedFrames": "\(checkpoint.checkpointedFrameCount)",
                "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
            ])
        } catch {
            OtosLog.catalog.errorOperation("catalog.database.wal", phase: "checkpointFailed", fields: [
                "reason": reason,
                "walBytes": "\(walBytes)",
                "error": String(describing: error),
            ])
        }
    }

    private func walFileSizeBytes() -> Int64? {
        Self.walFileSizeBytes(of: databaseFileURL)
    }

    /// The size of the write-ahead log beside `file`: 0 when there is none, nil in memory
    /// or when its size cannot be read.
    static func walFileSizeBytes(of file: URL?) -> Int64? {
        guard let file else {
            return nil
        }
        let walPath = file.path(percentEncoded: false) + "-wal"
        guard FileManager.default.fileExists(atPath: walPath) else {
            return 0
        }
        guard let size = try? FileManager.default.attributesOfItem(atPath: walPath)[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    private func processFilesystemEventBatch(for root: LibraryRootPath) async {
        let signpost = OtosSignpost.catalog.beginInterval("FilesystemEventBatch")
        defer {
            OtosSignpost.catalog.endInterval("FilesystemEventBatch", signpost)
        }

        let pendingEvents = filesystemEventBatches.removeValue(forKey: root) ?? []
        knownMaterializationSuppression.pruneExpired()
        let activeSuppression = knownMaterializationSuppression.activeExpiries()
        let now = ContinuousClock.now
        var keptEvents: [FilesystemEvent] = []
        keptEvents.reserveCapacity(pendingEvents.count)
        var suppressedCount = 0
        var stagingSuppressedCount = 0
        for event in pendingEvents {
            let flags = FilesystemEventFlags(event: event)
            let relativePath = CatalogPath.relativePath(rootPath: root, absolutePath: event.path)
            if let relativePath,
               KnownMaterializationSuppressionPolicy.isSuppressible(
                   flags: flags,
                   id: MediaAssetID(libraryRootPath: root, relativePath: relativePath),
                   active: activeSuppression,
                   now: now
               )
            {
                suppressedCount += 1
                continue
            }
            // Otos's own import staging files (`.otos-import-staging`, written into the
            // watched destination root while the import executor copies) are never
            // catalogued and must not record namespace mutations, bump occupancy, or
            // fire reconcile/replan churn.
            if let relativePath, relativePath.rawValue.hasSuffix(MediaImportExecutor.destinationTempSuffix) {
                stagingSuppressedCount += 1
                continue
            }
            keptEvents.append(event)
        }
        if suppressedCount > 0 {
            OtosLog.catalog.notice(
                "op=catalog.materializationEvent phase=suppress rootPath=\(root.rawValue, privacy: .public) count=\(suppressedCount, privacy: .public)"
            )
        }
        if stagingSuppressedCount > 0 {
            OtosLog.catalog.notice(
                "op=catalog.stagingEvent phase=suppress rootPath=\(root.rawValue, privacy: .public) count=\(stagingSuppressedCount, privacy: .public)"
            )
        }

        let decision = FilesystemReconciler.decide(
            events: keptEvents,
            root: root,
            rootExists: roots[root] != nil,
            isArmed: filesystemWatchingArmed.contains(root),
            isAvailable: rootIsAvailable(root)
        )
        classifiedFilesystemEventCount += pendingEvents.count

        switch decision {
        case let .drop(reason):
            changeJournals[root]?.oweWalk()
            await recordFilesystemEventDrop(root: root, reason: reason)
        case .noop:
            break
        case let .accumulate(scopes):
            var fileCount = 0
            var subtreeCount = 0
            var rootCount = 0
            for dirt in scopes {
                switch dirt.scope {
                case .root:
                    recordIndependentNamespaceMutation(root: root, scope: .root, rootReason: dirt.rootReason)
                    rootCount += dirt.eventCount
                case let .subtree(path):
                    recordIndependentNamespaceMutation(root: root, scope: .subtree(path))
                    subtreeCount += dirt.eventCount
                case let .file(path):
                    recordIndependentNamespaceMutation(
                        root: root,
                        scope: .file(path),
                        fileAction: dirt.fileAction ?? .upsert
                    )
                    fileCount += dirt.eventCount
                }
            }
            OtosLog.catalog.notice(
                "op=catalog.filesystemEvent phase=classify rootPath=\(root.rawValue, privacy: .public) eventCount=\(keptEvents.count, privacy: .public) file=\(fileCount, privacy: .public) subtree=\(subtreeCount, privacy: .public) root=\(rootCount, privacy: .public) suppressed=\(suppressedCount, privacy: .public)"
            )
            requestReconcile()
        }
    }

    /// Drains typed dirty scopes for one root.
    /// File dirt may settle while another root holds the global scan lease.
    /// Subtree/root dirt requires the global lease to be free. Loops so dirt that
    /// arrives mid-await is not lost.
    private func drainDirtyReconcile(for root: LibraryRootPath) async {
        while true {
            guard roots[root] != nil else {
                filesystemDirty.removeValue(forKey: root)
                return
            }
            guard namespaceMutationLeases[root] == nil else {
                return
            }
            guard !scanLeases.hasActiveFilesystemScan(for: root) else {
                return
            }
            guard filesystemWatchingArmed.contains(root), rootIsAvailable(root) else {
                return
            }
            guard var accumulator = filesystemDirty[root], !accumulator.isEmpty else {
                filesystemDirty.removeValue(forKey: root)
                return
            }
            let needsLease = accumulator.isRootDirty || !accumulator.subtrees.isEmpty
            let lane = scanLane(for: root)
            if needsLease, scanLeases.isLaneBusy(lane) || scanTasks[lane] != nil {
                return
            }
            let dirt = accumulator.take()
            filesystemDirty[root] = accumulator

            if dirt.isRootDirty {
                OtosLog.catalog.info("Filesystem rescan scheduled path=\(root.rawValue, privacy: .public)")
                OtosLog.catalog.notice(
                    "op=catalog.filesystemEvent phase=schedule mode=fullRoot rootPath=\(root.rawValue, privacy: .public) eventCount=\(dirt.fileCount + dirt.subtreeCount + 1, privacy: .public)"
                )
                enqueueScans([root], reason: dirt.rootReason ?? .events)
                return
            }

            if !dirt.subtrees.isEmpty {
                await runScopedReconcile(root: root, dirt: dirt)
                continue
            }

            await reconcileFileDirt(root: root, files: dirt.files)
        }
    }

    /// Reconciles each dirty file from what the filesystem says now. The dirt was taken
    /// at the root's current epoch; a path whose write finds the root changed since is
    /// put back, with every path not yet reached, and the next pass observes it again.
    private func reconcileFileDirt(
        root: LibraryRootPath,
        files: [MediaRelativePath: SingleFileReconcileOperation]
    ) async {
        guard let rootState = roots[root] else {
            return
        }
        let rootRowID = rootState.rowID
        let witness = ReconcileWitness(root: root, epoch: rootState.namespaceMutationEpoch)
        let started = ContinuousClock.now
        var changedCount = 0
        var changed: CatalogChangedFacts = []
        var deferredCount = 0
        let ordered = files.keys.sorted(by: { $0.rawValue < $1.rawValue })
        for (index, path) in ordered.enumerated() {
            let result = await reconcileFile(
                path,
                action: files[path] ?? .upsert,
                root: root,
                rootRowID: rootRowID,
                witness: witness
            )
            if case let .changed(facts) = result {
                changedCount += 1
                changed.formUnion(facts)
            }
            if case .deferred = result {
                var dirty = filesystemDirty[root] ?? FilesystemDirtyAccumulator()
                for remaining in ordered[index...] {
                    dirty.insert(.file(remaining), fileAction: files[remaining] ?? .upsert)
                }
                filesystemDirty[root] = dirty
                deferredCount = ordered.count - index
                break
            }
        }
        if changedCount > 0 {
            bumpNamespaceRevision(for: root)
            notifyCatalogChanged(.changed(changed))
        }
        let totalMs = DiagnosticsTiming.milliseconds(since: started)
        OtosLog.catalog.notice(
            "op=catalog.reconcile phase=finish mode=file rootPath=\(root.rawValue, privacy: .public) scopeCount=\(files.count, privacy: .public) changed=\(changedCount, privacy: .public) deferred=\(deferredCount, privacy: .public) totalMs=\(totalMs, privacy: .public)"
        )
    }

    private func runScopedReconcile(root: LibraryRootPath, dirt: FilesystemDirtyAccumulator) async {
        guard let rootRowID = roots[root]?.rowID else {
            return
        }
        let scan = scanLeases.makeActiveScan(
            rootPath: root,
            rootRowID: rootRowID,
            startNamespaceMutationEpoch: roots[root]?.namespaceMutationEpoch ?? 0
        )
        let lane = scanLane(for: root)
        scanLeases.beginFilesystemScan(scan, lane: lane)
        filesystemWatchingArmed.insert(root)
        watchRoot(root)
        // The root's own state moved (its order, a scan or listing starting or ending);
        // no row did, and the rows a scan changed or deleted were announced with them.
        notifyCatalogChanged(.changed(.membership, rows: .none))
        OtosLog.catalog.info(
            "Catalog scoped reconcile started path=\(root.rawValue, privacy: .public) subtrees=\(dirt.subtreeCount, privacy: .public)"
        )
        recordDiagnostic(
            operation: "catalog.reconcile",
            phase: "start",
            fields: [
                "rootPath": root.rawValue,
                "mode": "subtree",
                "subtreeCount": "\(dirt.subtreeCount)",
                "fileCount": "\(dirt.fileCount)",
            ]
        )

        // The directory walk must not run on this actor: a stored scanner closure and
        // `LiveCatalogScanner.scan` are `nonisolated async`, which under
        // `NonisolatedNonsendingByDefault` runs on the caller's actor. A detached task is the
        // same mechanism a full scan uses; every Store mutation below hops back through an
        // actor method that revalidates the scan lease first.
        scanTasks[lane] = Task.detached(priority: lane.taskPriority) { [scanner, scanCadence] in
            do {
                var totalObserved = 0
                var totalDeleted = 0
                var catalogChanged = false
                for subtree in dirt.subtrees.sorted(by: { $0.rawValue < $1.rawValue }) {
                    try Task.checkCancellation()
                    guard await self.owns(scan) else {
                        return
                    }
                    let baseline = try await self.scanBaseline(scan: scan, underSubtree: subtree)
                    let tally = ScanWriteTally()
                    let observation = try await scanner.scanSubtree(root, subtree, scanCadence) { batch in
                        try await self.recordScannedBatch(
                            baseline.filesNeedingWrite(batch), observedCount: batch.count, tally: tally, scan: scan
                        )
                    }
                    totalObserved += observation.mediaPaths.count
                    let deleted = try await self.reconcileMissingAssets(
                        scan: scan,
                        observedPaths: observation.mediaPaths,
                        underSubtree: subtree
                    )
                    totalDeleted += deleted
                    let companionChanged = if tally.rowsWritten == 0, deleted == 0,
                                              baseline.companionsMatch(observation.companions)
                    {
                        false
                    } else {
                        try await self.applyAndReconcileCompanions(
                            scan: scan,
                            companions: observation.companions,
                            underSubtree: subtree
                        )
                    }
                    if deleted > 0 || companionChanged {
                        catalogChanged = true
                    }
                }
                await self.completeScopedReconcile(
                    scan: scan,
                    root: root,
                    dirt: dirt,
                    summary: ScopedReconcileSummary(
                        observed: totalObserved,
                        deleted: totalDeleted,
                        catalogChanged: catalogChanged
                    )
                )
            } catch is CancellationError {
                await self.endScopedReconcile(scan: scan, root: root, dirt: dirt, failure: nil)
            } catch {
                await self.endScopedReconcile(scan: scan, root: root, dirt: dirt, failure: error)
            }
        }
    }

    private struct ScopedReconcileSummary {
        let observed: Int
        let deleted: Int
        let catalogChanged: Bool
    }

    /// The post-walk half of a scoped reconcile, as one actor method so the lease check, the
    /// revision bump and the lease release cannot be interleaved by another message.
    private func completeScopedReconcile(
        scan: ActiveScan,
        root: LibraryRootPath,
        dirt: FilesystemDirtyAccumulator,
        summary: ScopedReconcileSummary
    ) async {
        guard owns(scan) else {
            return
        }
        if !dirt.files.isEmpty {
            await reconcileFileDirt(root: root, files: dirt.files)
        }
        if summary.catalogChanged {
            bumpNamespaceRevision(for: root)
        } else {
            bumpPlanRevision(for: root)
        }
        OtosLog.catalog.notice(
            "op=catalog.reconcile phase=finish mode=subtree rootPath=\(root.rawValue, privacy: .public) observed=\(summary.observed, privacy: .public) deleted=\(summary.deleted, privacy: .public)"
        )
        scopedReconcileFinished(scan: scan)
    }

    /// A scoped reconcile that did not finish. Cancellation hands the taken scopes back as
    /// they were; any other failure is an incomplete enumeration, which must not drop them:
    /// it escalates to the root so the next lease drains conservatively.
    private func endScopedReconcile(
        scan: ActiveScan,
        root: LibraryRootPath,
        dirt: FilesystemDirtyAccumulator,
        failure: Error?
    ) async {
        if let failure {
            restoreScopedDirt(root: root, dirt: dirt, escalateToRoot: true)
            await scanFailed(scan: scan, error: failure)
        } else {
            restoreScopedDirt(root: root, dirt: dirt)
            await scanCancelled(scan: scan)
        }
    }

    private func restoreScopedDirt(
        root: LibraryRootPath,
        dirt: FilesystemDirtyAccumulator,
        escalateToRoot: Bool = false
    ) {
        var accumulator = filesystemDirty[root] ?? FilesystemDirtyAccumulator()
        if escalateToRoot {
            accumulator.insertRoot(reason: .events)
        } else {
            for subtree in dirt.subtrees {
                accumulator.insertSubtree(subtree)
            }
            for (path, action) in dirt.files {
                accumulator.insertFile(path, action: action)
            }
        }
        filesystemDirty[root] = accumulator
    }

    private func scopedReconcileFinished(scan: ActiveScan) {
        clearCurrentScan(scan, armFilesystemWatching: true)
    }

    private func startIntegrityScanSchedulerIfNeeded() {
        guard integrityScanTask == nil else {
            return
        }
        // The loop holds the Store weakly across each 15-minute wait and ends once the
        // Store is gone, rather than outliving it as an idle sleeper.
        integrityScanTask = Task { [weak self] in
            while !Task.isCancelled {
                // time: schedule — the 24 h integrity scan, checked every 15 minutes
                try? await Task.sleep(for: CatalogStore.integrityScanPollInterval)
                guard !Task.isCancelled, let self else {
                    return
                }
                await scheduleOverdueIntegrityScans()
            }
        }
    }

    private func scheduleOverdueIntegrityScans() {
        let now = ContinuousClock.now
        for path in roots.keys {
            guard roots[path]?.root.kind.isUserChosenFolder == true else {
                continue
            }
            guard rootIsAvailable(path), filesystemWatchingArmed.contains(path) else {
                continue
            }
            guard namespaceMutationLeases[path] == nil else {
                continue
            }
            if scanLeases.hasActiveFilesystemScan(for: path)
                || scanLeases.pendingScanPaths.contains(path)
            {
                continue
            }
            if let accumulator = filesystemDirty[path], accumulator.isRootDirty {
                continue
            }
            // A root never fully scanned in this process is overdue.
            let age = lastSuccessfulFullRootScanAt[path].map { $0.duration(to: now) }
            if let age, age < Self.integrityScanInterval {
                continue
            }
            filesystemDirty[path, default: FilesystemDirtyAccumulator()].insertRoot(reason: .integrity)
            OtosLog.catalog.notice(
                "op=catalog.integrityScan phase=schedule rootPath=\(path.rawValue, privacy: .public) successfulScanAgeSec=\(age.map { "\(Int(DiagnosticsTiming.seconds($0)))" } ?? "never", privacy: .public)"
            )
            requestReconcile()
        }
    }

    /// What one file reconcile did. `deferred`: the root changed (or a namespace owner
    /// took it) after this reconcile observed the file, so the observation may be stale
    /// and nothing was written; the path stays dirty for the next pass. `changed` names the
    /// kinds of fact the write changed.
    private enum FileReconcileResult {
        case changed(CatalogChangedFacts)
        case unchanged
        case deferred
    }

    /// A dirt-driven reconcile writes only while the observation it acts on is still the
    /// latest word on the root: no independent mutation since (`epoch`) and no namespace
    /// owner holding it. Checked synchronously right before each write is submitted, so a
    /// mutation's own write, submitted later, is ordered after this one by the writer.
    private struct ReconcileWitness {
        let root: LibraryRootPath
        let epoch: UInt64
    }

    private func isCurrent(_ witness: ReconcileWitness?) -> Bool {
        guard let witness else { return true }
        return roots[witness.root]?.namespaceMutationEpoch == witness.epoch
            && namespaceMutationLeases[witness.root] == nil
    }

    /// Reconciles one path from a single observation of it. An absent file is deleted
    /// from the catalog only when the dirt said it may be (`deleteIfMissing`); a present
    /// file that is not catalog media leaves the catalog; catalog media is upserted.
    /// A failed observation writes nothing and is logged; the next event or scan of the
    /// path observes it again.
    private func reconcileFile(
        _ relativePath: MediaRelativePath,
        action: SingleFileReconcileOperation,
        root: LibraryRootPath,
        rootRowID: Int64,
        witness: ReconcileWitness?
    ) async -> FileReconcileResult {
        let fileURL = root.url.appendingPathComponent(relativePath.rawValue, isDirectory: false)
        let observation: CatalogFileObservation
        do {
            observation = try await scanner.observeFile(fileURL, root)
        } catch {
            // Not applied: no position is stored past this event in this session, so the
            // next launch replays it.
            changeJournals[root]?.oweWalk()
            OtosLog.catalog.errorOperation("catalog.reconcile", phase: "observeFailed", fields: [
                "rootPath": root.rawValue,
                "path": relativePath.rawValue,
                "error": String(describing: error),
            ])
            return .unchanged
        }
        switch observation {
        case .absent:
            guard action == .deleteIfMissing else {
                return .unchanged
            }
            return await deleteCatalogedPath(relativePath: relativePath, rootRowID: rootRowID, witness: witness)
        case .present(nil):
            return await deleteCatalogedPath(relativePath: relativePath, rootRowID: rootRowID, witness: witness)
        case let .present(observed?):
            return await upsertObservedFile(observed, at: relativePath, root: root, rootRowID: rootRowID, witness: witness)
        }
    }

    private func upsertObservedFile(
        _ observed: CatalogScannedFileReader.ObservedItem,
        at relativePath: MediaRelativePath,
        root: LibraryRootPath,
        rootRowID: Int64,
        witness: ReconcileWitness?
    ) async -> FileReconcileResult {
        let dbQueue: CatalogWriter
        do {
            dbQueue = try database()
        } catch {
            OtosLog.catalog.errorOperation("catalog.reconcile", phase: "upsertFailed", fields: [
                "rootPath": root.rawValue,
                "path": relativePath.rawValue,
                "error": String(describing: error),
            ])
            return .unchanged
        }

        do {
            let rootCapabilities = roots[root]?.capabilities ?? .unknown
            guard isCurrent(witness) else {
                return .deferred
            }
            let (changed, holdEnded) = try await dbQueue.write { db -> (CatalogChangedFacts, Bool) in
                switch observed {
                case let .media(scannedFile):
                    // A path that was a companion and became media must leave the
                    // companion table so identity stays exclusive.
                    let companionDeleted = try Self.deleteCompanionRow(
                        rootRowID: rootRowID,
                        relativePath: scannedFile.relativePath,
                        db: db
                    )
                    let mediaChanged = try Self.upsertScannedFile(
                        scannedFile,
                        libraryRootPath: root,
                        libraryRootID: rootRowID,
                        capabilities: rootCapabilities,
                        db: db
                    )
                    let pairingChanged = try Self.repairCompanionsInDirectory(
                        of: scannedFile.relativePath,
                        libraryRootID: rootRowID,
                        capabilities: rootCapabilities,
                        db: db
                    )
                    // An event on a file is what reports its bytes becoming local: the
                    // provider's download changes no fact the upsert compares, so the event
                    // itself ends the file's digest hold (ADR 0009 §12). A hold whose facts
                    // moved was ended by the upsert.
                    let holdEnded = try EnrichmentClaimGateway.endDigestHold(
                        libraryRootID: rootRowID, relativePath: scannedFile.relativePath, db: db
                    )
                    // Companions are which files a row lists with it (`membership`).
                    let companionFacts: CatalogChangedFacts = companionDeleted || pairingChanged ? .membership : []
                    return (mediaChanged.facts.union(companionFacts), holdEnded)
                case let .companion(companion):
                    // A path that was media and became a companion must leave media.
                    let mediaDeleted = try Self.deleteAssetRow(
                        rootRowID: rootRowID,
                        relativePath: companion.relativePath,
                        db: db
                    ).deleted
                    let directoryKey = MediaCompanionPairing.directoryKey(of: companion.relativePath)
                    let primaries = try Self.fetchPrimariesInDirectory(
                        libraryRootID: rootRowID,
                        directoryKey: directoryKey,
                        db: db
                    )
                    let paired = MediaCompanionPairing.pair(
                        companions: [companion],
                        primaries: primaries,
                        capabilities: rootCapabilities
                    )
                    var companionChanged = false
                    for item in paired {
                        companionChanged = try Self.upsertCompanion(
                            item,
                            libraryRootID: rootRowID,
                            capabilities: rootCapabilities,
                            db: db
                        ) || companionChanged
                    }
                    var facts: CatalogChangedFacts = mediaDeleted ? .presence : []
                    if companionChanged {
                        facts.insert(.membership)
                    }
                    return (facts, false)
                }
            }
            if holdEnded {
                digestHoldEnded(MediaAssetID(libraryRootPath: root, relativePath: relativePath), reason: "fileEvent")
            }
            return changed.isEmpty ? .unchanged : .changed(changed)
        } catch {
            OtosLog.catalog.errorOperation("catalog.reconcile", phase: "upsertFailed", fields: [
                "rootPath": root.rawValue,
                "path": relativePath.rawValue,
                "error": String(describing: error),
            ])
            return .unchanged
        }
    }

    private func deleteCatalogedPath(
        relativePath: MediaRelativePath,
        rootRowID: Int64,
        witness: ReconcileWitness?
    ) async -> FileReconcileResult {
        let dbQueue: CatalogWriter
        do {
            dbQueue = try database()
        } catch {
            OtosLog.catalog.errorOperation("catalog.reconcile", phase: "deleteFailed", fields: [
                "path": relativePath.rawValue,
                "error": String(describing: error),
            ])
            return .unchanged
        }

        let deletionTarget: CatalogedFileDeletionTarget?
        do {
            deletionTarget = try await reader(for: backgroundReads.lane).readFreeingConnection { db in
                try Self.catalogedFileDeletionTarget(relativePath: relativePath, rootRowID: rootRowID, db: db)
            }
            let capabilities = roots.values.first(where: { $0.rowID == rootRowID })?.capabilities
                ?? .unknown
            guard isCurrent(witness) else {
                return .deferred
            }
            // Its file is in the system Trash, not proven deleted: the row stays until a
            // scan finds the Trash no longer holds it.
            if Self.isHeldInTrash(trashPath: deletionTarget?.trashPath) {
                return .unchanged
            }
            let derivedFolder = derivedFolder
            let derivedImagePaths = deletionTarget?.derivedImagePaths ?? []
            let deleted = try await dbQueue.write { db -> DerivedRemoval? in
                guard try Self.purgeGonePath(
                    relativePath: relativePath,
                    rootRowID: rootRowID,
                    capabilities: capabilities,
                    db: db
                ) else {
                    return nil
                }
                return try derivedFolder?.unname(derivedImagePaths, db: db) ?? DerivedRemoval.nothing
            }
            guard let deleted else {
                return .unchanged
            }
            await deleted.perform()
        } catch {
            OtosLog.catalog.errorOperation("catalog.reconcile", phase: "deleteFailed", fields: [
                "path": relativePath.rawValue,
                "error": String(describing: error),
            ])
            return .unchanged
        }
        return .changed(.presence)
    }

    private func recordFilesystemEventDrop(root: LibraryRootPath, reason: String) async {
        OtosLog.catalog.debug(
            "Filesystem rescan dropped path=\(root.rawValue, privacy: .public) reason=\(reason, privacy: .public)"
        )
        OtosLog.catalog.notice(
            "op=catalog.filesystemEvent phase=drop rootPath=\(root.rawValue, privacy: .public) reason=\(reason, privacy: .public)"
        )
    }

    private func cancelFilesystemEventPass(for root: LibraryRootPath) {
        filesystemEventPasses[root]?.cancel()
        filesystemEventPasses.removeValue(forKey: root)
        filesystemEventPassGenerations[root] = (filesystemEventPassGenerations[root] ?? 0) &+ 1
        filesystemEventBatches.removeValue(forKey: root)
        filesystemDirty.removeValue(forKey: root)
    }

    private func cancelAllFilesystemEventPasses() {
        for task in filesystemEventPasses.values {
            task.cancel()
        }
        filesystemEventPasses.removeAll()
        for root in filesystemEventPassGenerations.keys {
            filesystemEventPassGenerations[root] = (filesystemEventPassGenerations[root] ?? 0) &+ 1
        }
        filesystemEventBatches.removeAll()
        filesystemDirty.removeAll()
    }

    private func owns(_ scan: ActiveScan) -> Bool {
        scanLeases.owns(scan) { path, rowID in
            roots.ownsLease(rootPath: path, rootRowID: rowID)
        }
    }

    private func scanCanDelete(_ scan: ActiveScan) -> Bool {
        guard owns(scan) else {
            return false
        }
        return roots[scan.rootPath]?.namespaceMutationEpoch == scan.startNamespaceMutationEpoch
    }

    private func recordIgnoredStaleCallback(_ scan: ActiveScan, callback: String) async {
        OtosLog.catalog.debug(
            """
            Ignoring stale scan callback path=\(scan.rootPath.rawValue, privacy: .public) \
            callback=\(callback, privacy: .public)
            """
        )
        OtosLog.catalog.notice(
            "op=catalog.scan.staleCallback phase=ignored rootPath=\(scan.rootPath.rawValue, privacy: .public) rootRowID=\(scan.rootRowID, privacy: .public) callback=\(callback, privacy: .public)"
        )
    }
}

/// Durable media-operation transitions remain actor-isolated with catalog truth.
/// Filesystem execution and recovery sequencing belong to their operation owners.
extension CatalogStore {
    // MARK: - Import journal / settlement

    func importBatchAssetCount(_ batch: ImportBatchID, lane: CatalogReadLane) async throws -> Int {
        try await reader(for: lane).readFreeingConnection { db in
            try Int.fetchOne(
                db,
                sql: AssetRowSQL.importBatchCountSQL,
                arguments: [batch.unixMilliseconds]
            ) ?? 0
        }
    }

    func activeImportOperations(lane: CatalogReadLane) async throws -> [ActiveFileOperation] {
        try await reader(for: lane).readFreeingConnection { db in
            try Self.fetchAllActiveFileOperations(db: db)
        }
    }

    func activeSourceEraseOperations(lane: CatalogReadLane) async throws -> [ActiveSourceEraseOperation] {
        try await reader(for: lane).readFreeingConnection { db in
            try Self.fetchAllActiveSourceErases(db: db)
        }
    }

    func beginSourceEraseOperation(_ operation: ActiveSourceEraseOperation) async throws {
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try Self.insertActiveSourceErase(operation, db: db)
        }
    }

    /// Settles an erase whose file the source no longer holds: the journal row and the
    /// item's catalog row go in one durable transaction, with its derived images after.
    /// The erase is the proof of deletion (ADR 0008), so the catalog follows the card as
    /// each file goes rather than waiting for a rescan the user's Eject usually cancels.
    /// A root that is no longer registered has no row to remove; its journal still clears.
    func recordSourceFileErased(_ operation: ActiveSourceEraseOperation) async throws {
        let dbWriter = try database()
        let rootState = roots[operation.sourceRootPath]
        let derivedFolder = derivedFolder
        let erased = try Self.writeWithJournalDurability(dbWriter) { db -> (paths: [String], removal: DerivedRemoval)? in
            try Self.deleteActiveSourceErase(key: operation.key, db: db)
            guard let rootState else {
                return nil
            }
            let target = try Self.catalogedFileDeletionTarget(
                relativePath: operation.sourceRelativePath,
                rootRowID: rootState.rowID,
                db: db
            )
            let removed = try Self.purgeGonePath(
                relativePath: operation.sourceRelativePath,
                rootRowID: rootState.rowID,
                capabilities: rootState.capabilities,
                db: db
            )
            guard removed else {
                return nil
            }
            let paths = target?.derivedImagePaths ?? []
            return try (paths, derivedFolder?.unname(paths, db: db) ?? .nothing)
        }
        guard let erased else {
            return
        }
        let derivedImagePaths = erased.paths
        OtosLog.catalog.noticeOperation("import.erase.catalog", phase: "removed", fields: [
            "rootPath": operation.sourceRootPath.rawValue,
            "relativePath": operation.sourceRelativePath.rawValue,
            "derivedImages": "\(derivedImagePaths.count)",
        ])
        bumpNamespaceRevision(for: operation.sourceRootPath)
        // The erased file's row and its companion went (`purgeGonePath`); the Live Photo
        // partner it leaves is not named.
        notifyCatalogChanged(.changed(.presence))
        // The write above runs on the actor, so the row's removal is applied with it, before
        // this first suspension; the files go after, off the actor.
        await erased.removal.perform()
    }

    func beginImportOperation(_ operation: ActiveFileOperation) async throws {
        try importJournalFailure?(.begin)
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try Self.insertActiveFileOperation(operation, db: db)
        }
    }

    func recordImportOperationProgress(_ operation: ActiveFileOperation) async throws {
        try importJournalFailure?(.progress(operation.phase))
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try Self.updateActiveFileOperation(operation, db: db)
        }
    }

    /// The entry ended without publishing and a staging file it journaled could not be
    /// removed: the row stays, marked so startup recovery removes the file and the row,
    /// and so nothing reads it as work in flight.
    func markImportOperationAbandoned(key: ActiveFileOperationKey) async throws {
        try importJournalFailure?(.progress(.abandoned))
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try db.execute(
                sql: ImportJournalSQL.setPhaseSQL,
                arguments: [ActiveFileOperationPhase.abandoned.rawValue, Date().timeIntervalSince1970, key.rawValue]
            )
            guard db.changesCount == 1 else {
                throw CatalogStoreError.importOperationMissing(key)
            }
        }
    }

    func abandonImportOperation(key: ActiveFileOperationKey) async throws {
        try importJournalFailure?(.abandon)
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try Self.deleteActiveFileOperation(key: key, db: db)
        }
    }

    /// Settles a published copy: its row, its companions, and each of its products (ADR
    /// 0009). The copy is the source file, byte for byte, so each of the source's products
    /// current for the bytes the import copied is the copy's — the same freshness rule
    /// enrichment applies to every row. Failing a rendering, the source's thumbnail is
    /// carried as a provisional one. Nothing is made here: a product the copy still lacks
    /// stays owed, and the copy is offered to enrichment ahead of other background work
    /// while its bytes are local (`localBytesAwaitingProducts`).
    @discardableResult
    func settleImportedAsset(
        operation: ActiveFileOperation,
        byteSize: Int64,
        contentModifiedAt: Date,
        companions: [MediaCompanion],
        lane: CatalogReadLane
    ) async throws -> ImportProductsResult {
        guard let rootRowID = roots[operation.destinationRootPath]?.rowID else {
            throw CatalogStoreError.catalogUnavailable
        }
        recordIndependentNamespaceMutation(
            root: operation.destinationRootPath,
            scope: .file(operation.destinationRelativePath),
            fileAction: .upsert
        )
        let dbWriter = try database()
        let sourceRootID = roots[operation.sourceRootPath]?.rowID
        var overlay: ReusableEnrichmentOverlay?
        if let sourceRootID {
            overlay = try await reader(for: lane).readFreeingConnection { db in
                try Self.fetchReusableEnrichmentOverlay(
                    sourceRootID: sourceRootID,
                    sourceRelativePath: operation.sourceRelativePath,
                    db: db
                )
            }
        }
        let sourceMTime = MediaAsset.mtimeSeconds(operation.sourceModifiedAt)
        let destinationID = MediaAssetID(
            libraryRootPath: operation.destinationRootPath,
            relativePath: operation.destinationRelativePath
        )

        var metadata: EnrichedMetadata?
        var metadataOrigin = ImportProductOrigin.owed
        if let overlay, overlay.metadataCurrent(size: operation.sourceByteSize, mtimeSeconds: sourceMTime) {
            metadata = overlay.metadata
            metadataOrigin = .reused
        }

        // The rendering's images, staged for the copy: copies of the source's.
        var rendering: StagedRendering?
        var renderingOrigin = ImportProductOrigin.owed
        if let overlay, overlay.renderingCurrent(size: operation.sourceByteSize, mtimeSeconds: sourceMTime),
           let copied = stageCopies(of: overlay, for: destinationID, preview: true)
        {
            rendering = StagedRendering(
                thumbnail: copied.thumbnail, preview: copied.preview, stamped: true, renderedRevision: overlay.renderedRevision
            )
            renderingOrigin = .reused
        }
        if renderingOrigin == .owed, let overlay, overlay.thumbnailPath != nil,
           let copied = stageCopies(of: overlay, for: destinationID, preview: false)
        {
            rendering = StagedRendering(thumbnail: copied.thumbnail, preview: nil, stamped: false, renderedRevision: 0)
            renderingOrigin = .provisional
        }

        let derivedFolder = derivedFolder
        let upsert = try Self.writeWithJournalDurability(dbWriter) { db in
            var landedRendering: LandedRendering?
            if let rendering {
                let staged = [rendering.thumbnail, rendering.preview].compactMap(\.self)
                do {
                    // Staged images exist only where the catalog has a derived-image
                    // directory; a rendering with no images (nothing could be drawn) needs none.
                    let promote: (StagedDerivedImage) throws -> String = { image in
                        guard let derivedFolder else {
                            throw CatalogStoreError.catalogUnavailable
                        }
                        return try derivedFolder.promote(image, db: db)
                    }
                    let thumbnailPath = try rendering.thumbnail.map(promote)
                    let previewPath = try rendering.preview.map(promote)
                    landedRendering = LandedRendering(
                        thumbnailPath: thumbnailPath,
                        previewPath: previewPath,
                        stamped: rendering.stamped,
                        renderedRevision: rendering.renderedRevision
                    )
                } catch {
                    if let derivedFolder {
                        for image in staged {
                            ThumbnailStore.discard(image, in: derivedFolder.directory)
                        }
                    }
                    OtosLog.thumbnails.errorOperation("mediaOperation.settle", phase: "renderingPromotionFailed", fields: [
                        "destination": operation.destinationRelativePath.rawValue,
                        "error": String(describing: error),
                    ])
                    renderingOrigin = .owed
                }
            }
            let upsert = try Self.settleImportedAsset(LandedImport(
                operation: operation,
                destinationRootID: rootRowID,
                sourceRootID: sourceRootID,
                byteSize: byteSize,
                contentModifiedAt: contentModifiedAt,
                companions: companions,
                metadata: metadata,
                rendering: landedRendering
            ), db: db)
            try Self.deleteActiveFileOperation(key: operation.operationKey, db: db)
            return upsert
        }
        if metadataOrigin != .reused || renderingOrigin != .reused {
            localBytesAwaitingProducts.append(destinationID)
        }
        _ = bumpNamespaceRevision(for: operation.destinationRootPath)
        // A row that moved to the copy's path left one this write does not name.
        notifyCatalogChanged(.changed(
            CatalogChangedFacts.settledImport.union(upsert.facts),
            rows: upsert == .moved ? .unnamed : .rows([destinationID])
        ))
        requestReconcile()
        OtosLog.catalog.noticeOperation("mediaOperation.settle", phase: "finish", fields: [
            "destination": operation.destinationRelativePath.rawValue,
            "batch": "\(operation.importBatch.unixMilliseconds)",
            "metadata": metadataOrigin.rawValue,
            "rendering": renderingOrigin.rawValue,
        ])
        return ImportProductsResult(metadata: metadataOrigin, rendering: renderingOrigin)
    }

    /// Stages copies of the source's thumbnail and, when `preview`, its preview under the
    /// copy's names; nil when a copy fails, after discarding what it staged, or when there
    /// are files to copy and no derived-image directory to copy them in.
    private func stageCopies(
        of overlay: ReusableEnrichmentOverlay,
        for destinationID: MediaAssetID,
        preview: Bool
    ) -> (thumbnail: StagedDerivedImage?, preview: StagedDerivedImage?)? {
        let sourcePreview = preview ? overlay.previewPath : nil
        guard overlay.thumbnailPath != nil || sourcePreview != nil else {
            return (nil, nil)
        }
        guard let thumbnailDirectory else {
            return nil
        }
        var stagedThumbnail: StagedDerivedImage?
        do {
            stagedThumbnail = try overlay.thumbnailPath.map {
                try ThumbnailStore.stageCopy(
                    sourceRelativeName: $0,
                    destinationRelativeName: ThumbnailStore.relativeName(for: destinationID),
                    in: thumbnailDirectory
                )
            }
            let stagedPreview = try sourcePreview.map {
                try ThumbnailStore.stageCopy(
                    sourceRelativeName: $0,
                    destinationRelativeName: ThumbnailStore.previewRelativeName(for: destinationID),
                    in: thumbnailDirectory
                )
            }
            return (stagedThumbnail, stagedPreview)
        } catch {
            if let stagedThumbnail {
                ThumbnailStore.discard(stagedThumbnail, in: thumbnailDirectory)
            }
            OtosLog.thumbnails.errorOperation("mediaOperation.settle", phase: "derivedImageCopyFailed", fields: [
                "destination": destinationID.relativePath.rawValue,
                "error": String(describing: error),
            ])
            return nil
        }
    }

    func recordForeignOccupant(root: LibraryRootPath, relativePath: MediaRelativePath) async {
        recordIndependentNamespaceMutation(root: root, scope: .file(relativePath), fileAction: .upsert)
        OtosLog.catalog.notice(
            "op=mediaOperation.publish phase=foreignOccupant rootPath=\(root.rawValue, privacy: .public) relative=\(relativePath.rawValue, privacy: .public)"
        )
        _ = bumpNamespaceRevision(for: root)
    }

    /// Acquires the existing root namespace lease only when no other namespace
    /// mutation owns it. Reorganization recovery remains idempotent through its
    /// original API; Trash uses this atomic variant so two destructive commands
    /// cannot both believe they own one root between separate actor awaits.
    ///
    /// Registration is catalog truth, so this awaits the shared initial load like
    /// every mutation entry point: startup journal recovery reaches here from its
    /// own task, independent of `start()`, and before the load `roots` is empty
    /// for every persisted root. The load is the only suspension; the registry
    /// check and the lease install below stay atomic.
    func acquireNamespaceMutationLease(
        for rootPath: LibraryRootPath,
        owner: RootNamespaceMutationOwner
    ) async -> RootNamespaceLeaseAcquisition {
        do {
            try await ensureStartedForMutation()
        } catch {
            OtosLog.catalog.noticeOperation("namespaceMutation.lease", phase: "denied", fields: [
                "reason": "catalogUnavailable",
                "rootPath": rootPath.rawValue,
                "owner": owner.rawValue,
                "error": String(describing: error),
            ])
            return .catalogUnavailable
        }
        guard roots[rootPath] != nil else {
            OtosLog.catalog.noticeOperation("namespaceMutation.lease", phase: "denied", fields: [
                "reason": "rootNotRegistered",
                "rootPath": rootPath.rawValue,
                "owner": owner.rawValue,
            ])
            return .rootNotRegistered
        }
        if let current = namespaceMutationLeases[rootPath] {
            OtosLog.catalog.noticeOperation("namespaceMutation.lease", phase: "denied", fields: [
                "reason": "busy",
                "rootPath": rootPath.rawValue,
                "owner": owner.rawValue,
                "heldBy": current.owner.rawValue,
            ])
            return .busy(owner: current.owner)
        }
        let lease = installNamespaceMutationLease(for: rootPath, owner: owner)
        OtosLog.catalog.notice(
            """
            op=namespaceMutation.lease phase=acquire rootPath=\(rootPath.rawValue, privacy: .public) \
            owner=\(owner.rawValue, privacy: .public) generation=\(lease.generation, privacy: .public)
            """
        )
        return .acquired(lease)
    }

    /// Installs a new lease on a root the caller has checked no owner holds.
    @discardableResult
    private func installNamespaceMutationLease(
        for rootPath: LibraryRootPath,
        owner: RootNamespaceMutationOwner
    ) -> RootNamespaceMutationLease {
        nextNamespaceMutationLeaseGeneration &+= 1
        let lease = RootNamespaceMutationLease(
            libraryRootPath: rootPath,
            generation: nextNamespaceMutationLeaseGeneration,
            owner: owner,
            markedDirtyByExternalEvents: false
        )
        namespaceMutationLeases[rootPath] = lease
        return lease
    }

    /// Drops a root's lease and resumes every mutation waiting for it.
    private func dropNamespaceMutationLease(at rootPath: LibraryRootPath) {
        namespaceMutationLeases.removeValue(forKey: rootPath)
        namespaceLeaseReleaseWaiters.removeValue(forKey: rootPath)?.forEach { $0.resume() }
    }

    /// Returns once no lease holds `rootPath`: at once when none does, else in the step that
    /// drops it. The caller reads the catalog again after: another lease may be installed in
    /// that same step (a removal handed off at a release).
    private func untilNamespaceMutationLeaseReleased(at rootPath: LibraryRootPath) async {
        guard namespaceMutationLeases[rootPath] != nil else { return }
        await withCheckedContinuation { namespaceLeaseReleaseWaiters[rootPath, default: []].append($0) }
    }

    func ownsNamespaceMutationLease(_ lease: RootNamespaceMutationLease) -> Bool {
        guard roots[lease.libraryRootPath] != nil,
              let current = namespaceMutationLeases[lease.libraryRootPath]
        else {
            return false
        }
        return current.generation == lease.generation && current.owner == lease.owner
    }

    /// Follows the paths the trash queue reports as gone from their roots. A media row whose
    /// file went to the system Trash is kept, hidden under the item's command, with the
    /// file's place in the Trash: the item is not proven deleted, so its overlay stays
    /// (ADR 0008, ADR 0022), and a scan purges the row only once that file is gone. A
    /// companion, or a file deleted immediately (no Trash location), leaves the catalog.
    /// Unmoved members are not passed in and stay cataloged for the next retry.
    ///
    /// Only the holder of the root's namespace lease, the one that covered the moves, may
    /// report them. Each path's dirt is recorded before its row is marked, and the reconcile
    /// it requests runs at the write's suspension: without the lease it finds the file gone
    /// from its path and the row not yet naming the Trash, and purges the row with the
    /// user's choice and edit. Under the lease that reconcile defers (`isCurrent`), and so
    /// does any scan, until the release, when every row says where its file went.
    func reconcileTrashedPaths(
        _ paths: [MediaTrashPathResult],
        batch: MediaTrashBatchID,
        under lease: RootNamespaceMutationLease
    ) async {
        precondition(
            paths.allSatisfy { $0.rootPath == lease.libraryRootPath },
            "a Trash report covers only the root its lease holds"
        )
        guard ownsNamespaceMutationLease(lease) else {
            OtosLog.catalog.errorOperation("mediaTrash.reconcile", phase: "refused", fields: [
                "reason": "leaseNotHeld", "rootPath": lease.libraryRootPath.rawValue, "paths": "\(paths.count)",
            ])
            return
        }
        var changed: CatalogChangedFacts = []
        for path in paths where path.succeeded {
            guard let rootRowID = roots[path.rootPath]?.rowID else {
                continue
            }
            recordIndependentNamespaceMutation(
                root: path.rootPath,
                scope: .file(path.relativePath),
                fileAction: .deleteIfMissing
            )
            if let trashURL = path.trashURL, path.role != .companion {
                do {
                    let marked = try await database().write { db in
                        try db.execute(
                            sql: AssetRowSQL.markTrashedSQL,
                            arguments: [trashURL.path(percentEncoded: false), batch.unixMilliseconds]
                                + AssetKey(rootID: rootRowID, path: path.relativePath).arguments
                        )
                        return db.changesCount > 0
                    }
                    if marked {
                        changed.formUnion(.presence)
                        continue
                    }
                } catch {
                    OtosLog.catalog.errorOperation("mediaTrash.reconcile", phase: "markFailed", fields: [
                        "path": path.relativePath.rawValue,
                        "error": String(describing: error),
                    ])
                    // The file is gone from its path; the next scan sees that and keeps or
                    // purges the row by the same rule, so nothing is left wrong for good.
                    continue
                }
            }
            if case let .changed(facts) = await deleteCatalogedPath(
                relativePath: path.relativePath,
                rootRowID: rootRowID,
                witness: nil
            ) {
                changed.formUnion(facts)
            }
        }
        if !changed.isEmpty {
            notifyCatalogChanged(.changed(changed))
        }
    }

    // MARK: - Reorganization lease and journal settlement

    private func markNamespaceMutationLeaseDirty(for rootPath: LibraryRootPath) {
        guard var lease = namespaceMutationLeases[rootPath] else { return }
        lease.markedDirtyByExternalEvents = true
        namespaceMutationLeases[rootPath] = lease
    }

    @discardableResult
    func releaseNamespaceMutationLease(_ lease: RootNamespaceMutationLease) -> Bool {
        guard let current = namespaceMutationLeases[lease.libraryRootPath],
              current.generation == lease.generation,
              current.owner == lease.owner
        else {
            return false
        }
        let dirty = current.markedDirtyByExternalEvents
        dropNamespaceMutationLease(at: lease.libraryRootPath)
        OtosLog.catalog.notice(
            """
            op=namespaceMutation.lease phase=release rootPath=\(lease.libraryRootPath.rawValue, privacy: .public) \
            owner=\(lease.owner.rawValue, privacy: .public) dirty=\(dirty, privacy: .public)
            """
        )
        // A library the user asked to remove meanwhile goes now; scanning it first is
        // work its removal discards.
        if handOffDeferredLibraryRemoval(lease.libraryRootPath) {
            return true
        }
        if dirty || scanLeases.takeRescanAfterCurrentScan(lease.libraryRootPath) {
            enqueueScans([lease.libraryRootPath], reason: .requested)
        } else {
            startNextScanIfNeeded()
        }
        // Dirt the lease held back may be reconciled now.
        requestReconcile()
        return true
    }

    func hasNamespaceMutationLease(for rootPath: LibraryRootPath) -> Bool {
        namespaceMutationLeases[rootPath] != nil
    }

    func activeReorganizationComponents(lane: CatalogReadLane) async throws -> [ActiveReorganizationComponent] {
        try await reader(for: lane).readFreeingConnection { db in
            try Self.fetchAllActiveReorganizationComponents(db: db)
        }
    }

    func prepareReorganizationComponent(
        _ component: ActiveReorganizationComponent
    ) async throws {
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try Self.insertActiveReorganizationComponent(component, db: db)
        }
    }

    func recordReorganizationMoveIntent(
        key: ReorganizationComponentKey,
        stepIndex: Int
    ) async throws {
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try Self.updateStepPhase(key: key, stepIndex: stepIndex, phase: .willMove, db: db)
            try Self.updateComponentPhase(
                key: key,
                phase: .moving,
                nextStepIndex: stepIndex,
                updatedAt: Date(),
                db: db
            )
        }
    }

    func recordReorganizationMoveCompletion(
        key: ReorganizationComponentKey,
        step: ActiveReorganizationStep,
        nextStepIndex: Int
    ) async throws {
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try Self.updateStepPhase(key: key, stepIndex: step.stepIndex, phase: .didMove, db: db)
            try Self.updateMemberCurrentPath(
                key: key,
                memberIndex: step.memberIndex,
                currentRelativePath: step.destinationRelativePath,
                db: db
            )
            try Self.updateComponentPhase(
                key: key,
                phase: .moving,
                nextStepIndex: nextStepIndex,
                updatedAt: Date(),
                db: db
            )
        }
    }

    func recordReorganizationFilesystemCompletion(
        key: ReorganizationComponentKey,
        nextStepIndex: Int
    ) async throws {
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try Self.updateComponentPhase(
                key: key,
                phase: .filesystemComplete,
                nextStepIndex: nextStepIndex,
                updatedAt: Date(),
                db: db
            )
        }
    }

    /// A directory the component needed did not exist and the executor created it, so
    /// a rollback may remove it again once it is empty.
    func recordReorganizationDirectoryCreated(
        key: ReorganizationComponentKey,
        relativePath: MediaRelativePath
    ) async throws {
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try Self.updateDirectoryPhase(key: key, relativePath: relativePath, phase: .created, db: db)
        }
    }

    /// The component will not finish: from here its completed steps are undone.
    func recordReorganizationRollbackStart(key: ReorganizationComponentKey, nextStepIndex: Int) async throws {
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try Self.updateComponentPhase(
                key: key,
                phase: .rollingBack,
                nextStepIndex: nextStepIndex,
                updatedAt: Date(),
                db: db
            )
        }
    }

    /// One completed step was moved back: its member is at the step's source again.
    func recordReorganizationStepRolledBack(
        key: ReorganizationComponentKey,
        step: ActiveReorganizationStep
    ) async throws {
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try Self.updateStepPhase(key: key, stepIndex: step.stepIndex, phase: .rolledBack, db: db)
            try Self.updateMemberCurrentPath(
                key: key,
                memberIndex: step.memberIndex,
                currentRelativePath: step.sourceRelativePath,
                db: db
            )
        }
    }

    /// A rollback could not move a file back. The journal stays, so the next launch's
    /// recovery tries the rollback again, and the root stays under the lease until then.
    func recordReorganizationBlocked(key: ReorganizationComponentKey) async throws {
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            guard let component = try Self.fetchActiveReorganizationComponent(key: key, db: db) else {
                throw CatalogStoreError.catalogUnavailable
            }
            try Self.updateComponentPhase(
                key: key,
                phase: .blocked,
                nextStepIndex: component.nextStepIndex,
                updatedAt: Date(),
                db: db
            )
        }
    }

    /// Every step the component made was undone: the library is as it was before the
    /// component, so its journal goes and no catalog row changes.
    func discardRolledBackReorganizationComponent(key: ReorganizationComponentKey) async throws {
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try Self.deleteActiveReorganizationComponent(key: key, db: db)
        }
    }

    /// Remaps the catalog rows a component moved and records the remaps as a pending
    /// batch for the window, in one transaction (ARC-051, ARC-052).
    func settleReorganizationComponent(key: ReorganizationComponentKey, lane: CatalogReadLane) async throws {
        let dbWriter = try database()
        let component = try await reader(for: lane).readFreeingConnection { db in
            try Self.fetchActiveReorganizationComponent(key: key, db: db)
        }
        guard let component else {
            throw CatalogStoreError.catalogUnavailable
        }
        recordIndependentNamespaceMutation(root: component.libraryRootPath, scope: .root)
        let settled: CatalogIdentityRemapBatch = try Self.writeWithJournalDurability(dbWriter) { db in
            guard let currentComponent = try Self.fetchActiveReorganizationComponent(key: key, db: db),
                  let rootRowID = try Int64.fetchOne(
                      db,
                      sql: LibraryRootSQL.rowIDOfPathSQL,
                      arguments: [currentComponent.libraryRootPath.rawValue]
                  )
            else {
                throw CatalogStoreError.catalogUnavailable
            }
            return try Self.settleRelocationComponent(
                rootRowID: rootRowID,
                component: currentComponent,
                db: db
            )
        }
        // Relocation moves media on disk: advance occupancy so import planning
        // against this root replans. Reorg's own `rootRevision` stays the general
        // planRevision, which the occupancy bump also advances.
        bumpNamespaceRevision(for: settled.libraryRootPath)
        // Each row it moved, at the path it left and the path it took.
        let moved = Set(settled.remaps.flatMap { [$0.oldID, $0.newID] })
        notifyCatalogChanged(.changed(.movedRow, rows: moved.isEmpty ? .unnamed : .rows(moved)))
        OtosLog.catalog.notice(
            "op=reorganization.settle phase=finish rootPath=\(settled.libraryRootPath.rawValue, privacy: .public) remapCount=\(settled.remaps.count, privacy: .public) batch=\(settled.id, privacy: .public)"
        )
    }

    /// The window applied these batches; they no longer travel with published states.
    func acknowledgeIdentityRemaps(_ batchIDs: [Int64]) async throws {
        let dbWriter = try database()
        try await dbWriter.write { db in
            try Self.deletePendingIdentityRemapBatches(ids: batchIDs, db: db)
        }
        OtosLog.catalog.noticeOperation("reorganization.remapAcknowledged", phase: "finish", fields: [
            "batches": batchIDs.map(String.init).joined(separator: ","),
        ])
    }
}

// MARK: - Duplicates (ADR 0042)

extension CatalogStore {
    /// A RAW and its processed file are one photo, or two, from now on. A change is a change
    /// of what decides the stacks, so every reader of stacks reads again.
    func setRawPairing(_ pairing: RawPairing) {
        guard rawPairing != pairing else {
            return
        }
        rawPairing = pairing
        OtosLog.catalog.noticeOperation("stacks.rawPairing", phase: "set", fields: ["pairing": pairing.rawValue])
        notifyCatalogChanged(.changed(.stacks))
    }

    /// Duplicates compares these copies from now on. A change is a change of which files
    /// are duplicates of which, so the groups and the Duplicates scopes are read again.
    func setDuplicatesReach(_ reach: DuplicatesReach) {
        guard duplicatesReach != reach else {
            return
        }
        duplicatesReach = reach
        OtosLog.catalog.noticeOperation("duplicates.reach", phase: "set", fields: [
            "reach": "\(reach)",
        ])
        notifyCatalogChanged(.changed(.duplicateFacts))
    }

    /// Every visible copy whose current digest another visible copy shares — in its own
    /// library while Duplicates compares within each — every remembered "Keep All Copies"
    /// pair among them, and the reach the read used, which the rest of the build groups by.
    func duplicateCopies(
        availableLibraryPaths: Set<LibraryRootPath>,
        lane: CatalogReadLane
    ) async throws -> (copies: [DuplicateCopyFacts], keptPairs: Set<DuplicateKeptPair>, reach: DuplicatesReach) {
        let reach = duplicatesReach
        let libraries = roots.values.filter { $0.root.kind.isMemberOfAllMedia && availableLibraryPaths.contains($0.path) }
        guard !libraries.isEmpty else {
            return ([], [], reach)
        }
        let rootIDs = libraries.map(\.rowID).sorted()
        let pathsByRowID = roots.pathsByRowID
        let librariesByPath = Dictionary(uniqueKeysWithValues: libraries.map { ($0.path, DuplicateLibrary($0.root)) })
        return try await reader(for: lane).readFreeingConnection { db in
            let copies = try DuplicatesGateway.fetchDuplicateCopies(rootIDs: rootIDs, reach: reach, db: db).compactMap { row in
                row.facts(pathsByRowID: pathsByRowID, librariesByPath: librariesByPath)
            }
            let keptPairs = try DuplicatesGateway.fetchKeptPairs(rootIDs: rootIDs, db: db).compactMap { row in
                row.pair(pathsByRowID: pathsByRowID)
            }
            return (copies, Set(keptPairs), reach)
        }
    }

    // MARK: - Mirrors (ADR 0054)

    /// Each library as `account`'s mirror discovery sees it: the server prefixes learned for
    /// it, and the first file none of them explains that may be one of the account's assets
    /// (`MirrorGateway.Probe`).
    func mirrorProbes(account: LibraryRootPath, lane: CatalogReadLane) async throws -> [MirrorGateway.Probe] {
        guard let accountRootID = roots[account]?.rowID else {
            return []
        }
        let libraries = roots.values.filter { $0.root.kind == .library }.map { (id: $0.rowID, path: $0.path) }
        return try await reader(for: lane).readFreeingConnection(operation: "mirrorProbes") { db in
            try libraries.map { library in
                try MirrorGateway.Probe(
                    libraryRootID: library.id,
                    libraryRootPath: library.path,
                    serverPrefixes: MirrorGateway.serverPrefixes(accountRootID: accountRootID, libraryRootID: library.id, db: db),
                    candidate: MirrorGateway.candidate(libraryRootID: library.id, accountRootID: accountRootID, db: db)
                )
            }
        }
    }

    /// Adds a server path `library`'s relative paths follow on `account`'s server.
    func recordMirror(account: LibraryRootPath, library: LibraryRootPath, serverPrefix: String) async throws {
        guard let accountRootID = roots[account]?.rowID, let libraryRootID = roots[library]?.rowID else {
            return
        }
        try await database().write(operation: "recordMirror") { db in
            try MirrorGateway.record(
                accountRootID: accountRootID, libraryRootID: libraryRootID, serverPrefix: serverPrefix, db: db
            )
        }
        OtosLog.catalog.noticeOperation("immich.mirror", phase: "recorded", fields: [
            "accountRootPath": account.rawValue, "libraryRootPath": library.rawValue, "serverPrefix": serverPrefix,
        ])
    }

    /// Remembers that the server's path for `candidate`'s asset taught `library` no new
    /// prefix, so the probe does not ask it again while the asset's path stands.
    func recordMirrorAsked(account: LibraryRootPath, library: LibraryRootPath, candidate: MirrorGateway.Candidate) async throws {
        guard let accountRootID = roots[account]?.rowID, let libraryRootID = roots[library]?.rowID else {
            return
        }
        try await database().write(operation: "recordMirrorAsked") { db in
            _ = try MirrorGateway.recordAsked(candidate, libraryRootID: libraryRootID, accountRootID: accountRootID, db: db)
        }
    }

    /// Pairs every file of each library `account` mirrors with the asset its path names
    /// there (`MirrorGateway.owedPairs`), a batch of files at a time, and unpairs a file from
    /// an asset its path no longer names; returns how many pairs came and went. Each batch
    /// is read first and written only for the files whose pair is owed, so a walk over
    /// pairs that all stand — every owed walk of a settled account — opens no write. The
    /// catalog's triggers make each pair's rows one photo (schema v79).
    func pairMirroredCopies(account: LibraryRootPath, lane: CatalogReadLane) async throws -> MirrorWalk {
        guard let accountRootID = roots[account]?.rowID else {
            return MirrorWalk(paired: 0, unpaired: 0)
        }
        let dbQueue = try database()
        let started = ContinuousClock.now
        let mirrors = try await reader(for: lane).readFreeingConnection(operation: "mirrors") { db in
            try MirrorGateway.mirrors(ofAccount: accountRootID, db: db)
        }
        var paired = 0
        var unpaired = 0
        var files = 0
        var choicesJoined = false
        for mirror in mirrors {
            var after = ""
            while true {
                let batch = try await reader(for: lane).readFreeingConnection(operation: "mirrorPairsOwed") { [after] db in
                    try MirrorGateway.owedPairs(
                        libraryRootID: mirror.libraryRootID, accountRootID: accountRootID,
                        serverPrefixes: mirror.serverPrefixes, after: after, db: db
                    )
                }
                if !batch.owed.isEmpty {
                    // The write pairs again under its own conditions: a file or an asset that
                    // went or moved since the read is not paired.
                    let written = try await timedWrite(dbQueue, operation: "pairMirroredCopies") { db in
                        let joinsBefore = try CatalogSchema.choiceJoins(db)
                        let counts = try MirrorGateway.writePairs(
                            batch.owed, libraryRootID: mirror.libraryRootID, accountRootID: accountRootID, db: db
                        )
                        return try (counts, CatalogSchema.choiceJoins(db) != joinsBefore)
                    }.value
                    paired += written.0.paired
                    unpaired += written.0.unpaired
                    choicesJoined = choicesJoined || written.1
                }
                files += batch.count
                guard let last = batch.last, batch.count == MirrorGateway.pairBatchSize else {
                    break
                }
                after = last
            }
        }
        OtosLog.catalog.noticeOperation("immich.mirror", phase: "paired", fields: [
            "rootPath": account.rawValue,
            "mirrors": "\(mirrors.count)",
            "prefixes": "\(mirrors.reduce(0) { $0 + $1.serverPrefixes.count })",
            "files": "\(files)",
            "paired": "\(paired)",
            "unpaired": "\(unpaired)",
            "ms": "\(DiagnosticsTiming.milliseconds(from: started, to: ContinuousClock.now))",
        ])
        // A pair that comes or goes joins or splits a photo's copies.
        if paired + unpaired > 0 {
            notifyCatalogChanged(.changed(.digests(copiesChanged: true, digestsChanged: true, choicesJoined: choicesJoined)))
        }
        return MirrorWalk(paired: paired, unpaired: unpaired)
    }

    /// Keep All Copies: remembers every pair of copies in each group as kept together.
    /// Returns the pairs this call added, so undo can forget exactly those.
    func keepCopiesTogether(_ groups: [[MediaAssetID]]) async throws -> Set<DuplicateKeptPair> {
        var pairs: Set<DuplicateKeptPair> = []
        for members in groups {
            for (index, left) in members.enumerated() {
                for right in members[(index + 1)...] {
                    pairs.insert(DuplicateKeptPair(left, right))
                }
            }
        }
        let rowIDs = roots.rowIDSnapshot()
        let requested = pairs
        let added = try await database().write { db -> Set<DuplicateKeptPair> in
            var added: Set<DuplicateKeptPair> = []
            for pair in requested {
                guard let firstRoot = rowIDs[pair.first.libraryRootPath],
                      let secondRoot = rowIDs[pair.second.libraryRootPath]
                else {
                    continue
                }
                try db.execute(
                    sql: DuplicatesHoldSQL.insertKeptPairSQL,
                    arguments: [firstRoot, pair.first.relativePath.rawValue, secondRoot, pair.second.relativePath.rawValue]
                )
                if db.changesCount > 0 {
                    added.insert(pair)
                }
            }
            return added
        }
        OtosLog.catalog.noticeOperation("duplicates.keepAll", phase: "written", fields: [
            "groups": "\(groups.count)", "pairs": "\(added.count)",
        ])
        if !added.isEmpty {
            notifyCatalogChanged(.changed(.duplicateFacts))
        }
        return added
    }

    /// Undo of Keep All Copies: forgets exactly the pairs it added.
    func forgetKeptPairs(_ pairs: Set<DuplicateKeptPair>) async throws {
        let rowIDs = roots.rowIDSnapshot()
        try await database().write { db in
            for pair in pairs {
                guard let firstRoot = rowIDs[pair.first.libraryRootPath],
                      let secondRoot = rowIDs[pair.second.libraryRootPath]
                else {
                    continue
                }
                try db.execute(
                    sql: DuplicatesHoldSQL.deleteKeptPairSQL,
                    arguments: [firstRoot, pair.first.relativePath.rawValue, secondRoot, pair.second.relativePath.rawValue]
                )
            }
        }
        OtosLog.catalog.noticeOperation("duplicates.keepAll", phase: "forgotten", fields: ["pairs": "\(pairs.count)"])
        notifyCatalogChanged(.changed(.duplicateFacts))
    }
}

// MARK: - Same photo (ADR 0042)

extension CatalogStore {
    /// Visible stills in the fixed libraries whose thumbnail has no current render signature:
    /// the page after `cursor` of one walk over each root's key (`CandidateWalk`).
    func renderSignatureCandidates(
        after cursor: AssetKeyCursor? = nil,
        limit: Int,
        lane: CatalogReadLane
    ) async throws -> CandidatePage<RenderSignatureCandidate, AssetKeyCursor> {
        let libraries = roots.values.filter { $0.root.kind.isMemberOfAllMedia && $0.availability == .available }
        guard !libraries.isEmpty else {
            return CandidatePage(candidates: [], next: nil)
        }
        let rootIDs = libraries.map(\.rowID)
        let pathsByRowID = roots.pathsByRowID
        return try await reader(for: lane).readFreeingConnection { db in
            let (rows, next) = try CandidateWalk.keyPage(
                sql: RenderSignatureSQL.candidatesSQL, rootIDs: rootIDs, after: cursor, limit: limit, db: db
            )
            let candidates = rows.compactMap { row -> RenderSignatureCandidate? in
                guard let root = pathsByRowID[row["library_root_id"]] else { return nil }
                return RenderSignatureCandidate(
                    id: MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: row["relative_path"])),
                    thumbnailPath: row["thumbnail_path"],
                    source: row["source"]
                )
            }
            return CandidatePage(candidates: candidates, next: next)
        }
    }

    /// Writes render signatures for rows whose thumbnail is still the one they were read from.
    @discardableResult
    func applyRenderSignatures(_ results: [RenderSignatureResult]) async throws -> Int {
        let rowIDs = roots.rowIDSnapshot()
        let written = try await database().write { db -> Int in
            var written = 0
            for result in results {
                guard let rootID = rowIDs[result.id.libraryRootPath] else { continue }
                try db.execute(
                    sql: AssetEnrichmentSQL.writeRenderSignatureSQL,
                    arguments: [result.signature.map { Int64(bitPattern: $0.differenceHash) }]
                        + AssetKey(rootID: rootID, path: result.id.relativePath).arguments
                        + [result.source]
                )
                guard db.changesCount > 0 else { continue }
                written += 1
                if let signature = result.signature {
                    try db.execute(
                        sql: RenderSignatureSQL.writeGraySQL,
                        arguments: [rootID, result.id.relativePath.rawValue, Data(signature.gray)]
                    )
                } else {
                    try db.execute(
                        sql: AssetEnrichmentSQL.deleteRenderGraySQL,
                        arguments: AssetKey(rootID: rootID, path: result.id.relativePath).arguments
                    )
                }
            }
            return written
        }
        if written > 0 {
            notifyCatalogChanged(.changed(.duplicateFacts))
        }
        return written
    }

    /// Assets whose stored thumbnail has no current search embedding (ADR 0048), newest
    /// capture first so the photos a person is likeliest to look for are searchable first.
    /// Every available root is read: search covers whatever scope is shown. A Live Photo's
    /// movie is left out, because its still stands for the item. The page after `cursor` of one
    /// newest-first walk (`CandidateWalk`).
    func searchEmbeddingCandidates(
        after cursor: CaptureOrderCursor? = nil,
        limit: Int,
        lane: CatalogReadLane
    ) async throws -> CandidatePage<SearchEmbeddingCandidate, CaptureOrderCursor> {
        let rootIDs = availableRootRowIDs()
        guard !rootIDs.isEmpty else {
            return CandidatePage(candidates: [], next: nil)
        }
        let pathsByRowID = roots.pathsByRowID
        return try await reader(for: lane).readFreeingConnection { db in
            let (rows, next) = try CandidateWalk.capturePage(
                row: "a", after: cursor, limit: limit, arguments: StatementArguments(rootIDs), db: db
            ) { position, order in
                SearchEmbeddingStorage.candidatesSQL(rootCount: rootIDs.count, position: position, order: order)
            }
            let candidates = rows.compactMap { row -> SearchEmbeddingCandidate? in
                guard let root = pathsByRowID[row["library_root_id"]] else { return nil }
                let id = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: row["relative_path"]))
                return SearchEmbeddingCandidate(id: id, thumbnailPath: row["thumbnail_path"], source: row["source"])
            }
            return CandidatePage(candidates: candidates, next: next)
        }
    }

    /// The assets of `ids`, and the other members of their Live Photo groups, that are owed a
    /// search embedding, newest capture first: what the index embeds for a change that names
    /// its rows (`CatalogChangedRows`). Each is one seek of its own row, never a walk, so the
    /// read costs what the change named. Only available roots are read.
    func searchEmbeddingCandidates(for ids: Set<MediaAssetID>, lane: CatalogReadLane) async throws -> [SearchEmbeddingCandidate] {
        try await keyedCandidates(
            lane: lane, ids, expandingGroups: true, operation: "searchEmbeddingCandidatesByKey",
            sql: SearchEmbeddingStorage.keyedCandidateSQL
        ) { id, row in
            SearchEmbeddingCandidate(id: id, thumbnailPath: row["thumbnail_path"], source: row["source"])
        }
    }

    /// The stills of `ids` owed a text reading, newest capture first: what the index reads for
    /// a change that names its rows, one seek of each row.
    func searchTextCandidates(for ids: Set<MediaAssetID>, lane: CatalogReadLane) async throws -> [SearchTextCandidate] {
        try await keyedCandidates(
            lane: lane, ids, expandingGroups: false, operation: "searchTextCandidatesByKey", sql: SearchTextStorage.keyedCandidateSQL
        ) { id, row in
            SearchTextCandidate(id: id, previewPath: row["preview_path"], source: row["source"])
        }
    }

    /// The rows of `ids` (and, with `expandingGroups`, of the other members of their Live
    /// Photo groups) that `sql` returns by key, `currentEmbeddingBatch` keys a transaction,
    /// newest capture first.
    private func keyedCandidates<Candidate: Sendable>(
        lane: CatalogReadLane,
        _ ids: Set<MediaAssetID>,
        expandingGroups: Bool,
        operation: String,
        sql: String,
        candidate: @escaping @Sendable (MediaAssetID, Row) -> Candidate
    ) async throws -> [Candidate] {
        let available = Set(availableRootRowIDs())
        let rowIDs = roots.rowIDSnapshot()
        let pathsByRowID = roots.pathsByRowID
        let keys = ids.compactMap { id in
            rowIDs[id.libraryRootPath].flatMap { available.contains($0) ? AssetKey(rootID: $0, path: id.relativePath) : nil }
        }
        var found: [MediaAssetID: (capture: Double?, candidate: Candidate)] = [:]
        var start = 0
        while start < keys.count {
            let batch = keys[start ..< min(start + Self.currentEmbeddingBatch, keys.count)]
            start += batch.count
            let read = try await reader(for: lane).readFreeingConnection(operation: operation) { db in
                var asked = Set(batch)
                if expandingGroups {
                    let members = try db.cachedStatement(sql: SearchEmbeddingStorage.groupMembersSQL)
                    for key in batch {
                        for path in try String.fetchAll(members, arguments: key.arguments) {
                            asked.insert(AssetKey(rootID: key.rootID, path: MediaRelativePath(rawValue: path)))
                        }
                    }
                }
                let statement = try db.cachedStatement(sql: sql)
                return try Array(page: asked, atMost: asked.count) { key -> (id: MediaAssetID, capture: Double?, candidate: Candidate)? in
                    guard let root = pathsByRowID[key.rootID],
                          let row = try Row.fetchOne(statement, arguments: key.arguments)
                    else { return nil }
                    let id = MediaAssetID(libraryRootPath: root, relativePath: key.path)
                    return (id, row["best_capture_local"], candidate(id, row))
                }
            }
            for row in read {
                found[row.id] = (row.capture, row.candidate)
            }
        }
        return found.values.sorted { ($0.capture ?? -.infinity) > ($1.capture ?? -.infinity) }.map(\.candidate)
    }

    /// The available roots' assets that hold no thumbnail and will get none from Otos's own
    /// work (`SearchEmbeddingStorage.noThumbnailComingSQL`): what search never reads, so an
    /// empty answer does not count them among the items it is still reading
    /// (`PhotoSearchIndex.unreadCount`). Visits only those rows.
    func assetsWithNoThumbnailComing(lane: CatalogReadLane) async throws -> [MediaAssetID] {
        let rootIDs = availableRootRowIDs()
        guard !rootIDs.isEmpty else {
            return []
        }
        let pathsByRowID = roots.pathsByRowID
        return try await reader(for: lane).readFreeingConnection { db in
            let rows = try Row.fetchCursor(
                db, sql: SearchEmbeddingStorage.noThumbnailComingSQL(rootCount: rootIDs.count), arguments: StatementArguments(rootIDs)
            )
            var ids: [MediaAssetID] = []
            while let row = try rows.next() {
                guard let root = pathsByRowID[row[0]] else { continue }
                ids.append(MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: row[1])))
            }
            return ids
        }
    }

    /// The kinds of fact whose writes could change what `statements` read: each statement is
    /// prepared, never run, and its region (`Statement.databaseRegion`) is matched against
    /// what each kind's writes change (`CatalogChangedFacts.writes`).
    func factsRead(by statements: [String], lane: CatalogReadLane) async throws -> CatalogChangedFacts {
        try await reader(for: lane).readFreeingConnection { db in
            try statements.reduce(into: CatalogChangedFacts()) { facts, sql in
                try facts.formUnion(CatalogChangedFacts.read(by: db.makeStatement(sql: sql).databaseRegion))
            }
        }
    }

    private func availableRootRowIDs() -> [Int64] {
        roots.values.filter { $0.availability == .available }.map(\.rowID).sorted()
    }

    /// Writes search embeddings for assets whose thumbnail is still the one they were read
    /// from, and returns the ones written. A write is a change of `.searchContent`, which a
    /// description waits for (ADR 0053), and of `.searchReadings` too when it puts a photo into
    /// or out of On This Day (`OnThisDayPicks`: a confident screenshot or document label), a
    /// change that scope is read again for.
    func applySearchEmbeddings(_ results: [SearchEmbeddingResult]) async throws -> [SearchEmbeddingResult] {
        let rowIDs = roots.rowIDSnapshot()
        let leftOut = SearchEmbeddingStorage.onThisDayLeftOutSQL
        let (applied, changesOnThisDay) = try await database().write { db -> ([SearchEmbeddingResult], Bool) in
            var written: [SearchEmbeddingResult] = []
            var changesOnThisDay = false
            for result in results {
                guard let rootID = rowIDs[result.id.libraryRootPath] else { continue }
                let key = AssetKey(rootID: rootID, path: result.id.relativePath)
                guard try Bool.fetchOne(
                    db,
                    sql: SearchEmbeddingStorage.embeddingSourceIsCurrentSQL,
                    arguments: [result.source] + key.arguments
                ) == true else {
                    continue
                }
                let wasLeftOut = try Bool.fetchOne(db, sql: leftOut, arguments: key.arguments) ?? false
                try db.execute(
                    sql: SearchEmbeddingStorage.writeEmbeddingSQL,
                    arguments: key.arguments + [
                        result.source, SearchEmbeddingStorage.data(result.embedding),
                        SearchEmbeddingStorage.labelsText(result.labels),
                        SearchEmbeddingStorage.confidentLabelsText(result.confidentLabels),
                    ]
                )
                if try (Bool.fetchOne(db, sql: leftOut, arguments: key.arguments) ?? false) != wasLeftOut {
                    changesOnThisDay = true
                }
                written.append(result)
            }
            // The written rows take the vector file's next slots, in this order, in the same
            // commit (v70): a file the index has not yet appended them to is short of the
            // count, so a crash before it does leaves a file that is rebuilt, never trusted.
            if !written.isEmpty {
                try db.execute(sql: SearchVectorFileState.addSlotsSQL, arguments: [written.count])
            }
            return (written, changesOnThisDay)
        }
        if !applied.isEmpty {
            notifyCatalogChanged(.changed(
                changesOnThisDay ? [.searchContent, .searchReadings] : .searchContent, rows: .rows(Set(applied.map(\.id)))
            ))
        }
        return applied
    }

    /// The assets in available roots that have a current search embedding, without the
    /// vectors, with the roots read and every root cataloged: what `PhotoSearchIndex`
    /// reconciles its memory against after a catalog change. A root cataloged and not read
    /// (a card out, a library offline) keeps what memory holds of it.
    func currentSearchEmbeddingIDs(lane: CatalogReadLane) async throws -> CurrentSearchKeys {
        let rootIDs = availableRootRowIDs()
        let pathsByRowID = roots.pathsByRowID
        let read = Set(rootIDs.compactMap { pathsByRowID[$0] })
        let cataloged = Set(roots.values.map(\.path))
        guard !rootIDs.isEmpty else {
            return CurrentSearchKeys(ids: [], readRoots: read, catalogedRoots: cataloged)
        }
        let ids = try await reader(for: lane).readFreeingConnection { db in
            let rows = try Row.fetchCursor(
                db, sql: SearchEmbeddingStorage.currentEmbeddingIDsSQL(rootCount: rootIDs.count), arguments: StatementArguments(rootIDs)
            )
            var ids: Set<MediaAssetID> = []
            while let row = try rows.next() {
                guard let root = pathsByRowID[row[0]] else { continue }
                ids.insert(MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: row[1])))
            }
            return ids
        }
        return CurrentSearchKeys(ids: ids, readRoots: read, catalogedRoots: cataloged)
    }

    /// The stored embeddings of the available roots, a page at a time in each root's key order
    /// after `cursor` (`CandidateWalk`), each in its own transaction: the vector as stored and
    /// the loose labels' text, which the search index keeps compact. Whether each is current is
    /// the caller's to ask (`currentSearchEmbeddingIDs`), so a page reads only the embedding
    /// table, never an asset row.
    func searchEmbeddingRows(
        after cursor: AssetKeyCursor? = nil,
        limit: Int,
        lane: CatalogReadLane
    ) async throws -> CandidatePage<StoredSearchEmbeddingRow, AssetKeyCursor> {
        let rootIDs = availableRootRowIDs()
        guard !rootIDs.isEmpty else { return CandidatePage(candidates: [], next: nil) }
        let pathsByRowID = roots.pathsByRowID
        return try await reader(for: lane).readFreeingConnection { db in
            let (rows, next) = try CandidateWalk.keyPage(
                sql: SearchEmbeddingStorage.storedRowsSQL, rootIDs: rootIDs, after: cursor, limit: limit, db: db
            )
            let embeddings = Array(page: rows, atMost: rows.count) { row -> StoredSearchEmbeddingRow? in
                guard let root = pathsByRowID[row[0]], let vector: Data = row[2],
                      vector.count == SearchEmbedding.dimensions * MemoryLayout<Float32>.size
                else { return nil }
                return StoredSearchEmbeddingRow(
                    id: MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: row[1])),
                    vector: vector,
                    labels: row[3]
                )
            }
            return CandidatePage(candidates: embeddings, next: next)
        }
    }

    /// The current embeddings of `ids`, each sought by its key, `currentEmbeddingBatch` to a
    /// transaction: what the search index adds after a reconcile.
    func currentSearchEmbeddings(for ids: Set<MediaAssetID>, lane: CatalogReadLane) async throws -> [StoredSearchEmbeddingRow] {
        let rowIDs = roots.rowIDSnapshot()
        let keys = ids.compactMap { id in rowIDs[id.libraryRootPath].map { (id: id, rootID: $0) } }
        var found: [StoredSearchEmbeddingRow] = []
        var start = 0
        while start < keys.count {
            let batch = keys[start ..< min(start + Self.currentEmbeddingBatch, keys.count)]
            start += batch.count
            found += try await reader(for: lane).readFreeingConnection(operation: "currentSearchEmbeddings") { db in
                let statement = try db.cachedStatement(sql: SearchEmbeddingStorage.currentEmbeddingByKeySQL)
                return try Array(page: batch, atMost: batch.count) { key -> StoredSearchEmbeddingRow? in
                    guard let row = try Row.fetchOne(
                        statement,
                        arguments: AssetKey(rootID: key.rootID, path: key.id.relativePath).arguments
                    ),
                        let vector: Data = row[0], vector.count == SearchEmbedding.dimensions * MemoryLayout<Float32>.size
                    else { return nil }
                    return StoredSearchEmbeddingRow(id: key.id, vector: vector, labels: row[1])
                }
            }
        }
        return found
    }

    static let currentEmbeddingBatch = 500

    /// The search vector file the catalog's embeddings commit, and how many of its slots
    /// (v70, ADR 0048): nil while none is built.
    func searchVectorFileState(lane: CatalogReadLane) async throws -> SearchVectorFileState? {
        try await reader(for: lane).readFreeingConnection(operation: "searchVectorFileState") { db in
            try Row.fetchOne(db, sql: SearchVectorFileState.fileSQL).flatMap { row in
                UUID(uuidString: row["file_id"]).map { SearchVectorFileState(id: $0, slots: row["slots"]) }
            }
        }
    }

    /// Names `state` as the search vector file, or none: a file built or compacted is current
    /// from this commit on. Search's own bookkeeping, so no change is announced.
    func setSearchVectorFileState(_ state: SearchVectorFileState?) async throws {
        try await database().write { db in
            try db.execute(sql: SearchVectorFileState.deleteFileSQL)
            if let state {
                try db.execute(
                    sql: SearchVectorFileState.insertFileSQL,
                    arguments: [state.id.uuidString, state.slots]
                )
            }
        }
    }

    /// Commits `count` more slots of the search vector file: embeddings the index read from the
    /// catalog and appends to the file next, in this order. No change is announced.
    func addSearchVectorSlots(_ count: Int) async throws {
        guard count > 0 else { return }
        try await database().write { db in
            try db.execute(sql: SearchVectorFileState.addSlotsSQL, arguments: [count])
        }
    }

    /// The people the user has named and not hidden, for search to match in a query
    /// (ADR 0048): a hidden person is found only in the People gallery.
    func namedPeople(lane: CatalogReadLane) async throws -> [SearchPerson] {
        try await reader(for: lane).readFreeingConnection { db in
            try Row.fetchAll(
                db,
                sql: PeopleSQL.namedVisiblePeopleSQL
            ).map { row in
                SearchPerson(id: PersonID(rawValue: row["id"]), name: row["name"])
            }
        }
    }

    /// The assets in available roots that `facts` allow (ADR 0048): captured within the date
    /// span, located within the place, holding a face confirmed as every person named.
    func searchFactMatches(_ facts: SearchFactFilter, lane: CatalogReadLane) async throws -> Set<MediaAssetID> {
        let rootIDs = availableRootRowIDs()
        guard !rootIDs.isEmpty else { return [] }
        let pathsByRowID = roots.pathsByRowID
        var arguments: [DatabaseValue] = rootIDs.map(\.databaseValue)
        if let date = facts.dateSpan {
            // The span is days on this Mac's calendar, so its ends are the readings of its
            // clock at them: a photo taken that day anywhere matches it.
            arguments += [
                CaptureLocalTime(readingOf: date.start).seconds.databaseValue,
                CaptureLocalTime(readingOf: date.end).seconds.databaseValue,
            ]
        }
        if let place = facts.place {
            // A box first, so SQLite reads few rows; the exact distance after.
            let latitudeDelta = place.radiusMeters / 111_000
            let longitudeDelta = latitudeDelta / max(cos(place.latitude * .pi / 180), 0.01)
            arguments += [
                place.latitude - latitudeDelta, place.latitude + latitudeDelta,
                place.longitude - longitudeDelta, place.longitude + longitudeDelta,
            ].map(\.databaseValue)
        }
        arguments += facts.people.map(\.rawValue.databaseValue)
        let sql = AssetRowSQL.factMatchesSQL(
            rootCount: rootIDs.count, dated: facts.dateSpan != nil, placed: facts.place != nil, people: facts.people.count
        )
        let place = facts.place
        let statementArguments = StatementArguments(arguments)
        return try await reader(for: lane).readFreeingConnection { db in
            let rows = try Row.fetchCursor(db, sql: sql, arguments: statementArguments)
            var allowed: Set<MediaAssetID> = []
            while let row = try rows.next() {
                guard let root = pathsByRowID[row[0]] else { continue }
                if let place {
                    guard let latitude: Double = row[2], let longitude: Double = row[3],
                          place.contains(latitude: latitude, longitude: longitude) else { continue }
                }
                allowed.insert(MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: row[1])))
            }
            return allowed
        }
    }

    /// Stills whose stored preview has no current text reading (ADR 0048): the page after
    /// `cursor` of one newest-first walk (`CandidateWalk`).
    func searchTextCandidates(
        after cursor: CaptureOrderCursor? = nil,
        limit: Int,
        lane: CatalogReadLane
    ) async throws -> CandidatePage<SearchTextCandidate, CaptureOrderCursor> {
        let rootIDs = availableRootRowIDs()
        guard !rootIDs.isEmpty else { return CandidatePage(candidates: [], next: nil) }
        let pathsByRowID = roots.pathsByRowID
        return try await reader(for: lane).readFreeingConnection { db in
            let (rows, next) = try CandidateWalk.capturePage(
                row: "a", after: cursor, limit: limit, arguments: StatementArguments(rootIDs), db: db
            ) { position, order in
                SearchTextStorage.candidatesSQL(rootCount: rootIDs.count, position: position, order: order)
            }
            let candidates = Array(page: rows, atMost: rows.count) { row -> SearchTextCandidate? in
                guard let root = pathsByRowID[row["library_root_id"]] else { return nil }
                let id = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: row["relative_path"]))
                return SearchTextCandidate(id: id, previewPath: row["preview_path"], source: row["source"])
            }
            return CandidatePage(candidates: candidates, next: next)
        }
    }

    /// Writes text readings for stills whose preview is still the one read, each with its rows
    /// in the text index in the same transaction (`SearchTextStorage.index`); returns those
    /// written. A write is a change of `.searchContent`, which a description and a search shown
    /// wait for.
    func applySearchTexts(_ results: [SearchTextResult]) async throws -> [SearchTextResult] {
        let rowIDs = roots.rowIDSnapshot()
        let applied = try await database().write { db -> [SearchTextResult] in
            var written: [SearchTextResult] = []
            for result in results {
                guard let rootID = rowIDs[result.id.libraryRootPath] else { continue }
                let key = AssetKey(rootID: rootID, path: result.id.relativePath)
                guard try Bool.fetchOne(
                    db,
                    sql: SearchTextStorage.textSourceIsCurrentSQL,
                    arguments: [result.source] + key.arguments
                ) == true else {
                    continue
                }
                try db.execute(
                    sql: SearchTextStorage.writeReadingSQL,
                    arguments: key.arguments + [result.source, SearchTextStorage.readingJSON(result.reading)]
                )
                _ = try SearchTextStorage.index(
                    searchable: SearchTextReading.searchable(result.reading), rootID: rootID, path: result.id.relativePath.rawValue, db: db
                )
                written.append(result)
            }
            return written
        }
        if !applied.isEmpty {
            notifyCatalogChanged(.changed(.searchContent, rows: .rows(Set(applied.map(\.id)))))
        }
        return applied
    }

    /// Stills owed a description (ADR 0053), newest capture first, each with the facts the
    /// model is told, but those in `excluding`, which a pass already tried and could not
    /// describe: the writer's own held keys, passed without a copy per page. Read from the roots whose stills are read for faces, since a still is
    /// described only once its faces are read. A row whose edit cannot be read is passed over
    /// and logged.
    func photoDescriptionCandidates(
        after cursor: CaptureOrderCursor? = nil,
        limit: Int,
        excluding: some Collection<MediaAssetID> & Sendable = Set<MediaAssetID>(),
        lane: CatalogReadLane
    ) async throws -> CandidatePage<PhotoDescriptionCandidate, CaptureOrderCursor> {
        let rootIDs = roots.values.filter(\.root.kind.readsFaces).map(\.rowID).sorted()
        guard !rootIDs.isEmpty else { return CandidatePage(candidates: [], next: nil) }
        let pathsByRowID = roots.pathsByRowID
        return try await reader(for: lane).readFreeingConnection { db in
            let (rows, next) = try CandidateWalk.capturePage(
                row: "a", after: cursor, limit: limit, arguments: StatementArguments(rootIDs), db: db
            ) { position, order in
                PhotoDescriptionStorage.candidatesSQL(rootCount: rootIDs.count, position: position, order: order)
            }
            let candidates = try Self.photoDescriptionCandidates(rows, pathsByRowID: pathsByRowID, excluding: excluding, db: db)
            return CandidatePage(candidates: candidates, next: next)
        }
    }

    /// Those of `ids` owed a description now, by the walk's rule, each read by its own key
    /// (`PhotoDescriptionStorage.keyedCandidateSQL`), but those in `excluding`: the stills a
    /// change named, which the writer describes without walking the backlog again. On the actor
    /// it reads only the roots; the asked ids are keyed and put in key order inside the read,
    /// off the actor, since a change can name a whole library's stills.
    func photoDescriptionCandidatesByKey(
        of ids: Set<MediaAssetID>,
        excluding: some Collection<MediaAssetID> & Sendable = Set<MediaAssetID>(),
        lane: CatalogReadLane
    ) async throws -> [PhotoDescriptionCandidate] {
        let rowIDs = roots.values.filter(\.root.kind.readsFaces).reduce(into: [LibraryRootPath: Int64]()) { $0[$1.root.path] = $1.rowID }
        guard !rowIDs.isEmpty, !ids.isEmpty else { return [] }
        let pathsByRowID = roots.pathsByRowID
        return try await reader(for: lane).readFreeingConnection { db in
            let keys = ids.compactMap { id in rowIDs[id.libraryRootPath].map { (rootID: $0, path: id.relativePath.rawValue) } }
                .sorted { ($0.rootID, $0.path) < ($1.rootID, $1.path) }
            let statement = try db.cachedStatement(sql: PhotoDescriptionStorage.keyedCandidateSQL)
            var rows: [Row] = []
            for key in keys {
                if let row = try Row.fetchOne(
                    statement,
                    arguments: AssetKey(rootID: key.rootID, path: MediaRelativePath(rawValue: key.path)).arguments
                ) {
                    rows.append(row)
                }
            }
            return try Self.photoDescriptionCandidates(rows, pathsByRowID: pathsByRowID, excluding: excluding, db: db)
        }
    }

    /// The candidates `rows` name, with the facts the model is told, but those in `excluding`.
    /// A row whose edit cannot be read is passed over and logged.
    private nonisolated static func photoDescriptionCandidates(
        _ rows: [Row],
        pathsByRowID: [Int64: LibraryRootPath],
        excluding: some Collection<MediaAssetID>,
        db: Database
    ) throws -> [PhotoDescriptionCandidate] {
        var candidates: [PhotoDescriptionCandidate] = []
        candidates.reserveCapacity(rows.count)
        for row in rows {
            guard let root = pathsByRowID[row["library_root_id"]] else { continue }
            let id = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: row["relative_path"]))
            guard !excluding.contains(id) else { continue }
            let renderedRevision: Int64 = row["rendered_revision"]
            let recipe: EditRecipe
            do {
                recipe = renderedRevision == 0 ? .neutral : try editRecipe(json: row["edit_recipe_json"]) ?? .neutral
            } catch {
                OtosLog.metadata.errorOperation("description", phase: "recipeUnreadable", fields: [
                    "relativePath": id.relativePath.rawValue, "error": String(describing: error),
                ])
                continue
            }
            let key: StatementArguments = [row["library_root_id"] as Int64, id.relativePath.rawValue]
            try candidates.append(PhotoDescriptionCandidate(
                id: id,
                previewPath: row["preview_path"],
                source: row["source"],
                recipe: recipe,
                facts: photoDescriptionFacts(db, key: key)
            ))
        }
        return candidates
    }

    /// What the model is told about one still: its faces with their people, when and where it
    /// was taken, the text Vision is certain of and its confident scene labels. A hidden
    /// person is never named. The description eval reads its sample's facts through it too
    /// (`script/description-eval.sh`), so it scores exactly what the app tells the model.
    nonisolated static func photoDescriptionFacts(_ db: Database, key: StatementArguments) throws -> PhotoDescriptionFacts {
        // Asked once per still of a page: each statement is prepared once per connection.
        let faces = try Row.fetchAll(db.cachedStatement(sql: PhotoDescriptionStorage.facesSQL), arguments: key).map { row in
            let hidden: Bool = row["hidden"]
            let name: String? = row["name"]
            let birthday: String? = row["birthday"]
            return PhotoDescriptionFacts.Face(
                box: CGRect(
                    x: row["box_x"] as Double, y: row["box_y"] as Double,
                    width: row["box_width"] as Double, height: row["box_height"] as Double
                ),
                name: hidden ? nil : name.flatMap { $0.isEmpty ? nil : $0 },
                birthday: hidden ? nil : birthday.flatMap(PersonBirthday.init)
            )
        }
        let readings = try Row.fetchOne(db.cachedStatement(sql: PhotoDescriptionStorage.readingsSQL), arguments: key)
        let captured: Double? = readings?["best_capture_local"]
        let lines: String? = readings?["lines"]
        let labels = SearchEmbeddingStorage.confidentLabels(from: readings?["confident_labels"])
        return try PhotoDescriptionFacts(
            faces: faces,
            capturedAt: captured.map(CaptureLocalTime.init(seconds:)),
            town: readings?["town"],
            country: readings?["country"],
            textLines: lines.map { try SearchTextReading.shown(SearchTextStorage.reading(fromJSON: $0), sceneLabels: labels) } ?? [],
            labels: labels
        )
    }

    /// Writes descriptions for stills whose facts are still the ones described; returns those
    /// written.
    func applyPhotoDescriptions(_ results: [PhotoDescriptionResult]) async throws -> [PhotoDescriptionResult] {
        let rowIDs = roots.rowIDSnapshot()
        return try await database().write { db -> [PhotoDescriptionResult] in
            var written: [PhotoDescriptionResult] = []
            for result in results {
                guard let rootID = rowIDs[result.id.libraryRootPath] else { continue }
                let key = AssetKey(rootID: rootID, path: result.id.relativePath)
                guard try Bool.fetchOne(
                    db,
                    sql: PhotoDescriptionStorage.descriptionSourceIsCurrentSQL,
                    arguments: [result.source] + key.arguments
                ) == true else {
                    continue
                }
                try db.execute(
                    sql: PhotoDescriptionStorage.writeDescriptionSQL,
                    arguments: key.arguments + [result.source, result.text]
                )
                written.append(result)
            }
            return written
        }
    }

    /// The current descriptions of `ids` that the model wrote, by asset; a still owed one or
    /// declined is absent. What On This Day's titles are written from.
    func currentPhotoDescriptions(for ids: [MediaAssetID], lane: CatalogReadLane) async throws -> [MediaAssetID: String] {
        let rowIDs = roots.rowIDSnapshot()
        return try await reader(for: lane).readFreeingConnection { db in
            var texts: [MediaAssetID: String] = [:]
            for id in ids {
                guard let rootID = rowIDs[id.libraryRootPath],
                      let text = try String.fetchOne(
                          db, sql: PhotoDescriptionStorage.currentRowSQL, arguments: AssetKey(rootID: rootID, path: id.relativePath).arguments
                      )
                else {
                    continue
                }
                texts[id] = text
            }
            return texts
        }
    }

    /// The assets whose current text reading one of `queries` matches (ADR 0048, "Text in the
    /// photo"), from one read of the text index: the readings holding a word each query word
    /// begins (`SearchTextStorage.matchSQL`), each decided by `SearchTextQuery.matches(folded:)`,
    /// so the answer is exactly the matches over every current reading. Any root's, read now or
    /// not: the caller's scope says which it searches. `candidates` is how many rows the index
    /// returned.
    func searchTextMatches(_ queries: [SearchTextQuery], lane: CatalogReadLane) async throws -> SearchTextMatches {
        guard let expression = SearchTextStorage.indexExpression(queries) else {
            return SearchTextMatches(ids: [], candidates: 0)
        }
        let pathsByRowID = roots.pathsByRowID
        return try await reader(for: lane).readFreeingConnection(operation: "searchTextMatches") { db in
            let rows = try Row.fetchCursor(db.cachedStatement(sql: SearchTextStorage.matchSQL), arguments: [expression])
            var ids: Set<MediaAssetID> = []
            var candidates = 0
            while let row = try rows.next() {
                candidates += 1
                let folded: String = row[2]
                guard let root = pathsByRowID[row[0]], queries.contains(where: { $0.matches(folded: folded) }) else { continue }
                ids.insert(MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: row[1])))
            }
            return SearchTextMatches(ids: ids, candidates: candidates)
        }
    }

    /// The stills the same-photo rule compares (`SamePhotoSQL`), with the column facts it
    /// proposes pairs from and the stamp their evidence is read at, from the indexes that hold
    /// exactly those. Renders and record facts are read separately, only for the stills a
    /// proposed pair names whose evidence is not held at that stamp (`samePhotoEvidence`).
    func samePhotoCandidates(availableLibraryPaths: Set<LibraryRootPath>, lane: CatalogReadLane) async throws -> [SamePhotoCandidate] {
        let libraries = roots.values.filter { $0.root.kind.isMemberOfAllMedia && availableLibraryPaths.contains($0.path) }
        guard !libraries.isEmpty else {
            return []
        }
        let rootIDs = libraries.map(\.rowID).sorted()
        let pathsByRowID = Dictionary(uniqueKeysWithValues: libraries.map { ($0.rowID, $0.path) })
        return try await reader(for: lane).readFreeingConnection { db in
            try DuplicatesGateway.fetchSamePhotoCandidates(rootIDs: rootIDs, pathsByRowID: pathsByRowID, db: db)
        }
    }

    /// The evidence of these stills, which are in proposed pairs: the render signature and
    /// the sub-seconds kept in the metadata record. A still whose library is gone or that has
    /// no stored signature has none. Read `samePhotoReadBatch` stills a transaction, so a build
    /// proposing thousands of pairs never holds a reader for all of them.
    func samePhotoEvidence(for ids: [MediaAssetID], lane: CatalogReadLane) async throws -> [MediaAssetID: SamePhotoEvidence] {
        let rowIDs = roots.rowIDSnapshot()
        return try await samePhotoBatches(lane: lane, of: ids, operation: "samePhotoEvidence") { id, db in
            guard let rowID = rowIDs[id.libraryRootPath] else {
                return nil
            }
            return try DuplicatesGateway.fetchSamePhotoEvidence(rootID: rowID, id: id, db: db)
        }
    }

    /// The copies a group lists for these stills, which are in confirmed groups. Read fresh
    /// for every build: a choice, an edit or a companion changes a copy without moving the
    /// evidence that grouped it.
    func samePhotoCopies(for ids: [MediaAssetID], lane: CatalogReadLane) async throws -> [MediaAssetID: DuplicateCopy] {
        let libraries = Dictionary(uniqueKeysWithValues: roots.values.map {
            ($0.path, (rowID: $0.rowID, library: DuplicateLibrary($0.root)))
        })
        return try await samePhotoBatches(lane: lane, of: ids, operation: "samePhotoCopies") { id, db in
            guard let library = libraries[id.libraryRootPath] else {
                return nil
            }
            return try DuplicatesGateway.fetchSamePhotoCopy(rootID: library.rowID, id: id, library: library.library, db: db)
        }
    }

    static let samePhotoReadBatch = 256

    /// One point read per still, `samePhotoReadBatch` stills a transaction: each still's
    /// answer stands alone.
    private func samePhotoBatches<Value: Sendable>(
        lane: CatalogReadLane,
        of ids: [MediaAssetID],
        operation: String,
        read: @escaping @Sendable (MediaAssetID, Database) throws -> Value?
    ) async throws -> [MediaAssetID: Value] {
        var values: [MediaAssetID: Value] = [:]
        for start in stride(from: 0, to: ids.count, by: Self.samePhotoReadBatch) {
            let batch = Array(ids[start ..< min(start + Self.samePhotoReadBatch, ids.count)])
            let read = try await reader(for: lane).readFreeingConnection(operation: operation) { db in
                var values: [MediaAssetID: Value] = [:]
                for id in batch {
                    values[id] = try read(id, db)
                }
                return values
            }
            values.merge(read) { $1 }
        }
        return values
    }
}

/// What one scan pass observed and how many rows it changed, counted by the Store as each
/// batch is applied. One pass's own count, made by the one task that runs it and read when
/// it ends: the rows a pass changed decide whether its companions need the writer, and the
/// pass's finish line reports both.
final nonisolated class ScanWriteTally: Sendable {
    private let counts = Mutex((observed: 0, written: 0))

    func observed(_ count: Int) {
        counts.withLock { $0.observed += count }
    }

    func wrote(_ count: Int) {
        counts.withLock { $0.written += count }
    }

    var filesObserved: Int {
        counts.withLock { $0.observed }
    }

    var rowsWritten: Int {
        counts.withLock { $0.written }
    }
}
