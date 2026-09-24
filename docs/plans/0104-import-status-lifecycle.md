# Plan 0104: Import status belongs to one attachment and one run

Status: planned; implementation has not started.

## Purpose and user report

After importing from one SD card, the user inserted an empty, different card and
ejected it. Otos showed the earlier card's “1055 items copied and verified” footer
under an unavailable-library screen. The user asked whether the status should be
discarded after ending the import, then requested a robust implementation plan.

Success means that a completed, successful import leaves no detached status bar;
a new card cannot inherit an earlier attachment's counts, actions, preferences,
or navigation. Import history and imported media remain intact. Unresolved import
outcomes must remain attributable to their own run without masquerading as a live
card. Fix the state lifecycle, not just the screenshot.

This document proposes the detailed behavior below. Before implementing, restate
the product rules to the owner and obtain confirmation of the unresolved-outcome
and zero-item-failure behavior. Creating this plan does not claim those changes
are already implemented. Do not add future behavior to the requirements registry.

## Evidence and remaining uncertainty

Inspected against local commit `61bc772` on 2026-09-22. These are code findings,
not a runtime reproduction of the user's exact card sequence:

1. `MediaOperationCoordinator.detachedBatchPresentations` retains settled
   presentations for the process lifetime. Detach snapshots `lastCompletion`,
   including clean completions, and constructs a `.completed` presentation.
2. `sortedPresentations()` combines live sessions with detached presentations.
   It excludes matching **batch IDs**, not matching source paths. Different
   attachments at one path can therefore coexist in the same list.
3. `selectedImportPresentation`, `sessionPreferences(for:)`, and
   `SidebarView.removableTrailingAccessory(for:)` select the first matching
   **source path**. They do not establish that the record belongs to the current
   attachment. Sorting that list differently would not fix the ownership error.
4. `lastBatchBySourcePath` remembers navigation separately. It clears when a live
   presentation with no batch arrives; that makes correctness depend on delivery
   of a particular attachment's presentation before its removal is handled.
5. Catalog state and import presentations arrive independently. A retained
   removable root can also outlive availability. Inspect that path before
   attributing the unavailable-library screen solely to the footer lookup.
6. Detach during execution removes the session and requests cancellation.
   `applyExecutionResult` then rejects results without a matching live session.
   Comments and APP-029 explicitly acknowledge the missing named source-removal
   outcome. `ExecutionContext.task` is currently an empty task, not the actual
   execution lifetime; it must not be treated as proof that work has drained.
7. Existing tests cover clean-batch hiding and same-path reattachment navigation,
   but the latter explicitly delivers a fresh live presentation before eject.
   That is useful coverage, not proof against other delivery orders.

Still to establish with tests/logs: whether the two physical cards reused a mount
path; which publication order produced the screenshot; whether a fast detach and
reattach can be coalesced before the coordinator observes absence. Do not invent
hardware identity or call this exact incident reproduced without evidence.

## Proposed behavior contract

“Clean” means the existing complete-success verdict, including verification and
any requested erase outcome. Do not redefine success as merely “some files copied.”

| Situation | Card surface | Import batch surface | Navigation |
| --- | --- | --- | --- |
| Attached, still being inventoried | Current attachment's preparation state | No old run is substituted | Preserve the user's selection |
| Attached and proven empty | Current empty-card state; Eject remains available | No new batch | Preserve selection |
| Import executing | Current run's progress and applicable controls | Same run's progress when selected | Existing first-published-item rule |
| Clean import settled, card attached | Current plan and Eject; current-attachment completion facts only | Footer disappears immediately | Keep selected batch or user-chosen scope |
| Clean import settled, card successfully ejected or confirmed detached | No card status; dispose of its transient state | No completion footer | Follow only this attachment's nonempty batch if the removed card was selected; otherwise use the existing fallback |
| Empty card ejected without an import | No card status | No old batch footer | Existing fallback, never a previous attachment's batch |
| Import stopped, failed, or partially completed | Current attachment's applicable recovery controls | Honest outcome for that exact run | No unrelated selection is changed |
| Same unresolved run after detach | No live-card status or card actions | Retain the unresolved run's outcome with its proven destination/counts | Follow only a valid batch from this attachment |
| Eject fails or volume is busy | Keep the live state and existing eject error | Do not claim the card was ejected | Keep selection |
| Card pulled during execution | Remove live card actions; drain the run | Final source-removal outcome after settlement, with actual published count | Never navigate to an unrelated batch |

Additional rules:

- A source path identifies media locations; an attachment generation identifies a
  temporary connection. Use existing typed generations/identities. Do not add
  durable card IDs, volume fingerprints, serial-number databases, or sidecars.
- A clean run may retain the small completion facts needed while its card is
  attached. Discard those on detach. “Discard status” never means deleting the
  import journal, imported items, or authored overlay.
