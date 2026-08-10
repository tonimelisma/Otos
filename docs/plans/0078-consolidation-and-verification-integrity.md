# Plan 0078 — Consolidation And Verification Integrity

Consolidates the six increments that landed on 2026-08-09/10 (plans 0071–0077), repairs
what they left broken, and closes the process hole that let them land broken. Written
after a full review of `4bff0b0..ce174a2` — 48 commits, 58 files, +1,952/−980.

This plan owns the remediation. It does **not** re-litigate the product decisions those
increments made; the four-state import UX, the reservation ledger, and the
materialization breaker are all kept.

---

## 1. Where we actually are

Verified, not assumed. Each claim below was reproduced in the repo.

| # | Finding | Evidence | Severity |
|---|---|---|---|
| F1 | `main` fails its own required gate. `script/verify.sh` exits non-zero on clean `HEAD` | Build and tests pass (`** TEST SUCCEEDED **`), then `check-production-data-untouched.sh --after` fails: a test run left `net.melisma.OtosTests.failedMutationDoesNotTerminateOrderedConsumer()…plist` carrying `{"import.destinationByDeviceIdentity":{},"import.destinationBySource":{}}`. `--before` passed, so this run created it | **Blocker** |
| F2 | `Otos/Stores/CatalogDatabase.swift` (171 lines) is unreferenced. All 16 call sites still use `CatalogStore`'s private copies. `DatabaseTimedValue` and `DatabaseOpenResult` are each declared twice | `grep -rn 'CatalogDatabase\|CatalogReader\|timedRead' --include='*.swift'` returns no use outside the file | High |
| F3 | That dead copy is **lossy**: `CatalogDatabase.database()` drops `performThumbnailStoreStartupMaintenance()`, `recordDatabaseOpenDiagnostics(...)`, and the `Catalog database opened` log that `CatalogStore.database()` performs | `CatalogDatabase.swift:25` vs `CatalogStore.swift:1958` | High |
| F4 | The reservation ledger, device-identity destination defaulting, the zero-copy delete path, and the metadata-gate wake have **no tests**. `MediaOperationCoordinatorTests.swift` still holds its original four tests | ARC-047's acceptance text names these behaviors and cites that file as verification | High |
| F5 | Plans 0072–0077 were **never committed**. 92 code/script comments cite them (`§5`, `I1–I5`, `decision 18`, `decision 20`, `plan 0076 §2`). Two scripts print `See docs/plans/0072-*.md` as remediation for a failing gate | `git log --all --diff-filter=A -- 'docs/plans/*0072*'` … returns nothing for 0072–0077 | High |
| F6 | ARC-042's gate greps the string `@unchecked Sendable`. `nonisolated(unsafe)` is the same unsoundness and is unguarded — 7 uses, several added in the same increment that removed the 14 `@unchecked` ones | `script/check-no-unchecked-sendable.sh`; `grep -rn 'nonisolated(unsafe)' Otos OtosTests` | Medium |
| F7 | The requirements gate validates that a cited path **exists**, not that it verifies anything. A row may claim coverage for untested behavior and pass | `script/requirements-authority-check.sh`; F4 is a live instance | Medium |
| F8 | 75 of 96 requirement rows are allowlisted out of that gate. "The allowlist only ever shrinks" is a comment, not an enforcement | `ALLOWLIST` in the same script | Medium |
| F9 | Destination auto-defaults to the **alphabetically**-first library when several exist. The required behavior is the **first-added** library. Add order exists in the Store (`RootRuntimeState.rowID`) but is dropped at the model boundary, so no consumer can see it. Also untested | `MediaOperationCoordinator.swift:648`, `CatalogStore.swift:2254`, `:453` | High — Stage 4 |
| F10 | `_ = (skippedForeignCount, failedCount)` under a comment claiming the counts are surfaced. They are surfaced nowhere on the cancelled path, not even a log | `MediaOperationCoordinator.swift:460` | Low |
| F11 | `docs/architecture.md`'s coordinator row omits the ledger, session preferences, and rebuild suppression. `docs/index.md`'s ADR table stops at 0015 while 0016–0020 exist | Both files | Low |
| F12 | 48 commits landed direct to `main`. No PR, therefore no review, on any of it | `gh pr list` — last PR is #180 | Process |
| F13 | 348 accumulated `net.melisma.OtosTests.*` preference domains on the dev machine | `ls ~/Library/Preferences/net.melisma.OtosTests.*` | Housekeeping |

