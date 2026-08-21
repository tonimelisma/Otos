# 0097 — One Namespace Owner, And The Erase Manifest

## Read first

- `docs/adr/0025-volume-aware-path-equality.md` — the decision plan 0096 landed.
  This plan does not reverse it; it finishes it by giving the *input* to
  `FilesystemNameKey` a single owner, which 0096 left derived at each call site.
- `docs/adr/0026-settled-naming-and-card-erase.md` — the settled-naming gate and
  the permanent-deletion boundary. Increment 5 gives the gate a terminal state;
  increments 3–4 give the erase a manifest, a lease, and a journal.
- `docs/adr/0008-filesystem-source-of-truth-and-overlay-lifecycle.md` — identity is
  the path, overlay is purged only on **proven** deletion. Increment 2's capability
  backfill exists because a wrong capability makes a *live* file look deleted.
- `docs/adr/0015-observability.md` — the logging facade and the agent's windows.
  Increment 1 adds the correlation the agent needs to read a whole run, and the
  harness it needs to produce one without hardware.
- `docs/design/import-bar.md` — the import screen spec. Its erase alert and erase
  completion state both name **the same count**; increment 3 makes that true.

This plan assumes no prior context. Every increment states its goal, the exact
steps with file and line references, how to verify, and how to roll back.

---

## What is wrong today

Plan 0096 landed on 2026-08-20 as a single commit (`40261bf`, 52 files) rather than
as its thirteen planned PRs. Its designs were largely right; its integration was not
verified. This plan finishes the work, and the ordering is deliberate: the
instrumentation that makes the rest provable lands first, because 0096's failure
mode was that every increment's "Runtime:" verification step was unrunnable.

`main` is red. `script/verify.sh` fails on
`OtosTests/ImportExecutionProgressTests/zeroCopyPlanWithDeleteRequestedExecutesDeletion`,
reproduced twice on 2026-08-20:

```
Expectation failed: eraseOutcome.deletedCount == 1  (→ 0)
Expectation failed: !FileManager.default.fileExists(atPath: fixture.sourceFile.path)
```

That test is the one `docs/requirements.md` APP-032 cites as its verification.
Increment 1 of this plan is the fix that greens `main`, and it lands first and alone.

### D1 · Card erase deletes nothing, for every root

`MediaImportExecutor.eraseSourceFile` (`Otos/Services/MediaImportExecutor.swift:507`)
validates containment as:

```swift
let root = sourceRoot.url.standardizedFileURL.path(percentEncoded: false)
let url  = sourceRoot.url.appending(path: relativePath.rawValue).standardizedFileURL
guard url.path(percentEncoded: false).hasPrefix(root + "/") else { return .failed }
```

`LibraryRootPath.url` is `URL(fileURLWithPath: rawValue, isDirectory: true)`
(`Otos/Models/CatalogModels.swift:79`), so `.path(percentEncoded: false)` **already
ends in `/`**. `root + "/"` is a double slash, and the guard rejects every candidate.
Measured with a probe that mirrors `CatalogPath.normalizedDirectoryPath` exactly:

```
rawValue:  /var/folders/…/Card
root:      /var/folders/…/Card/          ← trailing slash from isDirectory: true
root+"/":  /var/folders/…/Card//
target:    /var/folders/…/Card/same.jpg  exists: true
GUARD hasPrefix(root+"/"): false
```

Every erase candidate returns `.failed`. `deletedCount` is 0 and `failedCount` is N,
so the bar renders `Card erase incomplete · 0 items deleted` with an attention badge,
auto-eject is suppressed (`MediaOperationCoordinator.swift:620`), and
`op=import.erase phase=finish` reports `failed=N` for a run with nothing wrong.
This is also a regression: before `40261bf`, `.skipPreexisting` sources were deleted.

### D2 · The erase set is built from plan dispositions, not from outcomes

`sourceDeletionCandidates` (`MediaImportExecutor.swift:468`) collects every entry
whose disposition is `.copy`, `.skipPreexisting` or `.excluded`:

```swift
case .copy, .skipPreexisting, .excluded:
    paths.insert(entry.source.relativePath)
```

`runPlanEntries` has already accumulated `failedCount`, `skippedForeignCount` and
`incompleteItems` before calling `eraseSourceFiles(context:)`
(`MediaImportExecutor.swift:396`), and passes none of it. So a `.copy` entry whose
copy **failed**, or which was **skipped as foreign**, still has its source file
deleted from the card: the file ends up neither in the library nor on the card.

Plan 0096 specified the erase set as "every entry whose disposition is `.copy`
**(published)**, `.skipPreexisting`, or `.excluded`". The parenthetical was the
requirement. D1 currently masks D2 — **fixing D1 without D2 activates data loss**,
which is why increment 1 fixes the guard and the outcome-gating together and neither
ships alone.

### D3 · The erase lost the journal, the lease, and the recovery arm

The pre-`40261bf` deletion wrote an `ActiveFileOperation` with
`phase: .sourceDeletionPending` before deleting and completed it after, with a
recovery arm at `MediaImportExecutor.swift:1234` that resumes an interrupted
deletion on the next launch. The copy path still checks
`ownsNamespaceMutationLease` before deleting (`:1128`). The new `eraseSourceFile`
does none of this:

