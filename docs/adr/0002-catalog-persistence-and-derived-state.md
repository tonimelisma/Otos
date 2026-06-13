# ADR 0002: Catalog Persistence And Derived State

## Status

Proposed

## Context

Otos needs an app-owned catalog for user-selected media roots. Originals remain
read-only on disk, while Otos stores overlay state in Application Support.

The first catalog increment needs to choose:

- the SQLite access layer
- the initial asset state model
- how scanner work persists filesystem facts, metadata results, and future
  thumbnails
- how SwiftUI receives state without becoming a second catalog authority

Verified repo facts:

- There is no existing persistence dependency or catalog implementation.
- The current app is a SwiftUI macOS shell with an instrumentation facade in
  `Otos/Support/Instrumentation.swift`.
- `docs/requirements.md` is the current implemented-requirements registry only;
  unimplemented catalog behavior belongs in specs and ADRs until it lands.
- Relevant current requirements include FND-001, FND-002, FND-006, FND-007,
  FND-008, FND-009, FND-011, MED-001, MED-002, MED-003, and APP-001.

Captured user guidance for verification:

- Use SQLite for the catalog.
- Use GRDB as the Swift SQLite access layer.
- Keep the initial model simple: one authoritative record per media asset.
- The asset record should begin with filesystem facts.
- Metadata and thumbnail fields can be added later when those features land.
- Derived metadata and thumbnails should be compared against filesystem facts to
  decide whether they are stale.
- Use a file signature instead of modification time alone for derived-data
  freshness.
- The initial file signature can be simple, such as content modification date
  plus byte size.
- Loading and retaining the whole catalog in memory may be acceptable because
  Otos is expected to manage media-library-scale data, and even millions of
  file records may be a reasonable memory tradeoff for a primary media app.
- Everything stored in the SQLite catalog should be loaded into the in-memory
  catalog working set until evidence or an explicit requirement proves otherwise.
- Thumbnail bytes are not catalog database payloads. Thumbnails should live as
  files on disk; SQLite stores thumbnail status and storage keys or paths.
- Keep the app as simple as possible. Simplicity is an architectural
  requirement, and performance-oriented complexity should come after
  correctness, clarity, and explicit evidence.

## Decision

Use GRDB with app-bundled SQLite as the catalog persistence layer.

Create one app-owned persistence boundary that owns the database writer for the
app lifetime. Open the database at launch, run migrations, and keep SQLite as
the durable catalog authority. For simplicity, load the catalog working set into
an app-owned in-memory projection after migration. The in-memory projection is
the app's fast working model while the app is running; SQLite remains the
durable source after relaunch, crash recovery, and migration.

The in-memory working set includes the SQLite catalog by default: media asset
rows, filesystem facts, derived-state status, thumbnail storage keys or paths,
and catalog metadata columns. If a value is important enough to be modeled in
the current SQLite catalog schema, it is presumed small and useful enough to be
loaded into memory until evidence proves otherwise.

Large derived payloads are not normal catalog columns. They mean payloads whose
size is not predictably bounded by one media-asset row, such as thumbnail image
bytes, rendered preview bytes, raw EXIF/XMP/QuickTime metadata dumps, embedded
media data, generated analysis blobs, embeddings, or future render artifacts.
Those payloads should live as files or be introduced only through a later spec
that explicitly decides storage and memory-loading behavior.

Start with a `DatabaseQueue` unless implementation evidence shows that live UI
queries are blocked by scanner writes. Consider `DatabasePool` and WAL only
after profiling or responsiveness evidence proves concurrent read pressure.

Model the first catalog around:

- `library_root`: user-selected media roots and access state.
- `media_asset`: one row per observed media asset.

The initial `media_asset` row stores filesystem facts and scan bookkeeping. It
also owns nullable or future-migration columns for derived state such as
metadata and thumbnails when those features land.

Derived data is fresh when its recorded source file signature matches the
asset's current file signature. `updated_at` timestamps may be stored for
diagnostics, sorting, and UI explanation, but they are not the source of truth
for freshness.

Initial asset fields should include the equivalent of:

- stable asset ID
- library root ID
- root-relative path
- file resource identifier when available
- content type
- byte size
- content modification date
- current file signature
- scan generation or last-seen marker
- missing/deleted observation state

Future metadata fields should record:

