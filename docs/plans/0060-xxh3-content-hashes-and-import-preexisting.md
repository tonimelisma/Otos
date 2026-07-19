# Plan 0060 — XXH3-128 content hashes and fact-only import preexisting decisions

## Status

Active. Product direction confirmed 2026-07-18.

## Purpose

Add one durable XXH3-128 content hash to every enriched or newly imported media
file without creating a checksum scheduler, checksum queue, checksum worker pool,
or second enrichment lifecycle. Hash production belongs inside the two operations
that already own deliberate byte access:

1. `MediaEnricher` hashes a materialized file as part of that asset's existing
   enrichment operation.
2. `MediaImportExecutor` hashes the completed import staging file as part of that
   entry's existing import worker before exclusive publication.

At the same time, simplify import collision handling. A file at the planner's
selected destination is preexisting solely when its live filename/path, byte size,
and filesystem-precision modification time match the planned output. Import
planning must not use content hashes, import provenance, or byte comparison to
make that decision. Hashes are stored now for a later duplicate-detection feature;
this increment does not design or expose that feature.

This plan supersedes the import-equality portions of ARC-046 and ARC-046A and the
content-fingerprint prohibition in ADR 0008. It does not supersede filesystem-path
asset identity: a hash describes current bytes and never becomes an asset ID.

## Confirmed product contract

The implementation must preserve all of these statements together:

- The checksum algorithm is **XXH3-128 with the default seed**.
- The persisted representation is the algorithm's canonical 16-byte form, not a
  platform-native `high64`/`low64` struct dump and not a hexadecimal string.
- Hashing runs inside existing enrichment/import work. There is no independent
  hashing owner, task stream, scheduling policy, worker count, retry queue, or UI
  progress state.
- Existing enrichment admission, materialization, claim-window, batching, retry,
  and cancellation ownership remains the only enrichment lifecycle.
- Existing import worker width remains eight. Each worker hashes its own staging
  file before publish; no ninth pool or cross-entry hash coordinator is added.
- A preexisting import decision depends only on the selected destination path
  (therefore its filename), byte size, and expected destination mtime.
- Import provenance may remain as history/diagnostic overlay, but it cannot change
  a planner disposition.
- Stored hashes cannot change import planning in this increment. They exist only
  as durable input for future duplicate detection.
- Originals remain read-only. Hashing reads bytes and writes only catalog overlay.
- Hashes are subordinate facts about the bytes currently observed at a filesystem
  path. They are not durable identity, are not written beside originals, and are
  invalid when the path's size/mtime source signature changes.

### Meaning of the three import facts

The comparison is exact and deliberately small:

1. **Filename/path:** the live occupant is at the candidate destination already
   selected by the current folder/name/suffix policy. No global filename search is
   performed.
2. **Size:** both planned source size and live destination size are non-null and
   equal.
3. **Mtime:** live destination mtime equals the mtime the executor would stamp on a
   newly imported destination, using the repository's existing filesystem-second
   comparison.

The third fact must use one shared helper. Today `MediaImportExecutor` derives the
destination mtime from capture-wall time when present, otherwise source mtime.
The planner must call that same pure rule; it must not compare against raw source
mtime when the executor would stamp a capture-wall date. If either size or expected
mtime is unavailable, an occupied candidate is not preexisting and the whole
bundle advances through the existing suffix policy.

## Current-state problem

- `MediaTransferPlanner.catalogDecision` first consults exact import provenance.
  Without matching provenance, an equal-size collision creates a
  `ComparisonRequest`.
- `ContentEqualityChecker` then reads both files in 1 MiB chunks. A dataless cloud
  destination returns `comparisonRequiresMaterialization`, blocking an otherwise
  actionable import plan.
- Current production catalog rows predate usable provenance backfill, so this
  fallback is common. Migration can add nullable columns but cannot infer which
  older source produced a destination.
- `MediaEnricher` currently reads metadata and generates a thumbnail but produces
  no full-content fingerprint.
