# ADR 0005: Catalog Publication And Library Availability

- Status: Accepted
- Date: 2026-06-15
- Spec: `docs/specs/0009-catalog-publication-and-availability.md`

## Context

The catalog implementation originally let `CatalogStore` publish full
`CatalogSnapshot` values, then the MainActor window model scheduled projection
work and rejected stale completions with a generation counter. That worked, but
it split one conceptual publication problem across two owners:

- `CatalogStore` decided when raw snapshots were emitted.
- `CatalogWindowModel` decided when snapshots plus sidebar selection became UI
  state.
- `CatalogProjection` did the expensive derived read-model work, but not the
  publication cadence.

The app also needed to represent transient library availability. If a removable
or network-backed root disappears, Otos should not delete previously cataloged
rows just because the filesystem is temporarily unreachable. Availability must
affect what the UI shows while preserving SQLite and in-memory catalog truth.

## Decision Area This ADR Owns

This ADR owns:

- Store change notifications versus Store-published UI snapshot streams.
- Projection-owned `CatalogWindowState` publication.
- The 10 Hz coalescing rule for catalog window state.
- The one-in-flight publication rule and dirty-during-run behavior.
- The `CatalogWindowViewModel.state` boundary.
- Transient library availability and its UI projection consequences.

## Related Decisions This ADR Does Not Own

This ADR references but does not own:

- SQLite schema, GRDB connection choice, filesystem facts, scan reconciliation,
  and package descendant scanning. Those belong to ADR 0002.
- Root identity, unsandboxed path access, and no sandbox/bookmark behavior. Those
  belong to ADR 0003.
- The permanent single-window UI ownership boundary. That belongs to ADR 0004.
- Metadata, thumbnails, manual scan controls, FSEvents, durable scan IDs, and
  media-container import. Those require separate specs or ADRs if ever
  implemented.

## Decision

Use Store-owned truth with Projection-owned UI-state publication:

- `CatalogStore` emits cheap change notifications. A notification means catalog
  inputs changed and a consumer may need to ask for a new raw snapshot.
- `CatalogStore.currentSnapshot()` builds a raw point-in-time `CatalogSnapshot`
  on demand. `CatalogSnapshot` is a value, not a UI publication stream.
- `CatalogProjection` owns a 10 Hz coalesced publication loop that emits
  `CatalogWindowState`.
- Store changes and sidebar-selection changes both mark projection dirty and go
  through the same publication loop.
- Only one `CatalogWindowState` publication may run at a time. If input changes
  while one publication is in flight, the completed result may be yielded, the
  dirty flag remains set, and the loop reruns on the next tick with the latest
  inputs.
- `CatalogWindowViewModel` consumes the `CatalogProjection` state stream, assigns
  `state` on the MainActor, owns sidebar selection, and forwards selection
  changes back to `CatalogProjection`.

Use transient library availability:

- `LibraryAvailability` is in-memory state only: `.available` or
  `.unavailable`.
- `CatalogLibraryState` keeps availability separate from scan activity.
- Availability is checked before a scan begins and after a scan failure by
  testing whether the root path is currently reachable.
- If the root is unavailable, Otos preserves SQLite and in-memory media rows,
  does not reconcile/delete missing rows for that root, marks the library
  unavailable, logs/diagnoses the condition, and continues.
- If a later scan opportunity finds the root available, Otos marks it available
  and scans normally.
- `CatalogProjection` hides unavailable libraries' media from All Media and
  selected-library scopes.
- Selecting an unavailable library shows `Library Unavailable`.
- All Media shows `No Available Media` when all cataloged media belongs to
  unavailable libraries.

## Alternatives Considered

### Alternative A: Store Publishes Full Snapshots

Keep `CatalogStore.snapshots()` as the main UI stream and let the ViewModel call
projection for each raw snapshot.

Pros:

- Direct continuation of the previous implementation.
- Store tests can observe exact snapshot values immediately.

