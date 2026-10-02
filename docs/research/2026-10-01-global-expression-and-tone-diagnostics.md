# Global expression and tone diagnostics for camera matching

Date: 2026-10-01. Development evidence for Plan 0105; no new runtime recipe is
accepted. Camera targets are required offline, excluded from inference.

## Questions and frozen factors

On seven original whole-image failures, test whether the existing per-image
5-cubed colour field can express the target with fixed baseline tone. Compare two
predeclared fitting objectives: encoded RGB and normalized D65 Lab (a DE76 proxy,
not DE00). Keep input, bounds 0.5, smoothness 0.00003, solver and geometry fixed.
Fit full sampled palettes explicitly; these pixels are expression evidence only.

Then compare fixed-tone/Lab-field expression with four per-image tone controls
(contrast, pivot, skew, saturation) initialized by the existing two-start RGB
solver, followed by the same Lab colour fit. EV, WB and hue preservation remain
fixed. This is sequential fitting, not a claimed joint optimum. No local operation
or new processing capacity is introduced.

Actual native 10-bit HEIFs supply historical whole-image mean/p95 scores. A fixed
5-by-4 grid uses existing independent RAW-derived geometry for aligned regional
scores. All excluded/uncertain tiles remain reported. Grid failures count mean
DE00 >2 among low-sensitivity tiles and are development diagnostics, not additional
final acceptance regions.

## Results

| Capture | Baseline whole mean/p95 | RGB colour fit mean/p95 | Lab colour fit mean/p95 | Tone then Lab fit mean/p95 |
| --- | --- | --- | --- | --- |
| 20260531_125558 | 2.650 / 5.278 | 1.547 / 3.391 | 1.465 / 3.386 | 1.610 / 3.570 |
| 20260704_114757 | 2.013 / 5.055 | 1.876 / 4.951 | 1.901 / 5.037 | 1.927 / 5.093 |
| 20260706_193840 | 2.520 / 4.974 | 1.983 / 4.497 | 1.972 / 4.478 | 2.028 / 4.534 |
| 20260707_164029_002 | 2.240 / 5.126 | 1.244 / 3.140 | 1.184 / 2.975 | 1.359 / 3.236 |
| 20260708_184432_001 | 2.044 / 5.795 | 2.311 / 6.555 | 2.394 / 6.700 | 2.379 / 6.500 |
| 20260711_142631 | 2.071 / 5.312 | 2.257 / 5.385 | 2.316 / 5.299 | 2.159 / 5.275 |
| 20260723_175925_001 | 2.123 / 5.531 | 1.073 / 2.868 | 1.099 / 2.975 | 1.161 / 2.799 |

| Capture | Reliable tiles / 20 | Baseline tile failures | RGB fit | Lab fit | Tone then Lab |
| --- | --- | --- | --- | --- | --- |
| 20260531_125558 | 20 | 16 | 0 | 0 | 1 |
| 20260704_114757 | 20 | 5 | 1 | 1 | 1 |
| 20260706_193840 | 18 | 16 | 10 | 9 | 11 |
| 20260707_164029_002 | 20 | 9 | 1 | 0 | 2 |
| 20260708_184432_001 | 16 | 3 | 5 | 6 | 7 |
| 20260711_142631 | 18 | 2 | 10 | 8 | 7 |
| 20260723_175925_001 | 16 | 7 | 0 | 0 | 0 |

The field can improve several fitted images substantially. Neither fitting
objective dominates; neither establishes capacity on every difficult case. A
whole-image mean passing still leaves regional failures. Sequential tone
initialization is not a general improvement and is rejected for promotion.
No per-image target-fitted recipe becomes an inference lookup or selector.

## Limits and next feedback loop

The sampled fitting path applies the look to reduced linear scene pixels; runtime
applies it at native resolution before display reduction. Nonlinear operations do
not commute with reduction. The observations also use one offline homography,
a compact spatial/source-palette sample and finite optimization. Native HEIF
checks expose the result, but a failed initializer does not prove that the global
family cannot express the camera rendering. Verify native-order loss and sampling/
convergence on recurring failures before adding a predictor or local processing.

The indoor July 6 capture is verified ISO 12800; remaining outdoor failures include
ISO 100. Do not explain all failures with noise or all with tone. Inspect colour
residual, native detail and clipping separately. Known random-noise differences
must not silently redefine the colour target or relax its gates.

Several originals became dataless between runs. The guard rejected their reads;
explicit non-blocking requests and availability-based resumption completed all
seven native checks. Availability is a point-in-time fact. No original was written,
no dataless read was used to force provisioning, and all fits/outputs are private.

The public diagnostic owners retain withheld-region mode and explicitly report
whole-image expression scope with `validationEvidence: false`. Fixtures verify
withheld-target mutation independence, whole-image response to included target
mutation, honest report scope, role rejection and no overwrite. Comparison
calibration also rejects acceptance roles. These establish tool behaviour, not
photographic generalization.

Private evidence: `/tmp/otos-sony-harness/paired-corpus-v2/expression/`,
`tone-expression/`, their contracts and logs; `capacity/grid-baseline/`; standalone
verification `measurement-final-build.log`. The original failures remain in scope.
