# Spec: Catalog Browser Smell And Review Follow-Up

## Classification

- Work type: Refactor / performance cleanup / regression fix
- Current requirement IDs: FND-002, FND-006, FND-011, FND-014, FND-015,
  FND-024, FND-034, FND-035, FND-038, FND-041, FND-043, FND-044, FND-046,
  FND-063, FND-065, APP-010, APP-013, APP-014
- ADRs: none. This increment preserves the current decisions in ADR 0004,
  ADR 0005, ADR 0006, ADR 0010, ADR 0011, and ADR 0012; it does not create a
  new expensive-to-reverse architecture decision.

## Problem

The user supplied an external code-smell review and asked to follow its
recommendations. The review agreed that the catalog browser architecture is
mostly correct, but identified several low-risk improvements:

- fix a real MainActor O(visible detail count x ordered ID count) scan in the
  AppKit grid bridge
- mechanically split `CatalogProjection` diagnostics and pure window policy from
  the actor's publication machinery
- collapse small non-load-bearing SQL single-root/`IN (...)` duplication
- remove a redundant `MainActor.run` wrapper in visible-detail delivery
- avoid large rewrites such as GRDB `ValueObservation`, projection actor splits,
  query-interface migration, removing `INDEXED BY`, or a SwiftUI-native grid
  rewrite

The required recent-PR review sweep also found two unclaimed actionable PR #37
review threads:

- `PRRT_kwDOS2KR4M6N8zeC`: an older projected state could overwrite a newer
  local ViewModel query descriptor, so a later filter command could be built from
  stale sort/sidebar values.
- `PRRT_kwDOS2KR4M6N8zeD`: toolbar and View menu filter surfaces hid a media kind
  when Store knew the kind but the scope had no concrete format token for it.

Before implementation, repo inspection found:

- `CatalogProjection.swift` is 737 lines and disables `file_length`; about a
  quarter of the file is diagnostics and pure policy rather than publication
  machinery.
- `CatalogStorePersistence.swift` is intentionally raw SQL at the Store edge, but
  `countAssets` and `distinctFilterableTypesQuery` duplicate single-root and
  multi-root query construction where the duplication is not needed for the
  index plan.
- `MediaAssetCollectionViewController.applyStructure` prunes cached tile details
  with `grid.orderedAssetIDs.contains($0.key)` on the MainActor.
- `MediaAssetCollectionViewController.requestVisibleDetails` creates a `Task`
  from a MainActor method and then wraps completion in `await MainActor.run`.
- `docs/onboarding.md` still points readers at `CatalogProjection.swift` as the
  single projection file.
- `CatalogWindowViewModel.applyState` directly assigns the projected descriptor,
  which is correct for ordinary state delivery and removed-library normalization
  but not for stale state arriving after a newer local query intent.
- `CatalogFilterMenu` and `OtosApp` use non-empty format lists as their kind
  availability gate.

## Scope

In scope:

- Add this decision-complete spec.
- Split projection diagnostics types into `CatalogProjectionDiagnostics.swift`.
- Split pure projection/window policy into `CatalogWindowPolicy.swift`.
- Keep `CatalogProjection` as the single actor that owns publication cadence,
  dirty state, subscriptions, descriptor retention, and publication ordering.
- Replace the AppKit detail-prune array membership scan with a Set membership
  check or equivalent no-worse path.
- Remove redundant MainActor wrapping only if Swift concurrency still preserves
  the same actor-safety and stale-completion rejection.
- Collapse `countAssets` and `distinctFilterableTypesQuery` SQL construction only
  where query-plan ownership is not changed.
- Update current docs, comments, and source hygiene tests needed by the split.
- Claim and fix the two unclaimed actionable PR #37 review threads through this
  increment's normal spec, tests, verification, and PR.
- Preserve newer ViewModel query descriptor intents when an older projected state
  is applied, while still accepting Projection's removed-library fallback when it
  matches the current local filter/sort.
