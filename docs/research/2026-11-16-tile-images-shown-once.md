# Grid and face tiles shown once (macOS 27, 2026-11-16)

## Question

`2026-11-16-full-size-view-memory.md` found that Core Animation copies any `CGImage` a layer
shows unless its pixels are an IOSurface, and keeps the copy with the image. It moved the
full-size view to Image I/O's IOSurface decode; the grid's thumbnails (`ThumbnailStore.load`:
decode, then draw into a bitmap context) and the face tiles (drawn into a `MappedImage`) kept
the old forms. The owner's app at rest after a tour, by `footprint` category: CoreAnimation
62 MB in 254 regions, CG Raster Data 55 MB in 468, IOSurface 12 MB. What holds each, and what
does each tile cost in the form it is shown?

## Method

- **A probe in the test host** (a temporary test, not kept): a 1512 × 945 window at a backing
  scale of 2, 300 layers each showing one image, `vmmap --summary` of the process before, once
  shown and flushed, and after the layers and images are let go. Inputs: 300 generated 256 px
  JPEG thumbnails (the stored shape, `ThumbnailStore.maxPixelSize`), and 256 px face cuts from
  generated 2560 × 1920 HEIC previews. The SwiftUI cases show the images as
  `Image(decorative:)` in a `LazyVGrid`.
