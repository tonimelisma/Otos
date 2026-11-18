# ADR 0018: SHA-1 Content Digest Overlay

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

Use SHA-1 through CryptoKit's `Insecure.SHA1`. It is the digest Immich reports as an uploaded
asset's `checksum`, so a library's copy and an account's are compared with no download (ADR
0053). It is a content fact, not a security boundary. No library is vendored, and no C target
exists for it.
- `ContentHasher` streams a file through it in 1 MiB reads.
- The typed `ContentDigest` holds exactly 20 bytes, and its initializers reject any other
  length. It reads Immich's Base64 `checksum` too.

The persisted value is the 20 bytes (`media_asset.content_sha1`). A digest is valid only with
the integer-second source size and mtime recorded for the bytes read.
`ContentDigestSQL.isCurrent` is the one test that a row's digest names its current
`(size, mtime)`. Every reader of the digest uses it, the copy triggers included (ADR 0054).
It tests the stored columns, so `idx_media_asset_content_sha1`, which holds them, answers a
scan of every digest with no table read. A virtual generated column would not: SQLite never
serves one from an index. No hexadecimal value is stored or logged.

Hash production is synchronous, inside the existing off-main enrichment worker or one of the
existing eight import workers. There is no hash actor, queue, retry ledger, worker pool,
progress UI, or independent lifecycle. Enrichment gates materialization immediately before
opening the file; import hashes its still-local staging file.

`CatalogStore` writes the digest and signature in the same transaction as the rest of the
enrichment overlay or the import settlement. `ActiveFileOperation` carries an optional digest
across the publish/settle crash window. Recovery uses a journaled digest and never rereads a
published cloud placeholder merely to fill a hash.

A source that states the digest of an item's bytes gives it with its listing
(`SourceListedItem.sourceDigest`). The row takes it, stamped with the facts the same listing
wrote. A size the source reports later fills the stamp's missing size (ADR 0054).

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
  revision moves, because a digest names no file. Such a row is never downloaded: while
  its original is not local, the Store holds it until its bytes are (ADR 0009 §12).
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

- **CryptoKit SHA-1 (selected):** platform-native, no dependency, and the digest Immich
  reports, so copies across a library and an account compare with no download. It hashes at
  1.6–2.0 GB/s on one core of an M1 Pro, far less than the read and the rendering cost per
  file (`docs/research/2026-11-14-one-photo-many-copies.md`).
- **XXH3-128 from vendored xxHash (until 2026-11-14):** faster, but it matches no source's
  digest. Pairing an Immich asset with a library file would have needed the asset's original
  downloaded, which Otos does only for the user's own work (ADR 0046 §4). It also needed its
  own C target and a membership exception for every Swift file.
- **XXH3 and SHA-1 side by side:** two digests answering one question.
- **CryptoKit SHA-256:** about as fast, but no source reports it.
- **No stored hash:** cannot provide the durable input Duplicates and copies need.

## Consequences

Migration v60 cleared every XXH3 digest, so every row became hash-stale and entered the
ordinary enrichment lifecycle once. There is no migration-time filesystem walk. This accepts the one-time full
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
