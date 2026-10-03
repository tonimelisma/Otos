# Native region feasibility versus pooled fitting loss

Date: October 3, 2026. Plan0105 capacity diagnosis, not inference or acceptance.
Sensor RAW9, fixed RAW geometry, existing field capacity and all HEIF colour limits
remain unchanged. Only separate verified HEIF targets are used offline.

## Question and contract

The corrected pooled mean/tail fit passes the whole cyan frame and its face/white
regions, but cyan and one reliable grid region remain just above meanDE00two.
A small pooled score does not establish every-region feasibility. The bounded
solver repair does not change those outcomes, so its investigation is closed.

Compare that frozen result with one feasibility-first fit on the same original
three plus seventeen fixed grid regions. Fourteen remain reliably corresponding;
unknown/sensitive regions are excluded from fitting and retained in scoring.
No field enlargement, solver-budget extension or target-dependent region selection.

The feasibility objective is the equal-region mean of squared positive excess
above region meanDE001.9. This is a stricter fitting target than acceptance2.0,
allowing margin for native HEIF encoding/sampling. Zero loss requires every fitted
region to meet that target; a good region cannot pay for a failure elsewhere.
Region membership is carried explicitly by the shared native sampler.

The existing positive prior matrix regularizes the proposed displacement through
curvature. An absolute model penalty does not compete with feasibility. This
change is explicit: it is not the previous pooled objective with hidden reweighting.
The actual feasibility loss accepts every step. Six outer iterations, up to twenty
halving trials, coefficient bounds and native observation order remain fixed.
Stop on sampled-region satisfaction, the finite budget or a numerical/line-search
failure. No objective-target, field, step-size or iteration sweep follows this fit.

## Mathematical and verification limits

[Boyd and Vandenberghe, optimization problems and feasibility](https://stanford.edu/class/ee364a/lectures/problems.pdf)
distinguish fitting objectives and constraints; their convex guarantees do not
apply automatically to our nonlinear native pixel pipeline. The squared positive
excess is a diagnostic feasibility objective, not a certified constrained solver.
Its sample-level success is not photographic acceptance or independent validation.

Observable fixtures check a failed region's positive loss despite another good
region, zero loss/zero influence for already feasible regions, correct region
identity for the144-pixel cyan object, and early sampled-target termination.
Final HEIF whole-image, original regions and all grid outcomes remain mandatory.
Every uncertainty is reported; there is no lens-error correction or runtime target
access. If photographic failures persist, retain them and reopen their measured
cause rather than label a lower loss success.


## Bounded result and next decision

The fit uses1021 native observations in245.87seconds. Its six-step budget is
exhausted: sampled loss0.0013701, white-shirt mean1.9194 and grid-4-1 mean2.0371
still miss the stricter1.9 fitting target. This is not a convergence certificate.

Actual native HEIF whole-image mean/p95 is1.8977/4.9473, passing both original
limits. Face1.5579, white shirt1.8706 and cyan1.4847 pass their original mean and
supplementary diagnostics with reliable fixed correspondence. The old pooled fit
had cyan2.1091. This demonstrates expression of the original cyan look inside the
existing field without enlarging it. It is target-assisted fitted evidence only.

All twenty declared regions: thirteen pass, four fail and three inconclusive.
One reliably corresponding grid region still fails colour at2.0464; three others
fail correspondence sensitivity. Three unknown regions remain inconclusive.
Whole-image p95 passes with little margin. Visual comparison at the declared
reduced scale shows close appearance, but is not native-detail acceptance.

The objective and absolute-prior role changed together. These results do not
independently assign cause to either change. Do not claim every-region/global
capacity or photographic acceptance from the original three regions passing.
The bounded expression question for cyan is answered; close it without further
iteration, target or floor sweeps. Proceed to shared RAW-only prediction/training,
keeping this witness private and preserving original hard-region gates, native
quality, all204 development outcomes and untouched independent acceptance.
