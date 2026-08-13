# Plan 0085 — Close The Gate That Let `main` Stay Red

## Goal

Make it impossible for `main` to sit red across dozens of merges again. The red
itself is already fixed; this plan fixes the process hole that hid it.

Scope is **CI configuration only**. No source, no tests, no requirements rows.

## Why now

`script/verify.sh` exited 1 at `script/lint.sh` from `7cc0983` (#192) through
`d7f8680` (#246) — roughly 50 merged PRs. Because `lint.sh` runs before
`build.sh` and `test.sh` (`verify.sh:6-12`), **build and test never ran** for that
entire stretch. Every "verify.sh green" claim in those commits was false, and the
memory-exhaustion bug fixed in `e5c92ef` shipped inside that window precisely
because no suite ever completed to reveal it.

Two independent failures had to coincide: the red was introduced, and the gate
that should have blocked it did not.

## What is already fixed

| Commit | Fix | Evidence |
| --- | --- | --- |
| `b72017a` | `swiftformat .` — 60 violations across 30 files, three auto-fixable rules (`wrapMultilineStatementBraces` 51, `sortImports` 6, `hoistPatternLet` 3) | `swiftformat --lint .` → `0/216 files require formatting`; `script/lint.sh` exit 0; `script/build.sh` succeeded |
| `e5c92ef` | Removed two self-recursive async test gates that exhausted memory | Suite peak footprint 57.3 GB → 205 MB; suite completes for the first time, 641 passed / 1 failed |

The failing tool was `swiftformat --lint`, not `swiftlint` (which reports
`0 serious` and passes). Plan 0083 diagnosed the wrong tool, and `1d73d71` (#196)
tried to hand-edit braces across 21 files rather than running the formatter. Both
are deleted.

## Root cause of the process hole — measured, not hypothesised

**GitHub Actions cannot allocate runners for this repository.** Every job in
every recent run fails in 2–3 seconds having executed **zero steps**:

```bash
$ gh run list --limit 15 --json conclusion,displayTitle
# every entry: "failure" — #240 through #247, spanning 2026-08-12 to 2026-08-13

$ gh api repos/tonimelisma/Otos/actions/runs/31658884668/jobs
# all six jobs: "conclusion":"failure", "steps":[]  ← no step ever ran
# Workflow YAML, SwiftFormat And SwiftLint, Script Inventory,
# Checkout Sanity, Text Hygiene, Required CI Gate

$ gh api repos/tonimelisma/Otos/commits/<sha>/check-runs
# every check: failure, no output title, no summary
```

A failing check produces step output. Zero steps with a 2-second duration is
runner allocation being refused — the billing/quota class of blocker that
AGENTS.md anticipates.

So the `lint` job did not "miss" the red: **no CI job has executed at all**, so
`lint.sh` never ran remotely for #192–#246. The local `script/verify.sh` was the
only gate, and the agent-authored DoD reports claimed it green without running
it.

That makes this plan's remaining work concrete: restore CI execution, then make
the checks required.

## Stages

### Stage 1 — Restore runner execution

This is an account/repository-settings action, not a code change, and it needs
the repo owner:

1. Check GitHub Actions billing and spending limits for the account
   (Settings → Billing → Plans and usage → Actions). A depleted included-minutes
   balance with no payment method produces exactly this signature.
2. Confirm Actions is enabled and a runner label the workflow requests is
   available (`ci.yml` jobs request `macos-*` and/or `ubuntu-*`; a macOS runner
   consumes minutes at 10× the Linux rate and depletes a free balance fastest).

Verification: re-run the failed workflow and confirm jobs report steps.

Until this is fixed, AGENTS.md's CI waiver applies — but it must be pasted as
evidence on each PR, and local `script/verify.sh` output is the only real proof.

### Stage 2 — Make the checks required, once they run

Enable branch protection on `main` requiring the `ci.yml` jobs to pass before
merge. Without this, a restored CI still would not have blocked #192–#246:
nothing prevented merging past a red check.

This is a repository setting. If the agent cannot set it, say so and give the
owner the exact steps rather than substituting a weaker in-repo check.

### Stage 3 — Align tool versions

Compare CI's installed lint tools to the local ones so a future green CI means
the same thing as a green local run:

```bash
grep -iE 'swiftformat|swiftlint' Brewfile
grep -n -A6 'Install lint tools' .github/workflows/ci.yml
swiftformat --version; swiftlint version
```

Pin CI to the `Brewfile` versions if they differ.

### Stage 4 — Prove the gate blocks

Open a throwaway PR containing one deliberate formatting violation (an unsorted
import in a scratch file). Confirm CI reports failure and that the PR cannot be
merged. Close it without merging, and paste the blocked-check screenshot or
`gh pr view` output into this plan's PR.

A gate nobody has watched fail is not a gate — the same lesson as
`script/check-no-unchecked-sendable.sh:2-4`.

## Verification

- `bash script/verify.sh` green end to end (lint, build, test) once plan 0086
  lands the one remaining test fix.
- CI `lint` job runs on a PR that touches only Swift files.
- A deliberately-red PR is blocked from merging.

## Non-goals and guards

- Do not add `--strict` to `swiftlint`, raise `line_length`, or re-add `error:`
  thresholds to size rules (AGENTS.md keeps size limits as warnings).
- Do not split any file to satisfy `file_length` / `type_body_length`.
- Do not weaken `lint.sh` to make CI pass. The tool was right; the process was
  wrong.
- Do not treat "CI was billing-blocked" as the explanation without evidence.
  AGENTS.md permits a CI waiver only with a pasted billing/quota blocker, and no
  such evidence exists in #192–#246.
