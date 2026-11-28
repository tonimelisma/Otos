---
name: release
description: How a merge reaches the installed Otos (Sparkle releases from CI), how to find and read a release, how a bad release is undone, and the maintainer's one-time setup. Use for any change that ships, a DoD report's release line, or a release workflow failure.
---

# Releases (ADR 0059, ADR 0030)

## When a merge publishes

`Release` starts on every push to `main`, beside `CI` (ADR 0062). It builds, signs and
launch-checks the app while CI runs, then waits for that commit's `CI gate`
(`script/ci-gate.sh`) and publishes only once it passed; a failed gate publishes nothing.
It publishes only when something under `Otos/`, `OtosKit/`, `Otos.xcodeproj/` or `Config/`
changed since the newest release; a merge of docs or scripts alone publishes nothing. Each
stage prints `op=release.stage stage=<name> seconds=<since start>`; merge to release is
about seven minutes when the PR was up to date.

## What it publishes

`script/release.sh` builds by the install recipe (`script/lib/installed-build.sh`):
Debug at `-O`, keeping `get-task-allow`. It signs with the maintainer's Apple Development
certificate and with Otos's EdDSA update key, then publishes `v<x.y.z>`, which holds:

- the zipped app;
- its dSYMs;
- Sparkle's feed;
- `Otos.dmg`.

## Versions

Each release is the next patch of `MARKETING_VERSION`'s `x.y` series
(`script/release-version.sh`). A new major or minor series starts by changing
`MARKETING_VERSION` in one PR. Sparkle compares `CFBundleVersion`, which is the
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

## Maintainer setup

A one-time setup outside the repository; no session does it.

- The release's secrets (the Apple Development `.p12` and its password, the team ID, the
  Sparkle update key) live in an Azure Key Vault. `Release` reads them keylessly through
  GitHub OIDC as an Entra app trusted only for the environment `release`, whose variables
  `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_KEY_VAULT` name them. The environment admits
  only `main` (deployment branch policy), and the repository holds no GitHub secrets for them.
- The Apple Development certificate expires yearly and is renewed in the vault. When Xcode
  refuses the certificate as revoked or expired, `Release` says so.
- A fresh install starts from
  `https://github.com/tonimelisma/Otos/releases/latest/download/Otos.dmg`; after that the app
  updates itself.
