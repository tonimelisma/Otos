# 0096 — Path Equality, Settled Naming, And Honest Progress

## Read first

- `docs/adr/0008-filesystem-source-of-truth-and-overlay-lifecycle.md` — asset
  identity is the filesystem path, and overlay is purged only on **proven**
  deletion. Increment 2 amends what "the same path" means; it does not weaken
  either rule.
- `docs/adr/0009-enrichment-storage-and-staleness.md` — the `(size, mtime)`
  enrichment signature. Increment 5 reuses its existing predicate rather than
  inventing a second staleness idea.
- `docs/adr/0019-import-plan-namespace-and-build-ownership.md` and
  `docs/adr/0021-concurrent-import-planning-and-destination-reservations.md` —
  namespace resolution and the reservation ledger, both of which increment 3
  makes case-correct.
- `docs/adr/0024-import-source-readiness-gate.md` — the readiness gate and the
  single-presentation-writer rule. Increment 9 closes the one hole ADR 0024
  documents but does not fix.
- `docs/design/import-bar.md` — the import screen spec. Increments 7 and 8
  change two of its statements; both changes are written into the spec in the
  same PR.

This plan assumes no prior context. Every increment states its goal, the exact
steps with file and line references, how to verify, and how to roll back.

---

## What is wrong today

One production run, 2026-08-19 22:00–22:07, captured with
`script/logs.sh capture --last 90m` into
`logs/capture-20260820T051040Z-p37834-prod.log` and cross-checked against the
live catalog at
`~/Library/Application Support/net.melisma.Otos/Catalog/catalog.sqlite`.

The user imported a 265-file SD card, ejected it, re-inserted it, and was told
there were **23 new items**. There were none. All 23 were videos Otos had
already imported four minutes earlier, and it imported them a second time under
different filenames.

```
21:59:49  catalog.scan  observed=265 changedCount=14 deleted=0
21:59:49  import.plan   copyCount=224 skipCount=41
22:00:10  mediaOperation.batch start  batch=1787202010189 files=224   (101 arw, 100 heif, 23 mp4)
22:02:33  eject
22:04:17  catalog.scan  observed=265 changedCount=23 deleted=23        ← identity churn
22:04:18  import.plan   copyCount=23  skipCount=242
22:04:19  catalog.enrichment.coordinator flush count=23 outcome=applied(count: 23)
   —      (no import.plan between here and the press: 51 seconds)
22:05:10  mediaOperation.batch start  batch=1787202310184 files=23     (23 mp4)
```

The two batches copied the same source files:

```sql
select relative_path, import_source_relative_path, import_batch_unix_ms, capture_wall_compact
  from media_asset where library_root_id = 7 and byte_size = 1476618665;

2026/08/20260814_163418.mp4 | PRIVATE/M4ROOT/CLIP/C7474.MP4 | 2026-08-20 05:00:10 | 20260814163418
2026/08/20260814_163607.mp4 | private/M4ROOT/CLIP/C7474.MP4 | 2026-08-20 05:05:10 | 20260814163418
```

Same source file. Two imports. Two names. Note the second row: its filename says
`163607` and its own `capture_wall_compact` says `163418`. **Otos wrote a file
whose name contradicts its own metadata**, and that self-contradiction is both
the cleanest detector for this defect class and the test oracle used throughout
this plan.

Four defects produced that run.

### D1 · Path identity is case-sensitive on a case-insensitive volume

The catalog held `PRIVATE/M4ROOT/CLIP/C7474.MP4` before the eject and
`private/M4ROOT/CLIP/C7474.MP4` after the re-insert — verified in the log (the
first import's `contentHash` lines carry the uppercase spelling, the second's
carry lowercase) and in the catalog (`select count(*) from media_asset where
relative_path glob '*PRIVATE*'` returns 0; 23 rows begin `private/`).

Whatever made the volume respell the directory between mounts, Otos has no
defence:

- `media_asset` is keyed `PRIMARY KEY (library_root_id, relative_path)` with
  SQLite's default binary TEXT comparison
  (`Otos/Stores/CatalogStorePersistence.swift:1290`).
- `reconcileMissingAssets` deletes any row whose `relativePath` is not in
  `observedPaths`, a `Set<MediaRelativePath>` with case-sensitive `Hashable`
  (`Otos/Stores/CatalogStore.swift:2798`).

So the re-scan inserted 23 "new" assets and deleted 23 "missing" ones — and
`reconcileMissingAssets` also deletes their thumbnail files
(`CatalogStore.swift:2808`, `2822-2826`). **Twenty-three files that were never
deleted had their entire overlay purged**, which is a direct breach of ARC-033
and ADR 0008's rule that a temporarily missing original is never a deletion.
Here the original was not even missing; it was spelled differently.

Otos already knows how to compare paths the way a volume does. It has done so
since reorganization landed:

```swift
// Otos/Services/FilesystemNamespaceSemantics+NameKey.swift:33
static func nameKey(relativePath: MediaRelativePath,
                    capabilities: VolumeNamespaceCapabilities) -> FilesystemNameKey
```

It normalizes Unicode and folds case according to
`probeVolumeCapabilities(rootURL:)`, which reads
`volumeSupportsCaseSensitiveNamesKey`. Measured on this machine: `/` reports
`caseSensitive=false, casePreserved=true`.

That owner is called by `ReorganizationPlanner` and **by nothing else**
(`grep -rn "nameKey(" Otos/` returns only `ReorganizationPlanner.swift` and the
definition). The catalog, the scanner, and the import namespace all compare raw
strings. Otos has one correct answer to "are these the same file" and applies it
in one of the three places that need it.

### D2 · The plan names files from a fact that is still being computed

`MediaTransferPlanner.namingTimestamp` (`Otos/Services/MediaTransferPlanner.swift:429`)
forks:

```swift
if let compact = bundle.wallCompact { return expandCompact(compact) }   // embedded local wall clock
let date = bundle.fallbackModifiedAt ?? Date(timeIntervalSince1970: 0)  // filesystem mtime
```

`capture_wall_compact` is written by enrichment. Rows re-inserted at 22:04:17
had none, so all 23 fell to the mtime branch — and for a video, mtime is when
recording **stopped**. The name deltas between the two batches are each clip's
duration (`+109 s`, `+46 s`, `+15 s`, …).

There is a gate meant to prevent exactly this, and its predicate is wrong:

```swift
// Otos/Services/MediaOperationCoordinator.swift:1189
snapshot.sourceMedia.contains(where: { $0.captureWallCompact == nil && $0.contentModifiedAt == nil })
```

It waits only when a file has **no date at all**. Every file on a card has an
mtime, so the guard fails and the coordinator never waits. `hasUsableDate`
(`Otos/Models/MediaOperationModels.swift:93`) is `captureWallCompact != nil ||
contentModifiedAt != nil`, so the `enriched` counter it feeds
(`MediaOperationCoordinator.swift:1183`) counts files that have *any* date, not
files that have been enriched. The name is a lie and the number it produces is
shown to the user as "waiting for metadata" progress.

The distinction the gate needs already exists in the schema.
`EnrichmentLeaseGateway.metadataStalenessSQLPredicate()`
(`Otos/Stores/EnrichmentLeaseGateway.swift:72`) defines exactly three states:

| `enriched_source_size` | `capture_wall_compact` | Meaning |
| --- | --- | --- |
| `NULL` | — | not yet enriched — **naming fact unsettled** |
| set | `NULL` | enrichment ran, no embedded wall clock — **mtime is final** |
| set | set | **settled** |

`PlanningFileFacts` (`Otos/Stores/MediaOperationGateway.swift:15-43`) selects
neither `enriched_source_size` nor `enriched_source_mtime`, so the planner cannot
tell "no date yet" from "no date ever".

### D3 · Enrichment landing does not invalidate the plan

`CatalogStore.applyEnrichmentBatch` (`Otos/Stores/CatalogStore.swift:1264`) ends
with `notifyCatalogChanged(...)` and **never** calls `bumpOccupancyRevision`. It
already computes `writeOutcome.structureChanged`, which is true precisely when
`best_capture`/`best_kind`/`best_format` moved — the fact the destination name is
derived from.

