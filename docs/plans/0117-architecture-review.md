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
- **Step 3.** Change notifications say what changed (ADR 0005, ARC-018). No Store operation
  sends `.changed(.all)`: each names the kinds it wrote (`presence`, `fileFacts`, `movedRow`,
  `edit`, `settledImport`), a change that follows no write names the runtime state it reports
  (a root's reach, or its own state with no row), and one that wrote nothing sends nothing.
  Only `.libraryRemoved` stands for every kind. An `asset_metadata` insert or delete now names
  `.location`. A witnessed move whose file facts were unchanged had announced nothing; it is
  announced as a moved row. Rejected, measured: deriving notifications from the writer (a GRDB
  `TransactionObserver`), which serves as the guard only.
- **Step 5.** One typed asset key, and the Store's SQL grouped by table:
  - `AssetKey` writes both path equalities, `exactText` (`library_root_id`, `relative_path`)
    and `volumeAware` (`relative_path_key`, ADR 0025), and binds the key. No runtime statement
    writes either out by hand, and the hand-written argument pairs are gone. `FaceRowKey.Photo`
    and the search reads' private row key were the same fact, and are `AssetKey`.
  - The statements of `CatalogStore.swift`, `CatalogStorePersistence.swift` and the two
    journals moved into per-table enums: `AssetRowSQL`, `AssetEnrichmentSQL`, `PeopleSQL`,
    `MediaCompanionSQL`, `LibraryRootSQL`, `ImportJournalSQL`, `ReorganizationJournalSQL`,
    and the search, description, place-cell, duplicates and vector-file owners. Only
    connection pragmas and maintenance stay where they run.
  - Every recorded plan is unchanged. Two statements that named a key without being listed
    are now recorded: `AssetRowSQL.digestStandingSQL` (a runtime read that sat in
    `CatalogSchema`) and `MediaCompanionSQL.otherSpellingSQL`.
- **Step 8.** The sources are in `OtosKit/` (ADR 0023): every source and resource the
  framework compiles moved there with `git mv`, and `Otos/` holds only `main.swift`,
  `Assets.xcassets` and `Otos.icon`. Each target compiles its own synchronized folder, and
  both `membershipExceptions` lists are gone. The framework's resources are the installed
  app's 20. `script/guard-app-folder.sh`, a fast gate, fails on any other file under `Otos/`,
  of any type (E8's first amendment). Every script, lint rule and doc that named a moved path
  names `OtosKit/` (the second); dated research notes keep the paths they were written with.

## Steps

Every step has landed or was stopped. Step 2, one owner for People's act overlay, was
measured and stopped (below). What remains is the closing recount of the fix table (above).

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
