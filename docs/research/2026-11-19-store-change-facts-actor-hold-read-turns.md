# Store change facts from the writer, the Store actor's holds, and background read turns (2026-11-19)

## Questions

Three measurements that decide three proposed Store changes:

- **M1.** Could the change facts the Store announces (`CatalogStoreChange`, `CatalogChangedFacts`)
  be derived from what each committed transaction wrote, instead of named by hand at each
  `notifyCatalogChanged` site? Where does the hand-named change over-notify, under-notify, or
  omit a fact the write produced?
- **M2.** How long does one hold of the `CatalogStore` actor last, per entry point, on a
  generated owner-shaped catalog with every background owner running? How long do the blocking
  calls on it take (`database()` open+migrate, `rootIsAvailable`, `deleteStagingIfNeeded`)?
  Decision bar: an actor split or a blocking-work move is justified only if a p99 hold is over
  ~50 ms or a blocking call is over ~10 ms at p99.
- **M3.** How long does a background read made by a People or Duplicates build wait for its
  `CatalogReadAdmission` turn while that build is the one the view needs
  (`LoadAdmission.want`, `BackgroundLoad.needed(by:)`)? Decision bar: worth fixing only if p95
  is over ~100 ms or over 5 % of the build's time.

## Method

Nothing touched the owner's catalog or library. The only read of his data was `log show` of the
installed app's own unified log for the last 7 days (M2, below). Every experiment that wrote
used a catalog the tests generate.

All instrumentation was experiment code on the local branch
`experiment/2026-11-19-store-change-facts-actor-hold` (commit `d401c1f6`, on top of `998ce0d1`).
It was never pushed or merged. Every probe appended ndjson lines to `build/experiment/` in its
worktree.

- **M1, the differential.** A GRDB `TransactionObserver` on the Store's pool, added in
  `CatalogWriter.init`, observing every event kind. For each statement it kept the event kinds
  GRDB's authorizer reported to `observes(eventsOfKind:)`, which give an `UPDATE`'s column set.
  It also kept the inserted, deleted and updated tables `databaseDidChange(with:)` reported.
  At `databaseDidCommit` it mapped them through `CatalogChangedFacts.writes`: a table event,
  or an update sharing a column with an entry, names that entry's facts. It wrote one line per
  commit, with the operation the Store named the write for (`CatalogWriter.write`'s
  `operation`). Tables and columns that no fact names were logged as unmapped.
  `notifyCatalogChanged` took `#function`/`#line` and logged each change it sent. A change was
  paired with the commits in the same Store since that Store's previous notification whose
  operation is the notifying function, or a caller or callee of it within two levels. The
  call graph came from `Otos/Stores` and `Otos/Services` source. At the two value-comparing
  enrichment sites (`EnrichmentOverlayBeforeWrite.changedFacts(to:)`), each row's result was
  logged. Run: the full `script/check.sh` suite, 2,202 tests, which covers the store,
  enrichment, trash, import, people and search suites, with the harness on.
  It made 909 Stores, 4,476 commits and 7,614 notifications, and the suite was green.
- **M1, overhead.** `ExperimentMeasurements.observerOverheadOnBulkInsert`: 150,000
  `media_asset` rows inserted into an owner-shaped catalog at scale 0.01, once as one
  `INSERT … SELECT` and once as 150,000 single-row statements, three repetitions. The observer
  timed its own callbacks (`callbackNanos`).
- **M2, actor holds.** `CatalogStore` got a custom `SerialExecutor` that runs every job on a
  serial dispatch queue and times `runSynchronously`. Each timed job is one actor hold, from a
  resume to the next suspension. Each hold was keyed by the job's `ResumeTask` and the
  `ResumeParent` chain of its async contexts (job offsets 56 and 64, context offsets 0 and 8,
  `swift/ABI/Task.h`), up to 16 frames. The chain was symbolicated afterwards with `atos`. A
  hold is attributed to the first `CatalogStore` method in its chain, so a hold that resumes in
  `withCheckedThrowingContinuation` after a GRDB read is attributed to the Store read that
  awaited it. Blocking calls were timed in place. Run:
  `OTOS_SCALE_TEST=1 script/check.sh --only StallReproductionTests`, alone, on the
  `RunningBackgroundOwners` shape (`2026-11-16-stall-reproduction-baseline.md`):
  - run 3: the stock live phase, 3 × 5 scope changes;
  - run 4: the same, plus 16 more scope changes, each preceded by asking both builds for a
    pass, with 2 s between them.

  `deleteStagingIfNeeded`'s body (`FileManager.removeItem` of the staging folder) was timed in
  `ExperimentMeasurements.stagingFolderRemoval`, on 2,000 files in 20 `DCIM` folders, at
  4 KB and at 512 KB per file. 512 KB was the most the disk's 13 GB of free space allowed.