- `MediaImportExecutor` uses `copyfile(3)` and its callback exposes progress, not
  copied buffers. Calculating a hash during that system copy would require replacing
  a correct metadata-preserving transfer path with a custom copier. This plan keeps
  `copyfile(3)` and performs one sequential read of the completed, still-local
  staging file within the same import worker. That is simpler and preserves copy,
  cancellation, metadata, and publication semantics.

## Invariants

- **H1 — One hash definition.** Every producer and consumer uses the same typed
  `XXH3Digest128` value, default seed, canonical byte order, and 16-byte validation.
- **H2 — Hash validity is explicit.** A hash is usable only when its recorded source
  size and integer-second mtime match the catalog's current source signature.
- **H3 — No accidental materialization.** Enrichment checks
  `FileMaterialization.status` immediately before opening the file for hashing.
  A dataless result follows the existing `.notMaterialized` path through the shared
  materializer; hashing never causes a synchronous provider fault by policy.
- **H4 — Stale completion cannot publish.** Store revalidates size/mtime in the same
  transaction that writes the hash and the rest of enrichment overlay.
- **H5 — Import publishes hash and media atomically.** A successful import settles
  its hash with the destination row. Crash recovery never invents a hash and never
  downloads a published cloud placeholder merely to fill one in.
- **H6 — Planning is fact-only.** Import dispositions are independent of hash,
  provenance, catalog membership of a live occupant, and byte materialization.
- **H7 — Bundle atomicity remains.** A primary plus `.xmp`/`.srt` companions uses
  one suffix. Every occupied member must satisfy the three-fact rule before that
  member is treated as preexisting; otherwise the bundle advances together.
- **H8 — No duplicate lifecycle.** Hashing adds work to existing operations but no
  new long-lived task owner or persisted work queue.

## Stage 0 — Dependency decision and reproducible hash contract

XXH3 is third-party code, so the dependency decision must land before functional
use, in the same PR:

1. Add `docs/research/2026-07-XX-xxh3-128-integration.md` with primary sources from
   the upstream xxHash project: v0.8.3 release/tag and commit, BSD-2-Clause license,
   streaming API, canonical conversion API, official test vectors, and benchmark
   context. Record the local Xcode 27/macOS 27 build and throughput probe described
   in Stage 8.
2. Add ADR 0018 (next free ADR number at implementation time) owning content hash
   algorithm, encoding, validity, and dependency integration. The ADR must compare:
   vendoring upstream `xxhash.c`/`xxhash.h`; a wrapper Swift package; a new remote
   Swift wrapper dependency; CryptoKit SHA-256; and no stored hash. Select the
   smallest audited integration: vendor the exact upstream v0.8.3 C implementation
   and license with a tiny local C module consumed only through an Otos Swift facade.
   Do not copy an unversioned snippet or add a wrapper maintained by an unrelated
   third party.
3. Record the exact upstream tag and commit in a checked-in vendor README and retain
   the upstream license. The vendored directory contains only files needed to build
   XXH3 plus license/version evidence; no CLI, tests, benchmark suite, or unrelated
   algorithms are added to the app target.
4. Update `Otos.xcodeproj/project.pbxproj` so the C implementation is compiled once
   and exposed through a narrow module/header boundary. Keep `xxhash.h` out of Swift
   domain files; only the hash facade imports the C module.
5. Define `nonisolated struct XXH3Digest128: Equatable, Hashable, Sendable` in a
   focused model file. Its initializer from stored bytes rejects lengths other than
   16. Its persistence form is the 16 bytes emitted by
   `XXH128_canonicalFromHash`; its display-only diagnostic form may be lowercase
   hexadecimal but SQL never stores that string.
