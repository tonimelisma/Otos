# Performance And Jank Evidence

Otos performance work uses Apple guidance and this repo's concrete tooling:
`OtosLog`, `OtosSignpost`, debug JSONL diagnostics,
`script/logs.sh`, `script/catalog-diagnostics.sh`, and `script/profile.sh`.

Sources:

- [Apple: Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)
- [Apple WWDC26: Profile, fix, and verify](https://developer.apple.com/videos/play/wwdc2026/268/)
- [Apple WWDC23: Analyze hangs with Instruments](https://developer.apple.com/videos/play/wwdc2023/10248/)
- [Apple WWDC23: Demystify SwiftUI performance](https://developer.apple.com/videos/play/wwdc2023/10160/)

## Baseline

- Hangs are delays between user input and visible response. Main-thread work
  over 100 ms needs investigation.
- Hitches are missed frames during continuous interaction. Scrolling,
  animation, pointer, grid, and resize paths need stricter feature-specific
  budgets than the hang threshold.
- Measure first, change the code, then remeasure. Do not diagnose performance by
  intuition alone.
- Follow Rob Pike's 5 Rules, whose canonical statement is in `AGENTS.md`: you
  cannot guess where time goes, so measure before tuning; do not get fancy until n
  is proven large; prefer simple data structures and simple algorithms.

## Required Spec Content

Performance-sensitive specs must name:

- the user interaction or app path being protected
- expected budget or threshold
- `OtosLog` categories and `OtosSignpost` spans
- debug JSONL diagnostic events, when large operations need checkable run
  artifacts
- which `script/profile.sh` templates will be used
- what artifact paths will be attached or summarized in the PR

## Repo Tooling

Timestamped per-run capture (build, launch, stream until Ctrl+C):

```sh
script/capture-run.sh
```

Output lands under `logs/run-<sessionID>-prod.log` with compact unified-log
timestamps, process, subsystem, category, and signposts. Prefer this over ad-hoc
debugger console redirection when analyzing a session.

Seeded scroll smoke (build, resolve and launch with the user's OneDrive Pictures
library, wait 10 seconds, scroll down/up, summarize diagnostics, quit):

```sh
script/smoke-run.sh
```

This is the default agent smoke path for browser runtime and jank-sensitive work.
It avoids the false confidence of launching into an empty catalog, captures a
compact log under `logs/`, and writes catalog diagnostics artifacts under
`build/Diagnostics`. Use `script/smoke-run.sh --verify` only when you need the
lighter seeded-launch check; it still fails unless diagnostics prove the seeded
root was consumed, but it does not exercise scrolling.

Live logs and signposts (attach to an already-running app):

```sh
script/logs.sh
script/logs.sh UI
script/logs.sh Performance
script/logs.sh Thumbnails
```

When reproducing main-thread stalls or priority inversions, enable Xcode's
**Thread Performance Checker** under **Product → Scheme → Edit Scheme → Run →
Diagnostics**.

SwiftUI/AppKit high-cardinality view jank:

- Use Otos Logger events and signposts for high-frequency ViewModel and AppKit
  boundaries: state assignment, media item count, collection receipt/apply/
  coalescing/reload/layout, and slow cells. These paths must not create JSONL
  tasks or retain full catalog state.
- Use coarse JSONL diagnostics for Store/scan operations, Projection summaries,
  availability transitions, failures, and actual active-app run-loop stalls.
- Use `sample` or `script/profile.sh "Time Profiler" 10s` while the app is
  beach balling to inspect private SwiftUI/AppKit stacks.
- Do not claim Otos directly measures private AppKit internals. Correlate our
  boundary evidence with Apple tooling evidence.

Catalog diagnostics:

```sh
script/catalog-diagnostics.sh check
script/catalog-diagnostics.sh summary
```

By default this reads the newest session-scoped JSONL file from
`~/Library/Application Support/net.melisma.Otos/Diagnostics/`, named
`catalog-diagnostics-<sessionID>-<prod|test>.jsonl`. Set
`OTOS_CATALOG_DIAGNOSTICS_FILE` to summarize a specific copied artifact.

Profiles:

```sh
script/profile.sh "Animation Hitches" 10s
script/profile.sh SwiftUI 10s
script/profile.sh "Swift Concurrency" 10s
script/profile.sh "Time Profiler" 10s
script/profile.sh "File Activity" 10s
```

List available templates:

```sh
script/profile.sh --list
```

## Review Checklist

- Is the MainActor busy, blocked, or waiting for an async dependency?
- Does SwiftUI recompute broad view state for narrow changes?
- Does a render path decode images, scan files, query persistence, or format
  large data synchronously?
- Does the implementation preserve user interaction as the highest-priority
  path?
- Are log and signpost names specific enough to identify the owner/submodule?
- Does the PR include trace/log artifact paths and summarize the worst spans or
  the exact blocker that prevented capture?
- For catalog and projection changes, does the PR include
  `script/catalog-diagnostics.sh check` output or the exact reason no debug
  diagnostic file existed?

## PR Evidence

For performance-sensitive changes, include:

- command run
- trace or log path under `build/Profiles` or captured terminal output location
- diagnostic summary path under `build/Diagnostics`, when applicable
- interaction exercised
- worst span or stall summary
- whether the result passed the budget
- follow-up risk if the budget was not met

User-operated performance reproduction is not a DoD condition. When the agent
environment cannot drive the required visible interaction, include the exact
limitation and all substitute evidence the agent could collect, then identify
the visible interaction as a non-blocking after-DoD task.
