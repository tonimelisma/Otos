# Sony VV2 RAW 9 fixed look reference

This package holds the camera-wide look fitted for the standalone ILCE-6700
RAW-to-HEIF renderer. It contains no photographs, sampled photo pixels,
capture manifests or private paths. `model.json` is the exact saved numerical
model and `test-vectors.json` contains 560 synthetic RGB input/output cases.
The harness build runs those vectors on CPU and Metal, including decoder and
malformed-model rejection. The original RAW 8 reference remains in the
neighboring `sony-vv2-reference` directory for historical comparison only.

## Input and stage order

1. Use `CIRAWFilter` on the ARW sensor bytes. Require decoder version 9.
2. Retain the camera's white balance and baseline exposure. Set boost, local
   tone mapping, contrast and sharpness to zero. Do not set RAW 9's unsupported
   detail/moire properties or ineffective color-noise property.
3. Require and enable Apple's native lens correction. Keep lens behavior out
   of the camera-wide look parameters.
4. Convert the developed image to float extended-sRGB-encoded RGB. Clamp
   look *input* to [0, 1.25], linearly interpolate each 49-knot channel curve
   and the 9 × 9 × 9 trilinear residual LUT from the same input, add them,
   then clamp the *result* to [0, 1]. LUT nesting is red, green, blue, RGB.
5. Tag the encoded numbers as sRGB without applying the transfer function a
   second time. Publish a complete 10-bit SDR HEIF with source capture
   metadata; never overwrite an existing file or write to a media root.

The look does not operate in scene-linear space. Apple's internal RAW 9
processing is opaque. A linear-space boundary and highlight behavior remain
research items; do not describe these coefficients as a universal camera
profile or as recovery of Sony's proprietary processing.

## Calibration provenance and limits

188 private, capture-verified training pairs supplied the fit. Each RAW was
decoded with the contract above, downscaled to 768 pixels on its long side,
converted to float encoded extended sRGB, and registered to its *separate*
Sony VV2 HEIF for training only. A 50 × 50 grid of Gaussian-blurred,
corresponding RGB samples was extracted per pair. Each image's samples carry
aggregate weight 2500, avoiding dominance by large valid regions. There were
455,703 valid six-channel samples in total, with 1421–2500 per image.

For each RGB channel, 49 bins across [0, 1.25] accumulate weighted target
means. Add unit weight toward the identity knot, then apply weighted isotonic
regression to make each curve nondecreasing. Evaluate all three curves at the
original input. Fit residuals to the 9³ cube by weighted least squares with
trilinear basis functions. Add ridge weight 2 to each node and first-neighbor
smoothness weight 10 along each cube axis, then solve the normal equations for
three output channels. The maximum absolute residual node coefficient is
0.174. Input values outside the domain use endpoint interpolation; output is
clamped only after curve and residual addition. This is the same model family
as the earlier reference with a new RAW 9 input contract and freshly fitted
coefficients.

The native harness now reproduces this sampling and fitting procedure through
`calibration-export-one` and `calibration-fit`; see its
[instructions](../../../tools/sony-render-harness/README.md). A native refit on
the same 188 training images reproduces the curves exactly and residual cube
within 4e-15. All 188 re-exported sample files match the original bytes exactly.
Neither samples nor private manifests belong in this package.
The [September 30 investigation](../2026-09-30-raw9-calibration-boundaries.md)
tests earlier linear colour boundaries, complete Sony look verification and
metadata adaptation without promoting an inaccurate replacement.

On six predeclared regressions, the encoded fixed-look HEIF passes two of six
broad-colour comparator gates. It passes 16 of 18 development-selection captures,
with mean image low-frequency DE00 1.494 and worst p95 6.009. On the subsequently
frozen 64-pair RAW 9 set, 64/64 HEIFs were produced and 42/64 met those gates.
These are development results, not fresh acceptance or a completed authored look.
Historical camera-guided results are excluded; all guide extraction, controls and
JPEG comparator code have been removed from the standalone tool. Camera previews
and companions are not inference inputs. The active
[framework](../../plans/0105-accurate-sony-rendering-pipeline.md) retains these
Sony-match scores as offline diagnostics, with separate authored-appearance,
technical and automatic-reliability acceptance. The
[pipeline comparison](../2026-09-29-raw-processing-pipeline-comparison.md)
records the earlier split, lens geometry and high-ISO strata.