6. Add `ContentHasher` as a stateless synchronous facade with one production method:
   `hashMaterializedFile(at:shouldContinue:) -> Outcome`. It opens one `FileHandle`,
   streams bounded chunks through `XXH3_128bits_reset/update/digest`, checks
   cancellation between chunks, closes deterministically, and returns typed
   `.complete(digest)`, `.cancelled`, or `.failed(detail)`. Do not make it an actor.
7. Choose one measured chunk size (start at 1 MiB, matching the removed equality
   reader) and document the measurement. Do not pool buffers or add mmap/direct-I/O
   machinery without profiler evidence.

### Stage 0 tests

- Empty input and at least three upstream official vectors produce the canonical
  expected digest.
- Chunked updates at boundaries 0, 1, chunkSize−1, chunkSize, chunkSize+1, and a
  multi-chunk payload match one-shot upstream XXH3-128.
- Canonical bytes round-trip through `XXH3Digest128`; 0-, 15-, and 17-byte values
  are rejected.
- Cancellation stops a multi-chunk read and returns `.cancelled` without a digest.
- Read/open failure returns `.failed` and does not crash or publish partial state.

## Stage 1 — Schema, migration, and typed persistence

Add one additive catalog migration after `v11_import_destination_provenance`.
Use self-describing column names so no independent algorithm discriminator is
needed while only one algorithm exists:

```sql
ALTER TABLE media_asset ADD COLUMN content_hash_xxh3_128 BLOB;
ALTER TABLE media_asset ADD COLUMN content_hash_source_size INTEGER;
ALTER TABLE media_asset ADD COLUMN content_hash_source_mtime INTEGER;
ALTER TABLE active_file_operation ADD COLUMN content_hash_xxh3_128 BLOB;
```

Implementation rules:

- `media_asset.content_hash_xxh3_128` is null or exactly 16 bytes. Add a SQLite
  `CHECK` constraint only if the repo's additive migration mechanism can do so
  without rebuilding the table; otherwise enforce length at the typed read/write
  boundary and cover malformed rows in tests.
- `content_hash_source_size` and `content_hash_source_mtime` are the signature of
  bytes hashed. Mtime uses the same integer-second convention as enrichment.
- All existing rows migrate with null hash/signature. No guessed hash and no
  migration-time filesystem reads.
- `ActiveFileOperation` gains an optional digest so a hash computed before publish
  survives the publish→settle crash window. Update insert, update, fetch, fixtures,
  and journal round-trip tests.
- Extend `EnrichmentResult` with a required digest for `.complete`. Production
  enrichment cannot stamp itself complete without a hash. Test-only constructors
  must pass a real deterministic fixture digest; do not hide missing coverage behind
  a default argument.
- Extend `MediaAsset`/stored row mapping only with the facts needed to answer hash
  validity. Do not publish hashes into SwiftUI window state or tile detail models.
- Add a Store/query method for future domain consumers only if a current test or
  persistence boundary needs it. This increment does not add duplicate queries or
  an index on the hash column.

### Hash staleness and existing-library backfill

Update `EnrichmentLeaseGateway.stalenessSQLPredicate()` and the in-memory
`MediaAsset.needsEnrichment` rule so an asset needs enrichment when:

- the existing metadata/thumbnail size+mtime stamp is missing or stale; **or**
- its XXH3-128 hash is missing; **or**
- its hash size/mtime signature is missing or differs from live catalog size/mtime.

This deliberately sends all pre-migration assets through the ordinary enrichment
lifecycle once. It does not create a hash-only mode: existing metadata and thumbnails
may be regenerated as part of that normal enrichment. For the current approximately
868 GiB catalog, verification must call out the expected one-time full-byte read and
must show that existing materialization admission bounds remain intact.

`CatalogStore.applyEnrichmentBatch` keeps its current per-result source-signature
revalidation. When a result matches, write metadata, thumbnail, digest, hash size,
and hash mtime in the same transaction. When it is stale or deleted, write none of
them and let the existing dirty/retry behavior reclaim fresh facts.

### Stage 1 tests

