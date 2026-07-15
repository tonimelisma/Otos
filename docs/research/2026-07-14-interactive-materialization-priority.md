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

## Verification

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
