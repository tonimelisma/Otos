# Plan 0062 — Separate content hashing from enrichment; never hash a removable source in place

## Status

Implemented, awaiting review/merge (2026-08-03). Stages 1–4 landed as code; the
global claim query resolves the plan's mixed-kind question by partitioning available
root IDs by hash requirement within each priority tier. Stage 5 (ADR 0018/0013,
requirements rows, architecture map) landed. One review finding beyond the plan: the
broad claim predicate must stay token-identical to the v12 migration's flattened
`WHERE` clause — SQLite's `INDEXED BY` implication check rejects re-parenthesized
equivalents with `no query solution` at prepare time, verified against SQLite 3.54.0.

## Purpose

Content hashing is fused into enrichment's definition of "enriched". Every asset on
every root is therefore read end to end before it counts as enriched — including files
on removable volumes, which are then read a second time when they are imported.

Hashing is the only part of enrichment that reads a whole file. `MediaMetadataReader`
reads ranges (`FileByteSource` seeks and calls `read(upToCount:)`); Quick Look reads a
portion. Removing the hash from the removable-source path removes the full read.

This plan separates hash production from metadata/thumbnail enrichment so that hashing
is gated on **byte locality** rather than applied uniformly, and so a removable volume
is never read in full merely to compute a digest.

## Evidence

Full field diagnosis, including the measurements below and the SQLite index
experiments in the research section: `docs/research/2026-08-01-removable-import-and-grid-field-diagnosis.md`.

Measured 2026-08-01, `/Volumes/CAMERA` — MS-DOS FAT32 over USB, 139 files, 521 MB:

| bytes | elapsed | throughput | owner |
|---|---|---|---|
| 52,199,424 | 112,442 ms | 0.46 MB/s | enrichment |
| 29,622,272 | 129,267 ms | 0.23 MB/s | enrichment |
| 24,969,216 | 96,409 ms | 0.26 MB/s | enrichment |
| 440,499 | 101,530 ms | 0.004 MB/s | enrichment |
| 1,477,858 | 4 ms | 369.46 MB/s | enrichment (local file, same session) |
| 624,627 | 22 ms | 28.39 MB/s | **import** (staged copy, local) |

`op=contentHash` records no path, so byte sizes were attributed by matching
`media_asset.byte_size` against `library_root_id = 10`. Five of six appear only on the
removable root and nowhere in either OneDrive root.

Consequences observed in the same session:

- Two enrichment worker slots stayed occupied ~2 minutes each hashing single files.
- `op=catalog.enrichment.scheduler phase=route claimed=25 readyQueued=5 enriching=2
  materializationPending=14 materializationInFlight=2 dispatched=0 limit=25` — six of
  eight worker slots idle.
- The same content was read twice off the card: once by enrichment's hash, once by the
  import copy.

The import path already hashes its staged copy locally at 28 MB/s
(`Otos/Services/MediaImportExecutor.swift:610`, logged `owner=import`), so removable
content still receives a digest — from local bytes, after import.

## Current state

### How "enriched" is defined today

`MediaAsset.needsEnrichment` (`Otos/Models/CatalogModels.swift:406`) returns
`metadataStale || hashStale`, where `hashStale` is true whenever
`content_hash_xxh3_128` is absent, malformed, or its recorded source size/mtime no
longer match the row's current facts.

`EnrichmentLeaseGateway.stalenessSQLPredicate()`
(`Otos/Stores/EnrichmentLeaseGateway.swift:51`) is the SQL twin of that expression. It
has five consumers:

| site | use |
|---|---|
| `EnrichmentLeaseGateway.swift:137` | `claimEnrichmentAsset` UPDATE guard |
| `EnrichmentLeaseGateway.swift:235` | `rootEnrichmentClaimQuery` |
| `EnrichmentLeaseGateway.swift:261` | `globalEnrichmentClaimQuery` |
| `EnrichmentLeaseGateway.swift:290` | further claim query |
| `CatalogStorePersistence.swift:1342` | partial index construction |

Swift-side, `EnrichmentLeaseGateway.priorityClaimInputs` filters on
`asset.needsEnrichment` (`:40`).

### Indexes

Two partial indexes are defined `WHERE <predicate>`:

- `idx_media_asset_needs_enrichment_global` on
  `(best_capture_unix DESC, library_root_id, relative_path)`
- `idx_media_asset_needs_enrichment_root` on
  `(library_root_id, best_capture_unix DESC, relative_path)`

