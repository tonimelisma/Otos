# RAW 9 calibration boundaries and failure experiments

Date: September 30, 2026. Standalone ILCE-6700 Sony VV2 research for
[plan 0105](../plans/0105-accurate-sony-rendering-pipeline.md). No app integration
or custom lens correction was added. The saved RAW 9 reference remains the
deployed baseline; none of today's photographic candidates closes its accuracy
gap. Private manifests, sampled pixels and outputs remain outside Git.

## Sources and implications

- Apple's [`linearSpaceFilter`](https://developer.apple.com/documentation/coreimage/cirawfilter/linearspacefilter)
  exposes a filter while RAW processing is linear. The SDK does not promise
  unprocessed sensor RGB or document the complete internal processing order.
- [DCamProf](https://rawtherapee.com/mirror/dcamprof/dcamprof.html) distinguishes
  camera characterization from tone rendering, explains how tone curves affect
  colour appearance, and discusses interpolation between illuminants. This
  supports testing colour calibration before styling and conditioning on white
  balance. It does not make colour and tone mathematically independent.
- [ExifTool's Sony tags](https://exiftool.org/TagNames/Sony.html) distinguish
  authored Sony adjustments from standardized EXIF descriptions with similar
  names. Capture verification must request Sony's namespace explicitly.
- Apple documents extended colour components in its
  [colour-space guidance](https://developer.apple.com/documentation/uikit/determining-color-values-with-color-spaces).
  Negative extended-sRGB components can represent colours outside the sRGB
  gamut. They can also reflect noise; negativity alone is not a scene-colour
  diagnosis.
- [ITU BT.2020](https://www.itu.int/rec/r-rec-bt.2020/en) specifies wider RGB
  primaries. Wider working primaries and output transfer/encoding are distinct
  choices. The experiment below uses BT.2020 primaries with the sRGB transfer
  for working numbers and still exports SDR sRGB HEIF.
- [ParamISP](https://arxiv.org/html/2312.13313v2) motivates examining ISO and
  exposure conditioning alongside white balance. Its results are not evidence
  that the same predictor matches this Sony body or look.

## Trustworthy measurements

### Capture look audit

The verifier now checks Sony CreativeStyle 16, PictureProfile 38, DRO 0,
Contrast 0, Saturation 0, Sharpness 0, Clarity 0, Highlights 0, Shadows 0,
Fade 0 and SharpnessRange 1 in both originals. The former check omitted eight
of these settings. An unqualified Sharpness request could return EXIF Sharpness
1 instead of Sony Sharpness 0.

All 276 previously used unique pairs pass the corrected verification: 188
training, 24 development/regression and 64 consumed RAW 9 acceptance captures.
There are 57 manifest session labels, not necessarily 57 independent trips.
Mixed Sony presets do not explain the measured failures in this corpus.
Fixtures cover changed and missing look fields on either side, capture mismatch,
wrong target transfer, unavailable originals and metadata timeout.

### Transform before blur

A nonlinear transform of blurred RGB is not the same operation as blurring its
pixelwise output. Initial per-image capacity estimates using the former order
were invalid for the release scorecard and were discarded.

The corrected diagnostic applies each fitted transform to the full frame before
the fixed Gaussian sigma 1.2 score blur. A 4-by-4 checkerboard partition supplies
two spatial folds, with filter-support buffers and an eight-pixel outer border.
Training points occur every six pixels; the other spatial half supplies held-out
scores. The reported p95 is the worse fold and mean is the mean of fold means.
These are target-assisted per-image fits, not deployable RAW-only predictions.

| Per-image family | Gates passed out of 24 |
| --- | ---: |
| Monotone channel curves plus 5³ residual cube | 20 |
| Same with 7³ cube | 20 |
| Cube indexed by original input rather than curved palette | 18 |
| 5³ cube plus coarse local bilateral residual grid | 20 |
| Degree-five global Chebyshev RGB model | 16 |

The waterfall, green-lit frame and two other scenes remain difficult. These
results do not prove a global model impossible: palette coverage, optimization
and remaining correspondence errors still limit the experiment.

A separate geometric diagnostic fits radial/scale displacement from gradient
correspondence in one spatial half and checks the other. It never selects points
by colour error. Correcting the waterfall's correspondence improves held-out
mean/p95 from 2.857/8.162 to 2.492/6.467, still outside the gate. Geometry explains
part of the error. This diagnostic is not a deployed lens profile, and neither
release masks nor thresholds changed.

## Earlier and wider representations

An identity `linearSpaceFilter` leaves final RAW 9 output unchanged (maximum
component difference 0.0 on all six regressions). Capturing its input and
converting to extended linear sRGB exposes highlights up to about 6.15, compared
with about 1.22 in the late encoded development. Portrait orientation must use
the RAW filter's orientation. The tap is a documented linear boundary, not a
claim of sensor RGB or independently disabled internal Apple corrections.

Across 212 training/development images, 142 contain negative late encoded-sRGB
samples. The green-lit frame has 14.39% negative sample pixels. The saved look
clamps these to zero, discarding information. Conversion to linear BT.2020
primaries before working encoding reduces negative samples substantially.
However, a refitted wide-working model still passes only two of six actual HEIF
regressions. Its training palette also expands, so this is not an isolated
colour-space ablation. Wider gamut is a useful boundary correction to study,
not an established accuracy improvement.

Apple's untouched default RAW 9 renderer passes zero of six Sony-match gates.
It therefore cannot replace the fixed look as a verified Sony rendering.

## RAW-only adaptation and added coverage

Eleven previously unused warm-lighting pairs were deliberately materialized
(22 files, approximately 534 MB logical bytes), then capture-verified. Originals
remain read-only. They expand a known lighting event, not independent acceptance
coverage. Adding them gives 199 training images and modestly improves the warm
portrait, without increasing regression passes.

Experiments separate candidate colour operations from the saved curves/LUT and
native lens correction. The curves/LUT itself still combines tone and creative
colour; these experiments do not establish complete stage independence.

| Actual decoded HEIF candidate | Regression gates |
| --- | ---: |
| Saved RAW 9 reference | 2/6 |
| Wider working primaries | 2/6 |
| Separate post-look Lab tone/chroma, WB-conditioned | 2/6 |
| Reference refitted with eleven warm captures | 2/6 |
| Linear-light colour matrix before look, WB/ISO/exposure-conditioned | 2/6 |
| Alternated matrix and shared curves/cube | 1/6 |
| Matrix, curves and metadata-conditioned small residual palette | 2/6 |

The linear matrix candidate preserves negative components until the colour matrix,
normalizes neutral luminance to remove matrix/exposure scale ambiguity, and uses
only RAW temperature, tint, ISO and exposure time. Its five smooth metadata
features exclude lens and focal length. Training uses 199 images; initialization
and epoch are selected using the 18 development captures. Analytic derivatives
match finite differences to 1.36e-12, and native CPU/Metal evaluation matches on
560 extended-domain synthetic inputs to 2.12e-7. Those checks certify equations,
not photographic accuracy. Sample-based fitting remains an approximation to
pixelwise-before-blur rendering, so actual encoded HEIF scores decide promotion.

| Regression | Saved reference mean/p95 ΔE00 | Linear metadata candidate |
| --- | ---: | ---: |
| Pool | 1.346 / 2.937 | 1.393 / 3.057 |
| Green-lit | 2.138 / 7.032 | 2.042 / 6.380 |
| Warm portrait | 3.029 / 5.397 | 2.092 / 4.276 |
| Waterfall | 2.551 / 7.829 | 2.676 / 7.911 |
| High ISO | 1.931 / 4.372 | 2.091 / 4.440 |
| Sunset | 2.765 / 4.610 | 2.587 / 4.658 |

It improves warm colour without meeting the portrait mean gate and worsens the
waterfall. No candidate is promoted. Image-statistics conditioning also failed
to improve all known failures and worsened the sunset. Increasing LUT resolution
alone is not supported by the corrected capacity experiment.

The matrix candidate passes 16/18 actual HEIF selection gates, with mean image
error 1.450 and worst p95 5.739. Alternating matrix and look fitting improves
selection mean to 1.358 but still passes 16/18 and regresses the high-ISO case.
An eight-feature, metadata-conditioned 5³ residual palette, represented exactly
on a 9³ grid, gets the warm portrait through its gate but misses green lighting
and waterfall and worsens other cases. It passes 16/18 selection gates with mean
1.437. None uses the target companion or embedded guide at inference.

A finer 16-by-16 spatial-fold experiment, with four-pixel scoring-filter buffers,
compares the same global fit with an 8³ local Lab-luminance grid on identical
masks. Both pass 21/24: local luminance changes are small and do not resolve the
remaining green-lighting, waterfall or July 8 cases. Those diagnostic masks
differ from the earlier coarse folds and do not alter release masks. Converting
early linear input to BT.2020 primaries before the original coarse-fold global
fit passes 19/24. Wider gamut alone does not solve the capacity gap.

## RAW filter lifetime and control audit

On all six captures, RAW 9 reports `isLocalToneMapSupported` false. Fresh filters
with local amount unset, 0, 0.25, 0.5 and 1 produce identical pixels. That exposed
control cannot supply a spatial tone operation on these inputs.

A scaled-filter lifetime hazard is reproducible on this host: repeated
`outputImage` requests after rendering the same filter change extents, for
example 774×516, then 387×258, then 194×129. Fresh identically configured filters
reproduce the original extent and pixels. The preview comparator now creates
separate filters for Apple default, neutral and native inspection rather than
mutating and reusing a scaled filter. The actual HEIF renderer and calibration
exporter already request one output from a fresh filter; their reported HEIF
gates are unaffected. This observed beta API behavior does not establish an
explanation of Apple's internal processing.

Image I/O recognizes in-memory ARW data as generic TIFF without a type hint and
omits the TIFF camera model. With `com.sony.arw-raw-image` as the hint, it reports
ILCE-6700, matching the URL metadata reader. Calibration uses that verified hint
and rejects unsupported originals before reading their companion.

## Native reproducible baseline calibration

The harness now exports training-only baseline samples and fits the existing
49-knot channel curves plus 9³ residual LUT using native Accelerate LAPACK.
There is no new numerical runtime dependency. Sample and model destinations
reject existing files; malformed/non-finite samples and held-out roles fail
before producing a model. Calibration reads originals through the existing
materialization gate, and samples remain private.

Each sample directory carries an explicit decoder, neutral-control, lens-state,
sample-count, scale and calibration-blur recipe. The fitter rejects absent,
malformed or mismatched recipes. Synthetic fixtures include wrong-decoder recipe
and unsupported-original rejection.

Native export re-read all 199 verified training captures in 256.7 seconds with
zero failures. All 188 original training sample files are byte-identical to the
earlier export.
Refitting 188 images and 455,703 samples reproduces saved curves exactly and cube
coefficients within 4e-15. This makes the current baseline reproducible; it
does not improve that baseline's photographic results. Calibration uses the
original Core Image blur-radius recipe, separately named from the release
scorecard's explicitly defined Gaussian sigma.

## Remaining work

The renderer reliably writes the tested HEIFs, but the RAW-only Sony accuracy
gate remains open. Continue comparing earlier colour boundaries, joint
colour/tone fitting and constrained local luminance before introducing a larger
predictor. Use actual HEIF validation throughout. After selecting a successful
pipeline, freeze new independent acceptance sessions, inspect native texture and
highlight behaviour, and measure RAW 9 memory, latency and cancellation. Custom
lens profiles remain deferred and geometry/fringing must stay separately reported.
