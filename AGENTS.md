# Otos Agent Instructions

Otos is a native macOS Lightroom-style application. The user's filesystem — or, for
an Immich account, its server — is the single source of truth for what media exists
and where it lives. Otos overlays organization, metadata, previews, and editing intent on
top of user-owned media that stays on disk wherever the user chose to keep it, including
cloud-synced folders. Originals are read-only, and Otos never takes the user's media
hostage: it never relocates originals into an opaque app-owned library, and nothing it
derives or authors (catalog, ratings, edits, metadata, thumbnails, previews) is written
into the user's media folders.

`docs/architecture.md` is the current-state code map. `docs/requirements.md` is the
authoritative registry of implemented behavior. `docs/adr/` justifies the architecture.
`docs/design/design-system.md` is the authoritative registry of design rules for
user-facing surfaces; per-screen specs live beside it in `docs/design/`. Read those for
detail; this file is how to work here.

More guidance loads when it applies:
- `.claude/rules/` loads by path: Swift, media bytes and MediaMetadata, persistence, UI
  and scripts.
- `.claude/skills/` loads by task: `ci`, `long-checks`, `otos-review`, `dod`,
  `mac-session` and `release`.

## Taylor's Standing Rules

These are the owner's own rules. They are kept here because a cloud session never reads
his `~/.claude/CLAUDE.md`.

- When it is already clear what Taylor wants, do it. Never ask whether to do it, how to
  do it, or which piece to do first, and never end a turn with a go-ahead question or a
  "Yes, do it" button. Ask only for what only Taylor can do (his accounts, devices,
  approvals) or a real product choice he has not made yet.
- Never end a turn while any item Taylor asked for can still move forward without him.
  When one item is blocked (the Mac locked, something only he can do), go on to the
  next unblocked one; stop only when every item is done or truly blocked, and list just
  the Taylor-only steps at the end.

## Non-Negotiable Principles

- Treat this repository as a blank-slate architecture. Do not add compatibility shims. If
  a structure is wrong, replace it with the right structure; do not patch around bad
  boundaries.
- **Engineering effort is free. Never take a shortcut.** Every engineering decision
  assumes effort costs nothing, so effort, diff size, file count, and schema migrations
  are never reasons to choose a design. When a code smell or anything iffy appears, stop
  and ask: if this were being built from a blank slate today, what approach and
  architecture would it have? Build that, and delete what it replaces. No quick fixes, no
  call-site patches for a type-level defect, no "good enough for now", no follow-up
  deferred to save work. Free effort is not license to gold-plate: the blank-slate answer
  is still the smallest correct design for the verified requirements.
- **Time is not free.** This is the one exception to the rule above. Measure how long
  every check, build, test run and CI job takes.
  - A commit's whole check, local and CI together, finishes within five minutes of the
    commit being ready (owner, 2026-11-26; ADR 0044 items 13–18). A commit that changes
    Swift may take six to nine, because its module recompiles on CI's three cores (owner,
    2026-11-26: "6-9 is fine").
  - A change that would break that budget is redesigned until it fits.
  - When it cannot fit, the final report says why, with the measurements.
- Keep the app as simple as possible. Prefer the smallest correct model, owner, schema,
  state flow, and UI that satisfies verified requirements. Simplicity is a requirement,
  not a shortcut.
