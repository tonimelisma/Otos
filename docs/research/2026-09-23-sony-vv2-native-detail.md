# Sony VV2: native-resolution detail and portable algorithm

Experiments performed September 23, 2026; documentation finalized September 26.
This completes the media-independent reference for the measured Sony VV2 look.
It does not implement an Otos editor or claim bit-identical Sony processing.

The [subsequent failure analysis](2026-09-26-sony-lens-and-indoor-color.md)
qualifies readiness: the recipe is reproducible, but indoor color and edge
geometry remain imperfect. It preserves improved, narrowly validated candidates.

## Decision

Preserve the trained color model and its original RAW boundary: decoder 8,
boost/local tone/contrast/sharpness/detail zero, native per-file noise defaults.
Do not add mandatory post-sharpening. The measured benefit was small and varied
by session; aggressive sharpening and maximum noise reduction were worse.
The package now contains everything needed to apply and numerically verify this
recipe without the training photographs. Repeating photographic evaluation or
training a better model requires paired images again.

The user's scope is algorithms, parameters, reproducible reference behavior and
research evidence, using macOS APIs without third-party dependencies. Media,
private manifests, crops and sampled pixels stay outside Git. No originals were
modified, deleted, or deliberately downloaded. Application integration is separate
work, not an outstanding research prerequisite for applying the saved function.

## Native pixel comparison

At this pass's admission snapshot, 312 of the original 344 pairs remained local.
All 312 were decoded; 32 dataless pairs were skipped. Every original read was
preceded by an `lstat` regular-file and `SF_DATALESS` check. This is a snapshot
check, not a guarantee against eviction in the gap before reading.

The harness uses Foundation, Core Image, Image I/O, Vision and Metal. Python's
standard library only schedules runs and aggregates JSON; no external image or
numerical library participates in this pass. Environment: macOS 27.0 (26A428),
Xcode 27.0 (27A266a), RAW decoder 8. RAW 9 is a different pipeline and was not
substituted for the decoder on which the saved model was learned.

1. Decode full sensor resolution (6192 × 4128, with orientation applied) and
   the main HEIF image. Develop RAW with the documented neutral settings.
2. Render both to extended-sRGB-encoded RGBA half-float images, then treat their
   samples numerically with further color conversion disabled. Apply the exact
   learned function with Metal. This avoids an 8-bit training/measurement path.
3. Register 768-pixel previews with Vision homography. Evaluate matrix direction
   and vertical-coordinate conventions by preview RGB squared error.
4. Take a 3 × 3 grid of 384-pixel native-resolution crops at quarter positions.
   Register local translation; reject a crop if either displacement reaches
   24 pixels. Test coordinate signs by RGB error. Refine residual displacement
   on a quarter-pixel grid over ±0.5 pixel using high-pass luminance error.
5. Measure only the central 336 × 336 pixels. RGB MSE/MAE use encoded RGB.
   Detail error is mean squared difference of encoded luma high-pass residuals:
   Y = .2126R + .7152G + .0722B, high-pass = Y − GaussianBlur(Y, radius 1.2).
   Each photo's accepted crops are averaged; each photo then has equal weight.
6. Compare no added sharpening against seven `CISharpenLuminance` settings,
   clamping their outputs to [0,1]. Sharpness/radius pairs are .25/.5, .5/.5,
   .25/1, .5/1, 1/1, .25/2 and .5/2. Radius is in native image pixels.

All 312 images had at least one accepted crop: 2,658 accepted and 150 rejected
out of 2,808 proposed crops. Each setting measured 300,077,568 pixel locations.
This is dense pixel-by-pixel comparison **inside sampled native-resolution
crops**, not comparison of every pixel in every entire image.

Registration is an estimated nuisance correction, not proof of exact geometric
correspondence. Residual lens distortion, interpolation, noise, demosaicing and
clipping all contribute to error. Local translation rejection is not a full
registration-confidence test. Do not interpret the metric as isolated sharpening
error, perceptual preference, or a bit-exact Sony reconstruction score.

## Post-sharpening result

| Setting (sharpness / radius) | Mean detail MSE | Mean RGB MSE |
| --- | ---: | ---: |
| None | 0.000046104 | 0.000428989 |
| 0.25 / 0.5 | 0.000045537 | 0.000430128 |
| 0.25 / 1 | 0.000045552 | 0.000435049 |
| 0.5 / 1 | 0.000049069 | 0.000451619 |
| 1 / 1 | 0.000068247 | 0.000515998 |

For each of nine shooting sessions, select the lowest-detail-error setting on
the other sessions, then score only the withheld session. This gives detail MSE
0.000045797 versus 0.000046104 without sharpening: **0.67% improvement**, with
212/312 individual images improved but two session means worse. The fixed color
model was already trained on all 344 original pairs: this is held-out selection
of the detail setting, **not** new held-out validation of the whole color pipeline.
The original research separately reports held-out color-model fits.

