# Editing foundation: decisions, RAW9, edited display and the first edits

Date: 2026-10-24. Research for non-destructive photo editing in Otos. No code or
behavior changed. Companion research the same day:

- `2026-10-24-macos-image-and-video-editing-apis.md` — what macOS provides.
- `2026-10-24-edited-photo-handoff-and-export.md` — copy, drag, Share, Open With, export.
- `2026-10-24-asset-identity-and-out-of-app-moves.md` — whether to move to checksums.

Labels: **[V]** checked against the cited source, header or repo file; **[M]** measured
on the development Mac; **[R]** community report; **[I]** inference.

## Owner decisions captured

1. **One current edit per photo**, as in Apple Photos. No virtual copies, no saved
   versions.
2. **Edits live in the catalog.** No sidecars, no catalog export.
3. **Originals are never modified.** An edit is a recipe overlay rendered from the
   original.
4. **An edit sidebar on the right**, built piece by piece.
5. **The first controls are what the platform provides**, starting with RAW9. Masks,
   looks and learned models are not in scope.
6. **An unedited RAW is shown with RAW9 defaults.**
7. **Grid, loupe and thumbnails always show the edited photo**, and a thumbnail updates
   after an edit.
8. **The edited version is what leaves Otos** on copy, paste, Share and drag; several
   selected photos copy and paste as several. **Export is allowed**, including of
   several photos (companion research).