### What is good and stays

- **The materialization breaker (0074) is the strongest work in the batch.** Injected
  `ContinuousClock` made it testable; scoping it so interactive demand is never
  suppressed is correct, and the reasoning is sound — a user's click is both the thing
  they are waiting on and the cheapest probe that the provider recovered. Untouched by
  this plan.
- `ImportPlanDetailReader` and `ImportPlanOverlay` were **deleted**, not shimmed.
- Cancel / retry / session-preferences are wired single-path (view → ViewModel →
  coordinator). No parallel behavior paths.
- The four-state import UX and the ledger design are kept. See ADR 0021.

---

## 2. WIP inventory — nothing is lost

Audited exhaustively before any cleanup. Recorded here so the disposition is provable
rather than asserted.

| Artifact | Finding | Disposition |
|---|---|---|
| Working tree | Clean. No modified, staged, or untracked files | Nothing to recover |
| `git stash list` | Empty | Nothing to recover |
| `feat/0072-remaining` (`797615b`) | `git cherry -v main` reports `-` — patch-equivalent to `main` | Safe to delete; SHA recorded |
| `feat/0072-verifiable-green` (`1d7a3f7`) | 0 commits ahead of `main` | Safe to delete; SHA recorded |
| `feat/0073-0074-loupe-breaker` (`a44eeb4`, `bf0def9`) | Both `-` under `git cherry` | Safe to delete; SHAs recorded |
| `.muse/worktrees/subagent-v2-…` | `prunable` — gitdir points at a directory that no longer exists | **Pruned** |
| 5 dropped stashes dated 2026-08-09 (`3513721`, `f6e00ae`, `4eb2352`, `cf76fd3`, `abadb4d`) | Compared file-by-file against `main`. The only files any of them hold that `main` lacks are `docs/plans/0071-import-ux.md` and the two deliberately-deleted files (`ImportPlanDetailReader.swift`, `ImportPlanOverlay.swift`) | No unique source work. Left in place; git keeps them reachable for the reflog window |
| ~120 other dangling commits | Pre-2026-08-09 rebase/squash residue from merged PRs | Left alone |
| `docs/plans/0071-import-ux.md` (375 lines) | Deleted by `630a74b` after implementation. **Contains the reservation-ledger design** (§4 conflicts C1–C5, §5 options O1–O4, §6 concurrent planning) that 92 comments cite | **Recovered** from `4bff0b0` into ADR 0021 by this increment |
| Plans 0072–0077 | Never written to the repo at any commit | Rationale reconstructed from code and commit messages; carried into this plan and ADR 0021 |
| `docs/research/2026-08-09-import-ux-benchmark.md` | Survived correctly in its MECE home | No action |

**Conclusion: no source work is lost.** The single at-risk artifact was the 0071 design
text, and it is recovered by this increment into a permanent home.

---

## 3. Root cause — one cause, thirteen symptoms

F1 through F12 are not thirteen independent mistakes. They are one:

> Six increments ran in a single session with **no plan committed, no PR, and no review**,
> and each one's verification was written by the same pass that wrote the code it checks.

Every finding is downstream of that:

- F5 exists because plans were never committed — so the design that the code cites has
  no home.
- F2/F3 exist because "Stage 1 of N" landed with no committed plan holding stages 2..N,
  so the half-migration has no forcing function and no reviewer to ask "where is the
  rest?"
- F4/F7/F8 exist because the same pass authored the behavior, the requirement row
  claiming it works, and the gate that checks the row. Nothing independent ever
  disagreed.
- F1 exists because two changes from the same session collided — 0071 made
  `persistDestinationMappings` chattier, 0072 made the leak detector absolute — and no
  one diffed them together.

So a remediation that only fixes the artifacts is itself a band-aid. Stages 6 and 8 are
not optional garnish; they are the half of this plan that stops the recurrence.

---

## 4. The to-be vision

Three principles. Each is testable, and each directly kills a class of finding above.

### P1 — A gate must fail for the reason it exists

Today's gates check *proxies*: a spelling (`@unchecked Sendable`), a file's existence
(`Tested by` paths). Every proxy is a place where the gate passes green while the
invariant it names is broken — which is precisely what F4 and F6 are.

