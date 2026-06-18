# Spec: Catalog Window ViewModel

## Classification

- Work type: Refactor
- Current requirement IDs: FND-014, FND-019, FND-023, FND-024, FND-028,
  FND-029, FND-030, FND-031, FND-032, FND-033, FND-034, APP-002, APP-003,
  APP-008
- Future idea or candidate links explicitly requested by the user: none
- ADRs: ADR 0004; publication details updated by ADR 0005

## Problem

The catalog UI state was split between a shared catalog session and a separate
browser state owner. That split was useful while exploring boundaries, but it
left too many layers for Otos's actual product shape. Otos has exactly one main
window. A multi-window catalog architecture is not a future plan, not a deferred
candidate, and not a design question.

Repo inspection found:

- `CatalogStore` already owned SQLite, migrations, in-memory catalog state, and
  scan lifecycle.
- `CatalogProjection` already kept catalog sorting and selected-scope filtering
  off the MainActor.
- The old shared-session/browser-state split created unnecessary ownership for a
  single-window app.
- `ContentView` coordinated state changes that belonged outside Views.
- Settings needed only library-management inputs.

Current-state note: Spec 0009 and ADR 0005 later moved coalesced UI-state
publication into `CatalogProjection`. This spec owns the single-window UI
ownership boundary; Spec 0009 owns the publication loop, `CatalogWindowState`,
and transient availability behavior.

## Scope

In scope:

- Replace the shared-session/browser-state UI split with one
  `CatalogWindowViewModel`.
- Keep `CatalogStore` as the only runtime catalog truth owner.
- Keep `CatalogProjection` as the only owner of catalog sorting, filtering,
  sidebar-scope derivation, title lookup, availability hiding, empty-state
  selection, selected-library validation, and UI-state publication.
- Make SwiftUI views passive composition surfaces.
- Make the main app scene a singleton SwiftUI `Window`, not `WindowGroup`.
- Remove the standard New Window command for the main window.
- Add explanatory code comments around ownership, actor boundaries, task
  lifetimes, and view passivity.
- Document Otos's one-main-window invariant as permanent.

Out of scope:

- Persistence schema changes.
- Scan lifecycle changes.
- Metadata, thumbnails, manual scan controls, sandboxing, bookmarks, durable
  scan IDs, FSEvents, or multiple catalog databases.
- Any future multi-main-window architecture. There is no future multi-window
  path to keep open.

## Architectural Criteria

- Otos has exactly one main window, permanently.
- The main window uses singleton SwiftUI `Window`; the main window does not use
  `WindowGroup`.
- Views do not orchestrate catalog state. They render inputs, bind controls, and
  call model intents.
- SQLite, filesystem traversal, scanning, sorting, filtering, sidebar-scope
  derivation, title lookup, availability hiding, empty-state selection, and
  selected-library validation stay off the MainActor.
- `CatalogStore` owns runtime truth: SQLite, migrations, in-memory roots and
  assets, transient availability, scans, and raw snapshot construction.
- `CatalogProjection` owns derived read models and the coalesced state
  publication loop.
- `CatalogWindowViewModel` owns final SwiftUI-visible state assignment, sidebar
  row selection, user intents, and task lifetimes.
- Settings receives only `[CatalogLibraryState]` plus add/remove intents.
- Settings may render availability, but it does not render scan activity.
- Sidebar selection remains distinct from future media-asset selection.
- Architecture-boundary comments explain current mechanics and why boundaries
  exist, not increment history.

## Captured Requirements For User Verification

The user guidance for this increment was explicit enough to record directly:

| ID or label | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| CHG-001 | Architecture | Otos has exactly one main window as a permanent product and architecture invariant. | Current | `docs/requirements.md`, ADR 0004, `AGENTS.md`, this spec |
| CHG-002 | Architecture | The main window uses a singleton SwiftUI `Window`, not a multi-window `WindowGroup`. | Current | `docs/requirements.md`, ADR 0004, `AGENTS.md`, this spec |
| CHG-003 | Architecture | Agents shall not design, document, ask about, defer, leave seams for, or propose multiple main windows. | Current | `docs/requirements.md`, `AGENTS.md`, this spec |
| CHG-004 | Architecture | `CatalogWindowViewModel` replaces the shared-session/browser-state UI split. | Current | `docs/requirements.md`, ADR 0004, this spec |
| CHG-005 | Architecture | Views shall not coordinate catalog notifications, snapshot construction, or projection invalidation. | Current | `docs/requirements.md`, `AGENTS.md`, this spec |
| CHG-006 | Non-functional | All catalog sorting, filtering, title lookup, selected-scope derivation, availability hiding, empty-state selection, and selected-library validation shall happen in `CatalogProjection` off the MainActor. | Current | `docs/requirements.md`, this spec |
| CHG-007 | Architecture | Settings receives projected library rows and add/remove intents only. | Current | `docs/requirements.md`, this spec |
| CHG-008 | Architecture | `CatalogWindowViewModel` owns sidebar row selection; future media asset selection shall use a separate concept. | Current | `docs/requirements.md`, this spec |
| CHG-009 | Process | Architecture-boundary files shall include explanatory comments for current mechanics and why boundaries exist. | Current | `docs/requirements.md`, `AGENTS.md`, this spec |

