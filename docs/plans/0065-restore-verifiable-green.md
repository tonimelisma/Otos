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
| 0 — instrumentation readable | ✅ ready | New `debugOperation` helper, 13 call sites reclassified, a SwiftLint rule, ADR policy |
| 1 — freeze index contract | ✅ ready | Inline frozen SQL into migration bodies + a contract test |
| 2a — delete the Swift twin | ✅ ready | Compare stored-before vs stored-after; deletes the recompute |
| 2b — one `hashRequired` | ✅ ready | Carry the claim decision; deletes two caches and an accessor |
| 4 — lock the regression | ✅ ready | One log field + a quiescence helper + an on-disk scale test |
| 5 — tooling and process | ✅ ready | Smoke-script defaults and PID scoping + a CLAUDE.md rule |

Each ready stage states its root cause, the fix in code, the test that proves it, and — where
it applies — **the way to verify the fix is real**: make the mistake deliberately and watch
the new guard catch it. A guard that has never fired has proven nothing.
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

### Root cause — not four call sites, thirteen, and an API that permits them

Promoting four `.debug` calls to `.notice` would be a bandaid. The actual defect is in the
logging API.

`Otos/Support/Instrumentation.swift:57-80` defines the structured boundary shape
(`op=` / `phase=` / `key=value`) as exactly two helpers — `noticeOperation` and
`errorOperation`. There is **no debug-level equivalent**. So anyone who wants a
debug-level structured line hand-writes the `op=…` string into `Logger.debug(...)`,
bypassing the helper entirely. **Thirteen sites do this today:**

| site | operation |
|---|---|
| `CatalogStore.swift:364` | `catalog.namespaceMutation phase=record` |
| `CatalogStore.swift:775` | `catalog.store.query.tileDetail phase=finish` |
| `CatalogStore.swift:2820` | `catalog.planningChange phase=emit` |
| `UIJankDiagnostics.swift:91,108` | `ui.sidebarSelectionToPaint phase=start/finish` |
| `MediaGridBridge.swift:569,582,594,604` | `ui.mediaGrid.focusTarget phase=park/scroll` |
| `MediaOperationCoordinator.swift:401` | `import.coordinator phase=receive` |
| `MediaOperationCoordinator.swift:486` | `import.coordinator phase=refresh` |
| `EnrichmentCoordinatorWorkSelection.swift:508` | `catalog.enrichment.scheduler phase=route` |
| `MaterializationCoordinator.swift:692` | `materialization.request phase=…` |

Not all are mistakes. `MaterializationCoordinator.swift:689-693` is **correct and
deliberate** — an explicit `isNotice` switch routing important phases to
`noticeOperation` and chatter to debug. That is the pattern the others should follow and
cannot, because no helper exists for the debug half.

### This affects two conclusions in the 2026-08-01 field diagnosis

Two of the thirteen are lines that diagnosis reasoned from:

- **§2** quotes `op=catalog.enrichment.scheduler phase=route` as its evidence that
  enrichment throughput is materialization-bound. That line is `.debug`.
- **§6** concludes the import coordinator "received no planning change at all for six
  minutes" from finding **zero** `op=import.coordinator phase=refresh` lines. That line is
  `.debug` (`MediaOperationCoordinator.swift:486`).

If debug lines were not captured, §6's zero was guaranteed by the log level rather than by
behaviour, and the conclusion does not follow from the evidence given.

**This is unresolved and must not be asserted either way.** The diagnosis states debug
capture was verified working; the measurement in the research note (§2) found zero Debug
messages retrievable. Both cannot be right. Resolving it is part of this stage: after the
fix, re-run and confirm whether `phase=refresh` appears. If it does, §6's premise was an
artifact and the *conclusion* (subscription correctly wired) still stands on the
independent `.notice` `phase=subscribed` markers — but the reasoning must be corrected in
the diagnosis document.

### The fix

**1. Add the missing helper.** In `Otos/Support/Instrumentation.swift`, beside
`noticeOperation` / `errorOperation`:

```swift
/// Debug-level twin of `noticeOperation` for signals we accept losing (per-frame or
/// per-asset chatter). Never use for a signal named in docs/requirements.md as a
/// diagnostic contract — macOS does not persist `.debug`, so such a signal would be
/// unreadable. See ADR 0015.
nonisolated func debugOperation(_ operation: String, phase: String, fields: [String: String] = [:]) {
    if fields.isEmpty {
        debug("op=\(operation, privacy: .public) phase=\(phase, privacy: .public)")
        return
    }
    let pairs = otosLogFields(fields)
    debug("op=\(operation, privacy: .public) phase=\(phase, privacy: .public) \(pairs, privacy: .public)")
}
```

**2. Convert all thirteen sites**, classifying each as contract or chatter:

- **Contract → `noticeOperation`:** `ui.sidebarSelectionToPaint` (both phases),
  `catalog.planningChange phase=emit`, `import.coordinator phase=receive`,
  `import.coordinator phase=refresh`, `catalog.enrichment.scheduler phase=route`. These are
  per-user-intent, per-occupancy-change, or per-claim-cycle — not per-frame — so the volume
  argument for `.debug` does not hold, and each is something a capture must be able to
  answer.
- **Chatter → `debugOperation`:** `ui.mediaGrid.focusTarget` (all four),
  `catalog.namespaceMutation phase=record`, `catalog.store.query.tileDetail phase=finish`,
  and the debug half of `MaterializationCoordinator`'s existing `isNotice` switch.

**3. Make the accidental version impossible.** `.swiftlint.yml` has no `custom_rules`
block; add one:

```yaml
custom_rules:
  structured_log_via_helper:
    name: "Structured op= log must use an Operation helper"
    regex: '\.(debug|info)\(\s*\n?\s*"[^"]*op='
    message: "Emit op=/phase= lines through noticeOperation/errorOperation/debugOperation, never a hand-rolled .debug(\"op=…\") string — level then becomes a deliberate choice instead of an accident."
    severity: error
```

This is **lint, not a source-reading test**, so it does not violate the CI prohibition on
tests that assert on source text — and unlike a runtime test it makes the mistake
unrepresentable rather than merely detected. Verify the regex against all thirteen sites
before and after conversion: it must flag 13 before, 0 after.

**4. Write the policy down.** `docs/adr/0015-observability.md` currently says nothing about
levels. Add: *a signal named in `docs/requirements.md` as a diagnostic contract is emitted
at `.notice` or above; `.debug` is for signals we accept losing; macOS does not persist
`.debug` for a subsystem without a configuration profile, so a `.debug` contract signal is
unreadable by construction.*

### Why not simply capture at `--level debug` instead?

Because it does not work. `script/logs.sh show` already passes `--info --debug` and still
returned zero Debug messages (research note §2) — the messages are never persisted, so
there is nothing for a later capture to retrieve. Raising the capture level would also make
every per-frame `focusTarget` line durable, which is the opposite of what the split is for.
The level of the *emitter* is the thing that has to be right.

### Done when

1. SwiftLint reports zero `structured_log_via_helper` violations, and reported 13 before.
2. A `script/smoke-run.sh --jank` capture with one sidebar scope change contains
   `op=ui.sidebarSelectionToPaint phase=finish ms=…`.
3. A scan-triggered capture contains matching `catalog.planningChange phase=emit` and
   `import.coordinator phase=receive` lines with the same `occupancyRevision`.
4. The §2/§6 question above is resolved in writing, in
   `docs/research/2026-08-01-removable-import-and-grid-field-diagnosis.md`.

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

### Root cause — migrations are not immutable

A test that pins the current text would be a bandaid: it detects drift after someone
writes it, and only if they remember the test means what it says. The real defect is
structural.

**A migration body must be a frozen historical artifact. These are not.**
`CatalogStorePersistence.swift:199-217`:

```swift
migrator.registerMigration("v12_xxh3_content_hashes") { db in
    try addContentHashColumns(db)
    try db.drop(index: "idx_media_asset_needs_enrichment_global")
    try db.drop(index: "idx_media_asset_needs_enrichment_root")
    try createEnrichmentClaimIndexes(db, includeContentHash: true)   // ← current code
}
```

`createEnrichmentClaimIndexes` calls `EnrichmentLeaseGateway.stalenessSQLPredicate(...)`,
which is **live production code that the query path also uses**. Editing that function
silently rewrites what v12 *would have* produced — so a fresh database and a shipped
database diverge, and no test built from the migrator can see it. The same is true of
v13 and of every other migration that delegates to a shared builder.

