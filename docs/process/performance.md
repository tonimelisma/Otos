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

Live logs and signposts:

```sh
script/logs.sh
script/logs.sh UI
script/logs.sh Performance
script/logs.sh Thumbnails
```

Catalog diagnostics:

```sh
script/catalog-diagnostics.sh check
script/catalog-diagnostics.sh summary
```

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
