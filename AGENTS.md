# Otos Agent Instructions

Otos is a native macOS Lightroom-style application. The user's filesystem is the
single source of truth for what media exists and where it lives. Otos overlays
organization, metadata, previews, and editing intent on top of user-owned media
that stays on disk wherever the user chose to keep it, including cloud-synced
folders. Originals are read-only, and Otos never takes the user's media hostage:
it never relocates originals into an opaque app-owned library and never writes
into the user's media folders.

## Non-Negotiable Principles

- Treat this repository as a blank-slate architecture.
- Do not add compatibility shims. If a structure is wrong, replace it with the
  right structure.
- Do not use effort as a decision criterion. Choose the correct architecture,
  even when it requires a larger refactor.
- Keep the app as simple as possible. Simplicity is a product and architecture
  requirement, not a shortcut. Prefer the smallest correct model, owner, schema,
  state flow, and UI that satisfies verified requirements.
- Performance comes after correctness, simplicity, and clear ownership. Do not
  introduce caches, pooling, background pipelines, generalized abstractions,
  split schemas, or other performance-oriented complexity for anticipated scale
  before requirements or evidence prove the simple path is insufficient.
- Do not patch around bad boundaries, stale abstractions, or accidental
  complexity. Remove the wrong abstraction and rebuild the affected path cleanly.
- Do not guess. Inspect the repo, read the relevant APIs, and verify claims with
  code, docs, tests, profiling, or runtime evidence.
- Do not fabricate user-visible or domain facts. Unknown dates, paths, provider
  state, progress, counts, diagnostics, and capabilities must remain unknown or
  explicitly qualified until proven.
- One user action has one implementation path. Buttons, menus, keyboard
  shortcuts, gestures, automation hooks, and tests should call the same owner
  intent instead of parallel behavior paths.
- The filesystem is the single source of truth. The catalog and every overlay
  Otos stores are a subordinate, rebuildable projection that always defers to the
  filesystem; when they disagree, the filesystem wins and the catalog reconciles.
- Otos never takes media hostage. There is no opaque app-owned media vault, and
  Otos never writes into the user's media folders, including no sidecar files. The
  catalog itself may be made exportable if portability is ever needed.
- Otos changes the user's files only through explicit, opt-in, user-initiated
  actions. The default is that nothing on disk changes. The user is allowed to keep
  their own mess; convenience features such as deduplication, renaming, or
  reorganization are opt-in and operate on the filesystem, never on a hidden copy.
- Overlay has one lifecycle. Every overlay Otos holds for an item, whether derived
  by Otos or authored by the user, is kept for as long as that item exists and is
  purged in full only when the item is proven deleted. A temporarily missing
  original is never treated as a deletion. Asset identity is the filesystem path;
  Otos does not invent durable IDs, content fingerprints, or sidecars to track
  files.

## Engineering Philosophy: Measure Before Optimizing

Follow Rob Pike's 5 Rules of Programming. They are binding guidance for how Otos is
built, not trivia:

1. You can't tell where a program is going to spend its time. Bottlenecks occur in
   surprising places, so don't try to second guess and put in a speed hack until
   you've proven that's where the bottleneck is.
2. Measure. Don't tune for speed until you've measured, and even then don't unless
   one part of the code overwhelms the rest.
3. Fancy algorithms are slow when n is small, and n is usually small. Fancy
   algorithms have big constants. Until you know that n is frequently going to be
   big, don't get fancy. (Even if n does get big, use Rule 2 first.)
4. Fancy algorithms are buggier than simple ones, and they're much harder to
   implement. Use simple algorithms as well as simple data structures.
5. Data dominates. If you've chosen the right data structures and organized things
   well, the algorithms will almost always be self-evident. Data structures, not
   algorithms, are central to programming.

Rules 1 and 2 restate Tony Hoare's maxim that premature optimization is the root of
all evil. Ken Thompson rephrased rules 3 and 4 as "when in doubt, use brute force."
Rules 3 and 4 are KISS. Rule 5 was stated earlier by Fred Brooks in The Mythical
Man-Month and is often shortened to "write stupid code that uses smart objects."

