---
name: ci
description: Read, watch and reproduce Otos's GitHub Actions CI from a cloud session (REST only), and read a failed run's op= lines. Use after every push, before merging, and when a CI job fails.
---

# CI from a session

Every push runs `CI`:
- the Ubuntu jobs: Checkout Sanity, Workflow YAML And Script Shape, Text Hygiene, and
  SwiftFormat And SwiftLint;
- `Build And Test (Xcode 27)` on GitHub's `xcode-27` runner, which runs `script/check.sh`;
- `Required CI Gate`, which `main` requires.

Build And Test's run on a PR's final commit is that PR's verification. A merge to `main`
that changes the app is then published by `Release` (`release` skill).

## Reading it

The VM's proxy refuses GraphQL, so `gh pr …` commands fail. Use REST:

    gh api repos/tonimelisma/Otos/commits/<sha>/check-runs --jq '.check_runs[] | "\(.id) \(.name) \(.status) \(.conclusion)"'
    gh api repos/tonimelisma/Otos/check-runs/<id>/annotations --jq '.[].message'
    gh api repos/tonimelisma/Otos/actions/jobs/<id>/logs | grep -E 'op=test.failure|op=check.(stage|duration|hang|tier|swiftformat)|op=lint|check: '

Job step timings, for the five-minute budget (ADR 0044, item 13):

    gh api repos/tonimelisma/Otos/actions/runs/<run>/jobs --jq '.jobs[] | "\(.name) \(.started_at) \(.completed_at)"'

## Watching it

Arm a `Monitor` that reads the check runs every 60 s. It must exit on every terminal fact:
- all six runs completed;
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
- A job gets at most one re-run. "Flake" is not a root cause.

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
