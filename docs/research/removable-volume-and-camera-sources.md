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
flows (both explicitly out of scope), the bespoke logging plumbing (Otos has
`CatalogDiagnostics`), pointer-based camera item IDs.

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

### Still open after this round

- Removable-volumes TCC prompt behavior for the real app bundle (signed,
  hardened) rather than an inherited-grant CLI context.
- Surprise-yank of the card (DA disappeared callback vs workspace
  notification) — not exercised to avoid disturbing the connected devices.
- Same physical card moved between camera-MSC and the built-in reader
  (expected same volume UUID — same synthesized-from-filesystem mechanism
  shown stable across remounts, but not physically confirmed).
- Canon/Nikon PTP bodies and Android-phone MTP/PTP visibility and their
  metadata/thumbnail behavior (only the Sony MTP path measured).
- Locked/unlocked iPhone access-restriction flow.
- Whether Sony Mass Storage mode (full filesystem, real EXIF, ranged reads of
  embedded previews via plain file I/O) should be the *recommended* connection
  mode in-product, with MTP as fallback.

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
