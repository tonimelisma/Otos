# Plan 0099 — Honest Import Naming And Plan Stability

Status: **not started**. Opened 2026-08-29 from a live diagnosis session against a
730-item SD card (`/Volumes/4152150790`) importing into
`…/OneDrive-Personal/Pictures/Camera Roll` (6696 assets).

This plan owns every defect, smell, and requirement uncovered in that session.
Nothing from it is deferred to memory or conversation: if an item is not fixed
here, it appears below under **Open design questions** with its options.

---

## 1. Production evidence

### 1.1 The duplicate proof (D1)

Hash-proven duplicates in the Camera Roll library (`content_hash_xxh3_128`, not
size matching):

```
103 duplicate groups · 207 files · 104 redundant copies · 48.1 GB wasted
by kind:  video 204   raw 2   image 1
```

Classifying the 102 hash-identical **video** pairs by the gap between their two
filenames leaves zero unexplained:

| Cause | Pairs | Both copies imported by Otos |
| --- | --- | --- |
| Filenames differ by exactly the video's **duration** | **23** | **23 of 23** |
| Filenames differ by exactly **7 hours** (UTC vs local) | 79 | 0 of 79 — **out of scope**: these come from OneDrive's own phone-camera upload naming the same video under a UTC-derived name. Not Otos's behavior and not this plan's concern; recorded only so the 103-group total is accounted for. |

The 23 are Otos duplicating its own import. Batch timestamps close it:

```
every one of the 23 pairs: one copy in import batch 2026-08-19 22:00:10
                           one copy in import batch 2026-08-19 22:05:10
                           exactly two distinct batches, five minutes apart
```

The 22:00 run named those videos from filesystem mtime, before enrichment reached
them. The 22:05 run, after enrichment supplied capture walls, computed different
names, found nothing at those paths, and copied all 23 again.

### 1.2 Why mtime is wrong for video

On the card, comparing the name mtime yields against the name the capture wall
yields, for all 730 rows:

```
identical filename        686 (94%)
different filename         44 (6%)   ← all 44 are videos
different day folder        0
different month folder      0

videos:  avg(mtime − capture_wall) = 17.8s   avg(duration) = 17.0s
         avg residual = 0.78s   range 6s … 87s
```

`mtime = capture_time + duration`. A video's mtime is when recording *stopped*, so
every video named before enrichment is wrong by its own length.

### 1.3 The plan-churn trace

```
21:24:14.022  import.plan finish  namingMtimeCount=730 namingSettledCount=730 copyCount=730
21:24:14.027  import.attachToReady elapsedMs=2027 copyCount=730          ← offered, Import ENABLED
21:24:14.636  occupancyRevision bump /Volumes/… reason=enrichmentNaming rev=4
21:24:14.637  presentation apply drawnKind=preparing                     ← state A
21:24:15.314  presentation apply drawnKind=ready importItems(730)        ← state C
   … card enrichment rev 4 → 28, ~1 Hz for 25 s, A↔C each cycle …
21:24:45.543  occupancyRevision bump …/Camera Roll reason=enrichmentNaming
   … destination enrichment, indefinitely …
```

40 re-plans, 37 completed, **every one `copyCount=730`**. Each costs ~480 ms
(272 ms enumerating 3056 destination entries + 208 ms planning). `namingMtimeCount`
decays 730 → 699 → 669 → … → 0 over ~25 s as enrichment lands.

### 1.4 Enrichment coverage across the catalog

```
root                          kind    n     no capture wall   never enriched
Camera Roll                   image  3513   402              0
Camera Roll                   raw    2435     2              0
Camera Roll                   video   748   177              0
Summer Photos                  image   575     1              0
Summer Photos                  video    69    69 (100%)       0
/Volumes/4152150790           image   343     0              0
/Volumes/4152150790           raw     343     0              0
/Volumes/4152150790           video    44     0              0
/Volumes/CAMERA                image   172     0              0
/Volumes/CAMERA                video     9     9 (100%)       0
DeviceStaging camera-…        all     251   251              251
```

