# Removable Volume And Camera Source Detection Research

Status: non-authoritative research note.

Date: 2026-07-05. POC results appended 2026-07-06 (see "POC results" below);
several assumptions in the earlier sections are now settled by measurement.

How the previous implementation (`../Otos Studio_old`) detected removable
volumes and PTP cameras, whether Otos should adopt a similar design (separate
sidebar section, excluded from All Media, insert-triggered scan, prioritized
enrichment), what platform APIs are involved, and what a POC must verify before
committing to an increment. This is design input, not current Otos behavior.

## Question

When a removable USB volume, SD card, or camera (PTP/MTP) is connected, Otos
should show it in the sidebar under a new removable-sources heading, scan it
immediately, and enrich it before regular libraries. Its content must not
appear under All Media. Can the old implementation be copied, and what must be
proven on real hardware first?

## The old implementation

The old app split detection into two independent feeds merged by a reducer.
All types below are in `Otos Studio_old/Otos Studio/`.

### Volume feed — `Infrastructure/ForegroundDeviceEventSource.swift`

- Initial enumeration: `FileManager.mountedVolumeURLs(includingResourceValuesForKeys:options:)`
  with `.volumeNameKey`, `.volumeUUIDStringKey`, `.volumeIsRemovableKey`,
  `.volumeIsEjectableKey` and `.skipHiddenVolumes` (line 276).
- Acceptance filter: `volumeIsRemovable == true` only (line 308). USB thumb
  drives, SD cards, and cameras in mass-storage mode pass; fixed external
  drives (typical USB SSD/HDD enclosures, which report `ejectable` but not
  `removable`) are deliberately excluded.
- Live updates: `NSWorkspace.didMountNotification` re-enumerates everything;
  `willUnmountNotification`/`didUnmountNotification` match a source by
  `NSDevicePath` from `userInfo` (lines 122–174). The will-unmount hook fed an
  early-warning publisher so in-flight work could stop before the volume died.
- Surprise-removal backstop: a DiskArbitration session with
  `DARegisterDiskDisappearedCallback` on a private dispatch queue (lines
  520–566). The callback filters `kDADiskDescriptionMediaRemovableKey == true`
  and reports volume path, volume UUID, and media UUID so a yanked card is
  removed even if the workspace notification never fires.
- Identity: `volumeUUID ?? mediaUUID` (media UUID read via
  `DADiskCopyDescription`, line 356) wrapped as a stable `volume:` identity;
  fallback to the mount path. Duplicate identities (two cards with the same or
  missing UUID) get a `#path:` suffix plus a per-session memory map so a row's
  ID never flips while mounted (lines 389–453).
- Eject: `NSWorkspace.shared.unmountAndEjectDevice(at:)`
  (`Infrastructure/DiskVolumeCommandService.swift`).

### Camera feed — `Infrastructure/ImageCaptureCameraDeviceAccess*.swift`

- Discovery: one `ICDeviceBrowser` with
  `ICDeviceTypeMask.camera | ICDeviceLocationTypeMask.local`, delegate
  `didAdd`/`didRemove`/`deviceBrowserDidEnumerateLocalDevices`
  (`+BrowserDelegate.swift`).
- Double-listing policy (`Shared/SourceDiscoveryPolicies.swift`): reject an
  `ICCameraDevice` when `mountPoint` is non-empty or its
  `transportType`/`locationDescription` normalizes to contain "massstorage".
  A camera or card that mounts as a filesystem is handled by the volume feed;
  ImageCapture must not list it a second time. (A later reducer-level
  suppression mechanism exists but ended up a no-op — rejection at
  source-creation was sufficient.)
- Identity (`Shared/SourceIdentitySharedModels.swift`):
  `persistentIDString ?? serialNumberString ?? uuidString`, falling back to
  `locationDescription` marked `transient`.
- Session per device (`ImageCaptureCameraSession.swift` + `+Delegates.swift`):
  `requestOpenSession()`, then wait for
  `deviceDidBecomeReadyWithCompleteContentCatalog`. Progress comes from
  `didReceiveStatusInformation` and `contentCatalogPercentCompleted`. Locked
  iPhones surface as
  `cameraDeviceDidEnableAccessRestriction`/`DidRemoveAccessRestriction`.
- Readiness state machine (`CameraReadinessCoordinator.swift`): open-session
  timeout, "catalog taking longer" escalation, access-restricted wait loop,
  disconnect/device-error propagation into thrown errors, waiter continuations
  with cancellation support. This is the hardest-won part of the old code.
- Enumeration (`ImageCaptureCameraSession+CatalogItems.swift`): facts from
  `device.mediaFiles` (`ICCameraFile`): `fileSize`,
  `creationDate`/`exifCreationDate`/`fileCreationDate` for capture time,
  modification-date candidates, `sidecarFiles` + `pairedRawImage` as
  attachments. Epoch-placeholder dates (|t| < 1ms from 1970) and
  unrepresentable dates are rejected with diagnostics — real cameras emit
  garbage dates.
- Known weakness: item IDs were pointer-identity of the `ICCameraFile`
  object (line 34), unstable across sessions. A new implementation should key
  on `fileSystemPath`/folder+name instead.

### Presentation

Per `docs/ui.md`, the sidebar had a `Sources` section separate from
`Libraries`; source rows used the same detail route as libraries; **source
content did not join the All Photos aggregate**. Scanning ran through the same
root runtime as libraries; camera rows resolved bytes through the active
camera session (download/stage before ImageIO read).

Notably, the old repo contains **zero MTP references**: it handled removable
mass-storage volumes and PTP cameras only.

## Verdict: adopt the same shape

Yes — the old detection layer is well-designed and maps cleanly onto current
Otos. What transfers as-is (concepts, largely re-typable code):

- Volume enumeration + acceptance filter + workspace notifications +
  DiskArbitration disappearance backstop.
- UUID-first volume identity with disambiguation memory.
- The ImageCapture mass-storage rejection policy.
- The camera readiness coordinator and date sanitization.
- Separate sidebar section; removable content excluded from All Media.

What should not transfer: the background agent/persistence monitoring, import
flows (both explicitly out of scope), the bespoke logging plumbing (Otos uses
`OtosLog` / unified logging per ADR 0015), pointer-based camera item IDs.

## Fit with current Otos

Two tiers with very different costs.

### Tier 1 — removable mass-storage volumes (SD cards, USB sticks, cameras in mass-storage mode)

These are ordinary filesystems, so the existing scan/enrich pipeline works on
them nearly unchanged. Integration points in current code:

- **Detection**: new `RemovableVolumeMonitor` service (port of
  `ForegroundDeviceEventSource`), feeding the store.
- **Model**: `LibraryRoot`/`CatalogLibraryState`
  ([CatalogModels.swift](../../Otos/Models/CatalogModels.swift)) gain a root
  kind (`library` vs `removable`); `SidebarSelection` gains a removable case.
  Removable roots carry `volumeUUID` identity because mount paths drift
  (`/Volumes/CARD` → `/Volumes/CARD 1`); `LibraryRootPath` remains the runtime
  join key but not the durable identity for removable roots.
