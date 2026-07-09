# Otos Agent Instructions

Otos is a native macOS Lightroom-style application. The user's filesystem is the
single source of truth for what media exists and where it lives. Otos overlays
organization, metadata, previews, and editing intent on top of user-owned media
that stays on disk wherever the user chose to keep it, including cloud-synced
folders. Originals are read-only, and Otos never takes the user's media hostage:
it never relocates originals into an opaque app-owned library and never writes
into the user's media folders.

`docs/architecture.md` is the current-state code map. `docs/requirements.md` is the
authoritative registry of implemented behavior. `docs/adr/` justifies the
architecture. Read those for detail; this file is how to work here.

## Non-Negotiable Principles

- Treat this repository as a blank-slate architecture. Do not add compatibility
  shims. If a structure is wrong, replace it with the right structure; do not
  patch around bad boundaries. Effort is not a decision criterion — choose the
  correct architecture even when it needs a larger refactor.
- Keep the app as simple as possible. Prefer the smallest correct model, owner,
  schema, state flow, and UI that satisfies verified requirements. Simplicity is
  a requirement, not a shortcut.
- Performance comes after correctness, simplicity, and clear ownership. Do not add
  caches, pools, background pipelines, generalized abstractions, split schemas, or
  scale machinery for anticipated load before measurement or a verified
  requirement proves the simple path insufficient.
- Do not guess. Inspect the repo, read the relevant APIs, and verify claims with
  code, docs, tests, profiling, or runtime evidence.
- Do not fabricate user-visible or domain facts. Unknown dates, paths, provider
  state, progress, counts, diagnostics, and capabilities stay unknown or
  explicitly qualified until proven.
- One user action has one implementation path. Buttons, menus, shortcuts,
  gestures, automation hooks, and tests call the same owner intent, not parallel
  behavior paths.
- The filesystem is the single source of truth. The catalog and every overlay Otos
  stores are a subordinate, rebuildable projection; when they disagree, the
  filesystem wins and the catalog reconciles.
- Otos never takes media hostage: no opaque app-owned vault, and it never writes
  into the user's media folders, including no sidecar files. It changes the user's
  files only through explicit, opt-in, user-initiated actions; the default is that
  nothing on disk changes.
- Overlay has one lifecycle. Every overlay Otos holds for an item is kept as long
  as that item exists and is purged in full only when the item is proven deleted.
  A temporarily missing original is never a deletion. Asset identity is the
  filesystem path; Otos invents no durable IDs, content fingerprints, or sidecars.
  See `docs/adr/0008-filesystem-source-of-truth-and-overlay-lifecycle.md`.
- The media grid never blanks a thumbnail already displayed for the same on-screen
  asset in the current process. A tile may show placeholder content only before
  that asset's thumbnail has ever decoded in this process; after a thumbnail
  paints, reorder-only applies, detail-query failures, missing detail rows, nil
  thumbnail loads, scrolling, enrichment, structural applies, and availability
  churn must keep that thumbnail or replace it only with a newer thumbnail for the
  same asset.
- Otos is an image/video product. Never add audio-specific playback, metadata,
  thumbnails, icons, classification, or workflows.
- Otos is unsandboxed. Design file access around user-selected media roots and
  normal filesystem paths. Do not add App Sandbox, security-scoped bookmarks,
  bookmark schema/lifecycles, or sandbox-driven file access.
- Otos has exactly one main window — a permanent product invariant. Use a
  singleton SwiftUI `Window` (not `WindowGroup`) for it; never design, defer, or
  leave seams for multiple main windows.

## Measure Before Optimizing (Rob Pike's rules)

You cannot tell where a program spends its time — measure before tuning, and only
when one part overwhelms the rest. Fancy algorithms are slow when n is small (n is
usually small) and buggier than simple ones; use simple algorithms and simple data
structures. Data dominates — get the data structures right and the algorithms
follow. In Otos: choose the simplest correct data structures and owners, ship them,
and let instrumentation prove a real bottleneck before optimizing it.

## Platform And Product Baseline

- Target the latest macOS/Xcode beta configured for this repo (baseline Xcode 27
  beta, macOS deployment target 27.0). Prefer Apple-native technologies: Swift,
  SwiftUI, Image I/O, AVFoundation, Core Image, OSLog, Instruments, filesystem
  APIs. Prefer SwiftUI; use AppKit only when SwiftUI cannot provide the capability
  or meet a verified responsiveness/performance requirement.
- Third-party dependencies require a justified decision (alternatives + tradeoffs)
  in an ADR before adding one.
- App data (catalog + all overlay) lives in Application Support and is treated as
  backed up. There is no cache eviction or preview pruning; overlay for an item is
  purged only when that item is proven deleted (absent from a reachable, fully
  enumerated root) or the user removes the containing root. Overlay is never purged
  when an original is merely temporarily missing.