Cons:

- Store owns a UI-facing cadence even though it does not own UI projection.
- The ViewModel needs its own stale-completion or cancellation policy for
  projection work.
- Sidebar-selection changes need a separate publication path from store changes.

Failure modes:

- Two similar schedulers grow: one in Store for snapshots and one near
  Projection for sorting/filtering.

### Alternative B: Store Publishes UI-Ready Window State

Move sorting, filtering, selection validation, availability hiding, and title
lookup into `CatalogStore`.

Pros:

- One actor owns both mutation and publication.
- No raw snapshot handoff is needed for UI.

Cons:

- Mixes persistence/scanning with presentation state.
- Makes Store depend on sidebar selection.
- Store tests become presentation tests.

Failure modes:

- `CatalogStore` becomes a general application model and accumulates UI-specific
  rules.

### Alternative C: ViewModel Owns Projection Scheduling

Keep Store notifications cheap but let `CatalogWindowViewModel` pull snapshots,
schedule projections, cancel tasks, and reject stale results.

Pros:

- Projection can stay a pure derivation service.
- The ViewModel has direct access to sidebar selection and can decide when to
  update.

Cons:

- MainActor code becomes the scheduler for work that should remain away from UI
  ownership.
- The ViewModel must keep generation counters or similar stale-result machinery.

Failure modes:

- Projection orchestration drifts into MainActor-adjacent code and becomes
  harder to reason about.

### Selected: Projection-Owned Publication Loop

Let `CatalogStore` emit cheap dirty signals and let `CatalogProjection` own the
coalesced UI-state stream.

Pros:

- One owner handles all inputs that affect catalog window state.
- Sorting/filtering and publication cadence stay off the MainActor.
- The ViewModel becomes a simple state-stream consumer.
- One dirty/in-flight rule covers scan updates, add/remove, availability changes,
  and sidebar selection.

Cons:

- `CatalogProjection` has a broader role than pure synchronous projection.
- Tests need to cover cadence, coalescing, and dirty-during-run behavior.

Failure modes:

- If the publication loop forgets to keep the dirty flag after in-flight input,
  the UI can temporarily miss a later state.
- If the loop starts multiple in-flight projections, large catalogs can waste
  CPU and increase latency.

## Consequences

Positive:

- Store ownership is clearer: it owns truth and raw snapshots, not UI stream
  cadence.
- Projection ownership is clearer: it owns every derived catalog window state,
  including publication timing.
- MainActor work is smaller: the ViewModel assigns already-derived state.
- Availability does not endanger catalog rows when disks or network roots
  disappear.

Negative:

- Projection tests need async timing controls.
- `CatalogProjection` now owns task lifetimes for publication subscribers.
- A briefly stale state may be yielded if input changes during an in-flight
  projection; the next tick corrects it with the latest inputs.

## Performance And Simplicity

The 10 Hz loop is not a scale optimization; it is the simplest rule that keeps
scan batches, add/remove changes, availability changes, and sidebar filtering on
one cadence. It avoids both per-file UI churn and duplicated schedulers. The
one-in-flight rule prevents overlapping publication work without introducing a
general worker queue.

## Verification

- Store tests prove change notifications are cheap dirty signals and
  `currentSnapshot()` returns raw catalog state.
- Store tests prove unavailable roots preserve rows and do not reconcile/delete.
- Projection tests prove 10 Hz coalescing, one-in-flight publication,
  dirty-during-run rerun behavior, availability hiding, and empty states.
- ViewModel tests prove `CatalogWindowViewModel` assigns `state` from
  Projection's stream and routes sidebar selection into Projection.
- Source hygiene rejects Store `snapshots()`/`publishSnapshot()` UI stream paths,
  `CatalogWindowModel`, `CatalogWindowProjection`, and generation-based
  projection rejection.
- Local verification runs through `script/verify.sh`.
