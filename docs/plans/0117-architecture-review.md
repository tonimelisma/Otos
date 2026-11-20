# Plan 0117: what a blank-slate review of the codebase changes (2026-11-19)

A review of the whole codebase asked of every part: "built from a blank slate today, would it
look like this?" Each recommendation was then argued against from the ADRs, research notes and
requirement rows, and every one that survived was measured or prototyped against a kill
criterion set in advance. This plan keeps only what survived the evidence. It names the
evidence, the done-criterion and the result that would stop each item.

The evidence:

- `docs/research/2026-11-19-structure-prototypes.md`: the OtosKit folder move, a serial lane
  and an owner loop, as prototypes.
- `docs/research/2026-11-19-store-change-facts-actor-hold-read-turns.md`: change notifications
  diffed against a writer-side observer, Store actor holds, and background read-turn waits.
- `docs/research/2026-11-19-account-videos-unread-faces.md`: account videos re-read every
  15 minutes.
- A dependency matrix of the window view model: which feature writes which other feature's
  stored state (method under step 5).

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

## Steps

Each step is its own increment, in this order.

### 1. Synchronous O(n) work and file deletion leave the Store actor

**Evidence.** Measured actor holds over 50 ms:

| Entry point | Hold | Cause |
| --- | --- | --- |
| `oweFacesAgain` | 15.6 s on a generated catalog | one `errorOperation` per photo, in a loop on the actor |
| `photoDescriptionCandidatesByKey` | 449 ms | sorts its keys on the actor |
| `filterOptionTally` | p99 79 ms | not yet attributed |
| `deleteStagingIfNeeded` | 123 ms–1.49 s for 2,000 files | file deletion on the actor (rule 6) |
| `DerivedRemoval.perform` | up to 160 ms | file deletion on the actor (rule 6) |

- Window reads waited up to 14.8 s behind the `oweFacesAgain` hold.
- The owner's app logged no `malformedFaceRow` in seven days. That failure is a generator
  artifact, but the shape (cost proportional to the rows, held on the actor) is real.

**Change.**
- Log once per page with a count.
- Sort inside the read that returns the keys.
- Attribute `filterOptionTally`, then fix its cause.
- Delete files through a named off-actor mechanism, applying only the result on the actor.

**Done when.**
- A deterministic test bounds the work each entry does on the actor: rows visited, log lines
  per page.
- The hold measurement on the experiment branch `experiment/2026-11-19-store-change-facts-actor-hold`
  (`d401c1f6`, local) shows no entry over 50 ms at the stock shape.

**Not changed.** The open and migration also exceed the bar, 18–47 ms on an owner-size
catalog. Nothing that needs the catalog can run before it, so moving it buys nothing.

### 2. Change notifications say what changed: narrow the `.all` sites

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

**Change.**
- Each site names the kinds it wrote.
- A site that wrote nothing sends nothing.
- Add `.location` to the `asset_metadata` insert's facts.

**Done when.** The differential harness on the experiment branch shows:
- no hand-named notification narrower than its write;
- no `.all` that follows a write of named kinds.

A test pins each corrected site.

**Rejected, measured.** Deriving notifications from the writer (a GRDB `TransactionObserver`)
would be broader, not safer:
- 64 % of enrichment batches write columns without changing any value a reader depends on.
  Only the store's before-and-after comparison of the generated `best_*` columns sees that.
- Copy-key triggers rewrite columns whatever their values.
- 3,104 notifications report runtime state that no write carries: scan, listing,
  availability and reach.

### 3. Every thumbnail outside the grid loads through `ThumbnailLoad`

**Evidence.**
- `DuplicatesView` carries a private decoder byte-identical to `ThumbnailDecode`.
- `PanePresentation` hand-rolls the same read → detail → decode with `Task.detached`, and drops
  a detail-read error without logging it.
- Face tiles are different on purpose and stay separate: they crop from the stored preview
  through the edit's geometry, and keep their own no-blank cache.

**Change.**
- `ThumbnailLoad` returns image, unavailable, or not yet.
- Duplicates and the pane call it.
- The pane's read error is logged.

**Done when.**
- Both copies are deleted.
- The existing Duplicates and pane tests pass unmodified, plus one test for the unavailable
  glyph.

### 4. One typed asset-key predicate and SQL grouped by table

**Evidence.**
- `library_root_id = ? AND relative_path = ?` is written out about 100 times across 10 files.
- None of the 95 `INDEXED BY` pins pairs with it. The key's index is the non-partial unique
  key, so sharing its text cannot break a partial-index prepare.
- The volume-aware `relative_path_key` (ADR 0025) is a second equality, so the typed key names
  which one it means.
- Migrations keep their SQL literal (ADR 0002); the freeze test holds them.

**Change.**
- An `AssetKey` predicate and binder.
- The statements in `CatalogStore.swift` move into per-table-group SQL enums, following
  `FaceStorage` and `PhotoDescriptionStorage`.