- Existing path-based destination preference memory remains intentional. Do not
  confuse that persistent setting with per-attachment preference overrides.
- A detached unresolved outcome is immutable run history, not a source session.
  It cannot supply a new attachment's preferences, spinner, Eject, Import, Erase,
  or automatic selection. Keep the existing process-lifetime scope; do not add
  persistent notification storage, expiry timers, or a dismissal feature here.
- For a failed run with zero published assets, preserve the existing selected
  failure surface while settling; do not fabricate a nonempty batch or select a
  nonexistent sidebar row. Confirm the final source-gone presentation with the
  owner before coding it. If current navigation cannot display that outcome,
  specify that small UI change here first rather than silently losing the error
  or adding a generic catalog alert (APP-008).
- Unknown disappearance is “source disconnected/unavailable,” not proof of a
  successful safe eject. Only confirmed eject outcomes justify “safe to remove.”

## Architecture: smallest correct ownership model

Keep `MediaOperationCoordinator` as the single owner of operation lifecycle.
`CatalogStore` owns attachment/detachment facts; `CatalogProjection` derives
catalog scopes; the ViewModel delivers intents and assigns presentation; views
remain passive. No new service, protocol, cache, global singleton, or scheduler is
needed simply to fix this bug.

Replace the mixed live-plus-detached presentation contract. Publish one coherent
value containing separately addressable live-source state and batch state. Exact
type names are an implementation choice, but these boundaries are mandatory:

- Live-source lookup requires the current source and attachment generation. A
  batch-only outcome is structurally ineligible for this lookup.
- Batch lookup requires `ImportBatchID`. Derive a live run's batch presentation
  from its one execution record; retain only necessary unresolved facts once it
  settles/detaches. Do not keep two mutable authoritative copies of a run.
- Preserve destination and final counts from the executed run, not from a later
  selected destination or a rebuilt plan. Preserve stopped/failed/erase outcomes
  rather than converting every detach into generic success.
- Attachment-to-batch navigation must use the same attachment facts. Remove the
  path-only `lastBatchBySourcePath` workaround once its replacement is verified.
  A small view-model delivery record is acceptable only for the independent
  stream handoff: it must carry generation, have explicit reset rules, and not
  become a second owner of completion or availability.
- Reuse a Store-owned attachment generation if one exists. Otherwise establish
  the generation at the existing attachment owner and carry it through the
  projection and operation input. A generation minted only after observing a
  missing path cannot distinguish a disconnect/reconnect hidden by coalescing.
  Do not independently mint competing generations in the ViewModel.

While implementing, write a short lifetime table for each retained field:
owner, key, creation, updates, removal, and consumer. A field without a necessary
consumer or removal rule should not survive the refactor. Put lasting ownership
decisions in the relevant ADR, not in a second architecture document.

## Implementation sequence

### 1. Establish the baseline and reproduce before changing production code

1. Read `AGENTS.md`, `docs/architecture.md`, APP-029, APP-008, ARC-047,
   `docs/design/import-bar.md`, the design-system rules below, and ADRs 0019,
   0021, 0024 and 0027. Read ADR 0008 before touching root lifetime.
2. Start a dedicated `fix/` worktree from current remote main. Preserve unrelated
   work, including the pre-existing `Otos.xcodeproj/project.pbxproj` modification
   observed while planning. Inspect the last five PRs for unresolved comments as
   required by AGENTS.md; claim and resolve applicable comments on their threads.
3. Run and supervise the required baseline check. A red baseline must be fixed
   before merging implementation that could hide a build/test regression.
4. Use existing coordinator fixtures, fake plan builders/executors, and owner
   boundaries to model: import on A, detach A, attach empty B, select B, detach B.
   Run with different paths and then the same path.
5. Add a failing regression for the stale footer and a separate navigation
   regression. Deliver both stream orders, omit the intermediate fresh-card
   presentation, and release delayed callbacks explicitly. Avoid sleeps as
   synchronization; use controllable continuations and bounded test waits.
6. Capture pre-fix lifecycle logs using disposable test media or test fixtures.
   Do not format, erase, or write to the user's SD cards to reproduce this bug.

### 2. Separate live attachment state from unresolved run outcomes

1. Inventory every consumer of `importPresentations`, `sourcePath` lookup,
   `detachedBatchPresentations`, `cardStillExists`, and `lastBatchBySourcePath`.
   Include footer selection, sidebar indicators, preferences, destinations,
   automatic batch selection, and empty-batch pinning.
2. Introduce the concrete publication value described above. Migrate every
   consumer in the same increment; remove the old mixed array contract. Do not
   leave compatibility shims or fallback “first matching path” lookups.
3. Stop retaining clean detached presentations at the producer. Hide the clean
   batch footer immediately on settlement through the shared policy, while
   retaining the attached card's useful Eject action.
