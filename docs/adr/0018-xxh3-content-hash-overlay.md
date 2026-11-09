# ADR 0018: XXH3-128 Content Hash Overlay

## Status

Accepted

## Context

Otos needs one durable content fact for enriched and newly imported image/video
primaries. The fact is useful for future duplicate work, but it must not become
filesystem identity, change overlay lifetime, write a sidecar, or participate in
the current import collision decision. Hashing also reads every byte, so it must
stay inside the two existing owners that already have deliberate byte-access and
cancellation/materialization boundaries.

## Decision

Use XXH3-128 with the default seed from the exact upstream xxHash v0.8.3 release,
commit `e626a72`. Vendor only the upstream `xxhash.c`, `xxhash.h`, and BSD-2-Clause
license evidence. A tiny local C wrapper exposes the streaming create/reset/update/
digest operations and converts with `XXH128_canonicalFromHash`; Swift consumes that
boundary through `ContentHasher` and the typed `XXH3Digest128` model. The vendored
files stay byte-identical to the release, so the `OtosXXH3` target sets
`CLANG_WARN_DOCUMENTATION_COMMENTS = NO` rather than patching upstream doc comments.

The persisted value is exactly 16 canonical bytes. The typed initializer rejects
all other lengths, and a hash is valid only with the integer-second source size and
mtime recorded for the bytes read. No hexadecimal value is stored or logged. Hash
production is synchronous inside the existing off-main enrichment worker or one of
the existing eight import workers. There is no hash actor, queue, retry ledger,
worker pool, progress UI, or independent lifecycle. Enrichment gates materialization
immediately before opening the file; import hashes its still-local staging file.

`CatalogStore` writes the digest and signature in the same transaction as the rest
of enrichment overlay or import settlement. `ActiveFileOperation` carries an
optional digest across the publish/settle crash window. Recovery uses a journaled
digest and never rereads a published cloud placeholder merely to fill a hash.

Import planning's collision decision remains fact-only: selected live path, live size,
and the shared expected destination mtime; it reads no import provenance. A plan entry
carries the source's current digest so the copy can be verified against it, and so the
plan knows what the libraries already hold: an item whose every member's current digest
matches an available library row (not pending trash) is skipped (`skipInLibrary`) —
renamed, moved, or in another library, it is not copied again. A digest names no file,
so digests arriving after Ready change nothing until the next plan; the bar's counts
hold. A card Erase re-confirms each content match against the catalog before deleting.

Hash production is gated on **byte locality**: a digest is read only from bytes that
are local without a download made for the digest's sake. Each enrichment claim carries
one scope the Store decides from its claim (`EnrichmentClaim`: metadata, a card's
products, or a library's every product) and the row's product stamps (`EnrichmentScope`,
ADR 0009): the set of its stale products the claim covers.

- A **fixed library** row is claimed for every stale product at once — metadata,
  rendering, digest, and its faces (ADR 0047) — and read once for all of them, with the deliberate background
  materialization libraries already get (ADR 0008). A row whose only stale product is
  its digest gets the digest alone: nothing is parsed or rendered again, and no planning
  revision moves, because a digest names no file.
- A **removable volume** is read for metadata first, with a provisional QuickLook
  thumbnail, because metadata is what an import waits on. Its rows are offered for
  their renderings and digests together, from one read, only once no row of that card
  needs metadata — the card is developed and checksummed while it sits idle, in
  anticipation of an import. Its bytes are local, so this downloads nothing. The import
  bracket (ENR-017) withdraws both passes while an import reads the card, and an eject
  quiesces them like any card claim.
- A **camera** (`.deviceMTP`) row is enriched from ranged reads for metadata, with its
  embedded preview as a provisional thumbnail, and is never hashed or rendered in place;
  either would force the whole-file transfer. Its copy gets both at import.

**An import never waits for a checksum.** Pressing Import does not wait for a card's
digest pass to finish. Each copy is still hashed from its local staged bytes — the only
read that proves what the copy holds, because a digest is valid only for the bytes read.
When the card row carries a digest current for the size and mtime the import copied, the
staged digest must equal it: a copy that differs (a failing reader, a flaky hub) is never
published, its entry fails with `reason=digestMismatch`, and the next plan offers it
again. Without a card digest the copy is hashed and published as before. Whether the
staged read limits import throughput is measured, not assumed (plan 0109 increment 0):
until a measurement shows it does, it stays inline.

Import reuse does not read the digest: the copy is the source file, so each of the
source's products is the copy's whenever its stamp names the size and mtime the import
copied (ADR 0009 §9). The copy keeps the digest the import computed.

## Alternatives considered

- **Vendor the upstream C implementation (selected):** the smallest audited
  integration, keeps the exact upstream algorithm and canonical representation, and
  avoids a second dependency lifecycle.
- **A Swift wrapper package:** adds package/build and API surface for no current
  substitution boundary; the C implementation would still be underneath.
- **A new remote Swift wrapper dependency:** adds supply-chain and availability
  risk for a core persistence fact and makes exact version/audit evidence harder.
- **CryptoKit SHA-256:** is platform-native and cryptographic, but costs more bytes
  and CPU than the non-cryptographic identity-independent fact this requirement
  needs; it would also choose a different algorithm than the confirmed contract.
- **No stored hash:** preserves the old model but cannot provide the durable input
  required by the future duplicate feature and would force another producer design.

## Consequences

Every pre-migration row is hash-stale and enters the ordinary enrichment lifecycle
once; there is no migration-time filesystem walk. This accepts the one-time full
byte read for the current library while preserving existing materialization and
claim bounds. The one-time read covers libraries and attached cards; a card is read in
full for its renderings and digests only after its metadata, never while an import
reads it.
Hashes are rebuildable subordinate overlay, not IDs, and their signature makes stale
bytes explicit. Import pays one sequential staging read after the existing system copy,
and that read now also verifies the copy against the card's digest where one exists.

A card row's digest can be wrong only if its bytes changed without a size or mtime
change, which the signature cannot see; the staged comparison then fails the entry
rather than publishing it, which is the safe direction.

The vendored implementation must be refreshed only by a later explicit dependency
decision with new vectors and compatibility review.
