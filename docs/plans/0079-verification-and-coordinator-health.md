# Plan 0079 — Verification And Coordinator Health

## Status

Approved direction: restore the codebase to a state where green evidence is trustworthy,
asynchronous import work has one explicit lifecycle owner, tests exercise the owner they
claim to verify, and test configuration cannot fall through to production state.

This plan is intentionally larger than a local patch. Effort is not a decision criterion.
Each implementation stage lands as its own reviewed PR, but the plan is complete only when
all stages have merged, final verification has passed on `main`, local/remote WIP is clean,
and this file is deleted.

## 1. Why this plan exists

A fresh review of `main` at `b4da4ef` found a codebase that builds and tests successfully
but cannot yet support the claim that all known issues are fixed.

| ID | Finding | Concrete evidence | Severity |
| --- | --- | --- | --- |
| H1 | The requirements gate is false-green | `script/requirements-authority-check.sh` uses a BSD-incompatible `sed` alternation at line 79. It extracts an empty ID for all 96 rows, then `continue`s. Cell-length, token, verification, and allowlist checks do not run. | Blocker |
| H2 | The registry already contains a malformed row that H1 misses | `ARC-047` has one duplicated acceptance cell: eight pipe-delimited fields rather than the table's seven. The gate reports clean. | High |
| H3 | A stale plan build can resurrect a detached source | `refreshSources` cancels and removes a build task, but off-actor namespace enumeration does not observe cancellation. Completion checks occupancy and destination only, then can re-register claims and publish presentation for a source removed while it awaited. | High |
| H4 | Rapid detach/reattach can lose the new task handle | An older build's unconditional `defer { buildTasks.removeValue(forKey: source) }` can remove a newer same-path build's handle after the dictionary entry has been replaced. | High |
| H5 | Ledger lifecycle tests do not exercise the ledger | `claimIsReleasedOnDetach`, `claimIsReleasedOnCancel`, and `claimIsReleasedOnFailure` call the stateless pure planner twice. They perform no detach, cancel, failure, coordinator transition, or claim release. | High |
| H6 | Several other test names overstate their oracle | The conflict/current-ledger tests inject `additionalReserved` directly into the pure planner rather than suspending a coordinator build across a real ledger change. The zero-copy "stays ready" test invokes the executor directly and never observes coordinator Ready state. | High |
| H7 | Test preferences can fall through to production | `CatalogWindowViewModel` accepts a test `UserDefaults` object and an independent optional suite name. Tests usually supply the first but omit the second; media-operation actors then construct `.standard`. | High |
| H8 | Current-state documentation contradicts itself | ADR 0021 says R1–R5 are untested and points to deleted plan 0078; ARC-047 claims named coverage; `docs/architecture.md` still describes the fallback as `sole/first` rather than first-added available. | Medium |
| H9 | A hidden local plan still looks like active WIP | `.cursor/plans/remove_dead_test-only_code_0d84b101.plan.md` is ignored via `.git/info/exclude`, dated 2026-07-01, and has seven todos marked pending. It is not visible in ordinary `git status`. | WIP hygiene |
| H10 | The suite has timing-based assertions in the affected owner | `MediaOperationCoordinatorTests` contains fixed sleeps of 20–400 ms around state transitions. Those tests can pass or fail based on scheduler load rather than the intended transition. | Medium |

What is already good and must be preserved:

- `script/verify.sh` genuinely builds the app, runs the complete XCTest/Swift Testing
  suite, and protects the production catalog/preferences before and after tests.
- `CatalogStore` remains the one durable catalog and transaction owner.
- `MediaTransferPlanner` is a pure, deterministic planning function.
- `MediaImportExecutor` owns filesystem execution and durable recovery.
- Exclusive publication remains the last defense against foreign writers.
- The filesystem remains truth; the reservation ledger remains process-local coordination.
- There are no live feature branches, stashes, open PRs, open issues, or registered
  secondary worktrees at the review point.

## 2. The target vision

The healthy end state has four properties.

### V1 — Green means the named invariant was actually checked

A gate has a self-test that seeds the violation it exists to catch. A requirement row has
one valid table shape. Its verification cell either names the exact executable proof or
states a bounded unverified clause honestly. Existence of a file or a plausibly named
test is traceability, not proof of behavior.