Both are built by `createEnrichmentClaimIndexes(_:includeContentHash:)`
(`Otos/Stores/CatalogStorePersistence.swift:1337`). That helper **already carries the
metadata-only predicate** as its `includeContentHash: false` branch — the split this
plan needs exists historically and is used by migration `v5`; migration `v12` swapped
to the broad predicate.

Both claim queries use `INDEXED BY`, which is a hard constraint rather than a hint:
SQLite refuses to prepare a statement whose WHERE clause does not imply the named
partial index's WHERE clause.

### What produces a hash

`MediaEnricher.live` (`Otos/Services/MediaEnricher.swift:39`) hashes first,
unconditionally, then parses metadata, then generates a thumbnail. Hash-first is
deliberate: it routes a provider eviction back through materialization before the
later phases run.

`EnrichmentResult.contentHash` (`Otos/Models/AssetMetadata.swift:129`) is a
non-optional `XXH3Digest128`, so the result type cannot express "enriched, not hashed".
`EnrichWork` (`Otos/Services/EnrichmentCoordinator.swift:86`) carries no root-kind fact
that would let the enricher decide, though it does already carry `isDeviceStaging`
populated from `deviceRootPaths` (`EnrichmentCoordinatorWorkSelection.swift:488`).

The zero-byte short circuit (`EnrichmentCoordinatorCompletion.swift:67`) synthesizes
`contentHash: XXH3Digest128.empty`. That is a genuine digest for an empty file and
requires no byte read.

### What consumes a hash

Exactly one place: `hashMatches` (`Otos/Stores/CatalogStore.swift:3544`), which gates
import overlay reuse — cloning the source's metadata and thumbnail onto the destination
row instead of re-deriving them. Plan 0061 §4.2 requires the digest as proof that the
overlay being cloned was extracted from exactly the bytes published at the destination,
and explicitly refuses to accept size/mtime as that proof.

Import collision decisions do **not** read hashes. `MediaTransferPlanner` contains no
hash usage.

## Future state

Hash production is gated on byte locality:

| root kind | bytes the enricher opens | hashed during enrichment? |
|---|---|---|
| `.library` | fixed library root, local or cloud-materialized | yes — unchanged |
| `.deviceMTP` | app-owned staging dir under `Caches/…/DeviceStaging` (ADR 0013 §5) | yes — unchanged |
| `.removableVolume` | the card or disk itself, read in place | **no** |

`.removableVolume` is the only kind that changes. MTP already satisfies "do not
checksum until after staging" by construction, because its catalog root path *is* the
local staging directory.

An asset with no hash on a removable root is **fully enriched**. It is not re-claimed,
not re-dispatched, and does not appear in any claim query.

Removable content receives its digest after import, from the destination copy, via the
existing import worker path. The source row keeps no digest, permanently.

Overlay reuse is dropped for removable sources — with no source digest, its validation
cannot pass, and Plan 0061 §4.5 already specifies that import succeeds and the
destination is enriched normally when the source digest is absent. Reuse is retained
unchanged for MTP, where the digest is free.

## Collision decisions (confirmed 2026-08-01 — no code change)

Duplicate decisions during import are asymmetric, deliberately, and neither side reads
bytes:

- **Destination collision** — a candidate destination path is occupied by a regular
  file whose live size equals the source size and whose live mtime matches the expected
  destination mtime: **assume duplicate, skip.** This is what prevents a re-inserted
  card from producing `-1`/`-2` suffixed copies on every insertion. It reads only the
  occupancy probe, so a dataless destination placeholder is never materialized to prove
  the point.
- **Source-internal collision** — two source files whose facts map to the same
  destination name: **assume not duplicate, copy both** under suffixed names.

The asymmetry fails toward the cheaper mistake in each direction. Wrongly assuming a
source duplicate would silently drop a photo; wrongly assuming a source non-duplicate
costs one redundant file. Wrongly assuming a destination non-duplicate re-imports the
whole card on every insertion.

Verified already implemented: destination side at
`Otos/Services/MediaTransferPlanner.swift:404` (`catalogDecision`), source side at
`Otos/Services/MediaTransferPlanner.swift:373-377` (`reserved` → `.advanceSuffix`).
ADR 0018's "import planning remains fact-only" contract is therefore preserved by this
plan, not amended. Do not reintroduce hash-based collision detection on either side.

## Research: how to keep the claim queries indexed

A SQLite partial index's `WHERE` clause may reference only columns of the table being
indexed, so the predicate cannot consult `library_root.kind`. Three shapes were
considered. The following was measured against a copy of the live catalog
(SQLite 3.54.0, 26,542 rows).

### Measured index behaviour