- metadata status
- metadata update timestamp
- metadata source file signature
- extracted metadata values required by implemented features

Future thumbnail fields should record:

- thumbnail status
- thumbnail update timestamp
- thumbnail source file signature
- thumbnail storage key or path inside Otos-owned Application Support storage

Scanner state flow:

1. Filesystem scan discovers files off the main actor.
2. The scanner writes discovered filesystem facts to SQLite in bounded
   transactions.
3. SwiftUI observes committed catalog projections instead of receiving a
   mutation per file.
4. Metadata and thumbnail workers read pending or stale assets, perform slow
   work outside database transactions, then write results only if the current
   asset row still has the same source file signature.
5. Cancellation, root removal, or a newer scan generation rejects stale worker
   completions.

Batching policy:

- User-authored catalog changes write immediately in one transaction.
- Fast filesystem inventory writes by bounded batch, such as file-count or time
  thresholds.
- Slower metadata and thumbnail work writes completed results in smaller
  bounded batches or individually when latency matters.
- Every scan phase flushes pending writes at phase end, cancellation, and before
  reporting completion.

SwiftUI state flow:

- SwiftUI views do not own or mutate catalog truth directly.
- A main-actor observable store may publish progress and view-ready projections
  from the in-memory catalog working set.
- Catalog writes flow through one catalog owner that updates SQLite durability
  and the in-memory projection together.
- Scanner progress may be published separately as throttled ephemeral state, but
  it must not contradict committed catalog facts.

Instrumentation:

- Log and signpost scan phases, batch sizes, write durations, observation
  latency, cancellation, stale-result rejection, and errors.
- Logs must use opaque IDs, safe counts, durations, and status values rather
  than filenames, absolute paths, thumbnails, EXIF payloads, or user-authored
  metadata.

## Alternatives Considered

### Raw sqlite3

Pros:

- No third-party Swift package dependency.
- Maximum control over SQLite configuration, statements, and transactions.
- Clear lowest-level performance ceiling.

Cons:

- High boilerplate for statement preparation, binding, decoding, migrations,
  transactions, and error handling.
- Easy to leak low-level SQLite concerns across app code.
- Less idiomatic Swift API surface for a SwiftUI macOS app.

Failure modes:

- Statement lifetime bugs, missed finalization, accidental main-actor database
  work, and inconsistent migration behavior.
- Hand-written wrappers recreate an incomplete local persistence framework.

### SQLite.swift

Pros:

- Swift wrapper over SQLite with a lightweight query-builder style.
- Easier than raw sqlite3 for simple CRUD.
- Smaller API surface than GRDB.

Cons:

- Less complete for long-lived catalog needs such as observation, migrations,
  transaction ergonomics, and explicit concurrency patterns.
- More likely to require custom app infrastructure as catalog complexity grows.

Failure modes:

- The first increment looks simple, but later metadata, thumbnails, import
  scans, and SwiftUI observation force a second persistence abstraction.

### GRDB With DatabaseQueue

Pros:

- Swift-native SQLite access while keeping SQLite explicit.
- Supports migrations, records, safe SQL binding, transactions, observations,
  and clear database-reader/database-writer boundaries.
- `DatabaseQueue` is simple and correct for an initial single-writer catalog.
- Works well with an app-owned SwiftUI store that observes committed database
  projections.

Cons:

- Adds a third-party dependency that must be tracked and reviewed.
- Larger API surface than raw sqlite3 or SQLite.swift.
- Requires discipline to keep GRDB calls inside persistence boundaries instead
  of spreading SQL through views.

Failure modes:

- Overusing observations can create excessive UI invalidation.
- Long write transactions can block reads when using `DatabaseQueue`.
- Treating GRDB records as UI state can blur ownership between persistence and
  presentation.

### Selected: SQLite As Durable Store With Full In-Memory Catalog Snapshot

Pros:

- Simple SwiftUI reads after startup because views and stores can consult an
  app-owned in-memory catalog projection.
- Fast filtering, grouping, and count updates for catalog-scale filesystem facts
  without a database round trip for every interaction.
- May be an acceptable memory tradeoff for a primary media app, even with large
  local libraries.
- Keeps SQLite available as the durable on-disk source for launch, crash
  recovery, migration, and external verification.
