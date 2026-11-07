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

- Source identity for removable sources: `volume:<uuid>` for removable volumes,
  with a mount-path runtime suffix only when duplicate mounted UUIDs collide, and
  `camera:<serial-or-persistent-id>` for MTP/PTP cameras. Transient camera
  identities are process-local and removed on detach.
- The `library_root` source metadata columns: `kind`, `device_identity`,
  `display_name`, and `last_seen_at`.
- The rule that removable sources are catalog roots but are excluded from All
  Media and shown in a separate sidebar/settings surface.
- The monitor ownership split: platform monitors detect attach, quiesce, resume,
  and detach events only; `CatalogStore` owns persistence, availability,
  scan/catalog leases, quiesce/resume state, and overlay lifecycle.
- The MTP staging contract: ImageCapture rows point at a local staging root;
  staged bytes are retained only while the camera is connected.
- Connected-source enrichment priority at Store claim time, plus camera eager
  staging order: stills before videos, then capture date, then path, without
  enabling cloud eager materialization.

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

4. **Quiesce/eject and detach are separate.** A user eject or an unmount request
   (DiskArbitration's unmount approval, which every unmount passes through, Otos's own
   included) first quiesces the source, drains in-flight enrichment for that
   root, and leaves catalog rows plus overlay intact. A failed eject resumes the
   source instead of detaching it. A confirmed unmount/disappearance marks the
   source unavailable, releases enrichment claims, stops filesystem watching, and
   preserves rows plus overlay, and stamps `last_seen_at` with the detach time — a
   source is last seen when it leaves as well as when it arrives. Explicit Forget
   removes the source row and its overlay. **Retention:** at launch, before any
   source re-attaches, a source that is not attached and whose `last_seen_at` is more
   than 90 days old (`RemovableSourceRetention.unseenPeriod`) is forgotten through the
   same removal as Forget, likes on never-imported photos included (owner decision
   2026-10-25). A source with no stamp is kept. A source still attached
   when Otos quits keeps its arrival stamp, so retention can count from up to one
   session early. The period is a product rule, not a stand-in for a fact (ADR 0033):
   no report can say an absent device will never return. Transient camera identities are removed on detach because they have no
   durable source identity to preserve. Every removable report comes from
   DiskArbitration alone — disk appeared, volume path changed, unmount requested,
   disk disappeared — on one serial queue into one ordered stream with one consumer,
   so a detach is never handled before the quiesce that preceded it; NSWorkspace's
   mount notifications are not used, because two sources on two queues cannot agree
   on an order. ImageCaptureCore's browser and session reports likewise feed one
   ordered stream per owner.

5. **MTP cameras use ImageCapture plus local staging.** ImageCapture provides
   catalog item names, type, size, dates, and 160x120-ish provisional thumbnails.
   The catalog root path is an app-owned staging directory. Enrichment materializes
   that staging URL by asking the active `DeviceCameraSession` to download the
   corresponding camera item. Store issues a process-local enumeration lease for
   each camera attach; batches can upsert observed rows only while that lease is
   current, and deletion reconciliation runs only after a stable catalog snapshot.
   Partial or unstable ImageCapture snapshots are fail-closed: they may make
   observed rows visible, but they do not prove that unobserved rows were deleted.
   The catalog follows the camera while it is connected: one `CameraCatalogSync` per
   camera runs a pass at attach and one more each time the camera reports an add,
   remove or rename after its catalog is complete (a newest-wins doorbell, so passes never
   overlap), staging and thumbnailing only items no earlier pass saw. Re-running the
   whole attach flow per report was rejected: it re-requested every thumbnail and
   re-queued every staging seed.
   Staging is swept off the MainActor at startup and deleted when the camera
   disconnects; the catalog rows remain for stable camera identities as unavailable
   overlay.

6. **Connected sources are prioritized at claim time only.** Store's enrichment
   candidate fallback query claims available removable roots before fixed roots.
   The coordinator does not maintain a durable second queue. MTP eager staging is
   submitted through the shared materializer at device priority, sorted stills
   before videos and then by capture date and path, so it can dispatch without
   flipping the cloud eager-download latch. Low-space device staging failures pause
   for retry rather than busy-looping as timeouts.

