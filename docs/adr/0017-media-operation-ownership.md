# ADR 0017: Media Operation Ownership

## Context

Import and library reorganization both cross a failure-sensitive boundary between
filesystem mutation and catalog persistence. Their executors need durable journals,
while catalog settlement must remain atomic with journal clearance. The initial
implementation placed journal transactions, scan exclusion, filesystem cleanup,
and recovery interpretation together on `CatalogStore`, obscuring which owner was
responsible for the filesystem lifecycle.

## Decision

`CatalogStore` remains the sole owner of SQLite catalog truth. It exposes semantic
durable transitions for import and reorganization rather than table-oriented CRUD,
and owns every transaction that must atomically update catalog rows and journal
state. It also owns the typed reorganization lease because that lease directly
arbitrates Store-owned scans, filesystem-event reconciliation, and planning
revisions.

`MediaImportExecutor` owns import filesystem execution and recovery: staging,
orphan-staging enumeration and deletion, byte transfer, exclusive publication, and
optional source deletion. `ReorganizationExecutor` owns directory prerequisites,
filesystem observations, and no-overwrite moves. `LibraryReorganizationRunner`
owns the reorganization use-case sequence and interprets durable journal phases at
startup before Store starts saved-library scans.

The import and reorganization journal files remain non-owning SQL/mapping helpers.
They execute only inside Store-owned transactions and perform no filesystem work,
recovery sequencing, notification, or actor coordination.

### Presentation ownership (plan 0092)

`MediaOperationCoordinator` is also the sole owner of every fact the import bar
renders (`MediaOperationSourcePresentation`, `docs/design/import-bar.md`), not only
of execution itself: the typed failure reason (`MediaOperationFailureReason`,
replacing a raw `String` the view used to print verbatim), the destination display
name, the batch ID as state from execution start onward, whether the card still
exists, and the settled attachment's copied count / clean flag / incomplete-item
identities. `ImportBarPresentation.map` is a pure function of that presentation; it
owns no facts of its own.

A source's `SourceSession` does not outlive its source, so a batch selected from
the sidebar's Imports row — which does outlive the source, by design — needs a
presentation from somewhere once the session is gone. The coordinator owns that
too: at detach, a settled (non-executing) session with a completed attachment is
snapshotted under its batch ID into a small side table
(`detachedBatchPresentations`) that `sortedPresentations()` folds in alongside live
sessions. This keeps the invariant intact — one owner publishes every presentation
fact — rather than letting the ViewModel reconstruct a "the card is gone" fact from
the *absence* of a session, which is exactly the kind of re-derivation `import-bar.md`
identifies as the failure mode this presentation exists to avoid.

One fact is deliberately *not* coordinator-owned: whether a Cancel is currently in
flight for a source (the bar's transient "Stopping…" state). Nothing about it
outlives the view session, no other consumer needs it, and the coordinator has no
natural moment to clear it that is not already the view's own moment (the next
presentation frame that leaves `.executing`). It lives on `CatalogWindowViewModel`
as ordinary MainActor UI state, the same tier as `sessionPreferencesBySource`.

## Rejected Alternatives

### Separate media-operation persistence actor

A second persistence actor would split ownership of transactions that must update
both operation journals and catalog rows atomically. Restoring atomicity would need
a lower transaction owner or would let the operation actor mutate catalog truth,
creating more coordination without an independent operation-store requirement.

### Keep filesystem recovery on `CatalogStore`

Directory enumeration, staging deletion, directory creation, and journal-phase
interpretation do not require catalog ownership. Keeping them on Store makes it an
operation orchestrator and mixes filesystem effects into the catalog authority.

### Protocol abstractions around Store transitions

There is one concrete catalog owner and no second production implementation.
Protocols would add an abstraction without changing ownership or reducing current
complexity.

### Let the view infer "card gone" from a missing presentation

The ViewModel already knows the removable-source list, so it could treat "no
presentation for this batch's source" as the card-gone signal instead of the
coordinator publishing one. Rejected: that reintroduces the re-derivation
`import-bar.md`'s presentation table exists to prevent, and it cannot distinguish
"the card was ejected after a clean import" from "this batch never had a session in
this process at all" (e.g. after a relaunch) — a distinction the coordinator can
make because it is the one that removed the session and knows why.

## Consequences

- Catalog and journal settlement remain one durable transaction.
- Filesystem effects have one operation-specific owner.
- Recovery decisions live beside normal execution decisions.
- Store retains only the cross-subsystem lease that protects its own scan state.
- Operation APIs describe state transitions rather than exposing journal-table CRUD.
- The bar's mapper (`ImportBarPresentation.map`) needs no store, coordinator, or
  ViewModel reference; every fact it draws from is already on the presentation it
  is handed, including after the source session that produced it is gone.
- A card pulled mid-execution (rather than ejected after settling) does not yet
  produce a named Failed cause on the batch row — the cancel-vs-detach race is
  unresolved follow-up, not a claim this ADR makes.

Import workers hash their completed primary staging file before publication. The
optional canonical digest is a field on `ActiveFileOperation`, is persisted before
the ready-to-publish phase, and is settled with the destination row by Store. This
adds no operation owner or queue. The planner uses only live destination occupancy,
size, and expected mtime; neither the digest nor import provenance affects a
disposition.