To-be: every ARC requirement is in exactly one of two states, and which one is visible.
Either its acceptance criterion is verified by a **test that fails when the behavior
breaks**, or the row says plainly that it is not machine-verified. No row may claim more
than its verification actually checks. A gate that cannot express an invariant should
say so rather than approximate it.

### P2 — Fully migrated, or not started

No "Stage 1 of N" extraction may sit in the tree without either its remaining stages in
a committed plan, or the migration completed. A new owner beside its still-live original
is not progress toward a better boundary; it is two owners for one question, which is
the exact smell CLAUDE.md names.

Applied to F2/F3, this forces a real decision rather than leaving the file to rot — and
the honest answer is in Stage 2.

### P3 — The design lands before the code that cites it

A code comment may only cite a document that exists in the repo **at the same commit**.
This is mechanically checkable and cheap, and it is the direct antidote to F5: 92
comments pointing at six documents that never existed.

Corollary, and the process rule that would have prevented most of this batch: **an
increment's plan is committed before its implementation merges.** Not after, not
alongside — before. That is what makes a plan a design artifact rather than a
retroactive changelog.

---

## 5. Stages

Ordered by dependency. Stage 1 is a merge blocker for everything else in the repo.

### Stage 1 — Green `main` (blocker)

Nothing else may merge first; CLAUDE.md's red-`main` rule exists because plan 0065
already lost two PRs to exactly this.

- Fix `persistDestinationMappings()` (`MediaOperationCoordinator.swift:1111`) to not
  write empty dictionaries. `set` a non-empty map; `removeObject` otherwise — matching
  what it already does for `lastUsedDestination`. Writing two empty dictionaries on
  every source refresh is pointless I/O regardless of the test signal, so this is the
  writer's bug, not the guard's.
- Run `script/purge-test-preference-domains.sh` to clear the 348 accumulated domains
  (F13).
- Re-run `script/verify.sh` and attach the result. Capture the exit status directly —
  piping it into `tail`/`head` masks the status and reports a false green.

**Done when:** `script/verify.sh` exits 0 on a clean tree, with the status observed
un-piped.

### Stage 2 — Resolve the 0076 half-migration by deleting it

**Recommendation: delete `Otos/Stores/CatalogDatabase.swift`.**

This is the honest call, not the lazy one. The extraction's stated benefit was removing
an actor hop in front of GRDB's already-serialized `DatabaseWriter` — a performance
argument that was never measured. CLAUDE.md forbids exactly that: no caches, pools, or
generalized abstractions before measurement proves the simple path insufficient. As
merged, the file also carries three silent regressions (F3) waiting for whoever wires it
up.

So: delete it, and record here what a future extraction must preserve.

- Delete the file. `CatalogStore` is unchanged and remains the single persistence owner.
- If profiling later shows the `CatalogStore` actor queue is a real bottleneck, redo the
  extraction **in one increment**, preserving `performThumbnailStoreStartupMaintenance()`,
  `recordDatabaseOpenDiagnostics(...)`, and the open log, and making the timed wrappers
  `nonisolated` (they take the writer as a parameter and touch no actor state, so their
  isolation buys nothing but a suspension point).
- Evidence that would justify reopening it: `CatalogOpenDatabase` / slow-query signposts
  showing measurable queueing in front of the writer.

**Done when:** no unreferenced persistence type remains, and the reopening criterion is
written down.

### Stage 3 — Restore the design record (kills F5's 92 dangling references)

- ADR 0021 lands with this increment — the reservation ledger's context, decision,
  rejected alternatives, and R1–R5.
- Rewrite every code comment citing an uncommitted plan to cite ADR 0021 (or the
  relevant requirement ID) instead. Sweep: `§5`, `I1–I5`, `decision 18`, `decision 20`,
  `plan 0072`–`plan 0077`.
- Fix the two scripts that print `See docs/plans/0072-*.md` as remediation
  (`check-no-unchecked-sendable.sh:10`, `ci-text-hygiene.sh:134`) to cite ARC-042 and
  the real guidance.
- References to plans **0073–0075** describe UI decisions with no surviving home. Fold
  the load-bearing ones into the requirement rows they support and delete the citation;
  do not invent ADRs for decisions that requirements already state.

**Done when:** no comment in `Otos/` or `script/` cites a document absent from the tree.

### Stage 4 — Destination default is the first-added library (F9)

