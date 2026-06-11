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

## Evidence Matrix

| Risk | Preferred Evidence |
| --- | --- |
| Pure domain rule | Unit test. |
| Workflow coordination | Store/application integration test. |
| Filesystem behavior | Temp-directory integration test. |
| UI command routing | State-owner test first; UI automation when visual/system routing matters. |
| Accessibility identifiers | UI automation or identifier inspection once UI exists. |
| Performance or responsiveness | Structured logs, signposts, Instruments trace, or focused performance test. |
| Concurrency and cancellation | Deterministic async test with controlled state, expectations, or clocks. |
| Persistence/schema | Migration, unknown-schema, preservation, and failure-mode tests. |
| Agent-generated behavior | Existing tests plus a regression tied to the requirement. |

## macOS Guidance

- Keep UI tests small and focused. They are valuable for app launch, menus,
  windows, accessibility identifiers, pasteboard/system integration, and flows
  that cannot be proven below the UI.
- Prefer state-owner tests for SwiftUI command routing and view model behavior.
- Use temporary directories for filesystem tests; never touch production media
  roots or app-owned production storage from tests.
- Use fixtures only when rights and privacy are clear.
- Avoid fixed `sleep` calls. Use expectations, polling with deadlines,
  cooperative yielding, or injectable clocks.
- UI automation can be blocked by local permissions. Record the exact blocker
  and the closest automated evidence when that happens.

## Local Commands

```sh
script/test.sh
script/test-ui.sh
script/verify.sh
```

`script/verify.sh` is the local PR gate while GitHub-hosted runners do not have
the required Xcode 27 toolchain.
