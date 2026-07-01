# Spec: Library Catalog Browser

## Classification

- Work type: Feature
- Current requirement IDs: FND-002, FND-006, FND-008, FND-013, FND-014, FND-015, FND-017, FND-018, FND-021, FND-022, MED-001, MED-002, APP-001
- Future idea or candidate links explicitly requested by the user: none
- ADRs: ADR 0002, ADR 0003

## Problem

Otos provides a persistent library catalog while leaving user originals on
disk. Users manage roots in Settings; the app automatically scans them and
projects Store-owned catalog queries into the single sidebar-detail window.

Current repo state verified through inspection:

- `CatalogStore` owns GRDB, the clean current schema, root runtime state, scans,
  and catalog query APIs.
- `CatalogProjection` publishes derived window state at the 10 Hz dirty cadence.
- `CatalogWindowViewModel` assigns final state and routes explicit intents.
- `ContentView` composes a library sidebar and placeholder media grid.
- The app is unsandboxed, SwiftUI-first, and uses AppKit only for the verified
  high-cardinality grid boundary.

## Scope

In scope:

- SwiftUI sidebar with `All Media` and saved libraries.
- SwiftUI Settings scene with a `Libraries` tab for add/remove.
- GRDB 7.11.0, SQLite in Application Support, and stable v1 migrations.
- SQLite-backed per-asset catalog working set owned by a catalog actor.
- Automatic launch/add scans only.
- Six-column filename placeholder grid while all filesystem facts remain in the
  catalog model.

Out of scope:

- Manual scan buttons, commands, or user-facing rescan controls.

In scope (filesystem watching):

- macOS FSEvents under saved library roots schedule debounced reconciliation for
  the affected root: safe single regular-file events reconcile one path, while
  unsafe events fall back to full-root rescans (specs 0023 and 0027).

Out of scope:

- Directory/subtree incremental FSEvents catalog updates.
- Metadata, thumbnails, previews, editing,
  import/export, sandboxing, bookmarks, AppKit root picker, and parallel scans.

## Definition Of Ready

- [x] Goal, scope, and non-goals are explicit.
- [x] Current repo state was inspected.
- [x] Captured user guidance is restated as precise requirements for user verification.
- [x] Observable current requirements and acceptance examples are listed.
- [x] Future ideas and unimplemented requirement candidates are separated from `docs/requirements.md`.
- [x] Roadmap, planning, or idea documents are ignored unless explicitly requested by the user for this task.
- [x] Ownership, side effects, persistence, cancellation, errors, progress, privacy, instrumentation, and tests are addressed.
- [x] At least three alternatives are compared.
- [x] Refactor retirement proof is defined.
- [x] Performance/jank evidence is defined.
- [x] Open questions are answered or out of scope.

## Captured Requirements For User Verification

