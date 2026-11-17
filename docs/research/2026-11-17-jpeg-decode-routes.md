# A JPEG original's decode, route by route (macOS 27, 2026-11-17)

## Question

A 12 MP JPEG decodes whole when a 2,560-pixel rendering is asked of it (4,032 is less than
twice 2,560), and Image I/O's thumbnail decode then peaked at about 110 MB for the length of
the decode, on either render lane: the costliest decode of a new library's first-launch tour
(`2026-11-17-full-size-view-on-originals.md`). What does each way of making that rendering
allocate, for a 12 MP and a 24 MP JPEG, and which should the one decode of an original take?

## Method

`OriginalPaneMemoryTests` (`OTOS_SCALE_TEST=1`, on demand, alone), the footprint sampled
every millisecond (`FootprintPeak`), each route three times on a fresh source after a warm-up,
generated 4,032 × 3,024 and 6,000 × 4,000 JPEGs (`FirstLaunchFootprintTests.writePhoto`):

- `aJPEGsRenderingAt2560ByRoute`: the routes that make their pixels when they return;
- `aJPEGsRenderingShownByRoute`: the routes whose pixels are filled only when a layer first
  shows them, each image set as a layer's contents in a 1512 × 945 window at a backing scale
  of 2 and committed, then measured through that showing.

## Results

Peak above the start, held once the transients are gone, time to the rendering (to the
committed layer for the second table), MB / ms:

| Route | 12 MP peak | 12 MP held | 12 MP ms | 24 MP peak | 24 MP held | 24 MP ms |
| --- | --- | --- | --- | --- | --- | --- |
| Thumbnail decode, cached at once, drawn into a surface | 109–111 | 18 | 84–88 | 59–61 | 17 | 62–97 |
| Thumbnail decode, lazy, drawn into a surface | 103–109 | 18 | 85–87 | 55–59 | 17 | 63–64 |
| Thumbnail decode, subsample factor | 107–110 | 18 | 85–89 | 60–62 | 17 | 63–64 |
| Whole decode drawn once, scaled, into a surface | 86–92 | 18–19 | 58–62 | 47–57 | 17 | 48–51 |
| Whole decode, lazy, drawn once into a surface | 87–89 | 19 | 60–62 | 56–57 | 16 | 48–50 |
| Whole decode as returned, before any showing | 0 | 0 | 0 | 0 | 0 | 0 |

| Shown in a layer | 12 MP peak | 12 MP held | 12 MP ms | 24 MP peak | 24 MP held | 24 MP ms |
| --- | --- | --- | --- | --- | --- | --- |
| Thumbnail decode drawn into a surface | 106–109 | 0–19 | 93–96 | 59–63 | 0 | 72–101 |
| Whole decode as returned | 36–37 | 18–19 | 17–19 | 73 | 19–36 | 30–32 |

- A whole decode as Image I/O returns it holds nothing until it is shown: its pixels are
  filled in the JPEG's own YCbCr layout (about 1.5 bytes a pixel) in an IOSurface by the
  first commit that shows it. Shown, a 12 MP JPEG costs a third of the thumbnail decode's
  peak and is on screen five times sooner; a 24 MP JPEG, which the thumbnail decode reads at
  half its size, costs more whole (73 MB) than by the thumbnail decode (59–63).
- The subsample factor changes nothing: a 12 MP JPEG has no half that covers 2,560, and a
  24 MP one is already decoded at half by the thumbnail decode.
- Drawing the whole decode once, scaled and upright, into an IOSurface peaks 20 MB lower
  than the thumbnail decode for a 12 MP JPEG and is 25 ms faster, and no worse for 24 MP.
- Caching at once or lazily changes nothing that matters.

## Decision (`OriginalRoute`, `DisplayImage.original`)

The one decode of a still's original that is not a RAW, on both lanes, takes the route its
format and size call for:

- a JPEG that Image I/O would decode whole for the asked edge anyway (a half of it falls
  short): for a pane, when it is upright and unedited, the whole image as Image I/O returns
  it (`wholeShown`, 36–37 MB, 17–19 ms); otherwise decoded whole and drawn once, upright and
  scaled, into an IOSurface (`wholeDrawn`, 86–92 MB, 58–62 ms);
- everything else: Image I/O's thumbnail decode, as before.

The lane cannot take `wholeShown`: it draws its rendering twice (the preview it encodes and
the grid thumbnail), and a whole image not yet filled would be decoded again for each draw.
`wholeShown` is a render of its own (`RenderKey.route`): the pane no longer joins the lane's
render of such a JPEG, as its own decode costs less than half of the lane's and is on screen
sooner than the lane's render would finish. The pane shows the 12 MP JPEG whole (4,032
pixels) rather than at the stored preview's 2,560, so its zoom never asks for a second
decode up to 100%.

The render lane's cost model charges what each route was measured to hold
(`DecodeCost.renderBytes(_:longEdge:route:)`): `wholeDrawn` the whole decode at four bytes a
pixel, the YCbCr image at a byte and a half, and the rendering (87 MB for a 12 MP JPEG), and
`wholeShown` three bytes a pixel (37 MB). Both lanes now render one 12 MP JPEG at a time
where they rendered two, each of which peaked at 110 MB beside the other.

## After

`OriginalPaneMemoryTests.thePhotoStepsOnANewLibraryNeverStackOnEnrichment`, three fresh
libraries in one process, peak above the footprint before each phase (MB):

| Phase | Before | After |
| --- | --- | --- |
| Photo steps alone | +166 | +101 |
| First enrichment alone | +428 | +324 |
| Photo steps with the first enrichment | +280 above 471 | +339 above 431 |

The 12 MP JPEG's step now takes 52 ms (it was the slowest of the four cameras); every step
took 30–261 ms. The on-demand bound on the steps alone is 120 MB (it was 200).

The seeded first-launch tours (`script/scorecard.sh --tour --dev --optimized --seed 28`,
`memory.peakFootprintMB`), with the tour's own fixes of the same change (its photo steps
issue the arrow key's intent and wait for the photo it names; its Duplicates step waits for
the groups the launch builds):

| Tour | Before (#903) | After |
| --- | --- | --- |
| Launch | 519 MB, 494 MB | 435 MB; Duplicates `groups=4` after 3,553 ms; photo steps 41–303 ms |
| Settled | — | 458 MB; settled `by launchWork` after 7,225 ms; Duplicates `groups=4`; photo steps 40–194 ms |

No step reached its deadline in either.

## Not done

- A turned (EXIF orientation other than 1) 12 MP JPEG is drawn upright in a pane
  (`wholeDrawn`, 86–92 MB): showing it whole would need the pane to turn its layer.
- A 24 MP JPEG keeps the thumbnail decode (59–63 MB): whole it costs more.

## Sources

- `OtosTests/OriginalPaneMemoryTests.swift` (`aJPEGsRenderingAt2560ByRoute`,
  `aJPEGsRenderingShownByRoute`), the lines in `build/measurements/image-memory.log` of
  that run (`op=paneMemory step=jpegRoute`, `step=jpegShown`).
- Apple, `CGImageSourceCreateImageAtIndex`, `CGImageSourceCreateThumbnailAtIndex`,
  `kCGImageSourceShouldCacheImmediately`, `kCGImageSourceSubsampleFactor` (Image I/O).
