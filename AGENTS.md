# Otos Agent Instructions

Otos is a native macOS Lightroom-style application. It overlays organization,
metadata, previews, and editing intent on top of user-owned media that remains on
disk wherever the user chose to keep it. Originals are read-only unless a future
spec explicitly changes that rule.

These instructions are part of the product architecture. Follow them before
local preference, speed, or convenience.

## Non-Negotiable Principles

- Treat this repository as a blank-slate architecture. Do not revive old Otos
  Studio implementation ideas, names, shims, or migration paths.
- Do not add compatibility shims. If a structure is wrong, replace it with the
  right structure.
- Do not use effort as a decision criterion. Choose the correct architecture,
  even when it requires a larger refactor.
- Do not patch around bad boundaries, stale abstractions, or accidental
  complexity. Remove the wrong abstraction and rebuild the affected path cleanly.
- Do not guess. Inspect the repo, read the relevant APIs, and verify claims with
  code, docs, tests, profiling, or runtime evidence.
- Keep user media private. Never log raw paths, filenames, thumbnails, EXIF
  payloads, or user content by default.

## Platform And Product Baseline

- Target the latest macOS and Xcode beta configured for this repo. The initial
  baseline is Xcode 27 beta with macOS deployment target 27.0.
- Prefer Apple-native technologies: Swift, SwiftUI, AppKit only when SwiftUI is
  insufficient, Image I/O, AVFoundation, Core Image, OSLog, Instruments, and
  filesystem/security-scoped access APIs.
- Third-party dependencies are allowed only when the spec proves they are the
  best architecture. Add alternatives and tradeoffs before adding one.
- Otos app data lives in Application Support. All overlay data is treated as
  backed up for now. Do not introduce preview pruning or cache eviction until a
  catalog-storage ADR defines that policy.
- Design file access around user-selected media roots and future
  security-scoped bookmarks, even during developer-build-first work.
- Do not choose SwiftData, Core Data, SQLite, or another catalog store casually.
  The first catalog implementation must begin with an ADR.

## Spec-Driven Workflow

Every meaningful increment starts with a spec in `docs/specs/` and any needed
ADR in `docs/adr/`.

A spec must include:

- Problem statement and user-facing goal.
- In-scope and out-of-scope work.
- Current repo state discovered through inspection.
- At least two architectural alternatives with pros, cons, and failure modes.
- The selected approach and why it is right for the product, not why it is easy.
- Interfaces, ownership boundaries, data flow, and persistence effects.
- Concurrency and actor ownership.
- Instrumentation and profiling plan.
- Test and acceptance criteria.

An ADR is required for:

- Persistence or catalog data model choices.
- Filesystem access and security-scoped bookmark policy.
- Thumbnail, preview, metadata, import, export, or render pipeline design.
- Any reusable architecture boundary, dependency, or module split.
- Any decision that would be expensive to reverse.

Do not implement from a vague task. First convert it into a decision-complete
spec, then implement.

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
- Do not hardcode light-only colors or custom sidebar chrome unless a design
  spec proves it belongs.

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
- Main-actor work must remain below Apple's 100 ms hang threshold. Scrolling,
  grid, animation, and pointer-interaction paths should be substantially below
  that.
- If a change touches jank, responsiveness, concurrency, media I/O, or rendering,
  include profiler or signpost evidence.

## Instrumentation Requirements

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

Codex-accessible evidence:

- `script/logs.sh` for live unified logs and signposts.
- `script/profile.sh SwiftUI 10s` for SwiftUI profiling.
- `script/profile.sh "Swift Concurrency" 10s` for concurrency profiling.
- `script/profile.sh "Animation Hitches" 10s` for hitch investigation.
- `script/profile.sh "Time Profiler" 10s` for CPU work.
- `script/profile.sh "File Activity" 10s` for filesystem work.

## Toolchain

Use full Xcode, not Command Line Tools:

```sh
sudo xcode-select --switch /Applications/Xcode-beta.app/Contents/Developer
```

Local scripts must fail clearly if `xcode-select -p` points at
`/Library/Developer/CommandLineTools` or any developer directory without
`xcodebuild`.

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
- Use PRs for review. Do not treat direct commits to `main` as the normal
  integration path.
- CI runs on `macos-26` and must build, test, run SwiftFormat lint, and run
  SwiftLint.
- Default local and CI verification runs unit tests. UI smoke tests live behind
  `script/test-ui.sh` because macOS UI automation can be blocked by local
  automation-mode permissions or runner configuration.
- Run `script/test-ui.sh` for UI-affecting changes whenever the environment can
  enable XCTest UI automation. If it cannot, record the exact automation setup
  failure in the PR.
- This is a private GitHub repository. Remote CI may be waived only when GitHub
  explicitly reports exhausted Actions quota. Paste that evidence in the PR.
- CI may not be waived for test failures, build failures, workflow syntax
  errors, missing Xcode, lint failures, runner bugs, or unrelated flakiness.
- Local `script/verify.sh` evidence is required even when remote CI quota is
  exhausted.

## Definition Of Done

A change is not done until the PR includes:

- linked spec and ADRs when required
- selected architecture with alternatives and pros/cons
- local verification command output summary
- tests for changed behavior
- UI smoke evidence for UI-affecting changes, or the exact environment error
  that blocked UI automation
- instrumentation added or updated for every meaningful path
- profiler or signpost evidence for performance-sensitive work
- privacy review for media, paths, metadata, logs, fixtures, and exports
- confirmation that no shim, legacy architecture, or effort-based compromise was
  introduced

If any item does not apply, state why in the PR.