On the consumer side, `refreshSources` marks a session dirty only when
`lastSeenOccupancy[source] != currentOccupancy`
(`Otos/Services/MediaOperationCoordinator.swift:872`).

Net: enrichment corrected all 23 capture dates at 22:04:19.006, 535 ms after the
plan was built, and the plan sat unchanged for 51 seconds until the user pressed
Import. This is plan 0095's D2 in a different fact: staleness keys on *which rows
exist*, and the destination filename depends on *what a row says*.

### D4 · The import bar's progress indicator is animated by an underdamped spring

The data cannot move backwards. `ByteProgressTracker`
(`Otos/Services/MediaImportExecutor.swift:1554-1580`) is monotonic by
construction — `creditedBytes += max(0, observed - publishedBytes)` guarantees
`settledBytes + creditedBytes + inFlightOffsets` never decreases — and the bar's
value is `Double(completedCount)` (`Otos/Views/ImportPlanFooter.swift:280`),
where `settledCount` only increments.

The rendering is the problem:

```swift
// Otos/Views/ImportPlanFooter.swift:120
.animation(surfaceAnimation, value: drawn)          // .spring(response: 0.35, dampingFraction: 0.85)
```

Two facts combine. `dampingFraction < 1` **overshoots and rings back**. And
`drawn` changes on every progress tick, because `secondaryLine` carries live
bytes and a remaining-time estimate (`ImportBarPresentation.swift:343-346`), so
the spring is retargeted mid-flight and carries velocity into the next target.

On this run the fill also advanced in bursts: 23 clips averaging 587 MB across 8
workers settled at 22:05:25.357, then 22:05:34.712 and 22:05:34.845 (two within
133 ms), then 22:05:43.845. A +2 step into an overshooting spring reads as the
bar jumping backwards. That spring exists for surface transitions (the bar
sliding in, Done dismissing), not for a progress stream.

### Adjacent defects found while investigating

| # | Defect | Evidence |
| --- | --- | --- |
| D5 | Two planners name the same file two ways. `ReorganizationPlanner.swift:372` formats the mtime fallback with `formatter.timeZone = TimeZone(secondsFromGMT: 0)`; `MediaTransferPlanner.swift:438` uses `snapshot.timeZone` (`.current`). In PDT those differ by exactly 7 hours. Increment 12 of plan 0095 restored reorganization's menu entry point, so this is now reachable. | `grep -n "secondsFromGMT" Otos/Services/ReorganizationPlanner.swift` |
| D6 | The import destination namespace does not fold. `DestinationNamespace.entries` is `[MediaRelativePath: …]` and `occupancy(of:)` is an exact-case lookup (`Otos/Models/MediaOperationModels.swift:431`). On a case-insensitive destination, planning `X.mp4` while `X.MP4` exists returns `.absent`, so the planner promises a copy that `renamex_np(RENAME_EXCL)` (ARC-048) will refuse with `EEXIST`. Not data loss — publication is exclusive — but the plan lies and the entry fails. The cross-plan claim sets (`ledgerClaims`, `planClaims`, `MediaOperationCoordinator.swift:1204-1227`) have the same gap. | `FilesystemNamespaceSemantics.swift:69`, `:93` |
| D7 | `markExecutionUnavailable` yields directly to continuations, bypassing `publish()` (`MediaOperationCoordinator.swift:461`). Its own comment states the consequence: "any later unrelated `publish()` re-derives from `session.phase` … and would show this `.failed` phase instead, since nothing here is sticky." Plan 0095's D6 shape, surviving in one case. ADR 0024 narrows its claim to `makePresentation` having one call site and does not mention this. | `MediaOperationCoordinator.swift:439-462` |
| D8 | The spec says `queuedForReadiness` renders "A, with the button in its **queued disabled form**" (`import-bar.md:173`, `:533`). The mapper returns `.importPending` / `primaryEnabled: false` for both plain preparing and queued (`ImportBarPresentation.swift:162-180`), so pressing Import produces no acknowledgement at all and the copy begins unannounced up to a minute later. There is also no way to withdraw a queued request. | same |
| D9 | `.importPending` renders `Button(rendered.title) {}` — an empty action (`ImportPlanFooter.swift:343`). Safe only while the mapper never enables it. One user action, one implementation path: a control whose action is a no-op is not an implementation path. | same |
| D10 | Increment 8 of plan 0095 centralized `.disabled` into `RenderedPrimary` but left `.buttonStyle`, `.frame(height: 30)` and `.keyboardShortcut(…)` repeated in all seven cases, and `rendered.isDestructive` read by exactly one of seven — verbatim the D11 diagnosis that increment was written to fix. | `ImportPlanFooter.swift:338-400` |
| D11 | Increment 9's v16 migration removes disk-image removable roots it can currently prove and preserves unmounted ones, so `/Volumes/Raycast` and `/Volumes/BoltAI 2` — the two roots named in plan 0095's D10 evidence — are still in `library_root` and always will be. | `select path from library_root where kind='removableVolume'` |
| D12 | `MediaChoice.accessibilityValue` is `rawValue == "notRated" ? "not rated" : rawValue` (`Otos/Models/CatalogModels.swift:270`). DES-068's user-facing strings are derived from a **persisted** enum raw value; renaming a database value rewrites what VoiceOver says. The repo's own smell list names stringly-typed domain facts. | same |
| D13 | The sidebar's `All Imports…` row shows `importBatches.count` — a count of *batches* (`Otos/Views/SidebarView.swift:74`). Every batch row above it shows an item count, and `All Media` and the library rows show nothing. It is the only number in the sidebar that counts a different kind of thing than the row above it, and it reads as an item count. | same |
| D14 | `sourceStillMatches` maps `.library` to `.sourceNotReady` (`MediaImportExecutor.swift:466`) while `transferBytesToStaging` maps the same case to `.failed(.other)` (`:497`). Unreachable today, but the first would render "The card is still being read" for a library source. | same |
| D15 | `guard-design-system.sh`'s DES-002 check matches only `\.font\(\s*\.[A-Za-z0-9]+`, so `.font(someVariable)` or `.font(Font.title3)` escapes it entirely. | `script/guard-design-system.sh:47` |
| D16 | `dismissedBatchIDs` (`CatalogWindowViewModel.swift:209`) grows for the life of the process with no bound and no eviction. | same |
| D17 | `docs/design/design-system.md` retired L4 in its hierarchy section ("Three levels", line 62) but DES-021 (line 90) still normatively specifies "45% light / 45% dark (L4)" with the check "Accessibility Inspector on L3 and **L4**", and DES-028 (line 98) still requires "at least 3:1 for L4". `hig-validation.md:121` and `import-bar.md:598` also still reference it. `DesignPalette.l4` is gone from code, so the authoritative registry mandates a level the app cannot express. | same |
| D18 | `CatalogPath.relativePath` calls `resolvingSymlinksInPath()` on every scanned file URL (`Otos/Models/CatalogPath.swift:43`). Measured: it does not fold case on APFS, so it is not D1's cause — but it **does** rewrite a leading `/private` prefix (measured: `/private/tmp/…` → `/tmp/…`). A library root under `/private` would produce relative paths that do not match the root prefix. Latent, unexercised, and cheap to make explicit. | probe recorded in increment 2's research doc |
| D19 | Zero-byte files are catalogued as media and stay in the grid forever. `MediaEligibility.isCatalogMedia` classifies on `UTType` alone and never reads `byte_size` (`Otos/Services/MediaEligibility.swift:25`, whose doc comment states the split deliberately: "Decodability and enrichment unsupported outcomes are separate"). The tile is honest — `thumbnailUnavailable` is true and it draws `photo.slash` (`MediaAssetTilePresentation.swift:186`) — but the item occupies the grid permanently with no statement of *why* and no action. Measured: 5 such rows, 3 of them OneDrive conflict artifacts (`…-<host>-safeBackup-0001.heif/.arw`, 0 bytes, sitting beside intact originals). A 0-byte file on a card is also planned as a copy today, since `hasAnyDate` is true from its mtime. See owner decision Q4. | `select relative_path, byte_size from media_asset where byte_size = 0`; `op=preview.decode phase=fail … decodeMs=1` |
| D20 | **An erase-only run has no outcome state at all.** `import-bar.md:304` and `:455` specify L1 `Card erased · 181 items deleted`, primary `Eject Card`, and "Selection does not move". No such branch exists in `ImportBarPresentation.done` — every branch there is a copy-run branch. Observed 2026-08-19 22:52: an erase of 265 files rendered ✓ `0 items copied and verified` with a green checkmark and a primary button reading `Show These Items` (`ImportBarPresentation.swift:462`). | `import.plan copyCount=0 skipCount=265`; `mediaOperation.batch start bytes=0 files=0`; user-reported screen |
| D21 | **An erase-only run mints an `ImportBatchID` it will never fill, and the selection follows it.** `runExecution` creates `let batch = ImportBatchID()` unconditionally (`MediaOperationCoordinator.swift:485`) even with zero copy entries; the terminal `currentBatchID` fallback publishes it and `followNewBatchesOnce` navigates to it. Contradicts `import-bar.md:455`. Plan 0095 increment 8 gated this for `.executing` only. | `catalog.projection.window … sidebarSelection=importBatch:1787205148920` at 22:52:29.997, then `resolvedSidebarSelection` falling back |
| D22 | **`Show These Items` on that state reveals nothing.** `select count(*) from media_asset where import_batch_unix_ms = 1787205148920` → **0**. Plan 0095's D12 shape surviving in the branch increment 8 did not touch. | same |
| D23 | **The one irreversible operation in Otos is completely uninstrumented.** `deleteSource` calls `FileManager.removeItem` (`MediaImportExecutor.swift:1375`) and logs **only on failure** — no start, no per-file, no count, no summary. Grepping a 30-minute capture spanning an erase of 265 files for any delete/trash/erase op returns **nothing**. It is not possible to prove from the logs that the user's files were deleted. `phase=verified skippedPreexisting=265` reports the *plan's* skip count, not what was removed. | `logs/capture-20260820T055352Z-p1218-prod.log` |
| D24 | **A skipped deletion reports success.** `deleteSourceIfRequested` returns `true` when `byteSize` or `contentModifiedAt` is nil (`MediaImportExecutor.swift:1309-1315`) — the file stays on the card and is counted as erased. Once D20's `N items deleted` string exists it will be wrong; today nothing counts at all. | same |
| D25 | **A deletion failure is counted as a copy failure.** `failedCount += 1; failureReasons.append(.other)` inside the deletion loop (`MediaImportExecutor.swift:392`) feeds the *copy* failure count, so an erase failure makes the bar describe a copy problem that did not occur. `EntryTotals` has `publishedCount`/`publishedBytes`/`failedCount` and no notion of deletion at all — the erase path is grafted onto the copy path's accounting, which is the shared root cause of D22, D24 and D25. | same |
| D26 | **Erase leaves the card dirty.** The erase set is `entry.isSkipPreexisting` (`MediaImportExecutor.swift:384`) — a copy-side fact. `deleteSourceIfRequested` deletes only `entry.source.sourceURL`, never `entry.companionDestinations`, so a sidecar Otos just copied is left on the card. Non-media files are excluded at scan and never erased; this card logged `catalog.scan.skippedNonMedia count=2`. After "Erase 265 Items" the card still held those files. See owner decisions Q5/Q7 and `docs/research/2026-08-19-source-file-disposition-prior-art.md`. | `op=catalog.scan.skippedNonMedia phase=skip rootPath=/Volumes/4152150790 count=2` |

