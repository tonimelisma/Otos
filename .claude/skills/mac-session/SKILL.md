---
name: mac-session
description: What a Claude Code session started on the owner's Mac adds — read-only work on his production data, the installed app's logs and symbols, profiling, the weekly performance run and owner-library tours, the look at the installed app, git over SSH. Use only in a session running on the Mac; a cloud session never reaches the Mac.
---

# A session on the owner's Mac

The owner starts such a session from Claude Code on the Mac itself; a cloud session never
reaches the Mac.

- It develops in a dedicated git worktree, never in the primary checkout's `main`.
- Its builds are dev builds (`net.melisma.Otos.dev`, with their own Application Support)
  against generated catalogs.
- It never installs: Sparkle is the only installer (ADR 0059).
- Its verification is the same CI run as a cloud session's. A local `script/check.sh` is
  for iterating, run in the background and watched (`long-checks` skill).

## The owner's production data is read, never changed

He asked for read-only testing on his real data (2026-11-15: "you are supposed to use my
production data for all read-only testing!"; 2026-11-18: "…including immich key"). This
is expected, and nobody asks first:

- launching the installed app and looking at it, and visiting its views;
- reading its unified log and crash reports;
- opening its catalog read-only (`sqlite3 -readonly … ?mode=ro`) for schema, counts,
  plans and timings;
- `stat` and `du` of his libraries and app folders;
- read-only GET requests to his Immich server with the session token Otos stored in the
  Keychain. The token is never printed or logged, and goes only to his own server.

These are never done there, because they change his data or leave state behind:

- Move to Trash, Like or Dislike, naming or merging people;
- import, erase, edit, reorganize, or any settings change;
- any write to the catalog or to his Immich server;
- a copy or backup of it, or a build launched on a copy (a copy's roots are his real
  folders and devices);
- reading a cloud-only file's bytes, which downloads it.

An Otos the session launched is quit when the look is done, and the quit is confirmed
(`pgrep -x Otos`).

## The look at the installed app

Use the screen tools the session has (computer use), looking at Otos's own window without
moving the owner's pointer where the tool allows.

- Sparkle installs each published release within the hour. To look at a specific
  release, wait for it (`gh release view v<x.y.z>`), choose App ▸ Check for Updates…, and
  confirm the installed `CFBundleShortVersionString`.
- Take a screenshot of each surface the increment changed, and of All Media's grid after
  any app change.
- Read the window's accessibility tree where the tool offers it. Its labels name every
  tile, so a blank tile, a duplicate, or a wrong badge or count is read rather than
  guessed.
- Allowed: navigation that changes no data, such as selecting a sidebar row, scrolling,
  opening a photo, or switching view mode.
- Never: a Like, Trash, rename, import, edit or setting.
- Put the window back where the owner left it.
- When the Mac is locked or the session has no screen tools, the look is a non-blocking
  note.

## Logs, symbols, profiling

- **Logs:**
  - `script/logs.sh stream [Category]` streams live.
  - `script/logs.sh show --last 10m` prints post-hoc ndjson.
  - The installed app persists `.info` and `.debug`.
- **Debugging and profiling:**
  - The installed app is a Debug build compiled with `-O` that keeps `get-task-allow`
    (ADR 0030). Attach with `lldb -p` or `xcrun xctrace record --attach <pid>`.
  - `script/installed-symbols.sh` first fetches the installed build's dSYMs.
  - Profile with `script/profile.sh "<Template>" 10s` and `script/profile-export.sh
    <trace>` (ADR 0015).
- **Diagnosis tools:** `script/scorecard.sh` (ADR 0015) and `script/bench.sh history`.

## The weekly performance run (ADR 0043)

`script/check.sh` prints one `op=perf.status` line:

- **`verdict=due`:** start `script/perf.sh run` in the background, watch it, and keep
  working.
  - It tours the installed app on the owner's library, read-only, then counts the
    benchmark cases on `origin/main`, and writes one verdict.
  - Another session's start gets `phase=skipped`.
  - `phase=pending` (an import in flight) leaves it due.
- **`verdict=fail`:** a target in `docs/scorecard-targets.json` was missed on his library
  (`felt=`). Fixing it is the next work.
  - Start with one tour that reproduces it (`script/scorecard.sh --tour`).
  - A miss that does not reproduce is recorded with `script/perf.sh not-reproduced
    <scorecard>`. A `fail` carrying `notReproduced=` asks for nothing.
  - A target changes only by the owner's decision.
- **Instruction rises (`cpu=`)** decide nothing; the owner says whether one is work.
- **No other tour or benchmark** belongs to a PR, unless the owner asks or a fix is
  reproducing a `fail`.

## Owner-only tooling

These run only on the Mac, on his data:
- `script/face-accuracy.sh`, `script/description-eval.sh`,
  `script/scene-label-hierarchy.sh`;
- Core ML conversion and validation of the `.mlpackage` files in `OtosKit/Resources/`.
  They come from his research repositories, which hold private family data and are out
  of scope.
- Apple Translation's language resources.

## Git over SSH

On the Mac, git reaches GitHub over SSH the moment HTTPS fails or stalls: a TLS handshake
timeout, `early EOF`, a fetch killed by a signal, or no progress. Switch at once, with no
HTTPS retry, to the deploy key's alias:

- fetch: `git fetch git@github.com:tonimelisma/Otos.git main:refs/remotes/origin/main`
- push: `git push git@github.com:tonimelisma/Otos.git <branch>`

Use the alias for the rest of the session. `gh` uses HTTPS only; when a `gh pr` command
times out, issue the same request once through `gh api` before reporting it failed.
