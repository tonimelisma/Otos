# 0029 — Standalone authored RAW look boundary

Status: accepted for the standalone implementation. Photographic evidence and
reopening rules live in the [vivid recipe validation](../research/2026-10-01-vivid-raw9-pipeline-validation.md).

## Context

The requested algorithm develops sensor RAWs into ready HEIFs outside the Otos app.
A versioned authored appearance must work without a camera-rendered companion or
embedded preview. Camera-rendered HEIFs are offline appearance anchors; they are
neither inference inputs nor physical colour ground truth. Native lens correction
and authored colour/tone must have independent ownership and diagnostics.

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

Offline calibration owns reference access, role/date-group validation, bounded
fitting, explicit authored-anchor priorities and diagnostic capacity recipes.
Authoring and broad training have disjoint capture-date groups; fitted anchors
define appearance and never count as independent validation. Reduced aligned observations initialize
models; actual native HEIFs validate photographic claims. Capacity recipes exclude
frozen appearance regions from both spatial and palette sampling. They are not
runtime selectors. Offline final-display fitting names encoded-RGB or normalized D65 CIELAB error
coordinates explicitly; neither replaces actual native-output validation. Region
measurement requires a fixed RAW-derived geometry baseline independent of candidate
colour and reports unregistered colour, measured local correspondence/support and
inconclusive facts separately. Confident native-detail matches are retained;
ambiguous matches get one fixed Gaussian-scale retry under the same confidence
rules. Relative correspondence uncertainty is a gate; moving both colour patches
together is a spatial-residual diagnostic. This preserves the distinction between
unreliable geometry and nearby content having different appearance error. Its
registration never becomes a deployed lens correction.

## Alternatives

- App integration: rejected for this increment because the task is algorithm
  development outside the app; no catalog/window/export owner is changed.
- Camera-preview-assisted matching: rejected because it cannot create the authored
  look when the camera has not produced a render and violates the input boundary.
- Reusing the saved encoded-RGB curve/LUT as the final architecture: retained only
  as a named comparator; it combines tone and colour without independent controls.
- Automatically adding local correction or predicting per-image coefficients:
  deferred until valid native capacity and unseen-group benefit demonstrate need.
- A third-party runtime/training library: unnecessary for the implemented compact
  family; Core Image, Metal and Accelerate provide the required concrete owners.

## Consequences and boundaries

The toolchain is Swift 6 with complete strict concurrency. The standalone harness
is independently buildable and testable; it shares only the repository's logging
facade with the app. Numerical conformance does not certify a photographic recipe.
Current research records the accepted fixed recipe, rejected candidates, three
inconclusive regional comparisons and the limits of fresh-shoot independence. This ADR owns implementation boundaries, not the final
look, camera profiling, custom lens profiles, app integration or future automation.
