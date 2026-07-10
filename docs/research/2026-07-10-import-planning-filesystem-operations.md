# Import planning, filesystem operations, and recovery research

Date: 2026-07-10
Scope: current Otos, `../gomediaimport`, the last integrated import implementation
in `../Otos Studio_old`, and current Apple filesystem/device APIs.  This is
research input for plan 0055, not authoritative implemented behavior.

## Questions

1. Which parts of `gomediaimport` are the product baseline for Otos import?
2. Which lessons from the retired desktop implementation remain useful without
   restoring its complexity?
3. Can one deterministic planning core drive both removable-media import and
   in-place library reorganization?
4. What guarantees can FSEvents, Foundation file operations, and ImageCaptureCore
   actually provide?
5. What is the smallest durable state needed for import history, idempotence, and
   crash recovery?

## Repositories inspected

### Current Otos

The current app already has most of the source and destination facts an import
planner needs:

- `CatalogStore` is the single SQLite/runtime catalog owner. It knows fixed
  libraries, removable filesystem roots, staged ImageCapture camera roots,
  availability, scanning, enrichment, and path-based `MediaAssetID` values.
- `CatalogProjection` publishes browser state; views stay passive and do not query
  SQLite. Visible tile details are fetched separately so the grid does not copy a
  full asset map on each publication.
- `EnrichmentCoordinator` owns byte-reading metadata/thumbnail work. The scanner
  records filesystem facts only, so a source can finish inventory before every
  item has a metadata-derived date.
- `CatalogFilesystemWatcher` watches known filesystem roots with per-file events,
  `IgnoreSelf`, `MarkSelf`, and a 0.1 second latency. Store adds a one-second
  debounce and falls back to a full scan for dropped/ambiguous events.
- Originals are filesystem-owned and path is identity. Catalog and overlay are
  subordinate. A successful reorganization therefore has to remap path identity
  and retain all overlay; it must not invent a durable content identity.
- SQLite currently opts into `eraseDatabaseOnSchemaChange`, and unsupported
  schemas can be reset. That was safe while all stored data was rebuildable. It is
  not safe once user-visible import history is durable overlay.
- The scanner currently catalogs image/raw/video only. It does not retain useful
  companion-file facts, and ImageCapture enumeration currently asks not to receive
  sidecars.

Relevant current files:

- `Otos/Stores/CatalogStore.swift`
- `Otos/Stores/CatalogStorePersistence.swift`
- `Otos/Stores/CatalogQueryGateway.swift`
- `Otos/Services/CatalogScanner.swift`
- `Otos/Services/CatalogFilesystemWatcher.swift`
- `Otos/Services/EnrichmentCoordinator.swift`
- `Otos/Services/CameraSourceMonitor.swift`
- `Otos/Models/CatalogModels.swift`
- `Otos/ViewModels/CatalogWindowViewModel.swift`
- `Otos/Views/SidebarView.swift`
- `Otos/Views/SettingsView.swift`

### `gomediaimport` gold standard

The inspected `gomediaimport` main checkout is clean. Its focused race-enabled
test suite passed:

```text
go test -race ./cmd/gomediaimport
ok github.com/sondregronas/gomediaimport/cmd/gomediaimport 1.616s
```

Its useful baseline is behavioral, not a Go-to-Swift type translation:

- recursively enumerate the whole source and exclude source-system artifacts;
- extract media dates, with filesystem modification date as a final fallback;
- place media either flat or in `YYYY/MM`, with optional date-based names;
- resolve collisions with deterministic numeric suffixes;
- compare an already-existing destination candidate before deciding it is a
  duplicate;
- build a dry-run plan before mutating files;
- copy through a bounded worker pool;
- optionally delete successfully imported sources and eject when done;
- associate useful sidecars with their primary media.

The CLI computes xxHash64 values to classify existing candidates. Otos should keep
the classification behavior but not the implementation choice: xxHash would add a
dependency or custom algorithm, and a persisted content hash would conflict with
path identity. A native, on-demand comparison is a better desktop boundary.

