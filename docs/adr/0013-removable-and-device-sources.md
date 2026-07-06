# ADR 0013: Removable And Device Sources

## Status

Accepted

## Context

Otos already treats the filesystem as the source of truth and stores catalog
overlay as a subordinate projection. Fixed library roots are normalized
filesystem paths selected by the user. Removable media needs a different runtime
shape: cards and cameras appear and disappear, should not pollute the fixed
library view, and still need retained overlay while the source is temporarily
absent.

Two source families are now implemented:

- Removable volumes that mount in the filesystem and can be scanned with the same
  read-only filesystem scanner used for fixed libraries.
- ImageCapture MTP/PTP cameras that do not expose ordinary filesystem paths. They
  provide provisional catalog facts and thumbnails through ImageCapture, then
  stage bytes locally for enrichment while connected.

This decision supports APP-016 through APP-018 and ENR-011.

## MECE Decision Scope

This ADR owns:

- Source identity for removable sources: `volume:<uuid>` for removable volumes
  and `camera:<serial-or-persistent-id>` for MTP/PTP cameras. Transient camera
  identities are process-local and removed on detach.
- The `library_root` source metadata columns: `kind`, `device_identity`,
  `display_name`, and `last_seen_at`.
- The rule that removable sources are catalog roots but are excluded from All
  Media and shown in a separate sidebar/settings surface.
- The monitor ownership split: platform monitors detect attach/detach only;
  `CatalogStore` owns persistence, availability, scan/catalog writes, and
  overlay lifecycle.
- The MTP staging contract: ImageCapture rows point at a local staging root;
  staged bytes are retained only while the camera is connected.
- Connected-source enrichment priority at Store claim time, plus camera eager
  staging order: stills before videos, then capture date, then path.

This ADR references, but does not own:

- Filesystem source of truth and overlay lifecycle, owned by ADR 0008.
- Base catalog schema, scan reconciliation, and private SQLite row ids, owned by
  ADR 0002 and ADR 0010.
- Enrichment storage and worker-pool ownership, owned by ADR 0009.
- Catalog projection, sidebar selection, and one-window UI ownership, owned by
  ADR 0004, ADR 0005, and ADR 0011.

Adjacent decisions requiring separate ADRs or specs:

- User-authored overlay portability/export.
- A future device import/copy workflow that writes originals to a user-chosen
  folder.
- A future metadata inspector or preview/original-load path.
- Provider-specific camera controls beyond ImageCapture catalog/thumbnail/download.

## Decision

1. **Keep one root table, add source metadata.** Fixed libraries, removable
   volumes, and MTP cameras all remain catalog roots because media identity in the
   app is still `(root path, relative path)`. The root row now records `kind`,
   optional `device_identity`, optional raw display name, and `last_seen_at`.
   SQLite row ids remain private persistence keys.

2. **Source identity remaps the current path.** A removable volume can return at a
   different mount path. When the same `device_identity` attaches, Store updates
   the existing root row path and moves runtime state instead of creating a second
   source. This preserves overlay for that source while keeping path identity for
   the current process and current filesystem view.

3. **All Media is fixed-library only.** Removable sources are shown under a
   separate sidebar section and in Settings' removable-media list. Selecting a
   removable source shows that source's cataloged rows; All Media queries filter to
   `kind == library`.

4. **Detaches are absence, not deletion.** A stable removable source detach marks
   the source unavailable, releases enrichment claims, stops filesystem watching,
   and keeps catalog rows plus overlay. Explicit Forget removes the source row and
   its overlay. Transient camera identities are removed on detach because they have
   no durable source identity to preserve.

5. **MTP cameras use ImageCapture plus local staging.** ImageCapture provides
   catalog item names, type, size, dates, and 160x120-ish provisional thumbnails.
   The catalog root path is an app-owned staging directory. Enrichment materializes
   that staging URL by asking the active `DeviceCameraSession` to download the
   corresponding camera item. Staging is swept at startup and deleted when the
   camera disconnects; the catalog rows remain for stable camera identities as
   unavailable overlay.

6. **Connected sources are prioritized at claim time only.** Store's enrichment
   candidate fallback query claims available removable roots before fixed roots.
   The coordinator does not maintain a durable second queue. MTP eager staging is
   seeded into the existing download pool and sorted stills before videos, then by
   capture date and path.

7. **Platform monitors are thin adapters.** `RemovableVolumeMonitor` and
   `CameraSourceMonitor` translate OS events into typed attach/detach inputs.
   They do not write SQLite, decide overlay lifecycle, or perform scan
   reconciliation.

## Consequences

- The schema stays small and direct: one root table with source metadata instead of
  parallel volume/camera tables.
- All Media keeps its meaning as the fixed user library collection.
- Overlay persists across expected disconnects without inventing durable asset
  IDs, fingerprints, sidecars, or import copies.
- MTP originals are not modified or imported. Staged bytes are temporary app
  support for enrichment, not a user media vault.
- Hardware smoke still requires real devices. Unit coverage pins policy, source
  projection, store remap/detach behavior, and staging order.

## Verification

- `OtosTests/CatalogStoreRemovableSourceTests.swift`
- `OtosTests/CatalogProjectionTests.swift`
- `OtosTests/CatalogStoreEnrichmentClaimTests.swift`
- `OtosTests/EnrichmentCoordinatorTests.swift`
- `OtosTests/CameraSourcePolicyTests.swift`
- `OtosTests/CatalogStoreMediaEligibilityTests.swift`
- Local `script/verify.sh` evidence is required by the increment report.
