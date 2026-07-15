# Interactive Materialization Priority

- Date: 2026-07-14
- Scope: OneDrive loupe latency, materialization ownership, and admission diagnostics

## Runtime observation

Unified logs from the production app showed `20260714_184637.hif` enter preview
materialization at 21:17:54 and complete at 21:19:46: 112,438 ms. During the
wait, enrichment repeatedly admitted unrelated Camera Roll downloads marked
`viewport=false`, commonly six to eight in flight with roughly 150–225 MiB of
logical bytes. The eventual embedded-preview decode was fast relative to the
provider wait.

A 20-minute unified-log query returned about 898,505 Otos records. The dominant
shape was repeated `enrichReject reason=videoEnrichCap`: every scheduler wake
walked and logged the same rejected claimed candidates individually.

## Platform API finding

[`FileManager.startDownloadingUbiquitousItem(at:)`](https://developer.apple.com/documentation/foundation/filemanager/startdownloadingubiquitousitem%28at%3A%29)
starts an asynchronous download but exposes no priority, ordering, or transfer
handle. [`NSFileProviderManager`](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager)
offers identifier-based download requests and progress, but its public request
surface likewise provides no interactive-versus-background priority contract and
would require URL-to-domain/item translation.

Therefore Otos can guarantee ordering only before provider submission. It cannot
claim that an already-issued OneDrive transfer was reordered. The chosen policy
stops new lower-priority dispatch while interactive work is pending or active and
caps eager background work at one physical transfer per root, bounding unavoidable
same-provider contention.

## Decision

One `MaterializationCoordinator` owns interactive, device, and background demand,
per-identity coalescing, admission, Store suppression, and lifecycle diagnostics.
`FileMaterialization` remains the one-URL status/request/polling mechanism.
Admission rejection logs become state-change aggregates rather than candidate ×
wake notices.

### Follow-up regression after PR #122

A second live incident on the same evening exposed that the first shared-owner
implementation had preserved physical admission but lost producer backpressure.
At least 919 enrichment requests entered the coordinator in about 30 seconds.
Loupe joined `20260714_185108.heif` after it had started as background work; the
provider timed out after 120,276 ms and 114 re-requests, and the coordinator did
not publish that completion for about another 67 seconds. CPU was about 192%.

Code inspection found three compounding defects: enrichment created one suspended
task and continuation per discovered placeholder, every request synchronously ran
another scheduler pass on the actor, and an interactive waiter joining an active
background entry did not raise that entry's effective priority. The 67-second
attribution was initially a hypothesis because the implementation did not measure
completion delivery separately from provider time.

## Initial implementation verification

Focused deterministic tests cover priority, same-identity coalescing, the one-root
background cap, reserved capacity, oversized-solo admission, and diagnostic-state
deduplication. A controlled 100-wake blocked-video test produced one unchanged
blocked transition and one later unblocked transition; no `enrichReject` record
remains.

The final Xcode 27 beta `script/verify.sh` run passed. An agent-driven launch
against the configured OneDrive library then entered loupe with Command-2 and
navigated across dataless items. The captured 30-second window contained 7,979
Otos events, 22 aggregate materialization-admission transitions, 23 interactive
request lifecycle records, and zero legacy `enrichReject` records. The first
interactive request dispatched at 22:48:46.976 while one same-root background
transfer submitted at 22:48:40.613 was already active. No later background
dispatch appeared before the interactive sequence ended. Three navigated HEIC
requests materialized in 1,563–1,803 ms; a queued HEIF request was promoted to
interactive without a duplicate transfer. The evidence is preserved locally in
`/tmp/otos-loupe-runtime-final.ndjson`; the full verification transcript is
`/tmp/otos-verify-final2.log`.

This run did not reproduce the original 112-second provider delay. It confirms
the application-level guarantees only: interactive dispatch precedes unstarted
background work, new background dispatch pauses, and at most one already-active
same-root background transfer competes. It does not claim provider-side
reprioritization.

## Scheduler-recovery verification (2026-07-15)

The recovery replaces caller-driven scheduling with one coordinator-owned wakeup
supervisor and restores bounded producer flow. Enrichment keeps at most 32 claimed
identities, hands at most 16 requests to the shared materializer globally and two
per root, and leaves the rest as Store backlog. Each identity has one lifecycle
state. The physical scheduler still admits at most one background transfer per
root. Interactive joins immediately contribute to effective interactive demand.

Deterministic verification includes a 25,000-placeholder library with held
transfers. It retained 32 claim states, two same-root materializer handoffs, and
one physical same-root transfer, then cancelled enrichment waiters and released
all claims during shutdown. A separate join test proved that device work remains
blocked while an interactive waiter shares an already-active background transfer,
then becomes dispatchable when that waiter cancels. The 100-wake diagnostic test
still emits one unchanged blocked transition. `script/verify.sh` passed under
Xcode 27 beta with all tests green; lint remained at the repository's warning-only
policy.

A production-data OneDrive run then reproduced provider failure without the
application-side completion delay. `20260714_184600_001.heif` timed out after
120,178 ms and 105 re-requests; `completionDeliveryMs=0`, and the next same-root
background request dispatched three milliseconds later. Throughout the capture,
`sameRootBackground=1`. The bounded five-minute capture contained 82 Otos events,
six materialization-admission transitions, 19 enrichment-admission transitions,
and zero legacy `enrichReject` events. This disproves
the old 67-second behavior for the recovered scheduler and supports actor mailbox
starvation as the removed application-side cause, while confirming that OneDrive
can independently consume the full 120-second provider timeout.

The automation environment launched and logged the production app but macOS did
not grant the process a foreground WindowServer connection, so synthetic Command-2
and arrow events could not drive a second interactive UI sequence. Interactive
ordering, promotion/join, stale-pane rejection, and lower-priority blocking were
therefore verified deterministically rather than claimed as a second live UI
observation. Runtime evidence is preserved in
`/tmp/otos-recovery-runtime.ndjson`, `/tmp/otos-runtime-stream.ndjson`, and
`logs/run-20260715T073509Z-p20666-prod.log`; the full gate transcript is
`/tmp/otos-verify-materialization-2.log`.
