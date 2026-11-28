# 0062. The release overlaps CI, and main skips a tree its pull request tested

- Status: accepted
- Date: 2026-11-28

## Context and problem

A merge took 19 to 27 minutes to reach the installed app (merges of 2026-11-28: CI on main
12.6 and 20.3 minutes, then the release 6.4 and 6.6 minutes after it). Two costs were
avoidable. CI on `main` rebuilt and re-ran the whole suite on a tree that was already built
and tested on its pull request, and the release waited for that run to end before it started
its own build, which shares nothing with CI's. The aim is 6 to 8 minutes from merge to a
published release without publishing anything CI has not passed (ADR 0059).

## Decision drivers

- Nothing is published before `CI gate` passed on the exact tree that ships.
- No verification is lost: every tree that reaches `main` was built and tested by CI.
- One owner per side effect: the build caches are saved in one place.
- Measured, not guessed: each release stage prints its seconds.

## Considered options

### Keep the release after CI, and make CI faster

- Good: no change in what triggers the release.
- Bad: the release's 6-minute build still starts only after CI; the floor is CI plus 6 minutes.
- Failure modes: none new.

### Start the release on the push and publish after `CI gate` (chosen)

- Good: the release's build, packaging and launch check run beside CI; it waits only for the
  gate, then publishes.
- Bad: a release job runs for a push whose CI then fails (it publishes nothing and fails).
- Failure modes: the gate never finishes (the wait gives up after 130 minutes and the job
  fails); CI was cancelled by a newer push (the release is skipped, the newer push releases).

### Skip CI's shards on main when the tree equals a tested pull-request head (chosen)

- Good: a push to main costs the Ubuntu jobs only, about two minutes to `CI gate`.
- Bad: relies on pull requests being up to date with main when they merge.
- Failure modes: a merge whose tree differs from its head (a stale branch, a direct push the
  ruleset would refuse) is detected by the tree hash and runs every shard.

## Decision

1. `main`'s ruleset requires a pull request to be up to date with `main`
   (`strict_required_status_checks_policy`). A session updates a stale branch with
   `PUT repos/<owner>/<repo>/pulls/<N>/update-branch` and waits for the new head's `CI gate`
   (`script/stage pre-merge` does both). The squash merge's tree is then the head's tree.
2. On a push to `main`, CI's `Already Tested` job (`script/ci-tested-tree.sh`) reads the
   commit's merged pull request, compares the two trees by hash, and reads the newest
   `CI gate` of GitHub Actions on the head. Only when the trees are equal and that gate
   succeeded are the `Build And Test` shards skipped. A pull request, the weekly run and a
   dispatch always run them.
3. `Release` starts on the push to `main`. `script/release.sh` builds, signs, packages and
   launch-checks while CI runs, then waits for that commit's `CI gate` (`script/ci-gate.sh`)
   and publishes only on success. The `release` environment admits only `main`.
4. The Build Cache workflow, on every push to `main`, builds the tests from the restored
   caches and saves them, and saves the resolved Swift packages alone under their pins, which
   the release restores. CI's shards only restore.
5. The disk image is compressed with LZFSE (`ULFO`) instead of zlib at level 9.

## Consequences

- Merge to release is bounded by the release job itself (its build, about three minutes)
  instead of CI plus the release.
- A merge's own CI on `main` no longer proves the merge again; the pull request's run is the
  proof, and the weekly run re-runs everything on `main`.
- A pull request that falls behind `main` must be updated and re-verified before it merges.

## Confirmation

- `script/ci-tested-tree.sh self-test` (a fast gate and CI's repo-shape job) holds the skip
  decision: only a push to main whose tree equals a head with a green gate skips.
- The ruleset's required check `CI gate` with the strict policy; `script/stage pre-merge`.
- Each release logs `op=release.stage` seconds and `op=ci.gate outcome=success` before
  `op=release phase=published`.

## Retirement proof

Retired only if a merge can reach `main` with a tree no `CI gate` passed on (for example a
merge queue that builds merge groups), or if CI on `main` becomes as fast as the skip.

## Reversal plan

Set the release back to `workflow_run` of `CI`, drop the `Already Tested` job and the Build
Cache workflow, and save the caches from shard 1 again; turn off the ruleset's strict policy.
One pull request; nothing else depends on it.
