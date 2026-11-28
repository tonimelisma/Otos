# Otos

Otos is a native macOS Lightroom-style application. It keeps user originals
read-only wherever the user stores them and builds an app-owned overlay for
catalog data, generated previews, metadata, and editing intent.

## Foundation

- Latest macOS only.
- Xcode 27 beta.
- Swift 6 with strict concurrency.
- Apple-first architecture.
- Spec and ADR driven development.
- OSLog and signpost instrumentation on meaningful paths.

Read `CLAUDE.md` (also reachable as `AGENTS.md`) before making changes. It is the
working contract for agents and contributors.

The documentation map lives in `docs/index.md`. Current requirements are tracked
in `docs/requirements.md`, future work in GitHub issues, and how-to-work guidance
in `CLAUDE.md`; the code map is `docs/architecture.md`.

## Setup

Select full Xcode:

```sh
sudo xcode-select --switch /Applications/Xcode-beta.app/Contents/Developer
```

Install developer tools (SwiftFormat and SwiftLint are fetched, pinned and
checksummed, by `script/lint-tools.sh` on first use):

```sh
brew bundle
```

Verify the checkout (gates, build and tests; `--only <Suite>` while iterating):

```sh
script/check.sh
```

Run the app:

```sh
script/build_and_run.sh
```

Stream local telemetry:

```sh
script/logs.sh
```

Capture a profile:

```sh
script/profile.sh SwiftUI 10s
```

Fetch Apple documentation for specs and ADRs:

```sh
script/apple-docs.sh '/documentation/swiftui/view'
```

Generate a local Definition of Done report:

```sh
script/dod-report.sh
```

GitHub CI runs the hygiene and lint gates on Ubuntu and `script/check.sh` on
GitHub's Xcode 27 runner. A Claude Code cloud session, which has no Xcode, runs
the gates itself and is verified by that CI run (CLAUDE.md, "Where sessions run").

## Fixtures

Media fixtures live in `OtosTests/Fixtures/Media`. They are user-provided,
rights-clean test files and must not be replaced with personal media casually.
