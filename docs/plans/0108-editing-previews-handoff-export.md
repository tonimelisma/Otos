# Plan 0108: Editing, previews, hand-off and export

Status: draft for owner alignment, 2026-10-25. Nothing here is built.

Research behind it:
- `docs/research/2026-10-24-editing-foundation.md`
- `docs/research/2026-10-24-macos-image-and-video-editing-apis.md`
- `docs/research/2026-10-24-edited-photo-handoff-and-export.md`
- `docs/research/2026-10-24-asset-identity-and-out-of-app-moves.md`
- `docs/research/2026-10-25-raw-decoders-thumbnails-and-full-size-renders.md`
- `docs/research/2026-10-25-cloud-drives.md`
- `docs/research/2026-10-25-browser-multi-file-paste-and-drop.md`
- `docs/research/2026-10-25-library-storage-and-previews.md`

## Owner decisions

1. One current edit per photo, stored in the catalog. No sidecars, no catalog export.
2. Originals are never modified; an edit is a recipe rendered from the original.
3. An edit sidebar on the right, built section by section (order below).
4. Controls are what macOS provides, starting with RAW9. No masks, looks or learned
   models.
5. An unedited RAW is shown with RAW9 defaults.
6. Grid, loupe and thumbnails always show the edited photo; a thumbnail updates after
   an edit.
7. The edited version is what leaves Otos on copy, paste, Share and drag. Several
   selected photos copy and paste as several, including into a browser. Hand-off
   behaves like Finder: the full-size file, handed over at once.
8. Export is allowed, including several photos at once and into a library folder.
9. No checksum identity (option B rejected).
10. A card or camera not seen for 90 days is forgotten automatically.
11. Background downloads stop at the 5 GB free-space floor.

## Facts the plan rests on

| Fact | Evidence |
| --- | --- |
| The library is about 778 GB; the Mac has a 494 GB disk with 15–19 GB free | catalog + `stat`, 2026-10-25 |
| 4,914 of 5,358 library RAWs and 8,031 of 8,536 other images are cloud-only | `SF_DATALESS`, 2026-10-25 |
| macOS makes downloaded OneDrive files cloud-only again under disk pressure, but only uploaded, idle files and only up to the purge goal | `2026-10-25-library-storage-and-previews.md` |
| Background downloads have no free-space floor today | `MaterializationCoordinator.swift:684` |
| Today's grid thumbnail is Quick Look's copy of the camera's embedded JPEG | `2026-10-25-raw-decoders…` |
| A cloud-only original takes seconds to over a minute to download | `2026-09-01-onedrive-hydration-shape-and-latency.md` |
| RAW9 renders at screen size in 1.0–1.2 s from a downloaded original | measured |
| A 2560 px HEIC preview averages 0.37–0.44 MB (≈6 GB for ~13,900 photos) | measured on 60 photos |
| A full-size JPEG of a RAW takes ~2.2 s and is ~4.8 MB | measured on 20 RAWs |
| Finder hands over the file itself. Chrome and WebKit accept a cloud-only file's URL, know its size at once, and their read downloads it (0.35–1.3 s for 0.2–0.3 MB JPEGs) | measured, `2026-10-25-library-storage-and-previews.md` |
| Browsers receive every pasted or dropped file; Chrome cannot display HEIC; neither displays ARW | `2026-10-25-browser…` |
| Import names collisions `_001`, `_002`…, shared by a RAW and its JPEG | `ImportNaming.swift:160` |

## Increments

Each increment is one PR through the normal path. Increments 1–3 do not depend on the
others and can land at any time; 4 precedes everything after it.

### 1. Materialization: correct the docs, floor background downloads

- **Docs.** ADR 0008, ADR 0009, ENR-008 and CLAUDE.md say downloaded bytes are
  "unreclaimable" and that a consumer app has no eviction path. Rewrite them to the
  research:
  - macOS evicts uploaded, idle files under disk pressure, up to its purge goal;
  - nothing is reclaimed while the provider is down or uploads are pending;
  - `evictUbiquitousItem(at:)` worked on OneDrive once, without a documented contract.