### Damage already on disk

Of 706 videos in `/Users/…/Pictures/Camera Roll`, 129 groups share an exact byte
size, covering **248 extra copies**. Parsing the timestamps out of the filenames
of the same-size pairs:

| Filename delta | Pairs | Cause |
| --- | --- | --- |
| exactly `+7h` (25200 s) | 39 | mtime rendered in UTC vs. the embedded local wall clock (part of the 889 pre-existing rows below) |
| 1–600 s | 12 | D2 — mtime (recording end) vs. capture date |
| other | 21 | not individually characterized |

Measured against the import journal, the split is exact. Of the 912 catalog rows
whose filename stem disagrees with their own `capture_wall_compact`, **889 have
no `import_batch_unix_ms`** and **23 have one**:

```sql
SELECT (import_batch_unix_ms IS NOT NULL) AS otos_imported, count(*) …
  →  0 | 889     -- pre-existing, named by an earlier tool from the mtime in UTC
     1 |  23     -- exactly the videos Otos re-imported on 2026-08-19
```

So the `+7h` pairs are **not** Otos's import doing it twice. The journal proves it:

```
2026/08/20260801_142905.mp4 | src=private/M4ROOT/CLIP/C7363.MP4 | batch=2026-08-02 06:02:12 | wall=20260801142905
2026/08/20260801_212905.mp4 | src=(null)                        | batch=(null)              | wall=20260801142905
```

The `21:29:05` copy has **no import journal at all** — it was already in the
library, named by some earlier tool from the mtime in UTC. Otos imported the card,
correctly named its copy `14:29:05` from the embedded wall clock, did not
recognize the existing file as the same content, and added a duplicate. 524 of
the 706 destination videos have no import journal, so most of this library
predates Otos.

That is a **deduplication** question, not a defect this plan can decide. It is
listed under Owner decisions below. What this plan does is stop Otos creating new
duplicates and remove D5's ability to create `+7h` ones itself.

---

## Owner decisions — resolved 2026-08-19

All decisions this plan waited on have been answered in a live session. Nothing
below is an assumption; each row records what was decided and why.

| # | Question | Decision |
| --- | --- | --- |
| Q1 | What does the **State E · Working** progress bar measure? | **Bytes.** The bar is the *visual* indicator and bytes move steadily; the item count is already stated in L1 (`Importing 12 of 42`) and the byte figure in L3 (`19 MB of 68 MB`), so the two lines already carry both facts and nothing is lost. **State A · Preparing keeps items** — during the card scan no byte total exists yet. The **batch row's 32 pt indicator** is a visual progress bar and follows the same rule as State E. Changes `import-bar.md:249` and `:577` to say which quantity, which they currently leave ambiguous. |
| Q2 | Should Otos recognize an existing destination file as the same content under a different name? | **Out of scope for this plan.** 889 pre-existing library rows were named by an earlier tool from the mtime in UTC and Otos cannot see them, but content-addressed dedup means hashing ~6,500 destination files at plan time — its own cost model, its own failure modes, its own ADR. This plan makes *new* duplicates impossible. |
| Q3 | Should the 248 existing duplicate copies be repaired? | **Deferred.** Increment 1 ships a read-only detector; decide on a real post-fix number. |
| Q4 | What should Otos do with a zero-byte file? | **Not imported, but deleted with the media.** It gets a new plan disposition (see Q5) and is included in the erase set. **No bar copy is required** — the owner explicitly does not want these named in the import bar. Note this is *not* the `.blocked` disposition: blocked entries are attention items, and attention items set `eraseEnabled: false` (`ImportBarPresentation.swift:279`), so a card holding a zero-byte file could never be erased — the opposite of the decision. Researched in `docs/research/2026-08-19-zero-byte-media-handling.md`. |
| Q5 | What is the **erase set**? Today it is `entry.isSkipPreexisting` only (`MediaImportExecutor.swift:384`) — a copy-side fact used as a card-side one, so sidecar originals and card debris survive every erase. | **The full model below**, adapted from `gomediaimport` prior art and deliberately simpler than it. Researched in `docs/research/2026-08-19-source-file-disposition-prior-art.md`. |
| Q6 | Should erase use permanent deletion or the card's Trash? | **Permanent (`removeItem`), and now owned by an ADR.** The recoverability guarantee is the verified library copy that `eraseConfirmationProvenClean` already proves — not a `.Trashes` folder, which would not free the space the user is erasing to reclaim. One exception the ADR must state rather than leave implicit: a zero-byte file is *not* in the library, so its deletion is unrecoverable — of zero bytes, so nothing is lost. |
| Q7 | How configurable is any of this? | **Exactly one setting: "Copy sidecars into the library."** It governs *copying* only. No per-extension action table — `gomediaimport` is a CLI where a config file is the only surface; Otos can change a default in a release. Cruft deletion is never configurable and happens only as part of an explicit Erase. |