These become an ADR, requirement rows and CLAUDE.md changes (the list of ways the
user's files change gains export) in the increments that build them.

## How Photos and Lightroom store an edit

| Product | Edit storage | Alternatives | Rendered result |
| --- | --- | --- | --- |
| Apple Photos | One `PHAdjustmentData` per asset — the most recent edit, with a format identifier and version [V, [Apple](https://developer.apple.com/documentation/photos/phadjustmentdata)] | Duplicate makes a real second asset | An editor must hand Photos a full-size rendered JPEG with the adjustment data [V, [PHContentEditingOutput](https://developer.apple.com/documentation/photos/phcontenteditingoutput/renderedcontenturl)]; the `.fullSizePhoto` resource is the modified photo [V, [Apple](https://developer.apple.com/documentation/photos/phassetresourcetype/fullsizephoto)] |
| Lightroom Classic | Develop settings in the catalog, history steps, snapshots; XMP sidecars optional | Virtual copies (extra catalog rows on one file) | Rendered previews cache (below) |
| Lightroom desktop | Edit settings synced to the cloud | Versions: named states of one photo, not separate thumbnails [R, [Life After Photoshop](https://www.lifeafterphotoshop.com/lightroom-versions-and-how-they-work), [Adobe community](https://community.adobe.com/t5/lightroom-ecosystem-cloud-based-discussions/is-quot-virtual-copy-quot-feature-available-in-lightroom-cc-6-3-1/m-p/13789221)] | Cache of originals and Smart Previews [R, [Adobe](https://helpx.adobe.com/lightroom/desktop/introduction/preferences.html)] |

Otos's model is Photos' first column: one recipe per photo, in the catalog.

## NeuralImageKit: what to reuse

`~/Development/NeuralImageKit` is a RAW9-to-vivid-HEIF experiment; no neural look is
accepted. Its product-first research
(`docs/research/2026-10-04-product-first-photo-processing-architecture.md` there)
surveys Lightroom-style editing and recommends a standalone development package.

| Reuse (as knowledge, rewritten for Otos) | Why |
| --- | --- |
| RAW9 opening sequence in `native/Development/RAWDevelopment.swift`: byte-backed `CIRAWFilter(imageData:identifierHint:)`, explicit `.version9`, resource download | A byte-backed decode makes the dataless check precede the only read; without a type hint the filter reported no decoder [V, NIK `docs/research/2026-10-04-native-foundation-probes.md`] |
| Its control receipt (every `is…Supported` flag and effective value) | Which sliders exist for a photo |
| Its post-write inspection of an encoded file (`native/Output/HEIFOutput.swift`) | Pattern for verifying export output |

| Do not reuse | Why |
| --- | --- |
| `native/SourceAccess/Publication.swift` (hard-link publish) | Otos's `ExclusivePublication` (`renamex_np(RENAME_EXCL)` after a volume probe) is stronger |
| `native/SourceAccess/GuardedFile.swift` | A second owner beside `FileMaterialization` |
| `FloatFrame` `[Float]` buffers | 384 MB per 24 MP frame; editing stays in lazy `CIImage` graphs |
| The resource wait (0.25 s semaphore poll inside a 30 s timeout) | Time standing in for a reported fact (ADR 0033) |
| ILCE-6700 / `.arw` / mandatory-lens gates, diagnostics, Python training | Experiment gates, not product policy |

## What RAW9 provides

Measured on two Sony ILCE-6700 ARWs (6192×4128) from the library, with a scratch probe
reading local, non-dataless files only [M, macOS 27.0, Xcode 27]. The installed catalog
holds 5,937 ARW files; every RAW in it is from the ILCE-6700 [M, catalog query].

- **RAW9 is opt-in.** A new filter defaults to decoder 8; supported versions were
  7, 8, 9 [M]. 69 of 939 supported camera models support RAW9
  (`CIRAWFilter.supportedCameraModels(with: .version9)`) [M]. A camera without RAW9
  decodes with RAW8 through the same filter
  (`2026-10-25-raw-decoders-thumbnails-and-full-size-renders.md`).
- **`downloadResources(timeout:completionHandler:)`** (new in 27) returned in 8–89 ms
  with resources already present [M].
- **Embedded preview:** 1616×1080 on both files [M].

Controls under RAW9 compared with RAW8 on the same file (defaults vary per photo) [M]:

| Control | RAW9 | RAW8 |
| --- | --- | --- |
| Exposure (EV offset) | yes, 0 | yes |
| Baseline exposure, shadow bias | 0.4, 3.0 | same |
| Boost (global tone curve), boost shadow | 1.0, 0.9 | same |
| Highlight recovery | supported, on | supported, on |
| Gamut mapping | on | on |
| Lens correction | supported, on | supported, on |
| Luminance noise reduction | supported, 0.01 | supported, 0.43 |
| Colour noise reduction | **not supported** | supported, 0.5 |
| Sharpness | supported, 1.0 | supported, 1.0 |
| Contrast | supported, 0 | supported, 0 |
| Detail | **not supported** | supported, 0.5 |
| Moiré reduction | **not supported** | supported, 0.55 |
| Despeckle, local tone map | not supported | not supported |
| Extended dynamic range | 0 (SDR) | 0 |
| White balance | as-shot 5847 K / tint 13.7 (also chromaticity and a pick location) | same |

The header documents temperature 2,000–50,000 K and tint −150…150, and
`neutralLocation` as a pixel to make neutral (`CIRAWFilter.h:186-195`) [V]. Apple says
RAW9's demosaic and denoise is a tiled Core ML model that is "more performance and
resource intensive than prior versions" and that intermediate caching keeps later
property changes fast [V, [WWDC26 305](https://developer.apple.com/videos/play/wwdc2026/305/)].

Render timings, one process per measurement so no cache crosses measurements, rendering
every pixel into a bitmap [M]:

| Output long edge | RAW9 first render | RAW9 after a property change | RAW8 first | RAW8 after a change |
| --- | --- | --- | --- | --- |
| 1024–2900 px (scale ≤ 0.5) | 1.0–1.9 s (render + HEIC encode) | 20–50 ms | 0.3–1.3 s | 2–30 ms |
| 5120 px | 2.5–2.7 s | 45–160 ms | 0.7–1.6 s | 14–50 ms |
| 6192 px (full) | 2.9–3.2 s | 55–180 ms | 0.6–1.5 s | 0.7–1.9 s |

The first property change after the first render took 0.6–1.4 s more at small scales
[M]. Draft mode was not reliably faster under RAW9 [M]. Peak resident memory per
process was 160–340 MB [M].

**RAW9 quirk [M]:** at a scale factor below 0.5, reading `outputImage` a second time
without changing any property returned an image at half the requested size (256→128 px,
2560→1280 px); changing any property restored it. RAW8 did not do this. A renderer must
read `outputImage` once per configured state.

## How Otos displays photos today

- **Grid thumbnails** are 256 px JPEGs from `QLThumbnailGenerator`
  (`Otos/Services/MediaEnricher.swift:381`, `ThumbnailStore.maxPixelSize = 256`) [V];
  for an ARW Quick Look builds it from the camera's embedded JPEG, not from RAW data
  [M, `2026-10-25-raw-decoders-thumbnails-and-full-size-renders.md`].
- **Loupe** uses the embedded preview whenever it is at least `min(target, 1024)` px
  (`Otos/Services/PreviewImageLoader.swift:250`) [V]. For these ARWs it shows the
  1616×1080 camera preview scaled to the window [I, from the measured preview size].

Decision 6 therefore changes every RAW's thumbnail and loupe image, not only edited
ones: all 5,937 ARWs move from the camera's look to RAW9's.

## Showing the edited photo everywhere: what to keep

How others do it [companion agent research, sources inline]:

- **Photos** keeps a full-size render per edited photo, because PhotoKit hands every
  edit over as a baked JPEG, plus smaller derivatives [V, Apple links above; R,
  [photos forensics](https://github.com/muxcmux/apple-photos-forensics)].
- **Lightroom Classic** keeps Standard previews sized to the screen (rendered from the
  edit, used everywhere except Develop), optional 1:1 previews it can discard, and Smart
  Previews (2,560 px partially processed RAW) for editing offline originals; Develop
  always renders from the RAW [R, [Lightroom Queen](https://www.lightroomqueen.com/lightroom-performance-previews-caches/),
  [Adobe](https://helpx.adobe.com/lightroom-classic/desktop/viewing-photos/lightroom-smart-previews.html)].
- **Capture One** keeps a display-sized preview and renders 100% zoom from the RAW [R,
  [Capture One](https://support.captureone.com/hc/en-us/articles/360002484457)].

Encoded size of a RAW9 render, Display P3, two files [M]:

| Long edge | HEIC | JPEG |
| --- | --- | --- |
| 3096 px | 0.43–2.1 MB | 1.1–3.5 MB |
| 5120 px | 0.71–3.7 MB | 1.7–6.2 MB |

Options:

| | Keep | First view of an edited or RAW photo | Storage for 5,937 ARWs |
| --- | --- | --- | --- |
| a | Nothing; render on demand | 1–3.2 s from a local original [M]; a dataless original downloads first (~50 s for one RAW, measured 2026-07-09, `docs/product/roadmap.md`) | 0 |
| b | **256 px thumbnail + one display-size render** per rendered photo | Immediate, also offline | ~2.5–12 GB at 3096 px, ~4–22 GB at 5120 px [I, scaled from two files] |
| c | Full-size render | Immediate | 1.0–5.2 MB per photo, ~6–31 GB more [M, follow-up research]; no consumer needs it: display never exceeds screen size, and 100% zoom (0.2–0.8 s for the visible area), export and hand-off render from the original |
| d | In-memory caches only | Lost on relaunch | 0 |

**Finding:** keep the 256 px thumbnail (option b's first half is required in every
option — the grid cannot decode RAW9 per tile) and a display-size render (b), not a
full-size one. The measurement is what justifies it: a first RAW9 render is 10–30× the
100 ms responsiveness budget, before any download. Both are derived overlay under the
one overlay lifecycle (ADR 0008, ADR 0009: kept, never evicted), and both are
re-rendered when an edit is committed; a newer thumbnail of the same asset replacing the
painted one is what APP-015 allows. Their staleness key extends today's `(size, mtime)`
signature with the recipe revision and the decoder identity (decoder version and OS
build), because Apple's RAW9 resources can change under an unchanged file. While the
sidebar is open, the editor renders live from the original with one `CIContext` per
view and `cacheIntermediates` on (Apple's guidance, measured 20–180 ms per change after
the first render), at display scale during a drag.

Owner decisions this leaves:

- **Display render size**: a fixed long edge (3096 or 5120 px measured above) or the
  main display's backing size.
- **Which photos get one**: every RAW (since all RAWs now render through RAW9) plus
  every edited photo, or only photos once edited or viewed.

## Order of the first edits

Each step is one shippable increment on top of the previous. The first step builds the
pipeline every later control reuses: the recipe table, the render owner, the right
sidebar, edited thumbnail and display render, undo and redo, reset. Each control is one
recipe value with two implementations — `CIRAWFilter` for RAW, a Core Image filter for
HEIC/HEIF/JPEG — and appears only when the photo supports it.

| # | Edit | RAW (RAW9) | Other images | Why here |
| --- | --- | --- | --- | --- |
| 0 | RAW shown with RAW9 defaults (no control) | `CIRAWFilter` defaults | — | Decision 6; every edit's "before" image; brings the thumbnail and display render |
| 1 | Exposure | `exposure` | `CIExposureAdjust` | One value, every format; proves the whole pipeline |
| 2 | White balance: temperature, tint, pick a neutral point | `neutralTemperature`, `neutralTint`, `neutralLocation`; as-shot default | `CITemperatureAndTint` (relative) | Most-used correction; first control whose RAW and non-RAW meanings differ |
| 3 | Crop, rotate 90°, flip, straighten | `CICrop`, `CIAffineTransform`, `CIStraightenFilter` on the developed image | same | Most common edit; first that changes output size, which the thumbnail and display render must follow |
| 4 | Contrast, highlights, shadows | `contrastAmount`; `CIHighlightShadowAdjust` | `CIColorControls` contrast; `CIHighlightShadowAdjust` | The rest of a basic light panel from built-ins |
| 5 | Vibrance, saturation | `CIVibrance`, `CIColorControls` | same | Built in, global |
| 6 | Sharpness, noise reduction, lens correction | `sharpnessAmount`, `luminanceNoiseReductionAmount`, `isLensCorrectionEnabled` | `CISharpenLuminance`, `CINoiseReduction`; no lens correction | RAW9 detail controls; need a 100% view to judge |
| 7 | Vignette | `CIVignette` | same | Last built-in global |
| 8 | Video trim | — | `AVPlayerView.beginTrimming`, composition time range | Simplest built-in video edit; first video recipe |

RAW9 controls it does not support (colour noise, detail, moiré, despeckle, local tone
map) never appear. Other built-ins — five-point tone curve, monochrome and preset looks,
LUTs, auto adjustment, video rotate/crop/colour — are available and not yet ordered.

## Open items

- `docs/plans/` gets a plan when building starts.
- The display-render size and scope decisions above.
- The hand-off and identity questions in the companion research.