In Otos this means: do not add caches, pools, pipelines, fancy algorithms, split
schemas, or scale machinery for anticipated load. Choose the simplest correct data
structures and owners, ship them, and let instrumentation prove where a real
bottleneck is before optimizing it. These rules are echoed from the process docs;
this section is their canonical statement.

## Platform And Product Baseline

- Target the latest macOS and Xcode beta configured for this repo. The initial
  baseline is Xcode 27 beta with macOS deployment target 27.0.
- Prefer Apple-native technologies: Swift, SwiftUI, Image I/O, AVFoundation,
  Core Image, OSLog, Instruments, and filesystem APIs.
  Prefer SwiftUI for UI implementation. Use AppKit only when SwiftUI cannot
  provide the required capability or cannot meet verified responsiveness or
  performance requirements.
- Third-party dependencies are allowed only when the spec proves they are the
  best architecture. Add alternatives and tradeoffs before adding one.
- Otos app data, including the catalog and all overlay Otos derives or the user
  authors, lives in Application Support and is treated as backed up. Overlay is
  held for as long as its originating item exists; there is no cache eviction or
  preview pruning to reclaim space. Overlay for an item is purged in full only when
  that item is proven deleted, that is, absent from a reachable, fully enumerated
  root. Overlay is never purged when an original is merely temporarily missing
  (ejected drive, offline network or cloud volume, unreachable root, or a dataless
  cloud placeholder that still enumerates). A user-excluded selective-sync subtree
  inside a reachable root enumerates without its paths, so reconciliation cannot yet
  tell it apart from a deletion and will purge it; preserving that case is a forward
  invariant to satisfy before user-authored overlay ships, not a current guarantee.
  See `docs/adr/0008-filesystem-source-of-truth-and-overlay-lifecycle.md`.
