# Spec: Catalog Library State Rows

## Classification

- Work type: Refactor
- Current requirement IDs: FND-014, FND-019, FND-023, FND-024, FND-026,
  FND-028, FND-029, FND-030, FND-031
- Future idea or candidate links explicitly requested by the user: none
- ADRs: none required; this refines the UI-facing read model inside the current
  catalog architecture and does not change persistence, filesystem access, or an
  expensive-to-reverse boundary.

## Problem

`CatalogSnapshot` originally exposed saved library roots and transient scan state
as separate values. That made consumers manually join durable root identity to
momentary catalog state and encouraged passing whole snapshots into views that
needed only a small slice.

Repo inspection found:

- Sidebar needed library display names plus transient row state.
- Settings needed library name/path and add/remove actions; after availability
  was added, Settings also needed availability.
- `LibraryRoot` was durable identity and should not absorb transient scan or
  availability state.

Current-state note: Spec 0007 retired the shared-session/browser-state split in
favor of `CatalogWindowViewModel`. Spec 0009 later split library row state into
separate availability and scan activity and moved UI publication into
`CatalogProjection`.

## Scope

In scope:

- Add a catalog read model that pairs each durable library root with current
  transient library state.
- Keep `LibraryRoot` pure as durable library-root identity.
- Change `CatalogSnapshot` to expose `libraries: [CatalogLibraryState]` and
  `assets`.
- Change `SidebarView` to receive `[CatalogLibraryState]`, not the whole
  snapshot.
- Allow Settings library management to receive `[CatalogLibraryState]`,
  add/remove intents, and no scan activity UI.
- Rename sidebar row selection to `SidebarSelection` so it remains distinct from
  future media-asset selection.
- Use `assetsInSelectedScope` for derived media rows in the selected All Media or
  library scope.

Out of scope:

- Persistence schema changes.
- Scan lifecycle behavior changes.
- New progress UI beyond Sidebar's existing scan activity hint.
- Metadata, thumbnails, manual scan controls, durable scan IDs, sandboxing, or
  bookmark behavior.

## Captured Requirements For User Verification

| ID or label | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| ADD-001 | Architecture | The catalog snapshot shall expose one current-state row per library that combines durable root identity with transient library state. | Current | `docs/requirements.md`, this spec |
| ADD-002 | Architecture | `LibraryRoot` shall remain durable library-root identity and shall not store transient availability or scan activity. | Current | `docs/requirements.md`, this spec |
| ADD-003 | Architecture | `SidebarView` shall receive only library state rows and a `sidebarSelection` binding, not the whole `CatalogSnapshot`. | Current | `docs/requirements.md`, this spec |
| ADD-004 | Architecture | Consumers shall not manually join roots to separate scanning or availability collections; transient state belongs on the library state row. | Current | `docs/requirements.md`, this spec |
| ADD-005 | Architecture | Settings library management shall consume library state rows and catalog add/remove intents only; it shall not consume scan activity UI, media assets, browser state, raw snapshots, or the whole window ViewModel. | Current | `docs/requirements.md`, this spec |
| ADD-006 | Architecture | Sidebar row selection shall be named and modeled as `SidebarSelection`, separate from future media-asset selection. | Current | `docs/requirements.md`, this spec |
| ADD-007 | Architecture | Main-window state shall use `sidebarSelection` for the selected sidebar row and `assetsInSelectedScope` for media rows in the selected All Media or library scope. | Current | `docs/requirements.md`, this spec |

Acceptance examples:

- Given one saved library is scanning, the sidebar row for that library shows
  scan activity from the library state row.
- Given one saved library is unavailable, Sidebar and Settings can show
  availability from the library state row without loading media assets.
- Given the sidebar renders, its initializer receives `[CatalogLibraryState]`
  and a `sidebarSelection` binding, not `CatalogSnapshot`.
- Given Settings renders the Libraries tab, its initializer receives
  `[CatalogLibraryState]` and add/remove closures, not
  `CatalogWindowViewModel`, `CatalogSnapshot`, media assets, or sidebar state.
- Given code stores the selected All Media or library row from the sidebar, it
  uses `SidebarSelection`, not `CatalogSelection`.
- Given code exposes the current media rows for the selected sidebar scope, it
  uses `assetsInSelectedScope`, not `assetsForSelection`.

## Architectural Alternatives

### Keep Separate Root And Transient-State Collections

Pros:

- No read-model type is needed.
- The model is understandable while only one view needs row state.

