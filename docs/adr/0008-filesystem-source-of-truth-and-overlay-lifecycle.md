# ADR 0008: Filesystem Source Of Truth And Overlay Lifecycle

- Status: Accepted
- Last updated: 2026-07-10

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
- The authored `MediaChoice` overlay is the first user-authored overlay. It is a
  single mutually exclusive `liked` / `notRated` / `disliked` value, retained
  while the cataloged item exists and purged with the item only on proven deletion
  or root removal. It never writes an XMP sidecar or changes filesystem truth.

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
- Keep pure path identity. A content hash may be retained as a subordinate fact
  about the bytes currently observed at that path, but it never establishes identity
  or preserves overlay across moves. Do not build the data model around durable
  filesystem identifiers or generated UUIDs. A move outside Otos keeps its overlay
  only when ADR 0034's byte-free witness proves it, and the witness never becomes an
  identity.
- No generated sidecars. Do not pollute the user's media folders with Otos-authored
  identity or overlay files. Existing user-owned useful companions (`.xmp` / `.srt`)
  may be inventoried and transferred during explicit import/reorganization. The
  catalog can be made exportable if portability is ever needed.
- Explicit Move to Trash is a user-initiated filesystem mutation owned by ADR 0022: system Trash only, catalog-proven members only, exact-path
  partial reconciliation, and no byte read or materialization request. An item in the
  system Trash is not proven deleted: its row and overlay stay, hidden, until the Trash no
  longer holds its file, so Finder's Put Back returns it with everything Otos held.
- Persisting one thumbnail per asset is acceptable even at a million assets;
  regenerating thumbnails is expensive precisely because most originals are in the
  cloud, so thumbnails are kept, not evicted.

## MECE Decision Scope

This ADR owns:

- The product contract that the filesystem is the single source of truth and the
  catalog plus all overlay is a subordinate, rebuildable projection.
- The no-hostage rule: no opaque app-owned media vault, nothing Otos derives or
  authors written into the user's media folders, and no generated sidecar files
  for identity or authored overlay.
  Existing useful companions may be inventoried/transferred only under explicit
  import or reorganization. Catalog export is the portability answer.
- The single overlay lifecycle: overlay is held while its item exists inside a
  tracked library root, purged in full only on proven deletion, removable-source
  retention (a card or camera unseen for 90 days, ADR 0013), or explicit
  library-root removal, and never purged on temporary absence.
- The definition of proven deletion versus temporary absence.
- Pure filesystem-path asset identity; hashes, durable identifiers, generated UUIDs,
  and sidecars never act as identity mechanisms.
- The cloud materialization policy: a detector gate prevents accidental blocking
  materialization, while deliberate, non-blocking background materialization is
  permitted for enrichment — up to eagerly materializing the whole media library —
  knowing Otos does not free the downloaded bytes itself. The enrichment owner that
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
- Out-of-app move and rename detection: ADR 0034 (the move witness).
- Color management beyond relying on system frameworks.

## Decision

Treat the filesystem as the single source of truth and the catalog as a
subordinate, rebuildable overlay.

1. Otos never relocates originals, never writes into the user's media folders, and
   never generates sidecars for identity or authored overlay. Existing user-owned
   useful companions may be inventoried in `media_companion` and transferred only
   during explicit import/reorganization. All overlay Otos derives or the user
   authors lives only in the Application Support catalog. If portability is needed,
   export the catalog.
2. Otos mutates the user's files only through explicit, opt-in, user-initiated
   actions. Absent such an action, nothing on disk changes.
3. Every overlay for an item shares one lifecycle. It is held for as long as the
   item exists inside a tracked library root and is purged in full, including the
   catalog row, the thumbnail, and any derived values, only when the item is proven
   deleted or when the user explicitly removes that library root from Otos. There
   are no separately purged overlay classes.
