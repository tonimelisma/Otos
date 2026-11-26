# Developing a macOS app when GitHub Actions is the only Mac

Date: 2026-11-26. Sources fetched that day. Plan 0118 is built on this note.

## Question

The owner (2026-11-26): "releases need to happen even from cloud. CI needs to be enough.
cloud dev might be the only way we do dev for months. we can't be gated on a local env."
What do current sources say about building, testing, looking at, measuring, diagnosing and
releasing a native macOS app whose only Mac is a hosted CI runner, and which of Otos's
Mac-only steps can move there?

## What Otos already has (repository, 960d000)

- `CI` runs `script/check.sh` on GitHub's `xcode-27` runner for every push; a run takes
  8–15 minutes (runs 45760367207 to 45770347726).
- `Release` builds, signs and publishes every green `main` commit that changes the app
  (ADR 0059); `build-1598` and `build-1599` were published that way on 2026-11-26. Releases
  already need no Mac. The release does not launch what it publishes.
- The test bundle is unhosted (ADR 0023): no CI job launches `Otos.app`.
- A self-contained tour exists: `script/scorecard.sh --tour --dev --seed <n> --optimized`
  builds the dev app, makes a sandbox home with a library of generated media on its own
  disk image (`script/sandbox-library.sh`), has the app register it through its own Add
  Library intent, runs `SmokeTour` (`OTOS_TOUR=1`) and judges the session from the log.
  `SmokeWindowCapture` (`OTOS_SMOKE_CAPTURE_PATH`, `OTOS_SMOKE_APPEARANCE`) writes the
  window's own rendering to a PNG (ADR 0020). None of it runs on CI.
- ADR 0043 rejected GitHub Actions for the benchmark counts only because no runner had the
  repository's Xcode beta; the `xcode-27` runner now has it.

## Findings

### The hosted runner can drive a GUI app

- The macOS runner images enable automation mode without authentication, keep the display
  awake, and pre-grant Accessibility and Screen Capture to `/bin/bash`, Terminal and Xcode's
  helper. The app under test gets no grant of its own, so any TCC prompt the app raises
  blocks a headless run.
  https://raw.githubusercontent.com/actions/runner-images/main/images/macos/scripts/build/configure-machine.sh,
  https://raw.githubusercontent.com/actions/runner-images/main/images/macos/scripts/build/configure-tccdb-macos.sh
- TCC grants cannot be supplied in a supported way except by a person or MDM; on macOS 27
  the user TCC database is protected. https://developer.apple.com/forums/thread/834560
- XCUITest needs an unlocked, foreground session, which hosted runners give; recent reports
  of element-lookup and AX-load timeouts on Xcode 26 exist, and nothing specific to
  `xcode-27` was found. https://developer.apple.com/forums/thread/840965,
  https://developer.apple.com/forums/thread/812307
- `xcrun xcresulttool export attachments --path R.xcresult --output-path out/` exports a
  result bundle's attachments; `get test-results summary|tests|metrics` print JSON.
  https://keith.github.io/xcode-man-pages/xcresulttool.1.html

### Screenshots and snapshots

- A window's own rendering (`cacheDisplay(in:to:)`, the mechanism `SmokeWindowCapture`
  and swift-snapshot-testing's NSView strategy share) depends on size, appearance, backing
  scale and color space, and reference images must be recorded on the OS that compares
  them. https://github.com/pointfreeco/swift-snapshot-testing (NSView strategy, PRs 533 and
  665)
- `ImageRenderer` draws only SwiftUI's own views; AppKit-backed controls render as
  placeholders, so it cannot stand in for a window capture.
  https://developer.apple.com/documentation/swiftui/imagerenderer
- No published practice for reviewing image diffs without a Mac goes beyond uploading the
  reference, actual and difference images as artifacts and reading them.

### Performance on hosted runners

- Wall-clock benchmarks on GitHub runners vary by a few percent run to run; instruction
  counts vary far less but are not fully deterministic. https://codspeed.io/blog/benchmarks-in-ci-without-noise
- No source confirms that hardware performance counters (instructions retired, which
  `script/bench.sh` compares) are readable inside GitHub's macOS VMs; kpc access needs
  privileges. https://developer.apple.com/forums/thread/849179. One run settles it.
- Xcode's performance baselines are keyed to a machine identifier, so ephemeral runners
  never match them; teams extract the numbers and compare against `main`'s themselves.
  https://developer.squareup.com/blog/measureblock-how-does-performance-testing-work-in-ios/

### Diagnostics from a Mac the developer cannot reach

- MetricKit delivers `MXCrashDiagnostic` and `MXHangDiagnostic` on macOS 12 and later, to
  the app itself; payloads export as JSON with binary UUIDs and offsets, symbolicated
  against the build's dSYMs. https://developer.apple.com/documentation/metrickit
- `OSLogStore(scope: .currentProcessIdentifier)` reads only the current launch; `.system`
  reads earlier ones on macOS but needs an administrator. https://developer.apple.com/forums/thread/691093
- Xcode Organizer's crash reports cover App Store and TestFlight apps only; a directly
  distributed app gets none. Third-party crash reporters send data off the machine.
  https://docs.sentry.io/platforms/apple/guides/macos/configuration/app-hangs
- CI artifacts of a public repository are public: owner diagnostics never go there.

### Release safety

- Sparkle 2 has channels, phased rollout (`sparkle:phasedRolloutInterval`) and critical
  updates, and no downgrade: a bad release is undone by publishing a higher version with
  the change reverted. A reverted migration cannot be undone that way.
  https://sparkle-project.org/documentation/publishing/, https://sparkle-project.org/documentation/upgrading/
- Verify the copy that ships (`codesign --verify --deep --strict`), launch it, wait for a
  readiness report, and gate publishing on that. https://developer.apple.com/forums/thread/706442
- Apple Development certificates are meant for development; this is accepted for an
  owner-only app (ADR 0059) and expires yearly, renewed with `script/release-setup.sh`.

### Runner facts

- `xcode-27` and `xcode-27-xlarge` are generally available (October 2026), arm64, macOS 27.
  https://github.blog/changelog/2026-10-15-xcode-27-runner-image-generally-available
- A standard macOS runner has 3 cores, 7 GB of memory and 14 GB of disk; standard runners
  are free for public repositories; five macOS jobs run at once on the Free, Pro and Team
  plans. https://docs.github.com/en/actions/reference/runners/github-hosted-runners,
  https://docs.github.com/en/actions/reference/limits
- `xcodebuild -run-tests-until-failure -test-iterations <n>` reproduces a flaky test without
  retrying it into green. https://keith.github.io/xcode-man-pages/xcodebuild.1.html

## Conclusions

1. Every step that only the Mac did can move to CI except what reads the owner's own data:
   the look at his library, the felt targets on his library, the evaluations on his private
   data and the Core ML conversions from his research repositories.
2. The look moves to CI as captures of each surface, light and dark, from a tour of the dev
   app on a generated library, uploaded as artifacts the cloud session downloads and reads.
   The app must raise no TCC prompt in that tour.
3. The release launches the exact archive it is about to publish and publishes nothing that
   does not reach its first window.
4. The weekly benchmark counts cannot move to CI: measured on 2026-11-26 (run 45870604355),
   the `xcode-27` runner's virtual Mac (`VirtualMac2,1`) reads zero instructions retired
   through `proc_pid_rusage`. Deterministic twin tests stay the only performance gate there.
5. What the installed app experiences reaches a session only when the owner hands it over: a
   diagnostics bundle the app writes on request, never uploaded to CI or anywhere public.
6. CI needs a way to run one suite many times, since a cloud session has no `--only`.