Cons:

- Keeps manual joins in consumers.
- Encourages passing whole snapshots to views that need only library rows.

Failure modes:

- Future library list surfaces duplicate joins or forget one transient state.

### Put Transient State Directly On `LibraryRoot`

Pros:

- Simple for call sites.
- Every library value carries its display state.

Cons:

- Mixes durable root identity with momentary scanner or availability state.
- Makes a saved library root look different depending on runtime conditions.

Failure modes:

- Persistence or equality starts treating transient state as root identity.

### Selected: Add `CatalogLibraryState`

Pros:

- Keeps `LibraryRoot` pure.
- Gives UI consumers one library row with path, display name, availability, and
  scan activity.
- Narrows Sidebar and Settings inputs to the data they actually render.

Cons:

- Adds one small read-model type and small enums.

Failure modes:

- The read model becomes a dumping ground for unrelated sidebar-only details.

## Selected Approach

Use:

- `LibraryAvailability`: current transient availability for a library row,
  initially `.available` or `.unavailable`.
- `CatalogLibraryActivity`: current transient scan activity for a library row,
  initially `.idle` or `.scanning`.
- `CatalogLibraryState`: read model containing `root`, `availability`, and
  `activity`, plus convenience `id`, `path`, `displayName`, `isAvailable`, and
  `isScanning`.

`CatalogSnapshot` stores `libraries: [CatalogLibraryState]` and
`assets: [MediaAsset]`. `CatalogStore.makeSnapshot()` creates one library state
per saved root, attaches transient availability, and marks the current scan root
as `.scanning`. `CatalogProjection` sorts library states and decides which
library assets are visible.

`SidebarView` takes `libraries: [CatalogLibraryState]` and a
`Binding<SidebarSelection>`, then renders availability and scan activity.

`SettingsView` takes `libraries: [CatalogLibraryState]`, `addLibrary`, and
`removeLibrary`. It renders name/path/availability and intentionally does not
display scan activity.

## Interfaces, Ownership, And Data Flow

- `CatalogStore` remains the owner of persisted roots, media assets, transient
  availability, and the current scan task.
- `CatalogStore.makeSnapshot()` is the single place that combines stored
  `LibraryRoot` values with transient library state.
- `CatalogSnapshot` exposes `libraries` and `assets`; it does not expose raw
  root arrays or separate transient-state collections.
- `CatalogProjection` turns raw snapshots into `CatalogWindowState`.
- `CatalogWindowViewModel` consumes `CatalogWindowState` and exposes it to
  SwiftUI.
- `ContentView` passes only `model.state.libraries` into `SidebarView`.
- `OtosApp` passes only projected library state and add/remove intents into
  Settings.

## Concurrency And Actor Ownership

- `CatalogStore` remains an actor and owns transient availability.
- `CatalogProjection` remains an actor and continues to sort/filter off the
  MainActor.
- `CatalogWindowViewModel` remains MainActor UI state assignment.
- This refactor does not add long-running filesystem traversal, persistence
  behavior, or manual scan controls.

## Instrumentation And Profiling

No separate operation is introduced by the row shape. Existing catalog scan,
persistence, availability, and projection diagnostics remain the observable
paths.

## Test And Acceptance Criteria

- Projection tests prove sorted library state rows preserve availability and
  scan activity.
- Store tests prove snapshots expose library state rows and transient state.
- Source hygiene tests reject the retired separate transient-state join pattern.
- Source hygiene tests prove `SidebarView` does not accept `CatalogSnapshot`.
- Source hygiene tests prove Settings does not consume `CatalogWindowViewModel`
  or scan activity UI.
- Source hygiene tests reject the retired `CatalogSelection` and
  `assetsForSelection` app-source terms.
- `script/verify.sh` must pass locally.
- Runtime diagnostics check must pass after launching the app.

## Code-Smell Review

- State duplication: the retired separate-collections shape duplicated row
  reconstruction knowledge across consumers. `CatalogLibraryState` removes that
  join.
- Stringly typed domain facts: typed `LibraryRootPath` remains the path identity.
- MainActor gravity: sorting and filtering remain in `CatalogProjection`, not in
  SwiftUI views.
- New accepted risk: `CatalogLibraryState` must stay a current read model and
  not grow unrelated sidebar-only state.

## Verification

- Local checks: `script/verify.sh`
- Focused updates: projection tests, store snapshot tests, and source hygiene for
  the removed transient-state join pattern.