- Most user media lives in cloud-synced folders. Cloud files may be dataless
  placeholders that still appear in directory enumeration: their filesystem facts
  (name, size, dates, type) are readable without downloading them, but reading their
  bytes forces materialization. Media metadata (EXIF and similar) requires reading
  bytes; filesystem facts do not. Byte-reading work must never *accidentally*
  materialize a dataless file by faulting on a read: it checks the
  `FileMaterialization` detector (the `SF_DATALESS` kernel flag, the only viable bulk
  signal) immediately before any byte read. Beyond that gate, deliberate, non-blocking
  background materialization is permitted for enrichment, up to and including eagerly
  materializing the whole media library: an owner may download a file it has chosen to
  enrich through the non-blocking ubiquitous trigger and await `SF_DATALESS` off-thread,
  never blocking a worker on a read-fault. Otos cannot reclaim downloaded bytes (a
  consumer app cannot evict another provider's files), so the local disk growth from
  eager materialization is a real, unreclaimable, deliberately accepted cost of complete
  enrichment coverage. Materialization status is transient and is never persisted. The
  current catalog/scanner reads only filesystem facts and materializes nothing; the
  `EnrichmentCoordinator` is the byte-reading enrichment owner that materializes. The
  eager-enrichment choice and where the derived products are stored are owned by ADR
  0009. See
  `docs/adr/0008-filesystem-source-of-truth-and-overlay-lifecycle.md`,
  `docs/adr/0009-enrichment-storage-and-staleness.md`, and
  `docs/specs/0021-cloud-materialization-triggering-and-eviction-poc.md`.
- Otos is an image/video product. Never add audio-specific playback, metadata,
  thumbnails, icons, classification, or workflows. This product boundary does
  not imply that the current catalog already filters unsupported files at scan
  time; only implemented eligibility rules may make that claim.
- Otos is unsandboxed. Design file access around user-selected media roots and
  normal filesystem paths. Do not add App Sandbox, security-scoped bookmarks,
  bookmark schema, bookmark lifecycles, or sandbox-driven file access flows.
- Otos has exactly one main window. This is a permanent product and architecture
  invariant, not a roadmap item, candidate future change, or open design
  question. Use a singleton SwiftUI `Window` for the main window, do not use
  `WindowGroup` for the main window, and do not design, document, ask about,
  defer, leave seams for, or propose multiple main windows.

## Spec-Driven Workflow

Every meaningful increment starts with a spec in `docs/specs/` and any needed
ADR in `docs/adr/`. The spec must be decision-complete before implementation.

Classify the work before drafting the spec:

- Feature: new user-facing or system capability.
- Refactor: ownership, boundary, naming, or structural change.
- Bug fix: correction of an observed or reproducible failure.
- Research: investigation with written conclusions before implementation.
- Process/tooling: workflow, CI, scripts, or documentation guardrails.

Definition of Ready

- Goal, change type, scope, and non-goals are explicit.
- Current repo state was inspected and summarized.
- Observable requirements and acceptance examples are identified.
- Captured user guidance has been written back to the user in detail for
  verification, or the spec states why the guidance is already explicit enough to
  record directly.
- Ownership, side effects, persistence, cancellation, errors, progress, privacy,
  instrumentation, and verification are addressed.
- At least three architectural alternatives are compared with pros, cons, and
  failure modes.
- The simplest correct alternative is identified, and any additional complexity
  is justified by verified requirements, measurements, or explicit user
  direction.
- ADRs include a MECE decision scope: what the ADR owns, what it references but
  does not own, and which adjacent decisions require separate ADRs or specs.
- Refactors include a retirement list and proof plan for old names, files,
  construction paths, tests, fixtures, docs, logs, accessibility identifiers, and
  persistence/schema paths.
- Performance-sensitive work names the jank/log/profile evidence that will be
  collected.

A spec must include:

- Problem statement and user-facing goal.
- In-scope and out-of-scope work.
- Current repo state discovered through inspection.
- Captured requirements for user verification, split into precise functional,
  non-functional, process, architecture, tooling, privacy, or regression items.
- Linked current requirement IDs from `docs/requirements.md`, if they already
  exist.
- Separate future ideas or unimplemented requirement candidates outside
  `docs/requirements.md`.
- At least three architectural alternatives with pros, cons, and failure modes.
- The selected approach and why it is right for the product, not why it is easy.
- Why the selected approach is the simplest correct approach, or what evidence
  justifies any extra complexity.
- Interfaces, ownership boundaries, data flow, and persistence effects.
- Concurrency and actor ownership.
- Instrumentation and profiling plan.
- Test and acceptance criteria.
- Code-smell review for the target area.

An ADR is required for:

- Persistence or catalog data model choices.
- Filesystem access policy.
- Thumbnail, preview, metadata, import, export, or render pipeline design.
- Any reusable architecture boundary, dependency, or module split.
- Any decision that would be expensive to reverse.

Each ADR must be mutually exclusive and collectively clear with adjacent
decisions. It must name the decision area it owns, name related decisions it
intentionally does not own, and avoid deciding future architecture through
placeholder fields, speculative hooks, or broad wording.

Do not implement from a vague task. First convert it into a decision-complete
spec, present to the user for feedback, and only then implement.

## Requirement Capture And Authority

`docs/requirements.md` is current-state authority only. It contains implemented
behavior, active process rules, requirements changed by the current increment, and
retired requirements. It must not be used as a backlog, roadmap, idea list, or
home for unimplemented product plans.

Future ideas and unimplemented requirement candidates belong in non-authoritative
planning documents, implementation specs, or ADRs until they are implemented.
Planning and idea documents may contain wild ideas, abandoned options, or concepts
that are never meant to be implemented. Do not use them to guide work unless the
user explicitly asks to use those documents or asks for roadmap/planning input in
the current task.

Do not document unbuilt features as roadmap entries or "TBD" placeholders inside
engineering docs. Forward-looking design takes one of two clearly separated forms.
Conditional architecture states the invariants a feature must honor "if it is ever
built", lives in ADRs, and is allowed because it protects the foundation's
integrity without committing to or scheduling the feature. The roadmap idea
grab-bag in `docs/product/roadmap.md` is a non-authoritative pile of ideas that
never guides work, is consulted only when the user explicitly asks "what else could
we build", and whose items are implemented only after explicit user approval.

Whenever the user gives guidance that affects product direction, app behavior,
architecture, workflow, quality, regression protection, evidence, or future
direction, agents must:

- restate the captured requirements to the user in detail for verification
- split bundled guidance into precise individual requirements
- label each item by type, such as functional, non-functional, process,
  architecture, tooling, privacy, or regression
- separate current implemented requirements from future ideas or candidates
- store captured guidance in the correct repository document during the same
  increment, marking unverified or unimplemented guidance as non-authoritative
  candidate material outside `docs/requirements.md`
- update `docs/requirements.md` only for implemented current behavior, active
  process requirements, changed requirements in the current increment, or retired
  requirements
- ignore roadmap, planning, or idea documents unless the user explicitly asks to
  use them for the current task
- include acceptance examples and verification evidence for current requirements

Regression reports are requirement input. Capture the expected preserved behavior,
the failing or risky condition, and the evidence that proves the regression is
covered.

User examples are requirement input when they carry intent. Treat a phrase such as
"how and when we load a data structure into memory" as an example of broader
guidance unless the user says it is itself the requirement.

## Architecture Standards

- Keep SwiftUI views small and composition-focused. Do not build a monolithic
  `ContentView`.
- Keep SwiftUI views passive. Views render provided state, hold local control
  state when appropriate, bind controls, and call explicit owner intents; they
  must not subscribe to catalog snapshot streams, coordinate projection
  invalidation, call SQLite, or orchestrate scanning.
- Keep domain models, stores, services, views, instrumentation, and support code
  in separate folders as the app grows.
- Prefer direct, concrete designs over speculative flexibility. Add a layer,
  cache, protocol, worker queue, normalized table, or generalized pipeline only
  when it removes current complexity or is required by verified behavior.
- Prefer explicit ownership over ambient global state.
- Keep state at the narrowest correct scope:
  - view-local state with `@State`
  - parent-owned mutable state with `@Binding`
  - app or scene services through explicit dependencies
  - durable preferences with `@AppStorage`
  - auxiliary-scene ephemeral state with `@SceneStorage` when appropriate; do
    not use this as a reason to introduce multiple main windows
- Prefer native macOS UI structure: sidebars, detail panes, inspectors,
  toolbars, commands, menus, keyboard shortcuts, contextual menus, and proper
  settings scenes.
- Do not create iOS-style push navigation for workflows that need persistent
  desktop context.
- Do not hardcode light-only colors or custom sidebar chrome.
- Protocols belong at real substitution boundaries. Do not add a protocol only
  to make code feel abstract.
- Persistence must have one current owner, explicit schema/version policy, and
  safe handling for unsupported or future schemas. Rebuildable cache state is
  overlay state, not a second source of media truth.
- Catalog UI state follows the single-window ownership split: `CatalogStore`
  owns runtime catalog truth and emits cheap change notifications,
  `CatalogProjection` owns 10 Hz coalesced `CatalogWindowState` publication plus
  all sorting, filtering, unknown/unavailable hiding, empty-state selection, and
  selected-scope derivation off the MainActor, and `CatalogWindowViewModel` owns
  only final SwiftUI-visible state assignment, newest-value sidebar selection
  delivery, lossless serial add/remove delivery, weak projected-state
  consumption, named task lifetimes, and scalar stall correlation.
- Architecture-boundary files should include explanatory file guides and focused
  comments that let a Swift newcomer follow how the current mechanics work and
  why the boundary exists. Architecture, concurrency, persistence, diagnostics,
  and AppKit-boundary files require substantial file guides plus focused comments
  for non-obvious actor isolation, task ownership, cancellation, persistence,
  coalesced publication, cache validation, availability preservation, and view
  passivity. Do not merely narrate syntax. Avoid changelog-style comments,
  increment-history comments, comparisons with recently removed code, and
  repeated comments for product invariants already documented in requirements or
  ADRs.

## Living Documentation

ADRs, specs, requirements, process docs, the onboarding walkthrough
(`docs/onboarding.md`), code comments, and documentation
indexes describe current reality. They are not append-only historical records;
Git history owns history. Whenever architecture, behavior, workflow, naming, or
instrumentation changes, edit every affected current document and comment or
delete it when its decision no longer has a current purpose. Do not leave stale
claims, superseded alternatives presented as current, obsolete backlinks, or
comments that explain a retired implementation.

Non-authoritative planning documents are the only exception. They may contain
future ideas or abandoned options, but they must be visibly labeled
non-authoritative and must never claim to describe the current implementation.

Every architecture or behavior increment must include:

- a repository-wide stale-document audit covering ADRs, specs, requirements,
  process docs, indexes, templates, scripts, and backlinks
- a code-comment accuracy audit covering file guides and focused comments in
  every affected architecture boundary
- deletion of documents or comments that no longer have a current purpose

## Swift And Concurrency

- Use Swift 6 language mode with strict concurrency.
- Keep `SWIFT_APPROACHABLE_CONCURRENCY = YES`.
- Keep UI-facing app code main-actor isolated by default.
- Every feature spec must name actor ownership:
  - main-actor UI state
  - background actors or services
  - `Sendable` boundaries
  - cancellation behavior
  - where work intentionally leaves the main actor
- Do not do media scanning, metadata reads, image decoding, thumbnail generation,
  database work, filesystem traversal, or export work on the main actor.
- SwiftUI `.task` may inherit main-actor isolation. Treat synchronous work inside
  `.task` as main-thread work unless the implementation proves otherwise.
- Avoid unstructured `Task` ownership. Long-running work needs an owner, a
  cancellation path, and stale completion rejection or coalesced dirty/in-flight
  handling when applicable.
- Retaining a task handle is not sufficient ownership when the running task
  strongly retains its owner. A long-lived stream consumer must capture its
  owner weakly across indefinite waits and upgrade that reference only for the
  smallest completed-value application scope; do not upgrade before the loop.
- Repeated synchronous UI intents that start asynchronous work must define their
  delivery semantics explicitly: newest-value coalescing, lossless serial
  delivery, or intentional concurrency. Do not combine intents with incompatible
  latency or buffering semantics merely to reduce property count. Constructive
  or destructive commands must not use a dropping buffer without an implemented
  rejection surface.
- When an actor suspends during initialization, persistence, or another stateful
  operation, coalesce duplicate work through one explicit owner and revalidate
  the operation's current typed ownership facts after every await before applying
  results. Prefer existing domain and persistence-instance identity over a
  generated token. Transient callback ownership must not become a durable scan
  ID, scan record, or second source of truth.
- Main-actor work must remain below Apple's 100 ms hang threshold. Scrolling,
  grid, animation, and pointer-interaction paths should be substantially below
  that and define feature-specific budgets in the spec.
- If a change touches jank, responsiveness, concurrency, media I/O, or rendering,
  include profiler or signpost evidence.

## Instrumentation And Performance

Instrumentation is not optional. Every meaningful path must be observable to the
submodule level before the feature is considered complete.

Performance work is evidence-driven and secondary to simple, correct product
behavior. The app must still respect user-facing responsiveness budgets and
MainActor constraints, but agents must not use anticipated scale or theoretical
performance gains to justify complexity before measurement or explicit
requirements call for it.

Use `OSLog.Logger` and `OSSignposter` through the repo instrumentation facade.
Required categories include:

- App
- UI
- FileAccess
- Catalog
- Metadata
- MediaIO
- Thumbnails
- Persistence
- Rendering
- Performance

Every significant operation should emit:

- category and operation name
- start and end signposts for timed spans
- result count or size when safe
- cancellation status
- error outcome without private payloads

For SwiftUI/AppKit responsiveness issues, use Logger/signposts for
high-frequency ViewModel state assignment and AppKit collection receipt,
coalescing, apply, reload, layout, and slow-cell work. Those paths must not spawn
per-update JSONL tasks or retain full catalog state. Keep durable JSONL for
coarse Store/scan boundaries, Projection summaries, availability transitions,
failures, and actual active-app run-loop stalls with scalar context. Use `sample`
or Instruments to prove private Apple framework stacks. Do not pretend app code
can signpost inside SwiftUI or AppKit internals directly.

Log policy:

- info: high-signal operation boundaries and signpost spans
- debug: detailed internal state useful for diagnosis
- error: failures and recovery paths with bounded payloads

Raw media paths and filenames may be logged when they are useful diagnostics for
developer builds or repo verification. Do not log secrets, credentials,
unbounded binary payloads, thumbnails, or full metadata blobs unless a future
requirement explicitly needs that diagnostic surface.

Jank and responsiveness work must follow the repo tooling path:

- Use `script/logs.sh [Category]` to verify live unified logs and signposts.
- Use `script/profile.sh "Animation Hitches" 10s` for hitch investigation.
- Use `script/profile.sh SwiftUI 10s` for SwiftUI invalidation/body work.
- Use `script/profile.sh "Swift Concurrency" 10s` for task/executor issues.
- Use `script/profile.sh "Time Profiler" 10s` for CPU-heavy work.
- Use `script/profile.sh "File Activity" 10s` for filesystem work.

Performance-sensitive PRs must include trace/log artifact paths and a short
summary of worst spans, MainActor stalls, or the exact blocker that prevented
capture. Follow Apple's profile, fix, and verify loop: measure first, make the
change, then remeasure.

## Code Smells

Code smells are indicators, not automatic guilt. When one appears, investigate
whether there is a deeper design problem. Every DoD report and PR must list the
code smells observed during the work, including `None observed` when that is the
truth.

Swift/macOS smell families to watch:

- MainActor gravity: work becomes main-actor isolated because it is convenient.
- SwiftUI body work: scanning, decoding, formatting, sorting, or I/O happens in
  `body`, property getters, or synchronous `.task` setup.
- State duplication: two stores, booleans, caches, or projections can answer the
  same domain question.
- AppKit bridge sprawl: AppKit escapes own workflow instead of a narrow native
  surface SwiftUI cannot provide.
- Unsafe concurrency escape: unchecked `Sendable`, detached tasks, shared
  mutable state, or callbacks cross actor boundaries without a clear owner.
- Stringly typed domain facts: weak `String`, `Int`, or dictionary models hide
  role, units, identity, or authority that should be typed.
- Ambiguous Swift API names: call sites do not make side effects, roles, or
  units clear.
- Test coupling: tests assert implementation details instead of observable
  behavior or public owner boundaries.
- Diagnostic payload sprawl: logs or errors expose secrets, credentials,
  unbounded metadata blobs, thumbnails, or binary payloads without a current
  diagnostic requirement.

## Toolchain

Use full Xcode, not Command Line Tools.

Use Homebrew for developer tools:

```sh
brew bundle
```

Required local checks:

```sh
script/verify.sh
```

## Git, CI, And Pull Requests

- Work on a branch named `codex/<description>` for agent-driven increments.
- Increments should use a dedicated git worktree when starting new
  work. If an existing branch/worktree is already the active increment, keep the
  work there and state that in the PR.
- Never discard user work. Do not remove stale worktrees, branches, or stashes
  unless they are proven to belong to the current increment and are already
  merged or patch-equivalent to `main`.
- Use PRs for review. Do not treat direct commits to `main` as the normal
  integration path.
- Reviews follow `docs/process/code-review.md` for the review criteria, severity
  model, and merge gate. The same criteria apply to agent self-review before a PR
  is opened.
- Each increment handles outstanding PR review comments as part of its work, so
  every prior PR's comments get resolved sooner or later. Before opening the
  increment's PR, scan the last five PRs (merged or open, human or bot reviewer)
  for review comments. For every comment that has not already been claimed:
  - Reply on the thread to claim it, stating the increment will address it.
  - Analyze it properly: decide whether it is a real, actionable, in-scope
    finding, and if so land the fix through the increment's normal owner-intent,
    spec, test, and verification path — even when the comment targets a file the
    increment did not otherwise touch.
  - After fixing, reply again on the same thread describing how it was fixed and
    where, linking the fixing commit or PR.
  - If a finding is not applicable, already resolved, or intentionally deferred,
    reply with that reason instead of silently skipping it.
  Do not open a parallel quick-patch that bypasses the spec, tests, or
  verification, and do not delete or hide a thread to "resolve" it.
- Required remote CI is a fast gate: checkout sanity, workflow YAML parsing,
  text hygiene, script inventory, and macOS lint. Remote CI does not run Xcode 27
  build/test until a runner with Xcode 27 exists.
- Xcode 27 build and test proof is required as local PR evidence through
  `script/verify.sh`.
- This is a private GitHub repository. Remote CI may be waived only when GitHub
  explicitly reports an account billing, spending-limit, or exhausted Actions
  quota blocker that prevents jobs from starting. Paste that evidence in the PR.
- CI may not be waived for test failures, build failures, workflow syntax
  errors, missing tools, lint failures, runner bugs, or unrelated flakiness.
- Local `script/verify.sh` evidence is required even when remote CI quota is
  exhausted.

## Definition Of Done

There is one Definition of Done for each increment. An increment is not done
until the work has landed on `main`, the repo is clean, and the workspace is
ready for the next increment. An open PR can be ready for review or merge, but
it is not done.

Verification is agent-owned. Do not require the user to launch the app, operate
the UI, reproduce an interaction, inspect visuals, or perform any other manual
verification as a condition of DoD, merge, or cleanup. Run every verification
step available to the agent. When a useful check cannot be automated or executed
in the agent environment, record the limitation, the evidence gathered instead,
and the remaining risk, then list that check only as a non-blocking after-DoD
task. Do not wait for the user before completing the increment.

There is exactly one DoD report for an increment. Do not create, post, or send a
review handoff DoD, partial DoD, pre-merge DoD, or "ready for review" DoD. The
first DoD report the user receives must be the final DoD report, and the final
DoD report may only be sent after the entire DoD is complete or after a true
external blocker prevents completion.

The final DoD report must be included in the PR as a final comment and sent to
the user. It must use green and red status emoji for every question, with clear
textual descriptions rather than terse labels. It must answer:

- what was done
- what planned work was not done, if anything
- which design decisions were made
- which requirements, specs, ADRs, and docs changed
- what verification ran, including Xcode version and local `script/verify.sh`
  result
- what remote CI reported, including exact billing, spending-limit, quota, or
  failure evidence
- what instrumentation, logging, profiling, or performance evidence exists
- what code smells were observed, addressed, accepted, or remain
- what media-originals and diagnostics review found
- which outstanding PR review comments were claimed, how each was fixed, or why a
  finding was not applicable
- what risks or follow-up work remain
- which merge, local `main`, post-merge verification, branch cleanup, worktree
  cleanup, stash cleanup, stale branch/worktree review, and final clean-tree
  steps completed

- linked spec and ADRs when required
- linked requirement IDs and acceptance examples
- captured user requirements were restated to the user and stored in the correct
  current or planning document
- selected architecture with alternatives and pros/cons
- local `script/verify.sh` output summary and Xcode version
- tests for changed behavior at the narrowest useful boundary
- remote CI status recorded, with quota waiver evidence only when GitHub
  explicitly reports an account billing, spending-limit, or exhausted Actions
  quota blocker that prevents jobs from starting
- instrumentation added or updated for every meaningful path
- trace/log artifact paths for performance-sensitive work
- code smells observed and how they were addressed or intentionally accepted
- review comments on the last five PRs (merged or open, human or bot) scanned;
  actionable in-scope findings claimed by reply, fixed, and answered with how they
  were fixed and where, linking the fixing commit or PR; inapplicable or deferred
  findings answered with the reason
- docs updated in the same increment when contracts, workflow, requirements, or
  behavior changed
- repository-wide stale-document audit completed for affected ADRs, specs,
  requirements, process docs, indexes, templates, scripts, and backlinks, with
  obsolete documents deleted instead of retained as misleading history
- code-comment accuracy audit completed for affected file guides and focused
  comments, with no syntax narration, increment history, or retired behavior
- media-originals and diagnostics review for media, paths, metadata, logs,
  fixtures, and exports
- confirmation that no shim, legacy architecture, or effort-based compromise was
  introduced
- unresolved risks and follow-up work
- any non-blocking after-DoD verification tasks that require user operation,
  clearly distinguished from incomplete agent-owned DoD work
- `script/dod-report.sh` output or equivalent final DoD report completed only
  after the full increment is otherwise done
- increment branch and commits pushed to the remote before handoff, or the exact
  push blocker recorded in the DoD report
- PR merged into `main`
- local `main` updated to include the merge commit
- post-merge verification run when the increment changed build, test, workflow,
  dependency, project, or runtime behavior
- increment branch deleted locally and remotely after merge
- increment worktree removed after merge, if one was created
- stashes created for the increment cleared after merge
- stale local branches, remote branches, and worktrees reviewed; remove only
  items proven to belong to the completed increment and already merged or
  patch-equivalent to `main`
- final working tree clean on the intended next-start branch

If any item does not apply, state why in the PR or final increment report. Never
delete unrelated user stashes, branches, or worktrees as part of cleanup.
