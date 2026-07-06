# Spec: MTP Camera Sources And Local Staging

## Classification

- Work type: Feature
- Current requirement IDs: APP-016, APP-018, ENR-011; updates FND-019,
  FND-023, FND-024, APP-002, APP-003, APP-005, ENR-001, ENR-008, ENR-009
- ADRs: `docs/adr/0013-removable-and-device-sources.md`
- User guidance source: root `PLAN.md`, explicitly approved for full implementation
  in this increment

## Problem

Many cameras expose media through ImageCapture/MTP rather than a mounted
filesystem. Otos must browse those connected cameras without importing originals
or treating staged bytes as a hidden library. Users should see provisional camera
items quickly, get small thumbnails immediately where the device provides them,
and let enrichment fetch bytes through a temporary staging directory while the
camera remains connected.

## Scope

In scope:

- Detect local ImageCapture camera devices and reject mass-storage devices that
  already present as mounted volumes.
- Open a camera session, wait for the complete content catalog, and record camera
  item filesystem-like facts into Store.
- Use `camera:<persistent-or-serial-id>` source identity, with transient identities
  removed on detach.
- Use an app-owned staging root as the catalog root path for the connected camera.
- Apply provisional ImageCapture thumbnails without replacing existing final
  thumbnails.
- Route enrichment materialization for staging URLs to the active camera session.
- Eagerly seed camera rows into the existing download pool, stills before videos,
  then capture date and path.
- Delete staging bytes on disconnect and sweep stale staging roots on startup.
- Show a dismissable camera connection banner and an enumerating empty state.

Out of scope:

- Camera control, capture, delete, or import/copy workflows.
- Security-scoped URLs and sandbox-specific access flows.
- Durable staging bytes after disconnect.
- Provider-specific protocols outside ImageCapture.
- Hardware validation when no MTP camera is attached in the agent environment.

## Current Repo State

Before this increment, all cataloged assets came from filesystem scans. Enrichment
materialized dataless cloud files through `FileMaterialization`, then read bytes
from the original URL. There was no way to catalog media from a device that did
not expose ordinary filesystem paths, and no route from a virtual catalog URL to a
device download.

## Captured Requirements For User Verification

| Label | Type | Captured requirement | Current or candidate | Storage location |
| --- | --- | --- | --- | --- |
| MTP-SOURCE | Functional | Connected MTP/PTP cameras appear as removable sources, not fixed libraries, and never contribute to All Media. | Current | APP-016, APP-018 |
| MTP-MASSSTORAGE | Functional | Cameras that report a mounted volume or mass-storage transport are rejected by ImageCapture monitoring so the removable-volume path owns them. | Current | APP-018 |
| MTP-ENUM | Functional | The UI can show a camera-specific enumerating empty state while ImageCapture is still reading the device catalog. | Current | APP-018 |
| MTP-PROVISIONAL | Functional | Device-provided provisional thumbnails may be stored before full enrichment and only fill missing thumbnail paths. | Current | APP-018 |
| MTP-STAGING | Architecture | Camera asset URLs point into an app-owned staging root; enrichment materializes those URLs through the active camera session. | Current | ADR 0013, APP-018 |
| MTP-LIFETIME | Architecture | Staging bytes exist only while connected and are swept on startup or detach; stable catalog rows remain unavailable after detach. | Current | APP-018 |
| MTP-BANNER | Functional | Selecting a connected camera shows a dismissable guidance banner recommending direct card insertion or Mass Storage mode for faster browsing. | Current | APP-018 |
| MTP-ORDER | Architecture | Eager staging downloads still/image work before videos, then capture date, then path. | Current | ENR-011 |

## Architectural Alternatives

### Alternative A: Ignore MTP cameras

Pros:

- No non-filesystem code path.

Cons:

- Fails the product requirement to browse connected cameras.
- Users must change camera mode or remove cards before Otos can see media.

Failure modes:

- No user-visible camera source appears despite a connected camera.

### Alternative B: Import camera files into Application Support as durable originals

Pros:

- Existing filesystem scan and enrichment paths could process imported bytes.

Cons:

- Violates "never takes media hostage"; app-owned originals become a hidden media
  vault.
- Requires delete/import/export semantics not approved by requirements.

Failure modes:

- Users think camera media is safely imported or synced when Otos has only a
  private copy.

### Alternative C: Virtual root plus temporary staging (selected)

Pros:

- Preserves the catalog root/query model.
- Keeps originals on the device and avoids sidecars/import copies.
- Lets enrichment reuse the existing materialization/download pool through a
  narrow router.

