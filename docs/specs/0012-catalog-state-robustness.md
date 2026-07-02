# Spec 0012: Catalog State Robustness

## Classification

- Work type: Refactor, reliability, instrumentation, and process/tooling
- Current requirement IDs: FND-023, FND-025, FND-028, FND-034, FND-035,
  FND-039, FND-040, FND-041, FND-043, FND-046, MED-002
- Retired requirement: FND-042
- ADRs: ADR 0005 and ADR 0007, amended in place

## Problem And Goal

The catalog architecture has correct high-level owners, but seven local design
smells make state delivery harder to reason about than it needs to be:

1. high-frequency UI paths create unstructured JSONL write tasks
2. a global UI update tracker duplicates ViewModel handoff context
3. sidebar selection uses property observation plus task spawning and a recursion
   guard instead of an explicit intent path
4. database-loaded roots are called available before reachability is checked
5. Store mutation paths maintain a manual structure revision for order caching
6. Projection materializes values for every asset even when one scope is visible
7. every `MediaAsset` duplicates its library display name

The goal is a simpler, more truthful, and more robust current-state flow without
changing the established Store/Projection/ViewModel/AppKit ownership, SQLite
schema, scan cadence, or media-grid behavior.

## Current Repo State

- `CatalogStore` is an actor that owns GRDB, SQLite migrations, root runtime
  state, Store-owned catalog queries, serial scans, availability, and cheap
  change notifications.
- `CatalogProjection` is an actor that owns the one-in-flight window-state
  publication loop and descriptor normalization outside MainActor.
- `CatalogWindowViewModel` is the single MainActor adapter for final state and
  user intents.
- `MediaAssetCollectionView` is a narrow AppKit bridge with one structural
  diffable apply in flight and newest-pending coalescing.
- JSONL diagnostics are debug-only durable evidence under Application Support;
  Logger and signposts are available for high-frequency native telemetry.

## Scope

In scope:

- explicit sidebar-selection intent delivery
- truthful unknown library availability
- identity-validated asset-order reuse
- selected-scope-only asset value maps
- removal of duplicated library display-name values
- native high-frequency UI telemetry and durable coarse JSONL evidence
- one actor-serialized lazy JSONL file handle
- ViewModel-owned main-run-loop stall correlation
- extensive current-state code guides and focused rationale comments
- repository-wide living-documentation and comment-accuracy enforcement

Out of scope:

- SQLite migration or schema change
- scan behavior, scan cadence, manual scanning, FSEvents, or durable scan IDs
- sandboxing or bookmarks
- media eligibility, thumbnails, metadata, selection, preview, or editing
- collection layout or rendering behavior changes
- periodic availability probing

## Captured Requirements For User Verification

The user explicitly required these items; this spec records them atomically:

| Label | Type | Requirement | Authority after landing |
| --- | --- | --- | --- |
| ROB-001 | Architecture | Keep Store, Projection, ViewModel, and AppKit ownership boundaries; simplify inside them. | FND-034 |
| ROB-002 | Tooling | Use native Logger/signposts for high-frequency UI telemetry; reserve JSONL for durable coarse evidence. | FND-025, FND-041 |
| ROB-003 | Architecture | Replace implicit sidebar `didSet` orchestration with one explicit, ordered intent path. | FND-023 |
| ROB-004 | Functional | A database-loaded root is unknown until checked; do not fabricate availability. | FND-028, FND-039, FND-040, MED-002 |
| ROB-005 | Architecture | Remove manual structure-revision bookkeeping and validate cached identity membership directly. | FND-042 retired, FND-043 changed |
| ROB-006 | Architecture | Materialize only selected-scope asset values and remove duplicated display-name state. | FND-043 |
| ROB-007 | Process | Add substantial code guides explaining current mechanics and rationale to all affected architecture boundaries. | FND-035 |
| ROB-008 | Process | Current ADRs, specs, requirements, process docs, comments, templates, scripts, backlinks, and indexes must never remain stale. | FND-046 |

