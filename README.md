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

Read `AGENTS.md` before making changes. It is the working contract for future
agents and contributors.

The documentation map lives in `docs/index.md`. Requirements are tracked in
`docs/requirements.md`, and process guidance lives under `docs/process/`.

## Setup

Select full Xcode:

```sh
sudo xcode-select --switch /Applications/Xcode-beta.app/Contents/Developer
```

Install developer tools:

```sh
brew bundle
```

Verify the checkout:

```sh
script/verify.sh
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

Remote GitHub CI is a fast hygiene and lint gate. Xcode 27 build/test evidence
is supplied locally with `script/verify.sh` until a GitHub runner with Xcode 27
exists.

## Fixtures

Media fixtures live in `OtosTests/Fixtures/Media`. They are user-provided,
rights-clean test files and must not be replaced with personal media casually.
