# The full-size view on a new library's originals (macOS 27, 2026-11-17)

## Question

A new library's first-launch tour peaked at 864–930 MB (plan 0116's target: 700 MB), the
same launch with no tour at 472 MB, and the tour with enrichment off at 562 MB. The peak comes
during the tour's photo steps (open, next ×3, previous ×3, Compare), which on a new library
decode originals, as no stored preview exists yet, while the first enrichment renders the same
files on the background lane (`2026-11-17-first-launch-decodes.md`). An earlier pass measured
"about 200 MB a step" without attributing it. What does each step allocate?

## Method

- `OriginalPaneMemoryTests` (`OTOS_SCALE_TEST=1`, on demand, alone): `ContentView` in a
  1512 × 945 window at a backing scale of 2, 28 generated originals from a person's cameras
  in turn (48 MP and 12 MP HEIC, 24 MP and 12 MP JPEG, as
  `script/sandbox-library-media.swift`), no stored previews, the loader told the originals
  are local. The tour's photo steps, each waiting until the pane holds its photo, the
  footprint's peak sampled every millisecond from before the first step, `vmmap --summary`
  after each; on three fresh libraries in turn: the first enrichment alone (every photo's
  preview rendered and staged, as it asks), the steps beside it, and the steps alone. Each camera's original also decoded alone for the
  pane. The test process's own `op=preview.decode`, `op=loupe.fullRes`,
  `op=loupe.zoomReport` and `op=render.still` lines.
- The seeded first-launch tour (`script/scorecard.sh --tour --dev --optimized --seed 28`), a
  sandbox home on a volume of its own, its peak from the app's `op=process.memory` lines.

## 1. A zoom report taken on one photo asked for a whole decode of the next

The largest single cost was not the fit-size decode. At four of the seven steps the test
process logged `op=loupe.fullRes`, a full-resolution request, while the loupe was at fit:

    op=loupe.fullRes id=photo-2.jpg decoded=3024 native=6000 magnification=0.529762 fit=0.529762
    op=loupe.fullRes id=photo-0.heic decoded=3024 native=8064 magnification=0.529762 fit=0.529762

Two photos of different sizes reporting the same fit is the tell: 0.5298 is the fit of the
4:3 12 MP photo shown before them. The loupe keeps showing the photo it has until the next
one's decode lands, and the zoom view reports while it swaps one document for the next, so
a report measured on the previous photo was applied to the new one: 6000 × 0.53 = 3,178
pixels "shown", more than the 3,024-pixel decode, so a full decode was asked for. A 24 MP
JPEG decoded whole is 96 MB, a 48 MP HEIC 195 MB, at fit, at every step to one. The app's
own log on the seeded tour shows the same reports after the fix, now refused
(`op=loupe.zoomReport phase=otherPhoto focused=…-00005.heic measured=…-00027.jpg`).

**Fix.** A `LoupeZoomReport` names the photo it was measured on, and the window takes only a
report on the focused photo.

## 2. A fit-size decode of an original asked for more than the stored preview

The pane asked an original for the screen's long edge, 3,024 pixels. A JPEG decodes at the
smallest half of itself that covers the asked edge, so a 24 MP JPEG (6,000 px) asked for
3,024 decodes whole, 3,000 being short of it; asked for 2,560 it decodes at half. Each camera
decoded alone for the pane (peak above start):

| Original | Asked 3,024 | Asked 2,560 |
| --- | --- | --- |
| 48 MP HEIC | 33–52 MB | 19–38 MB |
| 12 MP HEIC | 4–15 MB | 15–19 MB |
| 24 MP JPEG | **185 MB** | 50–63 MB |
| 12 MP JPEG | 96–119 MB | 108–112 MB |

A settled library shows every still at fit from its stored preview, 2,560 pixels, and asks
for full resolution only when the zoom shows more (APP-040). **Fix.** A still short of full
resolution is decoded at the stored preview's size from its original too: the same photo at
fit whether its preview is stored yet or not. A 12 MP JPEG still decodes whole either way
(4,032 is less than twice 2,560): it is the costliest pane decode, and the one the shared
budget below has to hold.

## 3. A JPEG's scaled decode was held twice