### V2 — One attached source is one lifecycle value

The coordinator does not infer a source lifecycle by correlating parallel dictionaries
and sets. One actor-owned `SourceSession` contains the current attachment generation,
destination, preferences, phase, ready plan/claims, and owned task/executor handles.
Every asynchronous completion carries typed session/build identity and can mutate state
only if it still belongs to the current session.

### V3 — Cancellation stops work; identity rejects stale completion

Cancellation is a resource-management request, not a correctness proof. Detach and
shutdown cancel owned work, but every completion also revalidates current ownership before
publication or execution. A cancellation-insensitive filesystem call may finish; its
result becomes inert.

### V4 — Tests enter through the same owner intents as the product

Planner tests prove planner decisions. Executor tests prove filesystem execution and
recovery. Coordinator tests attach/detach sources, queue/cancel imports, suspend/resume
builds, and observe public presentation/plan outcomes. A lower-layer simulation never
claims to prove an upper-layer lifecycle.

## 3. Design rules for the implementation

These rules are acceptance constraints, not suggestions:

1. Do not keep the existing parallel-state model and add one more `guard` as the final
   architecture. A minimal guard may be used only inside the same PR that introduces the
   single-session lifecycle and tests it.
2. Do not rely on `Task.isCancelled` alone. Validate session identity and build identity
   after every `await` that separates observation from mutation.
3. Do not generate durable media/source identity. Lifecycle generations are process-local
   typed counters and are never persisted, logged as domain identity, or written beside
   media.
4. Do not move destination naming into the executor. Ready plans must remain immutable and
   user-visible before execution; ADR 0019/0021 continue to apply.
5. Do not persist the claims ledger or let the executor read it. Claims are derived from
   live ready/executing sessions; the filesystem remains truth.
6. Do not add test-only branches to production behavior. A controllable plan builder is a
   real substitution boundary because plan construction is already an independently owned
   asynchronous operation.
7. Do not add Swift tests that read source files and assert on substrings. Script
   self-tests may validate documentation/script parsers in isolated temporary fixtures.
8. Do not split cohesive files merely to reduce SwiftLint size warnings. New boundaries
   must correspond to one owner or a real substitution seam.
9. Do not use roadmap ideas to fill gaps. Only current requirements, ADRs, observable code,
   and explicit owner guidance may define the result.

## 4. Target coordinator model

### 4.1 One session table

Replace the source-indexed collections that independently describe one source
(`presentations`, `readyPlans`, `destinationBySource`, `queuedStart`, `dirty`, `building`,
`executing`, `executors`, `attachStartedAt`, `attachToReadyMs`, `buildTasks`,
`claimsBySource`, and `sessionPreferences`) with:

```swift
private var sourceSessions: [LibraryRootPath: SourceSession]
```

`SourceSession` is actor-isolated state. It is not `Sendable` and never leaves the
coordinator.

Minimum fields:

```swift
private struct SourceSession {
    let attachmentGeneration: AttachmentGeneration
    var root: CatalogLibraryState
    var destination: LibraryRootPath?
    var preferences: ImportPreferences
    var phase: SourcePhase
    var isDirty: Bool
    var importRequested: Bool
    var nextBuildGeneration: UInt64
    var attachStartedAt: ContinuousClock.Instant
    var attachToReadyMs: Int?
}
```

Use small wrapper value types for `AttachmentGeneration` and `BuildGeneration` so the
compiler prevents comparing unrelated counters. Both are process-local monotonic values.

### 4.2 One mutually exclusive phase

`SourcePhase` must make invalid combinations unrepresentable:

```swift
private enum SourcePhase {
    case inventory
    case waitingForMetadata(done: Int, total: Int)
    case building(BuildContext)
    case ready(ReadyContext)
    case executing(ExecutionContext)
    case completed(CompletionContext)
    case failed(problem: String)
}
```

- `BuildContext` contains its typed build generation and owned `Task<Void, Never>`.
- `ReadyContext` contains the immutable `MediaOperationPlan`, skipped-package count,
  and its complete claim set.
- `ExecutionContext` retains the plan claims, executor, and owned execution task. Claims
  stay alive for the whole execution and die once at terminal settlement/cancel/failure.