- Migration from the checked-in pre-v12 fixture adds all four nullable columns and
  preserves every existing row and overlay field.
- Unknown/future schema refusal remains intact.
- Missing hash makes an otherwise-current asset need enrichment.
- Matching digest signature makes an otherwise-current asset complete.
- Size-only and mtime-only changes make both metadata and hash stale.
- A stale enrichment result cannot overwrite the digest for newer bytes.
- A malformed stored BLOB is treated as unavailable/stale, never truncated or
  accepted.
- Catalog deletion/root removal cascades the hash with its `media_asset` row under
  the existing overlay lifecycle.

## Stage 2 — Hash as part of existing enrichment

Modify `MediaEnricher.live` without changing coordinator ownership:

1. Keep the initial materialization gate.
2. Immediately before opening the file for hashing, repeat the gate. If dataless,
   return `.notMaterialized` so the existing coordinator/materializer path owns the
   deliberate transfer.
3. Run `ContentHasher` synchronously inside the already off-main enrichment worker.
   Pass a cancellation predicate derived from the worker task; do not create a child
   `Task`, detached task, operation queue, or hash actor.
4. On cancellation, propagate the existing cancellation/release semantics. On a
   read failure that may be transient, return `.transient`; log the typed reason.
5. Continue with `MediaMetadataReader.read` and thumbnail generation using current
   gates. Return one `EnrichmentResult` containing the digest and the source
   size/mtime captured for the work.
6. Preserve the existing claim until the combined hash+metadata+thumbnail result is
   queued for apply. There is no intermediate hash write and no second claim.

Hash first so a provider eviction before the full sequential read returns through
the materializer before spending work on metadata/thumbnail. Do not attempt to tee
bytes out of Image I/O, AVFoundation, Quick Look, or `MediaMetadata`; those APIs do
not expose one common full-file stream and such integration would create format-
specific hash behavior.

### Stage 2 tests

- One enrichment claim produces one hash, one metadata result, one thumbnail attempt,
  and one combined apply result.
- A dataless gate returns `.notMaterialized` before the hasher opens the file.
- A file that changes size/mtime during hashing is rejected at Store apply and later
  re-enriched.
- Cancellation during hashing releases the existing enrichment claim and schedules
  no separate checksum retry.
- A zero-byte media fixture hashes successfully with the official empty digest and
  follows the existing zero-byte enrichment policy.
- Coordinator claim-window, materialization limits, retry ledger, and shutdown tests
  remain unchanged except for supplying fixture digests.

## Stage 3 — Hash as part of each import worker

Keep the current eight-worker `MediaImportExecutor` task group and
`CopyfileTransfer.copy` behavior. After all primary bytes reach the staging file and
before `.readyToPublish`:

1. Confirm cancellation has not been requested.
2. Hash the primary staging file with `ContentHasher` in that same worker. The staging
   file was just written/downloaded and is the exact byte sequence that will publish.
3. If hashing is cancelled, remove staging and abandon the journal through the current
   cancellation path. If hashing fails, do not publish an unhashed new import: remove
   staging, abandon the operation, log the failure, and count the entry failed.
4. Put the digest on `ActiveFileOperation` and persist journal progress before moving
   the phase to `.readyToPublish`. This is the durable crash boundary.
5. Publish exclusively as today. `settleImportedAsset` writes the digest and the
   destination byte size/mtime signature in the same transaction as import batch,
   provenance, destination row, and companions.
6. The import hash does not mark metadata/thumbnail enrichment complete. A newly
   imported row can still need ordinary enrichment; when enrichment runs it may
   recompute the same digest and atomically replace it with the same value/signature.

For removable-volume imports this adds one local sequential read of staging after
`copyfile(3)`. For MTP imports it adds one local staging read after ImageCapture
download/reuse. It adds no second card read and no second cloud download. Retaining
the system copy path is an explicit simplicity/correctness decision; replacing it
with a custom tee copier is outside this plan unless profiling proves the staging
read dominates import time.

