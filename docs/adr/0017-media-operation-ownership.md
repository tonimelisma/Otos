# ADR 0017: Media Operation Ownership

## Status

Accepted. Implemented in `MediaOperationCoordinator` and the durable import and
reorganization journals owned by `CatalogStore`.

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

### Presentation ownership

`MediaOperationCoordinator` is also the sole owner of every fact the import bar
renders (`MediaOperationSourcePresentation`, `docs/design/import-bar.md`), not only
of execution itself: the typed failure reason (`MediaOperationFailureReason`,
replacing a raw `String` the view used to print verbatim), the destination display
name, the executing batch's ID (for the batch row's sidebar indicator), and the
settled attachment's copied count / clean flag / incomplete-item identities.
`ImportBarPresentation.map` is a pure function of that presentation; it owns no facts
of its own.

A presentation lives exactly as long as its `SourceSession` (held by `ImportSessionMachine`), which does not outlive
its source. The bar is drawn only on the card's own sidebar row (`import-bar.md`
"Where the user is standing"), so once the card is gone there is no surface for its
outcome: the coordinator logs it (`op=import.outcome phase=settled`) and discards it.
If execution was still active, its actual task moves through `drainingExecutions`;
the eventual result settles the old batch in the journal and the log without mutating
a replacement session at the same path.

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

### Keep a detached outcome to draw on the batch row

The coordinator could snapshot an unresolved outcome under its batch ID when the card
goes, so the batch row could keep drawing the bar. Rejected (2026-10-01): a batch row
shows that batch and nothing else. The snapshot would be a second, batch-keyed
presentation lifetime beside the session's, and its only consumer would be a bar the
user asked not to see there; the batch row's grid already shows what landed.

## Consequences

- Catalog and journal settlement remain one durable transaction.
- Filesystem effects have one operation-specific owner.
- Recovery decisions live beside normal execution decisions.
- Store retains only the cross-subsystem lease that protects its own scan state.
- Operation APIs describe state transitions rather than exposing journal-table CRUD.
- The bar's mapper (`ImportBarPresentation.map`) needs no store, coordinator, or
  ViewModel reference; every fact it draws from is already on the presentation it
  is handed.
- A card pulled mid-execution settles its old batch through the owned execution
  task and is logged; the live replacement attachment, if any, remains independent.

Import workers hash their completed primary staging file before publication. The
optional canonical digest is a field on `ActiveFileOperation`, is persisted before
the ready-to-publish phase, and is settled with the destination row by Store. This
adds no operation owner or queue. The planner uses only live destination occupancy,
size, and expected mtime; neither the digest nor import provenance affects a
disposition.
