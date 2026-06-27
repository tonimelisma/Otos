# Spec: Cloud Materialization Triggering, The Background-Download Contract, And The Eviction Constraint

## Classification

- Work type: Research/POC plus dead-code helper addition and a contract change to the
  cloud materialization policy
- Current requirement IDs: revises FND-057; references FND-053, FND-056, FND-059,
  FND-060
- Future idea or candidate links explicitly requested by the user: none
- ADRs: `docs/adr/0008-filesystem-source-of-truth-and-overlay-lifecycle.md`

## Problem

Spec 0016 added `FileMaterialization.status(of:)` (SF_DATALESS detection, no byte
read) and recorded the policy then in force: catalog, thumbnail, and media-metadata
work must never force-materialize dataless cloud files, deferring any download to
explicit, user-visible action. The owner has now decided to change that contract:
Otos may **silently materialize dataless files in the background** to drive future
thumbnail and media-metadata enrichment, rather than waiting for an explicit user
action per file.

Before committing to that direction, three things had to be measured rather than
assumed, because most Otos media is dataless (87% of the real library tested) and a
careless approach either stalls workers for minutes or silently fills the user's
disk:

1. How expensive is it to classify an entire real library by materialization status
   without reading bytes? (Is a whole-library status pass even practical?)
2. Can a download be triggered **without blocking** the calling thread, and does the
   non-blocking trigger work for a third-party File Provider (OneDrive), not just
   iCloud?
3. Can a consumer app **reclaim** the space afterward by evicting files it
   downloaded?

This spec records the POC that answered those questions, the dead-code helpers
retained from it, and the revised materialization contract as the forward
architectural guideline. It does not design the enrichment worker pools; that
architecture is undecided and explicitly out of scope.

## Scope

In scope:

- Record the verified POC results for status classification, non-blocking
  materialization, and eviction against a real OneDrive library.
- Retain the materialization trigger/observe primitives as dead code:
  `downloadingStatus(of:)`, `requestMaterialization(of:)`, and
  `materialize(_:pollInterval:timeout:)` with `MaterializationOutcome`.
- Change the cloud materialization policy in ADR 0008 and `AGENTS.md` to permit
  deliberate, non-blocking, bounded background materialization as the forward
  guideline, and revise FND-057 accordingly without claiming the behavior ships
  today.
- Record the eviction constraint discovered by the POC.

Out of scope:

- The enrichment worker-pool architecture: queues, viewport prioritization, pool
  topology, thumbnail/metadata stores, and the read path to the grid. Undecided; not
  designed here.
- Wiring any helper into a live path. The helpers stay dead until the enrichment work
  is specced.
- Persisting materialization status. It remains transient and is never stored
  (FND-060 unchanged).
- iCloud and other providers, and verification from the signed app bundle. Not tested
  per owner instruction.
- Thumbnail/metadata generation engines and storage. Separate future ADR/spec.

## Definition Of Ready

- [x] Goal, scope, and non-goals are explicit.
- [x] Current repo state was inspected.
- [x] Captured user guidance is restated as precise requirements for user
      verification.
- [x] Observable current requirements and acceptance examples are listed.
- [x] Future ideas and unimplemented requirement candidates are separated from
      `docs/requirements.md`.
- [x] Roadmap, planning, or idea documents are ignored unless explicitly requested.
- [x] Ownership, side effects, persistence, cancellation, errors, progress, privacy,
      instrumentation, and tests are addressed.
- [x] At least three alternatives are compared (materialization trigger mechanism).
- [x] Retirement proof is defined (the eviction prototype is removed).
- [x] A repository-wide stale-document audit is defined.
- [x] A code-comment accuracy audit is defined.
- [x] Performance evidence is defined (the POC timings below).
- [x] Open questions are answered or out of scope.

## Verified POC Results

POC harness: a throwaway executable compiled with `swiftc -swift-version 6 -O`
together with the real `FileMaterialization.swift`, run against a live OneDrive
library at `~/Library/CloudStorage/OneDrive-Personal/Pictures` (21,904 regular files,
19,012 dataless = 87%). It read no bytes during classification and downloaded only the
two smallest dataless files (4,096 bytes each) to exercise the trigger paths. The
harness was deleted after the run; this section is its retained evidence.

| Measurement | Result |
| --- | --- |
| Enumerate + free resource values (no bytes) | 21,904 files in 439 ms (~20 µs/file) |
| `status(of:)` SF_DATALESS classify (no bytes) | 154 ms whole library (~7 µs/file); 2,892 materialized / 19,012 dataless / 0 unknown |
| `ubiquitousItemDownloadingStatus` classify (no bytes) | same split, but 48,966 ms (~2,235 µs/file), ~317× slower; also reported stale after a fault |
| Non-blocking `startDownloadingUbiquitousItem` + SF_DATALESS poll | dataless → materialized in ~4.9 s on OneDrive; worker never blocked |
| Blocking `Data(contentsOf:)` fault | 4 KB file in 1.4 s, but holds the thread for the whole transfer |
| `NSFileProviderManager` eviction from a consumer process | failed: `getDomainsWithCompletionHandler` returns no domains, `NSFileProviderErrorProviderNotFound` (-2001) |

