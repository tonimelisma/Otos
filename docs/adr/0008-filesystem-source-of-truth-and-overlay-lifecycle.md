# ADR 0008: Filesystem Source Of Truth And Overlay Lifecycle

- Status: Accepted
- Last updated: 2026-06-26
- Specs: `docs/specs/0015-filesystem-truth-and-review-process.md`,
  `docs/specs/0016-cloud-materialization-detection.md`,
  `docs/specs/0021-cloud-materialization-triggering-and-eviction-poc.md`

## Context

Otos is a Lightroom-style library tool layered on media the user keeps on their own
disk, most often inside cloud-synced folders (iCloud Drive, Dropbox, OneDrive,
Google Drive). The defining product promise is that Otos never takes the user's
media hostage the way an import-into-an-opaque-library model does. The filesystem
is the source of truth; Otos is an overlay.

ADR 0002 already decided the catalog persistence layer, the media-asset schema, the
idempotent scan, and that a completed scan of a root deletes unobserved rows. This
ADR raises that narrow persistence statement to a product-wide contract and decides
the lifecycle that governs every overlay Otos will ever store, so that future
thumbnail, metadata, and editing work inherits one consistent rule instead of each
inventing its own.

Verified facts that shaped this decision:

- Cloud providers do not silently sync only part of a tree. A file is either
  materialized locally or a dataless placeholder that still appears in directory
  enumeration. The only way a subtree is fully absent locally is a user-initiated
  selective-sync exclusion, which is the user's explicit choice.
  - [iCloud Drive switched to dataless files in macOS Sonoma](https://mjtsai.com/blog/2023/10/27/icloud-drive-switches-to-dataless-files/)
  - [File Provider and cloud services](https://eclecticlight.co/2026/05/09/explainer-file-provider-and-cloud-services/)
  - [Dropbox selective sync versus online-only](https://teamdynamix.umich.edu/TDClient/30/Portal/KB/Article/6670/Dropbox-Difference-Between-Selective-Sync-and-Online-Only-Files-Folders)
- Reading a dataless placeholder's metadata (name, size, dates, content type) does
  not download it; reading its bytes forces materialization. Apps are expected to
  avoid unnecessarily materializing dataless files. Careless directory traversal or
  byte reads can trigger large downloads.
  - [Apple File Provider guidance](https://developer.apple.com/forums/tags/fileprovider)
  - [Globbing materializes dataless directories on macOS](https://github.com/fish-shell/fish-shell/issues/8399)
- The current scanner reads only metadata resource values and no bytes, so
  cataloging does not materialize cloud files today.
- There is no user-authored overlay in the app yet. Today every catalog row and
  every value stored about a file is rebuildable by re-observing the filesystem.

Captured owner guidance for verification:

- The filesystem is always the source of truth. If the user changes nothing,
  nothing changes.
- The user is allowed to keep duplicates, badly named files, or files in the wrong
  folders. Detecting or fixing those is an optional, opt-in convenience, never
  default behavior, and it operates on the filesystem rather than hiding files.
- Do not split overlay into separately purged classes. Hold every overlay for an
  item for as long as the item exists inside a tracked library root, and purge it
  all when the item is deleted or when the user explicitly removes that root from
  Otos.
- A temporarily missing original is not a deletion. Do not nuke catalog state for
  an ejected drive, a disconnected network or cloud volume, an unreachable root, or
  a dataless cloud item.
- Keep pure path identity. Do not build the data model around content fingerprints,
  durable filesystem identifiers, or generated UUIDs. Out-of-app moves are an edge
  case; a future convenience could detect them by matching thumbnails, but that is
  not a foundation.
- No sidecars. Do not pollute the user's media folders. The catalog can be made
  exportable if portability is ever needed.
- Persisting one thumbnail per asset is acceptable even at a million assets;
  regenerating thumbnails is expensive precisely because most originals are in the
  cloud, so thumbnails are kept, not evicted.

## MECE Decision Scope

This ADR owns:

- The product contract that the filesystem is the single source of truth and the
  catalog plus all overlay is a subordinate, rebuildable projection.
- The no-hostage rule: no opaque app-owned media vault, no writes into the user's
  media folders, and no sidecar files. Catalog export is the portability answer.
- The single overlay lifecycle: overlay is held while its item exists inside a
  tracked library root, purged in full only on proven deletion or explicit
  library-root removal, and never purged on temporary absence.
- The definition of proven deletion versus temporary absence.
- Pure filesystem-path asset identity and the rejection of durable identifiers,
  content fingerprints, generated UUIDs, and sidecars as identity mechanisms.
- The cloud materialization policy: a detector gate prevents accidental blocking
  materialization, while deliberate, non-blocking background materialization is
  permitted for enrichment — up to eagerly materializing the whole media library —
  knowing the downloaded bytes cannot be reclaimed by Otos. The enrichment owner that
  exercises this permission, and where it stores the derived products, are owned by
  ADR 0009.

This ADR references, but does not own:

- The SQLite catalog persistence layer, media-asset schema, in-memory working set,
  and idempotent completed-scan reconciliation, owned by ADR 0002.
- Normalized library-root path identity, unsandboxed access, and overlap rules,
  owned by ADR 0003.
- Transient library availability and the publication/projection model, owned by
  ADR 0005.
- Thumbnail and metadata storage, the staleness signature, and eager full-library
  materialization for enrichment (the application of this materialization policy),
  owned by ADR 0009.

Separate ADRs or specs must own:

- The editing model and any optional on-disk export of edited renders.
- Any out-of-app move or rename detection convenience, including a thumbnail-match
  relink, if it is ever built.
- Color management beyond relying on system frameworks.

## Decision

Treat the filesystem as the single source of truth and the catalog as a
subordinate, rebuildable overlay.

1. Otos never relocates originals, never writes into the user's media folders, and
   never stores sidecars. All overlay, derived or user-authored, lives only in the
   Application Support catalog. If portability is needed, export the catalog.
2. Otos mutates the user's files only through explicit, opt-in, user-initiated
   actions. Absent such an action, nothing on disk changes.
3. Every overlay for an item shares one lifecycle. It is held for as long as the
   item exists inside a tracked library root and is purged in full, including the
   catalog row, the thumbnail, and any derived values, only when the item is proven
   deleted or when the user explicitly removes that library root from Otos. There
   are no separately purged overlay classes.
4. Proven deletion has two current proof paths. The broad proof is a file that was
   previously cataloged at a root-relative path being absent from a completed
   enumeration of a reachable root. The narrow proof is a regular-file remove
   FSEvent delivered for an armed available root where Store checks that exact path
   and finds it absent before deleting only that catalog row and its thumbnail
   overlay. Temporary absence — an ejected or offline volume, an unreachable root,
   or a dataless cloud placeholder that still enumerates — is not a deletion and
   must not purge overlay. A cancelled or failed full scan never proves deletion.
   One case is deliberately outside this current guarantee: a user-excluded
   selective-sync subtree inside an otherwise reachable root enumerates without its
   paths, so `reconcileMissingAssets` cannot today distinguish it from a real
   deletion and will purge it. That is acceptable only while overlay is derived-only
   and rebuildable; preserving such a subtree is a forward invariant a detector must
   satisfy before user-authored overlay ships, not a guarantee the current
   implementation makes. Explicit library-root removal is different from temporary
   absence: the user chose to stop tracking that root in Otos, so Otos drops the
   root's catalog rows and derived overlay without changing originals on disk.
5. Asset identity is the filesystem path, the `(library_root_id, relative_path)`
   pair from ADR 0002. Otos does not store durable filesystem identifiers, content
   fingerprints, or generated UUIDs, and does not write sidecars to track files. An
   out-of-app move therefore appears as a deletion plus an addition. Recovering
   overlay across such a move is an optional future convenience that may match
   newly appeared files to orphaned thumbnails; it is explicitly not part of the
   identity model and must not drive schema design now.
6. Cloud materialization has two parts: an always-on detector gate and a permissive
   policy on top of it. The gate: byte-reading work must never *accidentally*
   materialize a dataless file by faulting on a read, so it checks the single
   `FileMaterialization` owner immediately before any read, using the `SF_DATALESS`
   kernel flag (proof-of-concept measured at ~7 µs/file across a 22k-file library;
   `ubiquitousItemDownloadingStatus` agrees but is ~317× slower and reports stale state
   right after a fault, so it is never used for bulk classification). The policy:
   deliberate, non-blocking background materialization is permitted for enrichment, up
   to and including eagerly materializing the whole media library. An owner may download
   a dataless file it has chosen to enrich through the non-blocking ubiquitous trigger
   (`startDownloadingUbiquitousItem`, proof-of-concept verified to fire for the
   third-party OneDrive provider) and await `SF_DATALESS` clearing off-thread, instead
   of blocking a worker on a read-fault. This reverses the earlier "defer materialization
   to explicit user action" rule. Otos cannot reclaim the bytes it downloads — a consumer
   app cannot evict another provider's files (the proof of concept got
   `NSFileProviderErrorProviderNotFound`) — so local disk growth is a real, unreclaimable
   cost. Eagerly materializing the whole media library to enrich it is nonetheless a
   permitted, deliberate product choice that accepts that growth as the price of complete
   coverage; that enrichment choice, how it prioritizes the viewport, and where the
   derived products are stored are owned by ADR 0009. Materialization status stays
   transient and is never persisted. The current catalog/scanner still reads only
   filesystem facts and materializes nothing; byte-reading materialization is the
   enrichment owner's job (ADR 0009). See
   `docs/specs/0016-cloud-materialization-detection.md`,
   `docs/specs/0021-cloud-materialization-triggering-and-eviction-poc.md`, and
   `docs/adr/0009-enrichment-storage-and-staleness.md`.
7. Media metadata and filesystem facts are distinct. Filesystem facts are URL
   resource values (name, size, dates, type, and the dataless flag) readable without
   materialization, and are all the catalog stores today. Media metadata (EXIF and
   similar embedded content, including any embedded preview) requires reading bytes
   and therefore materializes a dataless file, so it is gated on the materialization
   check above. The word "metadata" and the Metadata instrumentation category mean
   media metadata.

Because no user-authored overlay exists yet, the purge-on-proven-deletion or
library-removal rule is currently lossless: everything purged is rebuildable by
re-observing the filesystem after the root is re-added. The rule is stated now so
that future authored overlay inherits a single, predictable lifecycle.

## Alternatives Considered

### Split overlay into derived and authored classes with different purge rules

Keep purging derived overlay (thumbnails) on absence, but never hard-delete
user-authored overlay (edits, ratings); orphan and relink it instead.

Pros:

- Protects irreplaceable user work from a mistaken purge.
- Supports a Lightroom-style missing-file workflow.

Cons:

- Adds an orphan lifecycle, relink UX, and a second deletion policy before any
  authored overlay exists.
- The motivating cases, constant path reuse and frequent out-of-app moves, do not
  reflect how photo libraries are actually used.

Failure modes:

- Speculative complexity that an authored-overlay spec must revisit anyway.

Rejected for now in favor of one lifecycle. When irreplaceable authored overlay is
designed, that spec revisits whether a user-excluded selective-sync subtree, which
looks identical to a deletion locally, should be exempt from purge.

### Durable identity via filesystem identifiers, content fingerprints, or UUIDs

Track files across moves and renames with `fileResourceIdentifier`,
`fileContentIdentifier`, a content hash, or a generated UUID.

Pros:

- Could preserve overlay across out-of-app moves and renames.

Cons:

- Apple states `fileResourceIdentifier` and `volumeIdentifier` are not persistent
  across restarts; `fileContentIdentifier` is an APFS content stream, not path
  identity; whole-file hashing reads every byte and would force-materialize cloud
  placeholders, defeating the materialization policy.
- Makes the catalog look authoritative over the filesystem.

Failure modes:

- A filesystem identifier is treated as permanent identity that Apple does not
  guarantee, or hashing triggers gigabytes of cloud downloads.

Rejected. Pure path identity is simpler and correct for the real workload. This is
consistent with ADR 0002's rejection of durable identifiers and UUIDs.

### Sidecars next to originals

Mirror authored overlay into sidecar files beside each original.

Pros:

- Survives catalog loss, moves with the file through cloud sync, portable to other
  tools.

Cons:

- Writes into the user's media folders, which violates the no-hostage, no-pollution
  promise.

Failure modes:

- Otos becomes a tool that litters the user's library.

Rejected. Catalog-only storage with optional catalog export is the portability
answer.

### Treat any momentarily unobserved path as deleted

Purge overlay whenever a path is not seen in a scan.

Pros:

- Trivial to implement.

Cons:

- Destroys catalog state for ejected drives, offline volumes, and unreachable
  cloud roots.

Failure modes:

- Routine drive ejection or going offline wipes large parts of the catalog.

Rejected. Purge requires proven deletion from a reachable, completed enumeration.

## Consequences

- Future thumbnail, metadata, and editing work inherits one overlay lifecycle and
  one materialization policy instead of inventing their own.
- The catalog never grows a second identity scheme; path identity stays the only
  one, keeping ADR 0002's model intact.
- Out-of-app moves lose overlay by design. This is acceptable for the real
  workload and is the price of refusing fingerprints and sidecars. A future
  thumbnail-match relink convenience can soften it without changing identity.
- Reconciliation must distinguish proven deletion from temporary absence. The
  current whole-root availability model (ADR 0005) already prevents purging an
  unreachable root; a user-excluded selective-sync subtree inside a reachable root
  remains a known edge case to revisit when authored overlay exists.
- Persisted thumbnails are durable backed-up overlay, not an evictable cache,
  because regenerating them depends on expensive cloud materialization.
- Background enrichment may silently materialize dataless originals, which grows
  local disk use that Otos cannot reclaim (a consumer app has no eviction path).
  ADR 0009 deliberately spends that cost for complete enrichment coverage, up to
  eager full-library materialization by the enrichment owner; the scanner itself
  still materializes nothing.

## Retirement Proof

No existing structure is replaced. This ADR formalizes and extends the
filesystem-truth and reconciliation statements already present in ADR 0002 and the
read-only-originals rule already owned by MED-001. No code, schema, or test is
retired by this decision. The catalog continues to use the ADR 0002 schema with no
new identity columns, no sidecar writers, and no overlay-class split.

## Living Documentation Impact

- `AGENTS.md`: filesystem-truth, no-hostage, opt-in mutation, and overlay-lifecycle
  non-negotiables added; Application Support overlay and cloud materialization
  baseline rewritten. Done in this increment.
- `docs/requirements.md`: new current architecture requirements for filesystem
  truth, overlay lifecycle, path identity, and cloud materialization. Done in this
  increment.
- `docs/adr/0002-catalog-persistence-and-filesystem-scan.md`: still owns the schema
  and scan; it now references this ADR for the product-wide overlay contract.
- `docs/index.md`: this ADR registered. Done in this increment.
- `docs/specs/0016-cloud-materialization-detection.md` and
  `Otos/Services/FileMaterialization.swift`: add the verified dataless detection
  mechanism and the media-metadata versus filesystem-facts distinction that
  decisions 6 and 7 reference.
- No comment boundary in current source contradicts this decision; the scanner and
  store comments already describe filesystem-truth reconciliation.

## Reversal Plan

If a real, measured need to preserve overlay across out-of-app moves appears, add a
move-detection convenience behind the existing catalog owner without changing path
identity, preferring thumbnail matching over byte hashing so cloud placeholders are
never force-materialized. If authored overlay later proves too valuable to purge on
proven deletion, introduce an orphan-and-relink lifecycle in that feature's spec.
Sidecars remain out of scope unless the no-pollution product promise itself is
revisited with the user.