**Requirement (owner-stated, 2026-08-10):** when no saved mapping and no last-used
destination apply, the destination defaults to the **first configured media library, in
the order the libraries were added.**

As built, `MediaOperationCoordinator.swift:648` sorts by `path.rawValue` and takes the
first — alphabetical by path, not add order. That is wrong and must change.

**The reason it was built wrong is a real gap, and fixing that gap is this stage's
actual work.** Add order already exists and is already durable:
`RootRuntimeState.rowID` (`RootRuntimeState.swift:9`) holds `library_root.id`, declared
`table.autoIncrementedPrimaryKey("id")` in migration `v3_sort_key_separator`
(`CatalogStorePersistence.swift:79`). GRDB emits `INTEGER PRIMARY KEY AUTOINCREMENT`,
and SQLite **never reuses** an AUTOINCREMENT id — so the column is strictly monotonic in
insertion order for the life of the catalog, including across remove-and-re-add. A root
removed and added again is genuinely newest, which is the correct reading of "the order
they were added."

That fact is **dropped at the model boundary**: `catalogLibraryState(from:)`
(`CatalogStore.swift:2254`) does not copy `rowID` onto `CatalogLibraryState`, so no
consumer can see add order. An implementer who does not fix that will reach for whatever
the model does expose — which is exactly how `path.rawValue` got chosen the first time.

Steps:

1. Carry add order onto `CatalogLibraryState`. Source it from the existing
   `RootRuntimeState.rowID`; do **not** invent an ID, a timestamp, or a sequence counter
   — CLAUDE.md requires preferring existing persistence identity.
2. `CatalogStore.currentLibraries()` (`:453`) currently maps `roots.values`, which is
   dictionary order and therefore **nondeterministic across launches**. Return it sorted
   by add order so the one owner answers "what order were these added" once, rather than
   every consumer re-deriving it.
3. `MediaOperationCoordinator` takes the first available fixed library in that order.
   Delete the `sorted { $0.path.rawValue < $1.path.rawValue }` fallback and the
   `fixedAvailable.count == 1` special case — with a defined order, "sole" and "first"
   are the same expression.

Two clarifications an implementer will need, both settled here so nobody guesses:

- **Availability.** The default is the first *available* fixed library in add order. A
  library that is not currently available cannot receive an import, so skipping it is
  the only behavior that can succeed. It is not a new rule; it is the existing
  `fixedAvailable` filter, kept.
- **Display order is not touched.** `CatalogWindowPolicy.sortLibraries` orders the
  sidebar by display name. That is a *presentation* order and stays exactly as it is.
  This stage changes only which library is *defaulted as a destination*. Do not unify
  the two.

Tests:

- `destinationDefaultsToFirstAddedLibrary` — three libraries added in a non-alphabetical
  order; a source with no saved mapping defaults to the first *added*, not the first
  alphabetically.
- `destinationDefaultSkipsUnavailableFirstLibrary` — first-added library unavailable →
  defaults to the next available in add order.
- `savedDeviceMappingBeatsAddOrder` and `lastUsedBeatsAddOrder` — the three-step order
  holds.
- `invalidSavedMappingIsDroppedNotUsed` — a saved destination that is no longer an
  available fixed library is discarded, and the default recomputes.

Requirements: update ARC-047 to say "first-added library" instead of "sole/first
library" **in this PR**, because this is the PR where the behavior becomes true. Not
before.

**Done when:** the default is add-ordered, `currentLibraries()` has a defined order, and
the four tests above fail if the ordering regresses.

### Stage 5 — Test the remaining import invariants (F4, the real debt)

The largest stage, and the one that makes the rest of ARC-047's `Tested by` column true.
Each bullet is one test; the name is the deliverable.

Ledger (ADR 0021 R1–R5), against the pure planner plus the coordinator:

- `concurrentPlansIntoOneDestinationClaimDisjointNames` — two sources, one destination,
  both reach `.ready`; their claimed name sets do not intersect (R1, C1).
- `conflictingPublishReplansAndNeverEvicts` — force two builds to publish against the
  same free name; the loser re-dirties, rebuilds seeded from the winner's registered
  claims, and converges. The winner's claim is unchanged throughout (R4).
- `claimIsReleasedOnDetach`, `claimIsReleasedOnCancel`, `claimIsReleasedOnFailure` —
  three tests, one per death path (R1).
