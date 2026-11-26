---
paths:
  - "Otos/**/*.swift"
  - "OtosKit/**/*.swift"
  - "OtosTests/**/*.swift"
---

# Swift work in Otos

## Catalog UI ownership (ADR 0004, `docs/architecture.md`)

- `CatalogStore` (actor) owns runtime catalog truth and emits cheap change notifications.
- `CatalogProjection` (actor) owns coalesced `CatalogWindowState` publication, and all
  sorting, filtering, hiding, empty-state and scope derivation off the MainActor. It
  publishes on a background cadence and wakes at once on user intents.
- `CatalogWindowViewModel` (`@MainActor`) owns only:
  - final SwiftUI state assignment;
  - sidebar-selection delivery;
  - lossless serial mutation delivery;
  - weak projected-state consumption;
  - named task lifetimes.

## Swift and concurrency

- Swift 6 language mode, strict concurrency, `SWIFT_APPROACHABLE_CONCURRENCY = YES`.
  UI-facing app code is main-actor isolated by default.
- Never on the main actor:
  - media scanning, metadata reads, image decoding, thumbnail generation;
  - database work, filesystem traversal, export.

  Synchronous work inside a SwiftUI `.task` is main-thread work.
- Long-running work needs an owner, a cancellation path, and stale-completion rejection
  or coalesced dirty/in-flight handling. A long-lived stream consumer captures its owner
  **weakly** across indefinite waits, upgrades only for the smallest completed-value
  scope, and exits when the upgrade fails. A loop that only skips a beat keeps whatever
  its closure captured alive forever.
- Owner state follows ADR 0032. An actor is reentrant, so every `await` is a place another
  event can arrive:
  1. **State changes only in synchronous code.** An async operation takes its inputs as
     values, awaits without touching owner state, and returns an event. The event is
     applied synchronously after checking it still belongs to the identity it started
     for. Never hold a copy of owner state across an `await`.
  2. **A request is a revision counter** (`requested &+= 1`; work covers the value it
     started from; start again while `requested != covered`). Never a boolean a finishing
     operation clears.
  3. **One loop per owner, woken by a doorbell** (`.bufferingNewest(1)`). Newer work never
     cancels published work; cancel only for teardown. A cancelled result is never
     published.
  4. **An error is not a fact.** A failed read publishes nothing, leaves the request
     outstanding and is logged. Never substitute `[]`, `0`, `.empty` or `nil` for a value
     a user sees (lints `error_becomes_value`, `discarded_async_error`). Classify an error
     by its domain and code or the API's typed status, never by its localized text (lint
     `error_text_matching`).
  5. **Intents travel in one ordered stream with one consumer** (`.unbounded` for
     commands, `.bufferingNewest(1)` for newest-wins state), never one `Task {}` per call.
     - An intent that starts long work returns when it is applied.
     - A platform callback yields into its owner's stream. It never hops through its own
       `Task { @MainActor … }` (lint `unordered_main_actor_hop`), and never claims an
       isolation the platform does not give it (lint
       `dispatch_handler_claims_isolation`).
     - View-model work is never a bare per-call `Task {}` (lint `unowned_view_model_task`).
  6. **Blocking work leaves the actor by a named mechanism:** `@concurrent`,
     `Task.detached`, a task-group child, or a dedicated queue. This target compiles with
     `NonisolatedNonsendingByDefault`, so a `nonisolated async` call runs on its caller's
     actor.

  Test an interleaving by delivering the competing event at that exact suspension, never
  with time.
- Intervals and deadlines inside the process use `ContinuousClock` (`Instant`,
  `Duration`). `Date` is only for persisted or displayed timestamps (ADR 0033, lint
  `wall_clock_interval`).
- Main-actor work stays below Apple's 100 ms hang threshold, and scrolling, grid,
  animation and pointer paths well below it. Changes touching jank, responsiveness,
  concurrency, media I/O or rendering include log or profiler evidence.

## Instrumentation

Every meaningful path is observable before it is done.
- Use the repo facade, `OtosLog.Logger` plus `OSSignposter`, with categories App, UI,
  FileAccess, Catalog, Metadata, MediaIO, Thumbnails, Persistence, Rendering and
  Performance.
- No human reads logs; the agent does. Log what the agent must find, in a
  machine-greppable `op=` shape, and keep payloads bounded (ADR 0015).

## File guides

Architecture-boundary files carry a file guide, plus focused comments on the non-obvious:
- actor isolation, task ownership and cancellation;
- persistence, coalescing and cache validation;
- view passivity.

## Code smells

These are indicators, not guilt. When one appears, look for the deeper design problem.
Every PR notes the ones it observed:
- **MainActor gravity:** work isolated to main because it is convenient.
- **SwiftUI body work:** scanning, decoding, sorting or I/O in `body` or a synchronous
  `.task`.
- **State duplication:** two owners answer one domain question.
- **AppKit bridge sprawl.**
- **Unsafe concurrency escape:** unchecked `Sendable`, detached tasks, or shared mutable
  state crossing actors without an owner.
- **Stringly-typed domain facts.**
- **Ambiguous API names.**
- **Test coupling:** asserting implementation details instead of observable behavior.
- **Diagnostic payload sprawl.**