Relevant files:

- `../gomediaimport/README.md`
- `../gomediaimport/cmd/gomediaimport/import.go`
- `../gomediaimport/cmd/gomediaimport/file_operations.go`
- `../gomediaimport/cmd/gomediaimport/media_types.go`
- `../gomediaimport/cmd/gomediaimport/*_test.go`

### Retired `Otos Studio_old` import engine

The working tree contains unrelated pre-existing fixture deletions and was not
modified. The import implementation is absent from its current checkout, so the
last integrated snapshot before removal was inspected from Git at
`c799517afc75e0eddcb4c60900829be515412b66` (with the later removal chain checked
to ensure planner/executor blobs did not materially change first).

Useful lessons:

- make a plan immutable and reserve every destination before execution;
- track both source and destination dependencies;
- represent copy, skip, sidecar, cleanup, and conflict outcomes explicitly;
- use destination-local staging and no-overwrite publication;
- bound filesystem and camera concurrency separately;
- persist enough recovery state to distinguish abandoned staging from a file that
  was already published but not yet settled in the catalog;
- treat cleanup/eject as later phases, not proof that copying succeeded.

The retired design also persisted a large job/plan graph, used durable fingerprints
as proof, and carried a broad executor/recovery surface. Those mechanisms solve
more than the confirmed current product requires. Reusing their concepts does not
justify reinstating their structures.

## Apple API findings

### FSEvents is invalidation, not a transaction lock

Apple's FSEvents guide says events may be coalesced, latency is deliberate, and
clients must rescan when event history is dropped or cannot be trusted. Per-file
events improve targeting but do not make delivery synchronous with a filesystem
operation. `IgnoreSelf` suppresses events produced by the watching process, while
`MarkSelf` permits identification when self events are included.

Consequences:

- an event should increment a root's planning revision and invalidate/rebuild an
  affected ready plan;
- events arriving during a root scan must arrange another reconciliation instead
  of being discarded merely because watching is not yet armed;
- an executor cannot treat “no FSEvent arrived” as proof that source/destination
  remained unchanged;
- immediately before each operation, compare the source's cheap planned facts
  (path, size, modification date) and publish to a non-existing destination;
- Otos should keep `IgnoreSelf`, explicitly settle its own writes in Store, and
  avoid processing every import/reorganization twice.

Sources:

