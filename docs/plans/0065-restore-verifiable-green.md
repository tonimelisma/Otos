# Plan 0065 — Restore verifiable green

## Status

Not started. Created 2026-08-03 from a full review of the 2026-08-02/03 increments
(PRs #135, #136, #138, #139, #140, #141, #142, #143, #144).

All measurements cited here are recorded in
`docs/research/2026-08-03-post-increment-review-experiments.md`, which is the authority
for method, raw figures, and what each experiment does and does not establish. This plan
carries only the conclusions and the work.

## Purpose

`script/verify.sh` is green (559 tests, Xcode 27.0 / 27A5228h, exit 0). That is *green
by unit test*. This plan closes the gap between that and **verifiably green**: the
behavior claims made by plans 0062 and 0064 are not currently observable in any capture
the repo can produce, and three shipped constructs can silently diverge without any
test noticing.

The organising principle is the same one plan 0064 Stage 1 used and which this plan
found was not actually achieved: **nothing is optimised or declared fixed before the
signal that proves it can be read.**

Stage 0 is a hard prerequisite for Stages 3–4. Stages 1–2 are correctness guards that
are independent of it and can land in parallel.

## Readiness — read this first

Six stages are ready to implement from this document alone. Two are blocked on evidence
that does not exist yet and **must not be implemented on intuition**.

| Stage | Ready? | Nature of the change |
|---|---|---|
| 0 — instrumentation readable | ✅ ready | 4 log-level changes + a level-floor test + ADR policy |
| 1 — freeze index contract | ✅ ready | Test-only; no production change |
| 2a — delete the Swift twin | ✅ ready | Replace a recompute with `RETURNING`; deletes code |
| 2b — one `hashRequired` | ✅ ready | Return an already-computed value; deletes a cache |
| 4 — lock the regression | ✅ ready | One log field + de-flake existing tests |
| 5 — tooling and process | ✅ ready | Script default + a CLAUDE.md rule |
| 3 — field verification | ⛔ **blocked** | Needs a working cloud provider — see below |
| 3b — provider-failure policy | ⛔ **blocked** | Needs Stage 3's healthy baseline to decide |

### The blocker on Stages 3 and 3b is not a code problem

As of 2026-08-03 the OneDrive provider on the development machine refuses every read with
an immediate `ETIMEDOUT`, verified outside Otos on both library roots, with the OneDrive
processes running. Enrichment therefore emitted **zero** batches across three capture
sessions.

Until that is resolved — most likely a re-auth or sign-in on the OneDrive client, which is
a **user action, not an engineering task** — the enrichment storm that Plan 0064 Stage 3
optimises cannot be produced, so its perf claim cannot be verified and Stage 3b's design
question has no baseline to be decided against.

Do not substitute a synthetic reproduction for this. The whole point of Stage 3 is that a
mechanism test at n=2,000 in memory already passes; what is missing is behaviour at 25k
under real WAL pressure, where the field data shows the same query ranging 62 ms →
7,034 ms.

### Note on scope

An implementer should treat the six ready stages as the increment. "Get rid of every smell"
is explicitly **not** the goal — see *Explicitly out of scope* at the end, which records two
real Lens-B observations that should be left alone for now, with the trigger conditions
that would change that.

---

## Stage 0 — Make the instrumentation readable (blocking prerequisite)

### Evidence

Plan 0064 Stage 1 built `op=ui.sidebarSelectionToPaint` specifically because the
session's primary reported symptom ("about two minutes to switch to All Media") could
not be measured at all. Plan 0064 Stage 4 built the `phase=emit` / `phase=receive` pair
specifically to distinguish "no events emitted" from "events not received". Both were
reported closed in their DoDs.

**Neither can be read by any tool in this repository.**

All three emit at `.debug`:

- `Otos/Support/UIJankDiagnostics.swift:91` — `op=ui.sidebarSelectionToPaint phase=start`
- `Otos/Support/UIJankDiagnostics.swift:108` — `op=ui.sidebarSelectionToPaint phase=finish`
- `Otos/Stores/CatalogStore.swift:2820` — `op=catalog.planningChange phase=emit`
- `Otos/Services/MediaOperationCoordinator.swift:401` — `op=import.coordinator phase=receive`

All three capture paths stream at `--level info`, which is above debug, so the durable
`logs/*.log` artifacts never contain them:

- `script/smoke-run.sh:107`
- `script/capture-run.sh:32`
- `script/logs.sh:42` (`stream`)

`script/logs.sh show` passes `--info --debug`, so it *should* retrieve them post-hoc.
Measured during a live session: **zero Debug messages returned** — macOS does not persist
debug-level messages for a subsystem without an explicit logging configuration profile, so
they are neither streamed nor retrievable. `grep -c sidebarSelectionToPaint` over a full
captured session returns `0`. Raw counts in the research note, §2.

This also retroactively weakens one conclusion in the 2026-08-01 diagnosis: §6 inferred
that the import coordinator "received no planning change at all" from the *absence* of
debug-level lines. If debug lines are never captured, that absence was not evidence.
Stage 4's conclusion (the subscription is correctly wired) happens to be right and is
independently supported by the `.notice`-level `phase=subscribed` markers, which do
appear in capture — but the reasoning path must not be reused.

### Work

1. Promote the four operations above from `.debug` to `.notice`. They are per-user-intent
   and per-occupancy-change, not per-frame or per-asset — the volume argument for `.debug`
   does not hold. `phase=emit` is the only one with any burst risk; measure it in the
   Stage 4 capture before deciding whether it needs sampling.
2. Add a **log-level floor test**: assert that every operation named in
   `docs/requirements.md` as an observability contract is emitted at `.notice` or above.
   This is the guard that stops the class, not just the instance. It must assert on the
   `OtosLog` call boundary, not by reading source text (CI forbids source-text tests).
3. Decide and document the policy in `docs/adr/0015-observability.md`: **if a signal is
   part of a stated diagnostic contract, it is `.notice` or above; `.debug` is for
   signals we accept losing.** Right now the ADR is silent and the split is accidental.

### Definition of done

A `script/smoke-run.sh --jank` capture contains at least one
`op=ui.sidebarSelectionToPaint phase=finish ms=…` line, and a scan-triggered capture
contains matching `phase=emit` / `phase=receive` pairs.

---

## Stage 1 — Freeze the partial-index predicate contract

### Evidence

`EnrichmentLeaseGateway.stalenessSQLPredicate(hashRequired:)`
(`Otos/Stores/EnrichmentLeaseGateway.swift:106`) carries a comment stating its
`hashRequired == true` branch must remain token-identical to the `WHERE` clause that
migration v12 wrote. **The comment is correct** — confirmed against SQLite 3.54.0: the
token-identical form plans against the index, the re-parenthesized `(A) OR (B)` form fails
to prepare with `no query solution`.

Also confirmed against the **live catalog** (28,392 assets, schema at v13): the stored DDL
for `idx_media_asset_needs_enrichment_root` is byte-identical to what current code
generates, so **the hazard is dormant today, not live**. Research note §1.

The problem is that it cannot stay proven. Migration v12's body
(`Otos/Stores/CatalogStorePersistence.swift:199`) calls the *current*
`createEnrichmentClaimIndexes`, which calls the *current* predicate builder. A fresh
database therefore always agrees with itself; an existing catalog carries the historical
text forever. Every test builds from the current migrator, including
`v13MigrationAddsMetadataOnlyEnrichmentClaimIndexesAndKeepsDigests`, which only drops the
v13 pair and cannot observe the drift.

**Failure scenario.** Someone reflows `metadataStalenessSQLPredicate()` for readability.
All tests stay green. On every shipped catalog,
`fetchStoredAssetsNeedingEnrichment(hashRequired: true)` throws at *prepare*;
`claimEnrichmentCandidates` catches it at
`Otos/Services/EnrichmentCoordinatorWorkSelection.swift:112`, logs, and returns `[]`.
All library enrichment stops permanently. The app looks healthy; new files simply never
get thumbnails or metadata, forever.

### Work

1. Add `OtosTests/EnrichmentClaimIndexContractTests.swift`: `CREATE` both v12 indexes
   from a **frozen literal SQL string checked into the test file** — never regenerated
   from production code — then prepare the current hash-required root and global claim
   queries against them and assert the plan names the index. Include a comment stating
   the string is a historical artifact and must not be "fixed" to match new code.
2. Add the negative twin: assert the re-parenthesized form fails to prepare, so the test
   documents *why* the frozen string exists rather than looking like redundant coverage.
3. Decide whether `INDEXED BY` is worth its cost here, and record the decision. What it
   does is not in dispute: it converts a planner *preference* into a hard cross-version
   *build dependency*, which is the whole reason this stage exists. What it was adopted
   *for* is not recorded — no ADR, `docs/architecture.md` entry, or requirement mentions
   `INDEXED BY` at all, so the rationale currently lives only in whoever wrote it.
   Measure the claim queries with and without the hint against a copy of the live catalog,
   keep the hint if the measurement supports it, and write the result into an ADR either
   way. A constraint this sharp should not be undocumented.

---

## Stage 2 — Remove the two duplicated derivations

### 2a — `structureChanged` re-implements a generated column

`Otos/Stores/CatalogStore.swift:1351-1358` recomputes `best_capture`/`best_kind`/
`best_format` in Swift, mirroring the SQL `GENERATED ALWAYS AS` definitions at
`Otos/Stores/CatalogStorePersistence.swift:1288-1299`. Two owners, one derivation.

Reviewed term by term: the chains agree today, and the column set is complete (sort
fields are `bestDate`/`name`/`size` → `best_capture_unix`, `name_sort_key`, `byte_size`;
enrichment writes neither of the latter two, and filter facets are derived from
`best_kind`/`best_format`, which are covered).

**Failure scenario.** A future migration adds a timestamp source to `best_capture_unix`
and the Swift twin is not updated. The write changes the stored column; the twin computes
no change; `structureChanged` stays false; `.assetsDetailChanged` is emitted; the
projection reuses the previous order. **Assets sort into the wrong position and stay
there** until an unrelated structural change dislodges them. Silent, user-visible.

No test can catch this. `ProjectionEnrichmentCoalescingTests.detailEnrichment` builds
fixtures with `enrichedKind: asset.bestKind` and `original: asset.bestCaptureDate`, so
both derivations agree by construction — the oracle *is* the Swift logic.

**Work.** Delete the twin. The columns are `STORED`: read them back. Either re-`SELECT`
the three columns after `writeEnrichmentOverlay`, or add
`RETURNING best_capture_unix, best_kind, best_format` to the existing `UPDATE`
(SQLite 3.35+; GRDB supports it). One statement, zero duplication, the database remains
the single owner of its own generated columns. Cost is a PK lookup on batches averaging
~2 rows.

Add a test that would have failed under the old design: enrich with a result whose
effective `best_capture` differs from the naive Swift computation, and assert the emitted
change kind follows the *database*.

### 2b — `hashRequired` is derived twice

The store decides per row at claim time (`Otos/Stores/CatalogStore.swift:973`). The
coordinator independently re-derives `shouldHash` in `makeWork`
(`Otos/Services/EnrichmentCoordinatorWorkSelection.swift:490`) from a cache refreshed at
line 20 — *before* the claim, so strictly staler.

Both divergence directions were traced and neither livelocks; each self-heals within one
claim cycle. This is not a bug today. But the `library → removableVolume` direction costs
exactly what plan 0062 exists to prevent — one full-file read of a card file, measured in
the field at 0.005 MB/s — and it spends an extra actor round-trip per claim cycle
re-deriving a fact the store already computed and discarded.

**Work.** Carry `hashRequired` on the claimed candidate. `claimEnrichmentCandidates`
already computes it per row in `eligibleClaims`; return it instead of throwing it away,
and delete `CatalogStore.removableVolumeRootPaths()` plus the coordinator's
`removableRootPaths` cache.

---

## Stage 3 — Produce the missing field evidence

### Evidence that this is missing

`logs/` holds ~100 captures. Before this plan, **every capture since 2026-08-01 was a
test-run log**; the most recent real-application capture was from July. The perf claim in
plan 0064 Stage 3 was validated only by a unit test at 2,000 in-memory assets with 4-byte
fixtures, against field numbers taken at 25,367 assets under 4 MB of WAL pressure where
the same query ranged 62 ms → 7,034 ms — a 113× non-linearity in write pressure.

A mechanism test at n=2,000 proves the skip happens. It cannot prove the budget holds.

### Attempted 2026-08-03 — partial, then blocked

Two captures were taken against the live library (28,392 assets across 4 roots; 26,235 +
644 on the two reachable OneDrive roots, 11,122 metadata-stale):

- `logs/run-20260804T005005Z-p14033-prod.log` — 90 s settle + scroll
- `logs/run-20260804T005230Z-p21417-prod.log` — 360 s settle + scroll

What they **did** establish, at startup/scan scale:

| figure | measured |
|---|---|
| projection publications, whole session | 4 |
| worst `assetOrderQueryMs` | 256 |
| worst `projectionMs` | 318 |
| worst `mediaIdentityEqualityUs` | 8 |
| 26,879-item structural apply | `applyCallMs=6 applyMs=40 snapshotBuildMs=18` (`largeApply=true`, `reloadDataFallback=true`) |
| `mainThreadStall` count | 1, at `stallMs=207` (first apply, `latestItems=644`) |

These are healthy numbers and no order-query storm appeared — but they are **not** a
validation of Stage 3, because the condition Stage 3 addresses (enrichment applying
batches) never occurred. See Stage 3b.

### Work

Run `script/smoke-run.sh --jank` against the live library (26,235 + 644 assets, ~11,122
metadata-stale at time of writing — a genuine enrichment-storm environment) with a settle
long enough to reach steady-state enrichment, and write
`docs/research/2026-08-0X-plan-0064-verification.md` using the same table shape as the
2026-08-01 diagnosis. Required figures:

- full order queries per 100 enrichment applies (the Stage 3 headline; field baseline was
  31 full 25,367-row queries per ~35 batches)
- `projectionMs` and `assetOrderQueryMs` p50/p99 during enrichment
- `mediaIdentityEqualityUs` p99 (field worst: 434,251 µs)
- `SidebarSelectionToPaint` ms for the All Media switch under enrichment load — the
  primary reported symptom, still never measured (**requires Stage 0**)
- `mainThreadStall` count and worst `stallMs` (field worst: 327 ms on `applyStructure`)
- WAL bytes sampled alongside, since the field data shows it is the dominant term

If a figure regressed or cannot be produced, say so in the document. A verification
research note that only confirms is not a verification.

### Known gap this stage must not paper over

The 2026-08-01 diagnosis §3 records an unexplained 38-second window with no log output at
all (21:27:03.573 → 21:27:41.689). No plan has addressed it. If it recurs in the new
capture, it becomes its own plan; if it does not, record that and close it.

---

## Stage 3b — Degraded-provider behaviour, and a capture-methodology gap

### What was observed

The first Stage 3 attempts could not produce the headline figure, because **enrichment
never emitted a single batch**. Captured 2026-08-03, `logs/run-20260804T005230Z-*.log`,
over ~5 minutes after both scans completed:

```
op=catalog.enrichment.readiness phase=route probes=32 ready=0 needsMaterialization=0
   retryReadiness=0 materializationBound=32          (repeated, every cycle)

op=materialization.admission phase=blocked priority=background reason=rootBackgroundCap
   rejected=1 admitted=0 pendingBackground=1 inFlight=1

op=materialization.request phase=failed priority=background
   relativePath=2026/05/20260515_191306.jpg
   providerMs=120198 totalMs=120198 outcome=timedOut rerequestCount=115 inFlight=0
```

`op=catalog.enrichment.batch` count over the whole session: **0**. Stale asset count at
session start: **11,122**.

### Confounded — the provider was down

**These two captures are not valid evidence of an Otos defect.** OneDrive was not running
for either of them; it was started only afterwards. The initial reading here asserted a
"healthy environment" on the strength of `pgrep` showing `OneDrive File Provider.appex`
(pid 21529) and `OneDrive Sync Service` — but a live File Provider extension is not a
ready, signed-in sync client, and Otos's own materialization request can spawn the appex
on demand. Process presence was mistaken for provider readiness.

A 120 s timeout after 115 re-requests against a provider that is not up is the expected
outcome, not a finding.

### Re-run with OneDrive started — same result, provider confirmed as the cause

A third capture after OneDrive was started (`logs/run-20260804T005949Z-*.log`, ~7 minutes,
10,542 lines) reproduced it exactly: **0 enrichment batches**, 4 materialization requests
dispatched, **0 succeeded**, 3 timed out at `providerMs≈120,000 rerequestCount≈115`, and
34 readiness cycles at `materializationBound=32`.

The provider was then tested **directly, outside Otos**, on files from both OneDrive roots.
Both fail identically:

```
open() + read(4096)  →  Operation timed out   elapsed=1s   (blocks=0, unchanged)
```

**The OneDrive provider refuses every read with an immediate `ETIMEDOUT`** while its
processes run — signed out, awaiting re-auth, or still initialising. Environment state, not
an Otos defect. **Stage 3 is blocked on this machine until OneDrive actually serves.**

### The finding that survives

The provider fails **fast** — 1 second, definite `ETIMEDOUT`. Otos turns that into a
**120-second, 115-re-request stall**, and because `rootBackgroundCap` holds `inFlight=1`,
that single refusal blocks all 32 probed enrichment candidates for the full two minutes.

The mechanism is in the design: `FileMaterialization` polls `SF_DATALESS` *status* on a
retry cadence rather than observing what the provider returned. A provider answering "no,
right now" is indistinguishable from a slow one, so a fast definite failure is upgraded
into a long stall on a single-slot queue.

### Work

1. Decide whether a definite provider error should short-circuit the poll loop instead of
   running to the 120 s deadline. Both readings are defensible — a provider may recover
   within the window — so decide it against a healthy-provider baseline, which does not
   exist yet. Do not retune the cadence on intuition.
2. Reconsider `rootBackgroundCap`'s `inFlight=1` head-of-line behaviour **only after** (1).
   If a definite failure releases the slot promptly, the starvation may disappear without
   touching the cap.
3. Add a provider-readiness precondition to `script/smoke-run.sh`: verify by an actual
   read, and refuse to start or loudly annotate the capture when the configured root's
   provider is not serving. A capture that silently measures a dead provider is worse than
   no capture, because it looks like data.
4. Re-run Stage 3 once OneDrive serves. Only that capture counts.

Nothing in the 2026-08-02/03 diffs touches the materialization scheduler, so no causal link
to that increment is claimed.

### Work

1. Reproduce with a capture long enough to see whether the queue ever recovers, and
   whether the timeout is per-file or systemic.
2. Instrument the re-request loop: interval, backoff shape, and provider response per
   attempt. `rerequestCount` alone cannot distinguish "polling a slow success" from
   "hammering a provider into refusing".
3. Only then decide whether `rootBackgroundCap` / `globalOutstandingLimit` starving 32
   candidates behind 1 stuck download is the right shape. One stuck file currently
   blocks the entire enrichment queue; whether that is correct backpressure or a
   head-of-line-blocking defect depends on (2).

This stage blocks Stage 3's headline figure: **the enrichment storm that plan 0064
Stage 3 optimises cannot be observed on this machine until enrichment runs at all.**

---

## Stage 4 — Make the regression permanent

`orderQueryCount` is currently projection-internal state readable only by a test
(`Otos/Services/CatalogProjection.swift:44`). It is the single best metric this codebase
has for the Stage 3 defect and it never reaches a log.

1. Emit it as a field on the existing publication diagnostic, so a capture shows the
   Stage 3 property directly instead of requiring inference.
2. Add the scale test that does not exist: ~25k assets, enrichment storm, asserting both
   `orderQueryCount` **and** a `SidebarSelectionToPaint` budget. Gate it behind the
   existing smoke/scale mechanism if it is too slow for the default suite — but it must
   be runnable by `script/verify.sh` in some mode, or it will rot.
3. Replace the fixed sleeps in `ProjectionEnrichmentCoalescingTests`
   (`Task.sleep(150ms)`, `Task.sleep(300ms)`, and the exact `finalCount == afterDetail + 1`)
   with condition waits. This is the same shape plan 0063 spent a whole PR removing from
   `FileMaterializationTests` because it raced under parallel load; it should not have
   been reintroduced three PRs later.

---

## Stage 5 — Tooling and process defects found in passing

These are small, independently landable, and each cost real time during this review.

1. **`smoke-run.sh --verify` cannot succeed on this machine.** The default root
   `$HOME/Desktop/OneDrive/Pictures` resolves to
   `…/CloudStorage/OneDrive-Personal/Pictures`, which is an *ancestor* of the already
   registered `…/Pictures/Camera Roll` root, so seeding fails:

   ```
   op=catalog.library.ensure phase=error
     error=overlappingRoot(existingPath: …/Pictures/Camera Roll,
                           relationship: LibraryRootRelationship.ancestor)
   ```

   The overlap validation is behaving correctly; the *default* is wrong. Either point the
   default at the registered root or have the seed treat `overlappingRoot` against an
   existing descendant as success.

2. **`main` was red and merged onto.** PR #136's own body records `script/verify.sh`
   exiting 65 from five pre-existing failures on `main`; #138 restored green a day later.
   #135 and #136 therefore both merged against a red baseline, which is precisely when a
   real regression hides. Add the rule to `CLAUDE.md` under Git/CI: **a red `main` blocks
   merge of anything except the fix that greens it**, and a PR that observes a red
   baseline opens that fix first.

3. **Doc the `.debug` retention fact.** `docs/adr/0015-observability.md` should state
   plainly that `.debug` is not persisted on macOS without a configuration profile, so the
   next person does not build another instrument that cannot be read.

---

## Explicitly out of scope

- **`CatalogStore.swift` is 3,982 lines** and now owns roots, enrichment claims, import
  settlement, filesystem events, planning changes, thumbnails, and journals. That is more
  than one question, and it is the file most likely to become the wrong boundary. It is
  *not* a lint problem and must not be split to satisfy `file_length`. Raising it here so
  it is recorded, not to act on it in this plan.
- **The four-way `claimGroups` cross-product** (`Otos/Stores/CatalogStore.swift:~1020`).
  Root kind now feeds two orthogonal partitions (claim priority, hash requirement) and
  `INDEXED BY` forces a cross-product; group 4 (`fixed ∩ hashNotRequired`) is structurally
  empty. Correct today. If a third root-kind-derived partition appears, that is the signal
  to replace N derived predicates with one per-kind policy table.

## Sequencing

Stage 0 → Stage 3 → Stage 4 is the critical path; Stage 3 cannot produce its headline
figure without Stage 0. Stages 1, 2, and 5 are independent and can land in any order.
