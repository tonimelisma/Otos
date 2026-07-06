# Spec 0029: SQLite Retirement Completion

## Change Type

Refactor, bug fix, and process documentation.

## Problem Statement And User Goal

The SQLite-backed catalog redesign removed the old resident in-memory catalog
architecture, but a blank-slate review still found residue and lifecycle gaps:
production query-plan tests copied SQL instead of exercising Store-owned query
builders, projection test helpers still modeled fixture data as old snapshots and
value maps, `FileMaterialization` comments still claimed the byte-read gate was not
wired, and thumbnail files could be produced before the Store proved the
enrichment result still matched the current catalog row.

The user goal is not merely "the plan was implemented." The goal is a good-quality
codebase whose current architecture is coherent from source, tests, comments, and
docs, with old architecture names removed and derived app-owned overlay following
the same lifecycle as catalog truth.

## In Scope

- Make thumbnail generation stage files until `CatalogStore` validates the
  enrichment result against current SQLite facts.
- Purge staged thumbnails for stale/deleted enrichment results and purge app-owned
  thumbnails when a pre-user clean-schema reset discards their catalog references.
- Replace copied production SQL in query-plan tests with production query builders.
- Remove executable test helpers that model projection fixtures as old
  snapshot/value-map flows.
- Remove unused resident-value helper methods from `MediaAsset`.
- Update stale file guides, requirements, ADRs, onboarding, source hygiene, and the
  review criteria affected by this cleanup.

## Out Of Scope

- Changing catalog product identity away from filesystem path.
- Adding user-visible migration UI or preserving pre-release catalog state.
- Adding new metadata, sorting, filtering, editing, import, export, or preview
  features.
- Optimizing beyond correctness and architecture cleanup; any performance evidence
  here verifies that existing hot-path behavior remains observable.

## Current Repo State Discovered Through Inspection

- `CatalogProjection` now uses Store-owned ordered-ID queries for structural
  changes, reuses cached ordered IDs for `.assetsDetailChanged`, and asks Store for
  a separate cataloged count when no visible IDs remain. The prior live empty-state
  and detail-only full-order-query findings are already addressed.
- `CatalogStore.applyEnrichmentBatch` validates source facts in SQLite before
  stamping enrichment columns, but production thumbnail generation already writes
  the deterministic final thumbnail file before that validation.
- `CatalogStore.migrator.eraseDatabaseOnSchemaChange = true` discards old SQLite
  rows, but the code does not detect that clean reset and purge the app-owned
  thumbnail directory whose references were discarded.
- `CatalogStoreQueryPlanTests` copies the production order and enrichment SQL into
  test constants, so query plans can stay green while shipped query builders drift.
- `CatalogQueryTestSupport`, `CatalogProjectionTests`, and
  `CatalogProjectionOrderingTests` still use `ProjectionTestState`, `makeSnapshot`,
  and `assetsByID` fixture maps even though the production snapshot/value-map path
  is retired.
- `MediaAsset.mergingFacts` and `MediaAsset.applyingEnrichment` are unused remnants
  of the old in-memory merge model.
- `FileMaterialization.swift` still says its detector and materialization helpers
  are not wired up, while `MediaEnricher` and `EnrichmentCoordinator` now use them.

## Captured Requirements For User Verification

| ID | Type | Requirement | Acceptance Example |
| --- | --- | --- | --- |
| SQF-001 | Architecture | Production SQL used by Store query-plan tests shall come from the same Store-owned query builders the app executes. | Given an order or enrichment query changes, query-plan tests inspect the changed production SQL without copied constants. |
| SQF-002 | Architecture | Projection tests shall not model input as retired catalog snapshots or full asset value maps. | Given test support is inspected, projection fixtures carry libraries plus ordered IDs, not `ProjectionTestState` or `assetsByID`. |
| SQF-003 | Architecture | A generated thumbnail shall not replace the visible deterministic thumbnail file until Store validates the enrichment result against current SQLite facts. | Given a stale enrichment completes after a file changed, the staged file is discarded, the old final thumbnail remains intact, and SQLite is not stamped current; given a later promotion fails in a batch, earlier accepted rows remain committed and the failed item remains retryable. |
| SQF-004 | Architecture | A clean pre-user catalog schema reset shall purge app-owned derived thumbnails whose SQLite references were discarded, without touching originals. | Given an incompatible old local catalog and a thumbnail file under the app-owned thumbnail directory, starting the Store creates the current schema, removes the stale thumbnail, and leaves the media root alone. |
| SQF-005 | Process | Review criteria shall permanently flag pre-validation thumbnail publication, copied production SQL in tests, stale architecture helper names, and reset/overlay lifecycle mismatches. | Given a future review, `docs/process/code-review.md` names these as merge-gate concerns. |
| SQF-006 | Documentation | File guides and living docs shall describe current wiring, not the retired architecture or old increment history. | Given current docs/comments are searched, `FileMaterialization` no longer claims it is unused, and executable helpers no longer carry retired snapshot names. |