- **Sidebar**: [SidebarView.swift](../../Otos/Views/SidebarView.swift) adds a
  second section; Projection excludes removable roots from the All Media
  scope (`availableLibraryRootIDs()` / `rootIDsForQuery` in
  [CatalogStore.swift](../../Otos/Stores/CatalogStore.swift)).
- **Scan on insert**: mount event → attach root → `enqueueScans`. The scan
  queue is serial ([CatalogStore.swift:1505](../../Otos/Stores/CatalogStore.swift));
  a removable root should be inserted at the front of `pendingScanPaths`.
  `CatalogScanner` itself needs no changes for `/Volumes/...` paths.
- **Prioritized enrichment**: the coordinator already has per-asset priority
  (viewport, freshly downloaded) via `enrichmentCandidates(prioritizing:limit:)`
  ([CatalogStore.swift:445](../../Otos/Stores/CatalogStore.swift)). Root-tier
  priority is a small addition: claim removable-root candidates before
  general candidates (two-pass claim, or an ORDER BY on a root-priority rank
  in `fetchStoredAssetsNeedingEnrichment`).
- **Unmount**: mark the root unavailable and/or drop the rows. Whether catalog
  rows and thumbnails persist across remounts (fast re-insert) or are purged
  on eject is an open product decision; persistence requires the UUID identity
  above.

### Tier 2 — PTP cameras and phones (ImageCaptureCore)

