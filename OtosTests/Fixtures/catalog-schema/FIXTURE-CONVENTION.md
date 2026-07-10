# Catalog schema fixtures

Stage A of plan 0055 starts the checked-in schema-fixture convention. Every
future schema change should add a fixture that the migration tests can open.

Current approach in `CatalogStoreSchemaMigrationTests`:

- Build a synthetic pre-`v6` database by applying the production migrator, then
  dropping the Stage A columns and removing the `v6_import_history_and_capture_wall`
  migration identifier from `grdb_migrations`.
- Seed enriched metadata JSON and assert additive migration + capture-wall
  backfill.
- Seed a future migration identifier and assert refusal without erase.

When a later stage lands a new migration, add a corresponding fixture helper (or
a SQL dump under this directory) and keep the prior fixture green.