- Presentation is derived from `SourceSession`; it is not separately authoritative.

If storing a task in the enum makes construction awkward, the task handle may be a field
on `SourceSession`, but phase plus handle must be changed together in one synchronous actor
method and tests must prove no mismatched combination is observable.

### 4.3 Explicit transition functions

All mutation goes through these small actor-isolated transitions (names may improve, but
responsibilities may not be combined ambiguously):

- `attachOrRefreshSource(_:)`
- `detachSource(path:reason:)`
- `markDirty(path:reason:)`
- `beginBuild(path:)`
- `finishBuild(key:result:)`
- `failBuild(key:error:)`
- `requestImport(path:)`
- `beginExecution(path:ready:)`
- `finishExecution(key:result:)`
- `requestCancellation(path:)`
- `beginShutdown()` / `finishShutdown()`

`finishBuild` accepts a key containing path + attachment generation + build generation.
Before any mutation it proves:

1. the coordinator is started and not shutting down;
2. a session still exists at the path;
3. the attachment generation matches;
4. the current phase is `.building` with the same build generation;
5. the destination still matches;
6. source and destination occupancy revisions still match the snapshot.

Failure of any check discards the completion without republishing, registering claims,
or removing a newer task handle. A stale completion may log one structured
`phase=staleCompletion` diagnostic with typed reason; it must not log per-item payloads.

### 4.4 Claims are derived from live session phase

Remove `claimsBySource`. `ledgerClaims(for:excluding:)` unions claims from sessions whose
current phase is `.ready` or `.executing` and whose current destination matches.

This establishes one release rule: a claim exists exactly while its owning session phase
contains it. Detach removes the session. Terminal execution replaces `.executing` with a
terminal phase that contains no claims. Superseding a ready plan replaces its context in
one transition. There is no separate cleanup call that can be forgotten.

### 4.5 Detach, reattach, and shutdown

Detach behavior:

1. Remove the session from `sourceSessions` synchronously so presentation and claims
   disappear immediately.
2. Cancel its build task if present.
3. If executing, ask its executor to cancel. The durable journal remains the recovery
   authority for already-published or interrupted work.
4. Preserve device-identity destination persistence outside the session; discard session
   preferences and transient timing.
5. Late build/progress/execution completions fail their session-key check and do nothing.

Reattach at the same path always creates a new attachment generation. An old completion
cannot become current merely because path and occupancy happen to match again.

Shutdown behavior:

1. Set `isShuttingDown` before cancellation.
2. Finish public continuations once.
3. Snapshot and cancel every owned build/execution task and executor.
4. Clear sessions so claims and presentations die synchronously.
5. Await owned task completion without holding an assumption that callbacks will mutate
   state; callbacks reject because shutdown/session identity no longer matches.
6. Return only after task ownership is settled. No task may publish after shutdown returns.

## 5. Delivery stages

Each stage uses a dedicated worktree and PR. `main` must be green before the next stage
merges. Within a stage, write the failing fixture/test first, confirm it fails for the
intended reason, implement the correction, and then run the complete gate. Do not merge a
red test-only intermediate commit to `main`.

### Stage 0 — Preserve or retire hidden WIP before source changes

Scope: local audit; no product behavior.

Steps:

1. Read `.cursor/plans/remove_dead_test-only_code_0d84b101.plan.md` completely.
2. For each pending todo, prove one of:
   - implemented on current `main`, with source/test reference;
   - superseded by a current requirement/ADR;
   - still valuable and explicitly incorporated into this plan's relevant stage.
3. If no unique work remains, move the file to Trash (recoverable) rather than deleting
   blindly. If unique work remains, add it to this plan before removing the hidden file.
4. Confirm `/Users/example/Development/Otos-worktrees` contains no unregistered
   repository and `git worktree list` names only intentional worktrees.
5. Record the disposition on the first implementation PR.

Done when: there is no ignored plan with pending todos and no unregistered current Otos
worktree. Normal ignored build/log/profile artifacts are not WIP.

### Stage 1 — Restore trustworthy requirements enforcement (H1, H2)

Primary files:

- `script/requirements-authority-check.sh`
- `script/verify.sh`
- `docs/requirements.md`
- focused script fixtures created under a temporary directory by the self-test

Implementation:

1. Refactor the script into `check_root <root>` plus `self_test`; the default command runs
   the real repository check.
2. Parse table rows with portable `awk`, not BSD/GNU-specific `sed` alternation.
3. Require exactly seven pipe-delimited fields for each requirement body row (leading and
   trailing empty fields included). Document that literal pipes inside cells must be
   escaped.
4. Extract and trim ID, requirement, acceptance, implemented-in, and tested-by cells from
   fixed columns. Reject an unrecognized requirement ID instead of silently skipping it.
5. Keep path-existence validation, but label it traceability only.
6. Define the verification-cell grammar:
   - executable proof: backticked `path#symbol` entries;
   - honest debt: `unverified: <specific clause and reason>`;
   - `manual:` is not accepted because user action cannot be a DoD prerequisite.
7. For Swift proofs, require the named `func` in the cited file. For script proofs, require
   a named self-test case. Do not claim that symbol existence proves semantics.
8. Add self-test fixtures that separately seed and observe failure for:
   - malformed column count;
   - missing/invalid ID;
   - overlong requirement and acceptance cells;
   - forbidden implementation token;
   - missing implementation/test path;
   - missing Swift test symbol;
   - `manual:` verification;
   - invalid verification grammar;
   - one valid named proof;
   - one valid bounded `unverified:` entry.
9. Make `script/verify.sh` run both the real check and its self-test.
10. Repair ARC-047's duplicated acceptance cell. Retain only proofs that exercise the
    behavior they name; mark coordinator ledger/detach clauses `unverified` until Stage 4.

Do not attempt to normalize all legacy rows in this stage. The blocker is to make the
gate execute honestly and make ARC-047 truthful. Stage 6 removes the allowlist completely.

Tests/evidence:

- `script/requirements-authority-check.sh self-test`
- Temporarily seed each violation in the self-test fixture and show nonzero status.
- `script/verify.sh`
- `git diff --check`

Done when: all 96 IDs are actually parsed; ARC-047 has the canonical table shape; a seeded
extra cell and missing test symbol fail; the real repository check passes without
misrepresenting ledger coverage.

### Stage 2 — Make the preferences domain one explicit value (H7)

Primary files:

- new `Otos/Models/PreferencesDomain.swift` (or `Support` if repository naming supports it)
- `Otos/OtosApp.swift`
- `Otos/ViewModels/CatalogWindowViewModel.swift`
- `Otos/ViewModels/CatalogWindowViewModelMediaOperations.swift`
- `Otos/Services/MediaOperationCoordinator.swift`
- `Otos/Services/LibraryReorganizationRunner.swift`
- `OtosTests/TemporaryDefaults.swift`
- all ViewModel/media-operation/reorganization construction sites

Target API:

```swift
nonisolated enum PreferencesDomain: Equatable, Sendable {
    case standard
    case suite(String)

    func makeDefaults() -> UserDefaults { ... }
}
```

Implementation:

1. `CatalogWindowViewModel` accepts one required `PreferencesDomain`; remove the separate
   `sending UserDefaults` and optional suite-name inputs.
2. The MainActor creates its own `UserDefaults` instance from that domain for synchronous
   UI preferences.
3. Media-operation/reorganization actors receive the same Sendable domain value and each
   constructs its own actor-owned `UserDefaults` instance.
4. `OtosApp` passes `.standard` explicitly.
5. `TemporaryDefaults` creates a unique suite, exposes `.suite(suiteName)`, and cleans that
   suite. Every test passes this domain; there is no default parameter that can select
   production accidentally.
6. Keep `UserDefaults` references inside their isolation owner. Do not restore
   `nonisolated(unsafe)` or an unchecked Sendable conformance.
7. Add a test that starts a ViewModel/media coordinator with a temporary domain, attaches
   a source, changes its destination/preferences, reconstructs the actor from the same
   domain, and observes the persisted test value.
8. In the same test, use a distinct control suite and prove it is unchanged. The existing
   production-data before/after gate remains the system-level proof for `.standard`.

Documentation:

- Update ARC-042/ARC-047/ADR 0020 only if their current wording changes.
- Update architecture ownership wording if it currently implies a shared reference.