- **M3, read turns.** `LoadAdmission.run` set a task-local tag on its body: the load, whether
  the machine's `wanted` was that load at the grant, and a run number. `CatalogLaneReader`
  timed each background read's `CatalogReadAdmission.admit()` and logged it with the tag. In
  the scale runs the test called `admission.want(.people)` and `want(.duplicates)` in turn,
  before every scope change.
- **Load.** Other sessions' checks ran throughout. The load average was 164–227 during the
  scale runs. Every wall-clock figure is inflated by that load, and the test host is an
  unoptimized Debug build.

## Results

### M1: what the writer's own events say against what the hand named

Of 3,498 notifications that could be paired with commits:

| | Notifications |
| --- | --- |
| Exact (the observer's facts equal the hand's, `stacks`/`faceTiles` set aside) | 1,406 |
| The hand names more (i) | 1,386 |
| The observer names more (ii, iii) | 870 |

**(i) The hand over-notifies.** 3,079 of 7,614 notifications were `.changed(.all)` or
`.libraryRemoved`, from 20 sites. 1,120 of them followed a write, and every one of those writes
was narrower than everything:

| Site | `.all` sent | What its writes touched |
| --- | --- | --- |
| `insertLibraryRootAndStartScan` | 658 | membership (a new, empty root) |
| `addImmichAccount` | 95 | membership |
| `settleImportedAsset` | 84 | membership, copies, choices, images, detail; +date, kind, grouping, record, duplicateFacts in 33 |
| `setPendingTrash` | 53 | membership, copies, choices |
| `reconcileFileDirt` | 44 | membership (+date, kind, copies, detail, choices in 27) |
| `reconcileTrashedPaths` | 25 | membership, copies, detail, choices |
| `scanCompleted` | 23 | membership |
| `removeLibrary` (`.libraryRemoved`) | 22 | membership (+mediaRecord, faces in 3) |
| `detachRemovableSource` | 19 | membership, detail |
| `recordScannedBatch`, `recordSourceListingBatch`, `applySourceListingChanges` | 17 + 7 + 29 | membership, date, kind, copies, detail, choices |
| `recordSourceFileErased` | 16 | membership |
| `settleReorganizationComponent`, `restoreTrashedItem`, `completeSourceResync`, `revertCarriedWork` | 5 + 5 + 3 + 1 | membership, copies, choices |

The other 1,959 `.all` notifications follow no write at all: `shutdown` (1,002),
`performInitialLoad` (824) and `finishRemovableRootAttachment` (131). The rest of the
over-notification is a convention, not waste. `applyPreviewFaces`, `applyRenderedEditProducts`,
`setEditRecipe` and `applyProvisionalThumbnails` name `.detail` beside their own kind because a
tile's detail refresh follows every change (`CatalogChangedFacts.detail`). Their writes touch no
column of the detail kind.

**Changes no write can derive.** 3,104 notifications followed no commit of their own. They
report runtime state, not rows:

- `startNextScanIfNeeded` (847) and `clearCurrentScan` (831), membership;
- `beginSourceListing` / `endSourceListing` (171 / 160), `setAvailability` (21) and
  `setSourceAnswering` (13), membership;
- `changeEnrichability` (28), detail, and `setDuplicatesReach` (16), duplicateFacts.

A writer-derived channel would still need a second, hand-named channel for these.

**(ii) The observer is broader, by design.** Every under-notification by the hand (870) traced
to a value comparison the hand makes and a writer's events cannot:

- **Enrichment.** 534 of 563 `applyEnrichmentBatch` batches wrote a column of the date, kind,
  grouping or location kinds. 358 of those (64 %) changed none of those values, and the hand
  named none of them. Per row, 2,365 of 3,007 enrichment row writes (78.6 %) changed no
  `best_*`, grouping or location value. 3 of 3 metadata-refresh rows changed none.
- **Copies and choices.** Every digest write runs the `media_asset_copy_*` triggers. They
  update `has_copies`, `copy_key`, `shown_copy_root_id`, `media_choice` and `choice_sequence`
  whether or not a value changes. `DigestStanding` reads where the row stood before and after,
  and names copies only when it moved. The observer would have added copies and choices to
  39 of 53 `applyContentHash` notifications, to 111 of 140 `applySourceListingChanges`
  notifications, and to most enrichment batches.
