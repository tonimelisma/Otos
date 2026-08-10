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
| F9 | Destination is now auto-selected as the alphabetically-first library when several exist, and `.waitingForDestination` was removed. Combined with delete-after-import this is the app's largest blast radius, and it is untested | `MediaOperationCoordinator.swift:648`, `:283` | Medium — needs an owner decision (§6 D1) |
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

So a remediation that only fixes the artifacts is itself a band-aid. Stage 5 is not
optional garnish; it is the half of this plan that stops the recurrence.

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

### Stage 4 — Test the import invariants (F4, the real debt)

This is the largest stage and the one that makes ARC-047's `Tested by` column true.

Ledger (ADR 0021 R1–R5), against the pure planner plus the coordinator:

- Two sources planning into one destination produce **disjoint** claims.
- A conflicting publish re-dirties and converges instead of evicting the registered
  claim (R4).
- A claim is released on detach, on cancel, and on failure (R1).
- A settled entry's name is observed as real occupancy by the next build (R2).
- A build that suspends and resumes checks against the **current** ledger, not its
  build-start snapshot (R3).

Destination policy (F9): device-identity mapping wins; then last-used; then sole/first;
an invalid saved mapping is dropped rather than used.

Delete path: zero-copy **plus** delete-requested executes the deletion; zero-copy
**without** delete stays `.ready`. Given this is the highest-blast-radius path in the
app, it gets an explicit test before anything else changes near it.

Metadata gate: a catalog change that supplies dates wakes a `.waitingForMetadata`
source; a policy that never consults a date does not wait at all.

Also in this stage: fix F10 — either surface `skippedForeignCount` / `failedCount` on the
cancelled path or delete the dead tuple and its false comment. Do not keep a comment that
describes behavior the code does not have.

**Done when:** each ARC-047 acceptance clause maps to a named test that fails if the
behavior regresses.

### Stage 5 — Make the gates check invariants (P1)

- **ARC-042.** First establish whether `nonisolated(unsafe)` is still needed on the
  `UserDefaults` properties now that the actor initializers take `sending UserDefaults`
  — the combination is suspicious and may simply compile without it. Remove what is
  removable; extend the gate to the remainder with an enumerated, justified allowlist.
  A gate that bans one spelling of an unsoundness while its sibling spelling grows
  unchecked is the same failure ARC-042 was written to stop.
- **Allowlist shrink-only (F8).** Enforce mechanically — commit the count and fail when
  it grows. A rule stated in a comment, inside a script whose purpose is replacing
  comment-rules with gates, is self-undermining.
- **`Tested by` must name a test symbol, not just a file (F7).** This is the heavier fix
  and the one that actually closes the false-assurance hole. Cheaper interim: require
  the cited file to contain a test whose name is declared in the row.
- **New gate: citations resolve (P3).** Grep comments in `Otos/` and `script/` for
  `docs/…` paths and `plan NNNN`, and fail when the referenced document is absent at
  that commit. Cheap, and it would have caught all 92 instances of F5 on the first
  commit.

**Done when:** each new gate has a self-test proving it fails on a seeded violation —
the gates get the same oracle discipline as the code.

### Stage 6 — Documentation current-state repair (F11)

- `docs/architecture.md`: the `MediaOperationCoordinator` row names the reservation
  ledger, per-source session preferences, device-identity destination policy, and
  execution-scoped rebuild suppression.
- `docs/index.md`: ADR table extended through 0021 (currently stops at 0015).
- ARC-047's `Tested by` becomes true as Stage 4 lands, not before.

### Stage 7 — Process restoration (F12)

- Return to the PR path. One increment per PR, reviewed against the two lenses.
- Adopt P3's corollary: **a plan is committed before its implementation merges.**
- Branch/worktree cleanup at DoD, as CLAUDE.md already requires — today's three stale
  branches are the visible symptom of skipping it six times.

---

## 6. Open owner decisions

**D1 — Destination auto-defaulting when several libraries exist (F9).**

Plan 0071 decision 11 removed "choose a destination library" so that a destination is
always defaulted. As built, when no saved mapping and no last-used destination exist and
several libraries are available, the coordinator picks the **alphabetically first** one.
Combined with delete-after-import, a user who never chose a destination can copy into an
arbitrary library and then delete from the card.

Options:

- **(a) Keep as built.** Fastest path, matches decision 11 literally. Requires that the
  bar always show the chosen destination prominently enough that "arbitrary" is
  immediately visible and correctable.
- **(b) Keep the default, gate the delete.** Delete-after-import stays off and cannot be
  enabled until the destination has been explicitly confirmed once for that device.
  Preserves "never a blocking destination picker" while removing the irreversible half.
- **(c) Restore an explicit choice** when more than one library exists and nothing is
  saved — reintroduces the state decision 11 deleted.

**Recommendation: (b).** It honors decision 11 — no blocking picker, the import path is
never stalled — while requiring one explicit confirmation before the only irreversible
action in the flow. The reversible default stays automatic; the irreversible one does
not.

This decision does not block Stages 1–5. Stage 4 tests the behavior as built; if (b) is
chosen, the test changes with it.

**D2 — Whether `nonisolated(unsafe)` on `UserDefaults` is needed at all.** Empirical, not
a preference: Stage 5 establishes it by removing the annotation and compiling.

---

## 7. Non-goals

- Re-opening the four-state import UX, the ledger design, or the breaker. All three are
  kept as built; ADR 0021 records the ledger's rationale.
- Refactoring `MediaOperationCoordinator` for size. It is 1,141 lines and owns a lot —
  presentation state machine, destination policy, session preferences, ledger, build
  scheduling, execution lifecycle, persistence, rebuild suppression. That is worth
  watching, and destination policy in particular looks separable, but splitting a
  cohesive type before its invariants have tests would remove the safety net exactly
  when it is needed. Revisit after Stage 4.
- Performance work of any kind. Nothing here is measured as slow.

## 8. Done means

- `script/verify.sh` green on `main`, status observed un-piped.
- No unreferenced persistence type in the tree.
- No comment citing a document that does not exist.
- Every ARC-047 acceptance clause backed by a named test.
- Every new gate self-tested against a seeded violation.
- `docs/architecture.md` and `docs/index.md` describe the current tree.
- Stale branches and worktrees gone; this plan deleted when its stages are done.