Companion hashes are out of scope. The stored digest describes the primary media
asset only; `.xmp`/`.srt` remain inventoried companions under the existing model.

### Crash recovery

- `.copying` with staging is still discarded and retried; a non-journaled digest is
  discarded with it.
- `.readyToPublish` carries a digest. Recovery that publishes/settles uses it.
- `.publishedPendingSettlement` with a digest settles it without rereading final
  bytes, even if the provider has already made the destination dataless.
- A legacy/null-digest active operation may settle without a hash rather than
  materializing during recovery. The row remains `needsEnrichment` and gets a hash
  through the normal lifecycle later.

### Stage 3 tests

- Volume and mocked-MTP imports persist the expected canonical digest on the settled
  destination row.
- Hash failure/cancellation publishes no final file, removes staging, and abandons
  the journal operation.
- Journal round-trip includes the digest before `.readyToPublish`.
- Recovery after publish settles the journaled digest without invoking a file reader.
- Recovery of a legacy null digest settles safely and leaves the asset needing
  enrichment.
- Eight concurrent imports keep monotonic progress and never create a separate hash
  task owner.
- Imported hash signature uses destination size and the actual stamped destination
  mtime, not source/card mtime when those differ.

## Stage 4 — Replace import byte equality with filename+size+mtime

Make the import planner one-path and remove obsolete machinery.

### Shared expected-mtime rule

Move `MediaImportExecutor.destinationModifiedDate(for:)` into a pure, nonisolated
domain helper usable by planner and executor. It returns:

- capture-wall time converted through `CaptureWallClock` when available;
- otherwise source `contentModifiedAt`;
- nil when neither exists.

Do not use `Date()` as a planner/executor fallback. An unknown date must remain
unknown and follow existing `noUsableDate`/suffix behavior; fabricating the current
time would make plans non-deterministic and prevent convergence.

### Candidate decision table

For each bundle member's selected candidate:

| Live occupancy | Size + expected mtime match | Decision |
|---|---:|---|
| absent | n/a | copy candidate |
| regular file | yes | skip preexisting |
| regular file | no/unknown | advance the whole bundle suffix |
| directory/symlink/special/ambiguous foreign occupancy | n/a | advance suffix |
| reserved by an earlier planned source entry | n/a | advance suffix |

Apply the regular-file row whether or not the occupant is already present in the
catalog. Live filesystem occupancy remains the authority. A matching out-of-catalog
file is preexisting; a matching provenance row cannot override absent or mismatched
live facts.

For a bundle, retain existing reservation and suffix convergence: all physical
members must resolve without collision at the same suffix. A matching member can be
skip-preexisting while another absent member copies only if current bundle semantics
already support that mixed disposition without overwriting or splitting the bundle;
otherwise advance the bundle together. Add the adversarial tests before choosing the
code shape, and preserve the current all-members namespace guarantee.

### Delete obsolete import-equality code

- Remove `ContentEqualityChecker.swift`.
- Remove `ComparisonRequest`, `ComparisonResult`, `ComparisonMemoKey`, comparison
  collections from `ImportPlanBuildOutcome`, and comparison-resolution loops from
  `MediaTransferPlanner`.
- Remove `ContentEqualityChecker` construction/injection and
  `authorizeMaterialization` import-comparison wiring from
  `MediaOperationCoordinator`.
- Remove `.comparisonRequiresMaterialization` and byte-comparison-specific block
  reasons, UI strings, logs, and tests.
- Retain generic filesystem-probe-unavailable failures only where a live size/mtime
  observation truly failed.
- Retain import provenance columns and settlement writes as history/diagnostic facts,
  but delete planner reads of those fields if no remaining current consumer needs
  them in `DestinationOccupantFacts`.

Do not leave the old checker dormant for future duplicate detection. The later
duplicate feature will consume stored hashes through its own verified requirements;
keeping a second present-day import equality path would violate one-action/one-path.

