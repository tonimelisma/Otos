# 0029 — Standalone RAW camera-render matching boundary

Status: accepted for the standalone implementation. Photographic evidence and
reopening rules live in the [vivid recipe validation](../research/2026-10-01-vivid-raw9-pipeline-validation.md).

## Context

The requested algorithm develops sensor RAWs into ready HEIFs outside the Otos app.
The target is the visible rendering of the user's Sony VV2 camera HEIFs. Camera
HEIFs provide paired training/evaluation targets; rendering must work from sensor
RAW and its capture metadata without any camera image or embedded preview. Native
lens correction and colour/tone have independent ownership and diagnostics.

## Decision

`NativeRAWDevelopment` owns the one full-resolution Core Image RAW decoder-9
contract shared by standalone rendering and calibration. It retains native white
balance, baseline exposure, shadow bias and denoise, records actual native control
facts, and uses an extended-linear-sRGB development context with explicit extended
linear BT.2020 output for authored processing. Unsupported decoder/camera input
fails explicitly. Native lens correction follows the API's supported flag; missing
lens identity remains unknown and unsupported correction is reported disabled.
Custom profiles and lens-specific look coefficients are absent.

`AuthoredLook` owns versioned, bounded exposure/WB normalization, display tone,
creative saturation, an optional neutral-protected 5-cubed colour residual, explicit
display gamut policy and one sRGB transfer. Per-channel hue preservation uses
bounded interpolation between mapped channel endpoints, avoiding division by
near-zero signed luminance; it makes no energy-preservation claim. Stage ablations
use the same owner.
CPU evaluation supplies the offline numerical oracle; `MetalAuthoredLook` implements
the same pixel function for native output. Malformed or unsupported recipe versions
are rejected. There is no compatibility fallback or per-photo inference lookup.

`SonySensorRAWHEIFRenderer` owns original availability checks, typed look dispatch,
metadata preservation, native 10-bit SDR sRGB HEIF encoding and complete-file
publication without overwrite. It reads a guarded RAW and the already loaded
recipe only. Outputs are outside media roots; originals are never modified.
Cancellation observed before publication prevents publication and removes the
owned temporary output. Synchronous Apple work may finish before cancellation is
observed. Named signposts and structured stage logs expose development, colour
application, encoding and publication without adding media content to diagnostics.

`ConditionalProfile` owns an experimental shared colour-field selector over native
RAW neutral temperature and EXIF ISO. Constant, WB-only, ISO-only and combined
ablations share bounded fields and the saved-profile pixel owner. Its convex
metadata interpolation is continuous and capped; invalid required metadata fails.
Neither camera-image access nor lens identity belongs to selection. Offline
training can read separate HEIF targets; rendering reads only RAW and a frozen
shared model. This is a measured experiment, not an accepted replacement recipe.

Offline calibration owns reference access, role/date-group validation, bounded
fitting, explicit fitted-example weights and diagnostic capacity recipes.
`NativeRegionPalette` owns source-only full-region palette and native/reduced
preparation diagnostics. It reads no camera target and cannot certify matching.
Native objective fitting samples entire reliably corresponding scored rectangles
uniformly, with at most 1024 points per region and equal total region weight.
An inset is rejected because it can omit a small saturated object entirely;
Gaussian support comes from the already blurred full frame. Unknown geometry
remains excluded from fitting and reported in output evaluation.

Fitted examples and broad training have disjoint capture-date groups; fitted
examples are training evidence and never count as independent validation. Reduced aligned observations initialize
models; actual native HEIFs validate photographic claims. Withheld-region capacity recipes exclude frozen appearance regions from both
spatial and palette sampling. Whole-image expression diagnostics explicitly fit
all sampled areas, mark their reports as non-validation evidence, and cannot
establish automatic inference. Neither is a runtime selector. Offline final-display fitting names encoded-RGB or normalized D65 CIELAB error
coordinates explicitly; neither replaces actual native-output validation. Region
measurement requires a fixed RAW-derived geometry baseline independent of candidate
colour and reports unregistered colour, measured local correspondence/support and
inconclusive facts separately. Pixelwise mean/p95 establish colour matching;
median-colour outcomes are explicitly named diagnostics. Development-only
comparison calibration owns known perturbations and alternate preparation,
separately from renderer fitting. Supplementary offline perceptual evaluation is
owned by ADR 0031. Confident native-detail matches are retained;
ambiguous matches get one fixed Gaussian-scale retry under the same confidence
rules. Relative correspondence uncertainty is a gate; moving both colour patches
together is a spatial-residual diagnostic. This preserves the distinction between
unreliable geometry and nearby content having different appearance error. Its
registration never becomes a deployed lens correction.

## Alternatives

- App integration: rejected for this increment because the task is algorithm
  development outside the app; no catalog/window/export owner is changed.
- Camera-preview-assisted matching: rejected because rendering must use RAW alone
  and access to a camera image violates that input boundary.
- Reusing the saved encoded-RGB curve/LUT as the final architecture: retained only
  as a named comparator; it combines tone and colour without independent controls.
- Automatically adding local correction: deferred until reliable native residuals
  demonstrate need. A bounded shared RAW metadata predictor is retained as an
  experiment after combined native fits cleared five hard controls and shared
  conditioning improved two date-disjoint cases; broad regression and independent
  acceptance remain mandatory before promotion. No per-photo target fitting is
  used by the predictor.
- A third-party runtime/training library: unnecessary for the implemented compact
  family; Core Image, Metal and Accelerate provide the required concrete owners.

## Consequences and boundaries

The toolchain is Swift 6 with complete strict concurrency. The standalone harness
is independently buildable and testable; it shares only the repository's logging
facade with the app. Numerical conformance does not certify a photographic recipe.
Current research records the working candidate, seven whole-image development
failures, three inconclusive regional comparisons and incomplete independent
paired acceptance. Implementation acceptance in this ADR does not certify recipe
accuracy or completion of Plan 0105. This ADR owns implementation boundaries, not the final
look, camera profiling, custom lens profiles, app integration or future automation.
