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
boundary through `ContentHasher` and the typed `XXH3Digest128` model.

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

Import planning remains fact-only: selected live path, live size, and the shared
expected destination mtime. It reads neither this hash nor import provenance.

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
claim bounds. Hashes are rebuildable subordinate overlay, not IDs, and their
signature makes stale bytes explicit. Import pays one sequential staging read after
the existing system copy, while keeping the correct copyfile and publication path.

The vendored implementation must be refreshed only by a later explicit dependency
decision with new vectors and compatibility review.
