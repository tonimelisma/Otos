---
paths:
  - "OtosKit/Stores/**"
  - "OtosTests/**Migration*"
  - "OtosTests/**Persistence*"
---

# Catalog persistence and schema migrations

- Persistence has one owner, `CatalogStore`, with an explicit schema version. It refuses
  a future or unsupported schema without erasing it (ENR-004).
- A schema migration runs at launch, before the window can show the catalog, on a 2.5 GB
  file (ADR 0002, "Schema Migrations At Launch"). It costs only what its outcome needs:
  - Rebuild only an index whose definition changes.
  - Write rows before building the indexes that hold them.
  - Keep `foreignKeyChecks: .immediate`. A table rebuild registers `.deferred` and says
    why.
- A migration PR states the migration's cost, in milliseconds and WAL bytes, measured on a
  generated catalog of the reference library's shape (`docs/research/2026-11-15-catalog-open-cost.md`).
- Never change an applied migration in a way that changes its outcome.
- A release cannot be rolled back past a migration: Sparkle does not downgrade, and older
  code cannot read a newer schema. A bad migration is fixed forward.
