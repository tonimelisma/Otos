# Spec 0007: Catalog Window ViewModel

## Classification

- Work type: Refactor
- Current requirement IDs: FND-019, FND-023, FND-024, FND-029, FND-030,
  FND-031, FND-032, FND-033, FND-034, FND-035
- ADRs: ADR 0004 and ADR 0005

## Problem And Goal

Otos has exactly one main window. Its catalog UI therefore needs one disciplined
MainActor adapter, not a multi-window session graph. Views must stay passive,
while persistence, filesystem work, ordering, filtering, availability policy,
and publication cadence remain in their non-MainActor owners.

## Scope

In scope:

- singleton SwiftUI Window("Otos", id: "main")
- one app-owned CatalogWindowViewModel
- passive SwiftUI composition and narrow Settings inputs
- explicit sidebar-selection intent delivery
- Store/Projection/ViewModel task and state ownership
- substantial current-state comments at architecture boundaries

Out of scope:

- SQLite or scan lifecycle changes
- media rendering mechanics, owned by ADR 0006
- multiple main windows; this is permanently outside the product architecture
- metadata, thumbnails, manual scans, sandboxing, bookmarks, durable scan IDs,
  FSEvents, or multiple catalog databases

## Architectural Criteria

- Otos has exactly one main window, permanently.
- OtosApp owns one CatalogWindowViewModel and declares a singleton Window.
- Views render inputs, own local control state, and call explicit intents. They
  do not subscribe to catalog changes or coordinate projection.
- CatalogStore owns SQLite, migrations, complete in-memory truth, scans,
  availability, cheap change notifications, and raw snapshot construction.
- CatalogProjection owns sorting, filtering, title lookup, availability hiding,
  empty-state selection, selection resolution, and 10 Hz UI-state publication
  outside MainActor.
- CatalogWindowViewModel owns final state assignment, explicit selection
  delivery, user intents, task lifetimes, and scalar stall correlation on
  MainActor. It does no catalog work itself.
- Settings receives CatalogLibraryState rows plus add/remove intents. It may show
  availability but not scan activity.
- Sidebar row selection remains distinct from future media-asset selection.

## Captured Requirements

| Label | Type | Current requirement |
| --- | --- | --- |
| WIN-001 | Architecture | Exactly one main window is a permanent invariant. |
| WIN-002 | Architecture | The main scene uses Window, never main-window WindowGroup. |
| WIN-003 | Architecture | Views do not orchestrate Store notifications, snapshots, or Projection invalidation. |
| WIN-004 | Non-functional | Catalog derivation stays outside MainActor. |
| WIN-005 | Architecture | The ViewModel is a final-state adapter and explicit-intent owner only. |
| WIN-006 | Architecture | Settings receives only projected library rows and add/remove intents. |
| WIN-007 | Process | Boundary comments explain current mechanics and rationale. |

Acceptance examples:

- OtosApp declares Window("Otos", id: "main") and removes the standard New
  Window command for the catalog window.
- ContentView does not subscribe to catalog notifications, call Store or
  Projection, or coordinate onChange catalog work.
- SidebarView receives library rows, current selection, and one callback.
- CatalogWindowViewModel.selectSidebar(_:) is the only sidebar selection intent
  and Projection normalization does not feed back into it.
- Settings receives no snapshot, media assets, sidebar state, scan status, or
  entire ViewModel.

## Alternatives

### Single Main-Window ViewModel

Pros:

- matches the permanent product shape
- one MainActor owner for state and intent lifetimes
- preserves Store and Projection boundaries

Cons:

- the central adapter needs tests and comments to prevent responsibility creep

Failure mode: database, scanning, or projection work migrates into MainActor.

### Store Produces UI State

Pros:

- fewer types

Cons:

- couples persistence/scanning to sidebar selection, titles, and empty states
- turns Store into a general application model

Failure mode: Store tests become presentation tests.

### Views Drive Projection

Pros:

- orchestration is locally visible in the view file

Cons:

- SwiftUI lifecycle and MainActor inheritance own work scheduling
- cancellation and subscriptions leak into rendering code

Failure mode: sorting, snapshot construction, or notification handling runs in
view updates.

## Selected Approach

Use the single MainActor CatalogWindowViewModel adapter while preserving
CatalogStore and CatalogProjection as actors with distinct truth and derived
state responsibilities. This is the smallest model that matches the permanent
one-window product without moving work into Views or MainActor.

## Interfaces And Data Flow

- CatalogSnapshot: raw keyed Store value built on demand
- CatalogWindowState: UI-ready value emitted by Projection
- CatalogWindowViewModel.state: final value observed by SwiftUI
- SidebarSelection: selected All Media or library sidebar row
- CatalogMediaGridState: selected scope, ordered asset IDs, and scoped current
  asset values

Flow:

1. OtosApp constructs one ViewModel and calls start() from the main scene.
2. ViewModel starts one state-consumer task and Store startup task.
3. Store loads SQLite, emits cheap changes, and scans roots.
4. Projection's dirty loop asks Store for snapshots and emits derived state.
5. ViewModel assigns final state and scalar stall context on MainActor.
6. Views render state and call explicit intents.
7. Sidebar intents pass through one newest-buffered stream and forwarding task
   to Projection.

## Concurrency And Cancellation

- MainActor: ViewModel, SwiftUI, AppKit bridge, and local control state
- Store actor: persistence, runtime truth, scans, availability, snapshots
- Projection actor: change consumption, ordering, filtering, cadence, state
  broadcast
- ViewModel deinitialization finishes its selection stream, cancels startup,
  state-consumer, and selection-forwarding tasks, and stops its stall monitor.
- Projection and Store own their subscriber and scan lifecycles respectively.

## Instrumentation

- ViewModel state assignment uses Logger/signposts with scalar counts.
- The ViewModel-owned stall monitor durably records only actual active-app
  run-loop stalls.
- Projection writes coarse JSONL summaries and emits native signposts.
- No per-state JSONL task is created on MainActor.

## Comments

Store, Projection, ViewModel, models, diagnostics, persistence, scanner, and the
AppKit bridge contain substantial file guides. Focused comments explain
non-obvious task lifetime, actor reentrancy, coalescing, cache validation,
availability preservation, and bridge mechanics. Comments do not narrate
syntax, preserve prior designs, or repeat the one-window invariant throughout
ordinary code.

## Verification

- ViewModel tests: idempotent start, state consumption, rapid explicit selection
  intents, normalization without feedback, add/remove routing, and cancellation
- Projection tests: ordering/filtering, availability hiding, empty states, 10 Hz
  coalescing, one-in-flight work, and dirty-during-await rerun
- source hygiene: no View orchestration, no main WindowGroup, no retired
  parallel UI-state owners, and no implicit selection didSet
- script/verify.sh

## Code-Smell Review

- MainActor gravity is controlled by the adapter-only ViewModel boundary.
- Raw snapshot and UI-ready state are intentionally distinct values with
  different owners, not competing truth stores.
- The ViewModel is intentionally central for one window; source hygiene,
  comments, and tests guard against it becoming catalog truth.
