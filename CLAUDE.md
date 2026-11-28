# CLAUDE.md

## What this is

Otos is a native macOS Lightroom-style photo and video manager. The user's filesystem — or, for
an Immich account, its server — is the single source of truth for what media exists and where it
lives; Otos overlays organization, metadata, previews and editing intent on top of media that
stays wherever the user keeps it, including cloud-synced folders. It ships as a signed app that
updates itself with Sparkle from GitHub Releases. Swift 6 (strict concurrency), SwiftUI with
AppKit where needed, GRDB/SQLite, Core ML; Xcode 27, macOS 27.

`docs/architecture.md` is the code map, `docs/requirements.md` the registry of implemented
behavior, `docs/adr/` the decisions, and `docs/design/design-system.md` the design rules
(`docs/index.md` maps them all). More guidance loads when it applies:

- `.claude/rules/` by path: Swift, media bytes and MediaMetadata, persistence, UI and scripts.
- `.claude/skills/` by task: `ci`, `long-checks`, `otos-review`, `dod`, `mac-session`, `release`.

## Working style

- When it is clear what is wanted, do it. Ask only for what only the user can do, or for a real
  product choice nobody has made yet.
- Don't end a turn with a summary announcing the next step, an offer to continue, or a list of
  decisions that block nothing: take the next step.
- Stop only when nothing can move forward without the user, or when what blocks you is
  deliberately protected (a permission, a ruleset, a secret). Then say exactly what is needed.
- Still confirm destructive or irreversible actions outside the normal flow (deleting data,
  rewriting history, changing settings); the normal flow (branch, commit, PR, merge, release) is
  not one of them.
- Live tests (`OTOS_IMMICH_LIVE`, against a real Immich server) run only when the person running
  the session asks, stay read-only, and clean up everything they create in their own teardown,
  even when they fail, and confirm the removal.

## Product invariants

- Originals are read-only and Otos never takes media hostage: it never relocates originals into
  an app-owned library, and everything it derives or authors (catalog, ratings, edits, metadata,
  thumbnails, previews) lives in Application Support, with no sidecar files for identity or
  authored overlay. The user's files change only through explicit, user-initiated operations:
  import (copying media and its existing `.xmp`/`.srt` companions into a library), library
  reorganization (moves within it), export (new files into a folder the user chooses, never
  overwriting), Move to Trash, and card Erase on removable volumes and cameras only. The default
  is that nothing on disk changes. ([ADR 0008](docs/adr/0008-filesystem-source-of-truth-and-overlay-lifecycle.md), [ADR 0022](docs/adr/0022-recoverable-media-deletion.md), [ADR 0038](docs/adr/0038-export.md))
- Each source's own listing is the single source of truth: a folder's or card's filesystem, a
  camera's ImageCapture listing, an Immich account's sync stream. The catalog and every overlay
  are a subordinate, rebuildable projection; when they disagree, the source wins. Otos never
  writes to an Immich server. ([ADR 0046](docs/adr/0046-immich-accounts-as-read-only-sources.md))
- Overlay has one lifecycle: kept as long as the item exists, purged in full only when the item
  is proven deleted (absent from a reachable, fully enumerated root; for an Immich account, a
  deletion the server reports or a completed resync that no longer lists it) or when the user
  removes its root. A temporarily missing original is never a deletion. The one time-based
  removal: a card or camera unseen for 90 days is forgotten. Asset identity is the path; Otos
  invents no durable IDs, content fingerprints or sidecars. ([ADR 0008](docs/adr/0008-filesystem-source-of-truth-and-overlay-lifecycle.md), [ADR 0013](docs/adr/0013-removable-and-device-sources.md))
- The media grid never blanks a thumbnail already displayed for the same on-screen asset in the
  current process; reorders, failed or missing detail reads, nil loads, scrolling, enrichment,
  structural applies and availability churn keep it or replace it only with a newer thumbnail of
  the same asset. ([ADR 0006](docs/adr/0006-catalog-grid-rendering.md))
- Most media lives in cloud-synced folders as possibly-dataless placeholders, so byte-reading
  work never accidentally materializes a file; MediaMetadata, Otos's own library, owns every fact
  read from a file's bytes (`.claude/rules/media.md`). ([ADR 0009](docs/adr/0009-enrichment-storage-and-staleness.md), [ADR 0039](docs/adr/0039-mediametadata-boundary.md))
