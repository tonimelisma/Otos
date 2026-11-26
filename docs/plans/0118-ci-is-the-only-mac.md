# Plan 0118: CI is the only Mac (2026-11-26)

The owner (2026-11-26): "releases need to happen even from cloud. CI needs to be enough.
cloud dev might be the only way we do dev for months. we can't be gated on a local env."
A session on the owner's Mac stays possible, started from Claude Code on the Mac itself,
never reached from a cloud session.

Evidence: `docs/research/2026-11-26-ci-only-macos-development.md` and
`docs/research/2026-11-26-agent-instruction-files.md`.

## The strategy

- **GitHub's `xcode-27` runner is the Mac.** Each fact a session on the Mac supplied
  becomes a CI job whose evidence a cloud session reads: `op=` lines in the job log, JSON,
  and PNG artifacts made from generated media. Merging, releasing and the Definition Of Done
  need nothing else.
- **A session on the Mac is optional, and nothing waits for it.** It adds read-only looks at
  the owner's own data and app: his library, the installed app's logs, the felt targets, the
  evaluations on his data, profiling and lldb. It verifies through the same CI run, and it
  never installs. Sparkle is the only installer, so the installed app is always a build CI
  published.
- **What the owner's Mac experiences reaches a session only when he hands it over.** The app
  writes a diagnostics bundle on request, and he gives it to a session. Nothing about his
  data is uploaded to CI, a public artifact or a third-party service.

## Steps

Each step is one increment with its own PR, in this order.

1. **The tour on CI, with captures.** A CI job builds the dev app and runs the sandbox tour
   (`script/scorecard.sh --tour --dev --seed <n>`). It captures every surface the tour visits
   in light and dark (`SmokeWindowCapture`) and uploads the PNGs and the scorecard as
   artifacts. It fails when the tour does not finish, a step reaches its deadline, or the
   app logs a fault.
   - De-risk first: on one `workflow_dispatch` run, the app raises no TCC prompt, the
     sandbox disk image mounts on the runner, and a seed fits in 14 GB.
   - Done when the job is required for any diff that takes the full tier.
   - Also done when the Definition Of Done's look is "download this run's captures of the
     surfaces the increment changed and read them". Gray-scale (DES-029) is made from the
     PNG in the session.
   - Stops if the runner cannot show the window. Then XCUITest `screenshot()` is the
     fallback, and it is measured the same way.
2. **The release launches what it ships.** `script/release.sh` verifies the archive's
   signature (`codesign --verify --deep --strict`). It then launches the app from that
   archive in a sandbox home, waits for its first grid (`op=launch.firstGrid`, never a
   timer), quits it and confirms it is gone, all before publishing anything.
   - Done when a release whose app cannot reach its window publishes nothing.
3. **One suite, many times, on CI.** A `workflow_dispatch` workflow takes a suite name and an
   iteration count. It runs `-run-tests-until-failure` on the runner and prints the same
   `op=test.failure` lines. This is a cloud session's `--only`.
4. **The weekly counts on CI.** A scheduled workflow runs `script/bench.sh compare` of
   `origin/main` against the last run's head on the runner. It then runs a sandbox tour at
   `-O` whose scorecard is kept as an artifact for trend.
   - De-risk first: one run shows the instruction counters are readable inside the runner's
     VM. If they are not, the workflow is not built, and deterministic twin tests remain the
     only performance gate.
   - ADR 0043 is rewritten. `script/perf.sh` keeps only the owner-library tour, for a
     session on the Mac.
5. **Diagnostics the owner can hand over.** Help ▸ Export Diagnostics… writes one folder
   (ADR, requirement row, design spec). It holds:
   - the app's own log lines read through `OSLogStore`;
   - the MetricKit crash and hang payloads the app has kept in Application Support;
   - Otos's crash reports;
   - the installed version;
   - catalog counts.

   A cloud session symbolicates it against the release's dSYMs with `llvm-symbolizer`. It
   never goes to CI or anywhere public.
6. **The instruction files rebuilt.** Landed first (below).

## The five-minute budget

The owner (2026-11-26): "just try to ensure each commit wraps up in 5 minutes of testing
from the moment dev works. local and CI together, everything. if not possible, have a good
reason why not, and report back to me." Every step above fits inside it or says, with
measurements, why it cannot (ADR 0044, items 13–16). The tour of step 1 and the release's
launch of step 2 run beside the build and tests, never after them.

## The instruction files (step 6, landed)

`AGENTS.md` became a core file, `.claude/rules/` (Swift, media bytes and MediaMetadata,
persistence, UI, scripts) and `.claude/skills/` (`ci`, `long-checks`, `otos-review`, `dod`,
`mac-session`, `release`), with `script/cloud-setup.sh` printing where a session runs. The
owner's decisions on 2026-11-26:

1. His standing rules stay in `AGENTS.md`: a cloud session reads no personal file, and
   the owner chose not to add an environment setup script to supply one.
2. "Live tests may write to Taylor's real apps" is not an Otos rule.
3. Owner guidance is captured in its home and restated in the final report, not asked
   about first.
4. A session on the Mac develops in a worktree with dev builds and never installs.
5. The final report is posted in full on the PR, with a short summary and its link in chat.
6. "Engineering effort is free. Never take a shortcut" stays as written, with one
   exception: time is not free, and a commit's check fits five minutes.
