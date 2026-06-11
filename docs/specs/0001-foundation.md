# Spec: Repository Foundation

## Problem

Otos needs a strict foundation before product features are added. The repo is a
fresh Xcode SwiftUI macOS app with default template source, unit tests, UI tests,
and four user-provided media files in the repository root.

## Scope

In scope:

- Move media fixtures into the test fixture tree.
- Add AGENTS.md, setup docs, verification scripts, fast CI, lint configs, PR
  template, shared Xcode scheme, and Codex run config.
- Enforce full Xcode selection and Swift 6 strict concurrency settings.
- Add a minimal instrumentation facade.
- Create a private GitHub remote named `origin`.

Out of scope:

- Catalog persistence implementation.
- Real media browsing UI.
- Distribution hardening beyond current sandbox-oriented project settings.
- Preview pruning or cache policy.

## Architectural Alternatives

### Minimal AGENTS.md Only

Pros:

- Smallest change.
- Easy to review.

Cons:

- Leaves CI, scripts, fixture provenance, and instrumentation conventions
  undefined.
- Future agents would need to rediscover basic setup rules.

Failure modes:

- The project drifts before the first feature.
- CI and local verification diverge.

### Complete Foundation Files

Pros:

- Makes the repo runnable, verifiable, and reviewable from the first increment.
- Captures the no-shim, spec-first, concurrency, and instrumentation rules in
  code-adjacent files.
- Gives future work a repeatable PR checklist and local evidence path.

Cons:

- Larger initial diff.
- Requires maintaining scripts and CI as Xcode beta changes.

Failure modes:

- Remote CI may be temporarily unable to run because this private repo can
  exhaust GitHub Actions quota.
- Hosted GitHub runners may not have the required Xcode beta, so Xcode 27
  build/test proof must remain local until a real runner exists.
- Xcode beta path changes may require a script update.

## Selected Approach

Use the complete foundation. The larger change is the correct architecture
because it gives every later feature a clear workflow, local verification path,
and observability standard.

## Interfaces And Data Flow

- Test fixtures live under `OtosTests/Fixtures/Media`.
- Local automation enters through `script/verify.sh` and
  `script/build_and_run.sh`.
- Runtime diagnostics enter through `OtosLog` and `OtosSignpost`.
- Remote CI is a fast gate for checkout, workflow YAML, text hygiene, script
  inventory, and lint.
- Xcode build/test verification uses the shared `Otos` scheme locally through
  `script/verify.sh`.

## Instrumentation

The foundation adds OSLog and OSSignposter handles for required categories. New
features must add operation-specific logs and spans through that facade.

## Acceptance Criteria

- Root media files are removed from the repo root and present in
  `OtosTests/Fixtures/Media`.
- `.DS_Store` is ignored.
- `script/verify.sh` fails clearly when full Xcode is not selected.
- Remote CI does not select Xcode 27 or run Xcode build/test until a real Xcode
  27 runner exists.
- `xcodebuild -list -project Otos.xcodeproj` shows the shared `Otos` scheme.
- Private GitHub remote `origin` points at `tonimelisma/Otos`.

## Verification

- `script/lint.sh`
- `script/build.sh`
- `script/test.sh`
- `script/test-ui.sh` when the environment can enable macOS UI automation
- `script/verify.sh`
- `script/ci-text-hygiene.sh self-test`
- workflow YAML parsing
- `gh repo view tonimelisma/Otos --json name,visibility`