- Most media lives in cloud-synced folders as possibly-dataless placeholders whose
  filesystem facts (name, size, dates, type) read without downloading, but whose
  bytes force materialization. Byte-reading work must never *accidentally*
  materialize a file: check the `FileMaterialization` detector (`SF_DATALESS`)
  immediately before any byte read. Deliberate non-blocking background
  materialization for enrichment is permitted (up to eagerly materializing the
  whole library); its unreclaimable local-disk cost is deliberately accepted. The
  scanner reads only filesystem facts and materializes nothing; the
  `EnrichmentCoordinator` is the byte-reading owner that materializes. See
  `docs/adr/0008-…` and `docs/adr/0009-enrichment-storage-and-staleness.md`.

## Architecture Standards

- Keep SwiftUI views small, composition-focused, and **passive**: they render
  provided state, hold local control state, bind controls, and call explicit owner
  intents. They must not subscribe to catalog streams, coordinate projection
  invalidation, call SQLite, or orchestrate scanning.
- Prefer direct, concrete designs over speculative flexibility. Add a layer, cache,
  protocol, worker queue, normalized table, or pipeline only when it removes
  current complexity or a verified requirement needs it. Protocols belong at real
  substitution boundaries.
- Prefer explicit ownership over ambient global state. Keep state at the narrowest
  correct scope (`@State`, `@Binding`, explicit dependencies, `@AppStorage`).
- Persistence has one current owner with an explicit schema/version policy and safe
  handling of unsupported/future schemas. Rebuildable cache state is overlay, not a
  second source of media truth.
- Catalog UI ownership split: `CatalogStore` (actor) owns runtime catalog truth and
  emits cheap change notifications; `CatalogProjection` (actor) owns coalesced
  `CatalogWindowState` publication (background cadence, immediate wakeup on user
  intents) plus all sorting/filtering/hiding/empty-state/scope derivation off the
  MainActor; `CatalogWindowViewModel` (`@MainActor`) owns only final SwiftUI state
  assignment, sidebar-selection delivery, lossless serial mutation delivery, weak
  projected-state consumption, and named task lifetimes.
- Architecture-boundary files carry a file guide plus focused comments explaining
  non-obvious actor isolation, task ownership, cancellation, persistence,
  coalescing, cache validation, and view passivity. Comments describe current
  mechanics and why the boundary exists — never syntax narration, changelog/history
  entries, or comparisons with removed code.

## Swift And Concurrency

- Swift 6 language mode, strict concurrency, `SWIFT_APPROACHABLE_CONCURRENCY = YES`.
  UI-facing app code is main-actor isolated by default.
- Never do media scanning, metadata reads, image decoding, thumbnail generation,
  database work, filesystem traversal, or export on the main actor. Treat
  synchronous work inside SwiftUI `.task` as main-thread work.
- Avoid unstructured `Task` ownership: long-running work needs an owner, a
  cancellation path, and stale-completion rejection or coalesced dirty/in-flight
  handling. A long-lived stream consumer captures its owner **weakly** across
  indefinite waits and upgrades only for the smallest completed-value scope.
- Repeated synchronous UI intents that start async work define their delivery
  semantics explicitly (newest-value coalescing, lossless serial, or intentional
  concurrency). Constructive/destructive commands must not use a dropping buffer
  without a rejection surface.
- When an actor suspends mid-operation, coalesce duplicate work through one owner
  and revalidate the operation's current typed ownership facts after every await
  before applying results. Prefer existing domain/persistence identity over a
  generated token.
- Main-actor work stays below Apple's 100 ms hang threshold; scrolling/grid/
  animation/pointer paths well below it. Changes touching jank, responsiveness,
  concurrency, media I/O, or rendering include profiler/log evidence.

## Instrumentation

Every meaningful path is observable before it is done, through the repo facade
(`OtosLog.Logger` + `OSSignposter`, categories App/UI/FileAccess/Catalog/Metadata/
MediaIO/Thumbnails/Persistence/Rendering/Performance). **No human reads logs** — the
agent does, so log the things the agent must find, in a machine-greppable shape.
The agent's windows are `script/logs.sh` (unified logs) and `script/profile.sh`
(Instruments via `xctrace`). Performance work is evidence-driven: measure, change,
remeasure; attach the log/trace artifact and worst-span summary. Do not add scale
machinery for anticipated load before measurement.

## Code Smells

Code smells are indicators, not guilt; when one appears, look for the deeper design
problem. Every PR notes the smells observed (`None observed` when true). Watch for:
MainActor gravity (work isolated to main because it is convenient); SwiftUI body
work (scanning/decoding/sorting/I/O in `body` or synchronous `.task`); state
duplication (two owners answer the same domain question); AppKit bridge sprawl;
unsafe concurrency escape (unchecked `Sendable`, detached tasks, shared mutable
state crossing actors without an owner); stringly-typed domain facts; ambiguous API
names; test coupling (asserting implementation details instead of observable
behavior); diagnostic payload sprawl.