- Expose available media-kind filters even when a kind has no concrete format
  token in the current scope.
- Run local verification, runtime logging evidence, recent-PR review-comment
  sweep, PR, remote CI, merge, and cleanup.

Out of scope:

- User-visible browser behavior changes.
- New toolbar, selection, copy, search, preview, import, export, editing, or
  inspector behavior.
- New persistence schema, migrations, indexes, generated columns, or query
  descriptor semantics.
- GRDB `ValueObservation` migration.
- Splitting `CatalogProjection` into multiple actors.
- Query-interface DSL migration.
- Removing `INDEXED BY`.
- SwiftUI-native media grid rewrite.
- Consolidating `CatalogWindowViewModel` task handles into a task group. The
  supplied recommendation called that not-a-smell and not a dedicated refactor.
  The ViewModel touch in this increment is a narrow review-regression fix; it
  does not justify changing the already-tested task ownership model.

## Definition Of Ready

- [x] Goal, change type, scope, and non-goals are explicit.
- [x] Current repo state was inspected and summarized.
- [x] Captured user guidance is explicit enough to record directly: the user
      supplied the external review and said to follow its recommendations.
- [x] Observable requirements and acceptance examples are identified.
- [x] Ownership, side effects, persistence, cancellation, errors, progress,
      privacy, instrumentation, and verification are addressed.
- [x] At least three alternatives are compared below.
- [x] Refactor retirement list and proof plan are defined.
- [x] Performance-sensitive work names the evidence to collect.
- [x] A stale-document and code-comment audit is defined.

## Captured Requirements For User Verification

| ID | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| CBS-001 | Process | Follow the supplied code-smell review's small recommendations and avoid the large rejected rewrites. | Current increment | This spec |
| CBS-002 | Architecture | Keep `CatalogProjection` as one publication actor while moving diagnostics and pure policy to focused non-actor files. | Current | This spec, docs/onboarding.md |
| CBS-003 | Non-functional | AppKit grid structural apply shall not prune visible detail cache with repeated linear membership scans over the full ordered ID array. | Current | This spec, `MediaAssetCollectionView.swift` |
| CBS-004 | Architecture | Persistence cleanup shall not change schema, query descriptor semantics, forced order indexes, or Store ownership. | Current | This spec |
| CBS-005 | Process | The code-smell follow-up shall document smells observed, addressed, accepted, or deferred in the final DoD report. | Current | This spec, PR DoD |
| CBS-006 | Regression | Applying an older projected state shall not roll back a newer local ViewModel query descriptor; the next query intent must be built from the newest local sidebar/sort/filter state. | Current | This spec, `CatalogWindowViewModelQueryIntentTests` |
| CBS-007 | Functional | Toolbar and View menu filter surfaces shall expose an available media kind even when that kind has no concrete format tokens in the current scope. | Current | This spec, `CatalogFilterOptionsTests`, source hygiene |
| CBS-008 | Process | The unclaimed actionable PR #37 review threads shall be claimed, fixed, and replied to with the fixing PR or commit. | Current increment | This spec, GitHub review threads |

## Architectural Alternatives

### Alternative A: Do Nothing Until A Feature Touches These Files

Pros:

- zero regression risk
- no churn in heavily tested catalog browser code

Cons:

- leaves a known MainActor O(n x m) scan in the grid bridge
- leaves `CatalogProjection` with `file_length` disabled and mixed diagnostics,
  policy, and machinery
- makes the next browser feature land on a denser base

Failure modes:

- future changes pile more policy into `CatalogProjection`
- a large library scan pays unnecessary MainActor comparison work during
  structural applies

Rejected because the user explicitly asked to follow the recommendations and the
small fixes are low risk.

### Alternative B: Mechanical Split And Targeted Cleanup

Pros:

- fixes the known AppKit hot-path inefficiency
- removes projection `file_length` pressure without changing ownership
- keeps raw SQL and `INDEXED BY` choices that current ADRs/tests already justify
- keeps behavior, schema, and user-visible surface unchanged

