# 0030 — Offline camera-match perceptual diagnostic

Status: accepted for experimental offline measurement; no perceptual release
threshold is accepted.

## Context

Corresponding-pixel colour differences quantify broad colour and tone, but cannot
alone establish native detail quality. The comparison audit deliberately introduces
blur, halos, noise and colour defects to test what each measurement detects.

## Decision

Use NVIDIA's BSD-3-Clause LDR-FLIP implementation as a supplementary, offline-only
experimental diagnostic. Pin the upstream revision used in each evidence report;
keep its source, binary and image outputs in the private research directory. Use
explicit pixels-per-degree conditions and retain colour error maps and native
crops beside FLIP results. SDR camera targets require the LDR mode irrespective of
their 10-bit encoding. No default viewing condition is presented as a measured
user condition, and no FLIP scalar defines photographic acceptance.

The standalone renderer, fitting implementation and Otos app acquire no FLIP
dependency. The upstream tool is invoked only on deliberate offline comparison
assets. Its PNG-based audit is a perceptual diagnostic of those preview assets;
it cannot independently certify 10-bit native HEIF colour accuracy.

## Alternatives

- Colour differences alone: retain for colour acceptance, insufficient for total
  image quality because spatial detail defects need separate measurements.
- SSIM alone: structure does not establish a colour match and depends on scale.
- DISTS/LPIPS: learned dependencies and tolerance to texture/geometric changes add
  complexity beyond the immediate alternating-image comparison requirement.
- Reimplement FLIP in Swift: adds avoidable numerical and maintenance risk before
  the experiment establishes usefulness.

## Consequences and boundaries

Record upstream licence, revision, command, input interpretation and viewing
conditions with results. Validate identity and known perturbation responses before
using the diagnostic to compare recipes. A result selects no renderer change by
itself. Research owns findings; Plan 0105 owns measurement adoption and photographic
acceptance. Lens correction, training models and runtime dependencies are deferred.