**A narrower query can use a broader partial index.** A metadata-only `WHERE` forced
onto the existing broad `(metadata OR hash)` index with `INDEXED BY` plans successfully:

```
SEARCH media_asset USING INDEX idx_media_asset_needs_enrichment_root (library_root_id=?)
```

SQLite recognises that `A` implies `A OR B`.

**A broader query cannot use a narrower partial index.** A `(metadata OR hash)` `WHERE`
forced onto a metadata-only index fails at prepare time:

```
Parse error: no query solution
```

This is the safety property that matters: with `INDEXED BY`, wiring the wrong index to
the wrong root kind is a hard, immediate failure rather than silently missing rows.

**Selectivity, by root kind, in the live catalog:**

| root kind | rows | metadata-stale | hash-stale |
|---|---|---|---|
| `library` | 25,373 | 12,739 | 16,442 |
| `removableVolume` | 1,169 | 3 | 3 |

### Options

1. **Two index pairs.** Keep the broad pair for library/MTP roots; add a metadata-only
   pair for removable roots. The claim query names the index matching the root kind.
2. **Denormalise `hash_required` onto `media_asset`**, predicate becomes
   `metadataStale OR (hash_required AND hashStale)`. One index pair, fully selective.
3. **One metadata-only index**, hash-staleness filtered unindexed.

### Recommendation: option 1

- **No duplicated state.** Root kind stays owned solely by `library_root`; the query
  selects the index. Option 2 copies a root fact onto every asset row — the "two owners
  answer the same domain question" smell, for a fact that is already reachable.
- **Mis-wiring fails loudly.** Proven above: a broad query on a narrow index is
  rejected at prepare time. Option 2 has no equivalent guard; a stale `hash_required`
  value silently stops or starts hashing a whole root.
- **The index stays selective.** Under option 3, and under any scheme that keeps only
  the broad predicate, a removable row never gets a hash, so
  `content_hash_xxh3_128 IS NULL` stays true and the row is pinned in the index
  permanently. That set grows with every card ever attached. Option 1 lets a removable
  row leave the index as soon as its metadata is current.
- **The helper already exists.** `createEnrichmentClaimIndexes(_:includeContentHash:)`
  builds either predicate today; option 1 needs the two branches to coexist rather than
  alternate.

Cost: four partial indexes instead of two, so `media_asset` upserts maintain two more.
At the measured 26.5k rows this is not expected to matter; if a later measurement shows
otherwise, option 2 remains available.

**Residual risk to guard in tests.** The *safe-looking* mis-wiring — a narrow query
pointed at the broad index — does not error. It plans successfully and silently loses
selectivity. Tests must therefore assert which index is chosen, not only that results
are correct. `EXPLAIN QUERY PLAN` output is the assertion surface.

## Stages

### Stage 1 — Split the staleness contract

- `MediaAsset.needsEnrichment` (`Otos/Models/CatalogModels.swift:406`) exposes
  `metadataStale` and `hashStale` separately; the composed answer takes `hashRequired`.
  The model stays a pure value; the Store owns the root-kind → `hashRequired` mapping.
- `EnrichmentLeaseGateway.stalenessSQLPredicate()` splits into a metadata predicate and
  a hash predicate that compose, keeping the Swift and SQL forms twinned.
- Update all five consumers, including the `claimEnrichmentAsset` UPDATE guard
  (`:137`) and `priorityClaimInputs` (`:40`). A missed site here either re-claims a
  removable asset forever or stops claiming a library asset.

### Stage 2 — Indexes and migration

- Add a metadata-only index pair alongside the existing broad pair, via the existing
  `createEnrichmentClaimIndexes` helper.
- Add a migration following the established drop/recreate shape
  (`CatalogStorePersistence.swift:143-145` and `:201-203`).
- Claim queries name the index matching the root kind being claimed.
- The global claim query spans roots of mixed kinds; resolve during implementation
  whether it issues one statement per kind or partitions root IDs by kind first.
  It cannot use a single predicate across both.

### Stage 3 — Make the hash optional end to end

- `EnrichmentResult.contentHash` (`Otos/Models/AssetMetadata.swift:129`) becomes
  optional.
- The enrichment upsert (`CatalogStorePersistence.swift:636`, `:655`) writes hash
  columns only when a digest is present, and never clears an existing valid digest.
- `EnrichWork` (`Otos/Services/EnrichmentCoordinator.swift:86`) gains a `shouldHash`
  fact, populated in `makeWork` (`EnrichmentCoordinatorWorkSelection.swift:480`)
  following the existing `isDeviceStaging` / `deviceRootPaths` pattern.