### The erase model (Q4, Q5, Q7)

| Class on the card | Copied to library | Deleted on Erase |
| --- | --- | --- |
| Media | yes | yes |
| Media already in the library | no | yes |
| Zero-byte media (new `excluded` disposition) | no | yes |
| Useful sidecars `.xmp` / `.srt` | **only if "Copy sidecars" is on** | yes, either way |
| Cruft sidecars `.thm .ctg .aae .lrf .mpl .cpi` | no | yes |
| Source artifacts (Sony `M4ROOT/THMBNL`, `M4ROOT/CLIP/*.xml`, `._*`, card trash) | no | yes |
| Unknown non-media | no | **no** |

If the sidecar setting is off, `.xmp`/`.srt` are simply reclassified as cruft —
not copied, still deleted. ARC-045 already names the source-artifact set
verbatim, as **ignore paths**; this turns an existing ignore set into an erase
set rather than inventing one.

**Assumption stated, not decided:** an orphan `.xmp` with no matching media file
on the card follows the same rule as a parented one. This matches
`gomediaimport`, which gives orphan sidecars a destination and copies them. If
orphans should be left alone instead, that is a one-line change to the
classifier.


## Constraints

| # | Constraint | Why |
| --- | --- | --- |
| C1 | Every behavior change updates its `docs/requirements.md` row in the same PR. | CLAUDE.md |
| C2 | No new process/workflow/tooling rows in `docs/requirements.md`. | CLAUDE.md |
| C3 | Tests assert observable behavior or public owner boundaries. No test reads source files as text. | CLAUDE.md, CI-guarded |
| C4 | Each increment is one PR with a full `script/verify.sh`, branched from a green `main`, in its own worktree. | CLAUDE.md |
| C5 | Increment 1 lands first and alone. Every later increment's runtime verification reads its logs. | precedent: plan 0095 C5, for the same reason |
| C6 | **There shall be exactly one owner of "are these two paths the same file."** No increment may add a second case-folding or Unicode-normalizing comparison. | D1, D6 |
| C7 | **There shall be exactly one owner of "what timestamp names this file."** | D2, D5 |
| C8 | No increment weakens ADR 0008: overlay is still purged only on proven deletion, and identity is still the filesystem path. Increment 2 changes what path *equality* means, not what identity *is*. | ADR 0008, ARC-033 |

---

## Target end state

```
One path-equality owner:
  FilesystemNamespaceSemantics.nameKey(relativePath:capabilities:)
        │  capabilities probed once per root at registration, persisted on library_root
        ├── catalog identity + scan reconciliation   (increment 2)  ← new
        ├── import destination namespace + claims    (increment 3)  ← new
        └── reorganization planner                   (already correct, becomes the reference)

One naming owner:
  ImportNaming.timestamp(for:in:)                                  (increment 4)
        ├── MediaTransferPlanner
        └── ReorganizationPlanner

Settled-fact gating, one mechanism:
  enrichment writes a naming column
        → CatalogStore bumps occupancyRevision for that root        (increment 6)
        → coordinator marks the session dirty and replans
        → the plan's readiness predicate asks "is every source row's
          naming fact settled?" using EnrichmentLeaseGateway's own
          staleness predicate — not a second derivation              (increment 5)

One yield path:
  publish() is the only continuation.yield outside subscription replay
                                                                     (increment 9)
```

---

## Increments

Each is a separate PR. Steps are ordered; verification is the gate.

---

### Increment 1 · Instrument the facts this plan is about