| ID or label | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| LIB-001 | Functional | The main window shows a sidebar containing `All Media` and saved libraries. | Current | `docs/requirements.md` |
| LIB-002 | Functional | Library add/remove lives in a dedicated SwiftUI Settings scene, `Libraries` tab. | Current | `docs/requirements.md` |
| LIB-003 | Functional | The Add Library action selects exactly one folder using SwiftUI folder importing. | Current | `docs/requirements.md` |
| LIB-004 | Functional | The app supports multiple saved libraries. | Current | `docs/requirements.md` |
| LIB-005 | Functional | Exact duplicate, ancestor, and descendant library roots are rejected. | Current | `docs/requirements.md` |
| LIB-006 | Functional | Removing a library deletes Otos catalog rows for that root and leaves original files untouched. | Current | `docs/requirements.md` |
| LIB-007 | Functional | Removing a library always requires confirmation with destructive action copy that explains originals remain on disk and catalog information is deleted. | Current | `docs/requirements.md` |
| LIB-008 | Functional | Otos automatically scans saved libraries on launch, newly added libraries after add, and debounced filesystem-event rescans while running. | Current | `docs/requirements.md` |
| LIB-009 | Functional | Otos shall not expose a manual scan button, command, or user-facing scan API. | Current | `docs/requirements.md` |
| LIB-010 | Functional | The catalog stores file name, relative path, content type identifier, byte size, creation date, and content modified date; the current browser presentation is owned by Spec 0011. | Current | `docs/requirements.md`, Spec 0005, Spec 0011 |
| LIB-011 | Functional | Scan failures are kept out of the UI for this increment and recorded through logs. | Current | `docs/requirements.md` |
| CAT-001 | Architecture | The catalog owner uses GRDB with SQLite: `DatabasePool` for file-backed locations and `DatabaseQueue` for `.inMemory` tests. | Current | `docs/requirements.md`, ADR 0002, ADR 0010 |
| CAT-002 | Architecture | SQLite is the per-asset working set; Store keeps root runtime state resident and exposes Store-owned query APIs instead of retaining a resident per-asset map. | Current | `docs/requirements.md`, ADR 0002, ADR 0010 |
| CAT-003 | Architecture | The normalized root path is product identity; SQLite rowid is only a private foreign key implementation detail. | Current | `docs/requirements.md`, ADR 0003 |
| CAT-004 | Architecture | A `CatalogStore` actor owns GRDB, migrations, in-memory state, scan lifecycle, scan persistence cadence, and cheap catalog change notifications. | Current | `docs/requirements.md`, Spec 0009 |
| CAT-005 | Architecture | SwiftUI views never call SQLite directly; a MainActor ViewModel consumes projected catalog window state. | Current | `docs/requirements.md`, Spec 0007, Spec 0009 |
| CAT-006 | Non-functional | SQLite scan writes and SwiftUI-visible scan updates happen at a 10 Hz time cadence when pending changes exist. | Current | `docs/requirements.md`, ADR 0002 |
| DOD-001 | Process | There is exactly one DoD report for an increment, and no review handoff, partial, pre-merge, or ready-for-review DoD report may be sent to the user or posted to the PR. | Current | `docs/requirements.md`, `AGENTS.md`, `docs/process/development-workflow.md`, `script/dod-report.sh` |
| DOD-002 | Process | The final DoD report is created only after the entire DoD is complete or after a true external blocker prevents completion. | Current | `docs/requirements.md`, `AGENTS.md`, `docs/process/development-workflow.md`, `script/dod-report.sh` |
| DOD-003 | Process | The final DoD report uses green and red status emoji plus clear textual descriptions for every required DoD question, and it is included in the PR and sent to the user. | Current | `docs/requirements.md`, `AGENTS.md`, `docs/process/development-workflow.md`, `script/dod-report.sh` |

## Architectural Alternatives

### Catalog Actor With MainActor SwiftUI Model

Pros:

- One catalog authority owns persistence, in-memory state, and scan lifecycle.
- Keeps filesystem traversal and SQLite work off the MainActor.
- Matches the current ADR decision to keep SQLite as the per-asset working set
  behind one Store actor.
- Gives Projection keyed snapshots without database query coupling.

Cons:

- Requires explicit change notification and Projection publication plumbing.
- Requires care to avoid per-file MainActor updates.

Failure modes:

- Actor methods publish too frequently and create SwiftUI churn.
- A storage rowid leaks into product identity.

### GRDB ValueObservation Driving SwiftUI

Pros:

- Idiomatic GRDB for reactive database-backed screens.
- Less custom publishing code.

Cons:

- Makes SQLite query results the UI driver instead of the in-memory catalog
  owner.
- Couples SwiftUI state to query shape.
- Requires scheduling care as observations grow.

Failure modes:

- The app drifts away from the selected Store-owned catalog query model.
- View-level observations become a second owner of catalog freshness.

### MainActor Catalog With Background Helpers

Pros:

- Very direct SwiftUI data binding.
- Fewer actor hops in view code.

Cons:

- MainActor becomes catalog authority.
- Persistence and scan helpers must synchronize back into UI state.
- Increases the risk of filesystem or database work leaking into UI paths.

Failure modes:

- Duplicate state becomes inconsistent.
- Long-running work blocks or churns the MainActor.

### DispatchQueue Catalog Owner

Pros:

- Explicit serial execution model.
- Works with blocking filesystem APIs.

Cons:

- Less Swift-native than actors under Swift 6.
- Requires callback glue and weaker compiler isolation.

Failure modes:

- Reimplements actor-like ownership with less language support.

## Selected Approach