`vmmap` after each step: a HEIC step grew the `IOSurface` region by one decode; a JPEG step
grew `CoreAnimation` by 16.8 MB, a second full copy. Image I/O returns a HEIC's scaled decode
in an IOSurface, shown as it is, and a JPEG's in ordinary memory, which Core Animation copies
for display and keeps with the image (`2026-11-16-full-size-view-memory.md`). **Fix.** A
rendering of an original that is not an unedited HEIC is drawn once into an IOSurface of its
own (`DisplayImage.shown`) before the pane shows it.

## 4. The pane and the lane decoded the same photo, beside each other

The pane's decode of an original ran on its own path, outside the background lane's budget,
so on a new library a step's decode stacked on four enrichment renders, and the photo on
screen was often the one the lane was rendering at that moment, decoded twice.

**Fix** (`ImageRenderer`, `DecodeBudgetMachine`):

- The pane's still decodes go through the renderer's interactive lane, and both lanes' Image
  I/O decodes pass one budget. A decode the user waits on is granted at once and nothing of
  enrichment's starts while it runs, `LoadAdmission`'s rule; enrichment's run in order while
  they fit.
- An ask for a render already asked for on either lane joins it: one decode, each ask's
  `finish` run with the same pixels on the lane inside its admission. The user joining a
  background render still waiting for its turn makes it the user's. On the seeded tour the
  loupe's first photo joined the render enrichment had started
  (`op=render.still phase=joined lane=interactive`).
- A cancelled ask leaves at once; a render every ask left before it began is withdrawn
  before it reads a byte.

## After

The hosted test, one process, three fresh libraries in turn (peak above the footprint before
each, MB):

| Phase | Before (step peak, worst step) | After |
| --- | --- | --- |
| Photo steps alone | +306 (whole decodes at fit, asked by a report from the previous photo) | +166 (a 12 MP JPEG's whole decode at 2,560 over three held photos) |
| First enrichment alone | — | +428 |
| Photo steps with the first enrichment | +497 | +280 above a footprint the enrichment phase left at 471 |

Steps stayed fast: from the step to the pane holding its photo, 90–170 ms for an original
decoded, 18–36 ms for a photo held, 240–250 ms for Compare's two.

The seeded first-launch tour (`script/scorecard.sh --tour --dev --optimized --seed 28`,
`memory.peakFootprintMB`):

| | Peak footprint |
| --- | --- |
| Before (reported for #899) | 864–930 MB |
| After, two runs | 519 MB, 494 MB |

Every photo step reported (52–294 ms), each on an original (`local=4 storedPreview=0`).
A first run had one step reach its deadline: the tour read its next photo from the order,
awaited an openability read, and then stepped with `focusNext`, by which time enrichment had
moved the order and the loupe stayed put. That is the tour's own race with a moving order, not
the pane's; its photo steps after the deadline came from stored previews.

The always-run twins: `DecodeBudgetMachineTests` (the user's decode at once, enrichment's
waiting for it, a promoted render, the budget never exceeded),
`RenderSharingTests` (the pane handed the render enrichment asked for, the same pixels; an ask
cancelled before its render begins leaves without a byte read),
`CatalogWindowViewModelLoupeZoomTests.aReportMeasuredOnAnotherPhotoIsNotTaken`, and
`PreviewImageLoaderSizeTests.anOriginalIsDecodedAtTheStoredPreviewsSizeShortOfFullResolution`.
The on-demand bound: `OriginalPaneMemoryTests.thePhotoStepsOnANewLibraryNeverStackOnEnrichment`
— the steps alone add at most 200 MB (three held photos and the next one's decode, a 12 MP
JPEG decoding whole), and beside the first enrichment no more than the enrichment alone plus
that.

Not changed here: a 12 MP JPEG still decoded whole at 2,560 (about 110 MB for the length of
the decode, on either lane). Measured and changed since, route by route, in
`2026-11-17-jpeg-decode-routes.md`.

## Rejected

- Decoding at the screen's long edge with a JPEG's half-size decode accepted when it falls
  just short (3,000 for 3,024): a rule about one format's scaling written into the pane, and
  still twice the pixels a settled library shows at fit.
- Giving the interactive lane a reserve inside the budget instead of granting the user at
  once: the photo on screen would wait behind enrichment's renders, 300–1,450 ms each.
- A cache of the lane's recent renderings for the pane to take after the fact: memory held
  for a return that the stored preview, written moments later, already serves.
