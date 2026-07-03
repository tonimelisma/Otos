# ADR 0005: Catalog Publication, Selection Delivery, And Availability

- Status: Accepted
- Date: 2026-06-15
- Last updated: 2026-06-22
- Specs: `docs/specs/0009-catalog-publication-and-availability.md`,
  `docs/specs/0012-catalog-state-robustness.md`,
  `docs/specs/0013-catalog-lifecycle-race-safety.md`,
  `docs/specs/0014-catalog-task-and-mutation-ownership.md`

## Context

Catalog mutation, UI derivation, and MainActor assignment have different owners.
`CatalogStore` owns SQLite, root runtime catalog state, Store-owned queries, and scans. `CatalogProjection`
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
- Projection-owned coalesced `CatalogWindowState` publication
- one-in-flight publication and dirty-during-await behavior
- explicit sidebar-selection delivery from ViewModel to Projection
- transient `unknown`, `available`, and `unavailable` library availability
- availability-driven filtering and empty states

This ADR references but does not own:

- SQLite schema, filesystem facts, scan reconciliation, and package traversal:
  ADR 0002
- normalized path identity and unsandboxed access: ADR 0003
- permanent single-window UI ownership: ADR 0004
- ViewModel state-consumer lifetime and lossless serial add/remove delivery: ADR
  0004
- AppKit grid rendering: ADR 0006
- precomputed file-name sort keys: ADR 0007
- descriptor query ownership, generated best values, and current two-tier
  publication cadence: ADR 0011

Metadata, thumbnails, manual scans, sandboxing, bookmarks, durable scan IDs, and
media-container import are outside this decision. Coarse running-app FSEvents→rescan
policy is owned by ADR 0002 and spec 0023.

## Decision

### Store Truth And Change Signals

`CatalogStore` emits cheap typed change notifications, never a UI-ready catalog.
Ordinary events only invalidate Projection. A successful root removal also
carries its typed path through the lossless event stream. That transient fact is
necessary because remove and same-path add can complete inside one publication
interval, leaving a final queried state whose path membership looks unchanged.
ADR 0010 supersedes the old raw snapshot read: Projection now asks Store for
current library rows and ordered asset IDs, and visible grid cells fault detail by
ID through Store queries.

This keeps UI cadence out of Store mutation paths. SQLite and Store-owned root
runtime state remain catalog truth.

### Projection-Owned Publication

`CatalogProjection` owns one coalesced dirty loop. Store changes mark the
background loop dirty; direct sidebar, sort, and filter intents also mark dirty
and schedule an immediate publication attempt. On a publication with pending
work, Projection asks Store for current library rows plus descriptor-ordered
asset IDs, derives one `CatalogWindowState`, and yields it.

When Projection receives `.libraryRemoved(path)` for its selected root, it
immediately retains `.allMedia` as selection input and marks itself dirty. A
same-path replacement therefore remains unselected even when no root-absent
state was published. The path is transient context, not generated identity;
SQLite row IDs remain Store-private.

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

The ViewModel consumes Projection state through one owned task. That consumer
captures the ViewModel weakly while awaiting another state, so cancellation and
stream termination remain reachable when external ViewModel ownership ends.
Add/remove commands use a separate lossless serial stream owned by ADR 0004;
they do not share selection's newest-value buffering.

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
- The ViewModel's owned selection stream and Projection consumer have one
  cancellation point without the consumer retaining its owner indefinitely.
- Projection's retained selection agrees with the fallback state it publishes,
  while newer user input remains authoritative.
- Startup truthfully represents unchecked roots without blocking database load.
- Cached rows survive removable-disk and network availability changes.
- Projection tests require controlled clocks to verify background coalescing and
  immediate user-intent publication.

## Living Documentation Impact

Specs 0006, 0007, 0009, 0010, and 0011, requirements FND-023, FND-028,
FND-034, FND-039, and FND-040, and comments at the Store/Projection/ViewModel
boundaries must describe explicit selection delivery and unknown availability.
Retired selection-generation guards, optimistic availability claims, and ViewModel
selection `didSet` orchestration must not remain in current docs or comments.

## Verification

- Store tests cover unknown load state and available/unavailable transitions.
- Projection tests cover mixed availability filtering and checking empty states.
- ViewModel tests cover rapid selection intents, resolved-selection application
  without feedback, weak state-consumer lifetime, and owned-task cancellation.
- Source hygiene rejects retired selection guards and implicit `didSet`
  forwarding.
- `script/verify.sh` supplies the full local gate.
