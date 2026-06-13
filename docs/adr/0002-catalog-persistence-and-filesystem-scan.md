# ADR 0002: Catalog Persistence And Filesystem Scan State

## Status

Proposed

## Context

Otos needs an app-owned catalog for user-selected media roots. Originals remain
read-only on disk, while Otos stores catalog state in Application Support.

This ADR decides the initial catalog persistence layer, the exact filesystem
scan state stored in SQLite, and how scan updates reach SQLite and SwiftUI. It
does not decide metadata extraction, thumbnail generation, thumbnail storage,
preview storage, editing state, export state, security-scoped bookmark policy,
or the full library-root access schema.

Verified repo facts:

- There is no existing persistence dependency or catalog implementation.
- The current app is a SwiftUI macOS shell with an instrumentation facade in
  `Otos/Support/Instrumentation.swift`.
- `docs/requirements.md` is the current implemented-requirements registry only;
  unimplemented catalog behavior belongs in specs and ADRs until it lands.
- Relevant current requirements include FND-001, FND-002, FND-006, FND-007,
  FND-008, FND-009, FND-011, FND-014, FND-015, MED-001, MED-002, MED-003, and
  APP-001.

Verified macOS API facts from the configured Xcode 27 beta SDK:

- `FileManager.enumerator(at:includingPropertiesForKeys:options:errorHandler:)`
  returns a deep `DirectoryEnumerator` of `URL` values.
- The `includingPropertiesForKeys` argument identifies `URLResourceKey` values
  to prefetch and cache on returned URLs.
- The URL enumerator does not resolve symbolic links or recurse through symbolic
  links that point to directories.
- If the enumerated directory contains a mount point, the URL enumerator
  traverses the mount point.
- `URLResourceValues` exposes optional filesystem values such as
  `isRegularFile`, `isDirectory`, `isSymbolicLink`, `contentModificationDate`,
  `fileIdentifier`, `fileContentIdentifier`, and `fileSize`.
- `NSURLContentTypeKey` returns a `UTType` for a file-system resource.
- `NSURLFileResourceIdentifierKey` and `NSURLVolumeIdentifierKey` are not
  persistent across system restarts, so they are not durable catalog keys.

Captured user guidance for verification:

- Use SQLite for the catalog.
- Use GRDB as the Swift SQLite access layer.
- Keep the app as simple as possible.
- Performance-oriented complexity comes after correctness, simplicity, and
  clear ownership.
- Keep the initial model simple: one authoritative row per scanned media asset.
- Begin the asset row with exactly defined filesystem facts.
- Remove metadata and thumbnail fields from this ADR because their shape is not
  known yet.
- Do not include guesses, speculative fields, or future schema placeholders.
- Everything stored in the SQLite catalog should be loaded into the in-memory
  catalog working set until evidence or an explicit requirement proves
  otherwise.
- During filesystem scans, SQLite writes happen at 10 Hz, not based on the
  number of scanned files.
- During filesystem scans, SwiftUI-visible updates happen at 10 Hz, not based on
  the number of scanned files.
- ADRs should have clear MECE scope: each decision record owns one coherent
  decision area, names adjacent decisions, and does not decide unrelated future
  architecture.

## MECE Decision Scope

This ADR owns:

- SQLite as the catalog persistence choice.
- GRDB as the Swift SQLite access layer.
- `DatabaseQueue` as the initial GRDB connection owner.
- Full in-memory loading of the current SQLite catalog working set.
- The exact initial filesystem scan schema for scan runs and media asset rows.
- The macOS filesystem resource keys requested during the initial scan.
- The 10 Hz time-based cadence for filesystem scan SQLite flushes.
- The 10 Hz time-based cadence for SwiftUI-visible filesystem scan updates.

This ADR references, but does not own:

- `library_root_id` as an Otos-generated UUID primary key for a user-selected
  root.
- The existence of a library-root table that future filesystem-access work will
  define.
- Read-only treatment of user originals, which is already owned by MED-001.

Separate ADRs or specs must own:

- Filesystem access, security-scoped bookmarks, root registration, root display
  names, and root restoration.
- Which files are eligible media assets beyond being regular files.
- Move and rename detection.
- Metadata extraction, metadata schema, metadata freshness, and metadata scan
  cadence.
- Thumbnail generation, thumbnail storage, thumbnail schema, thumbnail
  freshness, and thumbnail scan cadence.
- Preview, render, edit, export, analysis, embedding, or search-index storage.
- File watching or incremental change notification outside explicit scan runs.
- Any decision to make filesystem-provided identifiers durable media identity.

## Decision

Use GRDB with app-bundled SQLite as the catalog persistence layer.

Create one app-owned catalog owner that owns the GRDB writer and the in-memory
catalog working set for the app lifetime. Open the database at launch, run
migrations, load the SQLite catalog into memory, and treat SQLite as the durable
source after relaunch, crash recovery, and migration.

Start with `DatabaseQueue`. Do not use `DatabasePool`, WAL-specific tuning, a
separate cache layer, or a query-paging architecture until measurements or
implemented requirements prove the simple path is insufficient.

