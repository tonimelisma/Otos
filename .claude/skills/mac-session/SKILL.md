---
name: mac-session
description: What a local Claude Code session on a Mac adds to the cloud workflow — native dev builds and tests, the look at the dev app and (read-only) at the installed app, logs, symbols, lldb and profiling, and the weekly performance run on a generated reference library. Use only in a session running on a Mac with Xcode.
---

# A session on a Mac

The cloud session is the default and CI is the verification. A local session on any Mac with
Xcode 27 (and possibly Otos installed) may also build and test natively, run the visual and
end-to-end checks, and inspect the installed app read-only. Its verification is still the
PR's `CI gate`.

- It develops in its own git worktree, never in the primary checkout's `main`.
- Its builds are dev builds (bundle id `net.melisma.Otos.dev`, their own Application Support),
  run against generated catalogs and libraries (`script/sandbox-library.sh`,
  `script/smoke-run.sh`, `script/scorecard.sh --dev --seed <photos>`).
- It never installs: Sparkle is the only installer (ADR 0059), so the installed app is always
  a build CI published.
- `script/check.sh` builds and tests locally; run it in the background and watch it
  (`long-checks` skill). It is for iterating; CI on the final commit is the evidence.

## The user's data

Otos tooling never writes to a user's library, catalog, Immich server or the installed app's
settings (ADR 0020). Experiments that write use generated catalogs and libraries.

- Read-only inspection of the installed app is fine: launching it and looking at its window,
  its unified log and crash reports.
- A live check on real data (reading the installed app's catalog, touring its library,
  querying a real Immich server) happens only when the person running the session asks for
  it, and stays read-only: `sqlite3 -readonly … ?mode=ro`, no Like, Trash, rename, import,
  erase, edit, reorganize or setting, no copy of the catalog launched as a library, and no
  read of a cloud-only file's bytes (it would download).
- An Otos the session launched is quit when the look is done, and the quit is confirmed
  (`pgrep -x Otos`).

## The look

Use the screen tools the session has (computer use), looking at Otos's own window.

- The dev app: build it (`script/build_and_run.sh`) and look at each surface the increment
  changed on a generated library, light and dark.
- The installed app, read-only: Sparkle installs each published release within the hour; to
  look at a specific release, wait for it (`gh release view v<x.y.z>`), choose App ▸ Check for
  Updates…, and confirm the installed `CFBundleShortVersionString`.
- Read the window's accessibility tree where the tool offers it: its labels name every tile,
  so a blank tile, a duplicate, or a wrong badge or count is read rather than guessed.
- Allowed on the installed app: navigation that changes no data (selecting a sidebar row,
  scrolling, opening a photo, switching view mode). Put the window back as it was.
- When the Mac is locked or the session has no screen tools, the look is a non-blocking note.

## Logs, symbols, profiling

- **Logs:** `script/logs.sh stream [Category]` streams live (`--pid <pid>` scopes it to one instance);
  `script/logs.sh show --last 10m` prints post-hoc ndjson. Otos persists `.info` and `.debug`.
- **Debugging:** dev builds and the installed app are Debug builds that keep `get-task-allow`
  (the installed one compiled with `-O`, ADR 0030). Attach with `lldb -p <pid>` or
  `xcrun xctrace record --attach <pid>`. `script/installed-symbols.sh` fetches the installed
  build's dSYMs from its release first.
- **Profiling:** `script/profile.sh "<Template>" 10s` and `script/profile-export.sh <trace>`
  (ADR 0015) profile the dev build.
- **Diagnosis:** `script/scorecard.sh` (ADR 0015) and `script/bench.sh history`. A user's
  problem reaches a session as a Help ▸ Export Diagnostics… folder (ADR 0060).

## The weekly performance run (ADR 0043)

The felt targets in `docs/scorecard-targets.json` hold for a reference library of 160,000
items (`docs/research/2026-11-16-performance-baseline.md`). `script/perf.sh run` tours an
optimized dev build on a generated library of that size (`scorecard.sh --tour --dev
--optimized --seed 160000 --seed-media small`), then counts the benchmark cases on
`origin/main`, and writes one verdict. It reads no user data. `script/check.sh` prints one
`op=perf.status` line:

- **`verdict=due`:** start `script/perf.sh run` in the background and keep working; another
  session's start gets `phase=skipped`.
- **`verdict=fail`:** a felt target was missed (`felt=`). Fixing it is the next work: start
  with one tour that reproduces it (`script/scorecard.sh --tour --dev --optimized --seed
  160000 --seed-media small`). A miss that does not reproduce is recorded with
  `script/perf.sh not-reproduced <scorecard>`.
- **Instruction rises (`cpu=`)** decide nothing by themselves; they are listed in the report.
- A target changes only with the decision that sets it, recorded in the same PR.

## Other Mac-only work

- Core ML conversion and validation of the `.mlpackage` files in `OtosKit/Resources/`
  (ADR 0045, ADR 0047) and Apple Translation's language resources need a Mac.
- `gh` uses HTTPS; when a `gh pr` command times out, issue the same request once through
  `gh api` before reporting it failed.
