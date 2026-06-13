# Otos Agent Instructions

Otos is a native macOS Lightroom-style application. It overlays organization,
metadata, previews, and editing intent on top of user-owned media that remains on
disk wherever the user chose to keep it. Originals are read-only.

## Non-Negotiable Principles

- Treat this repository as a blank-slate architecture.
- Do not add compatibility shims. If a structure is wrong, replace it with the
  right structure.
- Do not use effort as a decision criterion. Choose the correct architecture,
  even when it requires a larger refactor.
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

## Platform And Product Baseline

- Target the latest macOS and Xcode beta configured for this repo. The initial
  baseline is Xcode 27 beta with macOS deployment target 27.0.
- Prefer Apple-native technologies: Swift, SwiftUI, AppKit only when SwiftUI is
  insufficient, Image I/O, AVFoundation, Core Image, OSLog, Instruments, and
  filesystem/security-scoped access APIs.
- Third-party dependencies are allowed only when the spec proves they are the
  best architecture. Add alternatives and tradeoffs before adding one.
- Otos app data lives in Application Support. All overlay data is treated as
  backed up for now. Do not introduce preview pruning or cache eviction.
- Design file access around user-selected media roots and future
  security-scoped bookmarks, even during developer-build-first work.

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
- Interfaces, ownership boundaries, data flow, and persistence effects.
- Concurrency and actor ownership.
- Instrumentation and profiling plan.
- Test and acceptance criteria.
- Code-smell review for the target area.

An ADR is required for:

- Persistence or catalog data model choices.
- Filesystem access and security-scoped bookmark policy.
- Thumbnail, preview, metadata, import, export, or render pipeline design.
- Any reusable architecture boundary, dependency, or module split.
- Any decision that would be expensive to reverse.

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
- Keep domain models, stores, services, views, instrumentation, and support code
  in separate folders as the app grows.
- Prefer explicit ownership over ambient global state.
- Keep state at the narrowest correct scope:
  - view-local state with `@State`
  - parent-owned mutable state with `@Binding`
  - app or scene services through explicit dependencies
  - durable preferences with `@AppStorage`
  - per-window ephemeral state with `@SceneStorage` when appropriate
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
  cancellation path, and stale completion rejection by identity, version, or
  generation when applicable.
- Main-actor work must remain below Apple's 100 ms hang threshold. Scrolling,
  grid, animation, and pointer-interaction paths should be substantially below
  that and define feature-specific budgets in the spec.
- If a change touches jank, responsiveness, concurrency, media I/O, or rendering,
  include profiler or signpost evidence.

## Instrumentation And Performance

Instrumentation is not optional. Every meaningful path must be observable to the
submodule level before the feature is considered complete.

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

Log policy:

- info: high-signal operation boundaries and signpost spans
- debug: detailed internal state that remains privacy-safe
- error: failures and recovery paths without user content

Never log raw filenames, absolute paths, folder names, thumbnails, EXIF payloads,
or user-authored metadata by default. Use stable opaque IDs or safe counts.

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
- Privacy-hostile diagnostics: logs or errors expose media paths, names,
  metadata payloads, thumbnails, or user content.

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
- Required remote CI is a fast gate: checkout sanity, workflow YAML parsing,
  text hygiene, script inventory, and macOS lint. Remote CI does not run Xcode 27
  build/test until a runner with Xcode 27 exists.
- Xcode 27 build and test proof is required as local PR evidence through
  `script/verify.sh`.
- This is a private GitHub repository. Remote CI may be waived only when GitHub
  explicitly reports exhausted Actions quota. Paste that evidence in the PR.
- CI may not be waived for test failures, build failures, workflow syntax
  errors, missing tools, lint failures, runner bugs, or unrelated flakiness.
- Local `script/verify.sh` evidence is required even when remote CI quota is
  exhausted.

## Definition Of Done

There is one Definition of Done for each increment. An increment is not done
until the work has landed on `main`, the repo is clean, and the workspace is
ready for the next increment. An open PR can be ready for review or merge, but
it is not done.

- linked spec and ADRs when required
- linked requirement IDs and acceptance examples
- captured user requirements were restated to the user and stored in the correct
  current or planning document
- selected architecture with alternatives and pros/cons
- local `script/verify.sh` output summary and Xcode version
- tests for changed behavior at the narrowest useful boundary
- remote CI status recorded, with quota waiver evidence only when GitHub
  explicitly reports exhausted Actions quota
- instrumentation added or updated for every meaningful path
- trace/log artifact paths for performance-sensitive work
- code smells observed and how they were addressed or intentionally accepted
- docs updated in the same increment when contracts, workflow, requirements, or
  behavior changed
- privacy review for media, paths, metadata, logs, fixtures, and exports
- confirmation that no shim, legacy architecture, or effort-based compromise was
  introduced
- unresolved risks and follow-up work
- `script/dod-report.sh` output or equivalent final DoD report completed for the
  increment
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