- **No lease.** `execute()` acquires a lease on the **destination**, and only when
  `copyEntries` is non-empty (`MediaImportExecutor.swift:178`). An erase-only run
  holds no lease at all while deleting hundreds of files from a source root the
  scanner is actively watching. ARC-055 names exactly this class of mutation.
- **No journal.** A `removeItem` that is interrupted leaves no record.
- **Dead code.** `deleteSourceIfRequested` (`:1436`) now has no callers, so D24 of
  plan 0096 — the silent-success path — was orphaned rather than fixed, and the
  `.sourceDeletionPending` recovery arm is unreachable.

D24's real cause is a schema shape, not a return value: `active_file_operation`
(`Otos/Stores/CatalogStorePersistence.swift:514`) declares `destination_root_path`,
`destination_relative_path`, `source_byte_size` and `source_modified_at` as
`NOT NULL`. The journal models *a file being copied*. An erase of a cruft sidecar
has no destination and may have no recorded size, so it could not be journaled
honestly, and the old code returned `true` instead.

### D4 · The plan is not the manifest, so three numbers disagree

`import-bar.md:452` specifies one number: the alert says `181 items will be deleted`
and the completion says `Card erased · 181 items deleted`. Today:

| Number | Source | Value |
| --- | --- | --- |
| The alert's count | `summary.skipCount` (`ImportBarPresentation.swift:239`) | preexisting media only |
| What the sweep deletes | plan entries **plus** a fresh enumeration of the card at execution time (`MediaImportExecutor.swift:487-501`) | media + companions + useful sidecars + cruft + source artifacts |
| The completion's count | `eraseOutcome.deletedCount` | currently always 0 (D1) |

The confirmation count is computed at *plan* time and the deletion set is enumerated
at *execution* time, so they cannot agree even in principle. `MediaOperationPlanTotals.eraseCount`
(`Otos/Models/MediaOperationModels.swift:240`) was added for this and is read by
nothing.

### D5 · One path-equality function, four disagreeing sources for its input

Plan 0096's C6 required exactly one owner of "are these two paths the same file."
What shipped is one owner of the *comparison* and none of the *capabilities*:

```
nameKey(...) call sites:                                      30
`VolumeNamespaceCapabilities = .caseInsensitiveAPFS` defaults: 25
  silent `?? .caseInsensitiveAPFS` at comparison time:          7  (CatalogStore.swift:2013, :2064, :2639, :2808, :2849, :3641, :3708)
```

and four places that decide what a volume's rules actually are, which do not agree:

| Source | Behavior |
| --- | --- |
| `FilesystemNamespaceSemantics.probeVolumeCapabilities` (`+NameKey.swift:51`) | reads `volumeSupportsCaseSensitiveNamesKey`; hardcodes `prefersDecomposedUnicode: true` |
| `RemovableVolumeMonitor.swift:274` | builds `VolumeNamespaceCapabilities` inline instead of calling the probe; also hardcodes `prefersDecomposedUnicode: true` |
| `library_root.case_sensitive_names` | persisted at registration/attach — and ignored by import planning, which re-probes per plan build (`CatalogStore.swift:472`) |
| `LibraryReorganizationRunner.swift:159` | a hardcoded `.caseInsensitiveAPFS` literal |

### D6 · A wrong capability turns a live file into a proven deletion, or a trap

The v17 migration adds `case_sensitive_names` but never backfills it by probing, and
the reader treats `NULL` as false (`CatalogStorePersistence.swift:629`). Every root
registered before v17 therefore reports case-insensitive forever. Measured on a
case-sensitive volume created for this plan:

```
/Volumes/OTOSPROBECS  declaredCaseSensitive=true  format=APFS (Case-sensitive)
  IMG_1.JPG and img_1.jpg coexist → 2 real files → 1 folded key
```

Two collision policies then disagree about the same fact:

- `DestinationNamespace.init` (`Otos/Models/MediaOperationModels.swift:517`) and
  `reconcileMissingCompanions` (`CatalogStorePersistence.swift:1326`) build
  dictionaries with `Dictionary(uniqueKeysWithValues:)`, which **traps** on a
  duplicate key — a crash inside import planning or inside a store write.
- `reconcileMissingAssets` (`CatalogStore.swift:2864`) uses `Set` + filter for the
  same question, so it does not trap: it deletes one of the two rows and purges its
  overlay, which is exactly the ADR 0008 breach plan 0096 existed to remove.

### D7 · Two equality laws for one concept

`MediaRelativePath.==` (`Otos/Models/CatalogModels.swift:129`) short-circuits on an
FNV-1a hash of the raw UTF-8 before it ever compares the strings, so it is **byte**
equality. `FilesystemNameKey` wraps a bare `String` with synthesized conformance, so
it is **canonical** equality. SQLite's `relative_path_key = ?` is byte equality.
Reproduced with the repo's own constants (`PathFingerprint`, `CatalogModels.swift:25`):

```
Swift String ==  (NFC vs NFD) : true
FNV-1a(utf8) equal            : false
=> MediaRelativePath ==       : false   ← byte-wise
=> FilesystemNameKey ==       : true    ← canonical
```