- Follows the simplicity-first rule: avoid introducing database observation,
  paging, pooling, and query-projection complexity before the app proves it
  needs them.

Cons:

- Creates two representations that must remain synchronized: SQLite durability
  and the in-memory projection.
- Full startup load can become visible launch work if the catalog grows or row
  shape expands.
- Memory pressure becomes the app's responsibility as catalog columns grow,
  especially after metadata, search facets, ratings, edits, and UI grouping
  state arrive.
- A full object graph can accidentally invite main-actor work, broad SwiftUI
  invalidation, or expensive sorting/filtering in view code.

Failure modes:

- A write succeeds in memory but fails on disk, or succeeds on disk but does not
  update the in-memory projection.
- Startup turns into a mandatory full-catalog decode before the user can use the
  app.
- The app lets future unbounded payloads creep into SQLite and then loads them
  into memory because the default catalog-loading rule was not revisited.
- The in-memory model becomes treated as the catalog authority and weakens
  SQLite migration, recovery, and stale-result checks.

### SQLite In-Memory Database Mirrored To Disk

Pros:

- Very fast reads and writes while the app is running.
- Keeps SQL as the access model for in-memory state.

Cons:

- Adds explicit snapshot, backup, and crash-recovery complexity.
- Weakens SQLite's normal durability advantage for catalog updates.
- Makes app termination, crash, and power-loss behavior harder to prove.
- Does not remove the need for a SwiftUI-facing projection layer.

Failure modes:

- Recent scan, metadata, or thumbnail state is lost after a crash.
- Disk snapshots lag the visible app state.
- Recovery logic becomes a second persistence system.

### GRDB With DatabasePool And WAL From Day One

Pros:

- Allows concurrent reads while writes are active.
- Better fit if scanning, metadata extraction, and browsing all run heavily at
  the same time.

Cons:

- More moving parts than the first catalog increment needs.
- WAL introduces additional database sidecar files and checkpoint behavior that
  must be understood and instrumented.
- Premature concurrency can hide simpler ownership bugs.

Failure modes:

- The app pays complexity before evidence shows read contention.
- Long-running readers or checkpoint behavior can create surprising disk or
  freshness symptoms.

### Separate Tables For Filesystem Facts, Metadata Jobs, Metadata Values, And Thumbnails

Pros:

- Normalizes independently changing concerns.
- Scales better if metadata becomes large, repeated, multi-valued, or queried in
  many shapes.
- Gives jobs, retry history, and thumbnail variants explicit ownership.

Cons:

- More schema and query complexity before the first implemented behavior needs
  it.
- Harder to explain and verify during the initial library-root increment.

Failure modes:

- Premature decomposition creates accidental abstractions and more migration
  surface.
- The app starts with a job system rather than a catalog.

## Consequences

The first catalog implementation stays simple while preserving correctness:
there is one current asset row, one durable catalog authority, and one app-owned
persistence boundary.

SwiftUI remains responsive because slow filesystem and metadata work happens off
the main actor, writes are batched, and views consume the app-owned in-memory
working set rather than per-file scanner callbacks.

Freshness checks become robust enough for real media workflows. Modification
time remains part of the signature, but it is not the only proof that derived
metadata or thumbnails match the current file.

The schema can evolve by migration. If metadata payloads, thumbnail variants,
retry history, or search facets become too large for one asset row, those fields
can move into dedicated tables through a future ADR or spec.

The selected pattern constrains implementation:

- no direct database calls from SwiftUI views
- no SQLite columns for thumbnail bytes, raw metadata dumps, generated analysis
  blobs, or future render artifacts without a later spec that revisits memory
  loading
- no main-actor filesystem, metadata, thumbnail, or database work
- no derived-data write unless the source file signature still matches
- no logging of user media paths, names, metadata payloads, or thumbnails

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
catalog service. Views and scanner workers should depend on Otos-owned catalog
interfaces and value projections, not GRDB types directly.

If `DatabaseQueue` blocks browsing during active scans, measure with signposts
and move to `DatabasePool` plus WAL in a focused migration.

If one asset row becomes too wide or too contentious, split derived metadata,
thumbnail variants, or job state into dedicated tables while preserving
`media_asset` as the identity and filesystem-facts owner.

If the initial file signature is insufficient, strengthen it by migration. Do
not replace the freshness model with update-time comparisons.