**Goal.** Make every fact this plan changes observable *before* changing it. The
2026-08-19 run took a catalog query to explain because four of the five decisive
facts were not logged. (D1–D4, and every later increment's verification.)

**Steps.**

1. **Path churn.** In `CatalogStore.reconcileMissingAssets`
   (`CatalogStore.swift:2798`), before deleting, emit one line per deleted row up
   to a cap of 20, then a summary:
   `op=catalog.scan.reconcile phase=delete rootPath=… relativePath=… hadThumbnail=… hadEnrichment=…`
   and `op=catalog.scan.reconcile phase=deleteSummary rootPath=… count=… logged=…`.
   The cap keeps a 6,000-file root from flooding; the paths are what turn
   `deleted=23` into a diagnosis.
2. **Volume facts at attach.** Extend `op=catalog.removable.attach phase=finish`
   (`RemovableVolumeMonitor.swift`) with `caseSensitive=… casePreserved=…
   deviceModel=… volumeFormat=…`, read from the resource values the monitor
   already fetches plus `volumeSupportsCaseSensitiveNamesKey` and
   `.volumeSupportsCasePreservedNamesKey`. Do the same for library roots at
   registration, category `Catalog`.
3. **Naming decision.** In `MediaTransferPlanner.namingTimestamp`
   (`MediaTransferPlanner.swift:429`), emit
   `op=import.naming phase=resolve relativePath=… source=wallClock|mtime|epochFallback`.
   Sample at most 20 per plan build plus a summary
   `op=import.naming phase=summary rootPath=… wallClock=… mtime=… epochFallback=…`.
   A plan whose summary shows `mtime=23` on a video card is D2, visible at a
   glance.
4. **Enrichment → planning linkage.** `op=catalog.enrichment.batch phase=finish`
   (`CatalogStore.swift:1305`) gains `rootPaths=…` and `namingChanged=…` (the
   count of rows in this batch whose `capture_wall_compact` changed). Increment 6
   turns `namingChanged` into an occupancy bump; this increment only reports it.
5. **The presentation stream.** There is today **no** log anywhere on the path
   from `MediaOperationCoordinator.publish()` to what the bar renders — the
   existing `op=import.coordinator phase=receive` is the coordinator receiving
   *catalog* changes, not the UI receiving frames. Add, rate-limited to at most
   one line per 250 ms per source:
   - `op=import.presentation phase=publish sourcePath=… state=… completedCount=… totalCount=… completedBytes=… batchID=…`
     in `publish()` (`MediaOperationCoordinator.swift:1366`)
   - `op=import.presentation phase=apply sourcePath=… drawnKind=… primaryAction=… primaryEnabled=…`
     in `CatalogWindowViewModelMediaOperations.applyImportPresentations`

   Without this, "the bar jumped" is unfalsifiable from logs.
6. **The self-contradiction detector.** Add
   `script/catalog-query.sh name-vs-capture` — a read-only helper that runs one
   SQL statement against the production catalog and prints rows whose filename
   stem disagrees with their own `capture_wall_compact`:

   ```sql
   SELECT library_root_id, relative_path, capture_wall_compact
     FROM media_asset
    WHERE capture_wall_compact IS NOT NULL
      AND relative_path GLOB '*/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9].*'
      AND CAST(substr(replace(relative_path, rtrim(relative_path, replace(relative_path, '/', '')), ''), 1, 8) ||
               substr(replace(relative_path, rtrim(relative_path, replace(relative_path, '/', '')), ''), 10, 6) AS INTEGER)
          <> capture_wall_compact;
   ```

   **Filter to `import_batch_unix_ms IS NOT NULL`.** Measured on the production
   catalog: the unfiltered query returns 912 rows, of which **889 have no import
   journal** — pre-existing library files another tool named from the mtime in
   UTC, which Otos did not create and cannot currently recognize (owner decision
   Q2) — and **23 have one**, exactly the videos re-imported on 2026-08-19.
   Filtered, the detector is an exact oracle for Otos-caused damage: increments
   2–6 must take it to zero new rows, and the 889 are reported separately as
   pre-existing.

   **The script must be read-only** — no `UPDATE`, no `DELETE`, no schema change
   — and CI's script-inventory check should assert that.
7. **The erase path.** `deleteSource` (`MediaImportExecutor.swift:1362`) is the
   only irreversible operation in Otos and logs only on failure (D23). Add
   `op=import.erase phase=start rootPath=… plannedCount=…`, one
   `phase=deleted relativePath=… bytes=…` per file capped at 20, and
   `phase=finish rootPath=… deleted=… skipped=… failed=… bytesFreed=…`. The
   summary must count what was **actually removed**, not the plan's
   `skipCount` — the existing `phase=verified skippedPreexisting=265` reports
   the latter and is what made a 265-file deletion unprovable. `gomediaimport`
   reports exactly this (per-file when verbose, plus a count and total bytes
   freed); Otos should not report less about the same act.
8. Record in `docs/adr/0015-observability.md` that the presentation stream, the
   naming decision, and the erase path are now instrumented.

**Verify.** `script/verify.sh`. Then: attach the card, import, eject, re-insert,
and confirm from `script/logs.sh capture --last 15m` alone — without a catalog
query — that you can see (a) which paths were deleted and why, (b) that the
naming summary reports `mtime=23`, (c) the presentation frames the bar rendered.
Run the detector and record the current count as the baseline.

**Rollback.** Revert. No behavior depends on it.

---

### Increment 2 · One path-equality owner, applied to catalog identity

**Goal.** Eliminate D1 and D18. A file that is respelled is the same file.

**Research first.** Write `docs/research/2026-…-volume-path-equality.md` before
writing code:

- Measure `volumeSupportsCaseSensitiveNamesKey` and
  `volumeSupportsCasePreservedNamesKey` for: the internal APFS volume, the
  OneDrive `CloudStorage` folder, a mounted exFAT SD card, a mounted DMG, and an
  SMB mount if one is reachable. Record what each reports. (Already measured on
  the internal volume: `caseSensitive=false, casePreserved=true`.)
- Measure whether the SD card respells `PRIVATE` across remounts, and whether
  anything Otos does triggers it. **This is confirmatory, not blocking** — the
  fix does not depend on the cause, because `volumeSupportsCaseSensitiveNames` is
  authoritative for how the volume itself defines path equality. If the hardware
  is unavailable, record the gap exactly as
  `docs/research/2026-08-19-removable-volume-qualification.md` did.
- Record the `resolvingSymlinksInPath()` probe for D18: it does **not** fold case
  on APFS, and it **does** strip a leading `/private`.

**Steps.**

1. `library_root` gains `case_sensitive_names INTEGER` and
   `prefers_decomposed_unicode INTEGER`, both nullable. Populate at root
   registration and at every removable/device attach from
   `FilesystemNamespaceSemantics.probeVolumeCapabilities(rootURL:)`. Schema
   version bump with the repo's existing migration pattern
   (`CatalogStorePersistence.swift`, alongside v16).
2. `RootRuntimeState` carries a `VolumeNamespaceCapabilities`. A root whose
   capabilities are unknown (never probed, currently detached) defaults to
   case-insensitive + precomposed, matching
   `probeVolumeCapabilities`'s own documented fallback. Two owners must not
   disagree about the default.
3. `media_asset` gains `relative_path_key TEXT NOT NULL DEFAULT ''` — the
   `FilesystemNameKey.rawValue` for that row under its root's capabilities —
   written by the same upsert that writes `relative_path`. Add
   `CREATE INDEX idx_media_asset_relative_path_key ON media_asset(library_root_id, relative_path_key)`.
   Do **not** make it the primary key: `relative_path` stays the identity and the
   display spelling (ADR 0008, C8). The key is how equality is *tested*.
   - Compute it in Swift, not SQL. SQLite's `NOCASE` is ASCII-only; filenames are
     not. `nameKey` already does Unicode-correct folding.
4. `upsertScannedFile` (`CatalogStorePersistence.swift:1265`) gains a preceding
   lookup: if a row exists with the same `(library_root_id, relative_path_key)`
   but a different `relative_path`, **UPDATE its `relative_path` in place** and
   log
   `op=catalog.scan.reconcile phase=respell rootPath=… from=… to=…`. Do not insert.
   Every overlay column, the thumbnail, the import journal, and `media_choice`
   survive, because the row survives.
5. `reconcileMissingAssets` (`CatalogStore.swift:2773`) compares
   `relative_path_key` against a `Set<FilesystemNameKey>` built from the scan's
   observed paths, not `Set<MediaRelativePath>`. `CatalogScanner.swift:311` builds
   that set.
6. Same treatment for `media_companion` (`reconcileMissingCompanions`) — it has
   the identical `relative_path` keying.
7. Migration: backfill `relative_path_key` for every row. Handle the case where
   two existing rows fold to the same key with a deterministic merge — keep the
   row with a non-null `import_batch_unix_ms`, else the one with enrichment, else
   the lexicographically first `relative_path`; delete the other and its
   thumbnail. Log every merge. (Measured on the current production catalog: **zero**
   fold collisions in `media_asset` and `media_companion`, so this path is
   defensive, but it must exist and it must be tested.)
8. D18: replace `resolvingSymlinksInPath()` in `CatalogPath.relativePath`
   (`CatalogPath.swift:43`) with `standardizedFileURL` only, and document why —
   the root path was already symlink-resolved at registration
   (`normalizedDirectoryPath`, `CatalogPath.swift:13`), so resolving each file
   again buys nothing and its `/private` rewriting can break the prefix match.

**Verify.** `script/verify.sh` plus:
- `FilesystemNameKeyTests` extended for the ASCII and non-ASCII folding cases and
  for both capability values.
- `CatalogStoreCaseIdentityTests`: scan a fixture root observing `A/B.JPG`, then
  re-scan observing `a/b.jpg`, and assert on a **case-insensitive** root that the
  row count stays 1, `relative_path` becomes the new spelling, and the enrichment
  columns and thumbnail path are unchanged. On a **case-sensitive** root, assert
  two rows.
- `CatalogStoreSchemaMigrationTests` for the backfill and the collision merge.
- Runtime: import, eject, re-insert. Confirm from the logs alone that
  `catalog.scan phase=finish` reports `deleted=0` and that any respell appears as
  `phase=respell`, not `phase=delete`.

**Rollback.** Revert. The migration is additive; the added columns are ignored by
the prior build.

---

### Increment 3 · The destination namespace and the claim ledger fold too

**Goal.** Eliminate D6, and finish C6 — one path-equality owner in all three
places.

**Steps.**

1. `DestinationNamespace` (`Otos/Models/MediaOperationModels.swift:425-439`) keys
   `entries` by `FilesystemNameKey`. `occupancy(of:)` folds its argument using the
   destination root's capabilities before lookup. The namespace carries the
   capabilities it was built with, so no caller can look up a key from a different
   volume's rules.
2. `FilesystemNamespaceSemantics.enumerateNamespace`
   (`FilesystemNamespaceSemantics.swift:65`) takes the capabilities and folds each
   enumerated name as it inserts.
3. `ImportPlanningSnapshot` carries the destination's capabilities, probed once
   in `CatalogStore.importPlanningSnapshot` (`CatalogStore.swift:416`), so the
   planner never probes per file.
4. The cross-plan reservation sets — `ledgerClaims` and `planClaims`
   (`MediaOperationCoordinator.swift:1204-1227`) and `additionalReserved` —
   become `Set<FilesystemNameKey>`. Two sources importing `IMG_1.JPG` and
   `img_1.jpg` into one case-insensitive library must contend for one name.
5. `ReorganizationPlanner` already folds correctly. Extract nothing new; instead
   confirm by reading that it and the import path now call the same function with
   the same capabilities, and add a comment at `nameKey`'s definition naming its
   three callers.

**Verify.** `script/verify.sh` plus a planner test asserting that on a
case-insensitive destination containing `2026/08/X.MP4`, planning a source that
would name `2026/08/X.mp4` yields `.skipPreexisting` or a suffix — never a `.copy`
to the colliding name; and the mirrored test asserting it *does* copy on a
case-sensitive destination. Plus an `ADR 0021` reservation test with two sources
whose names differ only in case.

**Rollback.** Revert.

---

### Increment 4 · One naming owner

**Goal.** Eliminate D5 and satisfy C7.

**Steps.**

1. Add `nonisolated enum ImportNaming` beside `ImportDestinationDate`
   (`Otos/Services/`), owning one function:
   `static func timestamp(wallCompact: Int64?, fallbackModifiedAt: Date?, calendar: Calendar, timeZone: TimeZone) -> CaptureWallComponents?`.
   It returns `nil` when there is no usable date, rather than the current
   `Date(timeIntervalSince1970: 0)` sentinel — an epoch-zero filename is a
   fabricated value, and `MediaTransferPlanner` already has
   `.blocked(.noUsableDate)` for the real case
   (`MediaTransferPlanner.swift:206`).
2. `MediaTransferPlanner.namingTimestamp` (`:429`) becomes a call to it.
3. `ReorganizationPlanner.swift:369-374` becomes a call to it. **The
   `TimeZone(secondsFromGMT: 0)` formatter is deleted**, along with the
   `DateFormatter` allocation inside a per-file loop.
4. `ReorganizationPlanner` is given the same `calendar`/`timeZone` its snapshot
   carries, from the same source `importPlanningSnapshot` uses
   (`CatalogStore.swift:422-423`).

**Verify.** `script/verify.sh` plus `ImportNamingTests` asserting that both
planners produce the identical stem for the same facts, across: wall clock
present; wall clock absent with mtime; both absent. Add one test that pins the
local-time expectation with an explicit non-UTC `TimeZone` fixture so a future
regression to UTC fails rather than passing in whatever zone CI runs in.

**Rollback.** Revert.

---

### Increment 5 · The plan knows whether its naming facts are settled

**Goal.** Eliminate D2 — the plan can no longer name a file from a fact that is
still being computed.

**Steps.**

1. `PlanningFileFacts` (`Otos/Models/MediaOperationModels.swift:61`) gains
   `isNamingFactSettled: Bool`.
2. `MediaOperationGateway.fetchPlanningSourceMedia`
   (`MediaOperationGateway.swift:15`) selects `enriched_source_size` and
   `enriched_source_mtime` and derives the flag from **the existing predicate**,
   `EnrichmentLeaseGateway.metadataStalenessSQLPredicate()`
   (`EnrichmentLeaseGateway.swift:72`). Reuse it as SQL in the same `SELECT`
   (`NOT (<predicate>) AS naming_settled`). Do not re-implement the staleness
   rule in Swift — that is exactly the second derivation this plan exists to
   remove.
3. `hasUsableDate` (`MediaOperationModels.swift:93`) is renamed
   `hasAnyDate`, because that is what it tests. Its one consumer at
   `MediaOperationCoordinator.swift:1182` is renamed with it: `missingDates` →
   `filesWithNoDateAtAll`.
4. `shouldWaitForMetadata` (`MediaOperationCoordinator.swift:1181`) changes its
   condition from
   `contains(where: { $0.captureWallCompact == nil && $0.contentModifiedAt == nil })`
   to `contains(where: { !$0.isNamingFactSettled })`, and reports honest counters:
   `done` is the count of settled rows, `total` the source count.
5. The `sourceKind != .deviceMTP` exclusion at `:1187` stays. Document why in the
   same comment: device staging rows are enriched on a different path and gating
   on this predicate would hold the bar open indefinitely. If that turns out to be
   wrong it is its own increment, not a passenger here.

**Verify.** `script/verify.sh` plus:
- `MediaOperationGatewayTests` asserting the flag for all three schema states
  (not enriched; enriched with no wall clock; enriched with one).
- A coordinator test asserting a source with one unenriched row holds
  `waitingForMetadata` and does not reach `.ready`.
- A coordinator test asserting a source where enrichment ran and found no embedded
  date does **not** wait forever — it reaches `.ready` and names from mtime.
- Runtime: re-insert a card and confirm `op=import.naming phase=summary` reports
  `mtime=0` for a video card whose clips carry QuickTime creation dates.

**Rollback.** Revert.

---

### Increment 6 · Enrichment landing invalidates the plan

**Goal.** Eliminate D3. One mechanism, shared with increment 5: enrichment bumps,
the coordinator replans, and increment 5's predicate re-evaluates against the
settled facts.

**Steps.**

1. `EnrichmentBatchWriteOutcome` gains `namingChangedRoots: Set<LibraryRootPath>`
   — roots for which this batch changed `capture_wall_compact`. The write already
   computes `structureChanged`; add the narrower fact beside it rather than
   reusing `structureChanged`, which also covers kind and format and would bump on
   changes that cannot move a filename.
2. `CatalogStore.applyEnrichmentBatch` (`CatalogStore.swift:1264`) calls
   `bumpOccupancyRevision(for:)` for each root in `namingChangedRoots`, before
   `notifyCatalogChanged`. This is the correct revision: `bumpOccupancyRevision`'s
   own documentation says it is for "a real import-namespace change (media
   added/removed/**renamed**/resized)" (`CatalogStore.swift:337`), and a changed
   capture date renames the file the plan will write.
