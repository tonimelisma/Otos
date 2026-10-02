# Native-order fitting diagnostic — 2026-10-02

## Question and boundaries

Does fitting after reducing linear RAW differ materially from the renderer, which
applies the look at native resolution before reduction? Use four already-inspected
development captures. No new model, target-dependent runtime input, lens control
or acceptance limit. This is a measured correction to the Milestone 3 initializer,
not evidence that the shared camera match is complete.

`NativeOrderDiagnostic.swift` uses the existing `NativeRAWDevelopment` and
`MetalAuthoredLook`. Its encoded sRGB output is explicitly tagged before the same
colour-managed Lanczos/half-float observation as a decoded HEIF. The supplied
actual native export independently checks that pre-encoding approximation. It is
not lossless HEIF simulation. Original bytes are guarded; output paths are validated
against media directories; acceptance roles and existing destinations are rejected.
Both operations carry rendering signposts and structured elapsed/count logging.

## Processing-order measurements

Historical unregistered 768-long-edge sigma-1.2 pixelwise DE00, frozen recipe:

| Capture | Native pre-encoding vs actual export mean/p95 | Reduced initializer vs native order mean/p95 | Actual export vs Sony mean/p95 |
| --- | --- | --- | --- |
| 20260531_125558 | 0.096 / 0.296 | 0.205 / 0.841 | 2.650 / 5.278 |
| 20260706_193840 | 0.083 / 0.234 | 0.163 / 0.297 | 2.520 / 4.974 |
| 20260708_184432_001 | 0.135 / 0.465 | 0.653 / 3.436 | 2.044 / 5.795 |
| 20260711_142631 | 0.113 / 0.323 | 0.360 / 1.756 | 2.071 / 5.312 |

The order discrepancy exceeds the observed export approximation floor, especially
on the two daylight cases whose individual colour fitting previously worsened.
This does not establish that order explains every failed fit. The export gap
includes lossy codec/quantization and observation differences; its precise
components have not been isolated. Do not call the pre-encoding observation exact.

## Bounded native-order control refinement

For the two daylight failures, compare two initializers: the frozen shared field
and the existing per-image normalized-Lab field. Within each, vary only existing
contrast, tone pivot, skew and saturation. Hold exposure/WB, hue preservation,
colour field, native development and lens controls fixed. Two coordinate passes
with log steps 0.08 and 0.04, both directions, produce exactly 17 evaluations.
This is a local diagnostic, not a claim of convergence or global model capacity.

Freeze independently measured RAW-baseline grid correspondences/reliability before
fitting. Use 16/20 and 18/20 eligible tiles respectively. Sample every eight
comparison pixels with an eight-pixel tile inset after the historical blur; fit
equal-tile normalized-Lab squared error. This is not the DE00 acceptance objective.
Excluded/uncertain areas remain reported in final native evaluation. Fitted target
pixels are expression evidence only, never held-out validation.

| Capture | Baseline mean/p95 | Native refinement, shared field | Native refinement, per-image field |
| --- | --- | --- | --- |
| 20260708_184432_001 | 2.044 / 5.795 | 2.014 / 5.916 | 2.451 / 6.698 |
| 20260711_142631 | 2.071 / 5.312 | 2.000 / 5.029 | 2.239 / 5.212 |

Shared-field fitting loss fell from 0.00096950 to 0.00084287 and 0.00147130 to
0.00102463. Native fitting took 13.79 and 11.16 seconds for 17 evaluations each.
Actual HEIFs remain 6192×4128, 10-bit, decoder 9, with supported Apple lens
correction. In the July 8 result, the mean improves while p95 worsens. July 11 is
near the original whole-image limits but still fails p95. Neither variant passes
both gates; no recipe is promoted. Recomputing colour sensitivity can change a
region's diagnostic status even with unchanged geometry; it must not silently
remove that region from the frozen fitting/checking coverage.

## Decision and next feedback loop

Adopt the native-order observation for subsequent fitting diagnostics. Reject both
bounded fitted variants for promotion. Keep the reduced-linear fit as an explicit
initializer only. The per-image field degradation persists after this local tone
correction; RAW-only parameter prediction or extra local capacity is not yet
justified by these results.

Next audit native-order colour-field sampling and convergence, including a good
control. A compact local search failing does not establish global incapacity.
Compare its actual native output and fixed-region residuals against the unchanged
baseline; retain all failures and original hard controls. Native detail/noise and
independent-shoot acceptance remain separate open gates.

## Reproduction and evidence

See the harness README for `matching-native-order-audit` and
`matching-native-order-refine`. Private artifacts live at
`/tmp/otos-sony-harness/paired-corpus-v2/native-order`, `native-order-refine` and
`native-order-refine-field`. Final standalone build/self-tests:
`/tmp/otos-sony-harness/native-order-final-build.log`. Acceptance-role rejection
for both commands and preserved-output rejection were exercised through the CLI.
All pixels/recipes fitted to particular captures stay outside Git. The checked-in
frozen recipe is unchanged. No app, UI or third-party dependency changed.