---

## 2. Defect register

Every item carries evidence and a `file:line`. Severity: **S1** blocks merge of
anything touching import; **S2** user-visible incorrect behavior; **S3** waste or
spec drift.

### D1 — A plan is offered before source naming facts are proven · S1

`namingFactState` marks a row `.terminal` when it has a capture wall **or a durable
mtime**, so planning proceeds before enrichment has looked at the file
([MediaOperationGateway.swift:44](../../Otos/Stores/MediaOperationGateway.swift)).
"No capture wall" pre-enrichment means "we have not looked", not "none exists".
Names, and the destination mtime stamped from `ImportDestinationDate.expected`,
are then fabricated from mtime.

Because the destination name is also the dedupe key
([MediaTransferPlanner.swift:455](../../Otos/Services/MediaTransferPlanner.swift)),
the consequences are not cosmetic:
- **Duplicates** — proven, §1.1, 23 videos.
- **Silent non-import** — an mtime-derived name landing on an unrelated existing
  file whose size and second-precision mtime match reads `.skipPreexisting`, and
  that source file is never imported.

Violates ARC-046A (convergence to all-preexisting) and CLAUDE.md's "unknown dates
stay unknown until proven".

### D2 — Destination enrichment invalidates ready plans · S2

`applyEnrichmentBatch` bumps `bumpOccupancyRevision(reason: "enrichmentNaming")`
for every root whose `capture_wall_compact` changed, with no notion of role
([CatalogStore.swift:1312](../../Otos/Stores/CatalogStore.swift)).
`handlePlanningChange` then dirties every session whose **source or destination**
is that root ([MediaOperationCoordinator.swift:766](../../Otos/Services/MediaOperationCoordinator.swift)).

Enriching a file already in the library cannot change an import plan: Otos never
writes into media folders, so the filesystem namespace is untouched, and
`fetchDestinationOccupants` selects only `relative_path, byte_size,
content_modified_at_unix` — never `capture_wall_compact`
([MediaOperationGateway.swift:73](../../Otos/Stores/MediaOperationGateway.swift)).