The 16 images at ISO ≥2500 favored more sharpening on average. Most belong to
one indoor session, so an ISO-dependent setting would confound ISO with scene
and illumination. No such conditional setting is promoted into the saved recipe.

## RAW noise and detail controls

A second pass ran five alternatives on 39 selected images: 24 lower-ISO examples
spread across all nine sessions plus 15 high-ISO examples from the indoor session.
The six methods (including baseline) share 339 accepted crop positions. This is
an exploratory, high-ISO-enriched subset, not a representative quality estimate.
Each alternative changes just one RAW setting: luminance noise reduction to 0
or 1, RAW sharpness to 0.5 or 1, or RAW detail to 0.5. Other settings stay fixed.

| RAW alternative | Lower ISO detail MSE | High ISO detail MSE |
| --- | ---: | ---: |
| Original neutral + native noise | 0.000039361 | 0.000186014 |
| Noise reduction 0 | 0.000039071 | 0.000170956 |
| Noise reduction 1 | 0.000043614 | 0.000295349 |
| Sharpness 0.5 | 0.000043232 | 0.000172379 |
| Sharpness 1 | 0.000064619 | 0.000167482 |
| Detail 0.5 | 0.000039090 | 0.000165212 |

Maximum noise reduction substantially worsened this match. High-ISO detail 0.5
improved the selected scene's detail error by 11.2%, but changing RAW detail
also changes the input on which the color model was trained. Neither independent
high-ISO scene validation nor a refitted color model was performed. Retain this
as measured evidence for future training, not an unqualified global improvement.
No broad parameter search or exact inversion of Sony's proprietary demosaic,
noise, lens and sharpening pipeline is claimed.

## Portable implementation and verification

The [reference package](sony-vv2-reference/README.md) includes exact JSON curves
and residual coefficients, fitting equations, explicit decode/evaluation
contracts, Swift/Core Image development, Swift/Metal evaluation, a native
comparison harness, and 560 synthetic test vectors. No image pixels or individual
photo metadata are in that package. Aggregate results are retained in
`native-detail-summary.json` and `raw-controls-summary.json` alongside the model.

Listings were extracted into a fresh directory, compiled, and tested with access
to CloudStorage, the historical experiment directories, and visualization artifacts
explicitly denied. All 560 synthetic vectors passed: CPU maximum channel error
4.44e-16; Metal maximum channel error 1.92e-7. Invalid inputs, future model versions
and malformed LUT dimensions were rejected. This verifies implementation without
photographs. A trial `CIColorCube` path differed by up to 0.002653 and was rejected;
the exact Metal evaluator is the reference. The cause of that discrepancy was not
isolated, and it is not evidence that all Core Image cube implementations fail.

Baseline native batch elapsed 723.7 seconds with two workers. Median per-image
harness time was 3.71 seconds, maximum 16.84 seconds. A standalone pilot measured
6.91 seconds wall time, 394 MB maximum resident set and 1.64 GB peak footprint.
The 195 additional control runs completed in 437.7 seconds. These are research
CLI timings, not interactive editor performance claims. Structured progress,
per-image JSON and local logs provided observability; app logging was unchanged.

## Visual evidence and remaining limits

A local-only A/B gallery preserves seven difficult cases: the highest RGB-MSE
examples and additional highest detail-error examples, suppressing captures
within one minute of an already selected image. It has whole-image 2048-pixel
previews and aligned 336-pixel crops, with side-by-side and toggle controls.
The gallery uses the final fitted model, not held-out models. No gallery media
or identifying manifest is committed. Originals and historical artifacts remain
untouched; the user can discard training material after retaining this package.

Inspection of the worst RGB-error case found a saturated light whose Sony target
retains yellow while the learned result becomes white/red. Thus large residuals
can reflect highlight hue handling, not merely softness. Fine texture and warm
indoor rendering also remain imperfect. Generalization is limited to one camera,
one look and two capture days. These limits are documented, not solved by adding
unvalidated sharpening. The algorithm is ready to implement as the measured
approximation; exact Sony matching and broader looks need additional evidence.

## Apple API sources

- [CIRAWFilter](https://developer.apple.com/documentation/coreimage/cirawfilter)
  exposes decoder selection, neutral development and native detail/noise controls.
- [CISharpenLuminance](https://developer.apple.com/documentation/coreimage/cisharpenluminance)
  defines the tested radius and sharpness parameters.
- [Enhance RAW image processing with Core Image, WWDC26](https://developer.apple.com/videos/play/wwdc2026/305/)
  explains the opt-in RAW 9 pipeline; changing decoder requires fresh evaluation.