Cons:

- touches multiple files for a behavior-preserving refactor
- requires careful stale-doc and source-hygiene updates

Failure modes:

- a supposedly mechanical split accidentally changes access control or test
  visibility
- removing `MainActor.run` could expose actor-isolation assumptions if the task is
  not actually MainActor-inherited

Selected.

### Alternative C: Replace Publication Machinery With GRDB Observation

Pros:

- idiomatic database observation API
- might delete the hand-rolled dirty/cadence loop

Cons:

- conflicts with the current Store-owned query boundary
- loses the deliberate immediate-intent versus one-second-background cadence
  unless throttling is reintroduced
- broad behavior and diagnostics risk for no current measured need

Failure modes:

- bulk scan commits rebuild full window state too often
- view-model or database observation ownership becomes a second projection path

Rejected.

### Alternative D: Split Projection Into Multiple Actors

Pros:

- smaller actor files
- theoretical separation between publication and building

Cons:

- reintroduces cross-actor ordering and stale-completion problems solved by the
  current single actor
- adds architecture complexity without a current bug or measurement

Failure modes:

- descriptor normalization, dirty marking, and publication completion race across
  actors

Rejected.

## Selected Approach

Select Alternative B.

This is the simplest correct approach for the observed smells: keep the proven
owner graph intact, move pure helper material out of the actor file, and remove a
small measured-risk MainActor algorithmic inefficiency. The claimed review-thread
fixes stay at their current owners: ViewModel local control state for stale query
intent protection, and `CatalogFilterOptions` for kind availability. No persistence
or product decision is redesigned.

## Interfaces, Ownership, And Data Flow

- `CatalogProjection` remains an actor and owns:
  - Store subscription and continuation lifecycle
  - dirty/publishing/immediate-publication state
  - descriptor mutation and resolved-selection retention across awaits
  - Store reads and window-state publication
- `CatalogProjectionDiagnostics` owns diagnostics value types and JSONL field
  construction for projection publications.
- `CatalogWindowPolicy` owns pure functions for sorting libraries, resolving
  descriptors, scoping IDs, titles, and empty-state meaning.
- `CatalogStorePersistence` remains the single SQLite edge; query construction
  cleanup is local and uses the same columns, indexes, and arguments.
- `CatalogWindowViewModel` remains a MainActor adapter. It applies projected
  descriptor state only when it is not stale relative to newer local query intent
  state, or when Projection is resolving the currently selected removed library
  to All Media with the same filter/sort.
- `CatalogFilterOptions.availableKinds` is the single model-level answer for
  which kind rows appear in toolbar and View menu filters.
- `MediaAssetCollectionViewController` remains the only AppKit grid bridge; it
  prunes cached visible details using a membership set and still requests visible
  details by ID through the Store-backed detail reader.

Persistence effects:

- None. No schema, migration, index, generated column, or stored row changes.

UI effects:

- Mostly preservation. Selection, copy, sorting, filtering, scroll reset, scroll
  preservation, and visible-detail refresh semantics remain current. The only
  user-visible repair is that a known kind with no format token now appears as a
  kind-level filter instead of disappearing from filter menus.

Privacy and media-originals effects:

- None. No original files are read beyond existing visible detail facts, modified,
  moved, deleted, or sidecar-written.

## Concurrency And Actor Ownership

- UI-facing AppKit code remains MainActor-bound by the controller boundary.
- `CatalogProjection` remains off-MainActor publication owner.
- Projection diagnostics and policy helpers are synchronous value/pure helpers
  called from the actor; they introduce no tasks and no shared mutable state.
- `CatalogWindowViewModel` still forwards query intents through its newest-value
  stream. Stale projected states update rendered state but do not overwrite a
  newer local query descriptor used to build the next intent.
- The visible-detail query task keeps the existing stale-generation rejection and
  cancellation check. If removing `MainActor.run` fails strict concurrency, keep
  the explicit hop rather than weakening actor isolation.
