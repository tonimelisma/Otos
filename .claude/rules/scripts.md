---
paths:
  - "script/**"
  - ".github/**"
---

# Scripts and CI

- **Build-path scripts take the full tier.** These are `script/check.sh`,
  `script/verify.sh`, `script/build.sh`, `script/test.sh` and `script/lib/`. Only a build
  proves them, so a diff touching them takes the full tier. Other scripts, `.github/` and
  `.claude/` take the static tier (ADR 0044, item 10).
- **Every CI job's checks also run in `check.sh`'s fast gates,** so a green check is a
  green CI. Every fast gate also runs in an Ubuntu CI job, so the Mac shards skip them
  (`OTOS_CHECK_FAST_GATES=ubuntuJobs`, ADR 0044 item 18). A new gate goes into both places.
- **CI is held to the five-minute budget** (ADR 0044, items 13–16):
  - A new job states its measured duration.
  - A job that would push a commit's check past five minutes is redesigned: cached,
    narrowed to what changed, or parallel.
- **Every wait in a script carries a `time:` tag** (ADR 0033; `script/time-guard.sh`
  checks it).
- **Never put a kill-timeout on shared tooling.** A wall-clock limit destroys a
  legitimately slow run and hides the defect. A suite that hangs has a defect; fix it.
- **Kill a process tree, never the parent alone.** Killing `verify.sh` orphans its
  `test.sh` and `xcodebuild` children, and an orphan competing for `build/DerivedData`
  causes deadlocks.
- **A script with rules has a self-test** that `check.sh` runs in its fast gates (for
  example `perf.sh self-test`, `guard-*.sh self-test`). Change the rules and the self-test
  together.
- **A test that fails or hangs only under parallel load has a defect.** The cause is one
  of: a wall-clock bound; an order between two async facts it does not own; a leaked
  thread or file. Fix that test or its harness; never serialize the runs.
