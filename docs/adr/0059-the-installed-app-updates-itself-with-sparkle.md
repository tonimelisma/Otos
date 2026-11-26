# ADR 0059: The installed app updates itself with Sparkle

- Status: Accepted
- Date: 2026-11-26

## Context

The installed app (ADR 0030) was brought up to date by building `main` on the owner's Mac.
Work merged from a cloud session, which cannot reach the Mac, reached the installed app only
when something on the Mac built and installed it. The owner asked for Sparkle (2026-11-26:
"Set up sparkle for otos so it autoupdates from now on"), and settled how it is signed:
"Sparkle does not need notarization", as another project of his updates itself with
Sparkle, its own update key and his development certificate.

## MECE Decision Scope

This ADR owns how the installed app learns of, fetches, checks and installs a newer build,
and how CI makes and publishes that build. It defers what the installed build is (identity,
Debug at `-O`, symbols, logs) to ADR 0030, the busy predicate to ADR 0020, and the CI jobs that
prove a commit to `.github/workflows/ci.yml`.

## Decision

1. **Sparkle 2, pinned.** Sparkle 2.10.1 (`exactVersion`, resolved by commit in
   `Package.resolved`) is linked into OtosKit, where the app's code lives, and embedded by
   the app. A newer Sparkle is taken by a deliberate bump.
2. **Signed by Otos's own update key and the owner's development certificate; not
   notarized.** Sparkle accepts an update only when its archive's EdDSA signature matches
   the public key the installed app carries (`SUPublicEDKey`, the build setting
   `OTOS_SPARKLE_PUBLIC_ED_KEY`) and its code signature matches the installed app's. The key
   is Otos's alone: it lives in the login keychain under the account `net.melisma.Otos`, not
   `generate_keys`'s default account, which every app signed that way would share. CI
   signs with the same Apple Development certificate the Mac's own installs use: the team's
   newest one that Apple's revocation service (OCSP) accepts, because a revoked one still
   reads as valid in a keychain; the release asks the same service to explain a refusal. An update
   keeps the app's privacy permissions and Keychain items, and the build keeps
   `get-task-allow` (ADR 0030): lldb and Instruments still attach.
3. **Only the installed app updates.** `AppUpdater` starts Sparkle only for the product
   identity `net.melisma.Otos`, carrying the update key, outside a test host. A dev build
   would replace itself with another identity's build; a build without the key could not
   check a download.
4. **Hourly, silent, in the background.** Sparkle reads the feed every hour
   (`SUScheduledCheckInterval` 3600, its shortest), and downloads a newer build without asking
   (`SUAutomaticallyUpdate`). App ▸ Check for Updates… asks at once and shows what it finds;
   only a build that updates itself offers it.
5. **Installing never interrupts work.** Sparkle hands the downloaded update's install to
   `UpdateInstallGate`, which holds it while an import or a reorganization is in flight and
   runs it once none is: Sparkle quits Otos, replaces it and opens it again. The Store owns
   that fact (`CatalogStore.operationalWorkChanges`): every journal write commits through
   `writeJournal`, which reads the answer inside the same transaction, so the gate waits on
   the Store's report, never on time (ADR 0033). The install runs from the main run loop's
   own callback, never inside a main-queue job, because quitting can wait on a reply that
   arrives as one. A quit before then installs the update as Otos quits, Sparkle's default.
6. **CI builds and publishes every `main` commit CI passed that changes the app.**
   `.github/workflows/release.yml` runs after CI, only for a push to `main` that passed, in the
   environment `release` that holds the certificate, its password, the team ID and the update
   key. `script/release.sh` publishes only when something under `Otos/`, `OtosKit/`,
   `Otos.xcodeproj/` or `Config/` changed since the newest release (owner, 2026-11-26: "no need
   to release a new release with only a new versioning scheme"); a commit of docs or scripts
   alone ships nothing. It builds by the recipe `script/install.sh` uses
   (`script/lib/installed-build.sh`) with the certificate imported into a keychain of the run's
   own, signs the zipped app with the update key (on standard input), and publishes the release
   `v<x.y.z>` with the archive, its dSYMs, the feed (`script/appcast.sh`) and a disk image for
   installing by hand (`Otos.dmg`, signed with the app's certificate: the app beside a link to
   Applications, as latchkey's is; the release notes say how to open an app that is not
   notarized). It is marked latest, so `releases/latest/download/appcast.xml` and
   `…/Otos.dmg` always name the newest build. A commit no newer than the newest release is
   skipped; the newest three releases are kept.
7. **No updater with known advisories ships.** Before it builds, the release asks the OSV
   database about the Sparkle version `Package.resolved` pins (`script/sparkle-advisories.sh`)
   and stops on any advisory, or when OSV does not answer. A fix is a deliberate Sparkle bump.
8. **Semantic versions for people, the commit count for Sparkle.** Each release is the next
   patch of the project's `MARKETING_VERSION` series, `x.y` (owner, 2026-11-26: "can we adopt
   semver? bump on every commit"): `script/release-version.sh` takes the newest published
   `v<x.y.z>` and adds one to its patch, or starts a newer series at `x.y.0`, and the build
   carries it as `CFBundleShortVersionString`. A new major or minor version is a commit that
   changes `MARKETING_VERSION`, the owner's decision. Sparkle compares `CFBundleVersion`, the
   commit count: `main` takes only squash merges, so it grows with every merge, and builds
   published before semantic versions (`build-1598`, `build-1599`) compare below every later
   one. The version is taken from the published releases, not committed to a file, so a release
   never needs a commit of its own.

## Rejected alternatives

- **The Mac's own updater: a launchd agent that pulls `main` and builds it.** It needed the
  Mac's checkout kept clean and on `main`, built on the Mac for every merge, and was replaced
  before it was set up.
- **Developer ID signing and notarization.** Gatekeeper's path for apps others download; the
  owner's installs and updates need neither, and notarization refuses `get-task-allow`, which
  ADR 0030 keeps.
- **A Release build.** Drops `get-task-allow` and `#if DEBUG` diagnostics (ADR 0030).
- **A self-hosted Actions runner on the Mac.** The repository is public and takes pull
  requests from anyone; their workflows would run on the owner's Mac.
- **Hand-written update code (download, verify, swap).** Sparkle does each step, signature
  checks and the replace-and-relaunch included, and is maintained for exactly this.
- **Installing on Sparkle's schedule.** It would quit Otos in the middle of an import.
- **A version file bumped by each release.** It needs a commit on `main` per release, which the
  release would then build again; the published tags already say which version is newest.
- **The version from commit messages (feat → minor, fix → patch).** It makes every merge's title
  decide what users see; the owner decides a new series by changing `MARKETING_VERSION`.
- **GitHub Pages for the feed.** A release already holds the archive; its latest-release URL
  serves the feed with no second place to publish to.

## Consequences

- Updates start once the owner has run `script/release-setup.sh` on the Mac, which makes the
  update key, sets the environment's secrets from the login keychain with the owner's `gh`
  login (no value printed or committed), and opens the pull request that commits the public
  key; it builds and installs nothing. The first install is the first release's disk image,
  dragged to Applications once. Until the secrets exist the release job says what is missing
  and publishes nothing, and a build without the public key never starts Sparkle.
- A build installed from the Mac (`script/install.sh`) is updated by the next published build
  with a higher commit count.
- An update quits and reopens Otos when no import or reorganization is in flight, as an
  install from the Mac did.
- The signer's name and team ID are in every published build's signature.

## Defers

- What the installed build is, its symbols and logs — ADR 0030. The busy predicate — ADR 0020.