- No new detached tasks, unchecked sendability, actor splits, caches, or
  buffering semantics are introduced.

## Instrumentation And Performance Plan

The AppKit detail-prune change is a MainActor rendering-path cleanup, so the
increment must include:

- local `script/verify.sh`
- targeted tests for projection/source hygiene and media collection behavior
- unified-log evidence from launching the app with repo tooling, naming the UI
  and projection signposts observed
- a stale-search audit confirming `CatalogProjection.swift` no longer needs the
  `file_length` disable and docs mention the split reading order

No Instruments trace is required unless local verification or logs reveal a
runtime stall; the change removes a known O(n x m) path but does not introduce a
new performance design.

## Test And Acceptance Criteria

- `CatalogProjection` tests continue to pass after the diagnostics/policy split.
- Source hygiene proves `CatalogProjection.swift` no longer disables
  `file_length`.
- Source hygiene proves the AppKit tile detail prune does not use
  `grid.orderedAssetIDs.contains` inside the dictionary filter closure.
- Media grid selection/apply tests continue to pass.
- Query-plan tests continue to pass, proving SQL cleanup did not change locked
  order query behavior.
- ViewModel regression coverage proves a stale projected state cannot roll back a
  newer local sort before a subsequent filter intent is submitted.
- Filter option coverage proves a media kind with no formats still appears in
  available kind ordering, and source hygiene proves both toolbar and View menu
  use that model answer.
- `script/verify.sh` passes locally.
- Remote CI passes or reports an explicit account/quota blocker.

## Refactor Retirement List And Proof Plan

Retire:

- `// swiftlint:disable file_length` from `CatalogProjection.swift`
- projection diagnostics structs living inside the actor file
- pure projection policy functions living inside the actor file
- MainActor repeated linear `grid.orderedAssetIDs.contains` detail-prune scan
- redundant single-root branches in `countAssets` and
  `distinctFilterableTypesQuery`
- redundant `MainActor.run` wrapper if strict concurrency permits
- format-list emptiness as the kind availability gate in toolbar and View menus
- unconditional ViewModel local descriptor replacement by stale projected state

Proof:

- compiler and full test suite pass
- source hygiene checks cover the retired source shapes
- stale-doc search covers old reading-order claims and file-length disables

## Living Documentation And Comment Audit

Update:

- `docs/index.md` with this spec
- `docs/onboarding.md` reading order for `CatalogProjection`,
  `CatalogProjectionDiagnostics`, and `CatalogWindowPolicy`
- affected file guides/comments in projection and AppKit bridge files
- `docs/requirements.md` evidence links only where current requirement evidence
  points at moved source

Audit:

- ADRs/specs/process docs remain accurate because the ownership decisions do not
  change.
- No planning document is used except the user-supplied attachment captured in
  this spec.
- Delete or rewrite comments that describe helper locations incorrectly.

## Code-Smell Review

Observed:

- Large-file pressure and mixed responsibility in `CatalogProjection`.
- MainActor O(n x m) pruning work in the AppKit grid bridge.
- Small SQL branch duplication in persistence.
- Redundant actor-hop noise in visible-detail query completion.
- Stale projected-state overwrite of newer ViewModel query intent state.
- Kind availability conflated with format-token availability in filter menus.

Addressed:

- All observed items above are addressed.

Accepted or deferred:

- `CatalogStorePersistence.swift` remains a large raw-SQL file because current
  ADRs require one Store-owned SQLite edge and raw SQL is needed for locked query
  plans and `UPDATE ... RETURNING`.
- `CatalogWindowViewModel` task-handle consolidation is deferred until the
  ViewModel has a behavior or ownership reason to change its task topology. The
  narrow stale-state fix touched ViewModel intentionally without broadening into
  unrelated task-lifecycle refactor.
- Full ID materialization per publication remains accepted until
  `orderQueryMs`, structural apply, or runtime logs prove it is insufficient.
