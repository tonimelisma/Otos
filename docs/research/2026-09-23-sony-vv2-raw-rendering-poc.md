# Sony VV2 rendering from paired RAW/HEIF: local POC

Research recorded 2026-09-23; media inventory, decoding, fitting, and validation
performed on 2026-09-22. This is experimental evidence, not implemented Otos
editing behavior or a production filter specification.

## Conclusion

A small global tone/color transform reproduces much of this camera's preferred
rendering without a neural network. Across 344 paired captures, withholding each
capture session from its model's training reduced mean per-image CIE76 color
error from 8.397 for Apple's default RAW rendering to 2.380: a 71.7% reduction.
Every image improved on this metric. Independent channel tone curves alone
reached 3.105; a regularized 9 × 9 × 9 residual color LUT provided the remaining
improvement. These measurements assess aligned, lightly blurred, reduced-resolution
SDR color and tone, not identical full-resolution detail or subjective preference.

The model is specific to the alpha 6700, Sony VV2, and the defined Apple RAW v8
base development. It is not a universal look for arbitrary JPEGs or other cameras.
The [native-detail follow-up](2026-09-23-sony-vv2-native-detail.md) now records
full-resolution crop comparisons and noise/sharpening experiments. The
[portable algorithm package](sony-vv2-reference/README.md) preserves coefficients,
native reference listings, fitting math, and synthetic tests without media.
Broader capture-day and illuminant coverage remains a limit; these results do
not establish a need for a neural network or local adaptive processing.

## Data and cloud-file admission

The camera-roll filename inventory found 3,150 unambiguous same-folder,
same-stem ARW/rendered-image pairs. At the admission snapshot, 344 pairs had both
files materialized; the other 2,806 pairs were not read. All 344 admitted pairs
were used, not a selected visual subset. A second status inventory before the
end of the experiment found no additional local pairs.

The admitted originals totaled 14.227 GB. There were 67 captures from September
20 and 277 from September 21, all `ILCE-6700`. Capture timestamp/subsecond,
camera, exposure, and ISO agreed between each RAW and its companion. All
companions were HEIF, all reported VV2 (`CreativeStyle` numeric value 16,
`PictureProfile` 38), and Dynamic Range Optimizer was off. ISO ranged from 100
to 10,000; 294 images were ISO 100. The paired sample is narrow despite its size.

Admission follows the existing materialization research and implementation:

- Enumerate names and inode facts; do not extract EXIF from placeholders.
- Check `lstat.st_flags & 0x40000000` (`SF_DATALESS`) before metadata and image
  reads; skip dataless or unknown files rather than waiting for downloads.
- The Swift decoder checks regular-file status and the flag immediately before
  reading each original into `Data`. Subsequent decoding reads that in-memory
  data, not the provider path.
- No materialization request was issued. Originals were opened read-only;
  derived data and diagnostics stayed outside the media folders.

The flag is a point-in-time admission check, not a durable guarantee against
provider eviction between check and read. No such failure occurred in this run.
The local manifest records the snapshot, not current materialization state.

See [hydration shape and latency](2026-09-01-onedrive-hydration-shape-and-latency.md),
[materialization FSEvents](2026-07-11-onedrive-materialization-fsevents.md), and
`Otos/Services/FileMaterialization.swift`.

## These are 10-bit SDR HEIF files

The newest files' HEVC bitstream reports 10-bit luma and chroma. Independent
FFmpeg inspection reported `yuv422p10le` for the main image, BT.709 primaries,
and `iec61966-2-1` (sRGB) transfer characteristics. Image I/O decoded the main
image with 10 bits per component and an sRGB color space. An embedded JPEG is
8-bit; it is not the main image and was not the learning target.

All 344 targets' inspected color tags agreed on BT.709 primaries and the sRGB
transfer characteristic. Ten-bit precision does not imply HDR. Sony documents
that this camera disables HLG Still Image in RAW & HEIF mode. The experiment
therefore compares SDR renders and does not apply an HDR-to-SDR conversion.

## Reproducible processing boundary

Environment: macOS 27.0 (26A428), Xcode 27.0 (27A266a). Standalone Swift/Core Image
handles actual RAW development; an isolated temporary Python environment handles
numerical fitting. No app dependency or app source changed.

1. Create `CIRAWFilter` from ARW bytes, never from an embedded preview. Every
   decoded file selected decoder `8` in this environment; versions 7, 8, and 9
   were reported available. Version 9 was not evaluated.