Does **not** fit the current pipeline: ADR 0008 makes the filesystem the
source of truth, and enrichment reads bytes at `MediaAssetID.fileURL`. Camera
items have no file URL, no FSEvents, and byte access goes through a serialized
device session (`requestDownloadFile`, `requestThumbnail`, `requestMetadata`).
This tier needs the ported session/readiness machinery plus either a parallel
in-memory source catalog (the old app's choice) or a virtual root whose reads
route through the session. Ship Tier 1 first; Tier 2 is its own increment.

### MTP

macOS has no native MTP stack — still true through current macOS (2026-07).
`ICDeviceBrowser` sees PTP devices and Apple devices; an Android phone in MTP
("File transfer") mode will not appear. Options: document that Android users
select PTP ("photo transfer") USB mode, or bundle a third-party MTP stack
(libmtp, as OpenMTP does — LGPL, kernel-less userspace USB). Recommendation:
out of scope; PTP mode covers photo ingestion from Android.

## Platform API notes

- `FileManager.mountedVolumeURLs` + `URLResourceValues`:
  `volumeIsRemovable` = media removable from the mechanism;
  `volumeIsEjectable` = software-ejectable. Card readers and thumb drives
  report removable; external HDD/SSD enclosures usually only ejectable.
- `NSWorkspace` mount notifications post on `NSWorkspace.shared.notificationCenter`
  (not the default center); `userInfo["NSDevicePath"]` carries the mount path.
  Normal mount/eject is reliable; surprise removal needs DiskArbitration.
- DiskArbitration: `DASessionCreate` + `DARegisterDiskDisappearedCallback` +
  `DADiskCopyDescription` keys `VolumePath`, `VolumeUUID`, `MediaUUID`,
  `MediaRemovable`. Callbacks arrive on the session's dispatch queue; must
  unregister/queue-detach on teardown.
- TCC: first access to files on a removable volume triggers the
  `kTCCServiceSystemPolicyRemovableVolumes` "Files and Folders" prompt
  (Catalina+, applies to hardened non-sandboxed apps too; Otos is unsandboxed
  per ADR 0003). Denial makes reads fail while enumeration may still succeed.
  Ad-hoc/unsigned dev builds can re-prompt after re-signing.
- ImageCaptureCore: no separate TCC prompt for camera devices on macOS is
  documented (the Camera TCC service is AVCapture, not ICC) — verify in POC.
  iPhones additionally require device unlock + "Trust", surfaced through the
  access-restriction delegate callbacks.
- `ICCameraDevice.requestDownloadFile(_:options:...)` with
  `ICDownloadsDirectoryURL`, `ICSaveAsFilename`, `ICOverwrite`,
  `ICDownloadSidecarFiles`; thumbnails/metadata via per-item requests. All
  device I/O is serialized per device in practice (the old repo wrapped it in
  `CameraOperationScheduler`).

## Assumptions a POC must verify (hardware available: SD cards, MTP, PTP)

1. **Removable/ejectable matrix**: for each device (SD in built-in reader, SD
   in USB reader, USB stick, USB SSD, camera in mass-storage mode), log
   `volumeIsRemovable`, `volumeIsEjectable`, `volumeIsInternal`,
   `volumeUUIDString`, DA `MediaUUID`, filesystem type. Confirms the
   removable-only filter matches the devices Taylor actually wants listed.
2. **UUID presence on FAT32/exFAT**: cards are typically FAT32/exFAT;
   `volumeUUIDString` may be nil there. Confirm mediaUUID fallback fires and
   is stable across remounts and across readers.
3. **Mount-path drift**: two cards with the same label; remount; confirm
   `/Volumes/NAME 1` handling and that UUID identity keeps rows stable.
4. **Surprise removal**: yank a card without eject; confirm the DA
   disappearance callback fires and the workspace didUnmount does or doesn't.
5. **TCC prompt**: first scan of a removable volume from a dev build —
   when does the prompt appear, what denial does to the scan, whether the
   grant survives rebuilds.
6. **FSEvents on exFAT**: current `CatalogFilesystemWatcher` arms per root;
   verify file-level events work on an exFAT card and that the watcher
   tolerates the root vanishing mid-stream.
7. **Enrichment on card media**: run the existing pipeline against a mounted
   card (attach `/Volumes/X` as a plain library) — throughput, and that
   `FileMaterialization`'s cloud-dataless check never misfires on exFAT.
8. **ICDeviceBrowser discovery matrix**: camera in PTP mode, same camera in
   mass-storage mode (confirm `mountPoint` non-empty → volume feed owns it),
   iPhone locked/unlocked (access-restriction callbacks), Android in PTP mode.
9. **Catalog timing**: session open + complete-content-catalog time on a full
   card through PTP; whether `mediaFiles` facts (sizes, EXIF dates, sidecar
   pairing) are complete without per-item metadata requests; how often dates
   are epoch garbage.
10. **Session contention**: behavior when Photos.app or Image Capture auto-
    opens the same device; whether `requestOpenSession` fails, waits, or
    steals.
11. **Camera item identity**: confirm `ICCameraFile.fileSystemPath` (or folder
    path + name) is stable across sessions as the item key, replacing the old
    pointer-identity IDs.
12. **PTP throughput**: thumbnail-request latency per item and full-file
    download MB/s, to size Tier 2 enrichment expectations.

## POC results (2026-07-06)

Run on real hardware: `CAMERA` (FAT32 USB stick), `4152150790` (exFAT SD card,
Sony camera card with 2,801 files, in the built-in reader), and a Sony ILCE-6700
(A6700) connected over USB in MTP mode. Swift CLIs compiled against the macOS 27
SDK; sources in the session scratchpad (`volume-poc.swift`, `browser-poc.swift`,
`session-poc.swift`, `session-poc2.swift`, `thumb-poc.swift`, `fsevents-poc.swift`).

### Volume feed — verified

- Built-in SD reader: `isRemovable=true, isEjectable=true, isInternal=true`.
  An "external only" filter would wrongly exclude SD cards; removable-only is
  the correct filter (assumption 1 settled).
- SMB mounts report `isLocal=false, isRemovable=false` — naturally excluded.
- FAT32 and exFAT volumes both carry a synthesized `volumeUUIDString`, stable
  across unmount/remount. **Neither card exposes a DA `MediaUUID`** — the
  old code's `volumeUUID ?? mediaUUID` fallback chain is right, but mediaUUID
  is rarely there for card media (assumptions 2–3 partly settled; two-cards-
  same-label drift still untested).
- Both cards mount through **FSKit** (`fskit` mount flag) on current macOS —
  the old app predates this stack. FSEvents file-level events (create, modify,
  remove) fire correctly on the FSKit FAT32 mount with ~0.3 s latency
  (assumption 6 settled).
- **AppleDouble hazard (new Tier 1 gap)**: a `._X.ARW` sidecar file reports
  `contentType=com.sony.arw-raw-image` and `isHidden=true`. `CatalogScanner`
  enumerates without `.skipsHiddenFiles`, so Mac-touched FAT cards would
  catalog `._` junk as RAW images. Fix: skip hidden files (or `._` prefixes)
  at scan time.
- No TCC prompt appeared in this dev context (CLI inherits the terminal's
  grants). The removable-volumes prompt for the real app bundle remains
  untested (assumption 5 open).

### ICDeviceBrowser — verified, with surprises

- **Both mass-storage volumes are dual-listed as `ICCameraDevice`s** with
  `transportType=ICTransportTypeMassStorage` — and, surprisingly,
  **`mountPoint=nil`**. The old policy's first check (non-empty mountPoint)
  would not catch them on current macOS; only its transport/location
  "massstorage" string check does. That string check is load-bearing.
- The ICC device UUID/persistentID is *derived from but not equal to* the
  volume UUID (last bytes differ: `…C1DE` vs `…C151`). Cross-feed dedup by
  UUID equality would silently fail; dedup must key on the transport-type
  rejection, not identity matching.
- **The A6700 in MTP mode is fully visible** (`ICTransportTypeUSB`, Sony VID
  0x054c) with a real serial number. Apple's ImageCapture stack speaks
  MTP for cameras; the "macOS has no MTP" limitation is about Finder-style
  general file transfer, not camera media enumeration. (Whether arbitrary
  Android MTP phones appear remains untested here.)
- `deviceBrowserDidEnumerateLocalDevices` can fire *before* the `didAdd`
  callbacks deliver the devices it announces.

### A6700 over MTP: session behavior — the hard numbers

- Session open: immediate (0 ms, no prompt). **Content catalog: ~19.7 s for
  292 items (~67 ms/item), every session — no warm cache.** Extrapolates to
  ~3 min for a 2,800-item card. No `didReceiveStatusInformation` progress
  events fired and `contentCatalogPercentCompleted` stayed at 0–1 throughout;
  progress UI must be indeterminate on this device.
- `didAdd` fires per-item but effectively all at once at the end; there is no
  usable incremental population.
- **Catalog facts are thin**: `fileSystemPath=nil`, `ptpObjectHandle=0`,
  `exifCreationDate=nil`, `originalFilename=nil`, `duration=0` for videos,
  `pairedRawImage=nil` even for a DSC06715.ARW/DSC06715.HIF pair (Otos-side
  basename pairing needed). Present and reliable: `name`, `fileSize`,
  `creationDate` (capture time), `width`/`height`, coarse UTI, and a
  `parentFolder` virtual date-folder (e.g. `2026-07-03`).
- **Identity**: `name + fileSize + creationDate` (plus parent folder name) is
  stable across sessions — verified by fingerprint comparison across two
  sessions. Both fileSystemPath and ptpObjectHandle are unusable here.
- **Thumbnails: hard-capped at 160×120** (~7–11 KB JPEG, 60–330 ms each,
  serialized). `requestThumbnailData` with
  `ICImageSourceThumbnailMaxPixelSize` 256 or 1024 returns the identical
  160×120 payload. The device serves only the EXIF-standard thumb.
- **Metadata: unavailable.** Both `requestMetadata` and
  `requestMetadataDictionary` fail with **-20150 =
  `ICReturnMetadataNotAvailable`** for ARW, HIF, and MP4 alike. Per Apple
  forum reports this is device/transport-dependent (some Canon/Nikon PTP
  bodies do return EXIF); treat API metadata as opportunistic.
- **Partial reads work**: `requestReadData` returned 128 KB in ~211 ms
  (correct MP4 leading bytes). This is the door to header-parsing EXIF and
  embedded-preview extraction without full downloads.
- **Full download: 40 MB/s** (201 MB MP4 in 4.8 s) with
  `requestDownloadFile` + `ICDownloadsDirectoryURL`.
- **Concurrent sessions from two processes both succeed** (the ImageCapture
  daemon multiplexes), but the second session saw racy state:
  `deviceDidBecomeReadyWithCompleteContentCatalog` fired while
  `mediaFiles.count == 1` (fully populated moments later) and the
  `parentFolder` chain came back empty. Never treat the complete-catalog
  callback as proof that `mediaFiles` is fully delivered; reconcile against
  `didAdd` accounting.

### Staging question: do we need local bytes for metadata/thumbnails?

For the grid, no staging is strictly required — but what the device serves
free is small: 160×120 thumbs vs the 256 px `ThumbnailStore.maxPixelSize`
target, plus name/size/capture-date/dimensions facts (enough for date-sorted
browsing). Anything better than 160×120, and any EXIF at all (on this
camera), requires reading file bytes. The options, per unit of increasing
transfer:

1. **Catalog-facts-only enrichment** (0 extra bytes): grid shows upscaled
   160×120 thumbs; sort/filter by capture date works from catalog facts.
2. **Header partial-reads** (~128 KB–2 MB/file): parse TIFF/EXIF IFDs from a
   ranged read, pull DateTimeOriginal/lens/GPS and locate the embedded
   preview (`PreviewImage`/`JpgFromRaw` in ARW; Photo Mechanic's approach),
   then ranged-read just the preview. Real parsing work per format; ~0.2–0.5 s
   per file at observed latencies.
3. **Full download into a staging store** (all bytes, 40 MB/s): run the
   normal `MediaEnricher` on local bytes; everything downstream is the
   existing pipeline.

### Download-once contract (enrichment now, import later)

To guarantee bytes move off the camera exactly once, make one component own
device byte access: a **device staging store**, content-keyed by
`(device identity, folder/name, fileSize, creationDate)` — the fingerprint
verified stable across sessions. All byte consumers (enrichment, viewer,
future import) request through it:

- **Option A — lazy staging**: nothing downloads until something needs bytes
  (viewer open, 256 px thumbnail policy, later import). Import downloads only
  never-staged files and *moves* already-staged ones out of the cache.
  Cheapest transfer; first-view latency on demand; enrichment limited to
  option 1/2 quality until then.
- **Option B — eager shadow-ingest**: on connect, background-download the
  whole device into staging (spending the 40 MB/s once), enrich locally with
  the full existing pipeline, and import = verify fingerprint + move. Card-
  sized disk cost and minutes of upfront transfer; everything downstream is
  the ordinary filesystem pipeline and nothing ever downloads twice.
- **Option C — hybrid (recommended)**: catalog facts + camera thumbs
  immediately (option 1); eager staging as a background fill exactly like the
  existing dataless-cloud download pool (ADR 0009's eager materialization is
  the same shape); viewer/import requests jump the staging queue. Import
  consumes staged files by fingerprint and downloads only the tail.

In all options the staging store needs: fingerprint verification on use
(size + date; optionally a hash stamped at staging time), an eviction policy
for never-imported files, and survival across app restarts so a re-connected
device resumes rather than restarts.

### A6700 in Mass Storage (MSC) mode — same camera, second transport (2026-07-06)

The same body switched from MTP to MSC mode, with the reader card still
inserted in the Mac:

- The camera card mounts as an ordinary USB volume. **Its label is also
  `4152150790`** (Sony formatting), so it mounted at `/Volumes/4152150790 1` —
  the same-label mount-path-drift case observed for real. The two cards'
  volume UUIDs differ (`7524C26D-…` vs `C3194A6F-…`): UUID identity
  disambiguates where labels and paths cannot. Path-based root identity would
  have merged/confused them (open item 2 settled).
- The MTP `ILCE-6700` device disappears; the MSC camera is dual-listed as a
  third mass-storage `ICCameraDevice` named after its *mount point*
  (`4152150790 1`), again with `mountPoint=nil` and
  `serialNumberString=nil` — in MSC mode the camera body identity (serial)
  is invisible to the system; it is purely a card reader.
- **Enumeration: 379 files in 153 ms (0.40 ms/item)** — ~170× faster than the
  same card's MTP catalog. **Bulk read: 40.7 MB/s** (`dd` of the 201 MB clip)
  — identical to MTP's 40.2 MB/s download rate. The USB link is the
  bottleneck, not the protocol; MTP loses on per-item chatter and
  capability, not raw transfer.
- **MTP hides files**: the filesystem shows 379 files where the MTP catalog
  showed 292 media items — Sony per-clip `.XML` sidecars and other non-media
  files are absent from the MTP view. MTP-based import cannot copy what the
  MTP catalog never lists.

### Cross-transport identity (MTP vs mounted filesystem)

- Device-level identity never bridges: the MTP `persistentIDString` decodes
  (hex→ASCII) to the **camera body serial** (`D0CAA0151CF8`); volume identity
  is the **card's** filesystem UUID; ICC mass-storage persistentIDs are
  volume-UUID-derived but byte-mangled; and MSC mode hides the body serial
  entirely.
- Content-level identity bridges well: for stills, `name + fileSize +
  timestamp` matched exactly across MTP and filesystem
  (DSC06715.HIF: 4,562,944 bytes, 16:42:26 UTC both ways, exFAT storing
  TZ-correct timestamps). For videos, name+size match exactly but MTP
  reports recording *start* while the filesystem mtime is file close
  (15 s apart for a 15 s clip) — cross-transport matching needs a date
  tolerance of at least the clip duration, or should prefer name+size with
  hash confirmation.
- Recommendation: do not unify source identity across transports; dedupe at
  import time by content fingerprint (name+size, date-tolerant) or hash.
- Product guidance: for bodies that offer it (Sony), MSC mode is strictly
  better for Otos — full filesystem, real EXIF, ranged reads, 170× faster
  listing, and it exercises the plain Tier 1 pipeline. Keep the MTP/PTP path
  for devices that offer nothing else (iPhones, most Canon/Nikon bodies).

### Re-measurement on the shipped implementation (2026-08-30)

Same body (ILCE-6700) over MTP, now against the real app with 991 items / 36.5 GB
staged. A standalone ImageCaptureCore probe re-ran the 2026-07-06 checks and added
byte-threshold measurements. **Every 2026-07-06 API finding above still holds**:
`exifCreationDate` nil, `duration` 0.0 for a 335 MB video, `requestMetadataDictionary`
failing with -20150, partial reads working. Two facts changed and several are new.

**Changed since 2026-07-06**

- **`pairedRawImage` now populates.** July recorded it as `nil` "even for a
  DSC06715.ARW/DSC06715.HIF pair", requiring Otos-side basename pairing. The probe
  shows `DSC08976.HIF → pairedRawImage = DSC08976.ARW`. Otos-side pairing is still the
  safe default, but the API value is no longer always absent.
- **Throughput is far below the July benchmark.** July measured 40 MB/s single-stream
  (201 MB MP4 in 4.8 s). This session, running the shipped 16-way admission window,
  measured 8.5 MB/s (335 MB in 39 s) down to 0.9 MB/s (8.1 MB in 9.2 s), averaging
  ~13.5 MB/s across 36.5 GB in ~45 minutes. ImageCaptureCore funnels every request
  through one serial `ICDeviceCommandQueue` — a process sample showed it parked in
  `-[ICCameraFile requestDownloadWithOptions:completion:]` for 1,465 of 1,481 samples —
  so the 16 concurrent requests are not parallelism, and the evidence suggests they
  cost throughput rather than adding it. A single-stream re-benchmark against the July
  number is the way to confirm.

**New: how few bytes are actually needed for a naming fact**

July identified header partial-reads as "the door to header-parsing EXIF" but did not
establish the sizes. Measured on this session's staged originals:

| Type | Method | Bytes | Result |
| --- | --- | --- | --- |
| HIF / HEIC / JPEG | `CGImageSource` over the prefix | **256 KB** | `DateTimeOriginal=2026:08:23 13:11:35`, `OffsetTimeOriginal=-07:00` |
| ARW (Sony RAW) | direct TIFF/IFD walk over the prefix | **256 KB** | `DateTimeOriginal=2026:08:23 13:06:47`, `OffsetTimeOriginal=-07:00`; ExifIFD at byte 4,556 |
| MP4 / MOV | tail read, parse `moov`/`mvhd` | **2 MB from the end** | creation `2026-08-23 18:57:31` UTC, duration `14.01 s`; `moov` began 1,025,182 bytes into the last 1 MB |

Two details matter for implementation:

- **ImageIO cannot parse a truncated ARW.** Prefixes up to 16 MB still yielded nothing,
  because `CGImageSource` validates the container. The data is not the obstacle — a
  direct IFD walk finds the tag 4.5 KB in. RAW needs a small explicit TIFF reader, not
  a framework call.
- **The video result was cross-checked against full-file enrichment.** The 2 MB tail
  gave creation 18:57:31 UTC (11:57:31 local at -07:00) and 14.01 s; the catalog row
  produced by enriching the whole 201 MB file holds `capture_wall_compact=20260823115731`
  and `duration_seconds=14.014`. Exact agreement. This also supplies the duration that
  ENR-012's `mtime − duration` derivation currently obtains by downloading whole videos.

For 991 items that is roughly 250 MB of still prefixes plus ~126 MB of video tails —
**under 400 MB against 36.5 GB, about 100×** — and it yields the local wall clock *with
its UTC offset*, which is strictly stronger evidence than the absolute instant ARC-057
rejects. Against July's estimate of ~0.2–0.5 s of parsing per file, 991 items is ~6
minutes of header work versus the ~45 minutes of full staging measured here.

**New: corpus validation of header-only naming (991/991)**

The byte-threshold result above was one file per format, so the extraction was rerun
over **every staged original** and each result compared against the capture wall that
full-file enrichment had already written to the catalog:

| Format | n | Range that worked | Agreement with full-file enrichment |
| --- | --- | --- | --- |
| ARW | 464 | **64 KB prefix** | 464 / 464 exact |
| HIF | 464 | **256 KB prefix** | 464 / 464 exact |
| MP4 | 63 | **1 MB tail** | 63 / 63 exact |

Zero failures, zero mismatches, 208 MB read in total against 36.5 GB staged (**180×
less**), in ~2 s of CPU for the whole card. Note ARW needed only 64 KB — a quarter of
the single-sample figure — and the three formats needed three different ranges *on one
camera*, which is the argument against any fixed prefix constant.

Method per format, and why it differs: HEIF/JPEG parse through `CGImageSource` over the
prefix; ARW needs a direct TIFF/IFD walk because `CGImageSource` validates the whole
container and refuses a truncated one; MP4 needs a tail scan because Sony writes `moov`
last. A parser must therefore distinguish "tag absent" from "offset lies beyond the
bytes I was given" — the latter is the signal to escalate rather than to fail.

**Transport measurements (2026-08-30, ILCE-6700 attached, app idle)**

A standalone benchmark drove `ICCameraFile` directly, so these are transport numbers, not
inferences from the app's behaviour.

| Measurement | Result |
| --- | --- |
| Ranged read latency, 512 B × 20 | median **42.6 ms** (min 38.6, max 73.2) |
| Chunked parse fetch, ARW (1 × 64 KB) | **77 ms/file** |
| Chunked parse fetch, HIF (1 × 128 KB) | **91 ms/file** |
| Chunked parse fetch, MP4 (head + tail) | **234 ms/file** |
| Full download, single stream, 32 MB ARW | 0.86 s = **37.2 MB/s** |
| Full download, single stream, 320 MB MP4 | 8.03 s = **39.9 MB/s** |

Two conclusions follow.

*The 16-way admission window costs throughput.* Single-stream reproduces the 2026-07-06
benchmark of 40 MB/s almost exactly, while the shipped 16-way window delivered 0.9–8.5 MB/s
during the same session and ~13.5 MB/s averaged over the card. ImageCaptureCore serialises
on one `ICDeviceCommandQueue`, so the window buys no parallelism and demonstrably loses
throughput: 36.5 GB at 40 MB/s is ~15 minutes against the ~45 observed.

*Caching is what makes header reads viable, not the header reads themselves.* At 42.6 ms
per read, the package's uncached pattern (138 reads for HEIF) costs ~5.9 s per file — for
464 stills that is ~45 minutes, no better than downloading the card. With the reads served
from one cached chunk the same parse costs 77–234 ms, putting a 991-item card at **~100
seconds and ~97 MB**. This is the measurement behind requirement R3 in
`docs/plans/0101-mediametadata-byte-source-requirements.md`.

**Embedded previews are reachable by range (Sony ARW)**

The TIFF IFD chain declares its previews, so no scanning is needed: IFD0 carries
`PreviewOffset` 196,770 / `PreviewLength` 292,799, which extracts as a valid **1616×1080**
JPEG, and IFD1 carries a **160×120** thumbnail — exactly the size ICC serves, confirming the
device simply returns the embedded EXIF thumb rather than generating anything. A real
256 px grid thumbnail therefore needs one extra ~286 KB ranged read (~90–150 ms), not the
38 MB original.

HEIF is better still: `CGImageSourceCreateThumbnailAtIndex` with
`kCGImageSourceCreateThumbnailFromImageIfAbsent: false` returns a **256×170** embedded
thumbnail from a **128 KB prefix** — the same prefix the capture-wall read already fetches,
so a full-quality grid thumbnail costs nothing extra for HIF/HEIC. Untested for other RAW
vendors.

**How a reader knows where to look — from the format specifications, not from sampling**

An earlier draft of this section proposed an escalating prefix ladder (64 KB → 256 KB →
1 MB …) and a tail read for containers. That is guessing dressed as a strategy. The
formats are self-describing: each carries an index that states where its metadata lives,
so a reader follows the index instead of betting on a location. One read of the first
12 bytes identifies the family:

| Magic | Family | Members |
| --- | --- | --- |
| `ftyp` at offset 4 | ISO-BMFF | MP4, MOV, HEIC/HEIF, AVIF, CR3 |
| `II*\0` / `MM\0*` | TIFF | ARW, NEF, CR2, DNG, RW2, ORF, TIFF |
| `FFD8` | JPEG | JPEG/JFIF |

**ISO-BMFF** — ISO/IEC 14496-12:2015 clause 4.2: every box header carries "the entire
size of the box, including the size and type header, fields, and all contained boxes.
This facilitates general parsing of the file", with `size==1` meaning a 64-bit
`largesize` and `size==0` meaning the box extends to end of file. Clause 4.3.1 makes
`ftyp` mandatory, exactly one, and "placed as early as possible in the file … before any
significant variable-size boxes such as a Movie Box, Media Data Box, or Free Space".
Critically, the specification places **no constraint on whether `moov` precedes or
follows `mdat`** — Figure 1 shows `moov` first only as an example, which is precisely why
"faststart" exists as a post-processing step. So neither "head" nor "tail" is correct as
a rule: the reader walks the top-level box chain, 8–16 bytes per box, and finds `moov`
(or HEIF's `meta`) wherever the writer put it. Clause 4.2 also states that "boxes with
an unrecognized type shall be ignored and skipped", which is what makes a generic walk
safe against vendor boxes and future additions.

**TIFF** — the header occupies the first 8 bytes: byte order, magic, and at bytes 4–7 the
absolute offset of IFD0. IFDs may sit anywhere in the file at any even offset ≥ 8, each
ending with the offset of the next, and every IFD entry whose value exceeds 4 bytes
stores an absolute offset from the start of the file. A reader therefore reads 8 bytes,
seeks to IFD0, reads the directory, follows the `ExifIFD` pointer (0x8769), and reads
`DateTimeOriginal` (0x9003) and `OffsetTimeOriginal` (0x9011) at the absolute offsets
given. Nothing is assumed about placement; every step is directed by the file.

**JPEG/Exif** — CIPA DC-008 requires the `APP1` marker segment carrying the Exif IFD to
be placed immediately after the `SOI` marker, with `APP2` following it. Here the location
*is* specified, so a small fixed prefix is correct by the standard rather than by
observation.

**Anything else** — Fuji RAF and other proprietary containers have no public index rule
this reader can rely on. That case takes the terminal fallback: transfer the file and
enrich normally. This is what keeps the optimization from ever affecting correctness —
an unrecognized container costs bytes, never accuracy, and ARC-057's "proven, not
assumed" invariant holds unchanged.

The implication for the implementation is that the parser must be **range-driven**: it
asks a transport for byte ranges and the transport satisfies them, whether that is a
local file, an `ICCameraFile.requestReadDataAtOffset` call, or a cloud file. "How many
bytes did it take" then becomes a measured outcome worth logging, not a tuning constant
to guess. The corpus figures above (64 KB / 256 KB / 1 MB) are what this camera's files
happened to need — they are validation of the approach, not its design basis.

**Planning needs no staged bytes at all.** The two facts planning requires are the
capture wall (above) and a thumbnail, and the camera already serves thumbnails through
`requestThumbnailData` without a transfer — hard-capped at 160×120 on this body against
`ThumbnailStore.maxPixelSize` of 256, so they are functional but soft. Staging is
therefore an *import-time* concern only; nothing about offering a plan requires it.

**New: `fileCreationDate` agreed with EXIF for this material**

Rendering the scanner-recorded instant (which comes from `fileCreationDate`, since
`exifCreationDate` is nil) in the local timezone matched the enrichment-derived capture
wall for **991 of 991** items — 928 stills and 63 videos, exact to the second. That is
evidence this camera's file dates track EXIF for this material; it is *not* evidence
that the agreement survives media shot at a different UTC offset than the machine's
current one, because every item here was shot in the local zone. It is a useful
cross-check, not a naming source.

**New: catalog-callback ordering, confirming July's "racy state" note**

`deviceDidBecomeReady` fired with `mediaFiles` empty (0 items); the full 991 arrived
only at `deviceDidBecomeReadyWithCompleteContentCatalog`. July recorded the inverse
hazard (complete-catalog callback firing while `mediaFiles.count == 1`). Neither
callback is proof of a populated list on its own.

**What the shipped design cost, measured**

Option C (eager staging) was adopted. Its measured cost on this card: 36.5 GB staged
before the Import button could appear, ~45 minutes, and a further 36.5 GB written when
importing — ~73 GB of writes for one import. July's requirement that the staging store
have "an eviction policy for never-imported files" was not implemented: staged bytes
are released only by a whole-tree discard at app close or at launch, never when an item
is copied into the library. July also asked for staging "survival across app restarts";
the current product decision is the opposite (discard at quit, sweep stale trees at
launch, owner decision 2026-08-30), so that item is superseded rather than outstanding.

Consequences and fixes shipped; see "Outcome (2026-08-31)" below.

**New (2026-08-30, external): ranged reads are an optional MTP capability, and can fail
in success-shaped ways**

The measurements above establish that ranged reads work *on this body*. Protocol and
vendor sources establish that this does not generalise, which bounds any design built on
them.

- **`GetPartialObject` (opcode 0x101B) is optional.** `ICCameraFile.requestReadDataAtOffset`
  is backed by it, and it is absent from the mandatory PTP command set — which requires
  only `GetDeviceInfo`, `OpenSession`, `CloseSession`, `GetStorageIDs`, `GetStorageInfo`,
  `GetObjectHandles`, `GetObjectInfo`, `GetObject` and `GetThumb`. A conforming device may
  implement none of it. Windows' own MTP driver reportedly uses `GetObject` rather than
  `GetPartialObject`, which is evidence that working around its absence is normal practice
  rather than an edge case.
- **A device can advertise it and still fail.** libmtp issue #8 records Samsung Galaxy
  devices failing `GetPartialObject` **by timeout** whenever the offset lands on
  `size − (N × 512) + 500` — roughly one file in 512. libmtp's workaround is to read one
  byte less and force an extra request. The failure mode is a hang, not an error.
- **A failure can arrive shaped like success.** FB7663947 records
  `requestReadData(atOffset:length:completion:)` on iPadOS 13.4 calling its completion with
  a **non-nil, zero-byte `Data` and a nil error** where the file's actual contents were
  expected. A consumer that treats "no bytes, no error" as an in-bounds answer will read a
  transport failure as an empty file.

The design consequences are carried in `docs/plans/0100`: a per-session capability probe
before trusting ranged reads, a fallback to full transfer for devices that fail it, a
deadline covering ranged reads and not only downloads, and — in
`docs/plans/0101` R6/R7 — a byte-source contract in which a fully in-bounds range that does
not deliver its bytes is distinguishable from a range that ran past the end of the file.

**New (2026-08-30, SDK header): 160×120 is what ImageCaptureCore *caches*, not its ceiling**

The 160×120 thumbnail measured on this body was read as a framework limit. The macOS 27 SDK
header documents otherwise, on `ICImageSourceThumbnailMaxPixelSize`:

> Only the embedded EXIF thumbnail, or a created thumbnail of EXIF standard size (160x120)
> will be cached. […] Multiple calls to both cache the EXIF thumbnail, and subsequently
> retrieve a larger thumbnail will work as defined.

The same header notes that `ICImageSourceThumbnailMaxPixelSize` **is ignored when
`ICImageSourceShouldCache` is also passed**. Otos passes the size without the cache flag
(`CameraSourceMonitor.swift:433`), which is the correct combination, so the measurement
stands — but it is a fact about *this body over PTP*, which returns only its embedded EXIF
thumb, not about the framework. Another vendor may answer a 256 px request directly.

### Outcome (2026-08-31): range-driven reading shipped

The 2026-08-30 findings are implemented. A camera proven to answer ranged reads now
transfers nothing to be planned: its rows are enriched from the container's own index, and
their grid thumbnails come from the container's embedded preview. Device transfers are
capped at one, staged bytes are released on settlement, and the import bar's track reports
the stage it is in.

What the implementation added to what was measured here:

- **Ranged reads are gated, not assumed.** `GetPartialObject` is optional in MTP and absent
  from the mandatory PTP command set, and libmtp#8 documents a shipping device that fails it
  by timeout. One 12-byte read per attach must identify a family consistent with the item's
  extension; a device that fails stages exactly as before.
- **A failed read is transient, never absence.** The byte source throws on a transport error,
  a short in-bounds read, and the zero-bytes-no-error shape of FB7663947, so the package
  reports `.readFailure` rather than a definitive "no capture date" — which ARC-057 would
  treat as proof and turn into an mtime-derived filename, and that name is the dedupe key.
- **Reads are bounded.** A read that never answers times out rather than parking a dedicated
  thread.

**What is still unproven is the same thing throughout: one body.** Everything here is the
Sony ILCE-6700. The capability gate exists for devices that cannot serve ranges and has never
been run against one; the preview path is measured for ARW and HIF only; and the per-card
figure of ~93 s is arithmetic over per-file measurements rather than a timed run. Attaching a
card to a build carrying this would confirm all three at once, and is the single most useful
next measurement.

### Measured on hardware (2026-08-31): it works, and running it found two defects

The 2026-08-30 design shipped, and was then run against the same attached ILCE-6700 with
its overlay cleared so enrichment actually had to work. Two defects surfaced that 848
passing unit tests had not, and both were in code already reported as verified.

**The camera rows never reached enrichment.** Not seeding a range-capable device is only
half the change; the rows must then be *routed*. `LiveEnrichmentReadinessChecker` asks the
filesystem, a camera row has no file, `lstat` answers `.unknown`, and `.unknown` routes to a
readiness retry that can never succeed because nothing will ever create that file. Observed:
`probes=128 ready=0 rangedReady=0 retryReadiness=32 dispatched=0`, on repeat, with no
enrichment at all. This section's own design note said it — "readiness has no vocabulary for
reachable-by-range, so this needs a route, not a bypass" — and the implementation did not do
it.

It was invisible without hardware, and the reason is worth keeping: **a re-attached camera
keeps the overlay it already had**, so every row still looked enriched from the previous
session and the import bar went Ready as normal. Only clearing that overlay exposed it.

**Camera tiles lost their thumbnails.** `EnrichmentResult` resolves
`generatedThumbnail?.finalRelativePath ?? thumbnailPath`; the device path passed nil for
both, so every enriched row *cleared* the column, pointing the tile at nothing while its
provisional JPEG sat on disk under exactly that deterministic name. Measured: 684 of 991
rows lost their thumbnail with all 8,606 files still present. Neither owner's tests could
see it, because the provisional write and the enrichment write belong to different types.

**With both fixed, measured over MTP:**

| Measurement | Result |
| --- | --- |
| Rows enriched by ranged read | **991 / 991** |
| Downloads | **0** |
| Staged on disk | **0 B** |
| Bytes read off the camera | **1.9 MB** (the card holds 36.5 GB) |
| Elapsed for the whole card | **263 s** |
| Read caching | **41x** — 87,048 parser reads served by 2,108 transport reads |
| Capture walls vs full-file enrichment | **991 / 991 byte-identical** |
| Grid thumbnails retained | **991 / 991** |

That last-but-one row is the differential oracle, run end to end over MTP for the first
time rather than over staged copies.

**Correcting the estimate.** The plan projected ~93 s per card from per-file measurements.
The real figure is **263 s** — still roughly 10x better than the ~45 minutes a transfer took,
but the extrapolation was optimistic by ~2.8x, because it assumed reads pipeline better than
ImageCaptureCore's serial queue allows. Quote 263 s, not 93 s.

### Instrumented run (2026-08-31): what the ranged-read path actually costs

Measured by instrumenting the shipping code rather than a side POC — an ad-hoc
ImageCaptureCore binary has no TCC grant, and instrumenting the real path cannot drift from
it. Two new fields carry the answers: `transportWaitMs` (time blocked on the camera) beside
`elapsedMs`, and `previews`/`previewSizes` (what the container declares).

**Per-read cost is 3–6x the figure the design assumed.**

| Format | transport reads/file | ms per read | bytes read/file |
| --- | --- | --- | --- |
| ARW | 3.0 | ~141 ms | 1.3 KB |
| HIF | 1.0 | ~147 ms | 1.4 KB |
| MP4 | 4.0 | ~265 ms | 11.4 KB |

The plan projected per-card time from the 42.6 ms latency measured for **512-byte** reads.
Real 128 KB reads cost 141–265 ms. That, not scheduling overhead, is why a card takes ~263 s
rather than the projected ~93 s: transport across 991 items is ~330 s of the wall clock, and
the run is transport-bound in aggregate.

Two consequences worth keeping:

- **Per-file `elapsedMs` is not per-file cost.** It measures from task start, including the
  wait for the serial parse queue, so it reads ~2,900 ms against a transport wait of ~424 ms.
  Compare `transportWaitMs`, not `elapsedMs`, when judging whether chunk sizing could help.
- **Reads per file are already near the floor** for stills — HIF is 1.0. Tuning chunk size
  has little headroom there; the wins are in *not making reads at all*.

**The embedded-preview path shipped and produced nothing.** Every camera tile still carried
ImageCaptureCore's 160×120 thumb. The instrumentation found the cause in one run: the package
finds two previews in a Sony ARW (IFD0 and IFD1) and **both report no dimensions** —
`-1x-1@tiff.ifd0,-1x-1@tiff.ifd1`. In IFD0 the width/height tags describe the *main* image,
and this body omits them where previews live. The consumer filtered on
`(pixelWidth ?? 0) >= 256`, so nil became 0 and every preview was discarded.

Selection is now by byte length, and whether a preview is an improvement is decided after
decoding, where dimensions are real. Verified: 20 of 20 enriched ARW files carry a 256×171
thumbnail where all previously carried 160×120. HIF and MP4 keep the provisional thumb
correctly — the package reads previews from TIFF only, and those containers declare none.

**Verifying a preview cost a round trip, and should not have.** Reading two bytes at the
declared offset to confirm a JPEG marker cost two extra reads per RAW file, each landing
outside every cache, ~141 ms apiece — about 130 s across this card — to prove something the
consumer establishes for free by decoding. Removed in package 0.6.0. The principle: a library
must not spend a round trip to validate a claim its consumer validates as a side effect of
using it.

### Open: per-instance staging paths change asset identity every launch

Found while verifying the above, and it is a design problem rather than a bug to patch
quickly.

Staging roots became per process instance — `DeviceStaging/<instance-uuid>/<identity>/` — so
that the launch sweep could delete what an ended session left without destroying a second
running instance's in-flight transfer. That works. But asset identity **is** the filesystem
path (ADR 0008), so a camera item's identity now changes on every launch, and every overlay
keyed to it is re-created: catalog rows, and thumbnails, whose deterministic names hash the
root path. Observed: 9,997 thumbnail files against 9,304 catalog rows, and a camera item's
thumbnail not surviving a restart.

This conflicts with the overlay-lifecycle invariant that overlay is kept as long as the item
exists. The instance segment solves a real problem — a sweep must not delete a live peer's
staging — but it should not be part of the identity. Candidate directions, none yet
evaluated: keep the root at `DeviceStaging/<identity>/` and record ownership *inside* it (a
lock or marker file the sweep checks), or sweep by process liveness rather than by name.
Deciding this needs an owner's call on how much the app should care about a second instance
at all.

### Still open after this round

- Removable-volumes TCC prompt behavior for the real app bundle (signed,
  hardened) rather than an inherited-grant CLI context.
- Surprise-yank of the card (DA disappeared callback vs workspace
  notification) — not exercised to avoid disturbing the connected devices.
- Same physical card moved between camera-MSC and the built-in reader
  (expected same volume UUID — same synthesized-from-filesystem mechanism
  shown stable across remounts, but not physically confirmed).
- Canon/Nikon PTP bodies and Android-phone MTP/PTP visibility and their
  metadata/thumbnail behavior (only the Sony MTP path measured). The ranged-read
  capability gate exists precisely for a device that cannot serve `GetPartialObject`
  and has still never been run against one.
- Locked/unlocked iPhone access-restriction flow.
- Whether Sony Mass Storage mode (full filesystem, real EXIF, ranged reads of
  embedded previews via plain file I/O) should be the *recommended* connection
  mode in-product, with MTP as fallback.
- Whether any non-Sony device supports `GetPartialObject` at all, and how a
  non-supporting device fails — no such device was available. This is now the
  load-bearing unknown for range-driven reading, in place of the prefix-size question
  retired below.
- Whether another vendor's ICC thumbnail honours a 256 px request, which the SDK header
  says is possible and which would remove the need to extract previews by range for that
  vendor.
- Whether ranged reads contend with a concurrent download on the same serial
  `ICDeviceCommandQueue`. Measured only with the queue otherwise idle.

**Retired from this list, because sections above answer them.** Recorded rather than
deleted so a later reader does not re-run the measurement:

- *Whether the 16-way admission window reduces MTP throughput.* **Answered** in
  "Transport measurements" above: single-stream `requestDownload` gives 37.2 MB/s (32 MB
  ARW) and 39.9 MB/s (320 MB MP4), against 0.9–8.5 MB/s observed under the shipped 16-way
  window. The single-stream re-run this item asked for has been done.
- *Whether header prefix sizes hold beyond this body.* **Superseded** by "How a reader knows
  where to look": the question assumed a prefix constant, and the formats are
  self-describing, so a correct reader follows the container's own index and has no prefix
  size to generalise. The 64 KB / 256 KB / 1 MB figures are validation of the approach, not
  its design basis.
- *Whether `com.apple.quicktime.creationdate` is present in the same tail.* **Answered** by
  reading the package rather than the camera: `MediaMetadata` already surfaces
  `CaptureTimestamps.quickTimeCreation` from `com.apple.quicktime.creationdate` / Sony NRTM
  with an explicit `localWithOffset` / `localFloating` / `absolute` precision, and
  `VideoInfo.durationSeconds` from the movie header. `mvhd` supplies duration only; its
  UTC-anchored time is excluded from naming by ENR-012 anyway.

## Sources

- Old implementation: `../Otos Studio_old/Otos Studio/Infrastructure/` and
  `docs/ui.md` (paths above).
- [ImageCaptureCore](https://developer.apple.com/documentation/imagecapturecore),
  [ICDeviceBrowser](https://developer.apple.com/documentation/imagecapturecore/icdevicebrowser),
  [ICCameraDevice](https://developer.apple.com/documentation/imagecapturecore/iccameradevice),
  [ICCameraFile](https://developer.apple.com/documentation/imagecapturecore/iccamerafile),
  [requestDownloadFile](https://developer.apple.com/documentation/imagecapturecore/iccameradevice/1507818-requestdownloadfile?language=occ),
  [cameraDeviceDidEnableAccessRestriction](https://developer.apple.com/documentation/imagecapturecore/iccameradevicedelegate/3142896-cameradevicedidenableaccessrestr)
- [Disk Arbitration Programming Guide](https://developer.apple.com/library/archive/documentation/DriversKernelHardware/Conceptual/DiskArbitrationProgGuide/ArbitrationBasics/ArbitrationBasics.html),
  [DADiskCopyDescription](https://developer.apple.com/documentation/diskarbitration/dadiskcopydescription(_:)),
  [DARegisterDiskAppearedCallback](https://developer.apple.com/documentation/diskarbitration/daregisterdiskappearedcallback(_:_:_:_:)?language=objc)
- [volumeIsEjectableKey](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeisejectablekey),
  [URLResourceKey](https://developer.apple.com/documentation/foundation/urlresourcekey)
- MTP absence on macOS: [OpenMTP](https://openmtp.ganeshrvel.com/),
  [MTP — Wikipedia](https://en.wikipedia.org/wiki/Media_Transfer_Protocol),
  [MTP on Mac explainer](https://dev.to/hiyoyok/mtp-explained-and-why-it-matters-for-android-on-mac-3np4)
- TCC: [Eclectic Light — Permissions, privacy and TCC](https://eclecticlight.co/2025/11/08/explainer-permissions-privacy-and-tcc/),
  [AppleInsider — removable volumes toggle](https://appleinsider.com/inside/macos-sequoia/tips/how-to-toggle-removable-and-full-disk-access-for-apps-in-macos-sequoia)
- Device-dependent EXIF over PTP: [Apple forums — EXIF creation date of ICCameraFile always nil?](https://developer.apple.com/forums/thread/768690)
- Embedded RAW previews: [ExifTool forum — JpgFromRaw Sony ARW](https://exiftool.org/forum/index.php?topic=4328.0),
  [FastRawViewer RawPreviewExtractor](https://www.fastrawviewer.com/RawPreviewExtractor),
  [Extracting embedded JPEGs from RAW](https://havecamerawilltravel.com/extract-jpg-raw-2/)
- `ICReturnMetadataNotAvailable` (-20150): macOS 27 SDK
  `ImageCaptureConstants.h:81` (local SDK header).
- Thumbnail caching and max-pixel-size semantics: macOS 27 SDK
  `ICCameraItem.h`, `ICImageSourceThumbnailMaxPixelSize` / `ICImageSourceShouldCache`
  (local SDK header).
- MTP ranged-read capability and failure modes:
  [PTP required commands (Microsoft)](https://learn.microsoft.com/en-us/windows-hardware/drivers/image/ptp-required-commands),
  [libmtp#8 — GetPartialObject bug on Samsung Galaxy devices](https://github.com/libmtp/libmtp/issues/8),
  [cvubrugier/mtp-galaxy-bug reproducer](https://github.com/cvubrugier/mtp-galaxy-bug),
  [FB7663947 — requestReadData passes an empty Data to the completion block](http://ileyf.cn.openradar.appspot.com/FB7663947)
  and its [gist writeup](https://gist.github.com/mjrusso/b223bf8db93e64d858e80b6fb8ab6ef8).
