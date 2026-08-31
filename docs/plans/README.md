# Active Plans

Completed plans are removed after their implementation, documentation,
verification, and merge closure.

No active plans.

Plan 0100 (camera import: prove naming from ranges, stage only what is imported) is complete
and was removed at closure. It opened from a live MTP session where a 991-item card staged in
full — 36.5 GB, ~45 minutes — before the Import button could appear, and ~73 GB was written
for one import. Its decisions live in ENR-011 (a device that answers ranged reads is not
staged at all; capability is measured per attach; a failed read is transient), APP-018
(staging cleared at three points, per-instance trees, proven containment before any delete),
ARC-047 (the session holds its last proven naming count across a rebuild), APP-029 and
DES-031 (the bar's track reports the progress of the stage it is in), and ADR 0018 (content
hashing follows byte locality, so `.deviceMTP` is hashed after import).

Plan 0101 shipped as `MediaMetadata` 0.4.1: a transport-independent byte source, a
three-outcome read contract, public read cost, `identify(source:)`, `CachingByteSource`, and
embedded preview descriptors. Its boundary rule — every change must be justifiable to a
second consumer who has never heard of Otos — lives in that package's `ARCHITECTURE.md`.

The residual risk is recorded in `docs/research/removable-volume-and-camera-sources.md`:
every measurement behind the work comes from one Sony body, and a timed run with a card
attached is the next useful measurement.

## Closed## Closed

Plan 0099 (honest import naming and plan stability) is complete across six
increments and was removed at closure. It opened from a card whose import bar
oscillated between "730 new items" and "Checking the card…", and found a
duplicate-creating defect already proven in the catalog: 23 hash-identical video
pairs, both copies written by Otos, in two import batches five minutes apart, each
pair named apart by exactly that video's duration. Its decisions live in ARC-046
(planning revisions split by role — namespace for both roles, naming for the source
only), ARC-057 and ADR 0026 (a naming fact is offered only once enrichment has
*looked*; a durable mtime is a proven fallback, never an assumed one), ARC-047 (a
refresh is not a first check — a published plan survives the rebuild replacing it),
ENR-011 (every offered device seed is staged, none discarded), and ENR-012 (a video
with no embedded date derives its wall from mtime less duration, which names the
file but never stamps it).

Its supervision findings live in `AGENTS.md` ("Supervising long checks") and in
`script/check.sh` plus `script/hooks/guard-long-checks.sh`, added after a verify run
deadlocked and ran 9 h 40 m unnoticed — the cause being long-lived tasks that held
their owner weakly but never exited when that upgrade failed.

Plan 0098 (verification integrity, naming facts, and typing the namespace lease)
is complete across seven increments and was removed at closure. It opened against
a `main` that had been red since at least `40261bf` with five failing tests, and
green was restored in increment 4. Its decisions live in ADR 0015 (constant log
subsystem, no gate hides another), ADR 0025 (normalization is not a per-volume
capability), and ADR 0026 (naming facts answer the naming question; one source
delete owner; the erase lease is scoped to the erase sweep).

Plan 0097 was implemented, verified, merged in PR 291, and removed after
documentation closure.

Plans 0085–0096 are complete and were removed when the implementation, structural
guards, behavioral proofs, and verification closure landed. 0092 (import screen
redesign and design-system adoption) and its spun-off 0093 (grid day headers,
DES-069/APP-030) are both fully landed. 0094 (the OtosKit framework, the unhosted
test bundle, and the in-memory `PreferenceStore`) is fully landed — see ADR 0023
and `docs/research/2026-08-16-unhosted-test-bundle-capability.md` for the decision
and its evidence. 0095 (honest import — MTP correctness, one writer per published
fact, app-wide design system) is fully landed across twelve increments; ADR 0024
(readiness gate and single presentation writer) carries its architectural
decisions forward. 0096 (path equality, settled naming, honest progress) landed
its implementation in `40261bf` and its decisions in ADR 0025 and ADR 0026; plan
0097 closed the remaining integration debt in PR 291.