These are current implementation and process requirements for this increment. No
future ideas are being added to `docs/requirements.md`.

## Related Current Requirements

- FND-013 through FND-015: blank-slate correctness, simplicity, and
  measure-before-optimizing.
- FND-019, FND-031, FND-043, FND-044: Store-owned catalog truth, identity grid, and
  detail-only refresh behavior.
- FND-060 and ENR-001 through ENR-011: materialization, enrichment, thumbnail, and
  metadata ownership.
- APP-001: current docs and user-facing summaries claim only proven behavior.

## Architectural Alternatives

### Alternative A: Keep Final Thumbnail Writes And Delete On Rejection

Production enrichment would continue writing the deterministic final thumbnail
path before Store validation; `applyEnrichmentBatch` would delete the path when a
result is stale or deleted.

Pros:

- Smallest change.
- Prevents a rejected result from leaving a newly generated stale file behind.

Cons:

- A stale result can overwrite a previously valid final thumbnail before Store
  rejects it.
- Deleting the overwritten final path leaves SQLite temporarily pointing at a
  missing thumbnail.

Failure modes:

- Visible tiles blink to placeholders even when the prior best-known thumbnail
  could have remained intact.
- The code still publishes derived overlay before catalog truth validates it.

Rejected: it patches the symptom while preserving the wrong ownership order.

### Alternative B: Stage Thumbnails, Validate In Store, Then Promote

`MediaEnricher` writes a staged thumbnail file under the app-owned thumbnail
directory and returns a typed staged thumbnail with the final relative name.
`CatalogStore` validates the source signature and row ownership, promotes staged
files only for results it will stamp, and discards staged files for stale/deleted
results.

Pros:

- Keeps prior final thumbnails intact until replacement is proven current.
- Makes Store the owner of when a derived product becomes catalog-visible.
- Preserves the simple file-backed thumbnail architecture and current SQLite row
  shape.

Cons:

- Adds a small staged-file lifecycle to `ThumbnailStore`.
- File promotion and SQLite stamping cannot be a single cross-filesystem atomic
  transaction, so the bounded residual risk is an orphaned app-owned thumbnail if
  a process dies or storage fails at the narrow promotion/commit boundary. The
  product-safe reset and purge paths remove app-owned orphan risk without touching
  originals.

Failure modes:

- A crash between promotion and SQLite commit could leave an orphaned final
  thumbnail. The next reset/purge paths and deterministic naming keep this bounded,
  and the old architecture already accepted app-owned derived products as
  rebuildable overlay.

Selected: this is the smallest correct ownership change.

### Alternative C: Store Thumbnail Bytes In SQLite With Enrichment Rows

Replace file-backed thumbnails with SQLite BLOBs so the row update and thumbnail
publication are one transaction.

Pros:

- One transactional store.
- No separate staged-file lifecycle.

Cons:

- Reopens the rejected ADR 0009 design: image bytes can bloat the database and
  accidentally ride hot query or publication paths.
- Larger migration and rendering change, unrelated to the current defect.

Failure modes:

- The grid path regresses into byte-heavy catalog reads.

Rejected: it solves one lifecycle issue by violating the core grid/query
architecture.

### Alternative D: Add Durable Overlay Version IDs

Persist generated overlay version IDs so the Store can compare result tokens
instead of source facts and filenames.

Pros:

- More explicit overlay versioning.

Cons:

- Adds durable identity that is not a product fact and conflicts with filesystem
  path identity.
- More schema and scheduling complexity than the current source-signature model
  needs.

Failure modes:

- Token state becomes a second source of truth for freshness.

Rejected: unnecessary complexity and wrong identity model.

## Selected Approach

Use Alternative B. Keep thumbnails file-backed and deterministic, but split the
file write into staged creation and Store-owned promotion. Replace copied SQL with
Store-owned query builders. Replace snapshot/value-map test fixtures with
ordered-ID fixtures. Remove unused in-memory merge helpers and update docs/review
criteria to match the current architecture.