- `settledNameIsObservedAsOccupancyByNextBuild` — after settlement the next build sees
  the name through the namespace read, not through the ledger (R2).
- `conflictCheckUsesCurrentLedgerNotBuildStartSnapshot` — register a claim *while* a
  build is suspended; the resuming build must check against the newer ledger (R3). This
  is the one that would catch a regression to snapshot-time checking, so it must
  actually interleave, not just assert the final state.

Delete path — the highest-blast-radius path in the app:

- `zeroCopyPlanWithDeleteRequestedExecutesDeletion`
- `zeroCopyPlanWithoutDeleteStaysReady`

Metadata gate:

- `catalogChangeWakesWaitingForMetadataSource`
- `policyThatNeverConsultsDateDoesNotWait`

Also in this stage: fix F10 at `MediaOperationCoordinator.swift:460`. Either surface
`skippedForeignCount` / `failedCount` on the cancelled path or delete the dead tuple
**and its comment**. A comment describing behavior the code does not have is worse than
no comment.

**Done when:** every ARC-047 acceptance clause maps to a named test that fails if the
behavior regresses, and `ARC-047`'s `Tested by` column is true.

### Stage 6 — Make the gates check invariants (P1)

Four independent sub-stages; each may land as its own PR.

**6a — ARC-042 covers the invariant, not one spelling.** First establish empirically
whether `nonisolated(unsafe)` is still needed on the `UserDefaults` properties now that
the actor initializers take `sending UserDefaults`: delete the annotation from
`MediaOperationCoordinator.swift:35`, `LibraryReorganizationRunner.swift:12`, and
`CatalogWindowViewModel.swift:138` and build. Keep whatever the compiler proves
necessary; delete the rest. Then extend `script/check-no-unchecked-sendable.sh` to also
fail on `nonisolated(unsafe)`, with an enumerated allowlist carrying a one-line
justification per entry. A gate that bans one spelling of an unsoundness while its
sibling spelling grows unchecked is the same failure ARC-042 was written to stop.

**6b — Allowlist shrink-only (F8).** `script/requirements-authority-check.sh` states
"the allowlist only ever shrinks" in a comment. Enforce it: commit the expected entry
count next to the list and fail when the actual count exceeds it. A rule stated in a
comment, inside a script whose purpose is replacing comment-rules with gates, is
self-undermining.

**6c — `Tested by` must name a test, not a file (F7).** Today the gate checks that a
cited path exists on disk, so a row can claim coverage for untested behavior and pass —
F4 is a live instance. Change the `Tested by` cell format to
`` `path/to/File.swift#testName` `` and have the gate assert that the named test exists
in that file. Migrate rows as their behavior gets tested rather than all at once; the
allowlist from 6b is the migration ledger.

**6d — Citations resolve (P3).** New gate: scan comments in `Otos/` and `script/` for
`docs/…` paths and `plan NNNN` references, and fail when the referenced document is
absent at that commit. Cheap, and it would have caught all 92 instances of F5 on the
first commit that introduced them.

**Done when:** each new or changed gate has a self-test proving it **fails on a seeded
violation** — `script/ci-text-hygiene.sh` already has a `self_test` to copy. The gates
get the same oracle discipline as the code, which is the whole point of P1.

### Stage 7 — Documentation current-state repair (F11)