2. Retain as-shot white balance, baseline exposure, highlight recovery, and the
   decoder's lens correction. All samples had lens correction enabled, baseline
   exposure 0.4 EV, and shadow bias 3. White-balance temperature varied from
   about 3003 K to 7227 K.
3. Save Apple's default rendering as a comparator. For the defined neutral
   input, set `boostAmount`, `localToneMapAmount`, `contrastAmount`,
   `sharpnessAmount`, and `detailAmount` to zero. Other controls remain at this
   decoder's defaults. This is a defined base rendering, not unprocessed sensor
   values or a claim that all RAW software looks the same.
4. Set decode scale from a 768-pixel long edge; normalize orientation and resize
   with Lanczos. Work in extended linear sRGB internally and write neutral and
   target arrays as extended sRGB-encoded float32 RGBA. Those arrays preserve
   excursions outside 0–1 until the documented model/display clipping. Training
   does not pass through an 8-bit JPEG. Apple's comparison PNG is 8-bit, a small
   quantization asymmetry; gallery JPEGs are presentation artifacts only.
5. Match SIFT features and fit a RANSAC homography from RAW render to target.
   Require at least 20 inliers and at most 60 pixels of corner displacement.
   All 344 passed; median per-image inlier reprojection error was 0.254 pixels,
   and the largest corner shift was 7.686 pixels. A homography cannot eliminate
   arbitrary residual lens distortion.
6. Warp neutral and default renders into target coordinates; mask unavailable
   pixels and an eight-pixel border. Apply Gaussian blur with sigma 1.2 pixels
   to discount sharpening, noise, and small alignment differences.
7. Sample 2,500 valid training pixels per image, excluding any channel with
   neutral outside (0.005, 1.245) or target outside (0.005, 0.99). Evaluation
   samples 10,000 valid pixels per image without this color/clipping exclusion.
   Sampling is deterministic. There was no measured neutral-domain overflow
   above 1.25 in admitted valid pixels. Evaluation clips displayed RGB to 0–1.

Otos's existing `PreviewImageLoader` prefers embedded previews. That display
path is not an adequate training input: using it could compare two already
camera-rendered images. A future integration needs an explicit sensor-development
boundary and a versioned input contract before applying this recipe.

## Learned transform

Let `x` be the three-channel extended sRGB-encoded neutral input. The recipe is:

```text
output = clamp(channelCurves(x) + trilinear(residualCube, x / 1.25), 0, 1)
```

The three independent curves have 49 evenly spaced knots over 0–1.25. Estimate
per-bin channel means with a weak identity prior, then weighted isotonic
regression to enforce monotonicity. Linear interpolation evaluates each curve.

The residual cube has 729 RGB nodes. Fit the remaining paired-pixel error using
trilinear interpolation and squared error, plus weight-10 neighboring-node
smoothness and weight-2 zero-residual regularization. These strengths and the
cube size were fixed before reading validation scores. Each image contributes
the same sample count; capture sessions have different image counts.

There is no per-image color fitting against its target at prediction time,
no semantic mask, no learned spatial processing, and no separate matrix. Global
channel curves already explain most of the change. For example, the final red
curve maps input 0.2 to approximately 0.276 and 0.4 to 0.660. Those are encoded
RGB values, not linear-light exposure multipliers.

## Validation

Capture sessions are connected runs of timestamps separated by no more than ten
minutes. This produced nine groups of 9, 2, 56, 176, 18, 10, 38, 33, and 2 images.
Leave-one-session-out fitting produced exactly one held-out prediction for every
image. Close burst neighbors stay together. Temporal grouping is a proxy for
scene separation, not proof that every held-out subject is novel.

CIE76 is Euclidean Lab error, not CIEDE2000. The following values are means of
per-image measurements; PSNR is calculated in displayed sRGB, not sensor space.

| Method | Mean CIE76 error, lower better | Mean PSNR, dB | RGB mean absolute error |
| --- | ---: | ---: | ---: |
| Defined neutral rendering | 19.034 | 14.415 | 0.16870 |
| Apple default | 8.397 | 22.145 | 0.06972 |
| Learned channel curves | 3.105 | 32.241 | 0.01732 |
| Curves + residual LUT | 2.380 | 34.401 | 0.01271 |

Giving each session equal weight instead of each image yields 8.126 for Apple
and 2.742 for the LUT. The result therefore does not depend solely on the largest
176-image session. All nine session means and all 344 image errors improved
relative to Apple on the primary CIE76 metric.

A separate whole-day holdout used every image on the other day for training:

| Held-out day | Training images | Test images | Apple CIE76 | Curves CIE76 | LUT CIE76 |
| --- | ---: | ---: | ---: | ---: | ---: |
| September 20 | 277 | 67 | 9.221 | 3.261 | 2.652 |
| September 21 | 67 | 277 | 8.198 | 3.149 | 2.428 |

A falsification control shuffled target-pixel correspondence in training, then
predicted the largest held-out session. Its CIE76 error rose to 29.793, versus
1.935 for correctly paired fitting on that session. Pair correspondence matters;
the successful score is not merely the result of generating the dataset's
average color.

The final reusable recipe was fitted on all 344 images after validation. The
local gallery uses the held-out models, not that final all-data model.

## Visual findings and limits

Visual inspection covered one median-error example from each session plus the
three worst errors, with the worst indoor and foliage comparisons also inspected
at their full comparison-sheet size. The local gallery includes all 344 accepted
pairs in chronological order. Columns are neutral, Apple default, held-out
learned output, and actual Sony HEIF.

Typical daylight examples become much closer in brightness and color. The
largest remaining errors include warm indoor skin and bright foliage. In one
indoor example the learned output is visibly too warm. Mean LUT CIE76 is 2.249
for the 294 ISO-100 images and 4.770 for the 16 images at ISO 2500 or above.
Lighting and ISO are confounded; these observations do not identify the causal
processing difference. The worst image remains at 6.736 despite improving from
9.128 for Apple. Averages do not imply an exact or universally pleasing match.

Not established: full-resolution sharpness/noise matching, another camera or
look, arbitrary neutral-image inputs, HDR output, broad seasonal/lighting
coverage, or end-user aesthetic preference. No full-resolution or Otos UI
performance claim follows from this reduced-resolution POC.

## Artifacts and timing

Private artifacts are retained locally under the Codex task's
`sony-vv2-poc` artifact directory: full gallery, contact sheet, source scripts,
private pair manifests, sampled training/evaluation arrays, per-image scores,
registration records, decoder logs, model coefficients, `recipe.json`, and a
33-cube export. Photographs and private manifests are not committed or uploaded.
The throwaway execution directory is `/tmp/otos-raw-jpeg-poc`.

The standalone `.cube` approximates the combined curve/residual recipe; it is
not a Sony camera profile and must only be applied to the specified neutral v8
input. It declares domain 0–1.25. Against 100,000 deterministic random inputs,
export interpolation differed from the exact recipe by 0.000461 mean and 0.011112
maximum absolute channel value. The exact coefficient recipe is the reference.
The sampled gray ramp stayed finite; its tiny negative luminance step
(approximately 0.0000005) means strict final-LUT monotonicity is not guaranteed.

Decoding completed with zero failures: 343 batch decodes and one already completed
pilot, 226.6 seconds batch wall time with three subprocesses. Median recorded
per-pair decoder time was 1.754 seconds; worst was 8.320 seconds. Nine held-out
fits, evaluation, and final fitting took 15.323 seconds on cached sampled arrays.
These are CLI experiment timings, not interactive app latency benchmarks.

The isolated Python dependencies were NumPy 2.5.3, SciPy 1.18.1, Pillow 12.3.0,
and opencv-python-headless 5.0.0.93. No third-party runtime dependency is proposed
for Otos by this experiment.

## Sources

- [Sony alpha 6700: HLG Still Image](https://helpguide.sony.net/ilc/2320/v1/en/contents/201h_HLG_photo.html)
  — RAW & HEIF disables HLG; SDR/HDR distinction.
- [Sony: characteristics of HEIF](https://support.d-imaging.sony.co.jp/support/ilc/heif/06/en/index.html)
  — 10-bit gradations and separate HLG behavior.
- [Sony: Creative Look](https://www.sony.com/electronics/support/articles/00273574)
  — camera look controls and VV2 context.
- [Apple: CIRAWFilter](https://developer.apple.com/documentation/coreimage/cirawfilter)
  and the installed Xcode 27 `CIRAWFilter.h` — decoder controls and their meanings.
- [Apple: CIColorCubeWithColorSpace](https://developer.apple.com/documentation/coreimage/cicolorcubewithcolorspace)
  — native color-cube application boundary for a possible future implementation.
- [Zeng et al.: image-adaptive 3D LUTs](https://arxiv.org/abs/2009.14468)
  — a possible later adaptive approach; the POC uses a fixed regularized LUT,
  not this paper's neural model.

Online sources checked 2026-09-22. The measured claims above come from local
artifacts, not from those sources.