Done when: the compiler requires every production/test construction site to choose a
domain; no test can omit the choice; full tests and `production-data-untouched` pass.

### Stage 3 — Add a controllable real plan-building boundary

This is enabling architecture for Stage 4, not a test hook.

Primary files:

- new `Otos/Services/ImportPlanBuilder.swift`
- `Otos/Services/MediaOperationCoordinator.swift`
- new focused test support in `OtosTests/MediaOperationCoordinatorTestSupport.swift`

Design:

1. Move namespace enumeration + pure planner invocation + timing result out of the
   coordinator's private static helper into a concrete `ImportPlanBuilder` value.
2. The live builder remains `Sendable`, performs the work off the coordinator actor, and
   returns the plan, namespace counts, and timing fields needed by current diagnostics.
3. The coordinator initializer accepts a builder with a live default. This is the real
   substitution boundary between lifecycle ownership and expensive plan construction.
4. Test support provides a controlled builder actor that:
   - records each request key;
   - suspends a selected request on a continuation;
   - resumes it with a real planner result;
   - records cancellation without assuming cancellation ends the continuation.
5. Preserve current signpost/log names and keep logging in the owner that has the complete
   operation context. Do not expose filesystem paths or plan payloads to test-only APIs.

Tests:

- Live builder produces the same output as direct namespace enumeration + planner for a
  fixed fixture.
- Controlled builder can hold and resume two independent source builds.
- Cancelling a controlled request is observable but does not automatically resume it,
  reproducing the cancellation-insensitive boundary needed for Stage 4.

Done when: production behavior is unchanged; coordinator tests can deterministically
suspend the exact await boundary where stale completions occur; no fixed sleep is needed
to arrange that race.

### Stage 4 — Replace parallel coordinator state with SourceSession (H3–H6)

Primary files:

- `Otos/Services/MediaOperationCoordinator.swift`
- `Otos/Models/MediaOperationModels.swift` only for public presentation values
- `OtosTests/MediaOperationCoordinatorTests.swift`
- `OtosTests/MediaOperationCoordinatorTestSupport.swift`
- remove misleading lifecycle cases from `MediaTransferPlannerTests.swift`

Implementation order:

1. Add controlled failing tests for each scenario below and confirm each fails against
   the old coordinator for the intended reason.
2. Introduce typed attachment/build keys and `SourceSession`/`SourcePhase`.
3. Move one lifecycle path at a time: attach/refresh, build, ready/claims, import queue,
   execution, detach, shutdown.
4. Derive public presentations and ledger claims from sessions.
5. Delete the superseded dictionaries/sets only after all call sites use the session.
   Do not leave a compatibility mirror.
6. Make task completion cleanup conditional on the matching build/execution key; an old
   task can never remove a new handle.
7. Ensure progress callbacks also carry execution identity and cannot repaint a detached
   or superseded session.
8. Preserve destination persistence by device identity and last-used destination outside
   the transient session.
9. Preserve execution-scoped destination rebuild suppression. Compute executing
   destinations from session phases, retain dirty state in the relevant sessions, and
   flush once after the last matching execution ends.
10. Preserve attach-to-ready diagnostics, now stored in the one session.

Required owner-level tests (assert public behavior, not private dictionaries):

- **Detach during suspended build:** detach, resume the old builder, and assert no
  presentation, ready plan, or later publication returns for that source.
- **Rapid same-path reattach:** suspend build A, detach, reattach/build B, resume A, and
  assert only B's generation/plan can become Ready.
- **Old completion cannot clear new task:** after the above, detach B while it is still
  suspended and assert B is cancelled and cannot publish.
- **Claims release on detach:** source A reaches Ready and claims the base name; detach A;
  source B into the same destination receives the base name, not a suffix.
- **Claims release on cancel:** execute/cancel A to a controlled terminal result; B can
  claim any unpublished name after A's phase dies, while published names remain occupied
  through live namespace truth.
- **Claims release on failure:** a controlled failed execution kills unpublished claims;
  B can use them.
- **Current-ledger conflict:** suspend A and B after the same namespace snapshot; publish
  A; resume B; B loses the publish-time conflict check, rebuilds, and reaches Ready with a
  disjoint name without evicting A.