- Time is never a stand-in for a fact that can be known; every wait on time carries a `time:`
  tag (`deadline`, `backoff`, `schedule`, `measurement`, `poll` or `cadence <measurement path>`),
  checked by `script/time-guard.sh`. ([ADR 0033](docs/adr/0033-time-is-never-a-stand-in-for-a-fact.md))
- The machine's free resources are for the work: never hold work or trade throughput to keep
  Otos's own footprint small; only the machine's conditions hold it. A leak is still a bug.
  ([ADR 0057](docs/adr/0057-background-work-makes-room-for-the-machine.md))
- One user action has one implementation path: buttons, menus, shortcuts, gestures, automation
  hooks and tests call the same owner intent. ([ADR 0004](docs/adr/0004-catalog-ui-ownership.md), [ADR 0032](docs/adr/0032-owner-state-requests-and-intent-ordering.md))
- Otos has exactly one main window, a singleton SwiftUI `Window`, never `WindowGroup`, and no
  seams for more. ([ADR 0004](docs/adr/0004-catalog-ui-ownership.md))
- Otos is unsandboxed: file access is designed around user-selected media roots and normal
  paths, with no App Sandbox or security-scoped bookmarks. ([ADR 0003](docs/adr/0003-library-root-selection-and-access.md))
- Otos is an image and video product: never audio-specific playback, metadata, thumbnails,
  icons, classification or workflows (MED-004). ([ADR 0039](docs/adr/0039-mediametadata-boundary.md))
- Curation is Liked, Not Rated and Disliked; no star ratings, color labels or albums.
  ([ADR 0063](docs/adr/0063-curation-without-ratings-labels-or-albums.md))
- App data (catalog and all overlay) is treated as backed up: no cache eviction, no preview
  pruning. Otos tooling never writes to a user's library, catalog or the installed app's
  settings; experiments that write use generated catalogs. ([ADR 0020](docs/adr/0020-production-data-locations-and-the-developer-smoke-seam.md), [ADR 0035](docs/adr/0035-rendered-stills-and-stored-previews.md))
- User-facing surfaces follow `docs/design/design-system.md`: a UI change that violates a
  `DES-*` rule changes the rule in the same PR or is wrong; deviations from macOS defaults are
  marked `[deviation]` there with their justification.
- A new third-party dependency needs an ADR with alternatives and trade-offs before it is added.
  ([ADR 0001](docs/adr/0001-repository-foundation.md))

## Engineering philosophy

- No compatibility shims. When a structure is wrong, replace it and migrate its callers in the
  same change. Treat the repository as a blank slate: if this were built today, what would it
  look like? Build that, and delete what it replaces.
- The smallest correct design. Simplicity first; measure before optimizing, never optimize on a
  hunch.
- One owner per fact, per mutation and per side effect. Two places that know the same thing will
  disagree.
- Abstractions only at real boundaries (a process, a network, a storage format, a platform), not
  in anticipation.
- Don't guess and don't fabricate: an unknown API, path, value or result is looked up, measured or
  reported as unknown.
- You own the repository. Nothing is "pre-existing" or someone else's problem, and red CI is never
  waived: it is fixed first.
- Comments and docs describe current behavior and why it is that way, never its history.
- Engineering effort is free: diff size, file count and schema migrations are never reasons to
  choose a design, and there are no quick fixes or follow-ups deferred to save work. Free effort
  is not license to gold-plate: the answer is still the smallest correct design.
- Time is not free: a commit's whole check, local and CI together, finishes within five minutes
  of the commit being ready, six to nine when it changes Swift (ADR 0044 items 13–18). A change
  that would break that budget is redesigned until it fits, or the final report says why, with
  the measurements.
- Performance comes after correctness, simplicity and clear ownership. No caches, pools,
  background pipelines, generalized abstractions, split schemas or scale machinery before a
  measurement or a verified requirement proves the simple path insufficient.
- Do not fabricate user-visible or domain facts: unknown dates, paths, provider state, progress,
  counts, diagnostics and capabilities stay unknown or explicitly qualified until proven.

## Engineering practices

- Test first. A change in behavior starts with a test that fails without it.
- Every bug, CI failure and review finding gets a regression test, seen failing before the fix;
  quote its red output in the PR.
- The instrumentation flywheel, every increment:
  - Never guess a bug's cause. If the logs and metrics can't explain it, add the instrumentation
    first, so this occurrence or the next one is diagnosable, then fix.
  - Never guess at performance: measure, keep a baseline, optimize, and report before and after.
  - Even when nothing is blocked, review the instrumentation on every path you touched: add what
    was missing, remove what is noise.
