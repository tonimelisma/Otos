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

## Owner decisions already made

1. One current edit per photo, stored in the catalog. No sidecars, no catalog export.
2. Originals are never modified; an edit is a recipe rendered from the original.
3. An edit sidebar on the right, built piece by piece.
4. Controls are what macOS provides, starting with RAW9. No masks, looks or learned
   models.
5. An unedited RAW is shown with RAW9 defaults.
6. Grid, loupe and thumbnails always show the edited photo; a thumbnail updates after
   an edit.
7. The edited version is what leaves Otos on copy, paste, Share and drag. Several
   selected photos copy and paste as several, including into a browser.
8. Export is allowed, including several photos at once.
9. No checksum identity (option B rejected).

## Facts the plan rests on

| Fact | Evidence |
| --- | --- |
| The library is about 778 GB; the Mac has a 494 GB disk with 15–16 GB free | catalog + `stat`, 2026-10-25 |
| 4,914 of 5,358 library RAWs and 8,031 of 8,536 other images are cloud-only | `SF_DATALESS`, 2026-10-25 |
| macOS makes downloaded OneDrive files cloud-only again under disk pressure, but only uploaded, idle files and only up to the purge goal | `2026-09-01-onedrive-hydration-shape-and-latency.md` (300 of 999 imports within hours); `2026-10-25-library-storage-and-previews.md` (SDK, Microsoft, purge log) |
| Background downloads have no free-space floor; with the OneDrive domain broken, nothing downloaded is reclaimable | code + purge log, 2026-10-25 |
| Today's grid thumbnail is Quick Look's copy of the camera's embedded JPEG | measured, `2026-10-25-raw-decoders…` |
| A cloud-only original takes seconds to over a minute to download | `2026-09-01…`, `2026-07-14-interactive-materialization-priority.md` |
| RAW9 renders at screen size in 1.0–1.2 s from a downloaded original | measured, 2026-10-25 |
| A 2560 px HEIC preview averages 0.37–0.44 MB (≈6 GB for ~13,900 photos); JPEG about twice that | measured on 60 photos |
| A full-size JPEG of a RAW takes ~2.2 s and is ~4.8 MB | measured on 20 RAWs |
| Browsers receive every pasted or dropped file; Chrome cannot display HEIC; neither displays ARW | measured, `2026-10-25-browser…` |
| Rows of unplugged cards and cameras stay until Forget; they hold derived data plus likes | code + catalog, 2026-10-25 |

## Increments

Each increment is one PR through the normal path. Numbers give the order; increments
1–3 do not depend on the others and can land at any time.

### 1. Correct the materialization docs, and floor background downloads

- **Docs.** ADR 0008, ADR 0009, ENR-008 and CLAUDE.md say downloaded bytes are
  "unreclaimable" and that a consumer app has no eviction path. Rewrite them to the
  research:
  - macOS evicts uploaded, idle files under disk pressure, up to its purge goal;
  - nothing is reclaimed while the provider is down or uploads are pending;
  - `evictUbiquitousItem(at:)` worked on OneDrive once, without a documented contract.
- **Code, if Q5 is yes.** Background and device downloads start only while free space
  is above the same 5 GB floor that import (ADR 0027) and Move to Trash use, measured
  at each attempt, with no polling. Interactive downloads (the photo you opened) are
  exempt.

### 2. Device sources: retention and the missing test

- Add the test that a camera or card returning without some files removes their rows
  (code does it in `reconcileMissingAssets`; no test pins it).
- If Q1 is yes: forget a removable source whose last-seen date is 90 days old, exactly
  as the existing Forget does. Amends CLAUDE.md, ADR 0008, ADR 0013 and ARC-033 in the
  same PR.

### 3. Re-attach overlay after a move outside Otos (option C)

The scanner records inode and volume; the reconcile that would purge a missing row
first looks for a single new row on the same volume with equal inode, size, mtime and
birth time, and re-keys the overlay to it. Amends ADR 0008. Its cloud coverage is
stated from experiment R2.

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
  - Loupe and compare show the preview: about 0.1 s to decode (measured cold), cloud
    or not.
  - Zooming to 100% renders the visible rectangle from the original (0.2–0.8 s),
    downloading it if needed.
- **Backfill:** existing stills re-enter enrichment through the staleness key. Grid
  thumbnails switch from the camera's look to RAW9 as each file is processed; the
  no-blank rule holds, since a newer thumbnail of the same asset replaces the old one.