## The Seven Smells And Resulting Flows

### 1. Per-Update JSONL Tasks

Before:

1. ViewModel state assignment or AppKit collection work occurs on MainActor.
2. The path creates an unstructured `Task` for a JSONL event.
3. The task captures update context and queues behind the diagnostics actor.
4. Rapid UI updates can create more task objects than durable evidence needs.

During the change:

- remove JSONL calls and task creation from ViewModel state assignment and the
  collection bridge
- add Logger events and signposted spans for state receipt, structural apply,
  pending replacement, completion, visible reconfiguration, structural reload,
  layout, and slow cells
- retain JSONL for Store/scan boundaries, Projection summaries, availability
  transitions, failures, and actual run-loop stalls

After:

1. High-frequency UI boundaries emit native telemetry synchronously with scalar
   fields and signpost IDs.
2. No catalog state is retained for durable UI-event serialization.
3. A real stall alone creates one rare JSONL task containing scalar correlation
   fields.

Impact: bounded task ownership, lower diagnostic interference, and better fit
with Instruments without losing durable operational evidence.

### 2. Global UI Update Tracker

Before:

1. ViewModel assigns state.
2. A global MainActor tracker stores the latest update ID and grid counts.
3. A separate run-loop monitor reads that ambient state when a stall occurs.
4. Ownership of handoff context is split between the ViewModel and singleton.

During the change:

- merge scalar handoff tracking into `MainRunLoopStallMonitor`
- make the ViewModel own that monitor and its lifetime
- start and stop monitoring with ViewModel startup/deinitialization

After:

1. The ViewModel supplies scalar handoff context to its monitor after state
   assignment.
2. The monitor observes active-app run-loop delays.
3. A confirmed stall records the latest scalar context without retaining
   `CatalogWindowState`.

Impact: explicit lifetime, no ambient mutable UI state, and one owner for stall
correlation.

### 3. Implicit Sidebar Selection Orchestration

Before:

1. SwiftUI writes `sidebarSelection` through a binding.
2. `didSet` starts an unstructured forwarding task.
3. Projection can resolve a removed selection to All Media.
4. Applying the resolved value triggers `didSet` again, so a recursion guard is
   needed to suppress a false user intent.
5. Rapid changes create independently scheduled tasks whose delivery order is
   not represented by one owner.

During the change:

- expose `selectSidebar(_:)` as the only selection intent
- make the ViewModel property read-only outside the type
- create one `.bufferingNewest(1)` `AsyncStream` and one forwarding task
- let Sidebar construct a local control binding from value plus callback
- let Projection retain its resolved fallback when no newer intent arrived
- apply Projection's resolved selection in ViewModel without emitting an intent

After:

1. Sidebar calls one explicit ViewModel intent.
2. The ViewModel updates immediate UI selection and yields the value.
3. The owned stream retains only the newest pending rapid input.
4. The forwarding task serially calls Projection.
5. Projection retains a missing-library fallback unless a newer intent arrived
   during the build.
6. Resolved state updates the ViewModel property with no feedback path.

Impact: ordered ownership, bounded pending work, simpler cancellation, and no
recursion guard.

### 4. Optimistic Availability

Before:

1. Roots load from SQLite.
2. They are represented as available before the filesystem is checked.
3. Cached rows may briefly appear for an ejected or disconnected root.
4. The pre-scan check later corrects the state.

During the change:

- add `.unknown`
- initialize database-loaded roots as unknown
- keep newly added and successfully validated roots available
- hide unknown assets and add checking labels/empty states

After:

1. SQLite load restores durable root identity and catalog rows only.
2. The library row says unknown and UI says Checking.
3. The existing pre-scan check transitions it to available or unavailable.
4. Rows remain preserved in every availability state.

Impact: no fabricated reachability, no startup blocking, and no stale media
exposure before a check.

### 5. Manual Structure Revision

Before:

1. Store mutates keyed asset membership.
2. Each qualifying path must increment a transient counter exactly once.
3. Snapshot carries the counter to Projection.
4. Projection still needs a defensive identity check to avoid incomplete output
   if bookkeeping is wrong.

During the change:

- remove the counter, all mutation increments, snapshot/diagnostic fields, and
  revision-specific tests
- validate cached count and ID membership directly

After:

1. Store snapshots expose keyed truth only.
2. Projection checks whether cached IDs exactly represent snapshot membership.
3. A valid set reuses order; insertion, deletion, or same-count replacement
   causes a normal cache miss and sort.

Impact: fewer mutation responsibilities and a cache validity rule derived from
the actual authoritative identity set.

### 6. Full Asset Rematerialization

Before:

1. Projection validates or rebuilds global order.
2. It resolves values for all ordered IDs into the published grid map.
3. It separately filters identity order for availability and sidebar scope.
4. A detail change outside the selected scope can make window state unequal.

During the change:

- filter cached IDs first by available roots and sidebar scope
- fetch visible details separately by ID through the Store-backed detail reader

After:

1. Store returns ordered IDs from persisted sort keys.
2. Availability and scope produce ordered visible IDs.
3. Projection publishes ordered IDs plus a scalar detail-refresh generation.
4. Only visible IDs are queried as current detail values by the grid reader.

Impact: less copied state, narrower publication, and fewer irrelevant UI
assignments while preserving complete Store truth.

### 7. Duplicated Library Display Name

Before:

1. Each Store asset carries root identity and a copied library display name.
2. Snapshot repeats that display name for every asset.
3. Projection sorts using the duplicated field.
4. A root name change would require updating every asset copy.

During the change:

- remove `MediaAsset.libraryDisplayName`
- build one root-to-display-name lookup from snapshot library rows
- use typed root display-name fallback only for malformed snapshots

After:

1. `MediaAsset` contains only its identity and filesystem facts.
2. Library rows remain the display-name authority.
3. Projection joins the name once per root during sorting.

Impact: smaller model, one display-name authority, and no denormalized update
path.

## Architectural Alternatives

### Diagnostics Delivery

1. Per-event JSONL tasks preserve every event but create unbounded task pressure
   and duplicate native telemetry.
2. A bounded custom logging queue limits pressure but duplicates OSLog buffering,
   lifecycle, and Instruments integration.
3. Native Logger/signposts for high-frequency UI plus actor-serialized JSONL for
   coarse durable evidence uses each mechanism for its strength.

Selected: option 3. It is the smallest correct split and prevents diagnostics
from perturbing the UI path being measured.

### Sidebar Intent Delivery

1. Property `didSet` plus tasks is compact but implicit and unordered.
2. Replaceable per-change tasks add cancellation bookkeeping and can discard an
   intermediate selection whose state was already shown.
3. One newest-buffered stream plus one owned task makes ordering, backpressure,
   and cancellation explicit.

Selected: option 3.

### Startup Availability

1. Optimistic available fabricates reachability.
2. Block database publication until all roots are checked delays cached catalog
   and couples startup to slow/removable storage.
3. Explicit unknown publishes truthful durable state immediately and lets the
   existing scan lifecycle resolve reachability.

Selected: option 3.

### Order Reuse

1. Sort every publication is simplest in state but repeats unnecessary work.
2. Manual revision makes Store maintain derived invalidation truth.
3. Direct identity validation reuses order when proven valid and sorts otherwise.

Selected: option 3. O(n) identity validation is intentionally preferred over a
fragile counter because correctness and ownership come before theoretical
constant-time invalidation.

## Ownership, Concurrency, And Cancellation

- `CatalogStore` actor owns database connection, root runtime state,
  Store-owned catalog queries, transient availability, serial scan tasks, and
  broadcast change continuations.
- `CatalogProjection` actor owns descriptor-ordered Store queries, scope
  derivation, diagnostics summaries, publication loop, dirty flag, and state
  broadcast continuations.