- [File System Events Programming Guide](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)
- [FSEventStreamCreateFlags](https://developer.apple.com/documentation/coreservices/file_system_events/1455376-fseventstreamcreateflags)
- [IgnoreSelf](https://developer.apple.com/documentation/coreservices/1455376-fseventstreamcreateflags/kfseventstreamcreateflagignoreself?language=objc)
- [FSEventStreamEventFlags](https://developer.apple.com/documentation/coreservices/file_system_events/1455361-fseventstreameventflags)

### Foundation file operations are the correct default

`FileManager.copyItem(at:to:)` is a synchronous OS file copy and APFS may implement
copies as clones. `moveItem(at:to:)` fails rather than replacing an existing
destination and can copy-then-remove across volumes. `NSFileCoordinator` provides
coordinated read/write/move access for files managed by providers or other file
presenters, but it is blocking and must run off the main actor.

Consequences:

- use Foundation operations off-main and trust successful OS completion; do not
  reread the new file merely to “verify the copy”;
- stage an import on the destination volume, then publish without overwrite so a
  crash cannot expose a partial final file;
- coordinate source reads and destination writes/moves per operation, especially
  for cloud-synced fixed libraries;
- add a focused implementation probe for exclusive final publication. The local
  SDK exposes `renamex_np(..., RENAME_EXCL)` and `copyfile` exclusive flags; use
  them only if the documented Foundation no-overwrite behavior cannot close the
  measured race on supported filesystems.

Sources:

- [FileManager](https://developer.apple.com/documentation/foundation/filemanager)
- [FileManager.moveItem](https://developer.apple.com/documentation/foundation/filemanager/moveitem%28at%3Ato%3A%29)
- [About Apple File System](https://developer.apple.com/documentation/foundation/about-apple-file-system)
- [NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator)

### ImageCapture camera facts and sidecars

`ICCameraFile` exposes camera-provided modification dates and `sidecarFiles`.
`ICCameraDevice` provides delete requests/capability. Camera download success is
the byte-transfer boundary; source cleanup is a separate device request.

Consequences:

- request camera sidecars and convert them into the same lightweight companion
  facts used for filesystem sources;
- use embedded capture metadata first and real camera modification-date fields as
  the final date fallback;
- if neither exists, the item does not satisfy the no-dateless-media invariant and
  the source remains blocked with a real error. Do not substitute “now”;
- do not delete camera files until the destination file is published and catalog
  settlement is durable, and only when the user-enabled cleanup policy requests
  deletion.

Sources:

- [ICCameraDevice](https://developer.apple.com/documentation/imagecapturecore/iccameradevice)
- [ICCameraFile.fileModificationDate](https://developer.apple.com/documentation/imagecapturecore/iccamerafile/3131457-filemodificationdate)
- [ICCameraItem.modificationDate](https://developer.apple.com/documentation/imagecapturecore/iccameraitem/modificationdate)
- [ICCameraFile.exifModificationDate](https://developer.apple.com/documentation/imagecapturecore/iccamerafile/exifmodificationdate)
- [ICCameraFile.sidecarFiles](https://developer.apple.com/documentation/imagecapturecore/iccamerafile/sidecarfiles)
- [ICCameraDevice.requestDeleteFiles](https://developer.apple.com/documentation/imagecapturecore/iccameradevice/requestdeletefiles%28_%3A%29)

## Architectural alternatives

Detailed tradeoffs and the selected boundaries are in plan 0055. Research ruled
out only choices that contradict confirmed requirements:

- importing directly while still discovering dates cannot produce a stable full
  plan, deterministic suffixes, or “always import everything” semantics;
- FSEvents alone cannot validate an execution because delivery is asynchronous;
- post-copy checksumming is unnecessary because OS copy success is trusted;
- content-based identity or persistent hashes would violate path identity;
- reorganization cannot use content equality to merge originals because every
  source original must remain represented;
- the current destructive schema reset cannot coexist with durable import
  history.

The viable alternatives that remain are compared seriously in the plan: Store vs
coordinator ownership, companion-table vs enumeration-at-plan-time sidecars,
revision notifications vs broad catalog changes, no/full/minimal recovery state,
Foundation vs coordinated vs raw file operations, and three reorganization move
strategies.

## Conclusions carried into plan 0055

1. One pure deterministic planner can serve import and reorganization if operation
   mode supplies different collision/equality semantics.
2. A `MediaOperationCoordinator` actor should own eager plan lifecycle and
   execution; `CatalogStore` should continue to own catalog truth, SQL, revisions,
   import history, and recovery rows.
3. Build plans greedily for every attached removable source as soon as inventory,
   enrichment, destination choice, and companion enumeration are complete. An
   early Import click queues intent and waits for readiness.
4. Use FSEvents to increment source/destination revisions and trigger replanning;
   retain a scalar revision guard plus a per-file fact check because events do not
   lock the filesystem.
5. Import duplicate classification compares only already-existing candidates.
   Successful OS copies receive no post-copy byte comparison.
6. Import is idempotent under unchanged source, destination, and settings.
7. Reorganization reuses naming/reservation/execution infrastructure but never
   content-deduplicates. Source equal to proposed destination is a no-op; conflicts
   are resolved with move dependencies or deterministic suffixes.
8. Persist one import-batch timestamp on each actually imported media row. Preserve
   it through reorganization and expose nonempty batches in the sidebar.
9. Add a lightweight companion-file table for recognized source sidecars rather
   than treating sidecars as media assets or enumerating a second source of truth
   at planning time.
10. Persist only an active-operation settlement journal, not complete ready plans.
    Recovery completes settlement/cleanup or removes abandoned staging; it never
    silently resumes unstarted copy work.