Findings:

- A whole-library materialization-status pass is effectively free via SF_DATALESS
  (~7 µs/file). This measures FND-060's "never persist, always check" as correct and
  cheap; there is no reason to cache or store materialization state.
- `ubiquitousItemDownloadingStatus` agrees with SF_DATALESS but is ~317× slower
  (per-file File Provider round trips) and lags reality immediately after a fault, so
  it must never be used in the bulk/hot path. SF_DATALESS is the only viable bulk
  detector and the only trustworthy post-fault completion signal.
- The non-blocking ubiquitous download trigger fires for OneDrive, a third-party File
  Provider, not just iCloud. So background materialization can be done without
  blocking a worker thread.
- Per-file latency is seconds even for 4 KB files (provider round trip dominates, not
  size), so throughput depends on requesting several downloads concurrently, bounded.
- A consumer app cannot evict another provider's files:
  `getDomainsWithCompletionHandler` returns only the caller's own File Provider
  extension's domains, so Otos gets `ProviderNotFound`. Eviction additionally requires
  the provider-granted evictable capability (`NSFileProviderErrorNonEvictable`,
  -2008). Reclaiming space is therefore the provider's and the OS's job (disk
  pressure) and the user's via Finder "Remove Download" — not Otos's.

## Captured Requirements For User Verification

| ID or label | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| FND-057 (revised) | Non-functional | Byte-reading work consults `FileMaterialization` before any byte access so it never blocks on an accidental read-fault; the current catalog/scanner reads only filesystem facts and triggers no download. The materialization policy that governs future byte-reading enrichment is owned by ADR 0008. | Current | docs/requirements.md, ADR 0008, AGENTS.md |
| MAT-CONTRACT | Architecture | The cloud materialization policy is changed: Otos enrichment may deliberately materialize dataless files via non-blocking background download (it must not block a worker on a read-fault), as the forward architectural guideline. This is not implemented yet; the current app materializes nothing. | Current (as forward guideline in ADR 0008) | ADR 0008, AGENTS.md, this spec |
| MAT-BOUNDED | Architecture | Because a consumer app cannot programmatically reclaim downloaded bytes (POC: `ProviderNotFound`), background materialization must be bounded and treat local disk growth as a real, non-reversible-by-Otos cost. | Current (as forward guideline in ADR 0008) | ADR 0008, this spec |
| MAT-DETECT | Non-functional | Bulk materialization classification uses SF_DATALESS (`status(of:)`); `ubiquitousItemDownloadingStatus` is ~317× slower and stale after a fault and must not be used in the bulk/hot path. | Current | this spec, ADR 0008 |
| MAT-HELPERS | Architecture | The non-blocking trigger/observe primitives are retained as dead code with one owner; nothing calls them until the enrichment work ships. | Current | this spec, `Otos/Services/FileMaterialization.swift` |

## Architectural Alternatives

The settled decision here is the **materialization trigger mechanism**. (The detection
mechanism was settled in spec 0016; the worker-pool architecture is out of scope.)

### Alternative A: Implicit blocking read-fault

Read bytes (`Data(contentsOf:)`, `CGImageSource`, `AVAsset`) and let the kernel fault
the dataless range.

Pros:

- Universal: works for every provider with no special API.
- Simplest possible code.

Cons:

- Blocks the calling thread for the entire transfer (the 50 GB-video 15-minute stall).
- No clean cancellation; the download proceeds even if the caller stops waiting.

Failure modes:

- A worker pool stalls when several large dataless files are read concurrently; on the
  main actor it is a multi-minute hang.

### Alternative B: Non-blocking `startDownloadingUbiquitousItem` + SF_DATALESS poll (selected)

Request the download, return immediately, and observe completion by polling
SF_DATALESS off the calling thread.

Pros:

- Never blocks a worker on the transfer; the awaiting task suspends.
- POC-proven to fire for OneDrive, a third-party provider.
- Uses the same trustworthy SF_DATALESS signal as detection for completion.

Cons:

- Documented for iCloud; third-party support is empirical (proven for OneDrive,
  unverified for Dropbox/Google Drive).
- Polling granularity adds a small latency tail.

Failure modes:

- A provider that ignores the trigger leaves the file dataless until the timeout; the
  caller must treat `timedOut` as "still not local," not as an error to retry forever.

### Alternative C: `NSFileProviderManager` identifier-based control

Bridge the URL to a File Provider item/domain and drive downloads through the manager.

Pros:

- The lowest-level, most capable File Provider surface.

Cons:

- Identifier- and domain-keyed, provider-specific, and gated to the owning provider:
  the POC showed a consumer process gets `ProviderNotFound` for the domain.
- Heavier than the ubiquitous trigger for the same outcome.

Failure modes:

- A consumer app cannot obtain another provider's domain, so this path is unavailable
  for the common case (the same gate that blocks eviction).

## Selected Approach

