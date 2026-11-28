# What the full-size view holds while photos are stepped through (macOS 27, 2026-11-16)

## Question

A tour of the reference library on 5f77e2e5 (with the loader's three-photo hold, #866) opened a photo, stepped
next ×3 and previous ×3, then compared two: the footprint went from about 565 MB to about
790 MB, with transient peaks to 830 MB, and came back to about 655 MB only after the view was
left. The loader's own test measured +63 MB for ten photos walked. What holds the rest?

## Method

- **The reference library's derived folder, read-only:** the pixel size of a few stored previews
  (`sips -g pixelWidth -g pixelHeight`, a header read). They are 1920 × 1440 and
  2160 × 1440 (an Immich account's previews, 1440 px on the short edge), 220–700 KB each:
  about 12 MB each decoded at 4 bytes a pixel. The display is 3024 × 1964 pixels, so a
  screen-sized request asks for 3024 px and the whole preview is decoded.
- **The tour's photo steps in the test host's main window**
  (`ImageMemoryTests.theTourPhotoStepsInTheWindow`): `ContentView` in a 1512 × 945 window at a
  backing scale of 2, eight generated 2160 × 1440 HEIC previews, each step waiting until the
  pane holds its photo and the window has drawn it, as the tour does. At each step the
  footprint, its peak sampled every millisecond, and `vmmap --summary` of the process.
- **A probe of decode forms** (a temporary test, not kept): four of those previews decoded,
  each set as a `CALayer`'s contents in a window and drawn, all four held, then let go.

## 1. Each photo shown was held three times over

Before (`ThumbnailStore.load`: decode, then draw into a bitmap context), the tour's steps:

| Step | Footprint | CG Raster Data | CoreAnimation | Malloc dirty |
| --- | --- | --- | --- | --- |
| Loupe opened | 219 MB | 11.9 MB | 12.1 MB | 120 MB |
| Next ×3 | 302 MB | 35.6 MB | 35.8 MB | 156 MB |
| Previous ×3 | 314 MB | 35.6 MB | 35.8 MB | 168 MB |
| Compare, then the grid | 314 MB | 35.6 MB | 35.8 MB | 168 MB |

- **CG Raster Data** is the three photos the loader holds, 11.9 MB each.
- **CoreAnimation** is a second full copy of each of them. A layer whose contents are a
  `CGImage` in ordinary memory is given a copy Core Animation can hand to the window
  server, and the copy is kept with the image for as long as the image lives, displayed or
  not.
- **Malloc** grew by 48 MB that nothing holds: the decode's scratch, freed into the heap,
  which on macOS 27 stays in the footprint
  (`2026-11-16-freed-memory-stays-in-the-footprint.md`).
- Leaving the view gave nothing back: the loader still held its three photos, each with its
  Core Animation copy.

## 2. The form a decode takes decides whether it is copied

Four previews held in layers, in the probe:

| Decode | Footprint added (4 held) | Left after release | CoreAnimation | Time (4) |
| --- | --- | --- | --- | --- |
| `ThumbnailStore.load` (before) | 131 MB | 36 MB | 47.5 MB | 751 ms |
| Uncached image drawn into a `MappedImage` | 310 MB | 101 MB | 47.5 MB | 624 ms |
| Thumbnail drawn into a `MappedImage` | 128 MB | 33 MB | 47.5 MB | 564 ms |
| Drawn into an `IOSurface` set as contents | 48 MB | 12 MB | 0 | 475 ms |
| `CGImageSourceCreateThumbnailAtIndex`, as returned | 60 MB | 15 MB | 0 | 444 ms |

- Image I/O's thumbnail decode returns its pixels in an IOSurface, and Core Animation
  displays an IOSurface-backed image as it is: no second copy, and no malloc scratch left.
  It is also the fastest.
- A `MappedImage` is mapped memory, but Core Animation copies it like any other `CGImage`:
  mapped pixels return when the image goes, they are not shown without a copy. Drawing an
  uncached image decodes it into malloc'd scratch, the worst of the forms.
- Compare drew its panes with SwiftUI's `Image`. After Compare was left, `leaks --traceTree`
  found a pane's image still referenced from SwiftUI's display-list view cache
  (`DisplayList.ViewUpdater.ViewCache`); the panes now show the decode as a layer's
  contents, as the loupe does, and let it go when taken down.

## 3. After: one copy a photo, and leaving gives them back

The same steps with the decode as Image I/O returns it, both Compare panes showing it as a
layer's contents, decodes nobody waits for cancelled, and the held photos let go on leaving
(`theTourPhotoStepsInTheWindow`, after one warm-up visit so the footprint compared against
has paid the first visit's one-time costs):

| Step | Footprint | IOSurface | CoreAnimation |
| --- | --- | --- | --- |
| Before the loupe opens | 115 MB | 2.5 MB | 0.2 MB |
| Loupe opened | 130 MB | 17.9 MB | 0.2 MB |
| Next ×3 | 175 MB | 47.9 MB | 0.2 MB |
| Previous ×3 | 160 MB (peak 175) | 47.9 MB | 0.2 MB |
| Compare | 163 MB | 50.4 MB | 0.2 MB |
| Back in the grid | 133 MB | 20.4 MB | 0.2 MB |

- A new photo now adds one decode, 15 MB in its IOSurface (2160 × 1440 at 4 bytes a pixel,
  with the surface's alignment), where it added the decode, a Core Animation copy and
  malloc scratch before: 24–36 MB a step.
- The walk peaks 60 MB above the footprint before it, the three held photos and the one
  shown or decoding; before, the same steps grew 95 MB from the loupe's first photo and
  kept all of it.
- Steps stay fast: from the step to the pane holding its photo, 65–74 ms for a photo
  decoded, 24–27 ms for one held, 126 ms for Compare's two decodes side by side (the
  probe's decode alone: about 110 ms for the thumbnail form, about 190 ms before).
- Leaving gives back all but about 18 MB: one IOSurface of a decode stays. No image Otos
  made holds it: `leaks --traceTree` found neither Compare image in the heap after
  leaving. What does hold it is not known; the test window is off screen, and whether the
  window server's last frame of it keeps the surface was not measured.

## Conclusion

- A screen-sized request decodes the stored preview with
  `CGImageSourceCreateThumbnailAtIndex` at the requested long edge and hands that image to
  the pane as it is: one copy of a shown photo's pixels, in a region that leaves the
  footprint when the image goes.
- Leaving the full-size view lets go of the photos the loader held for a return
  (`releaseHeldPhotos`).
- A decode whose every waiter has moved on is cancelled before it reads a byte, and a
  cancelled decode is never held.