- `CatalogWindowViewModel` runs on MainActor and owns final state assignment,
  explicit user intents, separate newest-value selection and lossless mutation
  streams/forwarding tasks, store startup task, weak state-consumer task, and
  stall monitor.
- `MediaAssetCollectionView` stays MainActor-bound because AppKit requires it;
  it owns one in-flight structural apply and newest pending collection state.
- ViewModel deinitialization cancels consumers before finishing both intent
  streams and stops the monitor. State consumption does not retain the ViewModel
  across stream waits. Store scan cancellation remains Store-owned.
- No SQLite, filesystem, sorting, filtering, cache validation, or scope
  materialization runs on MainActor.

## Instrumentation

Durable debug JSONL:

- database/load/add/remove boundaries
- scan start/tick/finish/cancel/error and enumeration/resource issues
- Projection summaries including cache hit, membership change, sort duration,
  ordered count, and selected-scope count
- availability transitions and failures
- actual active-app main-run-loop stalls with scalar handoff context

High-frequency native telemetry:

- ViewModel state assignment
- collection state receipt, structural apply, pending replacement, completion,
  visible reconfiguration, structural reload, layout replacement, and slow cell
  configuration

`CatalogDiagnostics` lazily opens one append handle, serializes writes through
its actor, and closes/resets for deletion, test reset, error recovery, or actor
deinitialization. `script/catalog-diagnostics.sh check` summarizes the durable
event vocabulary into `build/Diagnostics`.

## Living Documentation And Comment Audit

- delete Spec 0002 because the roadmap is already clearly owned by the
  non-authoritative `docs/product/roadmap.md`
- amend ADR 0005 and ADR 0007 in place and rename ADR 0007 around order reuse
- rewrite every stale current-state claim in Specs 0004 through 0011
- update requirements, AGENTS, workflow, templates, PR checklist, DoD report,
  documentation index, diagnostics script, and backlinks
- add substantial current-state guides to catalog models, Store, Store
  persistence, scanner, Projection, ViewModel, diagnostics, stall monitor, and
  AppKit collection bridge
- remove comments that narrate prior increments, removed structures, or syntax

Git history preserves the retired implementation. Current docs and comments do
not.

## Acceptance Criteria

- rapid sidebar intents resolve to the newest value through one owned stream
- Projection normalization creates no selection feedback loop
- database-loaded roots are unknown without scanning
- unknown and unavailable assets remain cataloged but hidden
- checking labels and empty states are correct
- detail-only changes reuse identity order
- insertion, deletion, and same-count replacement rebuild order
- only selected-scope asset values are published
- Store contains no manual order-cache invalidation bookkeeping
- AppKit and ViewModel high-frequency paths create no JSONL tasks
- JSONL append handle is reused, resettable, and disabled when configured off
- all affected current docs/comments describe the landed architecture

## Verification

- focused Store, Projection, ViewModel, diagnostics, collection, and source
  hygiene tests
- `script/verify.sh`
- `script/catalog-diagnostics.sh check`
- focused unified-log capture for UI and catalog categories
- agent-controlled Time Profiler and Swift Concurrency traces
- bounded process RSS observation during agent-controlled runtime verification
- PR/CI/merge/post-merge/cleanup evidence in the one final DoD report

## Code-Smell Review

Addressed:

- unsafe/unowned task creation in high-frequency UI paths
- implicit side effects in a property observer
- fabricated availability
- duplicated invalidation and display-name state
- over-wide projected value maps
- ambient global MainActor tracking state
- stale documentation and comments

Accepted:

- Projection's order cache is derived state, justified by measured high-cardinal
  grid work and guarded by direct identity validation.
- UUID-keyed continuation dictionaries remain correct broadcast-subscription
  lifecycle management; they do not represent multiple windows or domain IDs.

No compatibility shim, schema fork, generalized queue, or speculative future
hook is introduced.