4. Store only the necessary unresolved run facts under batch identity. All
   published representations derive from the same facts through the existing
   presentation owner. Never manufacture a new success summary at detach.
5. Remove transient preference, progress, and diagnostic-deduplication state at
   attachment disposal where its consumer no longer needs it. Preserve the
   intentional destination preference setting and catalog-owned history.

### 3. Make detach, navigation, and late results deterministic

1. Trace the authoritative attach/detach event path through the Store and
   projection. Ensure a new attachment invalidates old navigation even if no
   fresh import presentation reaches the ViewModel before the next detach.
2. Handle both publication orders: catalog removal before operation cleanup,
   and cleanup before catalog removal. A temporarily unavailable retained root
   must not authorize an old live footer. Preserve legitimate unavailable-library
   behavior for fixed libraries.
3. Follow a removed selected card's batch only when that attachment produced it
   and the batch has published assets. Otherwise use the existing fallback.
   Respect the user navigating elsewhere; do not move them a second time.
4. Validate generation and current run ownership after every suspension that
   can affect publication, cancellation, settlement, or eject. Reject an old
   callback without discarding its legitimate run's final journal settlement.
5. Separate cancellation requested by the user from confirmed source removal.
   Record the first applicable interruption cause while the run is active;
   do not turn a previously completed run into a failure just because its card
   disappears afterward.
6. Keep the actual executing work owned until it settles/drains, even after its
   attachment is no longer live. If necessary move that execution context to a
   batch-keyed draining record owned by the same coordinator; transfer it, do
   not duplicate it. A replacement card at the same path must have a fresh
   session. Shutdown must await real work, not the current empty placeholder
   task. Release leases/claims according to actual filesystem work completion.
7. Use the executor/journal's final facts for copied counts and failures. A late
   result may settle its old batch but cannot update the new card, clear its
   task, eject it, change its destination, or steal selection.
8. Preserve one eject intent for automatic eject, sidebar control, and footer.
   Do not clear status merely because an eject request was sent; wait for the
   authoritative outcome. Verify the eject request targets its original
   attachment after any reader-drain or retry suspension.

### 4. Keep rendering passive and truthful

1. The footer asks the owner for the selected scope's presentation. It must not
   reconstruct lifecycle from booleans, timers, names, or independently observed
   streams. Apply the same selection policy to sidebar indicators.
2. Render detached failures/stops from their exact outcome. Remove controls whose
   source no longer exists; do not leave keyboard shortcuts acting on a new
   card at the same path.
3. Preserve the existing fixed footer height while it exists. Whole-surface
   removal is a lifecycle transition, not a smaller “Done” footer state.
4. Name each surface's one L1 fact; assign secondary text and controls to their
   design levels. Check DES-010–013, DES-018, DES-022, DES-029, DES-040,
   DES-053, DES-075 and DES-080. Update a conflicting design rule explicitly;
   do not silently introduce an exception.

## Required regression matrix

Tests assert observable state/intents, not private dictionary shapes or source
text. Extend existing suites instead of building a parallel test framework.

| Scenario | Required assertion | Primary suite |
| --- | --- | --- |
| A clean import settles while attached | Batch footer disappears; card still offers Eject | ViewModel / presentation |
| Clean A is ejected | No detached success footer can be retrieved | Coordinator |
| Empty B attaches and ejects after A | No A count, status, action, or batch navigation | Coordinator + ViewModel |
| B uses A's path and/or display name | Same result; path/name equality does not imply attachment equality | Coordinator adversarial |
| B detaches before fresh presentation is delivered | No remembered A navigation; correct fallback | ViewModel |
| Reattachment occurs before a coalesced refresh | Fresh generation; no reuse of A's session | Store/owner integration |
| Catalog removal and presentation cleanup swap order | Same final selection; no stale drawn footer in intermediate states | ViewModel |
| Old build/progress/result arrives after B attaches | Cannot mutate B; actual old execution still drains/settles | Coordinator adversarial |
| Successful eject versus failed/busy eject | Only confirmed disappearance clears card state; failure retains alert/actions | Eject owner + ViewModel |
| User cancels, disk floor stops, copy fails, or erase is incomplete | Correct distinct outcome survives replan and detach | Coordinator + presentation |
| Card pulled mid-copy with some items published | Source-removal outcome and actual settled count; no new-card mutation | Executor + coordinator |
| Card pulled before first published item | No fabricated batch count/navigation; agreed zero-item error remains visible | Coordinator + ViewModel |
| Source detaches during post-settlement replan | Clean result discarded; unresolved result preserved without stale plan | Coordinator adversarial |
| Destination changed after an earlier run | Old batch retains its actual destination; live plan uses new one | Coordinator |
| Two cards import concurrently | Each progress, result, indicator and eject belongs to its own attachment | Coordinator + ViewModel |
| User navigates away during import/eject | No forced jump to another scope | ViewModel |
| Repeated attach/detach and app shutdown | No accumulating clean snapshots or orphaned owned tasks; shutdown finishes | Coordinator lifetime tests |