Cons:

- Full enrichment requires the camera to remain connected.
- Hardware behavior depends on ImageCapture device implementation quality.

Failure modes:

- A camera disconnect cancels staging; rows remain unavailable until reconnect.

## Selected Approach

Alternative C is the smallest correct architecture. The camera source is a
catalog root whose path is an app-owned staging directory. Store owns catalog
facts and overlay exactly as it does for other roots. ImageCapture owns only
device enumeration, provisional thumbnails, and byte downloads. The
`DeviceStagingRegistry` routes missing staging URLs to the active camera session;
all other URLs still use the ordinary `FileMaterialization` path.

## Interfaces, Ownership, Data Flow, And Persistence

- `CameraSourceMonitor` owns `ICDeviceBrowser` lifetime and rejects mounted or
  mass-storage camera devices.
- `DeviceCameraSession` owns one `ICCameraDevice` session, waits for catalog
  readiness, maps `ICCameraFile` values to `DeviceCameraCatalogItem`, requests
  provisional thumbnails, and downloads one file to a staging destination.
- `CatalogWindowViewModel` owns monitor and per-camera task lifetimes. It
  registers sessions in `DeviceStagingRegistry`, attaches Store roots, records
  catalog batches, applies provisional thumbnails, and seeds enrichment staging.
- `CatalogStore.attachDeviceMTP(...)` creates or remaps the source root and marks
  it available/enumerating. `recordDeviceCatalogBatch(...)` writes filesystem-like
  facts. `completeDeviceCatalogEnumeration(...)` reconciles missing camera rows
  and marks the source idle.
- `DeviceStagingRegistry` is the only router from staging URLs to ImageCapture
  downloads. It enforces a free-space floor, writes via a temporary file, and
  deletes staging roots on unregister/startup sweep.

## Concurrency And Actor Ownership

- ImageCapture objects are accessed on the main actor because their delegate
  surface is ObjC/UI-framework style.
- Store remains the SQLite and runtime catalog actor.
- The ViewModel owns one cancellable task per camera identity and does not treat
  task cancellation as a deletion proof.
- EnrichmentCoordinator remains off-main for scheduling. Device staging seeds are
  ordinary `DownloadWork` values in the existing materialization pool.

## Instrumentation And Profiling Plan

- Store emits `catalog.device.scan.batch` diagnostics with root path, count,
  changed count, and database timings.
- Attach/detach diagnostics include source kind and identity through
  `catalog.removable.attach` / `catalog.removable.detach`.
- Provisional thumbnail failures are debug-only and bounded by relative path.
- Hardware performance profiling is deferred until a camera is attached; use
  `script/logs.sh FileAccess`, `script/logs.sh Catalog`, and `script/profile.sh
  "File Activity" 10s` for device smoke.

## Test And Acceptance Criteria

- `CatalogStoreRemovableSourceTests.mtpCatalogRowsAreScopedToCameraAndStagingIsRemovedOnDetach`
- `CameraSourcePolicyTests.rejectsMassStorageAndMountedCameraDevices`
- `CatalogProjectionTests.mtpCameraSelectionShowsEnumeratingStateAndConnectionBanner`
- `EnrichmentCoordinatorTests.eagerDeviceStagingDownloadsStillItemsBeforeVideos`
- Local `script/verify.sh` must pass before final closure.
- Hardware MTP smoke is a non-blocking after-DoD check when no device is available
  to the agent.

## Code-Smell Review

- MainActor gravity: ImageCapture session work is main-actor isolated because the
  framework delegate surface requires it; byte staging and Store persistence are
  not done in SwiftUI views.
- State duplication: staging bytes are temporary transport state, not catalog truth.
- Unsafe concurrency escape: C/DiskArbitration and ObjC delegate callbacks hop
  through typed owners before reaching Store.
- Stringly typed facts: source identities use explicit namespaces; asset paths
  remain typed `LibraryRootPath` plus `MediaRelativePath`.
- Diagnostic payload sprawl: no thumbnails, media bytes, or metadata blobs are
  logged.

## Stale-Document And Comment Audit

- Update `docs/index.md`, `docs/requirements.md`, `docs/onboarding.md`, ADR 0013,
  and this spec.
- Removed root `PLAN.md` after conversion.
- Update file guides/comments in camera monitor, staging registry, ViewModel,
  Store, Projection, and EnrichmentCoordinator where staging/source ownership is
  current reality.
