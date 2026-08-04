# 2026-08-03 — Post-increment review experiments

Experiments run while reviewing the 2026-08-02/03 increments (PRs #135, #136, #138, #139,
#140, #141, #142, #143, #144). Conclusions feed Plan 0065.

Sources: SQLite 3.54.0 (`3.54.0 2026-04-09 … aapl`, the system binary), a read-only copy of
the live catalog, `script/verify.sh`, and live `script/smoke-run.sh --jank` captures. No
originals were read or modified. The catalog was copied before querying; the live database
was never opened by these experiments.

---

## 1. `INDEXED BY` partial-index implication is syntactic — and unguarded

Relevant because Plan 0062 split the enrichment staleness predicate and both claim queries
pin an index with `INDEXED BY`, which SQLite treats as a hard constraint.

### 1a. The comment's claim is correct

`EnrichmentLeaseGateway.swift:106` warns that re-parenthesizing the predicate breaks the
implication check. Tested by building the v12 index text and preparing three query variants
against it:

| query predicate | result |
|---|---|
| token-identical to the index `WHERE` | `SEARCH media_asset USING INDEX idx_media_asset_needs_enrichment_root (library_root_id=?)` |
| same clauses wrapped as `(A) OR (B)` | `Parse error: no query solution` |

SQLite proves `A ⟹ A OR B` but will not prove `(A) OR (B) ⟹ A OR B`. The check is on the
parsed expression tree, so a logically equivalent reformatting is rejected at **prepare**
time, not at runtime.

### 1b. The hazard is dormant on the live catalog

The live catalog is migrated to v13. Its stored DDL for
`idx_media_asset_needs_enrichment_root` was extracted with
`SELECT sql FROM sqlite_master` and compared against what current code generates:
**byte-identical**. Plan 0062's flattening preserved the v12 text exactly, as intended.

### 1c. …but nothing can keep it proven

Migration v12's body (`CatalogStorePersistence.swift:199`) calls the *current*
`createEnrichmentClaimIndexes`, which calls the *current* predicate builder. Consequences:

- a **fresh** database always agrees with itself, whatever the text becomes
- an **existing** catalog keeps the historical text forever
- every test builds from the current migrator, so no test can observe the divergence

`v13MigrationAddsMetadataOnlyEnrichmentClaimIndexesAndKeepsDigests` looks like it covers
this but does not: it migrates with current code and drops only the v13 pair.

**Failure mode if the predicate is ever reformatted:** all tests stay green;
`fetchStoredAssetsNeedingEnrichment(hashRequired: true)` throws at prepare on every shipped
catalog; `EnrichmentCoordinatorWorkSelection.swift:112` catches, logs, returns `[]`. Library
enrichment stops permanently with no user-visible signal.

**Conclusion → Plan 0065 Stage 1.** Guard with a frozen literal v12 index string in a test,
never regenerated from production code.

### 1d. Undocumented decision

No ADR, `docs/architecture.md` entry, or requirement mentions `INDEXED BY`. A constraint
that converts a planner preference into a cross-version build dependency should not be
undocumented. Rationale and measurement wanted.

---

## 2. `.debug` instrumentation is unreadable by this repo's tooling

Plan 0064 Stage 1 added `op=ui.sidebarSelectionToPaint` to measure the session's primary
reported symptom; Stage 4 added `op=catalog.planningChange phase=emit` /
`op=import.coordinator phase=receive` to distinguish "not emitted" from "not received".
Both were reported closed.

All emit at `.debug`:

- `UIJankDiagnostics.swift:91`, `:108`
- `CatalogStore.swift:2820`
- `MediaOperationCoordinator.swift:401`

All three capture paths stream at `--level info` — `smoke-run.sh:107`,
`capture-run.sh:32`, `logs.sh:42` — so durable `logs/*.log` artifacts never contain them.
`logs.sh show` does pass `--info --debug`, so post-hoc retrieval *should* work. Measured
during a live session (pid 14640):

```
$ ./script/logs.sh show --last 5m   | count by messageType
{'Info': 20, 'Default': 85, 'Error': 2, 'Fault': 1}
```

**Zero Debug messages.** macOS does not persist debug-level messages for a subsystem absent
an explicit logging configuration profile. `grep -c sidebarSelectionToPaint` over a full
captured session returns `0`.

**Secondary consequence.** The 2026-08-01 diagnosis §6 inferred that the import coordinator
"received no planning change at all" from the *absence* of debug lines. If debug lines are
never captured, that absence was not evidence. Stage 4's conclusion is independently
supported by the `.notice`-level `phase=subscribed` markers (both confirmed present in
capture), but the reasoning path must not be reused.

**Conclusion → Plan 0065 Stage 0.**

---

## 3. Live catalog state (read-only copy, 2026-08-03)

28,392 assets, 7 roots, schema at v13 (`v13_hash_gated_enrichment_claim_indexes` applied).

| root | kind | assets | metadata-stale | no digest |
|---|---|---|---|---|
| `…/OneDrive-Personal/Pictures/Camera Roll` | library | 26,235 | 11,122 | 13,830 |
| `…/OneDrive-Personal/Family/Summer Photos` | library | 644 | 0 | 367 |
| `/Volumes/4152150790` | removableVolume | 1,374 | 0 | 0 |
| `/Volumes/CAMERA` | removableVolume | 139 | 0 | 0 |

Two observations:

- Both removable roots show **0 rows without a digest**, i.e. they retain hashes recorded
  before Plan 0062 stopped hashing them in place. This confirms the
  `COALESCE(?, content_hash_xxh3_128)` preservation in `writeEnrichmentOverlay` behaves as
  designed on real data — a plain assignment would have cleared 1,513 digests.
- 11,122 metadata-stale assets on the main library make this a genuine enrichment-storm
  environment for Plan 0064 Stage 3 verification.

All four claim indexes are present:
`idx_media_asset_needs_enrichment_{global,root}` and the `_metadata_only` pair.

---

## 4. Live captures

`script/verify.sh` on `main` at `c93ba05`: **exit 0, 559 tests passed, 0 failed**,
Xcode 27.0 (27A5228h).

Two `--jank` captures were taken (90 s and 360 s settle). At startup/scan scale:

| figure | measured |
|---|---|
| projection publications, whole session | 3–4 |
| worst `assetOrderQueryMs` | 256 |
| worst `projectionMs` | 318 |
| worst `mediaIdentityEqualityUs` | 8 |
| 26,879-item structural apply | `applyCallMs=6 applyMs=40 snapshotBuildMs=18`, `largeApply=true`, `reloadDataFallback=true` |
| `mainThreadStall` | 1 occurrence, `stallMs=207` (first apply, `latestItems=644`) |

**These do not validate Plan 0064 Stage 3.** Zero `op=catalog.enrichment.batch` lines were
emitted in either session, so the condition Stage 3 addresses never occurred.

### 4a. Invalidated first reading — provider was down

The initial analysis attributed the zero-enrichment result to an Otos defect, citing
`op=materialization.request phase=failed … providerMs=120198 outcome=timedOut
rerequestCount=115` and `readiness … materializationBound=32`, and asserted a "healthy
environment" because `pgrep` showed `OneDrive File Provider.appex` and
`OneDrive Sync Service` running.

**That was wrong.** OneDrive was not running for either capture. A live File Provider
extension is not a ready, signed-in sync client, and Otos's own materialization request can
spawn the appex on demand. Process presence is not provider readiness.

A 120 s timeout against a provider that is not up is the expected outcome, not a finding.

### 4c. Re-run with OneDrive started — same result, and the provider is the cause

A third capture was taken after OneDrive was started
(`logs/run-20260804T005949Z-p38953-prod.log`, 10,542 lines, ~7 minutes):

| | |
|---|---|
| `op=catalog.enrichment.batch` | **0** |
| materialization requests dispatched | 4 |
| materialization requests succeeded | **0** |
| materialization requests `outcome=timedOut` | 3, each `providerMs≈120,000`, `rerequestCount≈115` |
| readiness cycles at `materializationBound=32` | 34 |

The provider was tested **directly, outside Otos**, on files from both OneDrive roots:

```
$ open() + read(4096) on …/Summer Photos/2026/05/20260515_191306.jpg
read: Operation timed out          elapsed=1s     (stat: size=538853 blocks=0, unchanged)

$ open() + read(4096) on …/Camera Roll/2026/03/20260328_204245621_iOS.jpg
read: Operation timed out          elapsed=1s     (stat: size=9372399 blocks=0, unchanged)
```

**The OneDrive provider refuses every read with an immediate `ETIMEDOUT`**, on both roots,
with the OneDrive processes running. It is running but not serving — signed out, awaiting
re-auth, or still initialising. This is an environment state, not an Otos defect, and
**Plan 0064 Stage 3 cannot be measured on this machine until it is resolved.**

### 4d. What survives as a genuine Otos finding

The provider fails **fast** — 1 second, a definite `ETIMEDOUT`. Otos converts that into a
**120-second, 115-re-request stall**, and because `rootBackgroundCap` holds `inFlight=1`,
that one refusal blocks all 32 probed enrichment candidates for the full two minutes.

The mechanism is visible in the design: `FileMaterialization` polls `SF_DATALESS` *status*
on a retry cadence rather than observing what the provider actually returned. A provider
that answers "no, right now" is therefore indistinguishable from a provider that is merely
slow, and the fast, definite failure is upgraded into a long stall.

Whether that is correct (a provider may recover within the window) or a defect
(head-of-line blocking on a single slot, on a signal that was already definitive) is a real
design question. It should be decided against a healthy-provider baseline, which does not
exist yet. It is **not** a steady-state throughput claim, and nothing in the 2026-08-02/03
diffs touches the materialization scheduler, so no causal link to that increment is claimed.

### 4e. Methodology rule

Provider readiness must be a **recorded precondition** of any capture, verified by an
actual read, never inferred from a process listing. A capture that silently measures a dead
provider looks exactly like data.

### 4b. Tooling defect found

`smoke-run.sh --verify` cannot succeed on this machine. The default root
`$HOME/Desktop/OneDrive/Pictures` resolves to `…/CloudStorage/OneDrive-Personal/Pictures`,
an *ancestor* of the registered `…/Pictures/Camera Roll` root:

```
op=catalog.library.ensure phase=error
  error=overlappingRoot(existingPath: …/Pictures/Camera Roll,
                        relationship: LibraryRootRelationship.ancestor)
```

Overlap validation is behaving correctly; the default is wrong.

---

## 5. Static findings carried to Plan 0065 without new measurement

- **`structureChanged` duplicates a generated column.** `CatalogStore.swift:1351-1358`
  recomputes `best_capture`/`best_kind`/`best_format` in Swift, mirroring the SQL
  `GENERATED ALWAYS AS` at `CatalogStorePersistence.swift:1288-1299`. Chains agree today
  and the column set is complete (sort fields are `best_capture_unix`, `name_sort_key`,
  `byte_size`; enrichment writes neither of the latter two). Drift is undetectable —
  `ProjectionEnrichmentCoalescingTests.detailEnrichment` builds fixtures where both
  derivations agree by construction, so the oracle is the Swift logic, not the database.
- **`hashRequired` derived twice.** Store decides per row at `CatalogStore.swift:973`; the
  coordinator re-derives `shouldHash` at `EnrichmentCoordinatorWorkSelection.swift:490`
  from a cache refreshed *before* the claim. Both divergence directions traced; neither
  livelocks, each self-heals in one cycle. Not a bug — but the
  `library → removableVolume` direction costs one full-file read of a card file, the exact
  cost Plan 0062 exists to avoid.