`MediaRelativePath`'s own comment calls the fingerprint "Cheap Hashable only — not
identity", which is not what the code does: it is the deciding term in `==`.

Normalization is a storage property, not an equality rule, and it should be removed
at the boundary rather than carried through the system. Measured on exFAT — the
filesystem of an actual SD card:

```
exFAT: writing café.jpg as NFC then as NFD yields ONE file, stored decomposed
  readdir           → 2 entries (the file plus its `._` AppleDouble)
  FileManager.enumerator / contentsOfDirectory → 1 entry
```

macOS normalizes on write for exFAT, so NFC/NFD twins do not coexist on a card, and
`prefersDecomposedUnicode` has never been measured on any volume — it is hardcoded
`true` in both places that construct it.

### D8 · The settled-naming gate has no terminal state

`shouldWaitForMetadata` (`MediaOperationCoordinator.swift:1236`) now waits while any
source row has `!isNamingFactSettled`. Settled means enrichment wrote its
`(size, mtime)` signature. Nothing bounds the wait: one row that never enriches —
a file the enricher cannot open, a placeholder that never materializes — holds the
bar at `Checking the card…` indefinitely. The predicate it replaced was wrong but
always terminated.

`PlanningFileFacts.isNamingFactSettled` also defaults **optimistic** in the model
(`MediaOperationModels.swift:75`, `= true`) and **pessimistic** in the gateway
(`MediaOperationGateway.swift:41`, `?? 0` → not settled). Every existing test
constructs the optimistic one, and `grep -rn isNamingFactSettled OtosTests/` returns
nothing: the gate that the 2026-08-19 double-import turned on has no test at all.

### D9 · Enrichment now replans every attached source at up to 1 Hz

Plan 0096 increment 6 required a cost measurement and a coalescing decision. Neither
happened. The code path, read end to end:

- `EnrichmentCoordinator.applyFlushInterval = .seconds(1)` (`EnrichmentCoordinator.swift:201`)
  — enrichment flushes at **1 Hz**.
- Every flush that changes any `capture_wall_compact` bumps occupancy
  (`CatalogStore.swift:1312`).
- `handlePlanningChange` marks **every attached source whose destination is that
  root** dirty and schedules a rebuild (`MediaOperationCoordinator.swift:760`).
- A rebuild is a full source-row `SELECT`, a destination-occupant `SELECT`, an
  `enumerateNamespace` readdir over every destination folder, and a full plan build.

Importing into a library whose new rows are then enriched therefore drives a
self-sustaining replan loop for as long as a card stays attached.

### D10 · Verification debt from plan 0096

| # | Debt | Evidence |
| --- | --- | --- |
| D10a | `isNamingFactSettled`, the catalog respell path, the v17 backfill and its collision merge, `SourceFileClass`'s erase set, the executionUnavailable durability case, and the disk-image migration all shipped with no test. Plan 0096 named a test for each. | `grep -rn isNamingFactSettled OtosTests/` → none; no `CatalogStoreCaseIdentityTests`; no migration test |
| D10b | ARC-056, ARC-057 and APP-032 cite tests that do not exercise their stated criteria. ARC-056 claims "the catalog keeps one asset and its overlay" and cites two planner tests that never touch `CatalogStore`. | `docs/requirements.md:90-91`, `:137` |
| D10c | `script/logs.sh` filters on `process == "Otos"` (`script/logs.sh:33`), so every log line emitted under `xctest` is invisible to the agent's own tooling. Instrumentation added "so tests can be verified from logs" is unreadable. | measured while diagnosing the failing erase test |
| D10d | There is no runtime harness for import or erase. `smoke-run.sh` drives the app and asserts on `log show` for the grid; nothing equivalent exists for a card, because a card is hardware. | `script/smoke-run.sh` |
| D10e | The v17 collision merge deletes the losing row but not its thumbnail file, though it selects `thumbnail_path` to decide the winner. There is no thumbnail eviction anywhere, so the file leaks permanently. | `CatalogStorePersistence.swift:1500-1540` |
| D10f | `dismissedBatchIDs`'s cap evicts `dismissedBatchIDs.first` and names it `oldest` (`CatalogWindowViewModelMediaOperations.swift:148`). `Set.first` is an arbitrary element, so a live dismissal can be evicted and a dismissed bar can reappear. | same |
| D10g | `guard-design-system.sh` was given a file-level allowlist entry for `Otos/Views/ImportPlanFooter.swift` (`script/guard-design-system.sh:69`) so that one string, `Import Queued`, would pass DES-035/DES-039. That disables the check for every string in the file. | same |
| D10h | The shipped button title is `Import Queued`; `import-bar.md:533` and `:538` say `Import queued`, and both call it a **button** while `ImportPlanFooter.swift:346` renders a `Text`. | same |
| D10i | `MediaAssetTilePresentation.swift:177` reads `detail.enrichedSourceSize == 0` to say "empty file" — the enrichment signature, not the scanned `byte_size`. The label is absent until the file is enriched. | same |
| D10j | `MediaImportExecutor.sourceStillMatches`'s `.library` case was changed from returning `.sourceNotReady` to validating and proceeding (`:598`). Plan 0096 D14 asked for the classification to be *aligned*, not for the path to be opened. Combined with an erase that accepts `.library` sources (`:513`), this is a new reachable destructive path. | same |
| D10k | `ReorganizationPlanningSnapshot` gained `let calendar: Calendar = .current` and `let timeZone: TimeZone = .current` (`Otos/Models/ReorganizationModels.swift:15`). A `let` with a default is excluded from the memberwise initializer, so neither is injectable and the plan-0096-required non-UTC pin for reorganization naming cannot be written. | same |

