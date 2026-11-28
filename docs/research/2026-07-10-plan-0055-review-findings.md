# Plan 0055 review findings: naming, publication, durability, and camera facts

Date: 2026-07-10
Scope: a deep review of plan 0055 against the current Otos code, the
`../gomediaimport` CLI (behavioral gold standard), the retired `../Otos
Studio_old` import engine at `c799517a`, the first-party `../MediaMetadata`
library source, and Apple/SQLite platform documentation. Each finding below is a
fact the amended plan now relies on; the plan sections that consume them are
noted inline. This is research input, not authoritative implemented behavior.

## 1. Floating EXIF timestamps produce no UTC instant — naming must use wall-clock components

`MediaMetadata` deliberately sets `instant = nil` for EXIF timestamps that carry
no UTC offset (`TIFFMetadataParser.timestampCandidate`: `instant =
offsetSeconds.flatMap { … }`, authority `.localWithoutOffset` →
`CaptureTime.precision == .localFloating`). Most cameras do not write
`OffsetTimeOriginal`, so for the majority of real photos `ts_original_unix` is
NULL in the Otos catalog (`MediaEnricher.timestampFacts` promotes only
`timestamps.original?.instant`), and `best_capture_unix` already falls back to
filesystem dates. Consequences:

- Any naming policy phrased as "render the capture instant in a zone" silently
  names most photos by file mtime, not EXIF, and changes names when the Mac's
  time zone changes — breaking import idempotence for travelers.
- Every `MediaMetadata` parser path (TIFF/EXIF, ISOBMFF/QuickTime, GoPro GPMF,
  RIFF) constructs **complete wall-clock `dateComponents`** for every timestamp
  candidate — UTC components for absolute instants, local components for
  floating/offset timestamps. `CaptureTime.year…second` are non-optional fields.
  `MediaEnricher` already persists the components (plus offset and precision)
  into `asset_metadata.metadata_extra_json` per role.
- `gomediaimport` names by formatting the parsed timestamp value directly (Go
  `time.Format` on the parsed value), i.e., wall-clock verbatim: camera-local
  wall time for EXIF, UTC wall time for bare QuickTime `creation_time`.

Conclusion adopted by the plan (contract item 6, sections 4.2/4.4/4.5, planner
7.1): names and date folders represent the **local capture time only**. Format
parsed local-authority wall-clock components verbatim (`localFloating` /
`localWithOffset`); persist a compact `capture_wall_compact` scalar selected
from local-authority candidates only; backfill from stored metadata JSON; only
the mtime fallback renders a zone. **UTC-anchored timestamps
(`precision == .absolute`) are excluded from naming entirely** — a UTC wall
clock without a local offset is not the time where the item was captured.
MediaMetadata needs a stated/test-pinned contract, a
capture-local accessor that returns `nil` for absolute candidates, and
local-preferring role selection (a GPMF UTC epoch can currently shadow an Apple
local `creationdate` under the same `quickTimeCreationDate` role because
`CaptureTimestamps` takes the first parsed candidate per role).

### 1a. QuickTime container `creation_time` is unreliable in both directions

The QTFF/ISO 14496-12 specification stores container creation/modification
times as UTC, but ExifTool documents that "digital cameras often store local
time values instead (presumably because they don't know the time zone)," which
is why its `QuickTimeUTC` conversion is off by default. The atom is therefore
untrustworthy for local capture time whether or not the spec is honored:
spec-honoring files need a zone Otos does not have, and spec-violating files
carry unmarked local time indistinguishable from UTC. Excluding it from naming
and falling back to the card mtime (which the camera wrote in local time — see
1b) is strictly more reliable.

The exclusion is scoped precisely: **UTC is banned only when the capture zone
is unrecoverable.** A UTC-anchored timestamp accompanied by a recorded capture
zone converts to the local wall clock and is a first-class naming input:

- explicit `±hhmm` offsets (including `+0000`) are affirmative zone claims and
  already parse as `.localWithOffset` with local components;
- a UTC epoch beside a recorded device timezone converts to a derived local
  candidate. Concrete case found in MediaMetadata: the GPMF parser reads
  GoPro's `TimeZone` minutes field (`GoProMetadata.timeZoneMinutes`,
  ISOBMFFMetadataParser) but records it only as a diagnostic finding next to
  the `.absoluteInstant` creation epoch — the combination is discarded today.
  Combining them is a required MediaMetadata change (plan §4.5 item 4);
