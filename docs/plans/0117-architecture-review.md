# Plan 0117: what a blank-slate review of the codebase changes (2026-11-19)

A review of the whole codebase asked of every part: "built from a blank slate today, would it
look like this?" Each recommendation was then argued against from the ADRs, research notes and
requirement rows, and every one that survived was measured or prototyped against a kill
criterion set in advance. This plan keeps only what survived the evidence. It names, for each
step:

- the evidence;
- what is measured or guarded before the change ("de-risk first");
- the done-criterion;
- the result that stops it.

The evidence:

- `docs/research/2026-11-19-structure-prototypes.md`: the OtosKit folder move, a serial lane
  and an owner loop, as prototypes.
- `docs/research/2026-11-19-store-change-facts-actor-hold-read-turns.md`: change notifications
  diffed against a writer-side observer, Store actor holds, and background read-turn waits.
- `docs/research/2026-11-19-account-videos-unread-faces.md`: account videos re-read every
  15 minutes.
- A dependency matrix of the window view model: which feature writes which other feature's
  stored state. It found Edit the cleanest seam: Edit, Crop and EditCommands wrote only to
  each other (landed as step 7, below).
- The fix history of the two weeks before the plan (below).

## Where the fixes go

`main` took 202 `fix:` commits between 2026-11-06 and 2026-11-20. Counted by subject:

| Area | Fixes |
| --- | --- |
| Tests, checks and benchmarks | 58 |
| People and faces | 41 |
| Import, cards and Trash | 26 |
| Search and descriptions | 16 |
| Grid, tiles and thumbnails | 16 |
| Places and the map | 15 |
| Immich | 14 |
| Edit, crop and loupe | 10 |

The files most often in them:

| File | Commits |
| --- | --- |
| `PeopleModels.swift` | 37 |
| `CatalogWindowViewModelPeople.swift` | 34 |
| `PeopleAssignment.swift` | 31 |
| `FaceStorage.swift` | 25 |

The two hotspots are People and the test harness, so step 2 investigates People.

The harness's own share has a structural cause the repo has already largely removed:
- test-owned stores, temporary folders and queues (#823, #835, #843);
- footprint gates under `OTOS_SCALE_TEST`.

What remains is a test waiting on a fact it does not own, for example #964 (waited for online,
not the first listing), #933, #821, #685 and #981. That is six in the month before the plan, a
rate this plan does not chase.

**The plan's success signal** is this table recounted when the plan closes: fixes per area,
People and the harness first.

## Landed from this review

- **#975.** A Cancel before an import starts stops it, and a failed Immich sync stays owed
  (ARC-047, APP-063, ADR 0046).
- **#978.** A source-scanning guard fails when a folder it scans is missing. A trial move of
  the sources left two guards passing having read nothing.
- **#979.**
  - A card attaching at a mount point retention is forgetting is kept (ADR 0013).
  - A second search-index start starts nothing.
  - A failing Maps leaves place names quiet until a named backoff wake (ADR 0051).
  - The migration freeze covers every table, trigger and view a migration builds (ADR 0002).
    No divergence existed, and the owner's upgraded catalog matches a fresh build byte for
    byte.
- **#980.** A VP9 video is undecodable before any frame is fetched, and a frame AVFoundation
  cannot seek to is read at its sync frame. Fourteen account videos had cost about 3.4 GB of
  re-reads in 6.5 hours (ENR-031, ADR 0047).
- **#990.** Step 2's study, which stopped the owner change. Its six act-chain guards are in
  `PeopleActChainTests`.
- **#991.** A People act whose covering state arrives before its answer retires at the answer
  (APP-087). This was the latent defect step 2's study found.
- **#992.** Step 5's de-risk: every runtime statement naming an asset's key has a recorded
  query plan. Also step 1's attribution: the 79 ms was a test-only wrapper.
- **#998.** Step 1: the Store actor's local holds over 50 ms are gone:
  - `oweFacesAgain` logs one line per call with a count and a sample;
  - `photoDescriptionCandidatesByKey` keys and sorts its ids inside its read;
  - the test-only `filterOptions` wrapper is deleted;
  - derived files and a removed source's staging folder are deleted on a dedicated queue
    (`FileDeletion`), never on the actor.
- **Step 6.** Errors the Store turned into nothing are said:
  - People undo counts and logs the faces and rejections of a library no longer cataloged
    (`op=people.restore`);
  - `rootIsAvailable` logs an unreadable root's error by domain and code;
  - a failed planning read logs its error.