- **Duplicates.** `media_asset_render_signature_stale` clears `render_dhash` whenever a
  thumbnail or render changes. `DuplicatesHoldSQL` names duplicateFacts only for a photo
  Duplicates holds. `setEditRecipe` (61), `applyRenderedEditProducts` (34) and
  `requestEnrichmentDownload` (2) name it less often than the observer would.
- **Search.** `applySearchEmbeddings` names searchReadings only when On This Day's labels
  changed (4 of 53).
- **People.** A person's delete cascades to `person_summary` (peopleGallery). The hand names
  `.faces` (`perform`, `restore`), and `PeopleGallery.inputs` includes `.faces`.
- **Two over-reports of the observer itself.**
  - GRDB reports an update event's table but not its columns. A statement whose trigger body
    updates other columns of the same table is credited with all of them, even when the
    trigger's `WHEN` is false. `applyProvisionalThumbnails` writes only rows without a
    thumbnail, where `render_signature_read` is 0, and still "touched" `render_dhash`.
  - `CatalogChangedFacts.writes` lists `asset_metadata` inserts only under mediaRecord. An
    inserted record that carries a location therefore derives no `.location`, though the hand
    names it (40 enrichment batches). `read(by:)` is unaffected: a region that reads
    `primary_latitude` is modified by any `asset_metadata` insert.
- **Owner-only state.** 108 claim writes (`claimedEnrichmentCandidates`,
  `priorityEnrichmentCandidates`, `releaseEnrichmentClaims`) set `enrichment_claimed`, a
  `.detail` column, and send nothing. Only `EnrichmentClaimGateway` reads that column. A derived
  channel would wake every detail reader on each claim unless the owner's own columns were cut
  out.

Writes no fact names went to the Store's bookkeeping tables (`active_file_operation*`,
`active_reorganization_*`, `active_source_erase`, `copy_key_touched`, `derived_folder`,
`library_root_change_journal`, `people_assignment_settled`, `search_vector_file`,
`search_text_word_data/docsize`, `pending_identity_remap*`) and to `photo_description` (11
commits). Whether any other owner reads `photo_description` was not checked.

**(iii) A fact the write produced that no notification named.**

- **One instance, masked.** `writeSourceListingChanges` (`CatalogStore.swift:6835`) updates an
  existing row's `source_item_id`, `source_path_sha1` and `source_products_absent`
  (`:6868`). These are membership, copies-input and images columns in `writes`. The update
  records no row change ("none of them shown, so none a change the window hears"). One test
  commit updated a row there and `applySourceListingChanges` announced nothing.
  - What it affects: an account asset whose server products appear or disappear changes what
    `sourceProductCandidates` returns (`source_products_absent = 0`) and the empty-search
    "no thumbnail coming" set (`SearchEmbeddingStorage`). Every reader of that column also
    reads membership columns.
  - Why it is masked: the listing's `endSourceListing` sends `.membership` right after, so
    every reader of that column hears it there. No other unmasked case was found.

Every other commit with facts and no notification of its own was covered by a later
notification in the same Store:

- removable-root inserts, by `finishRemovableRootAttachment` `.all`;
- face-stamp clears, by `writeInPages` `.faces`;
- the source sync's resync and last-synced writes, by `beginSourceListing`, `endSourceListing`
  or `setSourceAnswering`.

**Overhead.** The observer's own callbacks cost 0.42–0.86 µs per change event in the
`INSERT … SELECT` form (63–372 ms per 150,000-row insert). They cost 2.1–3.4 µs per event when
`observes(eventsOfKind:)` is called once per statement (938–1,512 ms per 150,000 single-row
inserts). That is in a Debug build with a `Mutex` and dictionaries per event. Wall-clock time:
the `INSERT … SELECT` took 9.2–22.5 s observed against 14.6–21.0 s unobserved, and the
single-row form 77–97 s against 80–114 s. The machine's load hides any difference.

### M2: the Store actor's holds

