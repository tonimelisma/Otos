# 0032 — Owner state changes synchronously, a request is a counter, and intents arrive in order

Status: accepted.

## Context

Plan 0106 replaced elapsed-time waits in tests with owner-reported facts. Under load, each
hang that appeared traced to a product defect in how an owner kept state across an `await`,
not to a slow machine (`docs/research/2026-10-05-owner-state-reentrancy-and-ordering.md`):

- `CatalogProjection` cancelled a running build to start a newer one. A cancelled GRDB read
  throws `CancellationError`, the build's `catch` turned that into `[]`, and an empty
  catalog was published as fact.
- `MediaOperationCoordinator` copied a session across store reads and wrote the copy back,
  erasing the dirty mark a scan batch set mid-build, so a stale empty plan became final.
- Both kept "work is needed" in booleans that a finishing operation cleared, erasing a
  request made while it ran.
- User intents each started their own `Task {}`, which Swift does not order (SE-0431
  excludes implicitly-isolated tasks), so "change the destination, then Import" could
  arrive reversed.
- This target compiles with `NonisolatedNonsendingByDefault`, so a `nonisolated async`
  call runs on its caller's actor: the destination walk held the coordinator actor for
  285–324 ms and a subtree rescan held the store actor up to 995 ms
  (`docs/research/2026-10-23-actor-hold-during-blocking-work.md`).

An actor is reentrant: at every `await`, other messages run and change its state
(SE-0306). Writing code as if an `await` were an atomic step is the one mistake behind
all of these.

## MECE Decision Scope

This ADR owns how an owner (an actor or a main-actor view model) keeps state across
suspensions, how work is requested and covered, how user intents reach an owner, and where
blocking work runs. It defers publication cadence and the projection's read model to ADR
0005 and ADR 0011, the import session's lifecycle to ADR 0017, ADR 0019 and ADR 0021,
catalog persistence and scan leases to ADR 0002 and ADR 0008, and enrichment pacing to ADR
0009.

## Decision

1. **State changes are synchronous.** An owner's state changes only in non-`async` code. An
   async operation takes the inputs it needs as values, does its awaits without touching
   owner state, and hands its result back as an event. The event is applied synchronously,
   and only after checking that it still belongs to the identity it was started for
   (attachment, build generation, batch, scan lease). No owner keeps a copy of its state
   across an `await`. `ImportSessionMachine` is the model: `handle(_:)` is the only writer
   and returns the effects the shell performs.
2. **A request is a revision, never a boolean.** Each request does `requested &+= 1`. Work
   records the `requested` it started from when it is *taken up* and covers exactly that;
   when it finishes the owner starts again if `requested != covered`. Nothing decrements or
   clears `requested`. Quiescence is `requested == covered` with nothing in flight.
3. **One loop per owner, woken by a doorbell.** The doorbell is a
   `.bufferingNewest(1)` `AsyncStream<Void>`; every producer yields to it and one task runs
   the passes. Newer work never cancels older work: the older result is checked against its
   identity when it completes and dropped if stale. Cancellation is only for teardown,
   detach and shutdown, and a cancelled operation's result is never published. A loop that
   waits indefinitely holds its owner weakly and ends when the upgrade fails.
4. **An error is not a fact.** A failed read publishes nothing: the last published state
   stands, the request stays outstanding, and the error is logged with `errorOperation`.
   No `catch` or `try?` substitutes `[]`, `0`, `.empty` or `nil` for a value a user sees; a
   value that is genuinely unknown is optional and shown as unknown. SwiftLint rule
   `error_becomes_value` rejects `try? … ?? []/0/""/false/.empty` anywhere in the app,
   `discarded_async_error` rejects a `try? await` statement that drops a failure, and
   `projection_catch_substitutes_value` rejects the `catch` form in the projection.
5. **Intents to an owner travel in one ordered channel.** Commands (must not be dropped,
   must stay in order) use one `.unbounded` `AsyncStream<Intent>` with one consumer.
   State-valued intents (only the newest matters) use `.bufferingNewest(1)`. Never one
   plain `Task { await owner.intent() }` per intent. An intent that starts long work returns
   when it is applied, not when the work ends, so the next intent is never queued behind it.
   Platform reports (DiskArbitration, ImageCaptureCore delegates) are intents too: the
   callback yields into its owner's stream. SwiftLint rule `unordered_main_actor_hop`
   rejects a bare `Task { @MainActor … }` started from a callback; where an API documents
   the main thread, `MainActor.assumeIsolated` asserts it instead of hopping.
   `unowned_view_model_task` rejects a bare `Task {}` started per call in view-model code:
   such work is a named task property cancelled at teardown, or a stream's one consumer.
6. **Blocking work leaves the actor explicitly.** Filesystem walks, planning, decoding and
   hashing enter through `@concurrent`, `Task.detached`, a task-group child, or a dedicated
   queue. A comment saying "off the actor" or "off main" names which.
7. **Interleavings are tested deterministically.** Every `await` in an owner is a place
   another event can arrive, so each gets a test that delivers an event exactly there: a
   sequence of `handle(_:)` calls for a pure machine, a seam that parks the async work for
   an actor. Tests never use time to create an interleaving and never wait with a deadline.

## Rejected alternatives

- **Keep fixing instances found by stress loops.** One finding per ~10 minutes under load,
  and the class remains.
- **Serialize each actor with an async lock or queue.** That reintroduces the deadlocks
  reentrancy exists to prevent and holds UI intents behind long builds.
- **Only swap `isDirty` for a counter and add an `inout` mutate helper.** It closes the lost
  request but leaves stale copies expressible, and the transitions stay mixed with I/O, so
  they still need real stores and temp folders to test.
- **A third-party deterministic test executor.** It needs a dependency decision and replaces
  production interleavings with a test-only schedule; injected events test the real ones.
- **`Task.immediate` for ordered intents.** SE-0472 gives no ordering between two such tasks
  after their first suspension.

## Consequences

- `CatalogProjection` is one loop with two counters; a failed build publishes nothing
  (ARC-019). `MediaOperationCoordinator` is a shell around `ImportSessionMachine`
  (ARC-047). Import intents, trash undo/redo and prompt answers, and execution progress are
  ordered streams (ARC-047, APP-039).
- The trash queue treats a failed read as unknown and never moves an item the user took
  back (ARC-058); the preview loader never hands a request a smaller decode than it asked
  for (APP-040).
- A new owner copies one of the existing shapes instead of inventing a flag: the doorbell
  loop (`CatalogProjection`, `MaterializationCoordinator`) or the pure machine
  (`ImportSessionMachine`).
- `.swiftlint.yml` rejects the one syntactic form of rule 4 that can be matched precisely
  (a `catch` in `CatalogProjection*.swift` that assigns or returns `[]`, `.empty` or `0`).
  A rule for rule 6 ("`func … async` in a `Live*` type without `@concurrent`") cannot be
  made precise with a regex — it needs the type's isolation, and actors and `@concurrent`
  functions are both correct — so review carries it (CLAUDE.md, Code Review lens A).