---

## Owner decisions — needed before the increments they gate

Each row records a question this plan will not answer on its own. Increment 3 step 5
and increment 1 step 4 are explicitly blocked on Q1 and Q2.

| # | Question | Why it is not the agent's call | Blocks |
| --- | --- | --- | --- |
| Q1 | **Does erase prove the library copy by content?** The executor already hashes the exact bytes it wrote (`ContentHasher`, `MediaImportExecutor.swift:866`) and `proveFinalOwnership` (`:1320`) already trusts that digest at recovery, so proving a `.copy` costs nothing. A `.skipPreexisting` is different: `isContentHashRequired` is `kind != .removableVolume` (`CatalogModels.swift:219`), so a card is deliberately never hashed in place, and proving one would mean reading that file's bytes off the card. The alternative is today's name + size + mtime match (`MediaTransferPlanner.catalogDecision`, `:454`). | A real cost against a real risk on the one irreversible operation in the app. Reading N files off a card before deleting them is a product decision, not a refactor. | increment 3 step 5 |
| Q2 | **How does a test register a synthetic card?** A disk image is a real removable volume with a real mount point, real eject/re-attach, and a choosable case-sensitivity — measured for this plan (see increment 1). But plan 0096 increment 10 deliberately deletes `removableVolume` roots whose `device_model` is `Disk Image` (`CatalogStorePersistence.swift:343`), which is right for the product and forecloses the cheapest harness. Options: an explicit test-only registration entry point; or a marker that distinguishes a harness volume from a mounted DMG in the sidebar. | The product rule and the harness need are both correct and they collide. Which one bends is the owner's call. | increment 1 step 4 |
| Q3 | **What does the bar say when a naming fact can never settle?** D8 needs a terminal state. Reaching it means either proceeding silently from the filesystem mtime, or saying something. Any new string is product copy. | `docs/design/design-system.md` DES-035/DES-039 govern user-facing copy; inventing a string is inventing a requirement. | increment 5 step 3 |
| Q4 | **Do we normalize `relative_path` at the boundary?** D7's cleanest resolution is to normalize once where paths are constructed, after which byte equality and canonical equality agree everywhere including SQLite. That changes what future scans store in `relative_path`, so it is a data decision with a migration, not only a code change. | It rewrites a persisted identity column. | increment 2 step 5 |

---

## Constraints

| # | Constraint | Why |
| --- | --- | --- |
| C1 | **Each increment is one PR**, branched from a green `main`, in its own worktree, with a full `script/verify.sh`. Plan 0096's thirteen increments landed as one commit and its integration went unverified; that is the failure this plan exists to not repeat. | AGENTS.md; plan 0096 |
| C2 | **Increment 1 lands first and alone**, and greens `main`. Every later increment's verification reads what increment 1 emits. | AGENTS.md red-`main` rule |
| C3 | **No increment may fix D1 without D2 in the same PR.** The containment guard currently masks the data-loss path. | D1, D2 |
| C4 | **No new user-facing string** without an owner decision and a `docs/design/` entry in the same PR. | AGENTS.md; DES-035 |
| C5 | Every behavior change updates its `docs/requirements.md` row in the same PR, and a row's cited test must exercise the row's named source files. | AGENTS.md; D10b |
| C6 | **There shall be exactly one owner of "what are this volume's namespace rules"**, and it shall not be defaultable. No increment may add a `VolumeNamespaceCapabilities` default parameter. | D5 |
| C7 | **There shall be exactly one path equality law.** No increment may leave two types that answer "same file?" differently. | D7 |
| C8 | Tests assert observable behavior or public owner boundaries; no test reads source files as text. | AGENTS.md, CI-guarded |

---

## Target end state

```
One namespace owner:
  RootNamespace { root, capabilities (private), key(_:), contains(_:) }
        │  constructed once per root from a probe or the persisted row — never defaulted
        ├── catalog identity + scan reconciliation      (increment 2)
        ├── import destination namespace + claims       (increment 2)
        ├── reorganization planning + execution         (increment 2)
        └── erase containment                           (increment 1, then folded in by 2)

One equality law:
  MediaRelativePath == FilesystemNameKey == SQLite TEXT =        (increment 2, gated on Q4)

One erase truth:
  EraseManifest, built from execution outcomes
        ├── its count is what the alert confirms         (increment 3)
        ├── its items are what SourceEraser deletes      (increment 4)
        └── its items are what the Done state reports    (increment 3)
  SourceEraser — the only type permitted to remove a file from a source root,
        requiring a source-root lease and a journal row per item   (increment 4)

One run, readable end to end:
  run=<id> on every line from import.plan through import.presentation   (increment 1)
  a synthetic card the agent can attach, import, erase, and re-attach   (increment 1)
```