- `docs/architecture.md`: the `MediaOperationCoordinator` row names the reservation
  ledger, per-source session preferences, device-identity destination policy, and
  execution-scoped rebuild suppression. **Landed 2026-08-10 (PR #181).**
- `docs/index.md`: ADR table extended through 0021. **Landed 2026-08-10 (PR #181).**
- ARC-047's `Requirement` cell says "first-added library" — lands with Stage 4.
- ARC-047's `Tested by` becomes true as Stage 5 lands, not before.

### Stage 8 — Process restoration (F12)

- Return to the PR path. One increment per PR, reviewed against the two lenses.
- Adopt P3's corollary: **a plan is committed before its implementation merges.**
- Branch/worktree cleanup at DoD, as CLAUDE.md already requires — today's three stale
  branches are the visible symptom of skipping it six times.

---

## 6. Implementing this plan

**There are no open decisions. Nothing in this plan requires an owner ruling before
work starts.** Every question that arose while writing it has been settled in the stage
that owns it.

### Order and gating

Stage 1 blocks everything: `main` is red, and CLAUDE.md forbids merging anything except
the fix that greens it. After that, Stages 2, 3, 4 and 6 are independent of each other.
Stage 5 depends on Stage 4 (its destination tests must be written against the corrected
add-order behavior, not written twice). Stage 7 is bookkeeping that follows whatever
lands. Stage 8 is continuous.

```
1 ─┬─> 2
   ├─> 3
   ├─> 4 ──> 5
   └─> 6
```

One stage per PR. Stage 6's four sub-stages may each be their own PR.

### Rules that apply to every stage

- **Do not invent requirements.** If this plan does not state a behavior and the code
  does not implement it, it is not in scope. Ask; do not choose. A plausible-sounding
  product improvement invented mid-implementation is a defect, not a bonus — that is how
  F9 arrived.
- **Requirements rows move with the behavior**, in the same PR — not before it is true,
  not after.
- **Behavior-preserving work keeps existing tests green unmodified.** Stages 2, 3, 6 and
  7 change no product behavior; if a test needs editing there, stop and work out why.
- **Verify un-piped.** `script/verify.sh | tail` reports the exit status of `tail`, not
  of the script. Run it bare, or capture `${PIPESTATUS[0]}`. A false green from this
  exact mistake is how F1 stayed invisible.
- **Cite only what exists.** No comment may reference a document not in the tree at that
  commit (P3). ADR 0021 and this plan are the only valid targets for import-ledger
  citations.

### Per-stage verification

| Stage | Verify with |
|---|---|
| 1 | `script/verify.sh` exits 0, status observed un-piped, on a clean tree |
| 2 | `script/verify.sh`; plus `grep -rn 'CatalogDatabase\|CatalogReader' Otos/ OtosTests/` returns nothing |
| 3 | `grep -rn 'plan 007[2-7]\|docs/plans/' Otos/ script/ --include='*.swift' --include='*.sh'` returns nothing unresolvable |
| 4 | The four named tests; `script/verify.sh` |
| 5 | The eleven named tests; `script/verify.sh` |
| 6 | Each gate's self-test fails on a seeded violation, then passes when it is removed |
| 7 | `script/requirements-authority-check.sh`, `script/ci-text-hygiene.sh check` |

### WIP hygiene, every increment

The repo is clean as of 2026-08-10: no stashes, no untracked files, no stale branches,
no stale worktrees, `main` == `origin/main`. Keep it that way — six increments skipped
this and left three dead branches plus a broken worktree behind (§2).

- Start each stage in its own worktree on a conventional branch (`fix/`, `feat/`,
  `refactor/`, `docs/`).
- At DoD: merge, remove the worktree, delete the branch locally and on the remote,
  confirm `git status`, `git stash list`, `git worktree list` and `git branch -a` are
  clean, and confirm `git rev-list --left-right --count origin/main...HEAD` is `0 0`.
- Never delete a branch, worktree, or stash without proving it merged or
  patch-equivalent — `git cherry -v main <branch>` showing only `-` is the proof.

---

## 7. Non-goals

- Re-opening the four-state import UX, the ledger design, or the breaker. All three are
  kept as built; ADR 0021 records the ledger's rationale.
- Refactoring `MediaOperationCoordinator` for size. It is 1,141 lines and owns a lot —
  presentation state machine, destination policy, session preferences, ledger, build
  scheduling, execution lifecycle, persistence, rebuild suppression. That is worth
  watching, and destination policy in particular looks separable, but splitting a
  cohesive type before its invariants have tests would remove the safety net exactly
  when it is needed. Revisit after Stage 5.
- Performance work of any kind. Nothing here is measured as slow.
- Changing sidebar or Settings library ordering. `CatalogWindowPolicy.sortLibraries`
  orders those by display name and stays as it is; Stage 4 changes only which library is
  defaulted as an import destination.
- Any new user-facing affordance, prompt, confirmation, or state. This plan fixes what
  exists and tests it. It adds no product surface.

## 8. Done means

- `script/verify.sh` green on `main`, status observed un-piped.
- No unreferenced persistence type in the tree.
- No comment citing a document that does not exist.
- The import destination defaults to the first-added available library.
- Every ARC-047 acceptance clause backed by a named test.
- Every new or changed gate self-tested against a seeded violation.
- `docs/architecture.md`, `docs/index.md` and `docs/requirements.md` describe the
  current tree.
- Stale branches and worktrees gone; this plan deleted when its stages are done.