- **Bounds:** concurrent RAW renders are bounded by memory, measured at 160–340 MB
  each.

Docs: a new ADR for the render owner and previews; ADR 0009 (thumbnail generator),
ADR 0016 (preview decode); ENR-004 and new ENR/APP rows.

Videos keep their Quick Look thumbnail; playback downloads as today.

### 5. Edit recipe, sidebar and Exposure

- The recipe table (one current recipe per asset, overlay lifecycle) and the right
  sidebar.
- Undo, redo and reset.
- Exposure for RAW (`exposure`) and other stills (`CIExposureAdjust`).
- While dragging, the sidebar renders live from the original (20–180 ms per change).
  On commit, the thumbnail and preview are re-rendered.

Docs: a new ADR for edit storage; a design spec for the sidebar
(`docs/design/edit-sidebar.md`) reviewed against the design system; APP and DES rows.

### 6–11. One control per increment

| # | Edit | Notes |
| --- | --- | --- |
| 6 | White balance: temperature, tint, neutral picker | First control whose RAW and non-RAW meanings differ |
| 7 | Crop, rotate 90°, flip, straighten | First that changes output size; thumbnail and preview follow |
| 8 | Contrast, highlights, shadows | |
| 9 | Vibrance, saturation | |
| 10 | Sharpness, noise reduction, lens correction | RAW8-only controls (colour noise, detail, moiré) appear only on RAW8 photos |
| 11 | Vignette | |

### 12. Hand-off: copy, drag, Share, Open With

All four hand over rendered files in one Otos-owned folder in Application Support,
named after their originals, one file URL per photo (ADR 0012's shape). The folder is
cleared at the next launch.

- **Copy, drag and Share:** a JPEG at the resolution Q2 decides. JPEG because Chrome
  cannot display HEIC.
- **Open With:** a full-size render, because the receiving editor needs every pixel.

Amends ADR 0012, ADR 0028, APP-012, APP-035, APP-036 and APP-038.

### 13. Export

Scope per Q3. Several photos run as one background job with progress and cancel, and
use `ExclusivePublication` so nothing is ever overwritten. CLAUDE.md's list of the ways
the user's files change gains export. New ADR plus APP rows.

### 14. Video trim

`AVPlayerView` trimming as a recipe. Kept last; confirm it is still wanted.

## Research and tests

| | What | Who | Status |
| --- | --- | --- | --- |
| R1 | What makes OneDrive files cloud-only again, when, and which files | agent | done: macOS under disk pressure, uploaded idle files only, up to the purge goal; ordering unknown |
| R2 | Remote rename and move on OneDrive: does the local file keep its inode? | agent, after owner actions A1 and A2 | blocked |
| R3 | Live drop into Safari.app and into Chrome | agent with screen control, or one drag by the owner | optional: WebKit and Chromium source already cover it |
| R4 | In-app: warm preview decode, enrichment throughput with RAW9 renders, memory | agent, during increment 4 | at build time |

## Open questions for the owner

- **Q1.** Forget a card or camera unseen for 90 days, including likes on photos never
  imported?
- **Q2.** Copy, drag and Share hand over:
  - (a) a 2560 px JPEG: instant, works for cloud-only photos and for drag; or
  - (b) a full-size JPEG: about 2.2 s per RAW, plus the download for each cloud-only
    original. A drag cannot wait, so a cloud-only photo could not be dragged out
    straight away.

  Full size is always available through Export.
- **Q3.** Export, first version, proposed:
  - format JPEG, HEIC or Original;
  - size full or a long edge in pixels;
  - JPEG quality;
  - a destination folder chosen each time and remembered;
  - name collisions get a `-N` suffix;
  - metadata kept, with a toggle to remove location.

  Exporting into a library folder: allowed (Otos then catalogs the exports) or
  refused?
- **Q4.** Confirm the edit order in increments 5–11, and that video trim stays.
- **Q5.** Should background downloads stop at the 5 GB free-space floor (increment 1)?
  Today they continue until OneDrive refuses.

## Owner actions

- **A1.** Restart OneDrive: its sync component on this Mac reports "unable to startup
  … database is locked".
- **A2.** For R2: allow Otos's agent to put one test file in the OneDrive folder, then
  rename and move it from your phone or onedrive.com while the agent watches this Mac.