### Stage 4 tests

- Matching selected path + size + expected destination mtime skips with zero byte
  reads when destination is materialized or dataless.
- The same live match skips when no destination catalog row exists.
- Same path+mtime but different size advances suffix.
- Same path+size but different mtime advances suffix.
- Same filename elsewhere does not match; only the selected candidate path matters.
- Matching provenance with mismatched live facts does not skip.
- Matching hash with mismatched size/mtime does not skip; planner does not load hash.
- Matching source raw mtime but mismatching capture-wall-derived destination mtime
  does not skip.
- A completed Otos import replans entirely preexisting using only live occupancy
  facts, including after destination cloud eviction and across app relaunch.
- Source-internal duplicates still receive distinct suffixes.
- Companion collision tests preserve bundle atomicity.
- No import-plan state or overlay copy contains `comparisonRequiresMaterialization`.

## Stage 5 — Requirements, ADRs, architecture, and UI truth

Update current-truth documentation in the implementation PR:

- `docs/requirements.md`:
  - Rewrite ARC-046 import collision acceptance around selected path + live size +
    expected destination mtime; remove exact byte equality, comparison memo, and
    materialization-block language.
  - Rewrite ARC-046A so convergence comes from the three live facts, not provenance.
    Keep single-execution and replan-gating requirements intact.
  - Extend ENR-009/ENR-010 or add the next MECE enrichment requirement for one
    XXH3-128 digest produced and atomically stamped by ordinary enrichment, with
    size/mtime validity and no separate lifecycle.
  - Add/import-map the requirement that successful new imports settle a digest before
    publication recovery completes, without using it for planning.
- ADR 0008: permit a durable content hash as subordinate overlay while explicitly
  retaining path identity, no sidecars, read-only originals, deletion lifecycle, and
  materialization gates. Remove the blanket fingerprint prohibition and replace it
  with the narrower rule that hashes never establish identity or override filesystem
  truth.
- ADR 0009: make hash production part of the single enrichment lifecycle and source
  signature; document the one-time backfill and full-byte read.
- ADR 0017: add import worker hashing and journal/settlement ownership; state that
  collision planning is filesystem-fact-only.
- `docs/architecture.md`: update the where-to-change/dataflow map for
  `ContentHasher`, enrichment hash apply, import hash settlement, and simplified
  planner. Do not add a checksum subsystem box because none exists.
- `ImportPlanOverlay` and footer wording continue to say `preexisting`; remove only
  the now-impossible `needs materialization` comparison reason.

Architecture-boundary file guides must explain the current hash ownership, canonical
encoding, cancellation, materialization gate, stale-result rejection, journal crash
boundary, and why hashes do not participate in import planning. Comments must not
narrate this plan or compare at length with deleted code.

## Stage 6 — Instrumentation and performance evidence

Add machine-greppable diagnostics through the existing facade, without logging
digest values:

- Per enrichment hash: `op=contentHash phase=finish owner=enrichment bytes=…
  elapsedMs=… mbps=…`.
- Per import hash: `op=contentHash phase=finish owner=import batch=… worker=…
  bytes=… elapsedMs=… mbps=…`.
- Fail/cancel: same operation with typed `phase=failed|cancelled`, owner, and safe
  error category; never paths plus digest in one diagnostic payload.
- `ContentHash` signpost interval around only the sequential hash read.
- Import's existing per-file timing adds `hashMs` so staging, hashing, publish, and
  settlement remain separable.

Measure before tuning:

1. Add a deterministic generated local corpus outside media roots (0 B, 1 B, 1 MiB,
   100 MiB, and at least one multi-GiB sparse-disabled file) and record warm/cold
   XXH3-128 throughput on the configured Apple Silicon machine.
2. Profile one normal enrichment and one import batch with `script/profile.sh`.
3. On a bounded real OneDrive sample, verify the hasher starts only after deliberate
   materialization and produces no synchronous dataless read fault.
