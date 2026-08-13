# Plan 0086 — A Test Suite Whose Green Means Something

## Goal

Finish making a whole-suite run a trustworthy signal: fix the one remaining
failing test, and add a resource ceiling so a future runaway allocation fails
loudly instead of silently eating the machine.

Scope is **test correctness plus a runner guard**. No production behavior
changes.

## What is already fixed

`e5c92ef` removed the cause of the suite's resource collapse.

`MediaOperationCoordinatorAdversarialTests` declared two private gates whose
bodies called themselves:

```swift
private func waitForPendingBuilder(_ builder: …, source: …, timeout: …) async throws {
    try await waitForPendingBuilder(builder, source: source, timeout: timeout)  // itself
}
```

The intended target was the same-named free function in
`MediaOperationCoordinatorTestSupport.swift:108`, but an unqualified call inside
a type resolves to the member. Because the call is `async`, each frame is
**heap**-allocated, so the recursion never overflowed the stack — it allocated
until the machine ran out of swap. Introduced by `7cc0983` (#192), the commit
that moved these gates into shared support and left the wrappers behind.

Measured:

| | Adversarial suite alone | Whole suite |
| --- | --- | --- |
| before | 8422 MB peak footprint, 9/14 tests completing | 57.3 GB per host, 99% swapped; killing hosts returned ~34 GB of swap; suite never finished |
| after | 73 MB peak footprint, 14/14 passing | 205 MB peak footprint, 641 passed / 1 failed, suite completes |

## The one remaining failure

`ImportPlanBuilderTests/cancellingControlledBuildIsObservableButDoesNotResume`
still fails in-suite and passes in isolation (3/3). With the memory collapse
removed, this is no longer explainable as load noise — it is a real defect. **The
assertion contradicts the harness contract.**

`MediaOperationCoordinatorTestSupport.swift:165-179` — cancellation does two
things:

```swift
onCancel: {
    Task {
        await self.recordCancel(for: source)                          // (1)
        await self.resumeOnePendingWithCancellationDummy(for: source)  // (2)
    }
}
```

Step (2) (`:84-91`) does `pending.removeValue(forKey: source)`. It is not
optional: its own doc comment explains that an unresumed `CheckedContinuation`
traps, so the harness **must** resume on cancel.

`ImportPlanBuilderTests.swift:122-128` then asserts:

```swift
task.cancel()
try await waitForRecordedCancellation(controlled, source: source)  // waits for (1) only
…
// Still pending — cancellation did not auto-resume
#expect(pendingAfter.contains(source))                             // races with (2)
```

The gate waits for the first effect and asserts on state the second effect is
about to delete. The comment states a contract this harness does not have.

`7cc0983` converted this from `Task.sleep(100ms)` to a precise gate without
re-checking whether the following assertion still held. The sleep accidentally
covered both effects; the precise gate covers one. The cleanup lines after it
(`:130-132`) are dead for the same reason.

## The real contract

On cancellation of a suspended build:

1. The cancel is recorded — `recordedCancelled().contains(source)` is true.
2. The continuation is released with a dummy — `pendingSources()` no longer
   contains `source`.
3. `await task.value` returns that dummy, carrying the snapshot's own
   `generation` (`MediaOperationCoordinatorTestSupport.swift:92-96`) so the
   coordinator's stale-completion checks discard it.
4. No continuation leak — the process does not trap.

Point 3 is what actually matters and what nothing currently asserts: **a
cancelled build must not be able to install a plan.**

## Stages

### Stage 1 — A gate that covers both cancel effects

In `MediaOperationCoordinatorTestSupport.swift`, beside
`waitForRecordedCancellation` (`:133`):

```swift
/// Cancellation has two effects: the source is recorded, and the suspended
/// continuation is released with a dummy so it cannot leak. Gating on the first
/// alone leaves the second racing — the bug this helper exists to prevent.
func waitForCancellationSettled(
    _ builder: ControlledImportPlanBuilder,
    source: LibraryRootPath,
    timeout: Duration = .seconds(5)
) async throws {
    try await withTestTimeout("builder cancellation settled \(source.rawValue)", timeout: timeout) {
        while await !(builder.recordedCancelled().contains(source)
            && !builder.pendingSources().contains(source))
        {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
```

Add it as a **free function**, never as a same-named private wrapper inside a
test type — see Stage 3.

If `waitForRecordedCancellation` has no other caller after Stage 2, delete it
rather than leaving two gates that differ by a race.

### Stage 2 — Rewrite the test against the real contract

Replace `cancellingControlledBuildIsObservableButDoesNotResume` with:

```swift
@Test func cancellingSuspendedBuildRecordsCancelAndReleasesContinuation() async throws {
    // … same snapshot/source setup as today (ImportPlanBuilderTests.swift:108-115) …
    let task = Task { await controlled.build(snapshot: snap, additionalReserved: []) }
    try await waitForPendingBuilder(controlled, source: source)
    #expect(await controlled.pendingSources().contains(source))

    task.cancel()
    try await waitForCancellationSettled(controlled, source: source)

    #expect(await controlled.recordedCancelled().contains(source))
    #expect(!(await controlled.pendingSources().contains(source)))

    // A cancelled build yields a dummy that cannot install a plan.
    let result = await task.value
    #expect(result.plan.generation == snap.generation)
    #expect(result.plan.entries.isEmpty)
}
```

Confirm the dummy's shape against
`MediaOperationCoordinatorTestSupport.swift:92-96` before writing the last two
assertions; assert its actual shape, not this sketch. Delete the dead cleanup
lines.

Verification: reverting Stage 1's gate to `waitForRecordedCancellation` must make
the test fail again (proving the gate closes the race); the test passes both
isolated and in the whole suite.

### Stage 3 — A guard for the recursion class

The bug in `e5c92ef` was invisible to the compiler, to lint, and to review. It is
narrow enough to detect mechanically: a function whose body is a single call to a
function with the same base name and the same argument labels.

Add the check to `script/ci-text-hygiene.sh`, with a fixture proving it fires on
the exact shape that shipped:

```swift
private func f(_ a: A, b: B) async throws { try await f(a, b: b) }
```

Keep it deliberately narrow. A broad "possible recursion" heuristic will produce
false positives on legitimate recursive helpers and get disabled; this one
targets the delegation-that-isn't.

### Stage 4 — A resource ceiling on the suite

The suite consumed 57 GB without any check noticing. Add a ceiling so a future
runaway fails loudly and early.

In `script/test.sh`, run a lightweight sampler alongside `xcodebuild` that polls
each `Otos.app` test host's physical footprint (`footprint -p <pid>`) every few
seconds. If any host exceeds a threshold — start at **2 GB**, roughly 10× the
current 205 MB peak — kill the run and fail with the offending host's pid,
footprint, and the last test to start.

This is the instrumentation that would have caught `e5c92ef` on the PR that
introduced it, and it is cheap. Record the observed peak in the PR each time the
threshold is tuned, so the number stays evidence-backed rather than arbitrary.

### Stage 5 — Prove load-independence

```bash
for i in 1 2 3; do bash script/test.sh > "/tmp/otos-suite-$i.log" 2>&1; echo "run $i exit=$?"; done
grep -hE "' failed" /tmp/otos-suite-*.log | sed 's/ on .My Mac.*//' | sort -u
```

Zero failures across all three. Any test appearing there is load-dependent: find
the effect its gate waits for and the effect its assertion reads, and make them
the same effect. Do not raise a timeout — that hides a race.

Record the ten slowest cases in the PR for future reference:

```bash
grep -E "' passed" /tmp/otos-suite-1.log \
  | sed -E "s/.*'([^']+)'.*\(([0-9.]+) seconds\)/\2 \1/" | sort -rn | head -10
```

### Stage 6 — Store lifecycle in tests

Found while diagnosing the leak, and currently owned by no plan:

- `CatalogStore` has no `deinit` and no `close()`. `shutdown()`
  (`Otos/Stores/CatalogStore.swift:1914-1928`) cancels scan/integrity tasks,
  clears leases, and stops the filesystem watcher — but never releases
  `dbWriter`, so the SQLite connection stays open for the process lifetime.
- Tests instantiate `CatalogStore(location:)` **127 times**; `shutdown()` appears
  in only 11 test files. More than half of the stores created in the suite are
  never shut down, leaving open connections and armed filesystem watchers for the
  remainder of the run.

This did not cause the 57 GB collapse — that was the recursion in `e5c92ef`, and
the suite now peaks at 205 MB — so it is not urgent. It is still an ownership
gap worth closing:

1. Decide whether `shutdown()` should release `dbWriter`. In production there is
   one store for the app's lifetime and one window, so it may be correct as-is;
   if so, say so in the file guide rather than leaving it ambiguous.
2. Give tests one teardown path so a store cannot outlive its test. Prefer a
   helper that creates and tears down in one scope over adding 60 hand-written
   `shutdown()` calls that the next test will forget.
3. With Stage 4's ceiling in place, measure whether the change moves the peak. If
   it does not, record that and stop — AGENTS.md requires measurement before
   optimization, and a tidier lifecycle is a correctness/ownership argument, not
   a performance one.

## Verification

- `bash script/test.sh` green three consecutive whole-suite runs.
- `bash script/verify.sh` green end to end — the first time since `7cc0983`.
- The hygiene guard fires on its recursion fixture.
- The resource ceiling fires when the threshold is temporarily set below the
  observed peak.

## Non-goals and guards

- Do not fix the remaining failure by raising a timeout, adding a sleep, or
  serializing the suite. The gate must wait for the effect the assertion reads.
- Do not delete the failing test. The behavior it should assert — a cancelled
  build cannot install a plan — is real and currently unproven.
- Do not set the memory ceiling so high it can never fire, or so low it flaps.
  2 GB against a 205 MB peak is the starting point; tune with measurements.
- Do not touch `docs/requirements.md` here. Plan 0087 owns the registry.