Use a `CatalogStore` actor with a `CatalogProjection` actor and a
`@MainActor @Observable CatalogWindowViewModel`. Store opens and initializes one
long-lived GRDB writer, uses `DatabasePool` for file-backed locations, keeps only
root runtime state resident, serializes add/remove/scan work, and emits cheap
change notifications. Projection asks Store for current library rows and scoped
ordered asset IDs, then emits `CatalogWindowState` for SwiftUI.

This is the simplest correct approach because it has one persistence owner, one
catalog query owner, no query-backed SwiftUI coupling, no parallel scan pipeline,
and no generated product IDs.

## Interfaces, Ownership, And Data Flow

- `CatalogStore` actor: owns GRDB, root runtime state, transient availability,
  Store-owned catalog queries, one serialized initial load, change subscribers,
  pending scans, and scan cancellation. Database-restored roots retain
  exactly-once launch-scan requests even when a mutation initializes Store first.
- `CatalogScanner`: Sendable scanner function wrapper used by the actor and tests.
- `CatalogProjection`: actor that publishes coalesced `CatalogWindowState` for
  the main window.
- `CatalogWindowViewModel`: MainActor observable state assignment, explicit
  selection delivery, UI intents, owned tasks, and stall-monitor lifetime for the
  single main window.
- Store query APIs: current library rows, scoped ordered media IDs, visible media
  details, metadata detail, and enrichment candidates.
- `SidebarSelection`: SwiftUI sidebar selection for `All Media` or one root path.
- SQLite lives in Application Support under an Otos catalog directory.
- Root identity is the normalized path. `library_root.id` is storage-only.
- Active scanner callbacks are guarded by normalized root path plus the private
  root-row instance so remove/re-add at the same path cannot revive old work.
- Scans write pending batches no more often than 10 Hz; Projection publishes
  UI-ready window state no more often than 10 Hz when dirty.
- The app never writes, moves, deletes, or rewrites original media files.

## Retirement Proof

- `ContentView` remains the passive root layout.
- `OtosApp` remains the scene and ViewModel owner with a Settings scene.
- Do not add AppKit picker code, manual scan controls, sandbox/bookmark code,
  metadata fields, thumbnail fields, or direct SwiftUI database access.

## Instrumentation And Performance

- `Persistence`: database open, migration, load, root writes, media batch writes.
- `Catalog`: add/remove root, scan start, scan finish, scan cancel, scan failure.
- `FileAccess`: filesystem enumeration start and finish.
- `UI`: ViewModel start and projected state apply.
- Logs and signposts use operation names, counts, storage rowids, paths when
  useful, and outcomes.
- Responsiveness evidence is local build/test plus log inspection;
  no trace is required unless verification shows jank.

## Code-Smell Review

- MainActor gravity: avoided by actor-owned DB and scanner work.
- SwiftUI body work: views render precomputed projected state only.
- State duplication: one catalog actor owns canonical in-memory state.
- Unsafe concurrency escape: scanner is a Sendable closure owned by a cancellable
  task.
- Stringly typed domain facts: library root paths, relative paths, and media
  asset identity are typed at app boundaries.
- Diagnostic payload sprawl: logs avoid secrets and unbounded payloads.

## Acceptance Criteria

- Adding a folder in Settings persists a library root, scans it automatically,
  and shows eligible image and video files in `All Media` and that library.
- Adding an exact duplicate, ancestor, or descendant root fails without changing
  catalog state.
- Removing a library requires confirmation, deletes root/media catalog rows, and
  leaves originals on disk.
- Relaunching loads persisted roots/media rows into memory and starts automatic
  reconciliation.
- A completed scan deletes catalog rows for files no longer observed.
- A cancelled or failed scan does not delete previously cataloged rows.
- No manual scan button, command, or user-facing scan API exists.

## Verification

- Local checks: `script/verify.sh`
- Focused tests: catalog store add/remove/reload/reconcile/cancel/fail/overlap
  tests and source-surface check for manual scan controls.
- Performance/log evidence: `Catalog`, `Persistence`, `FileAccess`, and `UI`
  log/signpost coverage.
- CI expectations: remote fast gate must pass unless GitHub reports the known
  Actions billing/spending-limit blocker.