### macOS Scan Input

The filesystem scanner uses `FileManager` URL enumeration with this requested
resource-key set:

- `isRegularFileKey`
- `isDirectoryKey`
- `isSymbolicLinkKey`
- `contentModificationDateKey`
- `fileSizeKey`
- `fileIdentifierKey`
- `fileContentIdentifierKey`
- `contentTypeKey`

The initial enumeration options are `[]`. This means the scanner does not skip
hidden files, package descendants, subdirectory descendants, or mount points
through `FileManager.DirectoryEnumerationOptions` in this ADR.

Only regular files become `media_asset` rows. Directories, symbolic links, and
non-regular filesystem objects are scan traversal or filtering inputs, not media
asset rows.

If a requested resource value is unavailable for an observed regular file, the
corresponding nullable SQLite field is `NULL`. The app must not invent missing
filesystem facts.

### ID Contracts

`library_root_id` is an Otos-generated UUID string assigned when a user-selected
root is registered with Otos. It is not a filesystem inode, bookmark identifier,
path, URL, or Apple-provided resource value. It is the primary key of the
library-root record defined by the filesystem-access ADR or implementation spec.

`media_asset.id` is an Otos-generated UUID string assigned when the catalog first
creates a row for a `(library_root_id, relative_path)` pair. It remains stable
for that row. Rename and move detection are not defined by this ADR; if a file is
later observed at a different `relative_path`, that behavior needs its own
requirement or ADR.

`filesystem_scan.id` is an Otos-generated UUID string assigned to one scan run
for one library root.

### SQLite Schema

All IDs are stored as lowercase hyphenated UUID strings in `TEXT` columns.
All date values are stored as `REAL` seconds since the Unix epoch in UTC, using
`Date.timeIntervalSince1970`.

#### `filesystem_scan`

| Column | SQLite type | Null | Definition |
| --- | --- | --- | --- |
| `id` | `TEXT` | no | Otos-generated UUID for one scan run. |
| `library_root_id` | `TEXT` | no | Otos-generated UUID of the scanned library root. |
| `started_at_unix` | `REAL` | no | Otos clock time when the scan run started. |
| `finished_at_unix` | `REAL` | yes | Otos clock time when the scan run reached `completed`, `cancelled`, or `failed`. |
| `status` | `TEXT` | no | One of `running`, `completed`, `cancelled`, or `failed`. |

`filesystem_scan.library_root_id` references the library-root table's `id`.

#### `media_asset`

| Column | SQLite type | Null | Definition |
| --- | --- | --- | --- |
| `id` | `TEXT` | no | Otos-generated UUID for this catalog row. |
| `library_root_id` | `TEXT` | no | Otos-generated UUID of the containing library root. |
| `relative_path` | `TEXT` | no | Root-relative file-system path string from the library root to the item, with no leading slash. It is derived by removing the scanned root URL's standardized file-system path plus one path separator from the observed file URL's standardized file-system path. This is not localized display text. |
| `content_type_identifier` | `TEXT` | yes | `UTType.identifier` from `NSURLContentTypeKey`, when available. |
| `byte_size` | `INTEGER` | yes | File size in bytes from `URLResourceValues.fileSize`. |
| `content_modified_at_unix` | `REAL` | yes | Content modification date from `URLResourceValues.contentModificationDate`, encoded as Unix seconds. |
| `file_identifier` | `TEXT` | yes | Decimal string encoding of `URLResourceValues.fileIdentifier` (`UInt64`) when available. It is not globally stable and is not a primary key. |
| `file_content_identifier` | `INTEGER` | yes | `URLResourceValues.fileContentIdentifier` (`Int64`) when available. |
| `first_seen_scan_id` | `TEXT` | no | `filesystem_scan.id` for the scan run that first created this row. |
| `last_seen_scan_id` | `TEXT` | no | `filesystem_scan.id` for the most recent scan run that observed this path. |
| `missing_since_scan_id` | `TEXT` | yes | First completed scan run that did not observe this row's `relative_path`; `NULL` means not currently marked missing. |
| `created_at_unix` | `REAL` | no | Otos clock time when this row was first inserted. |
| `updated_at_unix` | `REAL` | no | Otos clock time when this row was last changed by a scan flush. |

Constraints:

- `media_asset.library_root_id` references the library-root table's `id`.
- `media_asset.first_seen_scan_id`, `last_seen_scan_id`, and
  `missing_since_scan_id` reference `filesystem_scan.id`.
- `(library_root_id, relative_path)` is unique.

Fields deliberately not stored by this ADR:

- `URLResourceValues.fileResourceIdentifier`
- `URLResourceValues.volumeIdentifier`
- absolute paths in `media_asset`
- localized names
- Finder tags, labels, comments, or quarantine information
- media metadata
- thumbnail status, paths, bytes, or generation state
- raw EXIF, XMP, QuickTime, ImageIO, AVFoundation, analysis, embedding, preview,
  render, or edit payloads