This is the simplest correct approach because it changes only the invalid
ownership points: publication of a derived file before Store validation, test SQL
drift, test helper mental models, and stale comments/docs.

## Interfaces, Ownership, Data Flow, And Persistence Effects

- `ThumbnailStore` owns staged JPEG creation, final promotion, staged discard, final
  delete, and app-owned thumbnail directory reset.
- `MediaEnricher` produces metadata plus a staged thumbnail descriptor; it does not
  publish final thumbnail files.
- `CatalogStore.applyEnrichmentBatch` remains the only owner that validates and
  stamps enrichment results. It promotes staged thumbnails only for rows that pass
  SQLite source-signature validation.
- `CatalogStorePersistence` exposes internal Store-owned query builders for the
  exact order and enrichment claim SQL used by production reads. Tests may inspect
  those builders through `@testable import`, but production callers still use Store
  owner APIs.
- Clean-schema reset remains destructive only for app-owned catalog/overlay in this
  pre-user app. Originals are untouched.

## Concurrency And Actor Ownership

- `MediaEnricher` continues to run off MainActor in coordinator worker tasks and
  gates byte reads through `FileMaterialization`.
- `CatalogStore` actor owns the apply decision. The synchronous thumbnail promote
  operation happens inside the Store-owned apply path after source validation and
  before stamping the row.
- Long-running coordinator behavior, worker counts, claim lease, and cancellation
  semantics are unchanged.
- Stale results are rejected by SQLite source-signature checks; staged files for
  rejected results are discarded after the apply attempt.

## Side Effects, Errors, Privacy, And Instrumentation

- Side effects are limited to app-owned Application Support catalog and thumbnail
  files.
- Originals and media folders are never written.
- Thumbnail stage/promote/reset paths use existing thumbnail logging and signposts
  with bounded relative names, never image bytes.
- On apply write failure, the Store records the existing enrichment batch error and
  discards staged products that were not accepted. App-owned final thumbnails remain
  rebuildable overlay governed by the normal purge/reset lifecycle.

## Test And Acceptance Criteria

- Add or update thumbnail tests proving staging leaves the final path absent until
  promotion and that promoted files are loadable JPEGs.
- Add a Store enrichment test proving stale completion discards staged thumbnail and
  keeps the old final thumbnail intact.
- Update schema-reset test proving incompatible catalog reset purges app-owned
  thumbnails while leaving originals untouched.
- Update query-plan tests to inspect production query builders and remove copied
  production SQL constants.
- Update projection test helpers to use ordered-ID fixtures, not snapshots/value
  maps.
- Add source hygiene for retired test helpers and copied production SQL.
- Run `script/verify.sh`.

## Instrumentation And Profiling Plan

This is correctness/architecture cleanup, not a jank fix. The changed paths keep
existing `OtosSignpost.thumbnails` and `OtosSignpost.persistence` coverage for
thumbnail writes and enrichment batch writes. Verification will report local
`script/verify.sh`; no new Instruments trace is required unless verification shows
a responsiveness regression.

## Code-Smell Review For Target Area

Observed:

- State duplication risk: final thumbnail files could change before Store accepted
  the corresponding catalog row.
- Test coupling: query-plan tests copied production SQL.
- Retired architecture language: projection helpers and comments retained snapshot
  and not-wired wording.
- Stale abstraction: unused in-memory merge helper methods remained on
  `MediaAsset`.

Planned handling: replace the ownership order, remove copied SQL/helper residue,
delete unused helpers, and update docs/comments.

## Stale-Document Audit Plan

Audit and update:

- `docs/requirements.md`
- `docs/adr/0009-enrichment-storage-and-staleness.md`
- `docs/adr/0010-store-owned-query-catalog-and-identity-grid.md`
- `docs/onboarding.md`
- `docs/process/code-review.md`
- `docs/specs/0022-metadata-and-thumbnail-enrichment.md`
- `docs/specs/0025-store-owned-query-catalog-and-identity-grid.md`
- file guides in `FileMaterialization.swift`, `MediaEnricher.swift`,
  `ThumbnailStore.swift`, `AssetMetadata.swift`, `CatalogModels.swift`,
  `CatalogStore.swift`, and `CatalogStorePersistence.swift`

The onboarding walkthrough is expected to change because thumbnail publication
ownership and reset lifecycle are part of the current reading map.