Acceptance examples:

- Given the app scene is inspected, the main window is declared as
  `Window("Otos", id: "main")` and not as a `WindowGroup`.
- Given app commands are inspected, the standard New Window command is replaced
  or unavailable for the main window.
- Given `ContentView` is inspected, it does not subscribe to catalog
  notifications, call projection, or coordinate `onChange` catalog work.
- Given `CatalogWindowViewModel` is inspected, it assigns `state` from
  `CatalogProjection`, routes add/remove intents to `CatalogStore`, and does not
  run SQLite, filesystem traversal, sorting, filtering, or projection cadence.
- Given Settings renders, it receives `[CatalogLibraryState]` and add/remove
  closures, not `CatalogWindowViewModel`, `CatalogSnapshot`, media assets, or
  sidebar state.

## Architectural Alternatives

### Alternative A: Single-Window Catalog ViewModel

Replace the shared-session/browser-state split with `CatalogWindowViewModel`.
Keep `CatalogStore` and `CatalogProjection` separate.

Pros:

- Matches the real product: exactly one main window.
- Removes one UI-state layer without moving work into Views.
- Keeps persistence/scanning, projection, and SwiftUI adaptation distinct.
- Gives Settings a narrow dependency surface.
- Keeps sorting and filtering off the MainActor.

Cons:

- The ViewModel has a central role and needs comments/tests so it is not
  mistaken for catalog truth.

Failure modes:

- Future code could start adding database or scanner work to the MainActor
  ViewModel.

### Alternative B: Put Projection Into `CatalogStore`

`CatalogStore` would produce UI-ready window state directly.

Pros:

- Fewer types.
- One actor receives catalog mutations and can see all in-memory data.

Cons:

- Mixes persistence/scanning ownership with UI read-model ownership.
- Makes the store aware of sidebar selection and window titles.
- Store tests would start asserting presentation ordering and labels.

Failure modes:

- The store becomes a general application model.

### Alternative C: Keep Shared Session Plus Browser State

Keep the earlier shared session and browser state split, and make `ContentView`
thinner.

Pros:

- Preserves a split that would be reasonable for a true multi-window app.

Cons:

- Otos is not a multi-window app.
- Keeps a layer that exists mostly to separate windows that do not exist.
- Leaves more names and task ownership points for a Swift newcomer to learn.

Failure modes:

- The architecture implies future multi-window support against the product rule.

### Alternative D: Let Views Drive Catalog Work

`ContentView` could subscribe to catalog changes and call projection directly
through `.task` or `.onChange`.

Pros:

- Direct and easy to see in one file.
- Fewer model methods.

Cons:

- Views become orchestrators.
- SwiftUI `.task` and synchronous view work can inherit MainActor isolation.
- It spreads cancellation and publication handling into view code.

Failure modes:

- Sorting/filtering or subscription setup leaks into view updates.

## Selected Approach

Implement Alternative A.

`CatalogStore` remains the only runtime catalog owner. `CatalogProjection` owns
derived catalog window state and publishes `CatalogWindowState` as described by
ADR 0005. `CatalogWindowViewModel` consumes that state stream, owns
`sidebarSelection`, routes add/remove intents to Store, and assigns final
SwiftUI-visible state on the MainActor.

This is the simplest correct approach because it removes a speculative
multi-window split while preserving the real boundaries that matter today:
persistence/scanning truth, off-MainActor projection, and passive SwiftUI views.

## Interfaces, Ownership, And Data Flow

- `CatalogStore`: actor; owns GRDB, migrations, in-memory catalog state, scans,
  transient availability, cheap change notifications, and raw snapshot
  construction.
- `CatalogSnapshot`: raw immutable Store value built on demand; it is not sorted
  for the main window and is not the UI publication stream.
- `CatalogProjection`: actor; owns sorting, filtering, title lookup,
  selected-scope derivation, availability hiding, empty-state selection,
  selected-library validation, and `CatalogWindowState` publication.
- `CatalogWindowState`: UI-ready value emitted by `CatalogProjection`.
- `CatalogWindowViewModel`: `@MainActor @Observable`; owns one main window's
  final UI state assignment, sidebar selection, user intents, and task
  lifetimes.
- `ContentView`: passive composition; renders sidebar and media table from
  `CatalogWindowViewModel`.
- `SidebarView`: receives `[CatalogLibraryState]` and
  `Binding<SidebarSelection>`.
- `SettingsView`: receives `[CatalogLibraryState]` plus add/remove closures.
- `OtosApp`: owns the one `CatalogWindowViewModel`, declares the one main
  `Window`, starts the ViewModel, and passes narrow slices to the main window and
  Settings.