- **#993.** Step 3's de-risk: the change-coverage guard is in every test's Store. On
  unmodified code it found three writes that announced nothing (ARC-018), and they are fixed:
  - a listing's changed source facts;
  - a server-absent preview;
  - cleared video face frames.
- **#997.** Step 7: Edit is the window's first feature model: `EditSession` owns the edit's state,
  lanes and tasks, and reads the window through a narrow context (ADR 0004). The window
  declares no edit state. People stays the next candidate.

## Steps

Each step is its own increment, in this order. Step 5 changes what is already understood. Step 3
guards before it changes anything, because it can fail silently: a missed notification. Step 2,
one owner for People's act overlay, was measured and stopped (below). Step 7 has landed (above).

### 3. Change notifications say what changed: narrow the `.all` sites

**Evidence.** Across the full suite, 3,079 notifications were `.all` or `.libraryRemoved`.

- 1,120 of them followed writes that touched only membership, copies, choices or detail. The
  largest senders:
  - `insertLibraryRootAndStartScan`: 658
  - `addImmichAccount`: 95
  - `settleImportedAsset`: 84
  - `setPendingTrash`: 53
- 1,959 more followed no write at all:
  - `shutdown`: 1,002
  - `performInitialLoad`: 824
  - `finishRemovableRootAttachment`: 131
- The `writes` table maps an `asset_metadata` insert only to the media-record fact. An inserted
  location therefore wakes no owner that reads location.

Each `.all` wakes every background owner and the window.

**De-risk first: landed.** Every test's Store carries the change-coverage guard
(`CatalogChangeCoverage`, ADR 0005): a commit no later change names all the kinds of fails the
test that made it, with the Store's value comparisons and owners' own state as the only
narrowings, each written down with its reason. Turning it on found three writes no change
named, fixed with it: a listing's change to a held row's source facts, a source's answer
that it holds no images of rows, and a video reading that takes its stored frames. A
narrowed site is now checked by every test that reaches it.

**Change.**
- Each `.all` site names the kinds it wrote.
- A site that wrote nothing sends nothing.
- Add `.location` to the `asset_metadata` insert's facts.

**Done when.**
- The guard passes across the full suite with no `.all` that follows a write of named kinds.
- A test pins each corrected site.

**Rejected, measured.** Deriving notifications from the writer (a GRDB `TransactionObserver`)
would be broader, not safer:
- 64 % of enrichment batches write columns without changing any value a reader depends on.
  Only the store's before-and-after comparison of the generated `best_*` columns sees that.
- Copy-key triggers rewrite columns whatever their values.
- 3,104 notifications report runtime state that no write carries: scan, listing,
  availability and reach.

The observer serves as a guard, never as the source of notifications.

### 5. One typed asset-key predicate and SQL grouped by table

**Evidence.**
- `library_root_id = ? AND relative_path = ?` is written out about 100 times across 10 files.
- None of the 95 `INDEXED BY` pins pairs with it. The key's index is the non-partial unique
  key, so sharing its text cannot break a partial-index prepare.
- The volume-aware `relative_path_key` (ADR 0025) is a second equality, so the typed key names
  which one it means.
- Migrations keep their SQL literal (ADR 0002); the freeze test holds them.

**De-risked.** Every runtime statement that names the key reads its text from a name, and
`CatalogStoreQueryPlanTests.everyStatementThatNamesAnAssetsKeyKeepsItsRecordedPlan` records the
plan of all 129 on an owner-shaped catalog (`OtosTests/Fixtures/Catalog/asset-key-query-plans.txt`).
126 find their row through the unique key's autoindex. Two seek `idx_face_person_photo`, which
also names the person, and one seeks its pinned `idx_media_asset_same_photo_candidate`. None
scans a table. The five temp B-trees, in four statements, each sort one photo's rows.

**Change.**
- An `AssetKey` predicate and binder.
- The statements in `CatalogStore.swift` move into per-table-group SQL enums, following
  `FaceStorage` and `PhotoDescriptionStorage`.

**Done when.** Every converted statement's recorded plan is unchanged.

**Stop if** any plan changes.


### 8. Move the sources into `OtosKit/`

**Evidence.** A trial move (`f7360fdb`):
- deleted the app target's 307-entry exception list and OtosKit's 2;
- had Xcode 27 beta keep resource membership correct (20 framework resources, five compiled
  models);
- built and passed every test unmodified, twice.

The only red gate was `requirements-authority-check`, because 1,326 doc references name `Otos/`
paths:
- 1,180 in `requirements.md`
- 80 in `docs/design`
- 43 in `docs/research`
- 22 in ADRs, across 12 files
- 1 in `architecture.md`

