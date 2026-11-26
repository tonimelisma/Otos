---
name: release
description: How a merge reaches the installed Otos (Sparkle releases from CI), how to find and read a release, how a bad release is undone, and the owner's yearly signing renewal. Use for any change that ships, a DoD report's release line, or a release workflow failure.
---

# Releases (ADR 0059, ADR 0030)

## When a merge publishes

`Release` runs after `CI` passes on a push to `main`. It publishes only when something
under `Otos/`, `OtosKit/`, `Otos.xcodeproj/` or `Config/` changed since the newest
release; a merge of docs or scripts alone publishes nothing.

## What it publishes

`script/release.sh` builds by the install recipe (`script/lib/installed-build.sh`):
Debug at `-O`, keeping `get-task-allow`. It signs with the owner's Apple Development
certificate and with Otos's EdDSA update key, then publishes `v<x.y.z>`, which holds:

- the zipped app;
- its dSYMs;
- Sparkle's feed;
- `Otos.dmg`.

## Versions

Each release is the next patch of `MARKETING_VERSION`'s `x.y` series
(`script/release-version.sh`). A new major or minor version is the owner's decision,
made by changing `MARKETING_VERSION`. Sparkle compares `CFBundleVersion`, which is the
commit count.

## Installing

The installed app checks hourly, downloads silently, and installs once no import or
reorganization is in flight (`UpdateInstallGate`). Nobody installs by hand after a merge.

## Reading one

    gh api repos/tonimelisma/Otos/releases --jq '.[] | "\(.tag_name) \(.published_at)"'
    gh api "repos/tonimelisma/Otos/actions/workflows/release.yml/runs?per_page=5" --jq '.workflow_runs[] | "\(.id) \(.conclusion) \(.run_started_at) \(.updated_at)"'

A cloud session's final report links the release that publishes its merge.

## Undoing a bad release

Sparkle 2 never downgrades, so a bad release is undone by merging a revert, which CI
publishes as a higher version. A revert cannot undo a schema migration: older code cannot
read a newer catalog. A bad migration is fixed forward (`.claude/rules/persistence.md`).

## Owner steps

- The first install is by hand, from
  `https://github.com/tonimelisma/Otos/releases/latest/download/Otos.dmg`. Once the
  installed app runs a release, it updates itself.
- The Apple Development certificate expires yearly. The owner renews it by running
  `script/release-setup.sh` on the Mac, which re-exports the newest valid certificate into
  the environment `release`. When Xcode refuses the certificate as revoked or expired,
  `Release` says so.