This is a general hazard that happens to be load-bearing here only because `INDEXED BY`
turns the divergence into a hard prepare-time failure. Elsewhere it would be a silently
wrong index.

### The fix — two parts, in this order

**1. Freeze the migration bodies (the actual fix).** Inline the literal SQL into each
migration so no migration body calls a shared builder. v12 becomes:

```swift
// FROZEN 2026-07. This is the SQL that shipped; it is a historical record of what
// existing catalogs contain, not a description of current behaviour. Never regenerate
// it from EnrichmentLeaseGateway, and never "fix" it to match a newer predicate — doing
// so rewrites history for fresh installs only and silently diverges them from every
// catalog in the field. A new predicate needs a NEW migration.
migrator.registerMigration("v12_xxh3_content_hashes") { db in
    try addContentHashColumns(db)
    try db.drop(index: "idx_media_asset_needs_enrichment_global")
    try db.drop(index: "idx_media_asset_needs_enrichment_root")
    try db.execute(sql: """
        CREATE INDEX idx_media_asset_needs_enrichment_global
        ON media_asset(best_capture_unix DESC, library_root_id, relative_path)
        WHERE enriched_source_size IS NULL
           OR enriched_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(enriched_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(enriched_source_mtime, -1)
           OR content_hash_xxh3_128 IS NULL
           OR length(content_hash_xxh3_128) <> 16
           OR content_hash_source_size IS NULL
           OR content_hash_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(content_hash_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(content_hash_source_mtime, -1)
        """)
    // …and the _root twin, same WHERE, keyed (library_root_id, best_capture_unix DESC, relative_path)
}
```

**The literal text above is not invented for this plan** — it was extracted from the live
production catalog with
`SELECT sql FROM sqlite_master WHERE name='idx_media_asset_needs_enrichment_root'`, so it
is exactly what field databases contain. Use that query, not the current Swift builder, as
the source when writing this. Do the same for v13's metadata-only pair.

`createEnrichmentClaimIndexes` then serves only fresh-schema creation and can evolve
freely — which is the point: **the query path and the migration history stop sharing a
mutable definition.**

**2. Then add the contract test** (`OtosTests/EnrichmentClaimIndexContractTests.swift`),
which is now cheap because the frozen text lives in production:

- Migrate a fresh database, then assert the stored DDL
  (`SELECT sql FROM sqlite_master WHERE name = …`) for both v12 index names still implies
  the current `stalenessSQLPredicate(hashRequired: true)` — by preparing the real root and
  global claim queries and asserting `EXPLAIN QUERY PLAN` names the index.
- Same for the metadata-only pair against `hashRequired: false`.
- **The negative twin:** build the same predicate re-parenthesized as `(A) OR (B)`, assert
  preparation *fails*. Without this the frozen strings look like redundant coverage and
  the next person deletes them. Confirmed failing with `no query solution` on SQLite
  3.54.0 (research note §1a).

### Done when

A junior dev can verify the fix by editing a space into
`metadataStalenessSQLPredicate()`: the build still succeeds, the migration text is
untouched, and the contract test fails loudly with the index name in the message. Before
this change, that same edit is silent.
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

#### The fix

Delete the twin and ask the database. The columns are `STORED`, so the post-write values
are readable — the correct move is to compare **stored before** against **stored after**,
never Swift's guess against stored.

Today `applyEnrichmentResult` (`CatalogStore.swift:1336-1368`) already does a pre-write
`SELECT` for `thumbnail_path`; it was widened to fetch the ordering columns too. Keep that
`SELECT`, drop the recompute, and add a post-write read:

```swift
// Pre-write (already present) — keep, it also supplies oldRow.thumbnailPath.
let oldRow: EnrichmentOverlayBeforeWrite? = try Row.fetchOne(db, sql: """
    SELECT best_capture_unix, best_kind, best_format, thumbnail_path
    FROM media_asset WHERE library_root_id = ? AND relative_path = ?
    """, arguments: [rootID, result.id.relativePath.rawValue])
    .map(EnrichmentOverlayBeforeWrite.init(row:))

try writeEnrichmentOverlay(result, libraryRootID: rootID, db: db)

// Post-write: SQLite recomputed the STORED generated columns. Ask it what they are
// rather than predicting them — the COALESCE chain lives in the schema
// (CatalogStorePersistence.swift:1288-1299) and must have exactly one owner.
let newRow = try Row.fetchOne(db, sql: """
    SELECT best_capture_unix, best_kind, best_format
    FROM media_asset WHERE library_root_id = ? AND relative_path = ?
    """, arguments: [rootID, result.id.relativePath.rawValue])

if let old = oldRow, let newRow,
   old.bestCaptureUnix != newRow["best_capture_unix"] as Double?
   || old.bestKind != newRow["best_kind"] as String?
   || old.bestFormat != newRow["best_format"] as String?
{
    outcome.structureChanged = true
}
```