7. **Removable volumes are read in place and never hashed during enrichment.**
   MTP stages because ImageCapture is not a filesystem. A `.removableVolume` is a
   real filesystem, so enrichment reads it in place — metadata ranges and
   thumbnail portions only — and deliberately never computes a content hash there
   (ADR 0018). A full read of the card is deferred to import, where the
   destination's still-local staged copy is hashed once at local-disk speed. This
   was a previously unexamined default (bandwidth was never weighed); the choice
   is now explicit: in-place reads plus import-time hashing, not wholesale staging
   of removable volumes to local cache, which remains an open disk-cost tradeoff.

8. **A returning source shows what this attachment has read, as it reads it.** A
   source's retained rows describe what it held when last read, and a card is
   routinely erased, formatted or refilled in a camera in between. On attach every
   retained row is marked `awaiting_presence`; each scan or enumeration upsert that
   observes the file clears it, and the completed read deletes what it never saw.
   While marked, a row is in no user-facing read (the one scope clause), no import
   plan and no enrichment claim, but it keeps every overlay, so a file still on the
   card reappears with its thumbnail the moment the read reaches it. Detach and launch
   clear the mark — with no attachment, nothing is awaited — and so does a read that
   fails or ends without completing, which proved neither presence nor absence (ADR
   0032 rule 4): the source then shows the rows it last held, never a partial or empty
   card. A card resumed after a refused eject is read again. Field trace 2026-11-06: an inserted
   card showed 32 tiles it no longer held, and its import bar planned from them, until
   its scan deleted 68 stale rows. Rejected: deleting retained rows at attach (throws
   away overlay for files still present); showing them dimmed until confirmed (shows
   files the card may not hold, which is the fault being fixed); a per-attachment
   generation column (needs a durable counter for a process-local fact the boolean
   already answers).

9. **A card is read in its own scan lane.** Filesystem scans hold a lease per lane:
   fixed libraries share one, since they live on the system disk or behind a file
   provider and walking two at once only slows both; each card is its own device and
   has a lane of its own. In the field trace above the card's one-second scan waited
   12.8 s behind a launch rescan of a 16,000-file library. Rejected: queue priority
   alone (a library walk already running still holds the one lane); cancelling the
   library walk (newer work never cancels published work, ADR 0032 rule 3).

10. **Platform monitors are thin adapters.** `RemovableVolumeMonitor` and
   `CameraSourceMonitor` translate OS events into typed attach/detach inputs.
   They do not write SQLite, decide overlay lifecycle, or perform scan
   reconciliation.

## Consequences

- The schema stays small and direct: one root table with source metadata instead of
  parallel volume/camera tables.
- Removable roots also persist the probed case-sensitivity and Unicode-normalization
  capabilities, plus the observed device model and volume format, so path equality
  and disk-image filtering remain tied to the source's actual namespace.
- All Media keeps its meaning as the fixed user library collection.
- Overlay persists across expected disconnects without inventing durable asset
  IDs, fingerprints, sidecars, or import copies.
- MTP originals are not modified or imported. Staged bytes are temporary app
  support for enrichment, not a user media vault.
- Hardware smoke still requires real devices. Unit coverage pins policy, source
  projection, store remap/detach behavior, and staging order.

## Verification

- `OtosTests/CatalogStoreRemovableSourceTests.swift`
- `OtosTests/CatalogStoreRemovablePresenceTests.swift`
- `OtosTests/ScanLeaseControllerTests.swift`
- `OtosTests/CatalogProjectionTests.swift`
- `OtosTests/CatalogStoreEnrichmentClaimTests.swift`
- `OtosTests/EnrichmentCoordinatorTests.swift`
- `OtosTests/CameraSourcePolicyTests.swift`
- `OtosTests/CatalogStoreMediaEligibilityTests.swift`
- `OtosTests/FileMaterializationTests.swift`
- Local `script/verify.sh` evidence is required by the increment report.
