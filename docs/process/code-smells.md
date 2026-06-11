# Swift And macOS Code Smells

Code smells are quick indicators that often point to deeper design problems.
They are not automatic proof that code is wrong. Investigate the smell, decide
whether it matters, and record the outcome in the PR or DoD report.

Sources:

- [Martin Fowler: Code Smell](https://martinfowler.com/bliki/CodeSmell.html)
- [Refactoring catalog](https://refactoring.com/catalog/)
- [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)
- [Swift 6 concurrency data-race safety](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/enabledataracesafety/)
- [Google Testing Blog: Test behavior, not implementation](https://testing.googleblog.com/2013/08/testing-on-toilet-test-behavior-not.html)

## Required Reporting

Every PR and DoD report must include a `Code smells observed` section. Use
`None observed` only after actively checking the touched area.

For each smell found, record:

- where it appeared
- whether it was fixed, accepted, or moved out of scope
- why the decision is correct for the architecture

## Swift And Concurrency Smells

- MainActor gravity: non-UI work becomes main-actor isolated because the nearest
  caller is UI-facing.
- Unstructured task ownership: detached or long-running tasks have no owner,
  cancellation path, or stale completion check.
- Unsafe concurrency escape: `@unchecked Sendable`, shared mutable references,
  callbacks, or captured state cross actor boundaries without proof.
- Synchronous `.task` setup: SwiftUI `.task` starts with heavy synchronous work
  before leaving the main actor.
- Weakly typed facts: `String`, `Int`, dictionaries, or tuples hide units,
  authority, identity, or role that should be modeled.
- Ambiguous call sites: names do not make side effects, roles, or units clear at
  the point of use.

## SwiftUI And AppKit Smells

- Work in `body`: sorting, scanning, formatting, decoding, I/O, or expensive
  computed properties happen while rendering.
- Broad invalidation: one item or one field change rebuilds a large view tree or
  unrelated state.
- State duplication: two stores, bindings, caches, or projections can answer the
  same domain question.
- AppKit bridge sprawl: an AppKit bridge owns workflow, persistence, or domain
  state instead of a narrow native surface SwiftUI cannot provide.
- UI action fork: buttons, menus, shortcuts, gestures, and automation hooks call
  different implementation paths for the same user action.

## macOS App Smells

- Non-native desktop flow: push-navigation or iOS patterns replace persistent
  sidebars, inspectors, menus, commands, contextual menus, and settings scenes
  where macOS users expect them.
- Side effect in construction: constructing a view/store/service starts
  filesystem, database, cleanup, or media work without an explicit owner intent.
- Privacy-hostile diagnostics: logs, errors, tests, or screenshots expose raw
  media paths, filenames, metadata payloads, thumbnails, or user content.
- Framework-shaped domain truth: app domain models mirror a framework dictionary
  or callback shape instead of the facts Otos actually owns.

## Test Smells

- Implementation-detail assertions: tests fail when internals are refactored but
  behavior is unchanged.
- Mock choreography: tests mostly verify calls between mocks instead of an
  observable result at an owner boundary.
- Sleep-based async: fixed sleeps replace deterministic expectations,
  cooperative yielding, or controllable clocks.
- UI-only proof: behavior that could be tested at a state owner or domain
  boundary is covered only by slow UI automation.
