# Library storage, OneDrive eviction and stored previews

Date: 2026-10-25. Measurements behind plan 0108. Scratch probes ran read-only against
the installed catalog (`net.melisma.Otos`) and downloaded originals only; nothing was
downloaded, evicted, moved or written in the media folders.

Labels: **[M]** measured here; **[V]** checked in code or the cited source; **[R]**
reported by others; **[U]** unconfirmed.

## The library and the disk

| | Library roots (OneDrive) | Downloaded | Cloud-only |
| --- | --- | --- | --- |
| RAW (ARW) | 5,358 files, 191 GB | 444 (15.5 GB) | 4,914 (175.6 GB) |
| Other images | 8,536 files, 35.7 GB | 505 (2.4 GB) | 8,031 (33.3 GB) |
| Video | 1,765 files, 551 GB | 65 (34.1 GB) | 1,700 (516.7 GB) |

[M, catalog query plus `lstat` `SF_DATALESS`.]

- Disk: 494.4 GB total, 15.2 GB free. `volumeAvailableCapacityForImportantUsage`
  reports 18.8 GB and opportunistic usage 3.1 GB [M].
- The whole OneDrive folder: 2,844 downloaded files using 53.1 GB on disk, and 125,608
  cloud-only files (1,203 GB) [M].
- So the downloaded 53 GB is **not** counted as space macOS can purge for important
  use (18.8 − 15.2 ≈ 3.6 GB purgeable) [M].
- The catalog also holds 2,199 rows from unplugged cards and cameras. Their files are
  absent because the devices are absent: camera rows point at staging folders deleted
  on disconnect (ADR 0013) [M, V].

## What makes downloaded files cloud-only again

- Otos's own record: of 999 originals imported on 2026-08-31, 300 (11.5 GB) were
  cloud-only within hours with about 17 GB free
  (`2026-09-01-onedrive-hydration-shape-and-latency.md`) [M, earlier].
- `FileManager.evictUbiquitousItem(at:)` made OneDrive test files cloud-only from a
  command-line process (`trash-dataless-placeholders.md`) [M, earlier]. That
  contradicts ADR 0008's "a consumer app cannot evict another provider's files", which
  was measured with `NSFileProviderManager` (`NSFileProviderErrorProviderNotFound`).

- **macOS evicts, not OneDrive's own policy.**
  - The FileProvider SDK's default root content policy on macOS, `downloadLazily`,
    says "Allow eviction on low disk pressure and other triggers"; only
    `downloadEagerlyAndKeepDownloaded` prevents it [V, `NSFileProviderItem.h:265`].
  - Microsoft's Files On-Demand page says the same: "the operating system will evict
    (dataless) files from the sync root" under disk pressure [R,
    [Microsoft](https://support.microsoft.com/en-au/onedrive/save-disk-space-with-onedrive-files-on-demand-for-mac)].
  - OneDrive for Mac has no Storage Sense–style policy. Its only space setting,
    `MinDiskSpaceLimitInMB`, blocks downloads below a floor; none is set here [R,
    [Microsoft admin settings](https://learn.microsoft.com/sharepoint/deploy-and-configure-on-macos);
    M, `defaults`].
- **Only uploaded, idle, unmodified files are eligible.** An Apple engineer: File
  Provider "marks uploaded files as evictable in APFS, and the system will
  automatically evict eligible items upon low disk pressure" [R,
  [Apple forums 756058](https://developer.apple.com/forums/thread/756058)]. `evictItem`
  refuses items with unsynced edits or open descriptors [V, `NSFileProviderManager.h`].
- **Eviction stops at the purge goal.** On 2026-10-24 at 22:49–22:52, macOS's purge
  daemon (`deleted`) ran a 3.10 GB purge at urgencies 1→3:
  - File Provider was asked for 35.9 MB, 776 MB and 57 MB, purged 0 bytes each time,
    and was disqualified;
  - `deleted` logged that it was "unable to satisfy the purge request".

  [M, unified log] That matches the measured 3.1 GB of purgeable space: with the
  OneDrive domain failing to start, none of the 53 GB counts as uploaded, so none is
  eligible [I].
- **Which files go first is unknown.** In Camera Roll, about 35% of each import day's
  files since 10-03 are still downloaded, the same share for every file type. That fits
  "evict up to the goal, then stop" [M; I]. Whether eviction is ordered by last use is
  undocumented [U].
- `evictUbiquitousItem(at:)` is documented for iCloud only; Otos's 2026-10-01 success
  on OneDrive is the only evidence for File Provider domains [V, R].
- **Consequence:**
  - Downloads Otos makes are reclaimable by macOS once uploaded and idle, and only as
    far as a purge needs.
  - While the domain is broken, or files still await upload, nothing is reclaimed.
  - Background downloads have no free-space floor today; they stop only when the
    provider reports insufficient space (`MaterializationCoordinator.swift:684`) [V].

## On-demand rendering, measured

From a downloaded original, one process per run, RAW9 [M]:

| Work | Time |
| --- | --- |
| Loupe-size render (2600×1734), filter creation to pixels | 1.0–1.2 s (4.4 s on the first run after build) |
| 100% view, visible 2560×1600 rectangle | 0.43–0.78 s first, 10–80 ms per slider change |
| Full-size JPEG (q 0.85) for hand-off | median 2.2 s, p90 2.4 s (n=20) |

Apple's draft mode did not shorten the loupe-size render (0.98–1.09 s).

## Stored preview, measured

20 randomly chosen downloaded files per type. Preview long edge 2560 px, Display P3,
quality 0.85. ARW through RAW9; JPEG and HEIC downscaled with orientation applied [M]:

| Source | Source median | HEIC preview mean (median, p90) | JPEG preview mean | Render | Decode of the HEIC preview, cold process |
| --- | --- | --- | --- | --- | --- |
| ARW | 34.3 MB | 0.44 MB (0.37, 0.76) | 0.94 MB | median 1.1 s | median 128 ms |
| JPEG | 0.95 MB | 0.43 MB (0.36, 0.76) | 0.82 MB | median 0.10 s | median 107 ms |
| HEIC | 4.4 MB | 0.37 MB (0.34, 0.57) | 0.85 MB | median 0.25 s | median 65 ms |

- Estimate for the ~13,900 library stills: about 6 GB as HEIC, about 12 GB as JPEG [I,
  means × counts].
- A full-size JPEG of an ARW is a median 4.8 MB (p90 6.8 MB) [M].
- The decode times include a cold process's framework start-up; a warm decode inside
  the app is unmeasured [U].

## Device rows

- Rows of unplugged sources stay until Forget (ADR 0013 decision 4) [V].
- A source returning without some files loses their rows:
  - a volume through its rescan;
  - a camera through `completeDeviceCatalogEnumeration` → `reconcileMissingAssets`
    (`CatalogStore.swift:2550`).

  [V] No test pins the camera case [V, test search].
- Device rows can hold a like or dislike (ARC-054), and import copies it to the library
  copy (`CatalogStoreImportJournal.swift:223`) [V]. None of today's device rows has one
  [M].
- They use 2,026 thumbnails, 32.6 MB [M].
- Disk images (Raycast, BoltAI 2) catalogued in July remain as sources with no rows.
  Today's monitor rejects disk images (`RemovableVolumeMonitor.swift:292`), but nothing
  removes the ones already stored [V, M].