---

## Increments

Each is a separate PR. Steps are ordered; verification is the gate.

### Increment 1 · Green `main`, and make a run readable

**Goal.** Fix D1 and D2 together (C3), and build the instrumentation every later
increment's verification depends on: a correlation ID, a log window that can see a
test process, and a card the agent can attach without hardware.

**Steps.**

1. **The containment guard.** `eraseSourceFile` (`MediaImportExecutor.swift:507`)
   compares against a root string with no trailing slash. Do not special-case the
   slash at this call site — derive containment from one helper that
   `CatalogPath` owns, beside `CatalogPath.relativePath`
   (`Otos/Models/CatalogPath.swift:42`), which already answers "is this URL inside
   this root, and what is its relative path". Increment 2 moves that helper onto
   `RootNamespace`; this increment gives it one home.
2. **The erase set comes from outcomes.** `runPlanEntries`
   (`MediaImportExecutor.swift:321`) already has `publishedCount`, `failedCount`,
   `skippedForeignCount` and `incompleteItems` when it calls `eraseSourceFiles`
   (`:396`). Pass the per-entry outcomes, and include a `.copy` entry's source only
   when that entry published. A `.failed` or `.skippedForeign` entry's source is
   never deleted. This is the whole of D2 and it does not wait for the manifest.
3. **One `run=` correlation ID.** Mint it when a source session enters `.building`
   (`MediaOperationCoordinator.buildPlan`, `:1120`) and carry it on every line from
   `op=import.plan` through `op=import.readiness`, `op=mediaOperation.batch`,
   `op=import.erase` and `op=import.presentation`. Today an erase-only run has no
   batch by design, so nothing stitches a run together; `batch=` is not a substitute.
4. **A card the agent can attach.** Q2 gates the mechanism. The measurements are
   done and recorded in `docs/research/2026-08-21-synthetic-removable-volume.md`
   (write it in this increment):

   ```
   hdiutil create -size 32m -fs "ExFAT" -volname OTOSPROBE probe.dmg
     → /Volumes/OTOSPROBE   caseSensitive=false casePreserved=true format=ExFAT
   hdiutil create -size 32m -fs "Case-sensitive APFS" -volname OTOSPROBECS probe-cs.dmg
     → /Volumes/OTOSPROBECS caseSensitive=true
   diskutil info /Volumes/OTOSPROBE → Removable Media: Removable
   ```

   Both mount, both report distinct capabilities, and both eject and re-attach — so
   every runtime condition this plan cares about is reproducible on any machine in
   about two seconds. Ship `script/synthetic-card.sh create|attach|detach|destroy`.
5. **Let the agent read its own tests.** `script/logs.sh`'s predicate is
   `process == "Otos"` (`script/logs.sh:33`), so nothing emitted under `xctest` is
   visible. Add an optional process argument, defaulting to today's behavior.
6. **Record the erase's real counts.** With steps 1 and 2 in place,
   `op=import.erase phase=finish` stops reporting `failed=N` for a healthy run.
   Add `manifestCount=` alongside `deleted=`/`skipped=`/`failed=` so the gap between
   intended and actual is one subtraction, not an inference.

**Verify.** `script/verify.sh` — this is the increment that must turn it green, and
`zeroCopyPlanWithDeleteRequestedExecutesDeletion` is its first oracle. Plus:
- An executor test asserting a failed copy's source survives the erase sweep (D2).
  This test fails on `main` today for the opposite reason it will pass afterwards,
  so assert the *file*, not the count.
- A containment test over a root with and without a trailing slash.
- Runtime: `script/synthetic-card.sh create`, attach, import, erase, re-attach, and
  confirm from one `run=` grep that plan, readiness, batch, erase and presentation
  all appear for the same run.

**Rollback.** Revert. `main` returns to red, which is where it already is.

---

### Increment 2 · One namespace owner, and one equality law

**Goal.** Eliminate D5, D6, D7. Make it impossible to compare two paths without
saying whose rules apply, and impossible to obtain those rules by guessing.

**Steps.**

1. Introduce `RootNamespace` beside `FilesystemNamespaceSemantics+NameKey.swift`:

   ```swift
   nonisolated struct RootNamespace: Sendable, Equatable {
       let root: LibraryRootPath
       private let capabilities: VolumeNamespaceCapabilities
       func key(_ relativePath: MediaRelativePath) -> FilesystemNameKey
       func contains(_ url: URL) -> MediaRelativePath?
   }
   ```

   `FilesystemNameKey`'s initializer becomes private to it. Delete the free
   `nameKey(relativePath:capabilities:)`; its 30 call sites take a `RootNamespace`.
2. Delete `VolumeNamespaceCapabilities.caseInsensitiveAPFS` as a public static and
   every default parameter that spells it — 25 of them, listed in D5. A root either
   has a `RootNamespace` or the operation does not run. `RootRuntimeState` holds it
   (`Otos/Stores/RootRuntimeState.swift:21`), so the seven
   `roots[…]?.capabilities ?? .caseInsensitiveAPFS` sites in `CatalogStore` lose
   their fallback.