**Done when.**
- `EXPLAIN QUERY PLAN` of every converted statement on a generated owner-shaped catalog still
  names the unique key's index.

**Stop if** any plan changes.

### 5. Edit becomes the window's first feature model

**Evidence.**
- The window view model holds 310 stored properties. Across its 26 files, cross-feature writes
  come to only 26 pairs of one to three writes each.
- Nearly all of them go to state every feature shares:
  - `gridSelection`
  - `viewMode` / `comparePair`
  - `windowUndoManager`
- Edit, Crop and EditCommands write only to each other.
- The one real feature-to-feature coupling is Trash/Curation writing Duplicates' session and
  undo state. ADR 0004 requires that step to stay one synchronous step on one ordered intent
  channel.
- Method: each stored property was assigned to the extension file that names it most. Then
  every assignment, compound assignment or mutating call from another file was counted. This
  is a heuristic: generic names such as `state` add noise.

**Change.**
- An `EditSession` (`@Observable`, MainActor) owns the edit's state, lanes and tasks.
- It reads a narrow context the window gives it: target, view mode, undo manager.
- Trash, Duplicates and Curation stay on the window model.

**Done when.**
- The window model no longer declares edit state.
- The edit tests pass with only the access path changed.

**Stop if** the edit needs to write window state anywhere other than the undo manager and view
mode.

### 6. Move the sources into `OtosKit/`

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

**Change.**
- The move.
- The script and lint path updates the trial listed.
- A mechanical rewrite of those references.
- ADR 0023 rewritten: no file stays in a folder the app target also sees.

**Done when.** The full `script/check.sh` is green on the moved tree. Since #978, a guard
pointed at a stale path fails instead of passing.

### 7. Errors the Store turns into nothing

- People undo's `restore` skips a face whose library is gone without counting or logging it
  (`CatalogStore.swift`, `try? FaceRowKey`). `applyAssignment` already counts its skips.
- `rootIsAvailable` turns any error into "unavailable" with no log.
- `planningMedia` logs its failure without the error.

**Change.** Each is counted or logged by error domain and code (lint `error_becomes_value`).

**Done when.** Each has a test that sees the log or count.

## Measured and dropped

| Proposal | Why it is dropped |
| --- | --- |
| Split `CatalogStore` into several actors | Stock holds: p50 0.02 ms, p95 0.44 ms, p99 1.9 ms. Every hold over 50 ms is one of step 1's local fixes. Writes span domains in one transaction (trash carry, import settlement, library removal, face undo). ADR 0002 keeps one owner. |
| Derive change notifications from the writer | Step 2's evidence: broader, not safer. |
| Promote a wanted People or Duplicates build's background reads | Their reads waited p95 0.10–0.20 ms, at most 0.20 % of a build. Small sample: 4 People and 3 Duplicates builds at owner size. |
| A generic `SerialLane` | Saves about 11 lines a port against a 25-line bar. Its awaitable `untilSettled()` would replace 45 polling waits only after all four lanes moved. |
| A subscribe-then-loop helper for background owners | `PhotoDescriptionWriter` needed four hooks beyond `drain`. About half the owners do not share the shape. The three subscribe-race answers are one guarantee. |
| A generic retry ledger | `PacingLedger` passed every requirement test and saved 2 lines in total. Timings are pinned by ENR-009/026/027/030/031/032 and APP-029/068. |
| Publish People and Duplicates outside the window state | `CatalogWindowParts` already removed the 45–60 ms cost (now 34 ms worst). The Duplicates sidebar row and People's act overlay depend on the shared publication. |
| One grid cursor model | Four different geometries: native, ragged groups, shift-extend, focus-only. |
| One combined tile value in the grid | A hover move would become a content change. A `forEachVisible` helper is the most it earns. |
| Room holds for decode, embeddings, faces | Rejected with measurement in ADR 0057. |
| Moving footprint tests out of the unit host | Already gated behind `OTOS_SCALE_TEST=1`. The default run asserts counts. |
| Replacing every polling test wait | ADR 0033 keeps them. Only waits with a reported fact convert. |
| Dropping the six never-read import columns | Required provenance: ARC-046A, ADR 0008. |

## Open observations

- **Duplicates waited behind People.** A Duplicates build waited 102 s for the heavy-load turn
  behind a People pass. ADR 0055 runs one heavy load at a time by design. Whether that wait is
  felt belongs to the weekly run's tour, not to this plan.
- **HEVC frame-seek failure.** It reproduces only on the owner's own files offline. No
  generated file triggers it.
- **Measurement conditions.** The actor-hold and read-turn numbers come from a Debug test host
  at load average 164–227. They rank causes; they are not felt latencies.

Each step's increment deletes its section here. The plan is deleted when the last one lands.