Data flow:

1. `OtosApp` constructs one `CatalogWindowViewModel`.
2. The main `Window` attaches `ContentView` and calls
   `catalogViewModel.start()`.
3. `CatalogWindowViewModel.start()` subscribes to `CatalogProjection` state and
   starts `CatalogStore`.
4. `CatalogStore` loads SQLite into memory, emits change notifications, and
   scans saved roots.
5. `CatalogProjection` pulls `CatalogStore.currentSnapshot()` on its coalesced
   cadence and emits `CatalogWindowState`.
6. `CatalogWindowViewModel` assigns `state` on the MainActor.
7. Views render the final state.

## Concurrency And Actor Ownership

- MainActor:
  - `CatalogWindowViewModel` state assignment and user intents.
  - SwiftUI views and local control state.
- Catalog actor:
  - `CatalogStore` persistence, scan lifecycle, availability, and raw snapshot
    construction.
- Projection actor:
  - Store notification consumption, sidebar-selection updates, coalesced
    publication, library sorting, asset sorting, selected-scope filtering, title
    lookup, empty-state selection, and selected-library validation.
- Cancellation:
  - ViewModel cancels state consumption on deinit.
  - Projection cancels its listener/timer when no subscribers remain.
  - Store scan cancellation remains owned by `CatalogStore`.

## Instrumentation And Profiling

- Keep existing `Catalog`, `Persistence`, `FileAccess`, and `UI` logs.
- Projection diagnostics use `catalog.projection.window` with library count,
  total asset count, selected-scope asset count, sidebar selection, resolved
  sidebar selection, and empty state.
- Availability diagnostics use `catalog.library.availability`.
- No Instruments trace is required unless verification shows jank.

## Code Comments

Add or keep explanatory comments in:

- `CatalogStore.swift`: runtime catalog truth, dirty notifications, availability
  preservation, and reentrancy checks.
- `CatalogProjection.swift`: off-MainActor publication loop, dirty/in-flight
  behavior, selected-scope derivation, and availability hiding.
- `CatalogWindowViewModel.swift`: MainActor state adapter and task ownership.
- `ContentView.swift`: passive composition.
- `SidebarView.swift` and `SettingsView.swift`: exact input slices and local
  state ownership.
- `CatalogModels.swift`: typed filesystem identity and snapshot/state roles.

Avoid comments that describe increment history, repeat the single-window rule in
ordinary implementation files, or explain obvious syntax.

## Retirement Proof

The increment must remove or prove absent from app source:

- `CatalogSession`
- `CatalogBrowserState`
- `CatalogBrowserProjection`
- `CatalogWindowModel`
- `CatalogWindowProjection`
- `WindowGroup` as the main scene
- `ContentView` catalog `.onChange` orchestration
- view-owned `update(snapshot:)` catalog work
- `assetsForSelection`
- `visibleAssets`
- `selectedAssets`
- generic catalog alert/message code
- Store `snapshots()`/`publishSnapshot()` UI stream paths
- ViewModel generation-based projection rejection

## Test And Acceptance Criteria

- Projection tests cover library sorting, asset sorting, All Media, library scope
  filtering, missing-library fallback to All Media, availability hiding,
  unavailable empty states, 10 Hz coalescing, one-in-flight publication, and
  dirty-during-run rerun behavior.
- ViewModel tests cover idempotent `start()`, state-stream consumption, sidebar
  selection routing, removed-library fallback, and add/remove intent routing.
- Store tests cover change notifications, raw `currentSnapshot()` values,
  unavailable-root preservation, scan-failure availability recheck, and remove
  cancellation/delete behavior.
- Source hygiene tests prove retired types and view orchestration are absent.
- Source hygiene tests prove the app uses singleton `Window`, not `WindowGroup`.
- `script/verify.sh` passes locally.
- Runtime diagnostics check passes after launching the app.

## Code-Smell Review

- MainActor gravity: controlled by keeping SQLite, scanning, projection
  publication, sorting, and filtering out of `CatalogWindowViewModel`.
- State duplication: accepted distinction between raw `CatalogSnapshot` and
  UI-ready `CatalogWindowState`; they have different owners and purposes.
- View orchestration: addressed by keeping catalog subscription and projection
  scheduling out of `ContentView`.
- Ambiguous ownership: addressed with Store/Projection/ViewModel boundaries and
  current-mechanics comments.
- Remaining accepted risk: `CatalogWindowViewModel` is intentionally central for
  the single main window; tests and comments must prevent it from becoming the
  catalog truth owner.

## Verification

- Local checks: `script/verify.sh`
- Focused tests: `CatalogProjectionTests`, `CatalogWindowViewModelTests`,
  `CatalogStoreTests`, `SourceHygieneTests`
- Diagnostics: `script/catalog-diagnostics.sh check` after an app run
- CI expectations: remote fast gate must pass unless GitHub reports an account
  billing, spending-limit, or exhausted Actions quota blocker.