- **Code.** Background and device downloads start only while free space is above the
  5 GB floor that import (ADR 0027) and Move to Trash already use, measured at each
  attempt with no polling. Interactive downloads (the photo being opened) are exempt.
  Updates ENR-008 and ADR 0009.

### 2. Device sources: 90-day retention and the missing test

- Forget a removable source whose last-seen date is 90 days old, exactly as Settings'
  Forget does: rows, likes, thumbnails and the source entry. Today that removes the
  July disk images (Raycast, BoltAI 2).
- Add the test that a camera or card returning without some files removes their rows
  (`reconcileMissingAssets` does it; no test pins it).
- Amends CLAUDE.md (one overlay lifecycle), ADR 0008, ADR 0013 and ARC-033, and adds
  a `time:` tag per ADR 0033: a retention period is a product rule, not a stand-in
  for a fact.

### 3. Re-attach overlay after a move outside Otos (option C)

The scanner records inode and volume. The reconcile that would purge a missing row
first looks for a single new row on the same volume with equal inode, size, mtime and
birth time, and re-keys the overlay to it. Amends ADR 0008 and ARC-033. Its cloud
coverage is stated from experiment R2.

### 4. Render foundation and stored previews

No editing UI yet. One render owner turns an asset plus its recipe (empty for now)
into pixels:

- **RAW:** `CIRAWFilter` with the newest decoder the file supports (RAW9, else RAW8),
  recorded per photo.
- **Other stills:** Core Image from the original.
- **Products, made whenever the bytes are local** (enrichment pass, import, opening a
  photo):
  - the 256 px thumbnail, now rendered instead of taken from Quick Look;
  - a 2560 px HEIC preview.

  Both live in Application Support under the overlay lifecycle. Staleness key: source
  `(size, mtime)` + recipe revision + decoder version + OS build.
- **Display:**
  - Loupe and compare show the preview: about 0.1 s to decode (cold), cloud or not.
  - Zooming to 100% renders the visible rectangle from the original (0.2–0.8 s),
    downloading it if needed.
- **Backfill:** existing stills re-enter enrichment through the staleness key. Grid
  thumbnails switch from the camera's look to RAW9 as each file is processed; a newer
  thumbnail of the same asset replacing the old one keeps the no-blank rule.
- **Bounds:** concurrent RAW renders are bounded by memory (160–340 MB each, measured).
  Videos keep their Quick Look thumbnail; playback downloads as today.
- **Docs:** a new ADR for the render owner and previews; ADR 0009 (thumbnail
  generator), ADR 0016 (preview decode); ENR-004 and new ENR/APP rows.

### 5. Edit foundation and the Light section

- The recipe table (one current recipe per asset, overlay lifecycle) and the right
  sidebar's frame.
- Undo, redo and reset.
- The **Light** section: Exposure, Contrast, Highlights, Shadows.
- **While dragging,** the photo renders live from the original (20–180 ms per change).
- **On commit,** Otos re-renders three things:
  - the thumbnail;
  - the preview;
  - a **full-size JPEG of the edited photo**, the file that hand-off gives out (13).
    It is kept while the photo has an edit, as Photos keeps renders for edited photos
    only: about 4.8 MB per edited RAW.

  Editing needs the original locally anyway, so the commit costs no extra download.
- **Docs:** a new ADR for edit storage and the edited render; the sidebar design spec
  (`docs/design/edit-sidebar.md`) reviewed against the design system; APP and DES rows.

### 6–11. Sidebar sections

