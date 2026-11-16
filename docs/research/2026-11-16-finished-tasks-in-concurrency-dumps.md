# Finished tasks in concurrency dumps, read as a parked trash shutdown

Date: 2026-11-16. Context: on 2026-11-16, five agents reported a full `script/check.sh` as hung
on `MediaTrashCoordinatorOwnershipTests/aPassSuspendedWhenShutdownLandsStartsNoDownloadThatOutlivesIt`,
because `xcrun swift-inspect dump-concurrency` showed a task "parked in
`MediaTrashCoordinator.shutdown()`". `2026-11-15-a-card-left-waiting-for-metadata.md` had
already found that task beside the real stall and labelled it a spawned task. This pass asks
why it is there at all.

## The dumps

Three dumps of stalled test hosts (01:45, 01:51 and 03:11) each list the same two tasks:

- a task built from the test's read hook (`closure #1 in closure #4 in closure #1 in
  aPassSuspended…`), resume function `task_future_wait_resume_adapter`, frame
  `MediaTrashCoordinator.shutdown()`;
- created a few task ids earlier, a drain loop shown parked in `AsyncStream.Iterator.next`
  inside `closure #1 in MediaTrashCoordinator.start()`.

No task under Swift Testing's runner carried any frame of the trash suite. The test awaits that
shutdown task's value, so a shutdown that never returned could not have let the test pass.
In the newest frozen run, the test log shows the test passed, in 66.6 s.

## The probe

A program of 30 lines: an actor starts a loop `for await _ in stream {}`. A second task
finishes the stream and awaits the loop task's value. Both tasks then complete, and their
handles are kept. Signed with `get-task-allow` and dumped with `swift-inspect
dump-concurrency`:

- **The finished loop task is listed** with the async backtrace `withUnsafeContinuation` →
  `AsyncStream._Storage.next()` → `AsyncStream.Iterator.next(isolation:)` → `closure #1 in
  Owner.start()`, resume function `withUnsafeContinuation`. That is the same shape as the trash
  drain loop in the dumps.
- **No flag marks it finished.** Its flags read `future`, the same as a live task's.

So the dump lists every task object still allocated, each with the context of its last
suspension. A task that has returned but is still held reads exactly like a parked one.

## Why the trash tasks were held

The test's read hook held the coordinator through a `Mutex<MediaTrashCoordinator?>`, and the
coordinator held the hook (`StoreReads`). That reference cycle kept three things in the test
host for the rest of the run:

- the coordinator;
- its drain task;
- the shutdown task the hook made (through the `Mutex` that held its handle).

The drain task's last suspension was the wake stream's `next()`, just before shutdown finished
the stream. The shutdown task's last suspension was `await drainTask?.value`, and nothing after
that line suspends.
`anItemTheUserTookBackDuringAPassIsNeverMoved` closed the same cycle through its
`willHandleItem` hook.

## Conclusions

- The trash queue's shutdown never stalled. The test leaked its queue, and the dump showed
  the leak as a stall.
- The hooks now reach the coordinator through a weak reference, and the test checks that the
  queue is released once the test lets go of it.
- `script/check.sh` now reports a stalled host as `op=check.hang` lines:
  - **`inFlight`:** only tasks under Swift Testing's runner count as tests in flight.
  - **`mayBeFinished`:** every other task with test frames.
  - **`onThread`:** a test case blocked synchronously is a running task with no async
    backtrace. It is reported by its thread.
  - **`threadStack`:** the `sample` stacks of those threads and of the main thread.