- bare `Z`-suffixed strings stay excluded: `Z` is the normalization idiom of
  encoders that do not know their zone, not a claim that capture happened in
  UTC+0, and trusting it would misname the common normalized case to gain only
  the rare genuinely-UTC+0 case;
- deriving the zone from GPS coordinates via a tz database is sound in
  principle but needs offline historical zone data; explicitly deferred.

Source: [ExifTool QuickTime tags](https://exiftool.sourceforge.net/TagNames/QuickTime.html)

### 1b. mtime fallback semantics: FAT/exFAT and PTP preserve local wall time

FAT stores pure local wall time on disk; exFAT stores local time plus an
optional 15-minute-granularity UTC offset field whose validity bit cameras
generally do not set (and whose handling is inconsistent across OS drivers per
the forensics literature). OS drivers (macOS msdosfs, Linux vfat) derive the
epoch by applying the *machine's current* offset. Rendering that epoch back in
the machine's current zone therefore reconstructs the on-card wall time
regardless of what zone the Mac is in — the offset cancels. PTP
`CaptureDate`/`ModificationDate` are DateTime strings in local device time
(ISO 15740 §5.3.4.1: optional `Z`/`±hhmm` suffix; "appending neither indicates
the time zone is unspecified"), parsed through the same current-zone lens by
ImageCaptureCore. Consequences:

- The earlier claim that mtime-fallback names "break idempotence across time
  zones" was **overbroad**: for FAT/exFAT cards and PTP sources — the dominant
  cases — wall time is the on-disk invariant and current-zone rendering is
  stable across Mac zone changes.
- The narrow residual zone-sensitive case is an epoch-native source filesystem
  (APFS external drive, network volume), plus a minor DST edge (kernel
  conversion uses a single current offset while Foundation applies historical
  DST rules for the file's date).

Sources:

- [exFAT specification (UtcOffset fields)](https://learn.microsoft.com/en-us/windows/win32/fileio/exfat-specification)
- [exFAT timestamp handling inconsistencies across OSes](https://www.sciencedirect.com/science/article/pii/S2666281722001573)
- [Linux vfat local-time conversion / tz=UTC option](https://lwn.net/Articles/287428/)
- [PIMA/ISO 15740 PTP spec §5.3.4.1 DateTime string](https://people.ece.cornell.edu/land/courses/ece4760/FinalProjects/f2012/jmv87/site/files/pima15740-2000.pdf)

### 1c. PTP CaptureDate/ModificationDate are optional

ISO 15740 defines both ObjectInfo date fields as optional ("CaptureDate: A
static optional field… ModificationDate: An optional field…"), so a
spec-conforming device may deliver dateless items; current Otos code already
observes zero/invalid values (`validCameraDate` rejects ~epoch-zero). This is
why the per-item `.blocked(.noUsableDate)` path exists even though filesystem
sources always have an mtime; in practice the case is rare.

### 1d. Naming bundles (RAW+JPEG, Live Photos)

RAW+JPEG pairs and Live Photo HEIC+MOV pairs share a directory and stem on
camera media and represent one shot. Without bundling, a MOV whose only
embedded date is the unreliable UTC atom would take the mtime fallback and
could land a different second than its HEIC (splitting the pair), and
mixed-burst suffix ladders could pair `_002.cr3` with `_003.jpg` from a
different shot. The plan groups same-directory same-stem eligible media into
one naming bundle sharing timestamp, stem, and suffix, with companions
following the bundle — Lightroom-consistent stem grouping.

### 1e. Imported-file mtime policy

Imported files' mtimes are the original capture date, never the import moment:
stamp the staged file (publication is a rename of
the same inode) with the embedded local-authority capture time interpreted in
the current zone when available, else preserve the planned source mtime — the
defined-zone version of `gomediaimport`'s `setFileTimes`. The stamped value is
journaled (`destination_modified_at`). Reorganization renames never touch
mtimes and the executor stamps nothing.

## 2. `FileManager.moveItem` no-overwrite is not atomic; `renamex_np(RENAME_EXCL)` is

Foundation documents that `moveItem` fails when the destination exists, but the
check is user-space before `rename(2)` — a check-then-act window. The atomic
primitive is `renamex_np(..., RENAME_EXCL)` (returns `EEXIST` atomically on
supporting filesystems); per-volume support is discoverable via `getattrlist`
`VOL_CAP_INT_RENAME_EXCL`. APFS supports it, which covers local libraries and
File Provider domain replicas. The realistic concurrent writer for an import
destination is a cloud sync engine materializing a same-named file synced from
another device. Plan 0055 section 8.1 now specifies the ladder
(`renamex_np` → `link`+`unlink` → documented `moveItem` fallback) with the Stage
E probe confirming the capability matrix.

Sources:

- [renamex_np(2)](http://www.manpagez.com/man/2/renamex_np/osx-10.12.3.php)
- [rename(2) Xcode man page](https://keith.github.io/xcode-man-pages/rename.2.html)
- [FileManager.moveItem(at:to:)](https://developer.apple.com/documentation/foundation/filemanager/1414750-moveitem)

## 3. `copyfile(3)` provides OS-native byte progress and mid-file cancellation

`FileManager.copyItem` wraps `copyfile` but exposes no progress or mid-file
cancellation; both reference engines (gomediaimport's chunked worker copy, the
retired executor's POSIX loop) provided byte progress and prompt aborts.
`copyfile(3)` with a `copyfile_state_t` progress callback preserves clones,
metadata, and xattrs (`COPYFILE_ALL`) while the callback's return value aborts
the copy. Plan section 8.1 selects coordinator + `copyfile` for copies +
`FileManager` for moves/deletes. `COPYFILE_ALL` also preserves modification
dates for filesystem copies (see finding 4).

## 4. Destination timestamps are load-bearing domain facts

Because destination mtime is the best-date fallback for imported assets
(contract item 5), a copy path that stamps "now" fabricates a date. Both
reference implementations set timestamps explicitly (`gomediaimport
setFileTimes` stamps the extracted capture datetime; the retired engine's
`preserveTimestamps` copied source times onto the staged file before finalize).
`copyfile(COPYFILE_ALL)` preserves mtime for filesystem sources; **ImageCapture
`requestDownload` has no documented mtime contract** and must be probed on real
hardware (Stage F). Per finding 1e the plan goes further than preservation:
imported files are stamped with the embedded capture time when available, else
the source mtime.

## 5. WAL + `synchronous=NORMAL` is app-crash durable, not power-loss durable

The catalog pool runs WAL with `PRAGMA synchronous = NORMAL`
(`CatalogStorePersistence.fileBackedDatabaseConfiguration`). Per SQLite
documentation, commits in this mode are durable across application crashes but
may roll back to the last checkpoint on power loss or kernel panic. A lost
settlement transaction silently loses an import-batch stamp for a published
file; a lost `sourceDeletionPending` row forgets a requested deletion; a lost
reorganization component recipe orphans a temp file recovery cannot see. Plan
section 4.1 item 4 now selects `synchronous = FULL` escalation for journal and
settlement transactions, measured in Stage E, with a documented fallback.

Source: [SQLite PRAGMA synchronous](https://www.sqlite.org/pragma.html#pragma_synchronous)
("WAL mode is safe from corruption with synchronous=NORMAL … a transaction
committed in WAL mode with synchronous=NORMAL might roll back following a power
loss or system reset").

## 6. The catalog cannot answer destination occupancy for import candidates

The scanner catalogs only eligible media (symlinks, packages, hidden files, and
non-media occupants are invisible), and FSEvents reconciliation is debounced.
The reorg half of the plan already concedes this and probes the filesystem
(`NamespaceOccupancyRequest`); the import planner originally trusted catalog
snapshots, which produces a fail/replan livelock when a foreign occupant holds a
candidate name (publish `EEXIST` → replan from the same blind snapshot → same
candidate). Plan sections 7.1/7.2/6.4 now give import the same occupancy-probe
boundary plus publish-time foreign-occupant feedback.

## 7. Camera sidecar and artifact facts

- `ICCameraFile.sidecarFiles` is a read-only **property** populated during
  enumeration; `.sidecarFiles` in download options controls download bundling.
  The plan's earlier "camera enumeration sets `.sidecarFiles: true`" conflated
  the two. Real-device probing is required (Stage B) for whether XMPs appear in
  `mediaFiles`, only via `sidecarFiles`, or both, and whether sidecar items
  expose size/mtime (the `media_companion` schema now allows NULL camera facts).
- `.lrc` is not a camera companion format in any ecosystem found: DJI produces
  `.srt` telemetry plus `.lrf` low-resolution proxy videos (per DJI support and
  community documentation); GoPro produces `.thm`/`.lrv`. `.lrc` is a lyrics
  format (audio-domain, which Otos categorically excludes). `gomediaimport`'s
  copy set is exactly `{xmp, srt}`. The plan drops `.lrc` pending device
  evidence.
- `gomediaimport` structurally excludes Sony `M4ROOT/THMBNL` thumbnail
  directories, Sony `M4ROOT/CLIP/*.xml`, top-level trash directories, and
  AppleDouble files. Current Otos `MediaEligibility` excludes only
  `M4ROOT/SUB`, `.Trashes`, Spotlight, and `avf_info` — so a Sony card's
  THMBNL content may be catalog-eligible and would be imported by "import
  everything." Stage B adopts the ignore list and verifies against real card
  fixtures.
- The scanner skips packages (`.skipsPackageDescendants` + `isPackage`), and
  macOS presents AVCHD camcorder structures as packages; whether that holds on
  FAT/exFAT cards must be verified with a real card (Stage B). Until packages
  are surfaced, "import everything then eject" would silently skip camcorder
  video — hence the contract item 2 skipped-package attention state.

Sources:

- [ICCameraFile.sidecarFiles](https://developer.apple.com/documentation/imagecapturecore/iccamerafile)
- [DJI: about .LRF files](https://support.dji.com/help/content?customId=01700006938&spaceId=17&re=US&lang=en)
- [DJI SRT telemetry files](https://mavicpilots.com/threads/lrf-and-srt-files.118171/)

## 8. RAW+JPEG breaks exactly-one companion pairing

`IMG_1.CR3` + `IMG_1.JPG` + `IMG_1.xmp` matches two eligible primaries; an
"exactly one match or unpaired" rule silently strands the xmp on import and
orphans it during reorganization. `gomediaimport` pairs first-match; the
Lightroom ecosystem convention pairs xmp with the raw. Plan contract item 10 and
section 5 now select prefer-raw with a deterministic non-raw fallback, plus
bundle-level destination-conflict handling (a companion can never suffix
independently of its primary, and is never overwritten — gomediaimport silently
truncates existing sidecars, which is not acceptable here).

## 9. Reference-engine deltas the plan now records explicitly

- **Source-internal duplicates:** gomediaimport optionally collapses
  byte-identical same-source files via xxHash; the plan never collapses
  (deterministic suffixes), matching the reorganization never-collapse rule.
  Recorded as a deliberate divergence in contract item 7.
- **Extension normalization:** gomediaimport rewrites extensions to the type's
  canonical first extension (`.jpeg → .jpg`); the plan lowercases only,
  recorded in planner step 7.1(3).
- **Execution self-invalidation:** settlements and requested source deletions
  bump the very revisions that guard plan starts; contract item 13 now states
  revisions guard starts, never continuation, and rebuilds are deferred until
  the execution finishes.
- **Sort-key recomputation:** relocation settlement must recompute `sort_key`,
  `name_sort_key`, and `name` (the `updateLibraryRootPath` precedent does; a
  missed recompute corrupts grid ordering silently). Now step 5 of section 4.3.

## 10. Greedy equality cost: the worst case is the common case

Re-attaching an already-imported card makes every file an equal-size candidate
and byte-compares the entire card against the destination in background
planning; a strictly per-generation comparison memo restarts the sweep on any
destination revision bump (e.g., one cloud-sync write), so convergence is not
guaranteed on active cloud destinations. Plan section 7.3 adds an ephemeral
in-memory cross-generation memo keyed by both sides' `(path, size, mtime)` and
the section 11 re-attach fixture measures total comparison bytes and memo hit
rate. Plan readiness remains enrichment-gated for filesystem sources (the
source is read once for metadata/thumbnails before the copy reads it again);
this cost is accepted for the first release and measured via the new
`op=mediaOperation.readiness` instrumentation, with a metadata-first readiness
split as the designated follow-up if it dominates. Camera (deviceMTP) sources
are exempt: PTP capture/modification dates arrive at enumeration without
downloads (finding 1b), so camera plan readiness never requires staging the
card, and import execution reuses enrichment-staged bytes when present instead
of a second device download (the retired engine's staging-reuse optimization).