3. Watch the cost. Enrichment ran 96 batches in the captured 90-minute window;
   most touched the destination library, where a bump forces a replan of every
   attached source. Log
   `op=catalog.occupancyRevision phase=bump reason=enrichmentNaming` and, in
   verification, count the replans a full-library enrichment pass triggers. If it
   is more than a handful per minute, coalesce in the coordinator — not by
   dropping bumps in the store.

**Verify.** `script/verify.sh` plus:
- A `CatalogStoreEnrichmentTests` case asserting the planning-change stream emits
  with an advanced `occupancyRevision` when a batch changes `capture_wall_compact`,
  and does not when it changes only `duration_seconds`.
- A coordinator adversarial case: build a plan from unenriched rows, apply
  enrichment, assert the session goes dirty and the rebuilt plan's `copyCount`
  drops to 0.
- Runtime: the whole 2026-08-19 sequence — import, eject, re-insert. The bar must
  read `Everything on this card is imported`, `import.plan phase=finish` must
  report `copyCount=0`, and increment 1's detector must find zero new rows.

**Rollback.** Revert. Increments 2 and 5 together already prevent the observed
failure — 2 stops the rows being re-inserted unenriched, 5 stops an unsettled
plan being offered. This closes the residual race where a row is legitimately
re-enriched after a plan was built.

---

### Increment 7 · The bar moves once, forward, and smoothly

**Goal.** Eliminate D4. Q1 is answered: the bar measures **bytes**.

**Steps.**

1. Scope the animation. `.animation(surfaceAnimation, value: drawn)`
   (`ImportPlanFooter.swift:120`) stops applying to the middle zone's progress
   indicator. The surface transition (bar appearing, leaving, changing state
   *kind*) keeps the spring, keyed on `drawn.kind` rather than the whole value;
   the progress indicator gets `.animation(.linear(duration: 0.2), value:)` on its
   own fraction, or no implicit animation at all. **`dampingFraction: 0.85`
   overshoots by construction and must never drive a progress indicator.**
2. `ImportBarPresentation.working` (`ImportBarPresentation.swift:321-366`)
   returns `.determinate(completed: progress.completedBytes, total:
   progress.totalBytes)`. L1 keeps `Importing 12 of 42` and L3 keeps
   `19 MB of 68 MB`, so both facts stay stated — only the *visual* bar changes.
   The batch row's 32 pt indicator follows the same rule. **State A · Preparing
   keeps items**: during the card scan there is no byte total. Update
   `import-bar.md:249` and `:577` to name the quantity, since the spec's
   ambiguity is what let this ship.
3. `remainingTimeClause` (`ImportBarPresentation.swift:371`) is re-checked against
   an 8-worker large-file run: with clips of wildly different sizes the estimate
   swings. If it is not stable enough to be honest (DES-032), widen its minimum
   sample beyond `elapsedMs >= 2000` — measured, not guessed, from increment 1's
   presentation logs.

**Verify.** `script/verify.sh` plus a mapper test pinning the drawn track value
for a known progress sample. Runtime: import a video-heavy card and confirm from
increment 1's `op=import.presentation phase=apply` frames that the rendered
fraction is non-decreasing across every frame. Screenshot light and dark
(DES-022), grayscale one (DES-029), run once with Reduce Motion (DES-075), and
tab through with no mouse (DES-080).

**Rollback.** Revert.

---

### Increment 8 · A queued Import says so, and no control has a dead action

**Goal.** Eliminate D8, D9, D10.

**Steps.**

1. `ImportBarDrawnState.PrimaryAction` gains `.importQueued`. The mapper routes
   `.queuedForReadiness` to it (`ImportBarPresentation.swift:162`), and
   `RenderedPrimary` gives it the title the spec's "queued disabled form" implies —
   `Import` with `isEnabled: false` is what ships today and is indistinguishable
   from plain preparing, so pick a title that states the fact (`Waiting…` or
   `Import Queued`), write it into `import-bar.md:533`'s table, and cite DES-035.