- Tests are hermetic: temporary directories and fixtures, never the developer's real data, config
  or accounts.
- Tests assert observable behavior or public owner boundaries. They never read a source file as
  text and assert on substrings (CI guards this), and never read a file through `#filePath`; they
  read the checkout from `SourceTree.root`.
- Prefer Apple-native technologies (Swift, SwiftUI, Image I/O, AVFoundation, Core Image, OSLog,
  Instruments). Prefer SwiftUI; use AppKit only when SwiftUI cannot provide the capability or meet
  a verified responsiveness or performance requirement.
- SwiftLint's size limits (`file_length`, `type_body_length`) are warnings: cohesion sets type
  boundaries; do not split a cohesive type to satisfy them.
- A performance PR adds a deterministic twin test for its win and says "measured in the next
  weekly run" (ADR 0043).

### Architecture standards

- SwiftUI views are small and passive: they render provided state, hold local control state,
  bind controls and call explicit owner intents. They never subscribe to catalog streams,
  coordinate projection invalidation, call SQLite or orchestrate scanning
  (`script/guard-view-passivity.sh`).
- Prefer direct, concrete designs. Add a layer, cache, protocol, worker queue, normalized table or
  pipeline only when it removes current complexity or a verified requirement needs it. Protocols
  belong at real substitution boundaries.
- Prefer explicit ownership over ambient global state, at the narrowest correct scope.
- Persistence has one current owner with an explicit schema/version policy, and refuses an
  unsupported or future schema safely. Rebuildable cache state is overlay, never a second source
  of media truth (`.claude/rules/persistence.md`).
- `.claude/rules/swift.md` holds the rules for Swift work: the catalog's ownership split,
  concurrency (ADR 0032), instrumentation, code smells and file guides.

## Commands

```sh
script/check.sh                          # everything CI checks, in one command (run before every push)
script/check.sh --only <Suite>           # the same gates and build, only the named suites (iteration, never evidence)
"$(script/lint-tools.sh swiftformat)" .  # the formatter (pinned and checksummed by script/lint-tools.sh)
script/lint.sh                           # SwiftFormat and SwiftLint
script/process-check                     # requirements, Validates tags and doc links agree
script/requirements-authority-check.sh   # the requirement registry's own rules
script/stage start | pre-merge <PR> | post-merge <PR>
```

- `script/check.sh` runs the seconds-long gates first, then the build and tests; it writes its
  whole log to `logs/check/`, names it on its first line (`op=check.log`), and prints each
  stage's duration. A diff confined to docs, Markdown, `.github/`, `.claude/`, lint config and
  scripts off the build path takes the **static** tier (every gate, no build or tests); anything
  else takes the **full** tier (ADR 0044). Never run `verify.sh`, `test.sh` or `build.sh`
  directly; where Xcode is installed, run `check.sh` in the background and watch it
  (`long-checks` skill).
- Signing: the project reads `$(OTOS_DEVELOPMENT_TEAM)` from the environment or
  `~/.config/otos/development-team`; without it a build is signed to run locally. Never commit the
  team ID, personal media or private paths: the repository is public.
- Performance is measured weekly (ADR 0043): `check.sh` prints one `op=perf.status` line;
  `verdict=elsewhere` in a cloud VM or on CI needs nothing; on a Mac, `due` and `fail` are
  handled as the `mac-session` skill says. Its targets hold for a reference library of 160,000
  items, which the run generates.

### Where sessions run

- **The cloud session is the default, and CI is the verification.** A cloud session runs in an
  Ubuntu VM (`CLAUDE_CODE_REMOTE=true`) with no Xcode; `script/cloud-setup.sh` (SessionStart)
  installs what the gates call. A static-tier tree is verified there in full; a full-tier tree
  ends `check: INCOMPLETE` (`phase=gatesOnly reason=noXcode`) and its verification is CI's run on
  GitHub's `xcode-27` runner (ADR 0061). The VM's proxy refuses GraphQL, tag pushes and branch
  deletion: read CI and merge through REST (`ci` skill).
- **A local session on any Mac with Otos installed** may also build and test natively, run the
  visual and end-to-end checks on generated libraries, and inspect the installed app read-only.
  It works in its own worktree with dev builds (`net.melisma.Otos.dev`), never installs (Sparkle
  is the only installer, ADR 0059), and verifies through the same CI run. Live checks on real
  data happen only when the person running the session asks (`mac-session` skill).
