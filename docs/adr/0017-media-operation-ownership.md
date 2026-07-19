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

## Consequences

- Catalog and journal settlement remain one durable transaction.
- Filesystem effects have one operation-specific owner.
- Recovery decisions live beside normal execution decisions.
- Store retains only the cross-subsystem lease that protects its own scan state.
- Operation APIs describe state transitions rather than exposing journal-table CRUD.

Import workers hash their completed primary staging file before publication. The
optional canonical digest is a field on `ActiveFileOperation`, is persisted before
the ready-to-publish phase, and is settled with the destination row by Store. This
adds no operation owner or queue. The planner uses only live destination occupancy,
size, and expected mtime; neither the digest nor import provenance affects a
disposition.