`EnrichmentOverlayBeforeWrite` then sheds `createdAtUnix`, `contentModifiedAtUnix`, `kind`,
and `format` — they existed only to feed the recompute — leaving the four columns actually
used.

`RETURNING best_capture_unix, best_kind, best_format` on the existing `UPDATE` is the
tidier single-statement form and GRDB supports it (SQLite 3.35+). Prefer it **if** it is
straightforward in `writeEnrichmentOverlay`, which currently uses `db.execute`; the
two-read version above is equally correct and is the safe default. Either way the cost is
one extra PK lookup on batches averaging ~2 rows.

#### The test that proves it

The current fixture cannot fail, so write one where Swift's guess and the database
disagree — enrich an asset whose `ts_original` is **cleared** by the new result while
`created_at_unix` still holds a different value. The database recomputes `best_capture`
from `created_at_unix`; a naive twin that only inspects `result.timestampFacts` sees
"nothing set" and can easily conclude "unchanged".

```
given  an asset with ts_original = T1 and created_at_unix = T0 (T0 ≠ T1)
when   an enrichment result arrives with all timestampFacts nil
then   the database's best_capture_unix moves T1 → T0
and    applyEnrichmentBatch must emit .catalogChanged, not .assetsDetailChanged
```

Run this test against the **old** implementation first and confirm it fails. A regression
test that never failed has proven nothing.

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

#### The fix

The store already decides this per row and then discards the decision; the coordinator
then guesses it back. Carry it instead.

**1. Introduce a claim result type.** `CatalogStore.enrichmentCandidates(prioritizing:limit:)`
(`CatalogStore.swift:849`) returns `[MediaAsset]`. Change it to return a small struct that
pairs each asset with the decision that authorised its claim:

```swift
/// An asset the Store has claimed for enrichment, together with the claim-time facts the
/// enricher must honour. `hashRequired` is decided once, by the owner of root kind, at the
/// moment the row is claimed — it is not re-derivable downstream without risking a
/// decision that disagrees with the predicate the row was actually claimed under.
nonisolated struct ClaimedEnrichmentCandidate: Sendable {
    let asset: MediaAsset
    let hashRequired: Bool
}
```

Both claim paths already have the value: `priorityEnrichmentCandidates` computes it in
`eligibleClaims` via the `isHashRequired` closure (`CatalogStore.swift:973`), and
`claimedEnrichmentCandidates` knows it per `claimGroups` entry. Thread it through both.

**2. Store it on the claim record.** `EnrichWork.shouldHash` stops being derived in
`makeWork` (`EnrichmentCoordinatorWorkSelection.swift:490`) and is passed in from the
candidate. `makeWork` and `enqueueReadyCandidate` (`:367`) take the candidate rather than a
bare `MediaAsset`.

**3. Delete the duplicate owner.** Remove `CatalogStore.removableVolumeRootPaths()`
(`CatalogStore.swift:806`), `EnrichmentCoordinator.removableRootPaths`
(`EnrichmentCoordinator.swift:173`), and the per-cycle refresh at
`EnrichmentCoordinatorWorkSelection.swift:20`. `RootRegistry.removableVolumeRootPaths` also
loses its only caller — delete it too rather than leaving an unused derivation that invites
a second opinion later.

Note that `deviceRootPaths` uses the same cache-and-re-derive shape for `isDeviceStaging`.
It is **out of scope here** — do not opportunistically refactor it. Record whether it has
the same divergence property; if it does, it is a follow-up plan, not a drive-by.

#### The test that proves it

Behaviour-preserving in the common case, so the oracle is the divergent case the old design
allowed:

