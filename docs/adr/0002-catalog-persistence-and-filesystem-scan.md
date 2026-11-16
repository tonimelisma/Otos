# ADR 0002: Catalog Persistence And Filesystem Reconciliation

- Status: Accepted
- Last updated: 2026-07-10

## Context

Otos needs an app-owned catalog for user-selected media roots. Originals remain
read-only on disk, while Otos stores catalog state in Application Support.

This ADR decides the initial catalog persistence layer, the exact filesystem
facts stored in SQLite for scanned media assets, and how scan updates reach
SQLite and SwiftUI. It does not decide metadata extraction, thumbnail
generation, thumbnail storage, preview storage, editing state, export state,
or the full library-root access schema.

Verified repo facts:

- `CatalogStore` is the single actor owner of GRDB, root runtime state, scan
  lifecycle, filesystem-event coalescing, and Store-owned catalog query APIs.
- File-backed catalog locations use a GRDB `DatabasePool`; `.inMemory` test
  locations use a GRDB `DatabaseQueue`.
- SQLite is the per-asset working set. The Store keeps root identity,
  availability, scan lifecycle, and notification state resident, but it no
  longer keeps a resident per-asset map or publishes raw catalog snapshots.
- The current app is a SwiftUI macOS app with an instrumentation facade in
  `Otos/Support/Instrumentation.swift`.
- `docs/requirements.md` is the current implemented-requirements registry only;
  unimplemented catalog behavior belongs in ADRs and plans until it lands.
- Relevant current requirements include ARC-003, ARC-004, ARC-006, ARC-008,
  MED-001, MED-002, APP-001, and APP-006.

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
  `name`, `isRegularFile`, `isDirectory`, `isSymbolicLink`, `creationDate`,
  `contentModificationDate`, and `fileSize`.
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
- During filesystem scans, SQLite writes happen on a time cadence, not based on
  the number of scanned files. ADR 0011 currently sets this background cadence
  to roughly one second.
- During filesystem scans, SwiftUI-visible updates happen on Projection's
  background publication cadence, not based on the number of scanned files. ADR
  0011 currently sets this background cadence to roughly one second while direct
  user query intents publish immediately.
- ADRs should have clear MECE scope: each decision record owns one coherent
  decision area, names adjacent decisions, and does not decide unrelated future
  architecture.
- The filesystem is the source of truth for current library and media
  existence.
- Do not generate Otos UUIDs for media assets in the initial catalog.
- Do not store individual filesystem scan records in the catalog.
- Filesystem scans are idempotent reconciliation operations.
- If a completed scan of a library root does not observe a previously cataloged
  file at that root-relative path, delete that media asset row.
- Do not store first-seen, last-seen, or missing-since scan markers.
- Do not store filesystem identifier fields in the initial media asset row
  unless a current requirement names a use for them.
- Store the scanner's current filesystem fact set plus `name` and
  `creationDate`; do not broaden the schema to every available URL resource
  value.

## MECE Decision Scope

This ADR owns:

- SQLite as the catalog persistence choice.
- GRDB as the Swift SQLite access layer.
- GRDB connection ownership: `DatabasePool` for file-backed locations and
  `DatabaseQueue` for `.inMemory` tests.
- SQLite as the per-asset working set, with Store-owned query APIs instead of a
  resident per-asset map.
- The exact initial filesystem scan schema for media asset rows.
- The macOS filesystem resource keys requested during the initial scan.
- The time-based cadence for filesystem scan SQLite flushes.
- The time-based cadence for SwiftUI-visible filesystem scan updates, as refined
  by ADR 0011's two-tier publication model.
- Scan-time media eligibility: which regular files become `media_asset` rows based on
  `NSURLContentTypeKey` and `UTType` conformance.
- Running-app filesystem watching: macOS FSEvents are hints acted on as they
  arrive, one pass per root at a time. Store
  accumulates typed dirty scopes (file / subtree / root) per root and reconciles
  the narrowest safely known scope. Events during an active lease retain their
  granularity in the next dirty generation instead of forcing a full-root rescan.

This ADR references, but does not own:

- The existence of a selected library-root record that library-root access work
  defines.
- `library_root_id` as a reference to that selected library-root record, without
  deciding the root identifier format or generation policy.
- Read-only treatment of user originals, which is already owned by MED-001.

