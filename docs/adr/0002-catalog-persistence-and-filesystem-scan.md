# ADR 0002: Catalog Persistence And Filesystem Reconciliation

## Status

Proposed

## Context

Otos needs an app-owned catalog for user-selected media roots. Originals remain
read-only on disk, while Otos stores catalog state in Application Support.

This ADR decides the initial catalog persistence layer, the exact filesystem
facts stored in SQLite for scanned media assets, and how scan updates reach
SQLite and SwiftUI. It does not decide metadata extraction, thumbnail
generation, thumbnail storage, preview storage, editing state, export state,
security-scoped bookmark policy, or the full library-root access schema.

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
  and `fileSize`.
- `NSURLContentTypeKey` returns a `UTType` for a file-system resource.
- `NSURLFileIdentifierKey` is the file system's internal inode identifier for
  an item and is not stable across all file systems or mounts.
- `NSURLFileContentIdentifierKey` is a 64-bit APFS value that identifies a
  file's content data stream.
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
- The filesystem is the source of truth for current library and media
  existence.
- Do not generate Otos UUIDs for media assets in the initial catalog.
- Do not store individual filesystem scan records in the initial catalog.
- Filesystem scans are idempotent reconciliation operations.
- If a completed scan of a library root does not observe a previously cataloged
  file at that root-relative path, delete that media asset row.
- Do not store first-seen, last-seen, or missing-since scan markers.
- Do not store filesystem identifier fields in the initial media asset row
  unless a current requirement names a use for them.

## MECE Decision Scope

This ADR owns:

- SQLite as the catalog persistence choice.
- GRDB as the Swift SQLite access layer.
- `DatabaseQueue` as the initial GRDB connection owner.
- Full in-memory loading of the current SQLite catalog working set.
- The exact initial filesystem scan schema for media asset rows.
- The macOS filesystem resource keys requested during the initial scan.
- The 10 Hz time-based cadence for filesystem scan SQLite flushes.
- The 10 Hz time-based cadence for SwiftUI-visible filesystem scan updates.

This ADR references, but does not own:

- The existence of a selected library-root record that future filesystem-access
  work will define.
- `library_root_id` as a reference to that selected library-root record, without
  deciding the root identifier format or generation policy.
- Read-only treatment of user originals, which is already owned by MED-001.

Separate ADRs or specs must own:

- Filesystem access, sandbox posture, root registration, root display names,
  and root restoration.
- Which files are eligible media assets beyond being regular files.
- Move and rename detection.
- Metadata extraction, metadata schema, metadata freshness, and metadata scan
  cadence.
- Thumbnail generation, thumbnail storage, thumbnail schema, thumbnail
  freshness, and thumbnail scan cadence.
- Preview, render, edit, export, analysis, embedding, or search-index storage.
- File watching or incremental change notification outside explicit scan runs.
- Durable scan history, audit logs, resumable scans, or scan diagnostics beyond
  privacy-safe instrumentation.
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

### Identity And Reconciliation Contracts

The filesystem is the source of truth for whether a media file currently exists
inside a selected library root.

`library_root_id` refers to the selected library-root record that owns the
scanned root. This ADR does not define the library-root table, root identifier
format, bookmark storage, root display name, or root restoration behavior. Those
decisions belong to the filesystem-access ADR or implementation spec.

`media_asset` identity is the pair `(library_root_id, relative_path)`. Otos does
not generate a separate media asset UUID in the initial catalog.

A filesystem scan is an idempotent reconciliation operation, not a durable
domain entity. The initial catalog has no `filesystem_scan` table and no scan
IDs.

For a completed scan of one library root:

- observed regular-file paths are inserted or updated in `media_asset`
- existing `media_asset` rows for that root whose `relative_path` was not
  observed are deleted

The initial catalog does not retain first-seen, last-seen, missing-since, scan
history, or tombstone state. Move and rename behavior is out of scope; in this
ADR, a file that appears at a new root-relative path is a new row, and a file no
longer observed at its old root-relative path is deleted.

### SQLite Schema

All date values are stored as `REAL` seconds since the Unix epoch in UTC, using
`Date.timeIntervalSince1970`.

#### `media_asset`