Relevant existing test files: `MediaOperationCoordinatorTests.swift`,
`MediaOperationCoordinatorAdversarialTests.swift`,
`CatalogWindowViewModelMediaOperationsTests.swift`,
`ImportBarPresentationTests.swift`, `ImportPlanFooterTests.swift`, and
`RemovableEjectOutcomeTests.swift` under `OtosTests/`. Locate Store attachment
tests by the actual owner before adding generation coverage. Preserve existing
tests unmodified unless their asserted behavior is intentionally changed by the
confirmed contract; explain each changed expectation on the PR.

## Observability and runtime verification

Use `OtosLog` and the existing signposting facade. Add concise lifecycle events
only where current evidence is insufficient: attachment start/end, run settlement,
clean-state disposal, unresolved-outcome retention, selection fallback/follow,
and stale callback rejection. Correlate with existing typed attachment generation
and batch/run identity. Include cause and known counts; do not add invented
diagnostic identities, per-frame dumps, or media contents to logs.

Use `script/logs.sh` to demonstrate the complete before/after sequence. Because
this changes async ownership and rendering, capture an appropriate short trace
with `script/profile.sh` and export it with `script/profile-export.sh`. Report
the actual longest relevant MainActor span and cancellation/drain behavior; do
not claim a timing threshold from unit-test speed alone. No media I/O or database
work moves to MainActor.

Run the final `script/check.sh` in the background using the supported runner's
background option. Arm a monitor that prints the log tail/heartbeat every 60
seconds; stop that monitor in the same action that collects the result. Rising
test counts show progress. Three unchanged test-stage heartbeats require
diagnosis. If a run hangs, sample and identify the blocked owner; terminate the
whole process tree before restarting. Never call build/test/verify directly or
add a timeout that masks a lifecycle defect. Any edit after the run requires a
new final-tree run.

Exercise the footer and its disappearance in light/dark appearance, grayscale,
keyboard-only operation, and Reduce Motion. Use agent-operated disposable media
or fixtures; record any unavailable hardware check and substitute evidence as a
non-blocking limitation, without claiming it was performed.

## Documentation and review gates

- Update APP-029 for the implemented footer/navigation lifecycle and regression
  tests, and ARC-047 for attachment and execution ownership. Update APP-008 only
  if its existing eject-error behavior changes. No workflow rows belong there.
- Rewrite affected sections of `docs/design/import-bar.md` (Done, Stopped,
  Failed, dismissal, navigation, journeys, and state summary) consistently.
- Update `docs/architecture.md` for the actual publication and draining-work
  ownership. Review ADRs 0019/0021 for placement of the lifecycle decision;
  amend the decision in its existing home where appropriate, without duplicating
  ADR 0008's filesystem identity policy or ADR 0027's disk-floor policy.
- Review from the diff using implementation fidelity and blank-slate
  architecture lenses. Run the design lens for the changed footer behavior.
  Every confirmed invariant violation blocks merge.
- Explicit smell review: no path-only cross-attachment lookup; no two owners for
  availability/outcome; no parallel action path; no fake task handle; no orphan
  cancellation work; no untyped state dictionary; no speculative protocol or
  cache; no lifecycle logic in SwiftUI; no source-text tests; no diagnostic
  payload sprawl. Do not split cohesive types merely to satisfy lint warnings.
  Record actual findings and remedies on the PR, not a blanket “no smells” claim.

## Completion checklist

- [ ] Product rules, including source-gone failures with zero imported items, confirmed.
- [ ] Original stale-footer and stale-navigation scenarios reproduced in tests.
- [ ] Live attachment and historical outcome lookups structurally separated.
- [ ] Clean detached status discarded by its owner; no UI-only suppression fix.
- [ ] Detach/reattach and stream-order matrix passes with deterministic timing.
- [ ] Executing work drains and settles under a real owner after disconnect.
- [ ] User media, overlay retention, import history, and destination preferences preserved.
- [ ] Requirements, design spec, architecture, and ADR reflect implemented truth.
- [ ] Final-tree local check, logs, trace, visual and keyboard evidence recorded.
- [ ] Remote CI passes or the exact allowed billing/quota waiver is documented.
- [ ] Review findings resolved; complete DoD posted on PR and sent to the owner.
- [ ] Implementation merged; only its own proven-merged branch/worktree removed.
- [ ] Delete this plan and update the plan index when all its work is complete.

The planning increment itself is documentation-only: run text-hygiene and
requirements-authority checks, not Xcode build/tests. That does not provide
implementation verification or establish that main currently passes its suite.
