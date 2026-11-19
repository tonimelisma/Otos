# Display images drawn before they are shown (macOS 27, 2026-11-18)

## Question

The owner: "scrolling has become incredibly janky. like a stop motion movie", "even small
libraries like a 109 asset import". What does the main thread do while the grid scrolls, and
what form must an image have so that showing it costs the main thread nothing?

## Evidence from the owner's app

The installed app's unified log over a minute of his scrolling in All Media (142,197 items),
read-only (`script/logs.sh capture --last 5m --pid <pid>`):

- 17 `op=mainThreadStall` lines of 100–217 ms in 25 s of scrolling, every one bracketed by
  `MediaGridViewController.reconfigureVisibleItems`, `scrollHold=true`.
- The grid's own work in each was 0 ms (`op=ui.mediaGrid.reconfigure reconfigureMs=0
  renderMs=0`); 29–69 tiles visible; every visible tile already had its thumbnail
  (`withoutThumbnail=0`), so nothing waited on the catalog or a decode lane.
- The heaviest stack of each stall is Core Animation's commit decoding a JPEG:
  `CA::Layer::prepare_commit → CA::Render::prepare_image → CA::Render::copy_image →
  IIOImageProviderInfo::CopyIOSurface → JPEGDecompressSurface → IOConnectCallStructMethod`
  (`CMPhotoDecompressionContainerCreateImageForIndex`).

The grid's thumbnails were Image I/O's whole decode of each stored 256 px JPEG, as
`CGImageSourceCreateImageAtIndex` returns it (`2026-11-16-tile-images-shown-once.md`). That
image is an IOSurface whose pixels the JPEG decoder writes only when a layer first shows it,
on the thread that commits the layer tree: the main thread. Preheating decoded nothing: it
made image objects whose pixels did not exist yet.

## Probe

A standalone Swift program (built `-O`), one window, 60 generated 256 × 192 JPEG
thumbnails, each form made on a background queue, then 60 layers given the images in one
transaction, timing `CATransaction.commit()` + `flush()` on the main thread. Two rounds each.

| Form | Made off main (60) | Main-thread commit that first shows 60 |
| --- | --- | --- |
| Image I/O's whole decode, as returned (the old form) | 17–42 ms | 182–215 ms |
| Drawn into an IOSurface-backed BGRA `CVPixelBuffer`, made a `CGImage` by `VTCreateCGImageFromCVPixelBuffer` | 44–65 ms | 1.3–1.4 ms |
| Drawn to BGRA, converted to a 4:2:0 YCbCr surface by `VTPixelTransferSession` | 131–193 ms | 0.9 ms |

- The old form costs 3.0–3.6 ms of main-thread time a tile the first time it is shown: a new
  row of 8–10 tiles is 30 ms, two frames at 60 Hz, four at 120 Hz. That is the stutter, and it
  does not depend on the library's size.
- The `2026-11-16` note measured the old form's commit as no slower than the form before it
  (a bitmap context's image, which Core Animation copies). Both were paying the main thread
  per tile; the note concluded nothing moved onto it, which was true and not enough.
- A drawn surface's pixels are filled when it is made; Core Animation shows it as it is.
- Keeping YCbCr (1.5 bytes a pixel against 4) needs the BGRA draw anyway and a second
  conversion; it is three times slower off main for a saving no measurement asks for.

## Memory

A drawn 256 × 192 thumbnail holds 196 KB where the lazily filled form held 80 KB once shown
(and its 40 KB of JPEG before). The grid's tile store already counts each image at 4 bytes a
pixel against its 256 MB budget (`TileContentStore.byteCost`), so what it may hold is
unchanged; what it does hold now matches what it counts. A 2,560 px loupe preview holds
19.7 MB drawn, about 7 MB in the old form; the loader holds three. A 12 MP JPEG shown whole at
full size is drawn (`OriginalRoute.wholeDrawn`, 86–92 MB at its peak) where the removed
`wholeShown` route peaked at 36–37 MB through its first showing — and decoded it on the main
thread, 12 MP at a time.

Not measured here: the owner's library at rest and its session peak; the weekly tour
(`script/perf.sh run`) measures them against the 800 MB target.

## Conclusion

- A layer is handed only a `DisplayImage`, whose one constructor draws the pixels into an
  IOSurface of its own off the main actor (ADR 0016). The old form cannot be expressed.
- `OriginalRoute.wholeShown` is removed: a pane and the lane ask for the same render.
- Every PR's check proves the pixels are in the surface when the image is made
  (`DisplayImageTests`, APP-091); the weekly tour measures scrolling's frame hitches.