2. Delete `.importPending`'s empty action closure
   (`ImportPlanFooter.swift:343`). `.importPending` and `.importQueued` are both
   non-actionable states; render them through a code path that has no action to
   call, not a `Button` with `{}`.
3. `RenderedPrimary` (`ImportPlanFooter.swift:66`) absorbs the four modifiers
   still repeated across all seven cases — `buttonStyle`, `frame(height:)`,
   `keyboardShortcut`, `tint` — so the `switch` in `primaryButton` chooses only
   the *action*, and every presentational fact comes from one value. `isDestructive`
   currently reaches one of seven cases, which is verbatim the D11 shape plan
   0095 increment 8 set out to remove.
4. Extend `ImportPlanFooterRenderedPrimaryTests` to assert every case's full
   render intent, including the new one.

**Verify.** `script/verify.sh` plus the extended renderer tests. Runtime: press
Import while a card is still scanning and confirm the bar acknowledges it.
Design checks per CLAUDE.md §Code Review (C), citing the `DES-*` IDs satisfied.

**Rollback.** Revert.

---

### Increment 9 · One yield path

**Goal.** Eliminate D7 and make ADR 0024's rule true as written.

**Steps.**

1. `SourceSession.phase` gains
   `.executionUnavailable(summary:generation:attentionItems:)`.
   `markExecutionUnavailable` (`MediaOperationCoordinator.swift:439`) sets that
   phase and calls `publish()`. Delete the direct `continuation.yield` at `:461`
   and the misleading `.failed(reason: .unexpected(detail: "executionUnavailable"))`
   bookkeeping phase.
2. `presentation(for:)` maps the new phase to
   `MediaOperationSourceState.executionUnavailable`. The override becomes durable:
   a later unrelated `publish()` re-derives it instead of replacing it.
3. Assert the rule structurally: after this, `MediaOperationCoordinator.swift`
   contains exactly two `continuation.yield` call sites — the subscription replay
   at `:237` and `publish()` at `:1369`. Add that to
   `script/guard-view-passivity.sh` or a sibling guard, with a self-test.
4. Rewrite ADR 0024's "Also owns (increment 6)" section: the rule is now one
   *yield* path, not merely one *constructor*. Delete the sentence claiming no
   third call site exists in favour of the stronger, now-true statement.

**Verify.** `script/verify.sh` plus a coordinator test that fires an unrelated
`publish()` after `markExecutionUnavailable` and asserts the presentation still
reads `.executionUnavailable`. This test fails on `main` today.

**Rollback.** Revert.

---

### Increment 10 · Disk-image roots, finished

**Goal.** Eliminate D11.

**Steps.**

1. `library_root` gains `device_model TEXT`, recorded at attach from
   `RemovableVolumeMonitor.deviceModel(forVolumeAt:session:)`
   (`RemovableVolumeMonitor.swift:278`), which already exists.
2. The v16 migration's successor removes any `removableVolume` root whose
   recorded `device_model` is `"Disk Image"`, whether or not it is currently
   mounted — the fact is now stored, so "unmounted" is no longer "unprovable".
3. For roots registered before this column existed and still not mounted, the
   fact is genuinely unknown. Do **not** guess. Leave them, and note the
   remaining exposure in the PR: a root with zero assets and no way to prove its
   nature. On the current production catalog that is exactly two rows,
   `/Volumes/Raycast` and `/Volumes/BoltAI 2`, both with 0 assets.
4. Update `docs/adr/0013-removable-and-device-sources.md` with the stored fact.

**Verify.** `script/verify.sh` plus a migration test over a fixture catalog
holding a recorded disk-image root that is not mounted. Runtime: mount a DMG,
confirm no removable row appears; unmount it; confirm the root does not persist.

**Rollback.** Revert.

---

### Increment 11 · Sidebar honesty and the registry debt

**Goal.** Eliminate D12, D13, D14, D15, D16, D17, D19.

**Steps.**

1. **D13.** Delete the trailing `Text("\(importBatches.count)")` from the
   `All Imports…` row (`SidebarView.swift:73-77`). Every other sidebar number is
   a media-item count; this one counts batches and reads as items. Add or update
   the `APP-*` row that covers sidebar row accessories.
2. **D12.** `MediaChoice.accessibilityValue` (`CatalogModels.swift:270`) becomes
   an explicit `switch` over the cases returning DES-068's exact strings, with no
   path through `rawValue`. `MediaChoiceTests#accessibilityValuesAreTheDES068Strings`
   already pins the strings; it will keep passing and will now be pinning a real
   owner.
3. **D14.** `sourceStillMatches`'s `.library` case
   (`MediaImportExecutor.swift:466`) returns the same classification as
   `transferBytesToStaging`'s (`:497`). A library is not an import source; both
   should say so the same way, and `MediaOperationFailureReason.sourceNotReady`'s
   camera/card wording must not be reachable for it.
4. **D15.** Widen `guard-design-system.sh`'s DES-002 pattern
   (`script/guard-design-system.sh:47`) to catch `.font(` with any argument, then
   allowlist the seven styles by name and fail on anything else, including a
   variable or a `Font.` reference. Extend the self-test with both new shapes.
5. **D16.** Bound `dismissedBatchIDs` (`CatalogWindowViewModel.swift:209`).
   Prefer removing the need for it: an ID is only ever inserted for a batch whose
   card is gone and whose run was fully clean, so it can be dropped once that
   batch leaves `importBatches`. If that is not sound, cap it and say why.
6. **D19.** Q4 is answered: a zero-byte file is **not imported and not named in
   the bar**, and it is deleted with the media. That is a plan-disposition
   change, not a `MediaEligibility` change — the file stays catalogued and its
   tile keeps the `photo.slash` glyph it already draws correctly. The
   disposition and the erase set both land in increment 12; this increment
   carries only the tile's accessibility label, so a VoiceOver user learns the
   file is empty rather than that it merely failed. Do **not** widen it to
   "anything that failed to decode": a corrupt 40 MB RAW is real damage the
   user needs to see.
7. **D17.** Finish the L4 retirement. `design-system.md:90` (DES-021) and `:98`
   (DES-028) still normatively define and check an L4 that the hierarchy section
   at `:62` says does not exist, and `hig-validation.md:121` and
   `import-bar.md:598` still reference it. Either every mention goes, or the
   retirement is reversed — the authoritative registry must not both retire and
   mandate the same level.

**Verify.** `script/verify.sh`; `guard-design-system.sh` and its self-test;
`check-doc-citations.sh`. Design checks per CLAUDE.md §Code Review (C) for the
sidebar change, citing the `DES-*` IDs.

**Rollback.** Revert. Each step is independent of the others; a reviewer may
split this increment if any one step grows.

---

### Increment 12 · One typed erase, and a card that is actually erased

**Goal.** Eliminate D20–D26. Implements owner decisions Q4, Q5, Q6 and Q7 and
`import-bar.md`'s erase-only state, which has been specified since the screen was
designed and never built.

**Why this is one increment and not six.** D22, D24 and D25 share a root cause:
the erase path is grafted onto the copy path's accounting. `EntryTotals` carries
`publishedCount`, `publishedBytes` and `failedCount` and has no notion of
deletion, so the deletion loop borrows `failedCount`, the outcome borrows
`.completed(publishedCount:)`, and the mapper has only copy-run branches to fall
into. Fixing them separately would mean three patches around the same wrong
boundary.

**Steps.**

1. **Classify every file on the card, once.** A `nonisolated enum
   SourceFileClass` beside `MediaEligibility` answers, for one relative path:
   `media`, `usefulSidecar` (`.xmp` / `.srt`), `cruftSidecar`
   (`.thm .ctg .aae .lrf .mpl .cpi`), `sourceArtifact(kind)` (Sony
   `M4ROOT/THMBNL`, `M4ROOT/CLIP/*.xml`, `._*`, card trash roots — the set
   ARC-045 already enumerates as ignore paths), or `unknown`. Match path
   components **case-insensitively** and spell both `M4ROOT/…` and
   `PRIVATE/M4ROOT/…`, exactly as `gomediaimport`'s `isSonyThumbnailDir` /
   `isSonyClipXML` do — the same volume respelling behind D1.