- **Settlement conversion:** after A publishes, its claim dies and B still advances
  because the real destination file is observed.
- **Detach during execution:** the executor receives cancel; late progress/result does not
  recreate presentation or auto-eject; the durable journal is left in a recoverable state.
- **Shutdown:** suspend builds and an execution, call shutdown, release the controlled
  operations, and assert shutdown returns with no later stream values or owned tasks.
- **Repeated Import:** two rapid intents still start exactly one batch.
- **Metadata wake:** retain the real catalog-change test, replacing polling sleeps with a
  recorder/continuation.
- **Zero-copy without delete:** queue through the coordinator and assert it remains Ready
  without invoking the executor.
- **Zero-copy with delete:** queue through the coordinator and assert the executor runs the
  journaled deletion path.

Delete or rename lower-layer tests whose old names claim these lifecycle guarantees. Pure
planner tests remain for naming decisions and `additionalReserved` behavior, with names
that say exactly that.

Documentation in the same PR:

- Update ARC-047 with the exact coordinator test symbols.
- Rewrite ADR 0021's verification-debt sections as current truth; remove references to
  deleted plan 0078.
- Update `docs/architecture.md` to describe `SourceSession`, typed stale-completion
  rejection, and first-added available destination wording.
- Update file-guide comments in the coordinator; remove history/comparison prose.

Instrumentation evidence:

- Capture tests/logs showing one `staleCompletion` rejection for the forced race.
- Preserve `suppressRebuild`/`flushRebuild` evidence for concurrent execution.
- No performance optimization is part of this stage; compare plan enumeration timing only
  to prove the boundary did not move work onto MainActor.

Done when: every ADR 0021 R1–R5 invariant has a coordinator-level adversarial test; stale
work cannot mutate or clear newer ownership; parallel source state has one owner value;
no lifecycle test name overstates its exercised layer.

### Stage 5 — Make coordinator tests deterministic (H10)

Primary files:

- `OtosTests/MediaOperationCoordinatorTests.swift`
- `OtosTests/AsyncTestSupport.swift`
- affected adjacent materialization/projection tests only when a shared helper is improved

Steps:

1. Classify every `Task.sleep` in `MediaOperationCoordinatorTests` as:
   - deliberate production-like latency supplied by a fake;
   - bounded polling inside a reusable timeout helper;
   - assertion settle delay.
2. Replace assertion settle delays with `AsyncValueRecorder`, controlled builder/executor
   continuations, or a predicate wait that records the observed transition sequence.
3. Retain a wall-clock timeout only as a deadlock escape, never as the event that makes the
   assertion true.
4. Assert transition sequences where ordering matters (for example Inventory → Planning →
   Ready), not just an allowed set of several terminal states.
5. Review fixed sleeps in directly shared test helpers. Expand beyond the coordinator only
   when the same deterministic primitive removes an actual assertion race; do not perform a
   blanket timing rewrite.

Done when: the coordinator suite contains no unexplained fixed settle sleep and fails with
a useful transition history when an expected state never arrives.

### Stage 6 — Remove the requirements allowlist and reconcile all current truth

This is the full health step. Keeping a permanent 74-of-96 bypass would preserve the same
class of false assurance under a working parser.

Primary files:

- `docs/requirements.md`
- `script/requirements-authority-check.sh`
- tests/scripts needed for truthful proof references
- affected ADRs and `docs/architecture.md` when the registry audit finds drift

Method, row by row:

1. Process all 96 current rows in ID order. Maintain an audit checklist in the PR body, not
   a second repository document.
2. Ask whether each row expresses one owner and one independently testable behavior. If it
   bundles unrelated behavior, retain the original ID for the central rule and create
   suffixed IDs for independent current behaviors. Do not renumber unrelated existing IDs.
3. Keep requirement and acceptance cells concise and observable. Move mechanics/rationale
   to the owning ADR; do not delete required behavior merely to meet a character cap.
4. Verify every Implemented-in path is an actual owner, not a nearby file.
5. For every Tested-by entry, read the test and confirm it exercises the named owner and
   clause. Rename misleading tests or mark the bounded clause `unverified`.