3. Fold the other three capability sources (D5) into the probe: `RemovableVolumeMonitor.swift:274`
   calls it instead of constructing capabilities inline; `LibraryReorganizationRunner.swift:159`
   takes the root's, not a literal; import planning reads the persisted row instead
   of re-probing per plan build (`CatalogStore.swift:472`).
4. **Backfill the persisted capability by probing** for every root whose
   `case_sensitive_names` is `NULL`, and stop treating `NULL` as false
   (`CatalogStorePersistence.swift:629`). An unprobed, currently-detached root is
   *unknown*, and an unknown root does not reconcile deletions — a wrong guess here
   purges the overlay of live files (D6, ADR 0008).
5. **One equality law** (Q4 gates the boundary-normalization half). Remove the
   fingerprint short-circuit from `MediaRelativePath.==` (`CatalogModels.swift:129`)
   so it compares strings, keeping the fingerprint for `hash(into:)` only where it
   is consistent with that equality; or normalize at construction and keep the
   fingerprint. Either way `MediaRelativePath`, `FilesystemNameKey` and SQLite agree
   afterwards, and the `decomposedStringWithCanonicalMapping` step inside `nameKey`
   is deleted as redundant rather than left as an unmeasured constant.
6. **Collisions get a policy, not a trap.** Replace both
   `Dictionary(uniqueKeysWithValues:)` sites (`MediaOperationModels.swift:517`,
   `CatalogStorePersistence.swift:1326`) with a build that returns a typed collision
   rather than crashing, and make `reconcileMissingAssets` (`CatalogStore.swift:2864`)
   use the same policy instead of silently resolving it by deletion.
7. **D10e:** the v17 collision merge deletes the losing row's thumbnail file, which
   it already selects to pick the winner.

**Verify.** `script/verify.sh` plus:
- `RootNamespaceTests` over both capability values, including the case pair proven
  reachable in D6.
- `CatalogStoreCaseIdentityTests` — plan 0096 increment 2 named this and it was
  never written: scan a root observing `A/B.JPG`, re-scan observing `a/b.jpg`, and
  assert on a case-insensitive root that one row survives with its enrichment and
  thumbnail intact, and on a case-sensitive root that two rows exist.
- A migration test over a fixture with a `NULL` capability column and a fold
  collision, asserting the merge keeps the right row and removes the loser's
  thumbnail.
- A test asserting `MediaRelativePath` and `FilesystemNameKey` agree on a pair that
  differs only by normalization.
- Runtime: `script/synthetic-card.sh` with the case-sensitive image from increment
  1, confirming `catalog.scan phase=finish` reports `deleted=0` across a detach and
  re-attach cycle.

**Rollback.** Revert. The capability backfill is additive.

---

### Increment 3 · The erase manifest

**Goal.** Eliminate D4. One value that the alert, the executor, and the Done state
all read, so the number the user confirms is the number that gets deleted.

**Steps.**

1. Add `EraseManifest` beside `MediaOperationPlan`:

   ```swift
   nonisolated struct EraseManifest: Equatable, Sendable {
       struct Item: Equatable, Sendable {
           let relativePath: MediaRelativePath
           let classification: SourceFileClass
           let proof: ErasureProof
           let byteSize: Int64?
       }
       let items: [Item]
       var mediaCount: Int
   }
   ```

2. The manifest is built where the plan is built, not enumerated again at execution
   time (`MediaImportExecutor.swift:487`). The card enumeration that finds sidecars,
   cruft and source artifacts moves into planning, where its result can be counted
   before the user is asked.
3. `.eraseItems(count:)` (`ImportBarPresentation.swift:239`, `:521`, `:539`) reads
   `manifest.mediaCount`. Delete `MediaOperationPlanTotals.eraseCount`
   (`MediaOperationModels.swift:240`), which nothing reads.
4. The Done state reports the executed manifest, and `import-bar.md`'s erase rows
   stop being aspirational: the same number appears in the alert and in
   `Card erased · N items deleted`.
5. **`ErasureProof` records how each item earned its place** (Q1 gates the strength):
   `.publishedThisRun(XXH3Digest128)` for a copy the executor hashed itself
   (`MediaImportExecutor.swift:866`), `.preexisting(...)` for a
   `.skipPreexisting` match, `.empty` for a zero-byte file, `.cruft(SourceFileClass)`
   for card debris. Whatever Q1 decides, the proof is *recorded per item* rather
   than implied by the disposition, so the log line for a deletion states why it was
   allowed.
6. **Wire the preference that was named but never built.** Plan 0096 increment 12
   step 3 specified that when "Copy sidecars into the library" is off, a
   `usefulSidecar` reclassifies as `.excluded(.cruft(…))`. Only the Settings label
   changed (`SettingsView.swift:75`); no classification consults the preference, and
   `ExclusionReason.cruft` is unreachable. Either wire it or delete the case.

**Verify.** `script/verify.sh` plus:
- A test asserting the alert's count, the manifest's item count, and the reported
  deleted count are the same number for a mixed card (media, sidecars, cruft,
  artifacts, one zero-byte file).
