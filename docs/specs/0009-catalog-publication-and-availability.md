# Spec 0009: Catalog Publication And Availability

## Classification

- Work type: Architecture refactor and reliability
- Current requirement IDs: FND-019, FND-023, FND-024, FND-028, FND-029,
  FND-034, FND-037, FND-038, FND-039, FND-040
- ADRs: ADR 0005

## Problem And Goal

Catalog truth changes and sidebar selection both affect one window state. They
need one off-MainActor publication cadence, not separate Store and ViewModel
schedulers. Root reachability also needs explicit transient modeling so an
ejected or disconnected library never causes catalog-row deletion.

## Scope

In scope:

- cheap Store change notifications
- on-demand keyed CatalogSnapshot values
- Projection-owned 10 Hz dirty publication loop
- one projection publication in flight
- explicit sidebar intent delivery
- transient unknown, available, and unavailable library states
- preservation and hiding rules for unchecked/unreachable roots

Out of scope:

- periodic availability probing, filesystem watching, or manual scanning
- persistence of availability
- schema changes
- metadata, thumbnails, sandboxing, bookmarks, or durable scan IDs

## Requirements

| Label | Type | Current requirement |
| --- | --- | --- |
| PUB-001 | Architecture | Store emits dirty signals, not UI snapshots. |
| PUB-002 | Architecture | Projection asks Store for keyed point-in-time snapshots. |
| PUB-003 | Non-functional | Projection publishes at most once per 100 ms tick while dirty and never overlaps derivation. |
| PUB-004 | Architecture | Store changes and explicit sidebar intents use the same dirty loop. |
| AVA-001 | Architecture | Availability is transient and never persisted. |
| AVA-002 | Functional | Database-loaded roots begin unknown; new validated roots begin available. |
| AVA-003 | Regression | Unavailable or failed roots preserve catalog rows and skip reconciliation deletion. |
| AVA-004 | Functional | Unknown and unavailable roots contribute no media to visible scopes. |
| AVA-005 | Functional | Unknown UI uses Checking labels; unavailable UI uses unavailable/no-available-media labels. |

## Alternatives

### Store Publishes Full Snapshots

Pros:

- mutation and snapshot emission are adjacent

Cons:

- Store owns UI timing without owning derived window state
- selection needs a second scheduler

Failure mode: duplicate Store and ViewModel publication machinery.

### Store Publishes UI-Ready State

Pros:

- one catalog actor

Cons:

- sidebar scope, titles, and empty states contaminate persistence/scanning truth

Failure mode: Store becomes a general application model.

### Projection Publishes Window State

Pros:

- one owner for every input that changes derived window state
- sorting/filtering and cadence remain outside MainActor
- ViewModel only assigns final state and owns explicit intents

Cons:

- Projection owns task and subscriber lifetimes in addition to pure derivation

Failure mode: dirty input received during an await is lost unless the flag is
preserved.

Selected: Projection-owned publication.

## Data Flow

1. Store mutates SQLite/in-memory truth and yields a cheap change notification.
2. Projection's Store listener marks the actor dirty.
3. Explicit selection intents arrive through the ViewModel-owned newest-buffered
   stream and also mark Projection dirty.
4. On the next 100 ms tick, Projection requests currentSnapshot().
5. Projection validates/rebuilds order, filters availability and scope, selects
   title/empty state, and emits CatalogWindowState.
6. ViewModel assigns the final value on MainActor.
7. If input changed during an awaited step, dirty remains true and the next tick
   derives the newest inputs.
8. If the selected library no longer exists, Projection retains the resolved All
   Media fallback unless a newer sidebar intent arrived during that build.

Only one derivation runs at a time. Equality suppression prevents assignment
when the resulting window state is unchanged.

## Availability Flow

1. Database load restores durable roots/assets and marks roots unknown.
2. Projection hides unknown assets and renders Checking state.
3. Immediately before scanning a root, Store checks reachability.
4. Reachable transitions to available and scans.
5. Unreachable transitions to unavailable, preserves rows, and continues.
6. Scan failure rechecks reachability before deciding whether the library
   disappeared during traversal.
7. A later scan opportunity repeats the same check and can restore available.

Unknown and unavailable are not error history. They are current process-local
reachability knowledge.

## Ownership And Cancellation

- Store owns database, memory, scans, availability, and change subscriptions.
- Projection owns Store-listener, 10 Hz loop, order cache, state subscriptions,
  selection input, and dirty/in-flight state.
- ViewModel owns explicit selection stream/task, state-consumer task, startup
  task, and MainActor assignment.
- Removing a root remains a Store intent that cancels its scan and deletes only
  Otos catalog state.

## Instrumentation

- Store and scan boundaries, failures, and availability transitions use bounded
  JSONL plus Logger/signposts.
- Projection records one coarse summary per derived publication: snapshot,
  ordering cache, membership change, sort duration, counts, scope, and timing.
- ViewModel assignment uses Logger/signposts, not per-update JSONL.
- Actual active-app run-loop stalls alone write durable UI correlation.

## Comments

Store, Projection, ViewModel, diagnostics, and model files explain actor
reentrancy, dirty-during-await preservation, one-in-flight publication,
selection-stream ownership, and availability row preservation. Comments describe
current mechanics only.

## Acceptance And Tests

- Store notifications carry no full UI snapshot.
- currentSnapshot() returns keyed current truth.
- publication coalesces Store/selection changes at 10 Hz.
- dirty-during-await yields then reruns without overlap.
- database-loaded roots remain unknown when scanning is disabled.
- pre-scan checks resolve unknown.
- unavailable roots preserve rows and do not reconcile.
- mixed unknown/available scopes hide unchecked media.
- checking and unavailable empty states are correct.
- rapid selection changes resolve to the newest intent without feedback.
- a removed selected path remains All Media if that path is later re-added
  without a new explicit selection intent.
- script/verify.sh passes.

## Code-Smell Review

- MainActor scheduling is avoided by Projection-owned cadence.
- Snapshot values and publication streams are named distinctly.
- Availability does not duplicate durable root identity.
- One explicit selection stream avoids property-observer side effects and
  unstructured task accumulation.