2. **`MediaOperationDisposition` gains `.excluded(ExclusionReason)`** —
   not copied, still part of the erase set, and explicitly **not** `.blocked`,
   which would make it an attention item and disable Erase forever
   (`ImportBarPresentation.swift:279`). Reasons: `.empty` (zero bytes, Q4) and
   `.cruft(SourceFileClass)`. It contributes no bar copy (owner decision Q4).
3. **One preference: "Copy sidecars into the library."** Added to
   `ImportPreferences` beside the existing import policy keys and edited from
   the Settings Import pane. When off, `usefulSidecar` classifies as
   `.excluded(.cruft(…))`. This is the **only** configuration in the model —
   no per-extension table (Q7).
4. **A typed erase outcome.** `EntryTotals` gains `deletedCount`,
   `deletedBytes`, `deletionFailedCount`; the deletion loop stops incrementing
   `failedCount` (D25). `MediaImportExecutionResult.completed` carries an
   `EraseOutcome?`. `deleteSourceIfRequested`'s silent-success path
   (`:1309-1315`) returns a distinct `.skipped(reason:)` instead of `true`
   (D24), and **companion sources are deleted with their primary** (D26).
5. **The erase set** is every entry whose disposition is `.copy` (published),
   `.skipPreexisting`, or `.excluded`, plus the source artifacts enumerated in
   step 1. `unknown` is never touched. Deletion is **path-validated against the
   source root before every `removeItem`**, mirroring
   `gomediaimport`'s `validateSourceCleanupTarget`, so a misfiring matcher
   cannot reach outside the card.
6. **No batch for a run that copies nothing.** `runExecution` mints an
   `ImportBatchID` only when the plan has at least one `.copy` entry (D21).
   `import-bar.md:455`'s "Selection does not move" then holds by construction
   rather than by a downstream guard.
7. **The erase-only Done state**, per `import-bar.md:304`: L1
   `Card erased · N items deleted` with the checkmark badge, primary
   `Eject Card`, **no `Show These Items`** (D20, D22). `N` is the typed
   `deletedCount` from step 4 — the number actually removed, never the plan's
   `skipCount`.

**Verify.** `script/verify.sh` plus:
- `SourceFileClassTests` over every class, both `M4ROOT` spellings, and mixed
  case.
- An executor test asserting the erase set includes companions, cruft sidecars
  and artifacts, and excludes `unknown`.
- An executor test asserting a path outside the source root is refused.
- A coordinator test asserting a zero-copy plan mints no batch.
- A mapper test asserting the erase-only state renders `Card erased · N items
  deleted` with primary `Eject Card` and no reveal.
- Runtime: import a card, then erase it, and confirm from
  `op=import.erase phase=finish` alone that `deleted` equals what was on the
  card and that a follow-up scan of the still-mounted card observes only
  `unknown` files. Design checks per CLAUDE.md §Code Review (C).

**Rollback.** Revert. The preference key is additive; no schema change.

---

### Increment 13 · Doc closure

**Goal.** Leave the documentation as current truth.

**Steps.**

1. New ADR: **path equality and the single name-key owner.** Context (D1, D6),
   decision (`FilesystemNameKey` from probed volume capabilities, one owner, three
   callers), rejected alternatives (a `COLLATE NOCASE` primary key — ASCII-only
   and wrong on case-sensitive volumes; content hashing as identity — rejected by
   ADR 0008; unconditional lowercasing — loses data on case-sensitive volumes),
   consequences (a new column, a migration, a merge rule).
2. New ADR or an ADR 0009 amendment: **settled naming facts gate the plan.** The
   three-state enrichment predicate, why `bumpOccupancyRevision` is the right
   revision for a naming change, and the replan-cost measurement from increment 6.
3. Amend `docs/adr/0008-…`: identity is still the path; **path equality is the
   volume's own equality**. State explicitly that a respell is not a deletion.
4. Amend `docs/adr/0024-…` per increment 9 step 4.
4b. New ADR: **the erase set and permanent source deletion.** It must state the
   boundary against ADR 0022 explicitly — ADR 0022 rejects `removeItem` for the
   Move to Trash command and excludes device roots, and card erase is the one
   other place Otos destroys user files, currently owned by no ADR. Record the
   owner's rationale: the recoverability guarantee is the verified library copy
   that `eraseConfirmationProvenClean` already proves, and a Trash on the card
   would not free the space the user is erasing to reclaim. State the one
   exception rather than leaving it implicit: a zero-byte file is not in the
   library, so its deletion is unrecoverable — of zero bytes.
5. `docs/architecture.md`: the name-key owner and its three callers, and the
   enrichment→occupancy→replan edge, in the where-to-change table.
6. `docs/requirements.md`: ARC-033 (overlay survives a respell), ARC-047 (the
   settled-naming gate), ARC-050 and the reorganization naming row (one naming
   owner), the ARC row covering namespace resolution (folding), plus the rows
   touched by increments 7, 8, 10 and 11.
7. Delete this plan.

**Verify.** `script/requirements-authority-check.sh`,
`script/ci-text-hygiene.sh check`, `script/check-doc-citations.sh`. Re-run
increment 1's detector and record the final count against the increment-1
baseline in the PR.

**Rollback.** Revert.

---

## Requirements and ADR changes

| Increment | Document | Change |
| --- | --- | --- |
| 1 | ADR 0015 | The presentation stream and the naming decision are instrumented paths |
| 2 | new ADR, ADR 0008, ARC-033 | Path equality is the volume's equality; a respell is not a deletion and does not purge overlay |
| 3 | ADR 0019, ADR 0021 | Namespace occupancy and cross-plan reservations fold under the destination's capabilities |
| 4 | ARC-050 / the reorganization naming row | One naming owner; the UTC fallback is deleted |
| 5, 6 | new ADR or ADR 0009 amendment, ARC-047 | A plan is offered only when every source row's naming fact is settled; enrichment that changes a naming fact bumps occupancy |
| 7 | `import-bar.md`, APP-029 | The determinate bar's quantity is stated, not implied; the progress indicator is not spring-animated |
| 8 | `import-bar.md`, APP-029 | A queued Import is visibly distinct; no primary action is a no-op |
| 9 | ADR 0024 | The rule is one yield path, not one constructor |
| 10 | ADR 0013 | The device model is stored, so a detached disk-image root is still provable |
| 11 | `design-system.md`, `hig-validation.md`, APP row for sidebar accessories | L4 fully retired; the sidebar's only non-item count removed |
| 12 | new ADR, ARC-045, ARC-047, `import-bar.md` | The erase set and the permanent-deletion boundary: what a card erase removes, why it is `removeItem` and not `trashItem`, and the one "Copy sidecars" preference. ARC-045's device-artifact **ignore** paths become an **erase** set. `import-bar.md`'s erase-only Done state stops being unimplemented |

---

## What this plan does not do

- **No content-addressed deduplication** (owner decision Q2). The 248 extra
  copies already in the library stay. This plan stops Otos adding more; it does
  not find the ones another tool created.
- **No repair of existing duplicates** (owner decision Q3). Increment 1 ships a
  read-only detector so the decision can be made on a real number.
- **No change to the MTP path beyond what falls out of the shared owners.** Plan
  0095's camera work has still never been observed against hardware — PR #277's
  test plan carries that as an open item — and that verification belongs with a
  camera attached, not folded in here.
- **No grid-performance work.** `mainThreadStall bracketedOp=MediaGridViewController.applyStructure
  stallMs=230 latestItems=265` was observed 2026-08-19 22:04:20, over Apple's
  100 ms threshold, and is the second such observation on this operation (plan
  0095 recorded `stallMs=109` on 2026-08-16). It is real, it is unrelated to
  import correctness, and it wants its own measurement-first plan.
- **No content-hash-based erase safety.** Erase deletes what the *plan* proved
  is in the library by name and `(size, mtime)`; it does not re-hash the
  destination first. That is owner decision Q2's territory.
- **No `CatalogStore` decomposition.** Increment 2 touches it in three places; it
  is still 4,190 lines and its boundaries are still worth revisiting, but doing
  both at once would make every regression ambiguous.
