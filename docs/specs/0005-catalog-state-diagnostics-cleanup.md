# Spec: Catalog State Diagnostics Cleanup

## Classification

- Work type: Refactor, small behavior, process/tooling
- Current requirement IDs: FND-006, FND-019, FND-020, FND-023, FND-024,
  FND-025, FND-026, MED-001, MED-002, APP-006, APP-008
- Future idea or candidate links explicitly requested by the user: none
- ADRs: ADR 0002, ADR 0003

## Problem

The catalog needs typed public identity, persistence-private SQLite details,
off-MainActor projection, bounded diagnostics, and no generic user-facing error
surface until product error behavior is specified.

Repo inspection found:

- `CatalogWindowViewModel` owns final window state and explicit intents only.
- typed library/relative paths form `MediaAssetID`; SQLite row IDs remain inside
  Store persistence records.
- the scanner stores name, relative path, content type, size, creation date, and
  modification date.
- `CatalogProjection` owns derived ordering/filtering and publication.
- `script/catalog-diagnostics.sh` summarizes durable coarse JSONL evidence.

## Scope

In scope:

- Remove `MED-003` and conflicting raw-path/raw-filename logging restrictions.
- Add scanner storage and UI display for `name` and `creationDate`.
- Type library root paths, media relative paths, and media asset identity.
- Hide SQLite row IDs inside `CatalogStore`.
- Move catalog sorting and selection filtering off the MainActor.
- Add debug-only JSONL diagnostics and a repo check script for large catalog and
  projection operations.
- Remove generic user-facing catalog messages and alerts.

Out of scope:

- Metadata, thumbnails, file identifiers, scan-history tables, durable scan IDs,
  manual scan controls, sandboxing, bookmarks, FSEvents, and user-facing error
  banners.
- Broadly storing every `URLResourceValues` field.
- Release-build user diagnostic export.

## Captured Requirements For User Verification

| ID or label | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| REM-001 | Privacy | Remove `MED-003`; raw paths and filenames are no longer forbidden diagnostics by default. | Retired | `docs/requirements.md`, `AGENTS.md`, process docs |
| REM-002 | Functional | Remove the generic user-facing catalog message and alert. | Current | `docs/requirements.md`, this spec |
| REM-003 | Architecture | Remove shared main-window selection from shared catalog truth. | Current | `docs/requirements.md`, this spec |
| REM-004 | Architecture | Remove public exposure of SQLite row IDs from catalog models. | Current | `docs/requirements.md`, this spec |
| REM-005 | Architecture | Remove ambiguous media asset string-concatenation identity. | Current | `docs/requirements.md`, this spec |
| CHG-001 | Functional | The scanner and catalog store file name, relative path, content type identifier, byte size, creation date, and content modified date; the browser presents the filename placeholder grid specified by Spec 0011. | Current | `docs/requirements.md`, ADR 0002, Spec 0011 |
| CHG-002 | Architecture | SwiftUI receives single-window catalog UI state through `CatalogWindowViewModel`; views remain passive. | Current | `docs/requirements.md`, Spec 0007 |
| CHG-003 | Architecture | Normalized filesystem path remains library-root identity, while SQLite rowid is persistence-private. | Current | `docs/requirements.md`, ADR 0003 |
| CHG-004 | Non-functional | Catalog sorting and selection filtering must run outside the MainActor. | Current | `docs/requirements.md`, this spec |
| ADD-001 | Architecture | `CatalogWindowViewModel` owns catalog startup, add-library, remove-library, sidebar selection, state consumption, and task lifetimes for the single main window. | Current | `docs/requirements.md`, Spec 0007 |
| ADD-002 | Architecture | `CatalogProjection` actor owns root sorting, asset ordering, media-grid scope filtering, title lookup, and selected-library validation. | Current | `docs/requirements.md`, this spec, Spec 0011 |
| ADD-003 | Architecture | Domain paths and media identity use typed values, not bare strings or concatenated IDs across app boundaries. | Current | `docs/requirements.md`, this spec |
| ADD-004 | Tooling | Debug builds write JSONL for coarse catalog and Projection operations; high-frequency UI paths use Logger/signposts. | Current | `docs/requirements.md`, this spec, Spec 0012 |
| ADD-005 | Tooling | A repo script checks and summarizes catalog diagnostics under `build/Diagnostics`. | Current | `docs/requirements.md`, this spec |

## Architectural Alternatives

### Keep `OtosAppModel` And Rename Properties Only

Pros:

- Smallest code diff.
- Keeps one observable type for the current small UI.

Cons:

- Leaves catalog truth mixed with main-window selection.
- Does not address MainActor filtering or the global-app-model smell.

Failure modes:

- Settings and future surfaces inherit unrelated browsing state.

### Put Projection Methods On `CatalogStore`

Pros:

- Keeps all catalog-related work in one actor.
- Avoids another type.

Cons:

- Mixes presentation ordering and selection projection into persistence and scan
  lifecycle ownership.
- Makes the store aware of UI selection.

Failure modes:

- Store methods become a grab bag for every view-specific projection.
- Persistence tests start asserting UI projection details.

### Selected: Typed Domain Models, Diagnostics, And Projection Actor

Pros:

- Gives each owner a narrow job: Store owns persistence/scans, Projection owns
  sorting/filtering, ViewModel owns UI state assignment, diagnostics are
  observable.
- Moves root sorting, asset sorting, and sidebar-scope filtering off
  the MainActor.
- Keeps Settings state narrow and local.

Cons:

- Adds one projection actor and diagnostic facade.

Failure modes:

- Projection diagnostics could become noisy if every tiny state assignment logs.
- A read-model type could grow unrelated UI details unless requirements stay
  precise.

## Selected Approach

Implement the selected alternative directly. `CatalogStore` remains catalog
truth. `CatalogProjection` sorts roots and assets, resolves sidebar selection,
computes title, and computes the selected-scope media grid off the MainActor.
`CatalogWindowViewModel` consumes the projected state stream described by Spec
0009 and assigns final SwiftUI state.

Errors remain out of the UI for this increment. Catalog failures are logged
through OSLog and written to debug JSONL diagnostics when applicable.

## Interfaces, Ownership, And Data Flow

- `LibraryRootPath`: normalized absolute filesystem path for a saved library
  root.
- `MediaRelativePath`: root-relative filesystem path for a cataloged file.
- `MediaAssetID`: typed pair of `LibraryRootPath` and `MediaRelativePath`.
- `LibraryRoot`: public domain model with typed path and display name, no rowid.
- `MediaAsset`: typed library path, typed relative path, optional name, optional
  content type identifier, optional byte size, optional creation date, optional
  content modification date.
- `CatalogSnapshot`: raw, Sendable, immutable store state built by
  `CatalogStore.currentSnapshot()`.
- `CatalogWindowViewModel`: `@MainActor @Observable`, owned by the one main
  window; owns catalog startup, add/remove intents, sidebar selection, task
  lifetimes, and final catalog window state assignment.
- `CatalogProjection`: actor used for sorting, filtering, and state publication
  away from the MainActor.
- `CatalogDiagnostics`: debug-only actor-serialized JSONL writer for coarse
  durable evidence under Application Support.

SQLite migration v2 adds nullable `media_asset.name` and
`media_asset.created_at_unix`. Missing filesystem facts remain `NULL` and show
as `Unknown`.

## Retirement Proof

Current source and docs must keep these retired surfaces unreachable:

- `OtosAppModel`
- `message` and `dismissMessage`
- generic `Catalog` alert in `ContentView`
- public `LibraryRoot.storageID`
- `visibleAssets`
- `selectedAssets`
- string-concatenated `MediaAsset.id`
- `MED-003`
- raw-path/raw-filename logging prohibitions in authoritative docs

## Instrumentation And Performance

- Keep OSLog categories and signposts for app, UI, catalog, file access,
  persistence, and performance.
- Keep debug JSONL diagnostics for DB open/migrate/load, add/remove, scan
  start/tick/finish/cancel/error, enumeration/resource issues, Projection
  summaries, availability changes, failures, and actual active-app stalls.
- Use Logger/signposts, not per-update JSONL tasks, for ViewModel and collection
  handoffs.
- Use `script/catalog-diagnostics.sh check` to copy/summarize current
  diagnostics into `build/Diagnostics`.
- No Instruments trace is required unless verification shows jank or a build/run
  issue.

## Code-Smell Review

- MainActor gravity: addressed by moving sorting/filtering into
  `CatalogProjection`.
- State duplication: addressed by separating catalog truth, derived projection,
  and MainActor state assignment.
- Stringly typed domain facts: addressed with typed path and identity values.
- Ambiguous Swift API names: `CatalogMediaGridState` explicitly separates scope,
  ordered identities, and keyed current values.
- Diagnostic payload sprawl: bounded JSONL events only; no secrets, credentials,
  thumbnails, or unbounded binary payloads.

## Acceptance Criteria

- Scanner and persistence include Name and Created facts. Spec 0011 owns the
  current placeholder-grid presentation.
- Sorting and selected-scope filtering are owned by `CatalogProjection`,
  not MainActor computed properties.
- Main-window sidebar selection is owned by `CatalogWindowViewModel`.
- Settings state is local to Settings.
- SQLite row IDs are private to `CatalogStore`.
- Media asset identity is a typed pair, not concatenated text.
- Generic catalog messages and alerts are gone.
- Debug diagnostics can be checked after an app run with a repo script.
- `MED-003` and conflicting raw-path/raw-filename restrictions are gone.

## Verification

- Local checks: `script/verify.sh`
- Focused tests: catalog migration/reload, scanner facts, store reconciliation,
  projection sorting/filtering, diagnostics writer/script, and source hygiene.
- Performance/log evidence: `script/catalog-diagnostics.sh check` plus OSLog or
  signpost evidence when needed.
- CI expectations: remote fast gate must pass unless GitHub reports the known
  Actions billing/spending-limit blocker.
