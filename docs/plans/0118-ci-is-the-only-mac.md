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
6. **The instruction files rebuilt** (next section). These can land first, since they change
   no build.

## Rebuilding AGENTS.md

`AGENTS.md` is 728 lines and 48,834 characters; the guidance is under 200 lines per file,
with procedures in skills and path-specific rules in `.claude/rules/` (research note above).
The rebuild keeps every rule's substance and moves it to where it loads when it applies.

### AGENTS.md (about 200 lines, every session, every environment)

- What Otos is, and where each kind of truth lives (`docs/architecture.md`, requirements,
  ADRs, design system, research, plans).
- How a session works:
  - The cloud session is the default.
  - `script/check.sh` is the one command.
  - Verification is CI's `Build And Test` on the final commit, wherever the session runs.
  - The three REST reads of CI.
  - Merging.
  - The Definition Of Done in short.
- The invariants, one to three lines each with their reason and ADR:
  - source of truth and no hostage media;
  - overlay lifecycle;
  - originals read-only and materialization;
  - production data is read, never changed;
  - no fabricated facts;
  - time is not a stand-in (checked by `script/time-guard.sh`);
  - one action, one path;
  - no audio;
  - unsandboxed;
  - one window;
  - a painted thumbnail is never blanked;
  - MediaMetadata owns byte facts;
  - dependencies need an ADR.
- Design principles:
  - blank slate, no shims;
  - the simplest correct design;
  - measure before optimizing;
  - the machine's resources are for the work.
- Documentation homes and their boundaries.
- Working with the owner (below).

### Path-scoped rules (`.claude/rules/`, loaded when a matching file is touched)

- `swift.md` (`OtosKit/**`, `Otos/**`, `OtosTests/**`):
  - Swift 6 and ADR 0032's six rules;
  - view passivity;
  - the architecture standards;
  - instrumentation;
  - code smells.
- `persistence.md` (the catalog store and migration files): ADR 0002's migration cost rules.
- `ui.md` (`OtosKit/Views/**`, `docs/design/**`): review lens C and the DES workflow.
- `scripts.md` (`script/**`): the tiers, `time:` tags, and the self-test convention.

### Skills (`.claude/skills/`, loaded when used)

- `ci`: reading, watching and reproducing CI from a cloud session; downloading captures.
- `long-checks`: supervising `check.sh`, heartbeats, hang diagnosis.
- `review`: lenses A and B with their questions.
- `dod`: the report's shape and `script/dod-report.sh`.
- `mac-session`: what a session on the Mac adds:
  - worktrees;
  - the SSH fallback;
  - `script/logs.sh` and `script/profile.sh`;
  - the production-data read-only procedures;
  - the owner-library tour and look;
  - the owner-data evaluations.
- `release`: what a merge publishes, how a bad release is undone (a higher version with the
  revert; never revert a migration), and the yearly certificate renewal.

### The SessionStart hook

`script/cloud-setup.sh` prints a few lines of context about where the session runs. In the
VM it names the `ci` skill and says that the Mac-only steps don't exist there. On the Mac it
names `mac-session`. The prose "Cloud Sessions" section goes away.

### Cut

- The "Owner setup" history ("Done on …"). The one pending owner step moves to the README.
- Dated owner quotes. Each one's reason moves into the ADR its rule names.
- The catalog ownership split (`docs/architecture.md`, ADR 0004). The weekly verdict table
  (ADR 0043). Sparkle's mechanics (ADR 0059).
- "Engineering effort is free. Never take a shortcut" stays as an idea. Its wording becomes
  plain, with scope and reason, because over-emphatic absolutes cause over-application.

### Open owner decisions

These change the files' wording, and only the owner can make them.

1. **"Taylor's Standing Rules".** Keep them in the public repository, or move them into a
   personal environment's setup script that writes `~/.claude/CLAUDE.md` (it reaches cloud
   sessions; a Mac session reads his own file).
2. **"Live tests may write to Taylor's real apps".** In Otos this contradicts "the owner's
   production data is read, never changed". Proposed: drop it from Otos.
3. **"Never ask whether to do it" against "restate non-trivial captured requirements for
   confirmation before relying on them".** Proposed: ask only for a product choice not yet
   made, and restate a captured requirement in the final report instead of before acting.
4. **"A session never builds, installs or develops on the owner's Mac" (2026-11-26).**
   Proposed: a session started on the Mac develops in a worktree with dev builds, and never
   installs.
5. **The DoD report "posted on the PR and sent to the user in full".** Proposed: posted in
   full on the PR, with a short summary and the link in chat.
6. **"Engineering effort is free. Never take a shortcut"**, rewritten as above. It is the
   owner's own rule, so its new wording is his to approve.