- **The window, as the tour uses it** (`ImageMemoryTests`, `OTOS_SCALE_TEST=1`, alone):
  - `theGridHoldsEachThumbnailOnce`: `ContentView` in a 1512 × 945 window at a backing scale
    of 2 over a generated catalog of the owner's shape (scale 0.02), its first 1,300 stored
    thumbnails written as 256 px JPEGs; All Media's first screenful, then three scroll steps of
    300 tiles, each waiting until every visible tile shows its thumbnail
    (`op=ui.mediaGrid.visibleThumbnails`'s report).
  - `thePeopleGalleryHoldsOnlyItsTiles`: the gallery's first 24 tiles in a 1200 × 800 window.
  - `theTourPhotoStepsInTheWindow`: the loupe and Compare steps of the tour.
  - Each ran before and after the change on the same machine, under the usual parallel load.
- **The owner's library was not measured.** The brief for this work forbids launching the
  installed app, so the at-rest numbers above are the owner's own, from before.

## 1. Which form is copied

300 thumbnails in layers:

| Thumbnail decoded by | CG Raster Data | CoreAnimation | IOSurface | Footprint added |
| --- | --- | --- | --- | --- |
| `ThumbnailStore.load` (before: decode, then draw into a bitmap context) | 60.9 MB | 56.2 MB | 0 | 118 MB |
| `CGImageSourceCreateThumbnailAtIndex` at 256 px | 60.9 MB | 56.2 MB | 0 | 117 MB |
| `CGImageSourceCreateImageAtIndex`, as returned (after) | 0 | 0 | 23.4 MB | 29 MB |

- Image I/O's whole decode of a JPEG is an IOSurface in the decoder's own YCbCr layout, about
  80 KB for a 256 × 192 thumbnail where the drawn form is 196 KB, and Core Animation shows it
  without a copy.
- Image I/O's *thumbnail* decode of the same small JPEG is not an IOSurface: it is copied like
  the drawn form. For a 2560 px HEIC it is one (the full-size view's form), so the codec, not
  the call, decides. Scaling a 256 px thumbnail down for a smaller tile costs more than
  holding the whole decode.

300 face cuts of 256 px:

| Cut drawn into | CoreAnimation | IOSurface |
| --- | --- | --- |
| a `MappedImage` (before), in layers | 75.0 MB | 0 |
| a `MappedImage`, through SwiftUI's `Image` | 70.0 MB | 0 |
| an IOSurface-backed pixel buffer, made a `CGImage` by `VTCreateCGImageFromCVPixelBuffer` (after), in layers | 0 | 77.5 MB |
| the same, through SwiftUI's `Image` | 0 | 77.5 MB |

A cut Otos draws itself needs pixels of its own; drawn into an IOSurface they are the only
copy, through a layer or SwiftUI alike, and they leave the footprint when the image goes.

Ten 2560 × 1920 HEIC previews: the whole decode holds 101 MB in IOSurfaces (YCbCr), the
thumbnail decode at the screen's 3024 px 203 MB (BGRA). A preview no larger than the request
is now decoded whole.

## 2. When the pixels are made

Neither form fills its pixels when decoded. After 300 decodes and before any is shown the
footprint grew 6 MB in both (the JPEGs' own bytes); the pixels are made when Core Animation
first shows the image, in the window's commit. The commit that first showed the 300 layers
took 1,024 ms with the drawn form and 1,033 ms with the whole decode. So moving to the whole
decode moves no decode onto the main thread that was not there before; it takes away the
second draw and the copy.

## 3. The grid in the window

Tiles at 6 columns are 387 × 387 pixels; the stored thumbnail is 256 px on its long edge, so a
tile always shows it at its stored size or larger, and it is decoded at its stored size.

| Step | Before: added / CG Raster / CoreAnimation | After: added / IOSurface / CoreAnimation | Visible thumbnails, before → after |
| --- | --- | --- | --- |
| Screenful (27 tiles, 75 held) | 18 MB / 9.3 MB / 5.9 MB | 8 MB / 2.5 MB / 0.9 MB | 56 → 37 ms |
| Scrolled 300 | 20 MB / 15.7 MB / 6.5 MB | 17 MB / 2.7 MB / 0.9 MB | 42 → 13–24 ms |
| Scrolled 900 (489 held) | 28 MB / 20.4 MB / 6.2 MB | 28 MB / 7.4 MB / 0.5 MB | 39 → 12–13 ms |

- Every scroll step showed every visible tile with its thumbnail, before and after
  (`withoutThumbnail=0`).
- Each shown tile's layer shows the very image the tile store holds.
- Before, each image shown filled 196 KB of CG Raster Data, kept while the store held it, and
  each tile on screen had a 196 KB Core Animation copy. After, an image shown holds one
  80 KB IOSurface and nothing else.
- After 900 tiles both forms add 28 MB. The 489 images the store holds, most never shown,
  keep their JPEG bytes (about 40 KB each) in the malloc heap until shown; before, the same
  images were lazily drawn and held about as much. What the grid holds past the viewport is
  the tile store's budget (256 MB at each image's nominal 4 bytes a pixel), not the decode's
  form, and is left as it is.
- The empty window holds 0.2 MB of CoreAnimation and the screenful 0.5–0.9 MB: the window's
  own layers (sidebar, toolbar symbols, badges, headers), not thumbnails.

## 4. The People gallery and the photo steps

| | Before | After |
| --- | --- | --- |
| Gallery: footprint added for 24 tiles | 52 MB | 44 MB, and 21 MB in a second run |
| Gallery: CoreAnimation | 9.8 MB | 2.6 MB |
| Photo steps: peak added / left after the grid | 60 / 18 MB | 19–20 / 7–8 MB |

- The gallery's remaining 2.6 MB of CoreAnimation is SwiftUI's own layers for the cells' text
  and backgrounds, not tiles.
- The gallery exceeded its 64 MB bound by 1–12 MB on a loaded machine before. With the tiles'
  display copies gone it measured 21–44 MB, so the bound stays 64 MB; what the rest of the
  earlier excess was (the decodes' transients under load is the likely part) was not
  separated.
- A stored preview decoded whole is 6 MB where the thumbnail form was 15 MB, so the photo steps'
  peak fell by two thirds.

## Not measured

- The Places map, the Info pane's face tiles, On This Day and Duplicates in the window. All
  decode thumbnails through `ThumbnailStore.load` and face tiles through `FaceCrop`, so they
  take the same form, but their own holders were not measured.
- The owner's library at rest and its session peak (`script/scorecard.sh --tour`), because the
  installed app is not launched for this work.

## Conclusion

- One decode path makes every image a layer shows (`DisplayImage`): a stored file is decoded
  whole by Image I/O when it is no larger than shown, else scaled by its thumbnail decode; a
  cut Otos draws itself is drawn into an IOSurface of its own. Each is held once, shown
  without a copy, and leaves the footprint when let go.
- `MappedImage` had one use, the face tiles, and is deleted.