```
given  a root claimed while its kind is .library (so hashRequired = true)
when   the root's kind changes to .removableVolume before the work is dispatched
then   the dispatched EnrichWork must still carry shouldHash = true
       (the value the claim predicate was based on), not the newer root-kind guess
```

Under the old design the coordinator's stale-or-fresh cache decides this independently and
can answer either way. Under the fix there is exactly one answer by construction.

Also assert the existing enrichment suite passes **unmodified** — this is a refactor, and
any test that needs editing is a signal that behaviour moved.

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

**1. Log it.** Add `orderQueryCount` to `CatalogProjectionPublicationDiagnostics`
(constructed at `CatalogProjection.swift:286`, emitted as
`op=catalog.projection.window phase=finish`). One field, alongside the existing
`assetOrderQueryMs`. A capture then answers "how many full re-sorts did N enrichment
batches cause?" directly instead of by inference. This is also what makes the Stage 3
research note writable by grep rather than by reasoning.

**2. De-flake the existing test — root cause, not longer sleeps.**
`ProjectionEnrichmentCoalescingTests` uses `Task.sleep(.milliseconds(150))` and
`(300)` to wait for projection quiescence, plus an exact
`finalCount == afterDetailOrderQueries + 1`. Raising the sleeps is the bandaid; the real
problem is that **there is no way to ask the projection whether it has settled**, so every
test invents a timing guess.

Add one to `OtosTests/AsyncTestSupport.swift`, beside the existing `waitForValues` /
`withTestTimeout` helpers:

```swift
/// Waits until the projection has no pending or in-flight publication, so a test can
/// assert on a settled `orderQueryCount` without guessing a sleep duration. Polls actor
/// state rather than sleeping a fixed interval — a fixed sleep is either flaky under
/// parallel-suite load or needlessly slow, and usually both.
func waitForProjectionQuiescence(
    _ projection: CatalogProjection,
    timeout: Duration = .seconds(5)
) async throws
```

This needs a small read-only accessor on `CatalogProjection` (`dirty == false &&
publishing == false`); `orderQueryCount` already sets the precedent for
test-observable projection state. Then replace both sleeps, and keep the exact `+ 1`
assertion — once quiescence is deterministic, exactness is correct rather than fragile.

Plan 0063 spent an entire PR removing exactly this pattern from `FileMaterializationTests`
by extracting a pure decision function. It reappeared three PRs later because the fix there
was local. A shared helper is what stops the third occurrence.

**3. Add the scale test that does not exist.** ~25k assets, enrichment storm, asserting
`orderQueryCount` **and** a `SidebarSelectionToPaint` budget. Note the honest constraint:
the existing 2,000-asset test runs in memory with 4-byte fixtures, and the field
non-linearity (62 ms → 7,034 ms for the same query) is driven by **WAL pressure**, which an
in-memory database does not reproduce. So this test must use an on-disk database and real
enrichment writes, or it will pass while the thing it guards regresses.

If that makes it too slow for the default suite, gate it behind an environment variable the
way `SmokeLibrarySeed` does — but wire it into `script/verify.sh` in some mode. A scale test
that only runs when someone remembers is a scale test that rots.

**Ordering note:** item 3 depends on Stage 0 (the `SidebarSelectionToPaint` budget is
unmeasurable until that signal is readable) and is best written after Stage 3 has produced
real numbers to set the budget from. Do not invent a budget.

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

   The overlap validation is behaving correctly; the *default* is wrong.

   **Do not** make the seed swallow `overlappingRoot` — that hides a real error class to
   fix a wrong constant. The root cause is that `smoke-run.sh:9` hardcodes
   `DEFAULT_ROOT="$HOME/Desktop/OneDrive/Pictures"`, a path that is not the registered root
   and is not derived from anything. Fix it by making the default *absent*: require the root
   as an argument or `OTOS_SMOKE_LIBRARY_ROOT`, and fail with a message naming the roots the
   catalog already has. A smoke script that silently seeds a different library than the one
   under test produces captures that look valid and are not — the same failure class as the
   dead-provider capture in Stage 3b.

   While there: `run_jank`'s `cleanup` trap calls `quit_app`, which does
   `pkill -x Otos` unconditionally. Two overlapping runs therefore have the first one's exit
   kill the second one's app mid-capture — observed during this review, and it silently
   truncated a session to a log that looked complete. Scope the kill to the PID this run
   launched.

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