- A test asserting an `unknown` file is in no manifest.
- Design checks per AGENTS.md §Code Review (C) for the alert and the Done state,
  citing DES-027A and DES-036.

**Rollback.** Revert.

---

### Increment 4 · One owner is allowed to delete

**Goal.** Eliminate D3. Restore the lease and the journal the erase lost, and make
the loss structurally impossible to repeat.

**Steps.**

1. `SourceEraser` — an actor that is the only type in Otos permitted to remove a
   file from a source root. It takes an `EraseManifest` and a lease, and returns an
   `EraseOutcome` whose counts are per-item facts.
2. **The lease is on the source root.** `execute()` acquires one on the destination
   and only when there are copies (`MediaImportExecutor.swift:178`); deleting from
   the card is a namespace mutation on the *card*, which ARC-055 already governs.
   `RootNamespaceMutationOwner` (`Otos/Models/ActiveReorganizationModels.swift:89`)
   gains the case that names it.
3. **The journal learns that not every operation is a copy.**
   `active_file_operation` (`CatalogStorePersistence.swift:514`) gains
   `operation_kind TEXT NOT NULL DEFAULT 'copy'`, and `destination_root_path`,
   `destination_relative_path`, `source_byte_size` and `source_modified_at` become
   nullable for `kind='erase'`. This is the actual cause of plan 0096's D24: the
   old code returned `true` for a file it could not journal, because the schema had
   nowhere to put it.
4. Delete `deleteSourceIfRequested` (`MediaImportExecutor.swift:1436`) and reuse its
   `.sourceDeletionPending` recovery arm (`:1234`) for the new kind, so an
   interrupted erase resumes instead of vanishing.
5. **Narrow the guard to match the invariant.** `guard-no-writes-into-media.sh`
   allowlists whole files (`script/guard-no-writes-into-media.sh:6`), so
   `MediaImportExecutor.swift` may call `removeItem` anywhere in its 1,766 lines —
   which is how an unjournaled, unleased deletion landed without a structural
   objection. After this increment, a `removeItem` targeting a source root belongs
   only in `SourceEraser`; make the guard say so, with a self-test.
6. **D10j:** `sourceStillMatches`'s `.library` case (`MediaImportExecutor.swift:598`)
   returns to a classification change rather than an opened path, per plan 0096 D14.

**Verify.** `script/verify.sh` plus:
- **The differential oracle.** `FilesystemTreeSnapshot`
  (`OtosTests/OriginalsReadOnlyTests.swift:9`) already captures path, size, mtime,
  mode, inode and content digest per entry and is `Equatable`. Erase is the one
  operation permitted to mutate a source tree, so assert
  `before.difference(after) == outcome.manifest` in both directions: nothing removed
  that is not in the manifest, nothing in the manifest left behind, nothing else
  changed by a byte. This cannot be satisfied by a patch — only by the manifest.
- A test asserting an erase without a source-root lease does not run.
- A recovery test: interrupt an erase, restart, assert the journal resumes it.
- A test asserting a path outside the source root is refused.

**Rollback.** Revert. The journal column is additive with a default.

---

### Increment 5 · The readiness gate terminates

**Goal.** Eliminate D8, and give the gate the tests it never got (D10a).

**Steps.**

1. Replace `PlanningFileFacts.isNamingFactSettled: Bool`
   (`MediaOperationModels.swift:61`) with a three-state fact, so "not settled yet"
   and "will never settle" stop sharing a value. The SQL already distinguishes them:
   `EnrichmentLeaseGateway.metadataStalenessSQLPredicate()` is reused correctly by
   `MediaOperationGateway.swift:16` and stays the single source.
2. Remove the model's `= true` default (`:75`). It defaults optimistic while the
   gateway defaults pessimistic, and every existing test constructs the optimistic
   one — which is why the gate has no coverage.
3. A source whose row can never settle reaches Ready and names from the filesystem
   mtime. What the bar says while that is true is Q3.
4. **Coalesce the replan (D9).** Debounce destination-driven rebuilds in
   `handlePlanningChange` (`MediaOperationCoordinator.swift:760`) rather than
   dropping bumps in the store, and attach the measurement plan 0096 required: the
   replan count per minute during a full-library enrichment pass, with the
   `op=catalog.occupancyRevision phase=bump reason=enrichmentNaming` and
   `op=import.plan phase=finish planMs=` lines as evidence, before and after.

**Verify.** `script/verify.sh` plus:
- Gateway tests for all three schema states (not enriched; enriched with no wall
  clock; enriched with one) — named by plan 0096 increment 5 and never written.
- A coordinator test asserting an unenriched row holds `waitingForMetadata` and does
  not reach Ready.
- A coordinator test asserting a row that can never settle does **not** wait forever.
- A coordinator test asserting a plan built from unenriched rows goes dirty when
  enrichment lands and rebuilds with `copyCount == 0`.
- Runtime: a synthetic card from increment 1, with the replan-rate measurement.

**Rollback.** Revert.

---

### Increment 6 · The registry means what it says

**Goal.** Eliminate D10b, and close the remaining debt from plan 0096 that no other
increment carries.

**Steps.**

