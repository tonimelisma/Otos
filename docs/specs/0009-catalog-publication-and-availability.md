# Spec: Catalog Publication, Availability, Naming, And Comment Cleanup

## Classification

- Work type: Refactor, behavior, documentation
- Current requirement IDs: FND-006, FND-019, FND-023, FND-024, FND-028,
  FND-029, FND-031, FND-033, FND-034, FND-035, FND-037, FND-038, FND-039,
  FND-040, APP-002, APP-003, APP-005, APP-008
- Future idea or candidate links explicitly requested by the user: none
- ADRs: ADR 0005; updates ADR 0004 references

## Problem

The dirty catalog branch already moved Otos toward a single-window architecture,
but the publication flow was still split in a way that made ownership harder to
explain:

- `CatalogStore` published full raw snapshots to UI subscribers.
- `CatalogWindowModel` scheduled projection tasks and rejected stale completions
  with generation counters.
- `CatalogProjection` performed sorting and filtering, but did not own the
  publication cadence for UI-ready state.

That left two similar mechanisms: one cadence for store snapshot publication and
one stale-result mechanism for projection. It also left the app unable to model a
library root that temporarily disappears, such as an ejected disk or unreachable
network path. A failed scan should not delete preserved catalog rows when the
root itself is unavailable.

Repo inspection found:

- `CatalogStore` could already build raw `CatalogSnapshot` values from in-memory
  roots/assets.
- `CatalogProjection` was already a non-MainActor actor and was the right owner
  for sorting/filtering.
- `CatalogWindowModel` was MainActor-isolated and had become the wrong place for
  projection scheduling and generation-based stale rejection.
- Settings needed library rows plus add/remove intents, and availability is now
  useful there; scan activity is not.
- Several comments described recent increment history or repeated the
  single-window invariant instead of explaining current mechanics.

## Scope

In scope:

- Rename `CatalogWindowModel` to `CatalogWindowViewModel`.
- Rename `CatalogWindowProjection` to `CatalogWindowState`.
- Rename the ViewModel's SwiftUI-visible property from `projection` to `state`.
- Keep `CatalogSnapshot` as the raw point-in-time store value and document that
  it is not a UI publication stream.
- Change `CatalogStore` to emit cheap change notifications rather than full
  snapshot streams.
- Move the 10 Hz coalesced `CatalogWindowState` publication loop into
  `CatalogProjection`.
- Ensure only one projection publication runs at a time.
- Preserve dirty state when inputs change during an in-flight publication and
  rerun on the next tick.
- Add transient `LibraryAvailability`.
- Split library availability from scan activity in `CatalogLibraryState`.
- Preserve catalog rows when roots are unavailable.
- Hide unavailable libraries' media in projected UI state.
- Show availability in Sidebar and Settings; keep scan activity out of Settings.
- Clean code comments so they explain current mechanics and why boundaries
  exist.

Out of scope:

- SQLite schema changes.
- Periodic availability probing, FSEvents, manual scan controls, metadata,
  thumbnails, durable scan IDs, package/container media import, sandboxing,
  bookmarks, or multi-main-window architecture.
- User-facing error alerts or banners.

## Captured Requirements For User Verification

The user guidance for this increment was explicit enough to record directly.