4. Proven deletion has two current proof paths. The broad proof is a file that was
   previously cataloged at a root-relative path being absent, or no longer catalog-
   eligible, in a completed enumeration of a reachable root. The narrow proof is a
   supported single-file FSEvent delivered for an armed available root where Store
   checks that exact path and finds it absent, or finds that it now exists only as a
   non-catalog-eligible item, before deleting only that catalog row and its
   thumbnail overlay. Temporary absence — an ejected or offline volume, an
   unreachable root, or a dataless cloud placeholder that still enumerates — is not
   a deletion and must not purge overlay. A cancelled or failed full scan never
   proves deletion.
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
   pair from ADR 0002. Otos does not store durable filesystem identifiers or
   generated UUIDs, and does not write sidecars to track files. A canonical content
   hash is allowed only as subordinate overlay with an explicit current size/mtime
   signature; it never changes identity or moves overlay. An
   out-of-app move appears as a deletion plus an addition, except where ADR 0034's
   witness — the file's identifier, size and creation time, and its old path gone —
   moves the row to the new path in the same write. The witness is a scan fact, not
   part of the identity model. A scan also captures a
   process-local namespace-mutation epoch for its root. Import, reorganization,
   and filesystem-event settlement advance that epoch before their Store write
   and retain typed dirty scopes. If the epoch changes while a scan is suspended,
   the scan may upsert facts it observed but cannot use its stale absence
   observation to purge media or companions; retained dirty scopes reconcile after
   the current lease clears. Explicit import settlement may reuse a source's
   current normalized enrichment overlay when the source `(size, mtime)` facts and
   SHA-1 digest (ADR 0018) agree. Metadata and normalized facts are cloned to the
   destination path identity, while a source thumbnail is copied into an independent
   destination thumbnail through the app-owned staged-promotion path. A reuse miss
   falls back to ordinary enrichment; source and destination overlay lifecycles
   never become linked.
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
   to explicit user action" rule. Otos does not free the bytes it downloads. macOS does:
   a File Provider root's default content policy allows eviction under disk pressure,
   and the system evicts uploaded, idle, unmodified items up to its purge goal — none
   while the provider is down or uploads are pending (research `docs/research/2026-10-25-library-storage-and-previews.md`). The
   `NSFileProviderManager` eviction call fails for a consumer app
   (`NSFileProviderErrorProviderNotFound`); `FileManager.evictUbiquitousItem(at:)`
   evicted OneDrive files in one probe (`trash-dataless-placeholders.md`) but is
   documented for iCloud only, so Otos does not rely on it. Background and device
   downloads never take the volume below the free-space floor (ADR 0027). Eagerly
   materializing the whole media library to enrich it is a permitted, deliberate
   product choice; that enrichment choice, how it prioritizes the viewport, and where the
   derived products are stored are owned by ADR 0009. A provider that definitively
   refuses a byte read with `ETIMEDOUT` (errno 60/110 or "timed out" text) twice
   consecutively on one file is a distinct transient fact `providerUnavailable`:
   `FileMaterialization` short-circuits the 120s wait at `k=2` probes (`~2s` vs 120s)
   with two `FileHandle.read(1)` probes (each kernel-capped at 1s), and
   `MaterializationCoordinator` records a per-root 60s `providerBreakerOpen`
   suppression after two consecutive `providerUnavailable` on that root so the next
   background candidates do not each pay 2s holding a `backgroundPerRootCap`
   slot (four per root, the owner's choice of 2026-10-31).
   Materialization status stays transient and is never persisted. The current
   catalog/scanner still reads only filesystem facts and materializes nothing;
   byte-reading materialization is the enrichment owner's job (ADR 0009). See
   `docs/adr/0009-enrichment-storage-and-staleness.md`.
7. Media metadata and filesystem facts are distinct. Filesystem facts are URL
   resource values (name, size, dates, type, and the dataless flag) readable without
   materialization, and are all the catalog stores today. Media metadata (EXIF and
   similar embedded content, including any embedded preview) requires reading bytes
   and therefore materializes a dataless file, so it is gated on the materialization
   check above. The word "metadata" and the Metadata instrumentation category mean
   media metadata.

Because no user-authored overlay exists yet, the purge-on-proven-deletion or
library-removal rule is currently lossless for derived overlay: everything purged
is rebuildable by re-observing the filesystem after the root is re-added. Import
batch stamps (`import_batch_unix_ms`) are the first non-rebuildable overlay fact:
they cannot be reconstructed from the filesystem alone, so catalog schema changes
must migrate additively and must never erase an unrecognized or future schema
(see ADR 0010). The overlay lifecycle rule is stated now so future authored overlay
inherits a single, predictable lifecycle.

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

### Durable identity via filesystem identifiers, hashes, or UUIDs

Track files across moves and renames with `fileResourceIdentifier`,
`fileContentIdentifier`, a content hash used as identity, or a generated UUID.

Pros:

- Could preserve overlay across out-of-app moves and renames.

Cons:

- Apple states `fileResourceIdentifier` and `volumeIdentifier` are not persistent
  across restarts; `fileContentIdentifier` is an APFS content stream, not path
  identity; using a hash as identity would make a subordinate byte fact authoritative.
- Makes the catalog look authoritative over the filesystem.

Failure modes:

- A filesystem identifier is treated as permanent identity that Apple does not
  guarantee, or a hash is used to relink paths and hashing triggers gigabytes of
  cloud downloads outside an existing deliberate materialization operation.

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

Import provenance is permitted only as filesystem facts about a copy Otos
performed: source root path, source relative path, source byte size and
modification time, plus the settled destination byte size and modification time.
The planner does not read those facts. A SHA-1 content digest (ADR 0018) is also permitted
as subordinate overlay, produced only inside ordinary enrichment or an existing
import worker after its deliberate byte-access gate. It is valid only with the
size/mtime signature of the bytes hashed, never becomes a second asset identity,
and never overrides live filesystem truth.

- Future thumbnail, metadata, and editing work inherits one overlay lifecycle and
  one materialization policy instead of inventing their own.
- The catalog never grows a second identity scheme; path identity stays the only
  one, keeping ADR 0002's model intact.
- Out-of-app moves the ADR 0034 witness cannot prove (across volumes, recreated by a
  provider) lose overlay by design; that is the price of refusing hashes as identity and
  refusing sidecars.
- Reconciliation must distinguish proven deletion from temporary absence. The
  current whole-root availability model (ADR 0005) already prevents purging an
  unreachable root; a user-excluded selective-sync subtree inside a reachable root
  remains a known edge case to revisit when authored overlay exists.
- Persisted thumbnails are durable backed-up overlay, not an evictable cache,
  because regenerating them depends on expensive cloud materialization.
- Background enrichment may silently materialize dataless originals, which grows
  local disk use until macOS evicts uploaded, idle files under pressure; Otos itself
  frees nothing and keeps the free-space floor. ADR 0009 deliberately spends that
  cost for complete enrichment coverage, up to
  eager full-library materialization by the enrichment owner; the scanner itself
  still materializes nothing.
- Path equality follows the volume that owns a root: `FilesystemNameKey` applies
  probed case and Unicode-normalization capabilities while the catalog preserves
  the physical spelling. A remount that respells a path is therefore an update
  to the same overlay row, not proven deletion; this is detailed in ADR 0025.

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
-  and
  `OtosKit/Services/FileMaterialization.swift`: add the verified dataless detection
  mechanism and the media-metadata versus filesystem-facts distinction that
  decisions 6 and 7 reference.
- No comment boundary in current source contradicts this decision; the scanner and
  store comments already describe filesystem-truth reconciliation.

## Reversal Plan

Move detection exists without changing path identity (ADR 0034). If it proves
insufficient, extend that witness rather than adopting byte hashing, so cloud
placeholders are never force-materialized. If authored overlay later proves too valuable to purge on
proven deletion, introduce an orphan-and-relink lifecycle in that feature's spec.
Sidecars remain out of scope unless the no-pollution product promise itself is
revisited with the user.
