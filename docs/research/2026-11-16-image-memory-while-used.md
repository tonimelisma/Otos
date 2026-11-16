# Image memory while the app is used (macOS 27, 2026-11-16)

## Question

Plan 0116's last unmet target is a peak footprint of at most 700 MB. At rest the app now
meets it, but the owner's full tour on 270d9a66 peaked at 1,171 MB and never came back down.
Its own `op=process.memory` samples, by step:

| Step | Footprint |
| --- | --- |
| First grid | 163 MB |
| People clicked (`tourStep label=people`, 0.7 s after the gallery painted) | 410 → 674 MB |
| Photo steps (open, next ×3, previous ×3, Compare) | 788 → 1,012 MB |
| `peopleBuilt` after the session's first assignment pass | 915 → 1,091 MB |
| Session peak | 1,171 MB |

What allocates at each of these moments?

## Method

- **The owner's unified log** for that session, read-only (`log show --info --debug`). The
  installed app was not launched.
- **A standalone probe**: a Swift program with no Otos code, `-O`. It reads `phys_footprint`
  from `TASK_VM_INFO` and runs `vmmap --summary` on itself. Its input is 60 generated
  2560 × 1920 8-bit Display P3 HEICs, the stored previews' shape (ADR 0035). Each mode runs in
  a fresh process.
- **The test process**: `ImageMemoryTests` (`OTOS_SCALE_TEST=1`, alone) and
  `PeopleStoreTests.peopleCostsOnTheOwnersShape` on the generated owner-shaped catalog.

## 1. Opening People: a face tile held the whole decode it was cut from

`FaceCrop.decode` decoded the preview with `CGImageSourceCreateThumbnailAtIndex`, at the scale
that makes the face's enlarged box 256 px (a 128 pt cell on a Retina display). It then cut the
tile with `CGImage.cropping(to:)`. A crop keeps a reference to the image it was cut from. For
a small face the decode is the whole 2560 px preview. `FaceTileImages` costed each entry at
the crop's own rows, so its 100 MB limit admitted gigabytes of real memory.

The probe ran 48 tiles with faces of 4 to 14 % of the preview's width:

| Tile made by | Held (48 tiles) | Tile pixels | Time | One tile's peak |
| --- | --- | --- | --- | --- |
| thumbnail, then `cropping(to:)` (before) | **563 MB** | 10 MB | 2.65 s | 28 MB |
| thumbnail, then the cut drawn into its own mapped pixels | 24 MB | 10 MB | 2.62 s | 48 MB |
| the cut drawn from the uncached image into its own mapped pixels (after) | 27 MB | 10 MB | 0.77 s | 9 MB |

Drawing a cut of the uncached image decodes only the part of the HEIC the cut covers, so a
tile costs a fraction of a decode and is 3.4 times faster.

The test process says the same. `ImageMemoryTests.thePeopleGalleryHoldsOnlyItsTiles` opens a
gallery of 200 people in a 1200 × 800 window at a backing scale of 2, over 24 generated
previews, with faces of 3 to 8 % of the photo's width. It waits until the first 24 cells'
tiles are decoded:

| | Footprint before the gallery | Tiles painted |
| --- | --- | --- |
| Before | 63 MB | **875 MB** |
| After | 63 MB | 115 MB |

**Fix.** `FaceCrop` draws the cut from the uncached image into a `MappedImage`
(`Otos/Support/MappedImage.swift`): its own pixels in a `ScratchBuffer`, unmapped when the
image goes. A turned preview, which Otos never writes, is decoded upright at the tile's
scale first, as before. `FaceTileImages` now costs what each entry really holds. Its limit
is 48 MB, about 190 gallery tiles, several screenfuls.

## 2. Decoded image memory itself is returned

Holding 10 previews and then releasing them, in the probe:

| Path | Region | Held | After release |
| --- | --- | --- | --- |
| `CGImageSourceCreateThumbnailAtIndex` at 2560 | IOSurface | 208 MB | 8 MB |
| `ThumbnailStore.load` (decode, then draw into a bitmap context) once its pixels are read | CG Raster Data | 236 MB | 48 MB |

A bitmap context made with `data: nil` on macOS 27 defers its drawing. The image it makes
fills its "CG Raster Data" region only when its pixels are first read, here at 20 MB a
preview. Both regions are virtual memory of their own and leave the footprint when the image
goes. Unlike freed malloc blocks
(`2026-11-16-freed-memory-stays-in-the-footprint.md`), decoded images cost the footprint
only while something holds them. So the loupe's memory is a matter of what it holds.

## 3. The full-size view held photos nobody was looking at

`PreviewImageLoader` kept a 256 MB LRU of decodes, and a full-resolution decode went into it
too. The pane already holds the image it shows (`PanePreview`), so everything the LRU held
beyond that was a photo already left: a stored preview is about 18 MB decoded, and 256 MB is
14 of them, or one full-resolution decode of a large original.

`ImageMemoryTests.theFullSizeViewHoldsOnlyWhatItCanReturnTo` walks ten generated stored
previews in the loader as the loupe asks for them, painting each, then steps back one. In the
test process, alone:

| | Before the walk | After the walk |
| --- | --- | --- |
| 256 MB LRU (before) | 194 MB | **354 MB** (+160) |
| Last three photos, no full-resolution decode held (after) | 151 MB | **214 MB** (+63) |

**Fix.** The loader holds the screen-sized decodes of the last three photos asked for, by
count: both Compare panes and the photo just left, so a step back or a slide back paints at
once. A full-resolution decode is held only by the pane showing it.
