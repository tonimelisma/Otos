# Spec: Catalog State Diagnostics Cleanup

## Classification

- Work type: Refactor, small behavior, process/tooling
- Current requirement IDs: FND-006, FND-019, FND-020, FND-023, FND-024, FND-025, FND-026, MED-001, MED-002, APP-006, APP-008
- Future idea or candidate links explicitly requested by the user: none
- ADRs: ADR 0002, ADR 0003

## Problem

The first catalog implementation works, but the first pass left several smells:
shared app state owns main-window selection, SQLite row IDs leak through public
models, media IDs are ambiguous string concatenations, asset filtering happens
through a MainActor computed property, and scanner diagnostics are not available
as a checkable run artifact.

Repo inspection found:

- `OtosAppModel` owns shared catalog state, main-window selection, user-facing
  catalog messaging, and snapshot application.
- `LibraryRoot.storageID` exposes the SQLite rowid outside persistence.
- `MediaAsset.id` concatenates library path and relative path with a pipe
  separator.
- The scanner currently stores relative path, content type identifier, byte
  size, and content modification date.
- `script/logs.sh` streams unified logs, but no script summarizes app-owned
  catalog diagnostics after a run.

## Scope

In scope:

- Remove `MED-003` and conflicting raw-path/raw-filename logging restrictions.
- Add scanner storage and UI display for `name` and `creationDate`.
- Split shared catalog state from per-window browsing state.
- Type library root paths, media relative paths, and media asset identity.
- Hide SQLite row IDs inside `CatalogStore`.
- Move catalog sorting and selection filtering off the MainActor.
- Add debug-only JSONL diagnostics and a repo check script for large catalog and
  projection operations.

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
| REM-003 | Architecture | Remove shared main-window selection from the shared catalog model. | Current | `docs/requirements.md`, this spec |
| REM-004 | Architecture | Remove public exposure of SQLite row IDs from catalog models. | Current | `docs/requirements.md`, this spec |
| REM-005 | Architecture | Remove ambiguous media asset string-concatenation identity. | Current | `docs/requirements.md`, this spec |
| CHG-001 | Functional | Media rows show file name, relative path, content type identifier, byte size, creation date, and content modified date. | Current | `docs/requirements.md`, ADR 0002 |
| CHG-002 | Architecture | SwiftUI receives shared catalog state through `CatalogSession`; per-window browser state lives separately. | Current | `docs/requirements.md`, this spec |
| CHG-003 | Architecture | Normalized filesystem path remains library-root identity, while SQLite rowid is persistence-private. | Current | `docs/requirements.md`, ADR 0003 |
| CHG-004 | Non-functional | Catalog sorting and selection filtering must run outside the MainActor. | Current | `docs/requirements.md`, this spec |
| ADD-001 | Architecture | `CatalogSession` owns shared catalog snapshot, startup, add-library, and remove-library intents. | Current | `docs/requirements.md`, this spec |
| ADD-002 | Architecture | `CatalogBrowserState` owns main-window-local selection and derived projection. | Current | `docs/requirements.md`, this spec |
| ADD-003 | Architecture | `CatalogProjection` actor owns root sorting, asset sorting, and `assetsForSelection` filtering. | Current | `docs/requirements.md`, this spec |
| ADD-004 | Architecture | Domain paths and media identity use typed values, not bare strings or concatenated IDs across app boundaries. | Current | `docs/requirements.md`, this spec |
| ADD-005 | Tooling | Debug builds write JSONL diagnostics for large catalog and projection operations. | Current | `docs/requirements.md`, this spec |
| ADD-006 | Tooling | A repo script checks and summarizes catalog diagnostics under `build/Diagnostics`. | Current | `docs/requirements.md`, this spec |

## Architectural Alternatives

### Keep `OtosAppModel` And Rename Properties Only

Pros:

- Smallest code diff.
- Keeps one observable type for the current small UI.

Cons:

- Leaves shared catalog state mixed with per-window selection.
- Does not address MainActor filtering or the global-app-model smell.

Failure modes:

- Settings and future windows inherit unrelated browsing state.
- Later viewport selection collides with current `visibleAssets` naming.

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

### Selected: Shared Session, Window State, And Projection Actor

Pros:

- Gives each owner a narrow job: store owns persistence/scans, session owns
  shared UI-facing catalog state, browser state owns window selection, projection
  actor owns sorting/filtering.
- Moves root sorting, asset sorting, and `assetsForSelection` filtering off the
  MainActor while keeping the model simple.
- Keeps Settings state local.

Cons:

- Adds one small actor and one additional observable state owner.
- Requires stale projection rejection.

Failure modes:

- A stale projection could overwrite newer UI state if generation checks are
  missed.
- Projection diagnostics could become noisy if every tiny state assignment logs.

## Selected Approach

Implement the selected alternative directly. `CatalogStore` publishes unsorted
snapshots. `CatalogSession` subscribes to those snapshots and asks
`CatalogProjection` to sort roots and assets off the MainActor before assigning
the shared snapshot. `CatalogBrowserState` owns `CatalogSelection` and asks the
same projection actor to compute `CatalogBrowserProjection`, including
`assetsForSelection` and title, whenever selection or snapshot changes.

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
- `CatalogSnapshot`: sorted, Sendable, immutable roots/assets/scanning state.
- `CatalogSession`: `@MainActor @Observable`, shared by the main window and
  Settings; owns catalog startup and add/remove intents.
- `CatalogBrowserState`: `@MainActor @Observable`, owned by the main window;
  owns selection and current browser projection.
- `CatalogProjection`: actor used for sorting and filtering away from the
  MainActor.
- `CatalogDiagnostics`: debug-only JSONL writer under Application Support.

SQLite migration v2 adds nullable `media_asset.name` and
`media_asset.created_at_unix`. Missing filesystem facts remain `NULL` and show
as `Unknown`.

## Retirement Proof

The increment must remove or prove unreachable:

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
- Add debug JSONL diagnostics for DB open/migrate/load, add/remove, scan
  start/tick/finish/cancel/error, enumeration/resource issues, projection sort,
  and projection filter.
- Use `script/catalog-diagnostics.sh check` to copy/summarize current
  diagnostics into `build/Diagnostics`.
- No Instruments trace is required unless verification shows jank or a build/run
  issue.

## Code-Smell Review

- MainActor gravity: addressed by moving sorting/filtering into
  `CatalogProjection`.
- State duplication: addressed by separating shared session state from
  per-window browser state.
- Stringly typed domain facts: addressed with typed path and identity values.
- Ambiguous Swift API names: addressed by using `assetsForSelection`.
- Diagnostic payload sprawl: bounded JSONL events only; no secrets, credentials,
  thumbnails, or unbounded binary payloads.

## Acceptance Criteria

- Media table includes Name and Created columns backed by persisted scanner
  facts.
- Sorting and `assetsForSelection` filtering are owned by `CatalogProjection`,
  not MainActor computed properties.
- Main-window selection is local to the main-window browser state.
- Settings state is local to Settings.
- SQLite row IDs are private to `CatalogStore`.
- Media asset identity is a typed pair, not concatenated text.
- Generic catalog messages and alerts are gone.
- Debug diagnostics can be checked after an app run with a repo script.
- `MED-003` and conflicting raw-path/raw-filename restrictions are gone.

## Verification

- Local checks: `script/verify.sh`
- Focused tests: catalog migration/reload, scanner facts, store reconciliation,
  projection sorting/filtering/stale rejection, diagnostics writer/script, and
  source hygiene.
- Performance/log evidence: `script/catalog-diagnostics.sh check` plus OSLog or
  signpost evidence when needed.
- CI expectations: remote fast gate must pass unless GitHub reports the known
  Actions billing/spending-limit blocker.
