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

1. **Captures on CI.** Landed for All Media: shard 3 of every full-tier run captures the
   dev build's window, light and dark, on generated media (ADR 0044, item 20), and the DoD's
   look reads them. Still open: a capture of each other surface (Places, People, On This
   Day, Duplicates, the edit panel), each needing generated media that fills it (photos with
   locations, faces, anniversaries, duplicate pairs) and a selection the capture waits on.
2. **The release launches what it ships.** Landed (ADR 0059, item 9).
3. **One suite, many times, on CI.** Landed: the workflow Repeat A Suite (ADR 0044,
   item 19).
4. **The weekly counts on CI.** The workflow Weekly Counts (Mondays, or by hand) first
   reads this runner's instruction counter (`proc-rusage.py`); reading zero, it measures
   nothing and says so. Otherwise it runs `script/bench.sh compare` of `main`'s head against
   `bench.sh last-measured` and pushes the records as `refs/notes/benchmarks`.
   - De-risk: its first run by hand. Counters that read zero end this step: the workflow
     is removed and deterministic twin tests stay the only performance gate.
   - Counters that read: `script/perf.sh run` keeps only the owner-library tour, for a
     session on the Mac, and ADR 0043 is rewritten for the split.
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
