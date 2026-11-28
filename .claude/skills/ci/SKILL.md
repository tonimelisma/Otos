---
name: ci
description: Read, watch and reproduce Otos's GitHub Actions CI from a cloud session (REST only), and read a failed run's op= lines. Use after every push, before merging, and when a CI job fails.
---

# CI from a session

Every push runs `CI`:
- the Ubuntu jobs: Checkout Sanity, Workflow YAML And Script Shape, Text Hygiene, Process
  (`script/process-check`, and `script/pr-check` on a PR), SwiftFormat And SwiftLint, and
  Already Tested (`script/ci-tested-tree.sh`);
- `Build And Test (Xcode 27) 1/3`, `2/3` and `3/3` on GitHub's `xcode-27` runners, each
  running `script/check.sh` with its shard of the suite (`OTOS_TEST_SHARD`, ADR 0044
  item 17);
- `CI gate`, which needs every other job and is the one check `main`'s ruleset requires.

`CI gate` green on a PR's final commit is that PR's verification. The ruleset also requires
the PR to be up to date with `main`: when `main` moved, update the branch with
`gh api -X PUT repos/tonimelisma/Otos/pulls/<N>/update-branch` (`script/stage pre-merge`
does it) and wait for the new head's `CI gate`. Because of that, a push to `main` is the
exact tree its PR tested, and `Already Tested` skips the shards there (ADR 0062); the
weekly run (Tuesday) and any push whose tree differs run them. `Release` starts on the
same push and publishes once that `CI gate` passed (`release` skill).

## Reading it

The VM's proxy refuses GraphQL, so `gh pr …` commands fail. Use REST:

    gh api repos/tonimelisma/Otos/commits/<sha>/check-runs --jq '.check_runs[] | "\(.id) \(.name) \(.status) \(.conclusion)"'
    gh api repos/tonimelisma/Otos/check-runs/<id>/annotations --jq '.[].message'
    gh api repos/tonimelisma/Otos/actions/jobs/<id>/logs | grep -E 'op=test.failure|op=check.(stage|duration|hang|tier|swiftformat)|op=lint|check: '

Job step timings, for the five-minute budget (ADR 0044, item 13):

    gh api repos/tonimelisma/Otos/actions/runs/<run>/jobs --jq '.jobs[] | "\(.name) \(.started_at) \(.completed_at)"'

## Watching it

Arm a `Monitor` that reads the check runs every 60 s. It must exit on every terminal fact:
- every run completed (`CI gate` among them);
- any run failed, was cancelled or timed out;
- a job GitHub did not start (its annotation says why, for example a billing limit).

A watcher that exits only on success waits forever on an outage. Never end the turn to
wait for a CI notification: a green run may never send one.

## A failure

- A failed build-and-test prints one `op=test.failure test=<Suite/case> at=<file>:<line>
  message=<issue>` line per failed test. Read them before changing anything.
- A hang prints `op=check.hang` lines (`long-checks` skill). The job uploads `logs/` as
  the artifact `check-logs-<run>-<attempt>`, which holds the hang dumps and every check's
  own log under `logs/check/`.
- Each push is a full run. To reproduce, read the failure, fix it, and push once.
- A failure that shows only sometimes is reproduced with the workflow Repeat A Suite:
  `gh api -X POST repos/tonimelisma/Otos/actions/workflows/repeat.yml/dispatches -f ref=<branch>
  -f inputs[suite]=<Suite> -f inputs[iterations]=20`. It runs that suite up to that many
  times and stops at the first failure (ADR 0044, item 19). Every Wednesday it repeats the
  suites that have flaked before (`docs/lessons.md`); a red weekly repeat is fixed first.
- A job gets at most one re-run. "Flake" is not a root cause.

## The captures

Shard 3 of a full-tier run launches the dev build it tested, once per appearance, on a
library of generated media, and writes its window in each view (the library's grid, Places, On This Day, Duplicates, and
the Edit pane), light and dark (`script/app-capture.sh`), as the artifact
`app-captures-<run>-<attempt>`. The window is zoomed to the runner's 1024 × 768 screen
and drawn inactive (a shell-launched app cannot take activation: gray window buttons, a
dimmed toolbar), and the grid is captured once the items at its top have their thumbnails.
People is not captured: the generated photos hold no faces.
A release captures the grid with the archive it is about to publish
(`release-captures-<run>`) and publishes nothing whose window does not draw. Fetch
them into the scratchpad and read the PNGs:

    gh api repos/tonimelisma/Otos/actions/runs/<run>/artifacts --jq '.artifacts[] | "\(.id) \(.name)"'
    gh api repos/tonimelisma/Otos/actions/artifacts/<id>/zip > <scratchpad>/captures.zip

`<view>-<appearance>.png` (`library`, `places`, `on-this-day`, `duplicates`, `edit`) is
the window as the screen composes it (`screencapture`); `<view>-<appearance>-rendering.png`
is the app's own `cacheDisplay` rendering, which leaves out layer-backed content (the
grid's tiles, the map) and the toolbar. For a branch whose CI built no app (the
static tier), start the workflow Capture The App on it
(`gh api -X POST repos/tonimelisma/Otos/actions/workflows/capture.yml/dispatches -f ref=<branch>`).
It also runs every Wednesday on `main`, capturing every view on a larger generated library. Name what each should show before
reading it (`dod` skill).

## A red `main`

A red `main` blocks merging anything that could change build or test results, except the
fix that greens it. A PR that sees a red baseline opens that fix first, because merging
beside a known-red `main` is exactly when a real regression hides. A doc-only increment
is not blocked: its diff cannot compile, run, or hide anything. Its final report names the
red baseline and the failing test.

## A job that did not run

That is a job queued with no runner while githubstatus.com reports Actions degraded, or
one refused for billing.
- It is not a failure, and is never replayed by hand.
- A cloud session has no other run for a full-tier change, so it waits and says so.
- When Actions recovers, `main`'s push run verifies the merge, and a red result there is
  fixed first.