| Run | Holds | Busy | p50 | p95 | p99 | p99.9 | Max |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Run 3 live (11.5 s, 3 × 5 scope changes) | 2,614 | 0.43 s | 0.02 ms | 0.44 ms | 1.9 ms | 14.9 ms | 44.9 ms (`oweFacesAgain`) |
| Run 4 live (111 s, +16 scope changes and builds) | 8,108 | 18.8 s | 0.07 ms | 0.63 ms | 5.0 ms | 48.5 ms | 15,646 ms (`writeInPages` ← `oweFacesAgain`) |
| Run 4 quiet replay (73 s) | 17,686 | 4.3 s | 0.08 ms | 0.72 ms | 3.4 ms | 12.1 ms | 143.5 ms (the start's first job) |

The entry points that dominate run 4's live phase:

| Entry point | Holds | Total | p50 | p95 | p99 | Max |
| --- | --- | --- | --- | --- | --- | --- |
| `writeInPages` (from `oweFacesAgain`) | 297 | 15,810 ms | 0.04 | 0.92 | 30.3 | 15,646 |
| `photoDescriptionCandidates` | 5,893 | 1,212 ms | 0.08 | 0.51 | 2.3 | 49.0 |
| `filterOptionTally` | 64 | 516 ms | 1.17 | 50.5 | 78.6 | 78.6 |
| `photoDescriptionCandidatesByKey` | 84 | 479 ms | 0.16 | 1.28 | 448.7 | 448.7 |
| `requestEnrichmentDownload` | 107 | 251 ms | 0.16 | 11.0 | 43.2 | 47.1 |
| `oweFacesAgain` | 1 | 176 ms | – | – | – | 176 |
| `orderedAssetIDs` | 64 | 65 ms | 0.13 | 1.18 | 48.6 | 48.5 |
| `mediaTileDetails` | 62 | 43 ms | 0.24 | 3.4 | 9.3 | 9.3 |
| every other entry | – | – | – | – | < 6 | < 13 |

Times are in milliseconds.

What the over-bar holds are:

- **`writeInPages` ← `oweFacesAgain`, 15.6 s.**
  - Mechanism: after its last page commits, `oweFacesAgain` (`CatalogStore.swift:1965`) logs
    one `errorOperation` per photo (`:1980`) in a loop on the actor, then notifies. Run 4's
    People pass found every generated face vector malformed and cleared 95,000 stamps in 372
    pages, about 165 µs per log line.
  - Window reads, which pass through the actor, waited behind it: `orderedAssetIDs`,
    `filterOptions` and `importBatches` all have a 14.5–14.8 s maximum in that run.
  - Cause of the count: a generator artifact. The owner's installed app logged
    `malformedFaceRow` 0 times in the last 7 days. The O(n) synchronous loop is real.
- **`photoDescriptionCandidatesByKey`, 449 ms.** It filters and sorts the asked ids
  (`CatalogStore.swift:11369`) on the actor before its read.
- **`filterOptionTally`, 79 ms.** The tally's own work on the actor, around its read.
- **`oweFacesAgain`, 176 ms.** The same loop, in a pass that found fewer rows.

Run 3, the stock shape, has no entry with a p99 over 50 ms. It ran at a load average of 227,
so its wall-clock holds include preemption.

Blocking calls on the actor:

| Call | Where | n | p50 | p95 / p99 | Max |
| --- | --- | --- | --- | --- | --- |
| `database()` open + migrate, owner-size catalog at the current schema | scale runs | 4 | – | – | 18.1–46.8 ms each |
| `database()` open + migrate | whole suite, many catalogs, some migrated from the baseline | 914 | 25.6 ms | 353 / 1,154 ms | 3,096 ms |
| `rootIsAvailable` | scale runs (paths absent) | 9 | 0.04 ms | – | 0.34 ms |
| `rootIsAvailable` | whole suite | 1,349 | 0.08 ms | 1.0 / 9.5 ms | 122 ms |
| staging removal, 2,000 × 4 KB | `stagingFolderRemoval` | 3 | 123 ms | – | 131 ms |
| staging removal, 2,000 × 512 KB | `stagingFolderRemoval` | 3 | 270 ms | – | 1,490 ms (first, cold) |
| `deleteStagingIfNeeded` in the suite (small folders) | whole suite | 3 | 0.3 ms | – | 0.3 ms |
| `DerivedRemoval.perform` (thumbnail deletes) | whole suite | 12 | 0.5 ms | 160 ms | 160 ms (2 files, under load) |

### M3: background read turns while a build is the view's

| Reads | n | Turn wait p50 | p95 | Max |
| --- | --- | --- | --- | --- |
| People build, wanted (runs 3–4) | 113 | 0.02–0.03 ms | 0.10–0.20 ms | 1.34 ms |
| Duplicates build (runs 3–4) | 6 | 0.02–0.04 ms | 0.03–0.04 ms | 0.04 ms |
| Every other background read (run 4) | 11,966 | 0.02 ms | 0.09 ms | 93.1 ms |
| People / Duplicates reads, whole suite (small builds) | 506 / 214 | 0.02 / 0.01 ms | 0.26 / 0.08 ms | 60.6 / 31.5 ms |

Each build's read waits as a share of its time:

| Build | Wanted at grant | Build time | Reads | Turn wait | Share |
| --- | --- | --- | --- | --- | --- |
| People | yes | 712 ms | 3 | 1.4 ms | 0.20 % |
| People | yes | 6,891 ms | 1 | 0.0 ms | 0 % |
| People | yes | 102,292 ms | 53 | 2.1 ms | 0.002 % |
| Duplicates (run 3) | no | 115–331 ms | 2 | 0.0 ms | 0.04 % |
| Duplicates (run 4) | no | 265 ms | 2 | 0.1 ms | 0.03 % |

A build makes few reads (`peopleSnapshot`, `settledPeopleAssignment`, `faceEmbeddings` pages;
`samePhotoCandidates`, `duplicateCopies`). The other owners' background reads are short pages:
the description writer's 2,951 and search text's 8,667. With four turns, a build's read almost
never finds all four taken.

The time a wanted build waits is for its `LoadAdmission` turn, not for read turns. In run 4,
Duplicates waited 102 s behind that People pass, which held the one heavy-load turn the whole
time.

## Conclusions

- **M1.** Deriving change facts from the writer would be broader, not safer:
  - it would lose the value comparisons that keep 64 % of enrichment batches out of the
    window's order, and the copies and duplicates standings;
  - it would announce owner-only state, the enrichment claims;
  - it still needs a second, hand-named channel for the 3,104 runtime-state changes.

  What the differential does show is waste in the other direction: 20 `.all` sites, 1,120
  times after writes that touched only membership with copies, choices and detail.
  `insertLibraryRootAndStartScan` alone sent 658. Narrowing those is the change this
  measurement supports.

  No unmasked missed notification was found. The one candidate,
  `writeSourceListingChanges`'s silent update of `source_products_absent`, is covered by the
  `.membership` that `endSourceListing` sends right after. Two corrections belong to any
  derivation:
  - an insert or delete of a table implies every fact that names its columns (the
    `asset_metadata` location gap);
  - GRDB events cannot tell a statement's columns from its triggers' columns.

  The observer costs under 1 µs per event in the bulk form.
- **M2.** At the stock shape, no entry point's p99 hold reaches 50 ms (overall p99 1.9–5.0 ms,
  max 44.9 ms). So an actor split is not justified. Three entry points cross the bar when
  their inputs are large, all by synchronous O(n) work on the actor:
  - `oweFacesAgain`'s per-photo error log, 15.6 s at 95,000 rows;
  - `photoDescriptionCandidatesByKey`'s key sort, 449 ms;
  - `filterOptionTally`'s tally, 79 ms at p99.

  Each is a local fix: log once per page with a count, sort inside the read. It is not an
  actor split. Two blocking calls cross the 10 ms bar and justify moving off the actor:
  - `deleteStagingIfNeeded`, 123 ms to 1.5 s for 2,000 files, on the actor in `removeLibrary`
    between the write and the notification;
  - `DerivedRemoval.perform`, which deletes files on the actor and reached 160 ms.

  `database()` open, 18–47 ms at the owner's size and seconds when migrating, crosses the bar
  too. But nothing that needs the catalog can run before it, so moving it buys nothing.
  `rootIsAvailable` is under the bar here (p99 9.5 ms under the suite's load). Its cost on a
  File Provider root is not measured.
- **M3.** A wanted build's read waits at most 1.3 ms for its turn, p95 0.2 ms, 0.2 % of its
  build at most. That is far below 100 ms and 5 %, so the read turns are not worth changing.
  The only queueing a wanted build meets is the heavy-load turn itself, when another heavy
  load already holds it.

## What it does not capture

- **Debug build and machine load.** The test host is unoptimized, and the load average was
  164–227. Holds and file times are wall-clock times on that machine.
- **The owner's data.**
  - His File Provider roots: `rootIsAvailable` and file removals there talk to `fileproviderd`.
  - His real face vectors: the 95,000 malformed rows are the generator's.
  - His real staged camera originals: 5–30 MB files, where the test used 512 KB.
- **Few builds.** Only 4 People and 3 Duplicates builds ran under `want` at the owner's size.
  The bound comes from the turn machine's own waits across 12,000 reads, not from many builds.
