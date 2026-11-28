# A new library's first launch: what its peak footprint holds (2026-11-17)

## Question

A sandbox dev build's first launch of a 28-photo library peaked at 889 MB (plan 0116's
target: 700 MB); its second launch at 534 MB, and a first launch of 2,000 smaller photos at
419 MB. A cold compile of the search text model adds at most 87 MB
(`2026-11-16-first-launch-footprint.md`). What is the rest, and what of it is Otos's?

## Method

Generated sandbox libraries only (`script/sandbox-library.sh`, its home on a volume of its
own); the reference library was not used. The optimized dev build (`--optimized`, the
installed app's compiler settings), launched with `OTOS_SANDBOX_LIBRARY` so its first launch
registers the library through the window's Add Library intent and enriches it at once.
`script/survey.sh --launch` around each first launch (footprint, kernel lifetime maximum,
vmmap by region), and the app's own `op=process.memory`, `op=render.still`,
`op=load.admission`, `op=face.model` and `op=search.*` lines.

## Measured

| First launch (no tour) | Photos | Peak footprint (lifetime max) | Footprint at +15 s |
| --- | --- | --- | --- |
| 1600 × 1200 JPEGs | 28 | 281 MB | 140 MB |
| A person's cameras: 48 MP and 12 MP HEIC, 24 MP and 12 MP JPEG | 28 | 625 MB | 179 MB |

With a tour on top, the small photos' first launches peaked at 361 to 582 MB, the peak during
the first photo's loupe; the earlier 889 MB library was 28 wallpapers of about 36 MP, large
originals like the second row.

The second row's timeline (app lines, one session):

- The first grid at +0.7 s: footprint 55 MB. The heavy loads (duplicates, People) ran and
  released at 55 to 56 MB.
- +1.0 s: footprint 305 MB, as enrichment's first still renders started on the background
  lane (four Image I/O decodes at once, `ImageRenderer.background`), each of a 24 or 48 MP
  original to a 2560-pixel preview, 300 to 1,450 ms each.
- AdaFace loaded at +1.6 s (705 ms).
- Footprint 296 to 442 MB while the 28 renders ran, kernel peak 624 MB by +6.2 s; back to
  201 MB at +7.3 s, the moment the last render finished.
- The models came later and one at a time: the search text tower at +22 s (1 MB of footprint
  added), the image tower when the first thumbnails were embedded. Vision's text reading runs
  in its own process (`Otos --read-text`, 36 to 65 MB). Descriptions run in the system's model
  process.

So the peak is the first enrichment's still renders (four decodes at once on the background
lane) and the preview encodes staged beside them, not the models: the models' weights are
mapped (clean, not footprint), each loaded alone, and the text tower loaded with no render
beside it.

In a test process (`FirstLaunchFootprintTests`, on demand), one still rendered alone to its
2,560-pixel preview peaked at: 48 MP HEIC 0 to 19 MB, 12 MP HEIC 15 MB, 24 MP JPEG 50 MB,
12 MP JPEG 104 to 112 MB. The 12 MP JPEG costs most because Image I/O decodes a JPEG at the
smallest half that covers the asked edge, and 4,032 is less than twice 2,560: it decodes
whole. A first budget counted a decode by its original's full pixels; it left the 28-still
render test where it was (220 → 240 MB), because that count was not what a decode holds.

28 stills made as enrichment makes them (rendered, then the HEIC preview and JPEG thumbnail
encoded and staged) peaked 551 MB above where they started: the staging encodes ran on the
callers, beside one another and beside the lane, with each rendering held until its encode
finished.

## Change

- The background lane admits a render by what it holds (`DecodeBudget`): the pixels its
  format decodes at for the asked edge (a JPEG at the smallest covering half, a HEIC at the
  asked size, anything else whole) and the rendering it makes, four bytes each, in the order
  asked so none is passed over. Its budget is four HEIC previews: three 24 MP JPEG previews,
  two of a 12 MP JPEG.
- A still's preview and thumbnail are encoded and staged on the lane, inside the render's
  admission (`ImageRenderer.render(_:longEdge:recipe:finish:)`): the encodes are bounded with
  the decodes, and no actor runs them (ADR 0032 rule 6).

## After

| Measure | Before | After |
| --- | --- | --- |
| 28 stills rendered and staged at once (test process, peak above start) | 551 MB | 284 MB |
| First launch, a person's cameras, 28 photos, no tour (survey, lifetime max) | 625 MB | 472 MB |
| The same with a launch tour (scorecard `memory.peakFootprintMB`) | 864 MB | 930 MB |

The tour's peak did not move, and it is not the lane's. It comes during the tour's photo
steps, while the first enrichment runs: each step to a 24 or 48 MP original that has no
stored preview yet decodes it at the screen's long edge (3,024) on the interactive lane, and
the footprint rose about 200 MB at each, from 380 to 765 MB over six steps, then fell to 318
MB at Compare. With enrichment left unstarted (`--ablate enrichment`) the same tour peaked at
562 MB during the same steps. So the rest is the loupe decoding large originals while
enrichment works beside it; neither alone exceeds 700 MB. Not changed here: attributing the
loupe step's 200 MB inside the process needs an allocation trace from the launch's first
seconds, which an attached recorder misses (it attaches after the peak).

## Rejected

- Fewer decodes on the lane for every photo (two instead of four): halves the throughput of a
  HEIC, an iPhone library's common photo, which holds 15 to 19 MB, to bound a cost only whole
  JPEG decodes have; four at once measured 2.5× the throughput of one (2026-10-31-raw9-speed).
- Loading the heavy models one at a time, or releasing each before the next: they already
  load apart and their weights are mapped; the peak did not move with them.
- A guard on the count of models resident at once: it would guard what was not the cause.
  The always-run twin guards the decode budget instead (`DecodeBudgetMachineTests`).