Regresses ARC-046 ("enrichment overlay writes and identical rescans never advance
it, so planning settles while a large cloud destination keeps enriching"),
reopening the livelock fixed by PR #111 (`b662d4f`, 2026-07-11). Introduced by
`40261bf` (2026-08-20, plan 0096). **No test asserts the bump**, so nothing locks
it in.

### D3 — A re-plan destroys the plan it is replacing · S2

`scheduleBuildIfNeeded` sets `phase = .building`, overwriting `.ready(ctx)` and
discarding the `ReadyContext`
([MediaOperationCoordinator.swift:1071](../../Otos/Services/MediaOperationCoordinator.swift)).
`.building` maps to `.planning` (line 1306) → the mapper's `preparing`
fall-through → "Checking the card…"
([ImportBarPresentation.swift:171](../../Otos/Views/ImportBarPresentation.swift)).
Four other sites do the same via `.inventory` (645, 1136, 1198, 1211) and one via
`.waitingForMetadata` (1267).

State A is therefore overloaded: "no plan has ever existed" and "a valid plan
exists but a newer one is in flight" draw identically.

### D4 — MTP staging is capped at 16 and the remainder is silently dropped · S1

`runCameraCatalogFlow` offers every catalog item as a staging seed
([CatalogWindowViewModelSourceMonitoring.swift:95](../../Otos/ViewModels/CatalogWindowViewModelSourceMonitoring.swift)),
but `stageDevice` accepts only `seeds.prefix(available)` where
`available = globalOutstandingLimit − materializationDemands.count`, and
`globalOutstandingLimit` is `MaterializationAdmissionPolicy.production.globalConcurrency` = **16**
([EnrichmentCoordinator.swift:317](../../Otos/Services/EnrichmentCoordinator.swift),
[MaterializationAdmissionPolicy.swift:36](../../Otos/Services/MaterializationAdmissionPolicy.swift)).

Nothing recovers the dropped seeds:
- `runCameraCatalogFlow` is a single pass per attach (`onAttach`/`onDetach` only;
  no update callback).
- An unstaged device file fails `lstat`, so `FileMaterialization.status` returns
  `.unknown`, which only schedules a 1 s readiness retry and releases the claim —
  it never creates a materialization demand
  ([EnrichmentCoordinatorWorkSelection.swift:80](../../Otos/Services/EnrichmentCoordinatorWorkSelection.swift)).
- Completing a download frees a slot but re-signals nothing that would stage seed 17.

**A camera with more than ~16 items never fully stages and therefore never fully
enriches.** Contradicts ENR-011's eager-staging intent.

### D5 — MTP import is not gated on naming facts · S1

`shouldWaitForMetadata` excludes `.deviceMTP` outright
([MediaOperationCoordinator.swift:1249](../../Otos/Services/MediaOperationCoordinator.swift)),
so a camera import is offered regardless of staging or enrichment state.

### D6 — MTP naming uses a modification-first camera date · S2

`ICCameraFile` exposes six dates. `CameraFileDate` reduces them to `captureDate`
(creation-first) and `modificationDate` (**modification-first**,
[CameraSourceMonitor.swift:100](../../Otos/Services/CameraSourceMonitor.swift)).
Only `modificationDate` reaches naming, as `content_modified_at_unix`;
`captureDate` goes to `ScannedMediaFile.createdAt` and the staging seed, and
`fetchPlanningSourceMedia` never selects `created_at`. For video that is again
end-of-recording. All are absolute `Date`s and cannot yield a local-floating wall
clock regardless — the same reason ENR-012 excludes UTC-anchored candidates.

### D7 — Videos with no local-floating wall stay wrong after full enrichment · S2

ENR-012 excludes UTC-anchored timestamps from `capture_wall_compact`. Coverage
(§1.4): **100%** of Summer Photos's 69 videos and of CAMERA's 9 videos, and 24% of
Camera Roll's 748, have no wall after successful enrichment. They name from mtime
= capture + duration — wrong by the video's length, permanently. The naming gate
(D1) makes this *proven* rather than *assumed*; it does not make it correct.
**Owner decision 2026-08-29 (O7): derive the video capture wall as
`mtime − duration`.** See Increment 5.

### D9 — An unreadable source file has no honest outcome · S3

Enrichment terminates definitively for normal media: `ReadOutcome` is
`.parsed` / `.unsupported` / `.readFailure`, and `shouldRetry` is true **only** for
`.readFailure`; a corrupt or unparseable file returns definitively and is written,
and zero-byte files are stamped by `finishEmptySource`
([EnrichmentCoordinatorCompletion.swift:57](../../Otos/Services/EnrichmentCoordinatorCompletion.swift)).

`.readFailure` is set in exactly one place: when opening the file's byte source
throws (`MediaMetadata.swift`, `ParserProvenance(status: .failed)`). On an
**available** removable volume that is one of three things, none transient:

| Scenario | Already handled? |
| --- | --- |
| File deleted between scan and enrichment | Yes — the reconciler purges the row |
| Card pulled | Yes — root goes `.unavailable`, `releaseEnrichmentClaimsForRoot` runs at detach ([CatalogStore.swift:1926](../../Otos/Stores/CatalogStore.swift)), and both claim-selection functions filter `availability == .available` ([RootRegistry.swift:132](../../Otos/Stores/RootRegistry.swift), `:151`) |
| Failing hardware | No |

`shouldRetry` is the metadata package's generic contract — meaningful for a
network byte source, meaningless for a local card. **There is no retry and no
backoff to add here.** What is missing is the third row: a file on a healthy mount
whose bytes cannot be opened can be neither enriched nor copied, and today it
would sit `.pending` forever, holding the D1 gate with nothing shown to the user.

---

## 3. Smell register

| # | Smell | Where | Disposition |
| --- | --- | --- | --- |
| S1 | `MediaOperationSourceState.needsReplan` is dead — never produced; only mapped in `SidebarSelectionPolicy` and asserted in `ImportBarPresentationTests:97` (a tested-but-unreachable state) | [MediaOperationModels.swift:380](../../Otos/Models/MediaOperationModels.swift) | Realize it as D3's "refreshing" state, or delete it and its test |
| S2 | One scalar `occupancyRevision` answers two questions — "which paths are occupied" and "what would we name this" — so a source-side naming fact invalidates destination-side planning | `RootRuntimeState`, `CatalogStore` | Structural cause of D2; fix in Increment 1 |
| S3 | `namingMtimeCount` is logged but nothing gates on it — a tripwire wired to nothing; it carried D1's evidence for nine days unread | [MediaOperationCoordinator.swift:1174](../../Otos/Services/MediaOperationCoordinator.swift) | Becomes the gate's own counter in Increment 2 |
| S4 | `stageDevice`'s silent drop emits no diagnostic at all | [EnrichmentCoordinator.swift:317](../../Otos/Services/EnrichmentCoordinator.swift) | Add `op=enrichment.stageDevice phase=…` with accepted/dropped counts |
| S5 | ARC-046 and ARC-057/ADR 0026 contradict each other on whether enrichment advances occupancy | `docs/requirements.md` | Resolve: they describe two different facts (Increment 1) |
| S6 | `RootPlanningChange` has exactly one subscriber, and `planRevision` is pull-only (`LibraryReorganizationRunner:263`) — the push/pull split is undocumented | `architecture.md` | Document in Increment 1 |
| S7 | No test covers ARC-046's enrichment clause — the clause that regressed. `noOpPlanRevisionChurnDoesNotDisturbReadyPlan` exercises only `bumpPlanRevision` | [MediaOperationCoordinatorTests.swift:318](../../OtosTests/MediaOperationCoordinatorTests.swift) | Write it in Increment 1 |
| S8 | `aDurableMtimeIsTerminalBeforeEnrichmentRuns` encodes D1 in its own name | [ImportPlanningNamingFactsTests.swift:111](../../OtosTests/ImportPlanningNamingFactsTests.swift) | Invert in Increment 2 |
| S9 | The enrichment retry ledger is in-memory only; there is no durable attempt/failure fact | [EnrichmentCoordinator.swift:142](../../Otos/Services/EnrichmentCoordinator.swift) | No change — see D9: nothing on a removable volume is transient |
| S11 | Viewport enrichment priority outranks everything, so scrolling a library during a card's enrichment can interleave and delay the gate | [EnrichmentCoordinatorWorkSelection.swift:251](../../Otos/Services/EnrichmentCoordinatorWorkSelection.swift) | Bounded by viewport size; specify in ENR-011 rather than change |
| S12 | `import-bar.md` state A conflates "never had a plan" with "refreshing a plan"; its state-inventory row 1 lists `needsReplan` as folding into A | `docs/design/import-bar.md` | Spec change in Increment 3 |
| S13 | ~480 ms × ~1 Hz of wasted enumerate+plan | — | **Resolved by D1+D2; no debounce, no coalescing, no new machinery.** Recorded so nobody adds scale machinery for it later |

---

## 4. Requirements and invariants established by the owner

Captured here verbatim in intent; each maps to a doc home below.

| # | Directive | Home |
| --- | --- | --- |
| **O1** | A destination filename may never be picked before enrichment has run for that source file. Waiting is a correctness requirement, not a UX tradeoff — the alternative creates duplicates or false-preexisting skips, which is data loss. | ARC-057 rewrite, ADR 0026 amendment |
| **O2** | Attached sources are fully enriched before anything else. | ENR-011 (already law and implemented — see §5.1) |
| **O3** | Removable volumes have no materialization limitation: enrichment of source media is guaranteed to complete. Plan for that; do not design around cloud indeterminacy on a card. | ADR 0009 / ADR 0026 rationale |
| **O4** | MTP: stage every file so it can be enriched, keep the staged bytes (they are already downloaded), and do not allow import to start until all are enriched. | New ARC row + ADR 0009; Increment 4 |
| **O5** | Enrichment overlay writes must not invalidate destination-side import planning. | ARC-046 (restore) |
| **O6** | Every issue and smell found in diagnosis belongs in the plan, not in conversation. | This document |
| **O7** | For videos, name from `mtime − length`. A video's mtime is when recording stopped, so the capture instant is the mtime less its duration. | ENR-012, `CaptureWallClock`, Increment 5 |

---

## 5. What is already correct — do not "fix" these

Recorded so the plan does not churn on settled ground.

### 5.1 Removable-source enrichment priority already exists (O2)

`availableRootIDsByRemovablePriority()` claims removable roots before fixed roots
in explicit tiers ([CatalogStore.swift:1077](../../Otos/Stores/CatalogStore.swift)),
which is **ENR-011**, with a passing test
(`CatalogStoreEnrichmentClaimTests#fallbackEnrichmentClaimsRemovableSourcesBeforeFixedLibraries`).
The 2026-08-29 trace confirms it in production: card enrichment ran 21:24:14–21:24:39,
the library's only from 21:24:45 — sequential. **No work needed**, only the S11
specification.

### 5.2 "Enrichment has looked" is already durable — no migration

`writeEnrichmentOverlay` writes `enriched_source_mtime` unconditionally on every
completion path
([CatalogStorePersistence.swift:905](../../Otos/Stores/CatalogStorePersistence.swift)),
while `capture_wall_compact` is nullable. So *looked and found no embedded date*
is already distinguishable from *never looked*, using the first two clauses of
`metadataStalenessSQLPredicate()`. **Increment 2 needs no schema change.**

### 5.3 The gate already precedes the expensive build

`shouldWaitForMetadata` is called before `planBuilder.build`
([MediaOperationCoordinator.swift:1157](../../Otos/Services/MediaOperationCoordinator.swift)),
so holding costs no enumeration.

### 5.4 The gate is correctly policy-conditional

`needsDate(policy:)` is false under `.original` naming and `.none` folders
([MediaTransferPlanner.swift:43](../../Otos/Services/MediaTransferPlanner.swift)).
The default is `.yearMonth` + `.captureDateTime`, so the gate applies by default
and correctly does not apply to original-name imports.

### 5.5 Overwrite safety is not at risk

Exclusive publication (`renamex_np(RENAME_EXCL)` → hard-link → check-then-act,
ARC-048) makes overwriting impossible; a race returns foreign-occupant. Cross-plan
name collisions are held by ADR 0021's reservation ledger, which is not
occupancy-driven. Real destination changes still re-plan through the ten other
`bumpOccupancyRevision` call sites. **None of these is weakened by D2's fix.**

### 5.6 Blast radius of the occupancy change is bounded

`occupancyRevision` has exactly five read sites: snapshot construction
(`CatalogStore:465-466`), `lastSeenOccupancy` (`Coordinator:745-746`), session
creation (`Coordinator:847`), and the two post-build revalidations
(`Coordinator:1189-1190`). The planning-change stream has one subscriber.

---

## 6. Increments

### Increment 1 — Stop destination churn (D2, S2, S5, S6, S7)

Behavior-preserving in intent: **every existing test stays green unmodified.**

Per-file inventory:
- `Otos/Stores/RootRuntimeState.swift` — split the scalar: `namespaceRevision`
  (paths on disk) and `namingRevision` (overlay naming). `planRevision` retained
  for reorg's pull-based staleness.
- `Otos/Stores/CatalogStore.swift` — `bumpOccupancyRevision` splits into
  `bumpNamespaceRevision` / `bumpNamingRevision`; line 1312 routes to the latter;
  the other ten call sites route to the former. `emitPlanningChange` carries both.
- `Otos/Models/MediaOperationModels.swift` — `RootPlanningChange` carries both
  revisions.
- `Otos/Services/MediaOperationCoordinator.swift` — `handlePlanningChange`
  re-plans a session when its **destination's** `namespaceRevision` moves, or its
  **source's** `namespaceRevision` moves. Post-build revalidation (1189-1190)
  compares the same pair per role. `lastSeenOccupancy` becomes a per-role pair.

Validation probes:
- New test: an enrichment naming write on the destination root leaves the source's
  ready plan and its generation untouched (the ARC-046 clause, S7).
- New test: a real destination namespace change still re-plans.
- Existing `noOpPlanRevisionChurnDoesNotDisturbReadyPlan` unchanged and green.
- Runtime differential: re-run the card scenario, assert zero
  `plan.rebuild phase=schedule` entries attributable to destination enrichment.

Fallback: if the two-revision split proves to touch more than the five read sites,
fall back to routing line 1312 by root kind (library → naming only) and record why.

### Increment 2 — Gate the offer on proven naming facts (D1, S3, S8)

**Sequencing note for Increment 1.** Once the gate exists, source-side *naming*
invalidation becomes redundant: after the gate, a source row's wall can change only
if enrichment re-runs, which requires the staleness predicate to fire, which
requires a size/mtime change — which is itself a namespace change that bumps
`namespaceRevision`. Increment 1 should therefore not build coordinator machinery
to consume `namingRevision`; the store still records it (reorg reads `planRevision`
by pull), but the import coordinator keys on `namespaceRevision` per role only.

Per-file inventory:
- `Otos/Stores/MediaOperationGateway.swift` — `namingFactState` derives from
  *looked-at*, not *has-any-date*: `.settled` when the row is current; `.terminal`
  when a capture wall exists **or** enrichment has looked and found none
  (`enriched_source_size`/`enriched_source_mtime` present); `.pending` otherwise.
- `Otos/Services/MediaOperationCoordinator.swift` — `shouldWaitForMetadata`'s
  `done`/`total` become the looked-at counters (S3), feeding state A's determinate
  progress honestly.
- `OtosTests/ImportPlanningNamingFactsTests.swift` — invert
  `aDurableMtimeIsTerminalBeforeEnrichmentRuns`;
  `aKnownCaptureWallIsTerminalEvenWhenEnrichmentCanNeverSettle` **stays green**
  (that half of ADR 0026 is correct).

Validation probes:
- Reproduce D1: a card whose videos are unenriched must not reach Ready; after
  enrichment it reaches Ready with capture-wall names.
- Convergence proof (ARC-046A): import, re-plan, assert `skipPreexisting` for
  every entry — the assertion the 23 duplicates would have failed.
- Adversarial: a row that can never be enriched (Q3's answer) does not wait forever.
- Adversarial: two cards into one destination, one held in the gate, must not lose
  names to the other (ADR 0021 C1 shape) — a gated card publishes no claims.

### Increment 3 — A refresh is not a first check (D3, S1, S12)

Per-file inventory:
- `Otos/Services/MediaOperationCoordinator.swift` — add
  `SourceSession.lastReadyContext`, written in the same transaction as
  `phase = .ready`, cleared only by a new `AttachmentGeneration` or execution
  start. Mirrors the existing `lastCompletion` / `lastProgress` pattern and ADR
  0024's single-writer rule. `presentation(for:)` falls back to it for
  `.building` / `.inventory` / `.waitingForMetadata`.
- `Otos/Models/MediaOperationModels.swift` — either realize `needsReplan` as the
  published refreshing state or delete it with its test (S1).
- `docs/design/import-bar.md` — state A means "no plan has ever existed for this
  attachment"; a re-plan holds C. Update the state-inventory row 1 and the
  A section. Cite DES-018/DES-053 (fixed height across states), DES-030/DES-032
  (honest numbers or none), DES-035 (no planner vocabulary).

Validation probe: runtime differential — the card scenario shows no
`drawnKind=preparing` after the first Ready for the same attachment.

### Increment 4 — MTP parity (D4, D5, D6, S4, O4)

Per-file inventory:
- `Otos/Services/EnrichmentCoordinator.swift` — `stageDevice` retains the full
  seed set as a durable pending queue and refills from it as demands complete,
  instead of `seeds.prefix(available)` discarding the remainder; emit the
  accepted/dropped/queued diagnostic (S4).
- `Otos/Services/MediaOperationCoordinator.swift` — remove the `.deviceMTP`
  exclusion at line 1249 so cameras use the same naming gate (D5), gated on
  staging completeness.
- `Otos/Services/CameraSourceMonitor.swift` — stop naming from a
  modification-first date; carry `captureDate` into the naming path, or rely on
  enriched staged bytes for `capture_wall_compact` and treat the camera date as a
  fallback of last resort (D6).

Validation probes:
- A camera with >16 items stages and enriches **all** of them.
- A camera import is not offered until every item is enriched.
- Diagnostic asserts accepted + queued = offered, dropped = 0.

**Disk-floor interaction — must be designed, not discovered.** `DeviceStagingRegistry`
refuses to stage below a 10 GB free-space floor and returns `.insufficientLocalSpace`,
which for device work retries every 60 s **forever** — `retryWorkIfNeeded` gives up
after 3 attempts for other outcomes but never for this one
([EnrichmentCoordinatorCompletion.swift:167](../../Otos/Services/EnrichmentCoordinatorCompletion.swift)).
Combined with D5's gate (no import until everything is enriched), a camera whose
staging cannot complete for disk reasons blocks import indefinitely — and importing
would not free the space anyway, since staging is separate from the library copy.
Per O4 the answer is not a partial import: the condition is **surfaced** as its own
state with a named cause ("not enough disk to prepare the camera"), never an
indefinite silent wait. Validation probe: with the floor breached, the bar states
the cause and does not sit in state A.

Risk: this increment cannot be verified without a physical camera. If no device is
available in the agent environment, record the limitation, cover the queue
mechanics with unit tests against a fake session, and note the residual as an
after-DoD item.

---

### Increment 5 — Derived video capture wall (D7, O7)

A video's mtime is when recording stopped. Where enrichment proves no
local-floating embedded wall exists, derive the capture wall as
`mtime − duration_seconds` rendered in the local time zone, and store it as the
one capture-wall truth with its own precision token so it is self-identifying and
honest.

Per-file inventory:
- `Otos/Models/CaptureWallClock.swift` — a new precision case (e.g.
  `derivedFromDuration`) alongside `localFloating` / `localWithOffset`;
  `select(from:)` gains the derivation as the last resort for video.
- `Otos/Services/MediaEnricher.swift` / `CatalogStorePersistence.writeEnrichmentOverlay`
  — the derivation runs at the enrichment write, so `capture_wall_compact` remains
  the single stored truth (per `8b011c8`, "capture timestamps have one stored
  truth, not two"). No naming-time computation.
- `docs/requirements.md` ENR-012 — the derived candidate and its precision.

**Drift constraint — the design's hard part.** Import stamps the destination mtime
from `ImportDestinationDate.expected` = capture wall, so a video imported under a
derived wall would land with `mtime == derived wall`.

A "never re-derive a stored derived wall" guard does **not** save this, because the
destination is a *different row* with no stored wall — and overlay reuse cannot
carry the source's wall across either: `settleImport` short-circuits reuse for
`.removableVolume` sources with `miss: .removableSourceNotHashed`, since ADR 0018
never hashes a card in place, and "the destination is enriched normally after
import" ([CatalogStore.swift:3929](../../Otos/Stores/CatalogStore.swift)). The
destination copy therefore enriches fresh, finds no embedded wall, and derives
`destination_mtime − duration` = `W − duration`. **One duration of drift per import
generation**, corrupting `best_capture` (grid order) and reorganization naming.

**Rule:** the derived wall names the file; it does **not** stamp the destination
mtime. `ImportDestinationDate.expected` returns the source's real mtime whenever
the wall's precision is `derivedFromDuration`. The destination file then keeps the
source mtime, its own enrichment derives the same `W`, and convergence still holds
because planner and executor apply the identical rule. The name answers "when was
this captured"; the stamp answers "what fact makes the next plan converge".

Validation probes: enrich → import → enrich the destination copy → assert the
destination's derived wall equals the source's; assert the second plan reports
`skipPreexisting` for every entry (ARC-046A); assert grid order is unchanged across
a re-import.

Applies to 100% of Summer Photos's 69 videos, 100% of CAMERA's 9, and 24% of Camera
Roll's 748.

### Increment 6 — An unreadable file is surfaced, not retried (D9)

No backoff, no retry ledger, no new pacing machinery — the scenarios that look
transient are already handled by root availability and reconciliation (D9 table).

Per-file inventory:
- `Otos/Services/EnrichmentCoordinator*` — a byte-source open failure on an
  available root is reported once as an unreadable-source fact, not silently
  re-queued. **Scope: all root kinds, not removable only.** A `.readFailure` on a
  cloud root is an open failure on an already-materialized file (dataless files
  return `.notMaterialized` instead), so it is equally non-transient; writing this
  as removable-only would leave cloud roots re-queueing forever.
- `Otos/Services/MediaOperationCoordinator.swift` — the naming gate stops counting
  such a row as `.pending`, so it cannot hold the offer.
- `Otos/Services/MediaTransferPlanner.swift` — that entry is `.blocked` with an
  unreadable-bytes reason, reusing the existing blocked/attention machinery
  (`MediaAttentionItem`), so the file is neither silently copied nor silently
  skipped.
- `docs/design/import-bar.md` — state D gains the unreadable-source reason and its
  `Show them` reveal.

No durable column: a fresh attachment re-evaluates every row anyway, so the fact
lives for the attachment that observed it.

Validation probes: an unreadable file does not hold the gate; the plan is offered
with that item in D's attention list; the item is never copied and never counted
as preexisting; no repeated claim/release cycle appears in the logs for it.

## 7. Documentation changes

| Doc | Change |
| --- | --- |
| `docs/requirements.md` ARC-046 | Restore truth: overlay naming writes advance `namingRevision`, never `namespaceRevision`; import-plan staleness keys on the latter per role |
| ARC-046A | Cite the convergence failure and its new test |
| ARC-047 | Ready is gated on scan readiness **and** proven naming facts |
| ARC-057 | Rewrite: withhold until enrichment has *looked*; a durable mtime is a fallback only once proven, never an assumption |
| ENR-011 | Add viewport-preemption bound (S11) and MTP staging completeness (D4) |
| ENR-012 | Add the derived video capture wall and its precision token (O7) |
| New ARC row | MTP staging completeness + camera naming gate (O4) |
| `docs/adr/0026` | Amend: `.terminal` means *proven*, not *assumed*. The original bug it fixed (a row with neither date waiting forever) stands |
| `docs/adr/0024` | Note the second gate and how the two compose in state A |
| `docs/adr/0009` | Enrichment priority for attached sources (O2/O3) and device staging completeness |
| `docs/architecture.md` | The namespace/naming revision split; the push/pull split (stream has one subscriber, reorg pulls `planRevision`) (S6) |
| `docs/design/import-bar.md` | State A meaning; two-phase progress (Increment 3) |
| `docs/research/2026-08-29-import-naming-duplicates.md` | New: the SQLite queries, the 23-pair proof, the mtime/duration measurement, the log trace |

---

## 8. Verification

- `script/verify.sh` (requirements-authority + lint + build + test) per increment.
- Runtime differential per increment against the same card scenario, with
  `script/logs.sh` evidence attached: re-plan count, `drawnKind` transitions,
  `namingMtimeCount` at the moment of offer.
- Re-run the §1.1 duplicate query after an import to prove convergence.
- Increment 4's device path cannot be verified without hardware — record the
  limitation and the residual risk per the DoD's agent-owned verification rule.
