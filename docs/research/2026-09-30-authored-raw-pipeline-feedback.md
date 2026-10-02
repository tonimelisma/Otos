# Research for the authored RAW-only pipeline framework

Date: September 30, 2026. Planning evidence for Plan 0105. The user authorized updating
the framework and starting execution after reviewing the chat draft. The changes
below are adopted planning decisions, not claims of new photographic improvement. No camera
JPEG or preview is an allowed inference input.

## Primary sources

- [darktable sigmoid](https://docs.darktable.org/usermanual/development/en/module-reference/processing-modules/sigmoid/):
  accepts linear scene RGB, produces linear display RGB, and provides contrast,
  skew, hue preservation and primaries controls. Exposure sets midtones before
  the view transform; only one view transform is recommended. Per-channel and
  RGB-ratio approaches have different hue/chroma consequences. This supports
  explicitly choosing colour handling alongside the curve, rather than treating
  tone as independent scalar brightness. Development documentation was consulted;
  its defaults are not evidence about our Core Image recipe.
- [darktable colour calibration](https://docs.darktable.org/usermanual/development/en/module-reference/processing-modules/color-calibration/):
  technical WB/profile handling and chromatic adaptation have distinct roles.
  The module uses linear scene RGB and can address different illuminants locally.
  Grey-world estimation has scene-dependent limitations. Correlated colour
  temperature can be inadequate for illuminants far from daylight. This cautions
  against expecting temperature/tint regression alone to solve mixed/LED lighting.
- [RawTherapee toolchain](https://rawpedia.rawtherapee.com/Toolchain_Pipeline):
  documents fixed module order, input/working/output colour responsibilities,
  nonlinear tone/creative operations and final conversion. Its camera auto-match
  operation is excluded from our scope. Its full feature inventory is not a
  reason to implement all of those operations here.
- [DCamProf](https://rawtherapee.com/mirror/dcamprof/dcamprof.html):
  distinguishes the colourimetric base from tone curves, gamut compression and
  look operators. Tone rendering affects colour appearance, and a profile can
  compensate for a particular curve. This supports shared fitting of interacting
  operations followed by ablations, rather than assuming independent physical
  effects because controls are separately owned.

## Adopted framework refinements

1. Use a fixed authored style plus separately owned technical normalization.
   Scene-dependent exposure/WB adjustment should not silently redefine the style.
   Start from camera WB and baseline exposure, adding normalization only when a
   specific failure demonstrates a need. Sensor clipping cannot be reversed by
   moving a tone shoulder.
2. Select one explicit display-transform family. A compact sigmoid-style transform
   is a reasonable first experiment because contrast/shoulder and colour handling
   can be controlled directly. It is a recommendation, not a validated winner.
   Compare against the saved baseline on actual native-size HEIFs before adoption.
3. Compare luminance/RGB-ratio handling with hue-controlled per-channel handling
   using the same normalization and look. Declare tests for neutral ramps, skin,
   saturated LEDs, gradients and highlights. No concurrent black-level/profile/LUT
   changes may obscure the result. Prefer smooth gamut treatment over unexplained
   clipping when it demonstrably prevents artifacts.
4. Establish a simple RAW-only reference renderer with explicit editable settings
   before training predictors. Successful manual settings diagnose which operation
   is required. Parameter prediction is a later problem; JPEG matching is absent.
5. Define separate acceptance for technical validity, authored appearance and
   automatic reliability. Existing Sony DE00 thresholds remain reported as offline
   diagnostics. Freeze look anchors plus technical/artifact gates before
   photographic selection; production acceptance tests our authored appearance.
   This must not quietly relabel known failures as successes.
6. Make the initial execution a bounded experiment, not another broad methods
   survey: frozen native input, one display family, two colour-handling variants,
   permanent hard cases/good controls, native HEIF output and an adopt/reject/
   inconclusive report. If no variant succeeds, produce a supported failure
   attribution before adding another family or increasing model complexity.

## Limits

Manual-editor workflows demonstrate useful operations, not reliable automatic
settings for our corpus. Apple's RAW decoder is a different input boundary from
an open-source demosaic pipeline; do not duplicate its WB/profile corrections.
No publication guarantees automatic rendering quality in mixed light, clipped
captures or insufficient training coverage. Research can constrain architecture
and hypotheses; our native photographic evidence must decide the implementation.
No external library/code has been added, no original modified, and no active
pipeline coefficient changed by this research pass. The framework now separates
authored-appearance acceptance from the retained offline Sony-match scores.