- What the installed app ran into reaches a session as a Help ▸ Export Diagnostics… folder
  (ADR 0060).

## Where docs live

- `docs/index.md` maps every doc. Requirements live in `docs/requirements.md`: stable IDs
  (`ARC-` architecture and system, `APP-` product surface, `ENR-` enrichment, `MED-` media and
  originals), one EARS sentence each, current behavior only, each `[verified]` by a test tagged
  `Validates: <ID>` or `unverified: <why>`. No process, workflow or tooling rows. Future work
  lives in GitHub issues, not in docs.
- `docs/architecture.md` says how the code is built and why; `docs/adr/NNNN-title.md` records each
  decision (superseded, never deleted; new ones from `docs/adr/0000-template.md`);
  `docs/lessons.md` holds rules learned and open problems, and is pruned when they are resolved.
- `docs/design/<surface>.md` specifies each user-facing surface and starts with `GOVERNS:`, the
  code it specifies; `docs/design/design-system.md` holds the `DES-*` rules.
- `docs/research/` holds every research pass, POC and benchmark, dated, with sources and
  conclusions, written in the increment that relies on it. Measurements on real data are
  described by a reference library's size, never by whose it was.
- Update the docs and this file in the same PR as the code they describe. Guidance that changes
  product direction, behavior, architecture or workflow goes to its home in the same increment:
  implemented behavior to requirements, a decision to an ADR, an unbuilt idea to an issue.
- Boundaries: no per-increment spec files; no plan, roadmap or ledger files; code reviews and
  final reports live on the PR.

## Increment lifecycle

1. **Start**: `script/stage start`. Anything red on main or in the last scheduled run, and any
   unanswered review comment on recent PRs, is fixed before new work. Read the open issues.
2. **Ready**: write the Definition of Ready in the PR body: the problem, requirement IDs or
   issue, acceptance criteria, what is out of scope.
3. **Test first**, then implement with the instrumentation flywheel.
4. **Verify** with the one verify command; it must be green before pushing.
5. **Docs** (requirements, architecture, ADRs, lessons, this file) in the same PR.
6. **Land**: PR, wait for `CI gate`, squash-merge, which releases (see Git, CI and PRs).
7. **Report**: after the merge, one PR comment with the Definition of Done checklist and the final
   increment report (below).

A plan that spans several increments lives in a GitHub tracking issue with a checklist, never in
a file. Never committed: per-PR report or readiness files, session state or resume files, ledgers
of merged PRs. That information belongs in the PR and its comments.

## Git, CI and PRs

- One branch per increment, cut from a fresh `origin/main`, named `feat/`, `fix/`, `docs/`,
  `chore/`, `refactor/` or `perf/` plus a short topic. Never reuse a branch after its PR merged;
  never name a branch for the tool that wrote it. Never discard user work: remove a worktree,
  branch or stash only when it is proven merged or patch-equivalent to `main`.
- Every change lands through a PR whose body fills `.github/pull_request_template.md`. CI checks
  the body, and that a PR titled `fix...` changes a test.
- `CI gate` is the one required check: a job that needs every other job (the Ubuntu gates, lint,
  Process, and the three `Build And Test (Xcode 27)` shards). Any edit after a run, even a
  comment, needs a new one. Wait for it (`script/stage pre-merge <PR>`), and fix every failure;
  never waive a failure, syntax error, missing tool or flake, and never skip, disable or
  quarantine a test to get green. A red `main` blocks merging anything that could change build or
  test results except its fix. A job GitHub could not run is not a failure (`ci` skill).
- The ruleset requires a PR to be up to date with `main`. When `main` moved, update the branch
  with `gh api -X PUT repos/tonimelisma/Otos/pulls/<N>/update-branch` and wait for the new head's
  `CI gate`; `script/stage pre-merge` does both. A push to `main` is then the exact tree its PR
  tested, so CI there skips the shards (ADR 0062).
- Squash-merge as soon as `CI gate` is green, without asking: in a cloud session with
  `gh api -X PUT repos/tonimelisma/Otos/pulls/<N>/merge -f merge_method=squash -f sha=<head sha>`
  (`script/stage post-merge <PR>` does this); locally with `gh pr merge --auto --squash`. Opening
  a PR is not a stopping point: continue through merge, cleanup and the final report.