6. Prefer adding a behavioral test or operational script proof when the agent can run it.
   Never add a Swift source-substring test.
7. Remove `manual:` entries. If no agent-owned machine proof is practical, use explicit
   `unverified:` wording with the exact missing proof and remaining risk.
8. Remove the `ALLOWLIST` and its count gate after the last row conforms. There is no
   replacement bypass.
9. Add a final self-test proving a nonconforming new row cannot skip validation.
10. Reconcile any ADR/architecture statement contradicted by the audited implementation.

Done when: zero rows bypass validation; the gate parses and validates every current row;
verification references are honest; no current ADR points to deleted work plans; roadmap
content was not used.

### Stage 7 — Warning and ownership-signal cleanup

The goal is useful signal, not a cosmetically small warning count.

Steps:

1. Group current SwiftLint warnings by rule and owning subsystem.
2. Fix mechanical style warnings in files touched by Stages 2–5.
3. For `file_length`/`type_body_length`, perform a Lens-B ownership review. Split only when
   a real owner or substitution boundary exists; explicitly retain cohesive warnings.
4. Review the final `MediaOperationCoordinator` size after the session model lands. Do not
   split transitions across extensions if doing so hides the state machine.
5. Review `CatalogStore` and `CatalogStorePersistence` only for demonstrated duplicate
   ownership or incorrect boundaries. Size alone does not authorize another extraction.
6. Record remaining warning categories and why they are accepted in the PR DoD. Do not add
   a hard warning threshold forbidden by repository guidance.

Done when: touched code has no avoidable style warnings; every structural warning is either
resolved through a real boundary or deliberately retained for cohesion; no speculative
cache/layer/protocol is introduced.

### Stage 8 — Independent final review and closeout

1. Run a cold two-lens review from `main`, not from implementation intent.
2. Re-run adversarial scenarios: detach/reattach, stale build completion, concurrent claims,
   cancel/failure release, zero-copy delete/no-delete, test-domain isolation, and every
   requirements-gate self-test.
3. Run `script/verify.sh` on the exact merge candidate and again after final merge.
4. Run `script/logs.sh show --last 10m` for any runtime/smoke exercise and attach relevant
   machine-greppable evidence. Profile only if the implementation changed a measured hot
   path; otherwise state why profiling was not warranted.
5. Confirm GitHub remote CI. A billing/quota waiver requires the exact current annotation;
   an old waiver is not reusable evidence.
6. Audit local/remote branches, worktrees, stashes, open PRs/issues, ignored plan files,
   `docs/plans/`, and working-tree state.
7. Post one final DoD report on the final PR and send the same report to the user.
8. Delete this plan in its own doc-only closeout PR only after all implementation PRs have
   merged and the final review has no blocking finding.
9. Merge the closeout PR, fast-forward local `main`, remove all increment worktrees and
   branches, and confirm `origin/main...HEAD` is `0 0`.

Done when: implementation and proof are on `main`; this plan is gone; only intentional
long-lived local artifacts remain; the next increment starts from a clean tree.

## 6. Required PR sequence

| Order | PR | Depends on | Full `script/verify.sh` |
| --- | --- | --- | --- |
| 1 | Requirements parser + self-test + truthful ARC-047 | none | required |
| 2 | Single `PreferencesDomain` value | PR 1 | required |
| 3 | `ImportPlanBuilder` boundary | PR 2 | required |
| 4 | `SourceSession` coordinator lifecycle + adversarial tests + docs | PR 3 | required, plus focused repeated runs |
| 5 | Deterministic coordinator test conversion | PR 4 | required, plus repeated focused suite |
| 6 | Full requirements allowlist removal/current-truth audit | PR 5 | required |
| 7 | Warning/ownership signal cleanup | PR 6 | required |
| 8 | Final review fixes, then plan deletion closeout | all | required after source fixes; doc-only gates for deletion PR, then post-merge full gate evidence from source head remains cited |

Do not combine PRs 1–4 merely to save workflow time. The sequence creates trustworthy
verification before relying on it and establishes the deterministic boundary before the
state-machine rewrite. A stage may be split further if reviewability improves, but no
partial owner migration may land without a committed child plan and an end-to-end green
state.

### Per-stage execution template

For every source stage, the implementer follows this order:

1. From clean, synchronized `main`, create a conventional branch and dedicated worktree.
2. Read the current requirement row, owning ADR, architecture entry, source file guide,
   and existing tests before editing.
3. Add the smallest deterministic failing fixture that reproduces the stage's finding.
4. Run the focused test and record the expected pre-fix failure in the PR description.
5. Implement the complete owner change; do not commit an intermediate compatibility path.
6. Run the focused suite repeatedly when the change is concurrency-sensitive:

   ```sh
   /usr/bin/xcodebuild \
     -project Otos.xcodeproj \
     -scheme Otos \
     -configuration Debug \
     -destination "platform=macOS" \
     -derivedDataPath build/DerivedData \
     test \
     -only-testing:OtosTests/MediaOperationCoordinatorTests
   ```

   Run it at least ten times for Stage 4/5. A loop is diagnostic evidence only; one full
   `script/verify.sh` remains the required repository gate.
7. Run `git diff --check` and `script/verify.sh` with the exit status observed directly.
8. Review the diff against both lenses and the inversion checklist below.
9. Scan the last five PRs for unresolved review comments (source-stage rule), claim and
   resolve any in-scope thread, then open a ready PR.
10. Wait for remote CI/review, fix actionable findings through the same branch, merge,
    fast-forward `main`, remove worktree/branches, and verify a clean `0 0` state.

For a doc-only stage, use `script/ci-text-hygiene.sh check` and
`script/requirements-authority-check.sh` instead of Xcode build/test, as required by
`AGENTS.md`. The source-stage proof it documents must already exist; a doc-only PR may not
invent or upgrade verification claims.

## 7. Review checklist for every implementation PR

Lens A — implementation fidelity:

- Which finding IDs does the diff close?
- Which test failed before the fix, and for exactly what reason?
- Does every touched requirement cite a proof that exercises its owner?
- Can a completion from before an `await` still mutate a replaced owner?
- Can detach, shutdown, cancel, or failure leave a claim/task/presentation alive?
- Does any test read/write `.standard` unintentionally?
- Did any media original or source folder change outside an explicit tested operation?

Lens B — architecture:

- Is there one owner for the question?
- Is state represented once, or mirrored for convenience?
- Does the type system rule out invalid combinations?
- Is a new protocol/abstraction a real substitution boundary used now?
- Did the change add performance machinery without measurement?
- Would a blank-slate implementation choose this structure?

Inversion pass:

- Delete the cancellation check: does identity still prevent stale mutation?
- Delay an old task until after a new same-path session exists: can it win?
- Make the test name false: would the test still pass?
- Add an extra requirements-table cell: does the gate fail?
- Omit a test preferences argument: does compilation fail?
- Remove one claim-release transition: does an owner-level test fail?

## 8. Definition of done for plan 0079

Plan 0079 is complete only when all are true:

- The requirements gate parses all rows and its seeded violations fail.
- `docs/requirements.md` has one valid table shape and no allowlisted rows.
- ARC-047 accurately names owner-level lifecycle proofs.
- ADR 0021 and architecture docs state current truth and cite no deleted plan.
- The coordinator owns one `SourceSession` per attached source.
- Stale build/progress/execution completions cannot mutate a detached, reattached, or
  shut-down session.
- Claims are derived from ready/executing session phases and die exactly with those phases.
- Preferences domain choice is one required Sendable value at every construction site.
- Coordinator race tests are deterministic and contain no unexplained settle sleeps.
- Full local verification passes on final `main`; production-data protection is clean.
- Remote CI is green or has current permitted billing/quota evidence.
- No open review findings remain.
- No hidden pending plan, increment branch, worktree, or stash remains.
- This completed plan has been deleted and cleanup is verified.

## 9. Explicit non-goals

- No new import UX, confirmation, destination policy, media type, or roadmap feature.
- No persistence of reservation claims or generated durable asset/source identity.
- No executor-owned destination naming.
- No broad `CatalogStore` rewrite justified only by file length.
- No cache, worker pool, shared namespace-read deduplication, or performance optimization
  without measurement.
- No weakening of exclusive publication, journal recovery, source-deletion safety, or
  production-data guards to make tests easier.
- No user-operated verification requirement.