### Scan Update Cadence

During a filesystem scan, discovered asset changes are accumulated by the catalog
owner and flushed to SQLite at 10 Hz when pending changes exist. This is a
time-based cadence: every 100 ms, not a file-count threshold.

The catalog owner publishes SwiftUI-visible scan state at 10 Hz when pending
view changes exist. This is also time-based: every 100 ms, not a scanned-file
threshold.

If a SQLite flush takes longer than one tick, the next tick coalesces pending
changes. The catalog owner must not run overlapping SQLite writes for one
catalog.

At scan end, cancellation, or failure, the catalog owner performs one final
flush before changing the `filesystem_scan.status` away from `running`.

## Alternatives Considered

### Raw sqlite3

Pros:

- No third-party Swift package dependency.
- Maximum control over SQLite configuration, statements, and transactions.

Cons:

- High boilerplate for statement preparation, binding, decoding, migrations,
  transactions, and error handling.
- Less idiomatic Swift API surface for a SwiftUI macOS app.

Failure modes:

- Statement lifetime bugs, missed finalization, accidental main-actor database
  work, and inconsistent migration behavior.

### SQLite.swift

Pros:

- Swift wrapper over SQLite with a lightweight query-builder style.
- Easier than raw sqlite3 for simple CRUD.

Cons:

- Less complete than GRDB for migrations, transaction ergonomics, and explicit
  database-reader/database-writer boundaries.

Failure modes:

- Later catalog work forces a second local persistence abstraction around the
  wrapper.

### GRDB With Query-Backed SwiftUI State

Pros:

- SQLite remains the only live catalog state.
- Reduces duplicated in-memory representation.

Cons:

- Adds observation/query-projection decisions before the first catalog behavior
  proves it needs them.
- Conflicts with the simplicity-first guidance to retain the SQLite catalog in
  memory until proven otherwise.

Failure modes:

- SwiftUI view code becomes coupled to database query shapes.
- Observation invalidation becomes the first catalog architecture problem.

### Selected: GRDB With Full In-Memory Catalog Working Set

Pros:

- Keeps SQLite explicit and durable while preserving simple SwiftUI reads.
- Loads every SQLite catalog row into memory by default, matching user guidance.
- Avoids paging, pooling, and database-observation complexity before evidence
  proves it is needed.
- Keeps one app-owned owner responsible for synchronizing memory and disk.

Cons:

- Creates two representations that must remain synchronized: SQLite durability
  and the in-memory working set.
- Full startup load can become visible launch work if future schema rows grow.
- Memory pressure becomes the app's responsibility as catalog columns grow.

Failure modes:

- A write succeeds in memory but fails on disk, or succeeds on disk but does not
  update memory.
- Later schema work adds large columns without revisiting the in-memory loading
  rule in a separate decision.

### Durable File IDs As Asset Identity

Pros:

- Could preserve identity across renames when a stable filesystem identifier is
  available.

Cons:

- `NSURLFileResourceIdentifierKey` and `NSURLVolumeIdentifierKey` are explicitly
  not persistent across system restarts.
- `URLResourceValues.fileIdentifier` is not globally stable across all file
  systems or mounts.
- Move and rename identity is a separate product behavior, not required for the
  initial filesystem scan catalog.

Failure modes:

- A filesystem-provided identifier is treated as a permanent media identity when
  Apple does not define it that way.

## Consequences

The first catalog implementation has one durable SQLite catalog, one app-owned
in-memory working set, and one row per scanned media asset path.

The schema contains only filesystem scan facts and Otos bookkeeping. Metadata
and thumbnails cannot be implemented by filling in placeholder fields from this
ADR; they require a later spec or ADR with exact fields.

The selected pattern constrains implementation:

- no direct database calls from SwiftUI views
- no metadata or thumbnail columns in the initial catalog schema
- no absolute paths in `media_asset`
- no durable use of `fileResourceIdentifier` or `volumeIdentifier`
- no main-actor filesystem traversal or database work
- no count-based scan flush threshold
- SQLite scan flushes at 10 Hz when pending changes exist
- SwiftUI-visible scan updates publish at 10 Hz when pending changes exist
- no logging of user media paths, filenames, thumbnails, metadata payloads, or
  user-authored metadata

## Retirement Proof

No existing catalog implementation is being replaced.

Before implementation, prove there are no stale catalog paths by checking for:

- existing SQLite or persistence dependencies
- app-owned catalog stores
- media asset models
- scanner construction paths
- thumbnail or metadata persistence paths
- tests or fixtures that assume a different catalog model
- docs that describe a different implemented catalog behavior

## Reversal Plan

If GRDB proves wrong, replace the persistence boundary behind the app-owned
catalog owner. Views and scanner workers should depend on Otos-owned catalog
interfaces and values, not GRDB types directly.

If the in-memory working set proves too large, measure startup time, memory, and
interaction latency before introducing paging or query-backed views.

If 10 Hz scan flushing proves too frequent or too sparse, change the cadence
through a new requirement or ADR update with measured evidence.
