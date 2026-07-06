# Testing AI-Generated macOS Code

AI-generated code must be reviewed and tested like code from an unfamiliar
developer. The agent can produce useful code quickly, but the repo must prove
behavior through requirements, tests, and runtime evidence.

Sources:

- [Apple XCTest documentation](https://developer.apple.com/documentation/xctest)
- [Google Testing Blog: Test behavior, not implementation](https://testing.googleblog.com/2013/08/testing-on-toilet-test-behavior-not.html)
- [Software Engineering at Google: Unit Testing](https://abseil.io/resources/swe-book/html/ch12.html)
- [Martin Fowler: Test Pyramid](https://martinfowler.com/bliki/TestPyramid.html)
- [GitHub Copilot responsible use](https://docs.github.com/en/copilot/responsible-use/agents)

## Policy

- Derive tests from requirements and acceptance examples, not from code shape
  after implementation.
- Prefer tests at public owner boundaries. Test behavior first; test
  implementation details only when the implementation detail is the contract.
- Use the narrowest reliable layer that proves the risk.
- Treat AI-generated tests as drafts. Review whether they would fail for the
  bug or requirement they claim to cover.
- Do not chase coverage percentages. Add tests that protect behavior,
  architecture contracts, privacy, and regressions.
- Prefer simple data structures and the narrowest reliable layer. Per Rob Pike's 5
  Rules, whose canonical statement is in `AGENTS.md`, simple code organized around
  good data structures makes behavior easy to verify.

## Evidence Matrix

| Risk | Preferred Evidence |
| --- | --- |
| Pure domain rule | Unit test. |
| Workflow coordination | Store/application integration test. |
| Filesystem behavior | Temp-directory integration test. |
| UI command routing | State-owner or command-model test. |
| Accessibility behavior | Focused manual audit or identifier inspection once UI exists. |
| Performance or responsiveness | Structured logs, signposts, Instruments trace, or focused performance test. |
| Concurrency and cancellation | Deterministic async test with controlled state, expectations, or clocks. |
| Persistence/schema | Migration, unknown-schema, preservation, and failure-mode tests. |
| Agent-generated behavior | Existing tests plus a regression tied to the requirement. |

## macOS Guidance

- Do not add screen-driving tests by default. They are intrusive on macOS,
  expensive in agent loops, and easy to overvalue before the app has real
  workflows.
- Reintroduce screen-driving tests only through a fresh spec and ADR that name
  the behavior, alternatives, cost, reliability plan, and expected evidence.
- Prefer state-owner tests for SwiftUI command routing and view model behavior.
- Use temporary directories for filesystem tests; never touch production media
  roots or app-owned production storage from tests.
- Use fixtures only when rights and privacy are clear.
- Avoid fixed `sleep` calls for ordinary state observation. Prefer owner events,
  continuations, Observation-backed streams, explicit gates, or injectable
  clocks/delay closures. Harness timeouts, negative/absence assertions, diagnostic
  file polling, and production cadence tests may still use bounded sleeps when the
  passage of time is the behavior being tested.
- Do not delegate verification to the user as a DoD condition. Run all
  agent-executable checks; record any UI interaction the environment cannot
  drive as an unverified risk and optional after-DoD task.
- Do not treat headless layer rendering as proof of AppKit overlay-corner masks
  when the implementation depends on `CACornerMask` or `maskedCorners`. The
  current measured headless paths (`cacheDisplay`, `layer.render`) do not
  faithfully expose those masks for `MediaAssetTileView`; use source/unit tests
  for pure geometry and on-screen screenshot smoke evidence for the real AppKit
  mask appearance.

## Local Commands

```sh
script/test.sh
script/verify.sh
```

`script/verify.sh` is the local PR gate while GitHub-hosted runners do not have
the required Xcode 27 toolchain.