1. **Coverage-backed requirement rows.** `requirements-authority-check.sh` verifies
   that a cited test exists and contains real assertions
   (`script/requirements-authority-check.sh:25`), but not that it touches the row's
   named source files — which is how ARC-056 came to claim catalog overlay survival
   while citing two planner tests. The build already runs with
   `-profile-coverage-mapping`, and `xcrun xccov view --report` works on the current
   result bundle today, so this needs no new infrastructure: require a cited test to
   cover at least one of its row's named files.
2. Fix ARC-056, ARC-057 and APP-032 to cite the tests increments 1–5 add.
3. **D10g:** replace the file-level domain-noun allowlist entry for
   `Otos/Views/ImportPlanFooter.swift` (`script/guard-design-system.sh:69`) with a
   string-level exemption, so one approved string stops disabling the check for the
   whole file.
4. **D10h:** reconcile the shipped title with the spec — `import-bar.md:533` and
   `:538` say `Import queued` and call it a button; `ImportPlanFooter.swift:346`
   renders `Import Queued` as a `Text`. Pick one and make both true.
5. **D10f:** `dismissedBatchIDs`'s bound (`CatalogWindowViewModelMediaOperations.swift:148`)
   evicts an arbitrary set element under the name `oldest`. Drop an ID when its
   batch leaves `importBatches` — the condition plan 0096 preferred — or keep a cap
   with an order that exists.
6. **D10i:** the tile's "empty file" label reads the enrichment signature
   (`MediaAssetTilePresentation.swift:177`); read the scanned `byte_size`.
7. **D10k:** make `ReorganizationPlanningSnapshot`'s calendar and time zone
   injectable (`Otos/Models/ReorganizationModels.swift:15`) and add the non-UTC pin
   plan 0096 increment 4 required, so a regression to UTC naming fails a test
   instead of passing in whatever zone the machine runs in.

**Verify.** `script/verify.sh`; `requirements-authority-check.sh` and its self-test;
`guard-design-system.sh` and its self-test; `check-doc-citations.sh`.

**Rollback.** Revert.

---

### Increment 7 · Doc closure

**Goal.** Leave the documentation as current truth.

**Steps.**

1. Rewrite `docs/adr/0025-volume-aware-path-equality.md` around `RootNamespace`:
   the owner is the *root's rules*, not a free function, and capabilities are never
   defaulted. Record the measured facts — that `prefersDecomposedUnicode` was never
   probed, that exFAT normalizes on write, and that Swift `String` equality is
   canonical while `MediaRelativePath` was byte-wise.
2. Rewrite `docs/adr/0026-settled-naming-and-card-erase.md` around the manifest and
   `SourceEraser`: what a card erase removes, what proves each item, why it holds
   the *source* root's lease, and why it is journaled per item.
3. Amend `docs/adr/0015-observability.md` with the `run=` correlation ID and the
   synthetic-card harness.
4. `docs/architecture.md`: `RootNamespace` and its callers, and `SourceEraser` as the
   only source-mutating owner, in the where-to-change table.
5. `docs/requirements.md`: the rows for path equality, the readiness gate, and the
   erase set, each citing a test that exercises it.
6. Delete this plan.

**Verify.** `script/requirements-authority-check.sh`,
`script/ci-text-hygiene.sh check`, `script/check-doc-citations.sh`.

**Rollback.** Revert.

---

## Requirements and ADR changes

| Increment | Document | Change |
| --- | --- | --- |
| 1 | ADR 0015 | A run is correlated end to end; the erase reports its manifest against its outcome; the agent can attach a synthetic card |
| 2 | ADR 0025, ARC-033, ARC-056 | Namespace rules belong to the root and are never defaulted; an unprobed root does not reconcile deletions; one path equality law |
| 3 | ADR 0026, `import-bar.md`, APP-032 | The erase manifest is the count the user confirms and the count reported back |
| 4 | ADR 0026, ARC-055, ARC-045 | Source deletion has one owner, holds the source root's lease, and is journaled per item |
| 5 | ADR 0009 or ADR 0026, ARC-057 | The readiness gate terminates; enrichment-driven replans are coalesced and measured |
| 6 | `docs/requirements.md`, `design-system.md`, `import-bar.md` | A cited test must cover its row's named files; the guard allowlist is string-level |

---

## What this plan does not do

- **No content-addressed deduplication.** Plan 0096's Q2 deferred it and this plan
  does not reopen it. Q1 asks only whether the files a user is about to *delete*
  are proven, which is a bounded set on an explicit action — not a library-wide
  hashing pass.
- **No `CatalogStore` decomposition.** Increment 2 touches it in nine places; it is
  4,295 lines and its boundaries are still worth revisiting, but doing both at once
  would make every regression ambiguous.
- **No grid-performance work.** `mainThreadStall bracketedOp=MediaGridViewController.applyStructure`
  remains observed and unaddressed; it wants its own measurement-first plan.
- **No MTP hardware verification.** Plan 0095's camera work has still never been
  observed against a camera. The synthetic card in increment 1 is a volume, not an
  MTP device, and does not close that gap.
- **No change to what a mounted disk image means to the product.** Plan 0096
  increment 10's rule stands unless Q2 says otherwise.