## Toolchain

Use full Xcode (not Command Line Tools). Install tools with `brew bundle`. The
required local check is `script/verify.sh` (requirements-authority + lint + build +
test). Read logs with `script/logs.sh [Category]`; profile with
`script/profile.sh "<Template>" 10s`.

## Documentation

Documentation is organized around **current truth**, not increments. Each kind has
one MECE home:

- **`docs/requirements.md`** — the authoritative registry of implemented product/
  system behavior. Rows have a stable ID and map to the source files and tests that
  implement/verify them. Current-state only: no future ideas, no process/workflow
  rows, no roadmap. Every behavior change updates the affected rows in the same PR.
- **`docs/adr/`** — one architectural decision per ADR, justifying what was built
  (context, decision, rejected alternatives, consequences). MECE: each names what
  it owns and what it defers. Supersede/rewrite an ADR when a decision changes;
  never append increment history.
- **`docs/architecture.md`** — the one-page current-state code map (dataflow, actor
  ownership, where-to-change table). Update it when ownership or dataflow changes.
- **`docs/research/`** — every online-research pass, POC, and benchmark, dated with
  sources and conclusions. Write research here in the increment that relies on it.
- **`docs/plans/`** — active work plans, numbered. **Delete a plan when its work is
  fully done.**
- **`docs/product/roadmap.md`** — a non-authoritative idea pile. It never guides
  work unless the user explicitly asks for roadmap input.
- **Code reviews and DoD reports live on the PR, never in the repo tree.**

Whenever the user gives guidance that changes product direction, behavior,
architecture, or workflow, capture it in the correct home above during the same
increment (implemented behavior → requirements; a decision → an ADR; an unbuilt
idea → roadmap or a plan). Restate non-trivial captured requirements to the user
for confirmation before relying on them.

### Boundaries (do not let these regress)

- Do not create `docs/specs/` or per-increment spec files. Decisions go in ADRs;
  requirements go in `docs/requirements.md`; work goes in `docs/plans/`.
- Do not add process, workflow, or tooling rows to `docs/requirements.md`.
- Tests assert observable behavior or public owner boundaries. **Tests that read
  source files as text and assert on substrings are forbidden** (CI guards this).
- SwiftLint size limits (`file_length`, `type_body_length`) are warnings. Do not
  split a cohesive type only to satisfy them, and do not re-add hard `error:`
  thresholds. Cohesion sets boundaries.

## Git, CI, And Pull Requests

- Branch with a conventional prefix matching the work (`feat/`, `fix/`, `refactor/`,
  `docs/`, `chore/`, `research/`). Start new work in a dedicated git worktree.
- Never discard user work: do not remove worktrees/branches/stashes unless proven to
  belong to the completed increment and already merged or patch-equivalent to main.
- Use PRs for review; direct commits to `main` are not the normal path. Apply the
  same review bar to your own self-review before opening a PR.
- Before opening a PR, scan the last five PRs (merged or open, human or bot) for
  unresolved review comments. Claim each on the thread, land in-scope fixes through
  the normal path, and reply with how/where it was fixed (or why it is not
  applicable). Do not bypass with a parallel patch or hide a thread.
- Remote CI is a fast gate (checkout sanity, workflow YAML, text hygiene, script
  inventory, macOS lint); it does not run Xcode 27 build/test until a runner exists.
  Xcode 27 build/test proof is local `script/verify.sh` evidence. CI may be waived
  only when GitHub reports a billing/quota blocker (paste the evidence); never for
  failures, syntax errors, missing tools, or flakiness.

## Definition Of Done

There is **one** DoD report per increment, and it is the final report — never a
partial, pre-merge, or ready-for-review DoD. An increment is done only when the
work has landed on `main`, the branch/worktree/stashes are cleaned up, and the tree
is clean on the next-start branch.

Verification is **agent-owned**: never require the user to launch the app, operate
the UI, or inspect visuals as a condition of DoD. Run every check available to the
agent; when a useful check cannot be run in the agent environment, record the
limitation, the evidence gathered instead, and the remaining risk as a non-blocking
after-DoD note, and complete the increment anyway.

The final DoD report is **posted on the PR and sent to the user in full** — the same
complete report, not a summary with a link. It uses green/red status emoji with
plain-language text and answers: what was done; what was not; design decisions;
requirement/ADR/doc changes; verification (Xcode version + `script/verify.sh`
result); remote CI status (with exact waiver evidence if any); instrumentation/
profiling evidence; code smells observed/addressed/accepted; media-originals and
diagnostics review; outstanding review comments claimed and how each was fixed;
risks/follow-ups; and the merge + cleanup steps completed. `script/dod-report.sh`
generates the mechanical checklist; the report must be complete before it is sent.
