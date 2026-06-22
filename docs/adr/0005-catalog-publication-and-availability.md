# ADR 0005: Catalog Publication, Selection Delivery, And Availability

- Status: Accepted
- Date: 2026-06-15
- Last updated: 2026-06-22
- Specs: `docs/specs/0009-catalog-publication-and-availability.md`,
  `docs/specs/0012-catalog-state-robustness.md`,
  `docs/specs/0013-catalog-lifecycle-race-safety.md`

## Context

Catalog mutation, UI derivation, and MainActor assignment have different owners.
`CatalogStore` owns SQLite, the in-memory catalog, and scans. `CatalogProjection`
owns ordering, scope filtering, availability hiding, empty-state selection, and
the UI publication cadence. `CatalogWindowViewModel` owns the final state that
SwiftUI observes and converts user actions into explicit intents.

Library reachability is transient. A root loaded from SQLite has not been
checked during the current process and therefore cannot truthfully be called
available. A temporarily missing removable or network root must not cause Otos
to delete catalog rows.

## MECE Decision Scope

This ADR owns:

- Store change notifications versus Store-published UI snapshots
- Projection-owned 10 Hz `CatalogWindowState` publication
- one-in-flight publication and dirty-during-await behavior
- explicit sidebar-selection delivery from ViewModel to Projection
- transient `unknown`, `available`, and `unavailable` library availability
- availability-driven filtering and empty states

This ADR references but does not own:

- SQLite schema, filesystem facts, scan reconciliation, and package traversal:
  ADR 0002
- normalized path identity and unsandboxed access: ADR 0003
- permanent single-window UI ownership: ADR 0004
- AppKit grid rendering: ADR 0006
- ordered asset-ID reuse: ADR 0007

Metadata, thumbnails, manual scans, FSEvents, sandboxing, bookmarks, durable scan
IDs, and media-container import are outside this decision.

## Decision

### Store Truth And Change Signals

`CatalogStore` emits cheap change notifications. A notification says that inputs
changed; it does not carry a UI-ready catalog. `currentSnapshot()` builds an
immutable, keyed, point-in-time `CatalogSnapshot` only when Projection needs one.

This keeps snapshot construction and UI cadence out of Store mutation paths.
SQLite and the in-memory dictionaries remain Store-owned truth.

### Projection-Owned Publication

`CatalogProjection` owns one 10 Hz dirty loop. Store changes and sidebar intents
mark the same loop dirty. On a tick with pending work, Projection asks Store for
a snapshot, derives one `CatalogWindowState`, and yields it.

Only one derivation may be in flight. Actor reentrancy allows new input to mark
the actor dirty while awaited Store or diagnostic work is running. The completed
state may still be yielded, but dirty remains set and the next tick derives the
newest inputs. No second projection starts concurrently.

### Explicit Selection Intents

`CatalogWindowViewModel.selectSidebar(_:)` is the sole UI intent for changing
sidebar scope. The ViewModel owns one `AsyncStream<SidebarSelection>` using
`.bufferingNewest(1)` and one long-lived forwarding task. Rapid user input cannot
create an unbounded task backlog; only the newest pending intent is retained.

Projection may normalize a selected library that no longer exists to
`.allMedia`. After deriving state, Projection also adopts that resolved fallback
as its retained selection when the input used for the build is still current. If
a newer explicit selection arrived during an await, the newer input wins and is
left untouched for the next dirty tick. Applying the resolved selection updates
the ViewModel property directly and does not emit another user intent, so
normalization cannot feed back into the stream or silently resurrect a removed
selection if the same path is later added again.

### Availability

`LibraryAvailability` is transient and has three states:

- `.unknown`: the root has not yet been checked during this process
- `.available`: the latest pre-scan reachability check succeeded, or a newly
  added root was validated successfully
- `.unavailable`: the latest reachability check failed

Database-loaded roots begin unknown. Availability is never persisted to SQLite.
The existing pre-scan check transitions unknown to available or unavailable. A
scan failure rechecks the root so disappearance during traversal can be modeled
as unavailable.

Unknown and unavailable roots retain all catalog rows but contribute no assets
to All Media or selected-library grids. Unknown is rendered as `Checking`,
`Checking Library`, or `Checking Libraries`; unavailable is rendered as
`Library Unavailable` or `No Available Media` where applicable. A later scan
opportunity can mark the root available and reconcile normally.

## Alternatives Considered

### Store Publishes Full Snapshots

Pros:

- direct mutation-to-snapshot observation
- simple Store-only tests

Cons:

- Store owns a UI-facing cadence without owning UI derivation
- sidebar changes require a second path
- Projection scheduling and stale-result handling move toward MainActor code

Failure mode: Store and ViewModel grow competing publication schedulers.

### Store Publishes UI-Ready State

Pros:

- one actor performs mutation and publication

Cons:

- persistence and scanning become coupled to presentation and sidebar state
- Store becomes a general app model

Failure mode: UI rules accumulate inside catalog truth ownership.

### ViewModel Starts A Task Per Selection Change

Pros:

- little explicit stream machinery

Cons:

- rapid input creates unordered unstructured tasks
- cancellation and stale completion require additional MainActor bookkeeping

Failure mode: an older selection arrives after a newer one or task count grows
with interaction rate.

### Optimistically Mark Loaded Roots Available

Pros:

- cached media appears immediately

Cons:

- fabricates reachability before the filesystem check
- can briefly expose stale rows for an ejected root

Failure mode: the UI states a domain fact that is not known.

## Consequences

- Store owns truth; Projection owns derived publication; ViewModel owns UI state
  and explicit intents.
- Sorting, filtering, and scope derivation remain off MainActor.
- The ViewModel's owned stream and tasks have one cancellation point.
- Projection's retained selection agrees with the fallback state it publishes,
  while newer user input remains authoritative.
- Startup truthfully represents unchecked roots without blocking database load.
- Cached rows survive removable-disk and network availability changes.
- Projection tests require controlled clocks to verify 10 Hz coalescing.

## Living Documentation Impact

Specs 0006, 0007, 0009, 0010, and 0011, requirements FND-023, FND-028,
FND-034, FND-039, and FND-040, and comments at the Store/Projection/ViewModel
boundaries must describe explicit selection delivery and unknown availability.
Retired generation guards, optimistic availability claims, and ViewModel
selection `didSet` orchestration must not remain in current docs or comments.

## Verification

- Store tests cover unknown load state and available/unavailable transitions.
- Projection tests cover mixed availability filtering and checking empty states.
- ViewModel tests cover rapid intents, resolved-selection application without
  feedback, and owned-task cancellation.
- Source hygiene rejects retired selection guards and implicit `didSet`
  forwarding.
- `script/verify.sh` supplies the full local gate.