The sidebar follows Lightroom desktop's order ([Lightroom Killer
Tips](https://lightroomkillertips.com/editing-with-lightroom-desktop-and-a-book-giveaway/),
[Adobe Community](https://community.adobe.com/feature-requests-681/p-change-order-of-edit-detail-icons-661292)).
Crop is a tool above the sections. Only controls macOS provides appear:

| Order | Section | Controls | RAW (`CIRAWFilter`) | Other stills (Core Image) | Increment |
| --- | --- | --- | --- | --- | --- |
| tool | Crop | Crop, rotate 90°, flip, straighten | on the developed image | `CICrop`, `CIAffineTransform`, `CIStraightenFilter` | 7 |
| 1 | Light | Exposure, Contrast, Highlights, Shadows | `exposure`, `contrastAmount`, `CIHighlightShadowAdjust` | `CIExposureAdjust`, `CIColorControls`, `CIHighlightShadowAdjust` | 5 |
| 2 | Color | White balance (temperature, tint, neutral picker), Vibrance, Saturation | `neutralTemperature`, `neutralTint`, `neutralLocation`; `CIVibrance`, `CIColorControls` | `CITemperatureAndTint`, `CIVibrance`, `CIColorControls` | 6 |
| 3 | Effects | Vignette | `CIVignette` | `CIVignette` | 8 |
| 4 | Detail | Sharpening, Noise reduction; RAW8 photos also get colour noise, detail and moiré | `sharpnessAmount`, `luminanceNoiseReductionAmount` (+ RAW8 controls) | `CISharpenLuminance`, `CINoiseReduction` | 9 |
| 5 | Optics | Lens correction (RAW only) | `isLensCorrectionEnabled` | — | 10 |

The build order is the sidebar order, with Crop after Color, because it is the first
control that changes the output size. Each section lands complete in one increment.
A section with no supported control for a photo is not shown for it.

### 12. Video trim

`AVPlayerView` trimming stored as a recipe. Last of the editing increments.

### 13. Hand-off: copy, drag, Share, Open With

Finder parity: the full-size file, handed over at once, one file URL per photo (ADR
0012's shape). Which file depends on the photo:

| Photo | Handed over | Cloud-only original |
| --- | --- | --- |
| Edited (any type) | The stored full-size JPEG from increment 5 | Not needed; the render is local |
| Unedited JPEG, HEIC, video | The original, as today | The receiver's read downloads it, as with Finder (measured) |
| Unedited RAW | Per Q6 | — |

Amends ADR 0012, ADR 0028, APP-012, APP-035, APP-036 and APP-038.

### 14. Export

- **Formats:** JPEG, HEIC or Original.
- **Size:** full, or a long edge in pixels, never enlarged.
- **Quality:** JPEG/HEIC quality setting.
- **Destination:** a folder chosen in the sheet and remembered. A library folder is
  allowed; the scanner then catalogs the exports like any new file.
- **Names:** the original's name with the new extension. A collision gets `_001`,
  `_002`… through `ImportNaming.suffixToken`, the same code import uses. Publication
  goes through `ExclusivePublication`, so nothing is ever overwritten.
- **Metadata:** kept, with a switch to remove location.
- **Several photos:** one background job with progress and cancel, under the 5 GB
  free-space floor.
- **Docs:** CLAUDE.md's list of the ways the user's files change gains export; a new
  ADR and APP rows.

## Research and tests

| | What | Who | Status |
| --- | --- | --- | --- |
| R1 | What makes OneDrive files cloud-only again | agent | done: macOS, under disk pressure, uploaded idle files only, up to the purge goal; ordering unknown |
| R2 | Remote rename and move on OneDrive: does the local file keep its inode? | agent + owner (A2) | test file uploaded and watched; waiting for the owner's rename and move |
| R3 | Hand-off of cloud-only originals into browsers | agent | done for paste in Chrome and WebKit; live drop into Safari.app and Chrome optional |
| R4 | In-app: warm preview decode, enrichment throughput with RAW9 renders, memory | agent, during increment 4 | at build time |

## Open questions for the owner

- **Q6.** An unedited RAW, copied or dragged out:
  - (a) **the ARW itself**, exactly as Finder does: instant, even when cloud-only, but
    no web page can show it; or
  - (b) **a full-size JPEG render:** about 2.2 s per photo plus the download of a
    cloud-only original, so a drag of a cloud-only RAW cannot complete straight away.

## Owner actions

- **A2.** On `onedrive.com` or the phone app, in `Otos rename test`:
  1. Rename `A/otos-probe.jpg` to `otos-probe-renamed.jpg`.
  2. Move it into folder `B`.
  3. Rename folder `A` to `A-renamed`.

  The agent watches this Mac and removes the test folder afterwards.