- `MediaEnricher.live` (`Otos/Services/MediaEnricher.swift:39`) skips the hash entirely
  when `shouldHash` is false. It must not hash and discard — the full read must not
  happen. Hash-first ordering is preserved when hashing does run.
- Fold the duplicated `FileMaterialization.status(of:)` guard at
  `MediaEnricher.swift:40-45`; the identical `guard` appears twice.
- The zero-byte path keeps passing `XXH3Digest128.empty`.

### Stage 4 — Import settlement

- Overlay reuse short-circuits to a typed miss when the source root is a removable
  volume, without attempting the digest comparison
  (`Otos/Stores/CatalogStore.swift:3544`).
- Add the miss reason to Plan 0061 §4.6's vocabulary so aggregate reuse counters stay
  meaningful.
- The destination hash produced by the import worker is unchanged.

### Stage 5 — Documentation

- Amend ADR 0018: hash production is gated on byte locality, not on "every enriched
  asset"; a removable source is never hashed in place.
- Scope Plan 0061 §4.2 and §4.5 to sources whose bytes are local.
- ADR 0013 records in-place versus staged reads for removable volumes as a considered
  decision. It is currently an unexamined default: MTP stages because ImageCapture is
  not a filesystem, and removable volumes are read in place because they are one —
  bandwidth was never weighed.
- Update the affected `docs/requirements.md` rows for enrichment completion and import
  settlement.

## Explicitly out of scope

- **Staging removable volumes to local cache wholesale.** This plan removes the second
  full read of the card. Whether Otos should also stage USB media the way it stages MTP
  is a separate decision with a disk-cost tradeoff.
- **Enrichment admission caps** (`videoEnrichCap`, `enrichConcurrency`) and
  materialization root caps. The `dispatched=0` stall was traced to the ready queue
  being homogeneous because materialization upstream had delivered only videos — not to
  a defect in the admission loop, which already skips rejected candidates
  (`EnrichmentCoordinatorWorkSelection.swift:425`). No measurement justifies changing
  the caps.
- **Import copy worker count.**
- **`.otos-import-staging` FSEvent churn**, the **unexplained import coordinator
  silence**, the **enrichment-driven projection reorder storm**, and the
  **instrumentation gaps** (no sidebar click→paint signpost; `op=contentHash` without
  `rootPath`). All four are owned by Plan 0064, with evidence in the 2026-08-01 research
  document.
- **The red test baseline.** `script/verify.sh` exits 65 on `main` from five
  pre-existing failures, one of which asserts the very contract this plan changes
  (`OtosTests/EnrichmentLeaseGatewayTests.swift:47`). Plan 0063 owns it and records the
  sequencing constraint between the two plans.

## Tests

- A removable-root asset with current metadata and no digest reports
  `needsEnrichment == false` and is returned by no claim query. This is the regression
  that would otherwise spin enrichment forever.
- A fixed-library asset with current metadata and no digest still reports
  `needsEnrichment == true`.
- Enriching a removable-root asset performs zero full-file reads. Assert against a
  byte-source spy, not elapsed time.
- Each claim query uses its intended index. Assert on `EXPLAIN QUERY PLAN` output — a
  narrow query silently plans against the broad index, so correctness assertions alone
  will not catch a mis-wire.
- Migration: a catalog populated under the old predicate migrates, all four indexes
  exist afterwards, and claim queries return the expected sets per root kind.
- Import from a removable source with no source digest settles successfully, records
  the new typed reuse miss, and leaves the destination needing enrichment until normal
  enrichment stamps it.
- Import from an MTP source with a valid staged digest still reuses overlay.
- Existing removable rows that already carry a digest keep it across the migration and
  do not become re-enrichable.

## Risks

- The staleness predicate is load-bearing for two claim queries, an UPDATE guard, a
  Swift-side filter, and two partial indexes. Splitting it wrong either spins
  enrichment forever or silently stops enriching a root. The first two tests above are
  the guards.
- `INDEXED BY` makes an unusable index a hard failure. That is desirable — it converts
  a mis-wire into an immediate error — but it means index and query predicates must be
  changed together in the same migration.
- Existing removable rows already carry digests (1,166 of 1,169 in the measured
  catalog). They must not be cleared, and their presence must not make the row
  re-enrichable under the new predicate.
- Removing the source hash removes the only current consumer of hashes for removable
  content. If duplicate detection is later built on hashes, removable sources will have
  none until imported. That is accepted: collision decisions are fact-only by design.