**De-risked: go, with two amendments** (`docs/research/2026-11-20-edit-access-and-move-replay.md`,
E8). The last 30 commits that touched `Otos/` were replayed onto the move with rename
detection:
- 28 picked cleanly, carrying all 163 file changes.
- The 2 that added a file conflicted loudly, and git placed both files at the right `OtosKit/`
  path.
- The replayed tree compiles.

The one silent case: a new file in a **new** folder picks cleanly and lands where the app
target builds it. So:
- **Guard.** It rejects every file under `Otos/` except `main.swift`, `Assets.xcassets/` and
  `Otos.icon/`, not only `.swift`; a resource in a new folder would otherwise go into the app
  bundle. It lands in the move's own PR. #978 already makes a guard pointed at a stale path
  fail.
- **Scripts.** The move rewrites every script that names an `Otos/` path, not only the gates:
  `scene-label-hierarchy.sh` still wrote to `Otos/Resources` and nothing failed.
- **Timing.** The move merges when no open PR changes `Otos/`. There were none on 2026-11-20.

**Change.**
- The move.
- The script and lint path updates the trial listed.
- A mechanical rewrite of those references.
- ADR 0023 rewritten: no file stays in a folder the app target also sees.

**Done when.** The full `script/check.sh` is green on the moved tree.

## Measured and dropped

| Proposal | Why it is dropped |
| --- | --- |
| Split `CatalogStore` into several actors | Stock holds: p50 0.02 ms, p95 0.44 ms, p99 1.9 ms. Every hold over 50 ms was a local fix, landed as step 1. Writes span domains in one transaction (trash carry, import settlement, library removal, face undo). ADR 0002 keeps one owner. |
| Derive change notifications from the writer | Step 3's evidence: broader, not safer. Kept only as step 3's guard. |
| Promote a wanted People or Duplicates build's background reads | Their reads waited p95 0.10–0.20 ms, at most 0.20 % of a build. Small sample: 4 People and 3 Duplicates builds at owner size. |
| A generic `SerialLane` | Saves about 11 lines a port against a 25-line bar. Lines were the wrong criterion; what it would buy is an awaitable "settled" fact for tests. Measured that way it still does not pay: six test fixes in a month waited on a fact they did not own, and only some were lane settles. |
| A subscribe-then-loop helper for background owners | `PhotoDescriptionWriter` needed four hooks beyond `drain`. About half the owners do not share the shape. The three subscribe-race answers are one guarantee. |
| A generic retry ledger | `PacingLedger` passed every requirement test and saved 2 lines in total. Timings are pinned by ENR-009/026/027/030/031/032 and APP-029/068. |
| Publish People and Duplicates outside the window state | `CatalogWindowParts` already removed the 45–60 ms cost (now 34 ms worst). The Duplicates sidebar row and People's act overlay depend on the shared publication. |
| One grid cursor model | Four different geometries: native, ragged groups, shift-extend, focus-only. |
| One combined tile value in the grid | A hover move would become a content change. A `forEachVisible` helper is the most it earns. |
| Room holds for decode, embeddings, faces | Rejected with measurement in ADR 0057. |
| Moving footprint tests out of the unit host | Already gated behind `OTOS_SCALE_TEST=1`. The default run asserts counts. |
| Replacing every polling test wait | ADR 0033 keeps them. Only waits with a reported fact convert. |
| Move People's act overlay (`PendingPeopleActs`) into Projection (step 2) | 8 of 57 People fixes since 2026-10-20 were overlay timing (14 %, under the third the step set). Three of the seven distinct ones are where a merge leaves the window's scope and filter, which is view-model state. Six interleaving tests of what the window shows pass on unmodified code and landed as guards (`PeopleActChainTests`). `docs/research/2026-11-20-people-act-chain.md`. |
| Dropping the six never-read import columns | Required provenance: ARC-046A, ADR 0008. |

## Open observations

- **Duplicates waited behind People.** A Duplicates build waited 102 s for the heavy-load turn
  behind a People pass. ADR 0055 runs one heavy load at a time by design. Whether that wait is
  felt belongs to the weekly run's tour, not to this plan.
- **HEVC frame-seek failure.** It reproduces only on the owner's own files offline. No
  generated file triggers it.
- **Measurement conditions.** The actor-hold and read-turn numbers come from a Debug test host
  at load average 164–227. They rank causes; they are not felt latencies.

Each step's increment deletes its section here. The plan is deleted when the last one lands,
after the fix table above is recounted for the same span of time.