- Performance comes after correctness, simplicity, and clear ownership. Measure before
  optimizing: you cannot tell where a program spends its time, n is usually small, and
  simple algorithms on the right data structures win (Rob Pike's rules). No caches, pools,
  background pipelines, generalized abstractions, split schemas or scale machinery before
  measurement or a verified requirement proves the simple path insufficient.
- The machine's free resources are for the work. Never hold work or trade throughput to
  keep Otos's own footprint small; only the machine's conditions hold it (ADR 0057). A
  leak, memory that never comes back, is still a bug.
- Do not guess. Inspect the repo, read the relevant APIs, and verify claims with code,
  docs, tests, profiling, or runtime evidence.
- The owner's production data is read, never changed (ADR 0020):
  - his libraries, catalog and Immich server;
  - the installed app's settings.

  Read-only work on it is expected from a session on his Mac, and nobody asks first; the
  `mac-session` skill lists what that covers. A cloud session never reaches his Mac.
  Experiments that write use generated catalogs shaped like his.
- Do not fabricate user-visible or domain facts. Unknown dates, paths, provider state,
  progress, counts, diagnostics, and capabilities stay unknown or explicitly qualified
  until proven.
- Time is never a stand-in for a fact that can be known. If something can report that
  work finished, state changed, or an item is ready, wait on that report. Where nothing
  can, the wait carries a `time:` tag (`deadline`, `backoff`, `schedule`, `measurement`,
  `poll`, or `cadence <measurement path>`), which `script/time-guard.sh` checks (ADR 0033).
- One user action has one implementation path. Buttons, menus, shortcuts, gestures,
  automation hooks, and tests call the same owner intent.
- Each source's own listing is the single source of truth: a folder's or card's
  filesystem, a camera's ImageCapture listing, an Immich account's sync stream (ADR 0046).
  The catalog and every overlay are a subordinate, rebuildable projection; when they
  disagree, the source wins and the catalog reconciles. Otos never writes to an Immich
  server.
- Otos never takes media hostage. Everything it derives or authors lives in Application
  Support, and it generates no sidecar files for identity or authored overlay.
  - The user's files change only through explicit, user-initiated file operations:
    - import, which copies media and its existing `.xmp` / `.srt` companions into a
      library;
    - library reorganization, which moves them within it;
    - export, which writes new files into a folder the user chooses and never
      overwrites one;
    - Move to Trash;
    - card Erase, on removable volumes and cameras only.
  - The default is that nothing on disk changes.
- Overlay has one lifecycle (ADR 0008). Every overlay for an item is kept as long as the
  item exists.
  - It is purged in full only when the item is proven deleted, or when the user removes
    its root. Proven deleted means:
    - absent from a reachable, fully enumerated root; or
    - for an Immich account, a deletion the server reports, or a completed resync that no
      longer lists it.
  - A temporarily missing original is never a deletion.
  - The one time-based removal: a card or camera unseen for 90 days is forgotten (ADR 0013).
  - Asset identity is the path. For a source whose originals Otos stages, the path is
    named by the source's own ID. Otos invents no durable IDs, content fingerprints, or
    sidecars.
- The media grid never blanks a thumbnail already displayed for the same on-screen asset
  in the current process. A tile may show placeholder content only before that asset's
  thumbnail has ever decoded in this process. After that, every one of these keeps the
  thumbnail, or replaces it only with a newer thumbnail of the same asset:
  - reorder-only applies;
  - detail-query failures and missing detail rows;
  - nil thumbnail loads;
  - scrolling and enrichment;
  - structural applies and availability churn.
- Otos is an image/video product. Never add audio-specific playback, metadata,
  thumbnails, icons, classification, or workflows.
- Otos is unsandboxed. Design file access around user-selected media roots and normal
  filesystem paths: no App Sandbox, security-scoped bookmarks or sandbox-driven access.
- Otos has exactly one main window, a permanent invariant: a singleton SwiftUI `Window`,
  never `WindowGroup`, and no seams for more.
- User-facing surfaces follow `docs/design/design-system.md`. A UI change that violates a
  `DES-*` rule either changes the rule in the same PR or is wrong. Deviations from macOS
  defaults are marked `[deviation]` there with their justification.

## Platform And Product Baseline

- Target the repo's Xcode beta (Xcode 27, macOS deployment target 27.0). Prefer
  Apple-native technologies (Swift, SwiftUI, Image I/O, AVFoundation, Core Image, OSLog,
  Instruments, filesystem APIs). Prefer SwiftUI; use AppKit only when SwiftUI cannot
  provide the capability or meet a verified responsiveness/performance requirement.
- A third-party dependency needs an ADR with alternatives and tradeoffs before it is
  added.
- App data (catalog and all overlay) lives in Application Support and is treated as
  backed up: no cache eviction, no preview pruning.
- Most media lives in cloud-synced folders as possibly-dataless placeholders: their
  bytes download when read, so byte-reading work never *accidentally* materializes a file
  (ADR 0008, ADR 0009). MediaMetadata, Otos's own library, owns every fact read from a
  file's bytes (ADR 0039). `.claude/rules/media.md` holds both rules in full.

## Architecture Standards

- SwiftUI views are small and **passive**: they render provided state, hold local control
  state, bind controls, and call explicit owner intents. They never subscribe to catalog
  streams, coordinate projection invalidation, call SQLite, or orchestrate scanning.
- Prefer direct, concrete designs. Add a layer, cache, protocol, worker queue, normalized
  table, or pipeline only when it removes current complexity or a verified requirement
  needs it. Protocols belong at real substitution boundaries.
- Prefer explicit ownership over ambient global state, at the narrowest correct scope.
- Persistence has one current owner with an explicit schema/version policy, and refuses an
  unsupported or future schema safely. Rebuildable cache state is overlay, never a second
  source of media truth.
- `.claude/rules/swift.md` holds the rules for Swift work: the catalog's ownership split,
  concurrency (ADR 0032), instrumentation, code smells and file guides.
  `.claude/rules/persistence.md` holds the migration rules.

## How A Session Works

A cloud session is the normal way to work, and it needs nothing else: GitHub's `xcode-27`
runner is the Mac that builds, tests and releases (plan 0118). A session on the owner's
Mac is optional, and nothing waits for one.

- **One command: `script/check.sh`.** It runs the seconds-long gates first, then the
  build and tests. It writes its whole log to `logs/check/` and names it on its first line
  (`op=check.log`), and it prints each stage's duration.
  - A diff confined to docs, Markdown, `.github/`, `.claude/`, lint config and scripts off
    the build path takes the **static** tier: every gate, and no build or tests.
  - Anything else takes the **full** tier (ADR 0044).
  - `script/check.sh --only <Suite>` (repeatable; a suite is a test type's name) runs the
    same gates and build but only the named suites. It is iteration feedback, never
    verification.
  - `script/hooks/guard-long-checks.sh` refuses `verify.sh`, `test.sh` and `build.sh`
    directly. Where Xcode is installed it also refuses a foreground `check.sh`; the
    `long-checks` skill says how to watch one.
- **Verification is CI on the PR's final commit, wherever the session runs:** the three
  `Build And Test (Xcode 27)` shards, read together as `Required CI Gate`. Any edit after
  a run, even a comment, needs a new one. The `ci` skill reads, watches and reproduces CI.
- **Format with** `"$(script/lint-tools.sh swiftformat)" .`. `script/lint-tools.sh` pins
  SwiftFormat and SwiftLint and checks their checksums.
- **Signing.** The project reads `$(OTOS_DEVELOPMENT_TEAM)` from the environment or the
  Mac's `~/.config/otos/development-team`; without it a build is signed to run locally.
  Never commit the team ID, personal media or private paths: the repository is public.
- **Performance is measured weekly** (ADR 0043). `check.sh` prints one `op=perf.status`
  line. In the VM or on CI it reads `verdict=elsewhere`, which needs nothing. On the Mac,
  `due` and `fail` are handled as the `mac-session` skill says. Nothing else measures per
  PR. A performance PR adds a deterministic twin test for its win and says "measured in
  the next weekly run".
- **Tests** assert observable behavior or public owner boundaries. They never read a file
  through `#filePath`; they read the checkout from `SourceTree.root`.

### Cloud Sessions

A cloud session runs in an Ubuntu VM (`CLAUDE_CODE_REMOTE=true`) with no Xcode, macOS or
display, and never reaches the owner's Mac. `script/cloud-setup.sh` (SessionStart; run it
by hand in a session with several repositories) installs what the gates call.

- A static-tier tree is verified in full there. A full-tier tree ends `check: INCOMPLETE`
  (`phase=gatesOnly reason=noXcode`) and its verification is CI's run. `op=lint.partial`
  (SourceKit rules CI's Mac checks) and `op=perf.status verdict=elsewhere` are expected.
- The VM's proxy refuses GraphQL (every `gh pr …` fails), tag pushes, remote branch
  deletion, and REST ref and release writes: read CI through REST (`ci` skill), open and
  merge PRs with the GitHub MCP tools. A full-tier change merges only on a green
  `Build And Test` run. No session needs to delete a branch: GitHub and `Branch Sweep` do
  ("Git, CI, And Pull Requests").
- Steps that need the owner's Mac (the look at his library, the weekly run, profiling, his
  installed app's logs, the evaluations and Core ML conversions on his private data) never
  block an increment; the final report lists the ones it would benefit from as
  non-blocking owner notes. What the installed app ran into reaches a session when the owner
  hands over a Help ▸ Export Diagnostics… folder (ADR 0060).

### Sessions On The Mac

A session on the Mac is one the owner starts from Claude Code on the Mac itself.
- It develops in a dedicated git worktree, with dev builds (`net.melisma.Otos.dev`, their
  own Application Support) against generated catalogs.
- It never installs. Sparkle is the only installer (ADR 0059), so the installed app is
  always a build CI published.
- It verifies through the same CI run.
- What it adds is read-only: his library, the installed app's logs, the weekly run,
  profiling, lldb, and the evaluations. The `mac-session` skill holds its procedures.

## Documentation

Documentation is organized around **current truth**, not increments. Each kind has one
home:

- **`docs/requirements.md`**: the authoritative registry of implemented product and system
  behavior. Rows have a stable ID and map to the source and tests that implement and
  verify them. It holds current state only, with no future ideas and no process rows.
  Every behavior change updates its rows in the same PR.
- **`docs/adr/`**: one architectural decision per ADR (context, decision, rejected
  alternatives, consequences), each naming what it owns and defers. Supersede or rewrite
  an ADR when a decision changes; never append increment history.
- **`docs/architecture.md`**: the one-page current-state code map. Update it when
  ownership or dataflow changes.
- **`docs/research/`**: every research pass, POC and benchmark, dated, with sources and
  conclusions, written in the increment that relies on it.
- **`docs/plans/`**: active plans, numbered. Delete a plan when its work is fully done.
- **`docs/product/roadmap.md`**: a non-authoritative idea pile. It guides work only when
  the owner asks for roadmap input.
- **Code reviews and DoD reports** live on the PR, never in the repo tree.

When the owner gives guidance that changes product direction, behavior, architecture or
workflow:
- Capture it in its home in the same increment: implemented behavior goes to
  requirements, a decision to an ADR, an unbuilt idea to the roadmap or a plan.
- Restate the non-trivial parts in the final report, so he can correct them. Do not hold
  the work to ask first.

### Boundaries (do not let these regress)

- No `docs/specs/` or per-increment spec files.
- No process, workflow, or tooling rows in `docs/requirements.md`.
- Tests that read source files as text and assert on substrings are forbidden (CI guards
  this).
- SwiftLint size limits (`file_length`, `type_body_length`) are warnings. Cohesion sets
  type boundaries; do not split a cohesive type to satisfy them or re-add `error:` limits.
- Comments describe current mechanics and why a boundary exists. They never narrate
  syntax, record history, or compare with removed code.

## Git, CI, And Pull Requests

- Use the branch the harness names; otherwise a conventional prefix (`feat/`, `fix/`,
  `refactor/`, `docs/`, `chore/`, `research/`). Never discard user work: remove a
  worktree, branch or stash only when it is proven merged or patch-equivalent to `main`.
- **No branch outlives its work on GitHub.** A session never deletes a remote branch; it
  keeps GitHub from holding one that has no open PR:
  - GitHub deletes a PR's head branch when the PR merges (the repository's "Automatically
    delete head branches", which stays on).
  - A branch is pushed only when it holds a commit for a PR. After a branch's PR merges,
    restart it from `main` locally and push it again only with the next PR's first commit,
    whatever a harness says about pushing a restarted branch. A push after the merge
    re-creates the branch GitHub just deleted.
  - Nothing is pushed to a merged PR's branch except as the start of a new PR, opened in
    the same turn.
  - `Branch Sweep` (`.github/workflows/branch-sweep.yml`) deletes any branch holding no
    commit `main` lacks, on every branch creation and every push to `main`. A branch with
    work is never swept: it is landed through a PR, or named to the owner.
- Changes go through PRs, with your own work held to the same review bar. Before opening
  one, scan the last five PRs for unresolved review comments, claim each and answer it
  (doc-only increments skip this).
- A CI job that ran and failed always blocks: never waive a failure, syntax error,
  missing tool or flake, and never skip, disable or quarantine a test to get green. A red
  `main` blocks merging anything that could change build or test results except its fix.
  A job GitHub could not run is not a failure (`ci` skill).
- Opening a PR is not a stopping point: read CI yourself and continue through merge,
  cleanup and the final report in the same turn.

## Code Review

Review from the diff, not the author's intent. Use the `otos-review` skill for:
- lens A, implementation fidelity;
- lens B, architecture;
- the questions no lint can ask.

For a user-facing surface, lens C is in `.claude/rules/ui.md`. Rank findings by severity,
each a concrete failure scenario with `file:line`. A confirmed correctness bug or a lost
invariant or requirement blocks merge; smells and lens-B notes are logged on the PR. Every
PR notes the code smells observed (`None observed` when true). For hot-path or store work,
suggest the owner run `/code-review ultra`; it is his to trigger.

## Definition Of Done

An increment is done only when:
- its work has landed on `main`;
- its branch, worktree and stashes are cleaned up, and GitHub holds only `main` and the
  branches of open PRs (`script/dod-report.sh` reads it; a cloud session lists it through
  `git ls-remote`, never from memory);
- the tree is clean on the next-start branch.

Each increment has **one** report, the final one, never a partial or pre-merge one.
- **A merge that changes the app** (`Otos/`, `OtosKit/`, `Otos.xcodeproj/`, `Config/`)
  is published by CI as the next `v<x.y.z>` release once its CI passes. The installed app
  installs it by Sparkle within the hour (`release` skill). The report links that release.
- **The agent looks at what it shipped.** Tests prove the code; only a look proves what
  the owner sees. A cloud session reads the window captures CI makes of every full-tier
  change, light and dark, on generated media (`app-captures-<run>`, `ci` skill); the look
  at the owner's own library is an owner note. A session on the Mac also looks at the
  installed app, read-only (`mac-session` skill).
- **Verification is agent-owned.** Never make the owner launch the app, operate the UI or
  inspect visuals a condition of done. When a check cannot run where the agent is, record
  the limitation, the evidence gathered instead and the remaining risk as a non-blocking
  note, and finish.
- **The report is posted in full on the PR.** The chat gets a short summary and the PR
  link. The `dod` skill holds its contents, and `script/dod-report.sh` generates the
  mechanical checklist.
