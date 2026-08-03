# Plan 0063 — Restore a green test baseline on main

## Status

Active. Confirmed 2026-08-02. Highest priority: a red baseline makes every other
increment's verification ambiguous.

## Purpose

`script/verify.sh` exits 65 on `main`. Lint and build pass; five tests fail. They were
baselined on `main` @ `cd1d3e2` with no working-tree changes, so they are pre-existing
and were not introduced by any increment merged on 2026-08-02.

Until this is fixed, no increment can claim a green local check, and a genuine
regression can hide behind the known-red set.

## Failing tests

| test | file |
|---|---|
| `priorityClaimInputsFiltersUnavailableAndNonStaleAssets` | `OtosTests/EnrichmentLeaseGatewayTests.swift:47` |
| `foreignOccupantAdvancesSuffix` | `OtosTests/MediaTransferPlannerTests.swift:248` |
| `differentLiveMtimeAdvancesTheWholeBundleSuffix` | `OtosTests/MediaTransferPlannerTests.swift` |
| `differentLiveSizeAdvancesTheWholeBundleSuffix` | `OtosTests/MediaTransferPlannerTests.swift` |
| `missingLiveMtimeDoesNotClaimPreexisting` | `OtosTests/MediaTransferPlannerTests.swift` |

Both groups are stale tests asserting superseded contracts, not product regressions.

## Root cause 1 — enrichment staleness fixture predates Plan 0060

`OtosTests/EnrichmentLeaseGatewayTests.swift:51` builds an asset with
`enrichedSourceSize: 1024` and `enrichedSourceMTimeSeconds: 1` but no content hash, then
asserts at `:62`:

```swift
#expect(currentAsset.needsEnrichment == false)
```

That held until Plan 0060 folded hash-staleness into `MediaAsset.needsEnrichment`
(`Otos/Models/CatalogModels.swift:406`), which now returns `metadataStale || hashStale`.
With `contentHash == nil`, `hashStale` is true, so the asset is stale and the assertion
fails. Commit `acef1cb` introduced this and landed red.

### Sequencing constraint

**Do not fix this by asserting the current behavior verbatim.** Plan 0062 changes the
correct answer again: after it lands, a metadata-current asset on a `.removableVolume`
root with no hash is legitimately **not** stale, while the same asset on a `.library`
root still is. Fixing this test to assert "no hash means stale" and then re-fixing it
under 0062 is churn.

Two acceptable resolutions:

1. **Land 0062 first**, then write the test against the split contract with one case per
   root kind. Preferred — the test then encodes the durable rule.
2. If 0063 must land first, make the fixture genuinely current by giving it a valid
   content hash and matching signature, so the test asserts what it was always about —
   "a fully current asset is not eligible" — without encoding *which* facts constitute
   currency. This survives 0062 unchanged.

Option 2 is the smaller change and does not block on 0062. Prefer it if this plan lands
first.

## Root cause 2 — planner tests assert a superseded internal contract

The four `MediaTransferPlannerTests` failures call
`MediaTransferPlanner.planImport(snapshot:occupancy:)` directly and expect it to consult
`snapshot.knownForeignOccupants`. Production applies foreign knowledge one level up, in
`buildImportPlan`'s probe loop:

```swift
// Otos/Services/MediaTransferPlanner.swift:81
let resolvedOccupancy = FilesystemNamespaceSemantics.resolve(
    occupancyRequests,
    knownForeignOccupants: foreign
)
```

`foreign` is `knownForeignOccupants.union(snapshot.knownForeignOccupants)` at `:73`, and
is genuinely consumed — the production path is correctly wired. `planImport` alone never
sees foreign knowledge, so a test that supplies only a partial occupancy map gets
`.needsProbes` and fails its `guard case let .ready` with `Issue.record("expected ready
plan")`.

These tests reach past the public owner boundary into an internal step. Per CLAUDE.md,
tests assert observable behavior or public owner boundaries. The fix is to exercise
`buildImportPlan` — the real entry point, which owns the probe loop — rather than to
re-plumb foreign handling into `planImport` to satisfy the tests.

Confirm during implementation that no production caller invokes `planImport` directly
expecting foreign handling; if one does, that is a real defect and this plan grows to
cover it.

## Also in scope — one load-sensitive flake

`FileMaterializationTests/materializationRerequestsUntilProviderClearsDataless` failed
once inside a full-suite run at 1.465 s, then passed 3/3 in isolation at 0.006 s — a
244× difference. It did not reproduce in a later full-suite run.

Diagnose and remove the timing sensitivity rather than retrying it. A test that only
fails under parallel load will otherwise erode trust in the suite exactly when the suite
is being used to prove something.

## Not in scope

- Changing `MediaAsset.needsEnrichment` semantics. That is Plan 0062's subject.
- Changing where foreign-occupant knowledge is applied in production. The current
  placement is correct; only the tests are wrong.

## Definition of done

- `script/verify.sh` exits 0 on `main`.
- No test asserts an internal planner step in place of a public owner boundary.
- The flake is root-caused, not retried.