- Merging to main releases; nobody tags or publishes by hand. `Release` starts on the push to
  `main`, builds, signs and launch-checks the app beside CI, and publishes `v<x.y.z>` (the next
  patch of `MARKETING_VERSION`'s series; a new series is one PR changing `MARKETING_VERSION`;
  `CFBundleVersion` is the commit count) once that commit's `CI gate` passed, and only when
  `Otos/`, `OtosKit/`, `Otos.xcodeproj/` or `Config/` changed. The installed app installs it by
  Sparkle within the hour (`release` skill, ADR 0059, ADR 0062).
- The weekly runs: CI on `main` every Tuesday; Capture The App (every view on a generated
  library) and Repeat A Suite (the suites in `docs/lessons.md` that have flaked) every Wednesday.
  A red weekly run is fixed first.
- The cloud sessions' GitHub proxy refuses tag pushes, branch deletion and GraphQL: use the REST
  API (`gh api`), and leave branch deletion to GitHub's delete-on-merge and the Branch cleanup
  workflow.
- Commit messages: an imperative subject saying what changed; the body says why.

### Review

Review from the diff, not the author's intent, with the `otos-review` skill: lens A
(implementation fidelity), lens B (architecture) and the questions no lint can ask; lens C for a
user-facing surface is in `.claude/rules/ui.md`. Rank findings by severity, each a concrete
failure scenario with `file:line`. A confirmed correctness bug or a lost invariant or requirement
blocks merge; smells and lens-B notes are logged on the PR, and every PR notes the code smells
observed (`None observed` when true). For hot-path or store work, suggest the requester run
`/code-review ultra`; it is theirs to trigger.

## Privacy review

Before every commit, read your own staged diff (`git diff --cached`) and remove anything private
about the maintainer, their family or their computers: people's names, addresses, personal email
addresses and accounts, hostnames, home-directory paths, IP addresses, tenant, client or vault
IDs, real personal documents or photos. Use neutral stand-ins in tests and examples. There is no
list of private terms to check against: judge the diff.

## Definition of Done

An increment is done when every line holds; the final report marks each ✅ or ❌ with evidence:

- [ ] Start stage clean: main CI, the last scheduled run and recent review comments were green or
      fixed first.
- [ ] Tests first; the regression test's red output before the fix is quoted.
- [ ] The verify command is green, and CI is green on the final commit.
- [ ] Traceability and doc checks (`script/process-check`, `script/pr-check`) are green.
- [ ] Docs and CLAUDE.md are updated in the same PR.
- [ ] Instrumentation reviewed on touched paths: what was added, what removed, or why it is
      adequate.
- [ ] Privacy review done on every commit's staged diff.
- [ ] Every review thread is answered or resolved.
- [ ] Merged; main CI green; the release it produced is linked.
- [ ] Clean up: only main and open PRs' branches remain on the remote; the working tree is clean.

The agent looks at what it shipped: tests prove the code, only a look proves what a user sees.
A cloud session reads the window captures CI makes of every full-tier change, light and dark, on
generated media (`app-captures-<run>`, `ci` skill); a session on a Mac also looks at the dev app
and, read-only, the installed app (`mac-session` skill). Never make the requester launch the app,
operate the UI or inspect visuals a condition of done: when a check cannot run where the agent
is, record the limitation, the evidence gathered instead and the remaining risk, and finish.
`script/dod-report.sh` generates the mechanical checklist; the `dod` skill holds the look.

### Final increment report

One PR comment after the merge, with these parts:

1. **Done / not done**: what the increment delivered, and anything left out.
2. **Definition of Ready**: as written, and whether it held.
3. **Requirements, ADRs and docs**: IDs added, changed or retired; ADRs; docs touched.
4. **Design decisions**: each with the alternatives considered and why they lost.
5. **Verification evidence**: commands, CI run links and durations, release link.
6. **Regression test**: name and red output before the fix (or "no bug fixed").
7. **Diagnosis**: for a bug, the root cause and how it was established.
8. **Instrumentation**: added, removed, and gaps still open.
9. **Performance**: before and after numbers, or "not touched".
10. **Privacy review**: done on every commit; anything removed.
11. **Smells**: what looked wrong but was out of scope.
12. **Follow-ups**: each filed as an issue, linked.
13. **Definition of Done**: the checklist above, each line ✅ or ❌ with evidence.