| ID or label | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| REN-001 | Architecture | Rename `CatalogWindowModel` to `CatalogWindowViewModel`. | Current | `docs/requirements.md`, ADR 0004, this spec |
| REN-002 | Architecture | Rename `CatalogWindowProjection` to `CatalogWindowState`. | Current | `docs/requirements.md`, this spec |
| REN-003 | Architecture | Rename the ViewModel's UI-visible property from `projection` to `state`. | Current | `docs/requirements.md`, this spec |
| PUB-001 | Architecture | `CatalogStore` exposes cheap change notifications, not a UI snapshot stream. | Current | `docs/requirements.md`, ADR 0005, this spec |
| PUB-002 | Architecture | `CatalogStore.currentSnapshot()` remains the on-demand raw store snapshot builder. | Current | `docs/requirements.md`, ADR 0005, this spec |
| PUB-003 | Architecture | `CatalogProjection` owns the 10 Hz coalesced `CatalogWindowState` publication loop. | Current | `docs/requirements.md`, ADR 0005, this spec |
| PUB-004 | Non-functional | Only one projection publication may run at a time. | Current | `docs/requirements.md`, ADR 0005, this spec |
| PUB-005 | Non-functional | If inputs change while projection publication is in flight, the completed state may be yielded and the next tick reruns with the latest dirty state. | Current | `docs/requirements.md`, ADR 0005, this spec |
| PUB-006 | Architecture | Generation-based stale projection rejection is removed from the ViewModel. | Current | `docs/requirements.md`, this spec |
| AVAIL-001 | Architecture | Library availability is transient in-memory state and is not persisted to SQLite. | Current | `docs/requirements.md`, ADR 0005, this spec |
| AVAIL-002 | Architecture | `CatalogLibraryState` has separate `availability` and scan `activity` fields. | Current | `docs/requirements.md`, this spec |
| AVAIL-003 | Functional | Availability is checked before scans and after scan failure. | Current | `docs/requirements.md`, ADR 0005, this spec |
| AVAIL-004 | Functional | Unavailable roots preserve cataloged rows and do not reconcile/delete media rows. | Current | `docs/requirements.md`, ADR 0005, this spec |
| AVAIL-005 | Functional | A later scan opportunity that finds a root available marks it available and scans normally. | Current | `docs/requirements.md`, ADR 0005, this spec |
| UI-001 | Functional | Sidebar shows library availability and scan activity. | Current | `docs/requirements.md`, this spec |
| UI-002 | Functional | Settings receives `[CatalogLibraryState]`, renders name/path/availability, and does not display scan activity. | Current | `docs/requirements.md`, this spec |
| UI-003 | Functional | All Media hides assets from unavailable libraries. | Current | `docs/requirements.md`, this spec |
| UI-004 | Functional | Selecting an unavailable library shows no stale rows and displays `Library Unavailable`. | Current | `docs/requirements.md`, this spec |
| UI-005 | Functional | All Media displays `No Available Media` when all cataloged media belongs to unavailable libraries. | Current | `docs/requirements.md`, this spec |
| CMT-001 | Process | Comments explain current mechanics and why code works; they do not read like increment history or repeat documented invariants. | Current | `docs/requirements.md`, `AGENTS.md`, this spec |

Acceptance examples:

- Given a library root is saved but unavailable when its scan turn arrives, the
  root is marked unavailable, existing media rows remain in memory/SQLite, and
  missing-row reconciliation does not run for that root.
- Given an unavailable library has cataloged rows, All Media hides those rows and
  the library scope shows `Library Unavailable`.
- Given all cataloged rows belong to unavailable libraries, All Media shows
  `No Available Media`.
- Given add/remove, scan batch, scan failure, availability, or sidebar selection
  changes occur rapidly, SwiftUI receives coalesced `CatalogWindowState` updates
  from `CatalogProjection`, not raw store snapshot streams.
- Given projection is already building state and another input changes, no
  second projection starts immediately; the next tick reruns with the latest
  dirty inputs.
- Given code comments are inspected, ordinary files explain actor ownership,
  publication coalescing, reentrancy, cancellation, availability preservation,
  and non-obvious filesystem behavior without changelog prose.

## Architectural Alternatives

### Alternative A: Keep Store Snapshot Stream And ViewModel Generation

Pros:

- Smallest refactor from the dirty branch.
- Raw snapshot publication remains easy to observe in tests.

Cons:

- Leaves publication split across Store and ViewModel.
- Requires a ViewModel generation counter for stale projection completions.
- Sidebar selection still needs separate projection scheduling.

Failure modes:

- Store and projection grow parallel cadence/cancellation machinery.

### Alternative B: Move UI Projection Into Store

Pros:

- One actor could own mutation, snapshot construction, and UI publication.
- Avoids an extra state stream.

Cons:

- Mixes persistence/scanning with presentation selection, titles, sorting, and
  empty-state selection.
- Makes Store aware of sidebar selection.

Failure modes:

- Store becomes an application model instead of catalog truth owner.

### Alternative C: ViewModel Owns The Coalesced Loop

Pros:

- Keeps Projection as a pure derivation service.
- The ViewModel already sees sidebar selection.

Cons:

- MainActor-adjacent code owns scheduling for expensive work.
- The ViewModel becomes harder to explain to a Swift newcomer.

Failure modes:

- MainActor gravity returns through task scheduling and stale-result handling.

### Selected: Projection-Owned Publication Loop

Pros:

- One owner handles every input that affects catalog window state.
- Sorting, filtering, empty states, availability hiding, and publication cadence
  remain off the MainActor.
- The ViewModel becomes a simple stream consumer and intent router.
- The Store remains focused on catalog truth.

Cons:

- `CatalogProjection` now owns task lifetimes and not just pure derivation.
- Async tests need to cover cadence and dirty/in-flight behavior.

Failure modes:

- A missed dirty flag could skip a state update.
- Overlapping publications could waste CPU if the one-in-flight rule regresses.

## Selected Approach

Implement the selected alternative.

`CatalogStore` emits `AsyncStream<Void>` change notifications and keeps
`currentSnapshot()` as the raw point-in-time snapshot boundary. `CatalogProjection`
subscribes to those notifications, accepts sidebar selection updates, wakes at a
10 Hz cadence when dirty, pulls the current raw snapshot, and publishes
`CatalogWindowState`. `CatalogWindowViewModel` starts the store/projection flow,
assigns `state`, owns the sidebar selection binding, and routes add/remove
intents to the store.

Availability is owned by `CatalogStore` because it describes the transient
runtime condition of saved roots. Projection consumes the snapshot's
availability rows and decides what the window should show.

## Interfaces, Ownership, And Data Flow

- `CatalogStore`: actor; owns SQLite, migrations, in-memory roots/assets,
  transient availability, scans, scan persistence cadence, root add/remove, cheap
  change notifications, and `currentSnapshot()`.
- `CatalogSnapshot`: raw immutable point-in-time Store value. It is not sorted
  for the main window and is not the UI publication stream.
- `CatalogLibraryState`: read model containing durable `LibraryRoot`, transient
  `LibraryAvailability`, and transient `CatalogLibraryActivity`.
- `CatalogProjection`: actor; owns the publication loop and all derived
  `CatalogWindowState` work.
- `CatalogWindowState`: UI-ready value containing library rows, title, resolved
  sidebar selection, media empty state, and the `CatalogMediaGridState` defined
  by Spec 0011.
- `CatalogWindowViewModel`: `@MainActor @Observable`; owns final state
  assignment, sidebar selection, add/remove/start intents, and task lifetimes.
- `ContentView`: passive composition from `CatalogWindowViewModel.state`.
- `SidebarView`: receives `[CatalogLibraryState]` and
  `Binding<SidebarSelection>`.
- `SettingsView`: receives `[CatalogLibraryState]`, add intent, remove intent,
  and local selection/importer/confirmation state.

Data flow:

1. `OtosApp` constructs one `CatalogWindowViewModel`.
2. `CatalogWindowViewModel.start()` subscribes to
   `CatalogProjection.states(store:initialSidebarSelection:)` and starts
   `CatalogStore`.
3. `CatalogStore` loads SQLite into memory, emits a change notification, and
   auto-scans saved roots.
4. `CatalogProjection` marks itself dirty for store notifications and sidebar
   selection changes.
5. On a 100 ms tick, if dirty and no projection is in flight, Projection pulls
   `CatalogStore.currentSnapshot()` and builds `CatalogWindowState`.
6. `CatalogWindowViewModel` assigns the state on the MainActor and normalizes
   `sidebarSelection` when Projection resolves a removed selection to All Media.
7. Views render final state and call ViewModel intents.

## Concurrency And Actor Ownership

- MainActor:
  - SwiftUI views and local control state.
  - `CatalogWindowViewModel` state assignment and user intents.
- Catalog actor:
  - SQLite, in-memory truth, availability, scan lifecycle, change
    notifications, and raw snapshot construction.
- Projection actor:
  - Store notification listener task.
  - 10 Hz timer loop.
  - Dirty flag and one-in-flight publication guard.
  - Snapshot pull, sorting, filtering, availability hiding, and state emission.

Cancellation:

- `CatalogWindowViewModel` owns and cancels its state-consumption task on
  deinitialization.
- `CatalogProjection` cancels its store-listener and timer tasks when the final
  subscriber ends.
- `CatalogStore` continues to own scan cancellation when roots are removed.

Actor reentrancy:

- Store scan batch writes recheck the current scan identity after awaited SQLite
  work before mutating in-memory assets.
- Projection clears the dirty flag before awaited snapshot/state work; changes
  during that await mark dirty again for the next tick.

## Instrumentation And Profiling

- Keep OSLog categories and signposts for App, UI, FileAccess, Catalog, and
  Persistence.
- Keep debug JSONL diagnostics for database operations, add/remove, scan
  start/tick/finish/cancel/error, enumeration/resource issues, package skips,
  and projection work.
- Add/keep diagnostics for availability changes through `catalog.library.availability`.
- Projection diagnostics use `catalog.projection.window` with library count,
  total asset count, selected-scope asset count, sidebar selection, resolved
  selection, and empty-state outcome.
- No Instruments trace is required unless verification shows jank.

## Code Comments

Keep comments that explain:

- Why Store emits dirty signals instead of UI snapshots.
- Why Projection owns the coalesced publication loop.
- Why dirty is cleared before awaited work and preserved when inputs arrive
  during in-flight publication.
- Why unavailable roots preserve rows and skip reconciliation.
- Why Store rechecks scan identity after awaited database writes.
- Why ViewModel is MainActor-only state assignment and intent routing.

Remove comments that:

- Describe the last increment instead of the current code.
- Repeat the single-window invariant in ordinary implementation files.
- Explain obvious Swift syntax or UI labels.

## Test And Acceptance Criteria

- Source hygiene tests reject:
  - `CatalogWindowModel`
  - `CatalogWindowProjection`
  - Store `snapshots()`/`publishSnapshot()` UI stream paths
  - generation-based projection rejection in the ViewModel
  - view-owned catalog orchestration
- Store tests prove:
  - change notifications are cheap dirty signals
  - `currentSnapshot()` returns raw point-in-time catalog state
  - unavailable roots preserve rows and do not reconcile/delete
  - failed scans recheck root availability before marking unavailable
  - removed roots cancel scans and delete catalog rows
- Projection tests prove:
  - 10 Hz loop coalesces store changes and sidebar changes
  - only one projection publication runs at a time
  - dirty-during-run yields then reruns
  - unavailable-library assets are hidden from All Media and selected-library
    scopes
  - unavailable empty states are selected correctly
- ViewModel tests prove:
  - renamed ViewModel starts idempotently
  - ViewModel assigns `state` from Projection's stream
  - sidebar selection routes into Projection
  - add/remove intents route to Store
- View tests where practical prove:
  - Sidebar and Settings render availability
  - Settings does not display scan activity
  - Media grid shows unavailable empty states
- `script/verify.sh` passes locally.
- Runtime app verification and diagnostics check run before final DoD closure.

## Code-Smell Review

- MainActor gravity: addressed by moving publication scheduling out of the
  ViewModel and keeping projection work in `CatalogProjection`.
- State duplication: accepted distinction between raw `CatalogSnapshot` and
  UI-ready `CatalogWindowState`; they answer different questions.
- Ambiguous naming: addressed by renaming the SwiftUI adapter to
  `CatalogWindowViewModel` and its output to `state`.
- Task ownership: improved by having Projection own publication tasks and
  ViewModel own only its consumption task.
- Diagnostic payload sprawl: unchanged policy; raw paths may be useful developer
  diagnostics, but secrets, credentials, thumbnails, unbounded metadata, and
  binary payloads remain inappropriate.
- Remaining accepted risk: briefly yielding an older state when input changed
  during in-flight publication is acceptable because the next tick reruns with
  the latest dirty input.

## Verification

- Local checks: `script/verify.sh`
- Runtime check: `script/build_and_run.sh --verify`
- Diagnostics check: `script/catalog-diagnostics.sh check`
- CI expectations: remote fast gate must pass unless GitHub reports an account
  billing, spending-limit, or exhausted Actions quota blocker that prevents jobs
  from starting.