4. Compare import throughput before/after on the same removable source. Report
   staging-copy and hash spans separately.
5. Verify enrichment never exceeds current claim/materialization/admission bounds
   while the existing library backfills hashes.

Do not respond to a slow measurement by adding hash workers, buffer pools, mmap,
custom copy loops, or a second queue in this increment. Record the evidence and stop;
any architecture change needs a separately verified requirement.

## Implementation sequencing

One implementation increment, one dedicated feature worktree, and one PR unless a
reviewer requires a mechanical dependency/ADR precursor:

1. Stage 0 research + ADR + vendored dependency + facade/vector tests.
2. Stage 1 schema/model/staleness migration with failing-first persistence tests.
3. Stage 2 enrichment integration and coordinator regression tests.
4. Stage 3 import journal/staging/settlement integration and recovery tests.
5. Stage 4 planner simplification and deletion of byte-comparison machinery.
6. Stage 5 current-truth documentation and UI cleanup.
7. Stage 6 local verification, profiling, runtime evidence, and cold code review.

The schema and typed digest land before either producer. Enrichment lands before the
existing-library backfill is considered enabled. Import journal persistence lands
before import publication uses the digest. The planner simplification can be reviewed
independently but must land in the same completed increment so the user-visible 121-
file materialization block is removed.

## Explicit non-goals

- No duplicate finder, duplicate groups, duplicate UI, automatic deduplication,
  deletion, merge, or relinking.
- No import decision based on hash, provenance, capture metadata, thumbnails, or
  byte comparison.
- No hash for `.xmp`/`.srt` companions, thumbnails, metadata JSON, or edited output.
- No perceptual hash, similarity fingerprint, partial-file hash, or cryptographic
  integrity/security claim.
- No separate checksum queue, worker pool, actor, progress UI, admission policy,
  retry ledger, or materialization priority.
- No migration-time filesystem walk or hash backfill outside normal enrichment.
- No custom replacement for `copyfile(3)` without new profiler evidence and a
  follow-up architectural decision.
- No content-addressed storage and no use of a digest as `MediaAssetID`.

## Verification matrix

Run all of the following before merge:

- Focused digest/vector/cancellation tests.
- Catalog migration and future-schema tests.
- Store enrichment staleness, stale-apply, thumbnail lifecycle, and deletion tests.
- Enrichment coordinator materialization, retry, cancellation, drain, and shutdown
  suites.
- Import planner truth-table, bundle/suffix, dataless, and foreign-occupant tests.
- Import executor volume, MTP, cancellation, eight-worker progress, journal, publish,
  settlement, and recovery tests.
- `script/requirements-authority-check.sh`.
- `script/ci-text-hygiene.sh check`.
- Full `script/verify.sh` under the configured Xcode 27 beta.
- Runtime log evidence and Instruments evidence from Stage 6.
- Cold diff-based code review with an adversarial pass for: false preexisting skip;
  stale hash publication; implicit cloud materialization; crash after publish before
  settle; digest endianness/version drift; and a hidden second work lifecycle.

## Definition of done

- Every successfully enriched asset stores a valid canonical XXH3-128 digest with a
  matching size/mtime signature.
- Every newly imported primary stores its digest through crash-safe settlement.
- Existing rows backfill only through ordinary enrichment; no separate hash work
  system exists.
- Import planning classifies preexisting using only selected path, size, and expected
  destination mtime and cannot block on content materialization.
- All obsolete byte-comparison planning code and user-visible comparison block states
  are deleted.
- Hashes remain subordinate overlay and are unused by import planning or any new UI.
- Required ADRs, requirements, architecture map, research evidence, dependency
  license/version record, instrumentation, and tests are current.
- The implementation plan is deleted once all work lands on `main`.
- The implementation PR is merged, branch/worktree cleaned, next-start tree clean,
  remote CI green (or exact billing/quota waiver evidence), and the one final DoD
  report is posted on the PR and sent to the user in full.