Separate ADRs or specs must own:

- Filesystem access policy, root registration, root display names, and root
  restoration.
- Move and rename detection.
- Metadata extraction, metadata schema, metadata freshness, and enrichment
  scheduling (ADR 0009).
- Thumbnail generation, thumbnail storage, thumbnail schema, thumbnail
  freshness, and enrichment scheduling (ADR 0009).
- Identity-grid publication and visible detail reads (ADR 0010).
- Camera package, AVCHD, XAVC, or other compound media-container import
  workflows.
- Preview, render, edit, export, analysis, embedding, or search-index storage.
- Per-path incremental filesystem-event catalog updates (V2).
- Scan diagnostics stored in SQLite as product state.
- Any decision to make filesystem-provided identifiers durable media identity.

## Decision

Use GRDB with app-bundled SQLite as the catalog persistence layer.

Create one app-owned catalog owner that owns the GRDB writer, root runtime state,
scan lifecycle, and catalog query APIs for the app lifetime. Open the database at
launch, initialize the clean current schema, load saved roots and counts, and
treat SQLite as the durable per-asset working set after relaunch and crash
recovery.

Use `DatabasePool` with WAL for file-backed locations so Store-owned projection,
grid-detail, and enrichment reads can run alongside serialized writes. Keep
`.inMemory` test locations on `DatabaseQueue`, because GRDB pools require files.
File-backed pools use `maximumReaderCount = 4`. Those readers are shared by every
background read — the window's order and options, enrichment's claims, the derived owners'
builds — and at 164,517 assets with an account enriching, each of those holds a reader for
seconds; a visible tile's detail read then waited 2.5–4.5 s for one, with 0 ms of its own
work (`docs/research/2026-11-14-scope-switch-and-background-laps.md`; at ~23k assets the
same wait's p95 was 17 ms, `docs/research/2026-07-10-grdb-reader-pool-qos.md`). So a
file-backed Store also opens a second, read-only `DatabasePool` of two readers on the same
file after migrating it (`CatalogStore.interactiveReader`), and the reads a user waits on
with something on screen — the visible tiles' details and the inspector's item — use only
it. No background read can occupy it, so it never queues behind one. It is not a cache:
every read is a SQLite read of the current WAL snapshot. A read reaches its connection
through the Store actor, so the Store keeps O(rows) work off itself: an order read turns
its rows into the window's IDs inside the read, on the connection's queue, because at
166,000 rows that mapping held the Store for half a second per read and every visible
tile's read queued behind it (`docs/research/2026-11-15-shared-reader-waits.md`). Readers
wait on SQLite's locks through a busy handler of the Store's own (`ReaderLockWait`, with
GRDB's ten-second limit), so a read's log line tells the wait for a lock (`lockMs`) from
the wait for a connection, and a detail read's line carries the wait for the Store itself
(`storeMs`). Every connection of both pools reports its transaction, first statement and
the Store's name for it to `CatalogConnectionActivity` through its SQLite trace, and a read
that waited a second or more writes `op=catalog.store.stall` as its body starts: its wait
split at the instant its connection began it, and, on `op=catalog.store.stall.holders`
parts beside it, what every other connection was running or ended during the wait
(`docs/research/2026-11-15-startup-read-stalls.md`). A truncating checkpoint (below) can find one of its short
reads in flight; the checkpoint then fails, is logged, and the next bulk write retries it.
Raising the shared pool's reader count was rejected: background work fans out to fill any
count.
Do not add a second cache
layer or query-paging architecture until measurements or implemented
requirements prove the current Store-owned query model insufficient.

Store keeps the WAL bounded. SQLite resets its write-ahead log only at an instant no
reader is using it, so readers that overlap one another back to back — the window,
enrichment and the derived owners while a library or account is listed — starve its
automatic checkpoint and the log grows without end: 257 MB in the installed app during
a 147k-asset Immich first sync, 357 MB in a 100k-row listing probe whose log stayed at
25 MB with no reader (`docs/research/2026-11-12-listing-batch-cost.md`). After every
bulk write (a scan batch, a device- or source-listing batch, an enrichment batch) Store
reads the WAL file's size: a log SQLite keeps resetting is reused from its start, so
its file stays near one write's pages, and only a starved one keeps growing. The read is logged only when the file grew past the largest size logged since the last truncation (`op=catalog.database.wal phase=grew`): a reused log's file keeps its size, so a line per batch (586 in 20 minutes at 57 MB, under the budget) said nothing new. Past
`CatalogStore.defaultWALByteBudget` (64 MiB, about two and a half times the unstarved
high-water mark) Store truncates the log behind GRDB's barrier, which waits for the
reads in flight and holds new ones until the log is empty. The barrier is GRDB's callback form, so the wait blocks GRDB's queue rather than
a cooperative thread. A failed checkpoint is logged and the next bulk write retries.
Rejected: a passive checkpoint after every bulk write to read the log's frame count
(it backfills pages SQLite otherwise batches, every batch); a periodic
checkpoint (time standing in for the log's own size, ADR 0033);
raising `wal_autocheckpoint` (a passive checkpoint still cannot reset a log readers
hold); `journal_size_limit` alone (it applies only at a reset, which starvation
prevents).

### Schema Migrations At Launch

The catalog opens, and migrates, before the window can show any of it: on the owner's 2.5 GB
catalog the first launches after new migrations took 22–43 s against 9–86 ms for one with
none, and the log said nothing about the wait
(`docs/research/2026-11-15-catalog-open-cost.md`). So:

- **The open explains itself.** Store applies pending migrations one at a time, in
  registration order (`CatalogStore.applyPendingMigrations`), each between
  `op=catalog.migration phase=start` and `phase=finish … ms=` lines that name it and its step;
  `op=catalog.database.open` times every other step (`poolMs`, `schemaMs` — where SQLite
  recovers a log the last process left, `walBytesAtOpen` — `rootsMs`, `migrationsMs`,
  `thumbnailsMs`, `readerMs`), and `op=catalog.start`'s finish line carries `migrations` and
  `migrationsMs`. The open runs no integrity check, `optimize`, `ANALYZE` or checkpoint.
- **The window says what the open is doing** (DES-121): Store reports the step and the
  libraries the catalog holds (`CatalogStore.openings`, newest value, one consumer), read
  before any migration with SQL every schema version answers.
- **A migration enforces foreign keys as it runs** (`foreignKeyChecks: .immediate`, every
  registration). GRDB's default turns enforcement off and then runs `PRAGMA foreign_key_check`,
  which reads every table that declares a foreign key — nearly the whole file, 0.6–1.5 s warm
  and 8.8 s cold per migration on the owner-shaped catalog — to find violations a migration
  that writes no key cannot cause. No registered migration rebuilds a table, deletes a row
  another table refers to or changes a referenced key, so with enforcement on no foreign-key
  action fires and the outcome is the default's. A future migration that must rebuild a table
  (SQLite's twelve-step `ALTER TABLE`) registers `.deferred` and says so.
- **A migration costs only what its outcome needs.** It rebuilds only an index whose
  definition changes (each rebuild is a full scan and sort of its table, one per index), and
  writes rows while the indexes it changes are dropped, so each is built once over the written
  rows rather than maintained for every write. An applied migration's body changes only when
  its outcome — schema text, row contents, object order — stays identical: GRDB knows a
  migration by its name, and a catalog that applied it never runs it again.
- **A migration's PR states its cost** — milliseconds and WAL bytes — measured on a generated
  catalog of the owner's shape (about 167,000 assets, 2 GB: the research note's recipe), and
  what in its outcome needs that time when it is more than a second.
  `CatalogMigrationCostTests` measures it (`OTOS_SCALE_TEST=1 script/check.sh --only
  CatalogMigrationCostTests`): it generates that catalog (`OwnerShapedCatalog`), puts it back
  to the schema before the newest migration (the statements that undo it, kept beside the
  test), runs the Store's own pass over the newest, and writes its milliseconds, the WAL it left and the file's size before and after to
  `build/migration-cost/owner.txt`. The owner's file is fragmented on disk (its asset table
  1.2 % sequential), so a migration that reads a whole table there is slower than measured;
  the PR says so.

Rejected: building indexes after launch, off the open (a deferred-index mechanism). Otos's
reads name their indexes (`INDEXED BY`), so a read before the build would fail, or need a
second, slower text for every read that falls back to the 544 MB table while the index builds;
and the build holds the one writer for the same seconds, so a Like or a Move to Trash would
wait behind it with nothing on screen to say why. The wait is cheaper made once, measured,
and shown. Rejected: one foreign-key check after all pending migrations (GRDB offers none, and
enforcement as the statements run already covers what it would verify).

### macOS Scan Input

The filesystem scanner uses `FileManager` URL enumeration with this requested
resource-key set:

- `isRegularFileKey`
- `isDirectoryKey`
- `isSymbolicLinkKey`
- `isPackageKey`
- `nameKey`
- `creationDateKey`
- `contentModificationDateKey`
- `fileSizeKey`
- `contentTypeKey`

The initial enumeration options are `[.skipsPackageDescendants]`. This means the
scanner does not skip hidden files, subdirectory descendants, or mount points
through `FileManager.DirectoryEnumerationOptions`, but it does treat macOS
packages as file-like roots and does not descend into package contents.

Only regular files whose `contentTypeKey` conforms to `UTType.image` or
`UTType.movie` become `media_asset` rows. Other regular files are skipped during
scan observation and are not reconciliation failures. Nil `contentTypeKey` is
excluded. The scanner reads no bytes to decide eligibility; decodability and
enrichment unsupported outcomes are owned by later enrichment work.

Directories, symbolic links, and non-regular filesystem objects are scan traversal
or filtering inputs, not media asset rows. Package roots and package descendants are
not media asset rows in the catalog scan.

Skipped non-media regular files are summarized through debug JSONL diagnostics with
a per-scan count (`catalog.scan.skippedNonMedia`). A skipped non-media file is not a
filesystem scan failure.

Skipped package roots are recorded through debug JSONL diagnostics with the
package path and available content type identifier. A skipped package is not a
filesystem scan failure. This prevents app-owned document packages such as
Photos libraries from causing partial-root scan failures merely because their
private internals are inaccessible.

This ADR does not decide that all package contents are irrelevant to Otos.
Camera packages and compound video layouts can contain media that may be relevant
to a Lightroom-style app. Supporting those formats requires an explicit,
tested media-container import decision instead of accidental traversal of every
package directory.

If a requested resource value is unavailable for an observed regular file, the
corresponding nullable SQLite field is `NULL`. The app must not invent missing
filesystem facts.

### Identity And Reconciliation Contracts

The filesystem is the source of truth for whether a media file currently exists
inside a selected library root.

`library_root_id` refers to the selected library-root record that owns the
scanned root. This ADR does not define the library-root table, root identifier
format, root display name, or root restoration behavior. Those decisions belong
to the filesystem-access ADR or implementation spec.

`media_asset` identity is the pair `(library_root_id, relative_path)`. Otos does
not generate a separate media asset UUID in the initial catalog.

A filesystem scan is an idempotent reconciliation operation, not a durable
domain entity. The catalog has no `filesystem_scan` table and no durable scan
IDs.

For a completed scan of one library root:

- observed eligible regular-file paths are inserted or updated in `media_asset`
- existing `media_asset` rows for that root whose `relative_path` was not
  observed are deleted

The catalog does not retain first-seen, last-seen, missing-since, scan history,
or tombstone state. Move and rename behavior is out of scope; in this ADR, a
file that appears at a new root-relative path is a new row, and a file no longer
observed at its old root-relative path is deleted.

### Startup And Transient Scan Ownership

Initial database loading is one actor-owned operation. The first Store caller
creates one finite startup task; concurrent startup or mutation callers await
that same result. Loaded catalog state is applied exactly once, so an actor
reentrancy window cannot replace a mutation with an older database snapshot.

Database-restored roots that have not received their automatic launch scan are
tracked separately from whether loading has finished. A mutation may require the
catalog to load without consuming those pending scan requests. The later ordinary
app start drains the restored-root set exactly once. A root added after loading
is not in that set because the add operation queues its own immediate scan.

Each active scan has a process-local ownership lease consisting of normalized
`LibraryRootPath` plus the private SQLite `library_root.id` for that particular
stored root instance. Store validates both values before and after every awaited
database write and before accepting completion, cancellation, or failure. If a
root is removed and the same path is added again, the new row ID makes every
callback from the cancelled predecessor stale and harmless.

This lease is concurrency bookkeeping inside `CatalogStore`, not scan identity.
It is never persisted, exposed as domain state, or retained as history. Otos
still has no generated scan ID or durable scan entity.

### SQLite Schema

All date values are stored as `REAL` seconds since the Unix epoch in UTC, using
`Date.timeIntervalSince1970`.

#### `media_asset`

| Column | SQLite type | Null | Definition |
| --- | --- | --- | --- |
| `library_root_id` | `INTEGER` | no | SQLite rowid of the selected library-root record that owns the scanned root. It is a private foreign-key implementation detail, not library-root domain identity. |
| `relative_path` | `TEXT` | no | Root-relative file-system path string from the library root to the item, with no leading slash. It is derived by removing the scanned root URL's normalized, symlink-resolved file-system path plus one path separator from the observed file URL's normalized, symlink-resolved file-system path. This is not localized display text. |
| `name` | `TEXT` | yes | `URLResourceValues.name` from `NSURLNameKey`, when available. This is the filesystem resource name for the item, not localized display text. |
| `content_type_identifier` | `TEXT` | yes | `UTType.identifier` from `NSURLContentTypeKey`, when available. |
| `byte_size` | `INTEGER` | yes | File size in bytes from `URLResourceValues.fileSize`. |
| `created_at_unix` | `REAL` | yes | Creation date from `URLResourceValues.creationDate`, encoded as Unix seconds. |
| `content_modified_at_unix` | `REAL` | yes | Content modification date from `URLResourceValues.contentModificationDate`, encoded as Unix seconds. |

Constraints:

- `media_asset.library_root_id` references the library-root table's `id`.
- `(library_root_id, relative_path)` is the primary key.

Fields deliberately not stored by this ADR:

- `media_asset.id`
- durable `filesystem_scan` rows or scan IDs
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
owner and flushed to SQLite on the background scan cadence when pending changes
exist. This is a time-based cadence, not a file-count threshold.

`CatalogProjection` publishes SwiftUI-visible background scan state on its
background publication cadence when pending view changes exist. Direct user
sidebar, sort, and filter intents can still wake a publication immediately. The
cadence is time-based, not a scanned-file threshold.

If a SQLite flush takes longer than one tick, the next tick coalesces pending
changes. The catalog owner must not run overlapping SQLite writes for one
catalog.

At scan end, cancellation, or failure, the catalog owner performs one final
flush of pending observed-file changes. Deletion of unobserved existing rows
happens only after a completed scan of that library root, not after a cancelled
or failed scan.

### Running-App Filesystem Watching (V1)

While the app is running, `CatalogFilesystemWatcher` subscribes to macOS File
System Events for each saved library root using file-level events
(`kFSEventStreamCreateFlagFileEvents`), `IgnoreSelf`, and `WatchRoot`. `MarkSelf`
is not used (no consumer of `OwnEvent`). The watcher translates callbacks into
`Sendable` events and forwards them to `CatalogStore`; it never writes SQLite or
catalog memory. Provider hydration runs outside the Otos process, so `IgnoreSelf`
cannot identify those events. Each `CatalogStore` owns its own watcher instance
(`CatalogFilesystemWatcher.live()`): one stream, root list and handler per Store,
stopped by `stop()` or when the Store releases it. A process-wide watcher was
rejected: a second Store's `start` would redirect the first one's events and any
Store's `stop` would silence every other, which is exactly what parallel tests do.

`CatalogStore` maps each event path to exactly one library root, ignores events
until that root's first scan has completed ("arming"), and receives them through one
ordered stream. One pass per root acts on its events as they arrive; events that land
while the pass awaits join the root's batch and the same pass takes them next, so a
burst is coalesced by the work itself rather than by a quiet period
(`docs/research/2026-10-23-cadence-audit.md`). Each pass classifies its batch with
`FilesystemEventFlags` /
`FilesystemReconciler` into typed dirty scopes and merges them into one
process-local accumulator per root:

- supported regular-file events → `.file` (upsert or delete-if-missing);
- trustworthy descendant directory / `MustScanSubDirs` → `.subtree`;
- dropped, unknown, root-changed, symlink, unmappable, or root-path coverage →
  `.root`.

Coalescing rules: duplicate files merge conservatively; a subtree absorbs
descendant files/subtrees; `.root` clears every narrower scope. There is no
fixed path-count threshold that escalates to a full-root scan.

When no filesystem lease owns the root, Store drains the accumulator: file scopes
settle through `CatalogScannedFileReader` / the shared upsert-delete edge; subtree
scopes enumerate that descendant directory with the same scanner fact path and
delete only component-safe rows inside the boundary; root scopes use the existing
full-root scan proof. Dirt that arrives while a lease is active stays in the next
dirty generation — useful path/scope information is never discarded into an
unconditional `rescanAfterCurrentScan` for the common event path.
`rescanAfterCurrentScan` remains only for independently verified owners such as
reorganization.

Known-materialization suppression (ADR 0009 / research 2026-07-11) may drop
allowlisted hydration-shaped events for paths Otos has explicitly asked the
provider to materialize; unsafe membership/coverage shapes never suppress.

A Store-owned integrity scheduler marks a library root `.root` dirty once when
24 hours have elapsed since its last successful full-root reconciliation (launch
and add scans count). It does not duplicate work for active/pending/already-dirty
roots.

Watcher lifecycle is tied to saved roots: start after catalog load, add on
`addLibrary`, remove on `removeLibrary`, stop on `shutdown`. Availability
re-probing and offline-root watching policy are unchanged from ADR 0005.

### Media Eligibility At Scan

A regular file is eligible when `URLResourceValues.contentType` conforms to
`UTType.image` or `UTType.movie`. Shared policy lives in `MediaEligibility`.

Verified POC on a 21,922-file OneDrive library (`~/Desktop/OneDrive/Pictures`):
every extension mapped to one UTType; nil `contentTypeKey` was absent; 11 of
21,922 files (PDF and extensionless dynamic types) would be excluded by this rule.

Alternatives rejected for scan membership:

- Extension allowlist: duplicate policy surface and misses mis-typed files.
- UTType plus extension fallback: rejected; nil and unknown types are excluded.
- Byte sniffing or ImageIO/AVFoundation at scan: violates the no-byte-read scan
  contract for dataless cloud placeholders.
- Projection or UI-only filtering: leaves non-media rows in SQLite until manually
  reconciled away.

Decodability remains enrichment's job. A file with a correct UTType that cannot be
decoded is still cataloged until enrichment records an unsupported outcome.

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

### Superseded: GRDB With Full In-Memory Catalog Working Set

Pros:

- Kept SQLite explicit and durable while preserving simple early SwiftUI reads.
- Avoided paging and database-observation complexity before evidence proved the
  first catalog model insufficient.

Cons:

- Created two representations that had to remain synchronized: SQLite durability
  and the in-memory working set.
- Full startup load and full-map publication became visible work as catalog rows
  and enrichment churn grew.
- Memory pressure became the app's responsibility as catalog columns grew.

Failure modes:

- A write could succeed in memory but fail on disk, or succeed on disk but not
  update memory.
- Later schema work could add large columns without revisiting the in-memory
  loading rule in a separate decision.

Superseded by ADR 0010, which keeps SQLite as the per-asset working set and
routes order, detail, metadata, and enrichment selection through Store-owned
queries.

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

- Would support audit history, resumable scans, or detailed diagnostics if
  Otos treated scans as product entities.
- Would explain when a row was first seen, last seen, or marked missing.

Cons:

- Treats an idempotent reconciliation operation as a durable domain entity.
- Adds scan IDs, scan status, first-seen, last-seen, and missing-since state
  outside the current product model.
- Preserves missing-file history when the current desired behavior is to delete
  missing rows after a completed scan.

Failure modes:

- Later work reads scan history as authoritative product state.
- A cancelled or failed scan accidentally marks files missing.

## Consequences

The current catalog implementation has one durable SQLite catalog, one app-owned
Store actor, and one row per currently observed scanned media asset path. SQLite
is the per-asset working set; root runtime state is resident in Store, while
asset order, visible detail, metadata detail, and enrichment candidates are read
through Store-owned queries.

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
- SQLite scan flushes on the background scan cadence when pending changes exist
- SwiftUI-visible background scan updates publish on Projection's background
  cadence when pending changes exist
- concurrent initial-load callers share one Store-owned startup task
- database-restored roots receive one automatic launch scan request
- scan callbacks must still own the same root path, private root-row instance,
  and process-local lease generation before changing durable or in-memory state

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

If scan flushing proves too frequent or too sparse, change the cadence through a
new requirement or ADR update with measured evidence.

Durable scan history and scan IDs are out of scope because scans are idempotent
reconciliation operations, not product entities.