| Column | SQLite type | Null | Definition |
| --- | --- | --- | --- |
| `library_root_id` | `TEXT` | no | Identifier of the selected library-root record that owns the scanned root. The value format is defined by the filesystem-access ADR or implementation spec. |
| `relative_path` | `TEXT` | no | Root-relative file-system path string from the library root to the item, with no leading slash. It is derived by removing the scanned root URL's standardized file-system path plus one path separator from the observed file URL's standardized file-system path. This is not localized display text. |
| `content_type_identifier` | `TEXT` | yes | `UTType.identifier` from `NSURLContentTypeKey`, when available. |
| `byte_size` | `INTEGER` | yes | File size in bytes from `URLResourceValues.fileSize`. |
| `content_modified_at_unix` | `REAL` | yes | Content modification date from `URLResourceValues.contentModificationDate`, encoded as Unix seconds. |

Constraints:

- `media_asset.library_root_id` references the library-root table's `id`.
- `(library_root_id, relative_path)` is the primary key.

Fields deliberately not stored by this ADR:

- `media_asset.id`
- `filesystem_scan` rows or scan IDs
- first-seen, last-seen, missing-since, or tombstone state
- `URLResourceValues.fileIdentifier`
- `URLResourceValues.fileContentIdentifier`
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
flush of pending observed-file changes. Deletion of unobserved existing rows
happens only after a completed scan of that library root, not after a cancelled
or failed scan.

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
- Could help detect hard links, APFS clones, or content-sharing cases in a later
  feature.

Cons:

- `NSURLFileResourceIdentifierKey` and `NSURLVolumeIdentifierKey` are explicitly
  not persistent across system restarts.
- `URLResourceValues.fileIdentifier` is not globally stable across all file
  systems or mounts.
- `URLResourceValues.fileContentIdentifier` identifies an APFS content data
  stream, not the file's path identity.
- Move and rename identity is a separate product behavior, not required for the
  initial filesystem scan catalog.

Failure modes:

- A filesystem-provided identifier is treated as a permanent media identity when
  Apple does not define it that way.

### Generated Media UUIDs

Pros:

- Could provide a compact internal handle for future overlays that need stable
  identity independent of path.
- Could make foreign keys simple if later tables attach to media assets.

Cons:

- Adds app-owned identity before a current requirement needs it.
- Makes the catalog look more authoritative than the filesystem for media
  existence.
- Requires behavior decisions for moves, renames, deletes, and reappearing files
  that are outside this ADR.

Failure modes:

- A stale UUID row survives after the filesystem no longer contains the file.
- Later features depend on UUID stability before the product defines what file
  identity means across moves or renames.

### Durable Scan Records

Pros:

- Could support audit history, resumable scans, or detailed diagnostics later.
- Could explain when a row was first seen, last seen, or marked missing.

Cons:

- Treats an idempotent reconciliation operation as a durable domain entity.
- Adds scan IDs, scan status, first-seen, last-seen, and missing-since state
  before a current requirement needs them.
- Preserves missing-file history when the current desired behavior is to delete
  missing rows after a completed scan.

Failure modes:

- Future work reads scan history as authoritative product state.
- A cancelled or failed scan accidentally marks files missing.

## Consequences

The first catalog implementation has one durable SQLite catalog, one app-owned
in-memory working set, and one row per currently observed scanned media asset
path.

The schema contains only current filesystem facts for media assets. Metadata and
thumbnails cannot be implemented by filling in placeholder fields from this ADR;
they require a later spec or ADR with exact fields.

Completed scans reconcile each selected root to the filesystem's current state.
Rows observed during the scan are inserted or updated. Rows not observed after a
completed scan are deleted.

The selected pattern constrains implementation:

- no direct database calls from SwiftUI views
- no generated media asset UUID in the initial catalog
- no durable `filesystem_scan` table
- no first-seen, last-seen, missing-since, or tombstone columns
- no metadata or thumbnail columns in the initial catalog schema
- no absolute paths in `media_asset`
- no durable use of `fileIdentifier`, `fileContentIdentifier`,
  `fileResourceIdentifier`, or `volumeIdentifier`
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

If durable scan history or media UUIDs become necessary, add them through a new
requirement and migration that defines the product behavior they support.