Alternative B for triggering, SF_DATALESS for both detection and completion. The
retained helpers wrap exactly this: `requestMaterialization(of:)` fires the
non-blocking trigger, `materialize(_:pollInterval:timeout:)` requests then polls
SF_DATALESS until materialized or timeout, and `downloadingStatus(of:)` exposes the
ubiquitous status for per-item progress only (never bulk). Eviction is not offered:
the POC proved it is unavailable to a consumer app, so reclaiming space is left to the
OS and the user.

The materialization **policy** changes accordingly. The old contract forbade
materialization outside explicit user action. The new contract permits deliberate,
non-blocking, bounded background materialization for enrichment, while keeping the
detector gate so work never *accidentally* blocks on a read-fault. This is the forward
architectural guideline in ADR 0008; the current app still materializes nothing.

## Interfaces, Ownership, And Data Flow

- `Otos/Services/FileMaterialization.swift`, `nonisolated enum FileMaterialization`:
  - `static func status(of: URL) -> FileMaterializationStatus` (from spec 0016).
  - `static func downloadingStatus(of: URL) -> URLUbiquitousItemDownloadingStatus?` —
    per-item progress/cross-check; not for bulk use.
  - `static func requestMaterialization(of: URL) throws` — non-blocking trigger.
  - `static func materialize(_: URL, pollInterval:timeout:) async -> MaterializationOutcome`
    — request plus off-thread poll; honors cancellation between polls; reads no bytes.
  - `nonisolated enum MaterializationOutcome` — `alreadyMaterialized`, `materialized`,
    `requestFailed`, `timedOut`, `cancelled`, `statusUnavailable`.
- No actor isolation, no shared mutable state, `Sendable` by construction. No
  persistence: results are computed on demand and discarded.
- No live caller in this increment. A future enrichment owner will call these from its
  own background context, bounded, off the main actor.

## Retirement Proof

A prototype `evict(_:)` helper, its private `EvictFailure`, the `EvictionOutcome`
enum, and the `import FileProvider` it required were written during the POC and are
removed in this increment. The POC proved eviction is unavailable to a consumer app
(`ProviderNotFound`), so a non-working helper would be a wrong abstraction; the finding
is recorded here and in ADR 0008 instead. No other structure is retired. The catalog
schema, scanner, and runtime behavior are unchanged.

## Living Documentation And Comment Audit

- Added: this spec; registered in `docs/index.md`.
- Updated: `docs/adr/0008-filesystem-source-of-truth-and-overlay-lifecycle.md`
  (decision 6 and its alternatives/consequences: the materialization policy now
  permits deliberate non-blocking bounded background materialization, records the
  eviction constraint, and cites this spec); `AGENTS.md` (the dataless baseline
  paragraph); `docs/requirements.md` (FND-057 revised, marked Changed).
- `Otos/Services/FileMaterialization.swift`: the materialization-helpers file guide
  states the three mechanisms, why the non-blocking trigger is chosen, that the
  helpers are dead, and that the status is transient. The eviction comment block is
  removed with the helper.
- No claim in any updated document asserts that background materialization ships
  today; each states it as the forward guideline while the current app materializes
  nothing.

## Instrumentation And Performance

- The POC timings above are the performance evidence for the detection and trigger
  cost. They are recorded here rather than collected from a live path because nothing
  is wired in.
- When a future enrichment owner wires these in, it instruments materialization
  requests and completions at its batch boundary under `FileAccess` or `MediaIO`
  (count requested, materialized, timed-out, bytes pulled), never per file inside
  these functions, consistent with spec 0016.

## Code-Smell Review

- Dead code: intentional and documented, matching the spec 0016 precedent. Not
  unit-tested because only a live File Provider produces a dataless placeholder; the
  POC is the evidence (owner accepted POC-validated only).
- Stringly typed facts: avoided via typed `MaterializationOutcome`.
- Diagnostic payload sprawl: not applicable; no media content is logged.
- Wrong abstraction: avoided by removing the non-working eviction helper rather than
  keeping it.

## Acceptance Criteria

- `FileMaterialization` exposes `downloadingStatus`, `requestMaterialization`, and
  `materialize` returning `MaterializationOutcome`; the file compiles under Swift 6 and
  reads no bytes in any of them.
- No code path persists materialization status, and no eviction helper or
  `FileProvider` import remains in the app.
- ADR 0008 decision 6 states the revised materialization policy and the eviction
  constraint and cites this spec; `AGENTS.md`'s dataless paragraph matches; FND-057 is
  revised and marked Changed; none of them claim the behavior ships today.
- This spec records the POC results and is registered in `docs/index.md`.

## Verification

- Local checks: `script/verify.sh` (lint, requirements-authority, build, test).
- Focused tests: none added; the trigger paths require a live provider and are
  POC-validated (owner-accepted), consistent with spec 0016's dataless branch.
- Performance/log evidence: the POC results table above.
- Stale-document audit: completed across ADR 0008, `AGENTS.md`, `docs/requirements.md`,
  `docs/index.md`, and the helper file guide.
- Code-comment accuracy audit: the helper file guide describes the retained mechanics;
  the eviction comment is removed.
- CI expectations: fast gate green; remote CI does not run Xcode 27 build/test.
