# Native normalization, fitting objective and camera-profile capacity

Date: October 2, 2026. Development diagnosis for Plan 0105; no matching recipe
promoted and no acceptance pixels used. Inference still uses RAW 9 and frozen
RAW-only models outside Otos. Lens ownership and all matching gates are unchanged.

## Questions and fixed boundaries

1. Do existing input gains help the four-control native tone diagnostic?
2. Does optimizing CIEDE2000 rather than squared normalized Lab improve the
   actual native HEIF comparison?
3. Can the existing unrestricted channel-curve/9-cubed camera-profile family
   express the residuals with native sampling and a jointly solved interpolator?

Eight regression images cover seven previously failing daylight/high-ISO cases
and one passing control. Fixed RAW geometry, region correspondence/sensitivity,
source development, lens settings and output ownership are retained. Target-assisted
per-image fits are expression witnesses, never automatic recipes or validation.
The historical unregistered whole-image scores below cannot attribute every error
pixel to colour. Region checks retain candidate-independent native correspondence;
unknown/high-sensitivity areas remain reported rather than counted as passes.

## Existing normalization controls and direct objective

Two fixed coordinate passes use contrast, pivot, skew and saturation: 17 native
evaluations. Adding existing red/blue linear-BT.2020 input gains gives 25; green
and exposure are fixed. Gain log steps are 0.04 and 0.02; tone steps 0.08 and 0.04.
These gains are an input-balance experiment, not sensor-WB reconstruction.
The field and all native decoder controls stay fixed. The direct objective is the
equal-region pixel mean DE00 plus 0.25 times the weighted worst-five-percent mean.
This does not change the original mean/p95 acceptance limits. The alternative
normalized-Lab squared objective is a DE76 surrogate.

| Capture | Frozen whole mean/p95 | Tone + gains, Lab | Tone + gains, direct DE00 | Direct fit region mean failures / fixed reliable regions |
| --- | --- | --- | --- | --- |
| May 23 passing control | 1.440 / 2.966 | 1.313 / 2.447 | 1.167 / 2.197 | 0 / 20 |
| May 31 | 2.650 / 5.278 | 1.902 / 4.362 | 1.902 / 4.362 | 3 / 20 |
| July 4 | 2.013 / 5.055 | 1.776 / 4.474 | 1.736 / 4.417 | 1 / 20 |
| July 6 high ISO | 2.520 / 4.974 | 2.313 / 4.489 | 1.942 / 4.190 | 7 / 18 |
| July 7 | 2.240 / 5.126 | 2.305 / 5.047 | 1.942 / 4.612 | 8 / 20 |
| July 8 | 2.044 / 5.795 | 1.985 / 5.920 | 2.005 / 5.776 | 1 / 16 |
| July 11 | 2.071 / 5.312 | 2.093 / 5.010 | 1.988 / 5.065 | 3 / 18 |
| July 23 | 2.123 / 5.531 | 2.078 / 5.395 | 1.950 / 4.762 | 7 / 16 |

Five of seven failures meet the historical whole-image limits with the direct
objective. Every one still fails at least one fixed reliable region; no matching
acceptance follows. Lower Lab proxy loss can worsen actual DE00. Optimizer choice
matters, but compact controls alone have not solved the problem.

## Existing camera-profile family and native expression fit

The saved format-2 baseline uses 49 monotone encoded-sRGB knots per channel plus
an unrestricted smooth 9-cubed RGB residual LUT. Its input contract differs from
the scene-linear authored family: RAW 9 mapped native output converted to encoded
extended sRGB, clamped to [0,1.25]. Seven of eight images improve in whole-image
mean with this existing shared model versus the frozen authored baseline, while
high ISO worsens. This comparison does not isolate neutral protection or curve
capacity, since the input boundary and tone representation also differ.

The new offline fit samples actual native source pixels before reduction. A
24-by-24 lattice per reliable fixed region has an eight-evaluation-pixel inset.
Target interpolation uses fixed measured correspondence. A source-only nine-point
range test at offsets -4,0,4 excludes variation above 0.03 in any encoded channel.
All excluded areas remain in output measurement. This rule rejects 9,150 of 10,368
potential high-ISO points, retaining 1,218; that substantial exclusion is a sampling
limitation, not proof of adequate palette coverage.

Sequential fitting retains the historical binned isotonic curve initializer and
smooth LUT solve. Joint fitting uses the actual two-knot/eight-node interpolation
basis and jointly optimizes 778 coefficients per output channel. Curve identity
weight 1, LUT ridge 2 and axis-neighbor smoothness 10 are retained. Monotone
projected accelerated gradient has a fixed 600-iteration/channel budget and
reports the projected-gradient infinity norm; convergence requires below 1e-6.
Output clamp, perceptual colour and HEIF encoding are outside this RGB surrogate.
A synthetic known-optimum test recovers identity from a biased initializer to
7.74e-9 maximum RGB error; all channels satisfy the gradient threshold.

| Capture | Saved shared profile mean/p95 | Native sequential fit | Native joint fit | Joint region mean failures / fixed reliable regions |
| --- | --- | --- | --- | --- |
| May 23 control | 0.980 / 1.963 | 0.963 / 2.369 | 0.941 / 2.334 | 0 / 20 |
| May 31 | 1.781 / 4.092 | 1.695 / 4.885 | 1.600 / 4.836 | 2 / 20 |
| July 4 | 1.570 / 4.261 | 2.006 / 5.183 | 2.073 / 5.216 | 3 / 20 |
| July 6 high ISO | 3.056 / 6.009 | 2.445 / 6.126 | 2.459 / 5.974 | 14 / 18 |
| July 7 | 1.381 / 3.489 | 1.754 / 4.813 | 1.789 / 4.859 | 5 / 20 |
| July 8 | 1.740 / 5.718 | 1.835 / 6.174 | 1.820 / 6.170 | 0 / 16 |
| July 11 | 1.581 / 4.858 | 2.047 / 6.595 | 2.059 / 6.839 | 7 / 18 |
| July 23 | 1.458 / 4.776 | 2.005 / 6.895 | 1.755 / 6.684 | 5 / 16 |

Actual native HEIFs supply every table score. Three of eight joint fits meet the
whole-image limits; two of those still fail reliable regions. July 8's passing
reliable-region means do not excuse its whole-image p95 failure or establish the
cause of errors outside reliable coverage.

All three high-ISO channels converge to the declared RGB tolerance; most other
fits hit the finite budget in at least one channel (largest reported norm about
3.09e-5). Neither small gradient nor improved RGB loss guarantees lower HEIF DE00.
The high-ISO result rules out unfinished optimization as the explanation for
that particular regularized-surrogate failure. It does not prove global-profile
incapacity: point sampling, noisy exclusions, regularization and objective mismatch
still limit the experiment. Fits take about 4.9–6.0 seconds each on this host;
full native rendering/region checks are measured separately.

An initial batch accidentally supplied a different image's grid report and was
stopped and marked invalid. None of its results enter these tables. The fitting
command now verifies the report SHA256 against the declared geometry baseline;
wrong baselines, acceptance roles and existing destinations are rejected before
source fitting. The corrected batch uses explicitly verified per-image inputs.

## Reserve and feedback decision

A filesystem-only refresh found 229 new named RAW/HEIF candidates across six dates.
They were frozen as acceptance candidates before metadata or image-byte reads.
There is no exact-image or date overlap with the conservative 568-image prior-use
ledger. Deliberate provision followed by guarded metadata-only audit verified 208
Sony ILCE-6700 same-capture/VV2 SDR-sRGB pairs; 21 remain unavailable, none rejected.
No image pixels were decoded for fitting or viewing. A two-hour grouping rule
produces seven temporal candidates, not ten independently checked shoots.
The reserve stays pixel-untouched; metadata and temporal grouping do not certify
semantic independence or fulfil the final acceptance gate.

The next bounded experiment changes fitting observations/objective, retaining the
existing capacity. Compare point-RGB fitting with low-frequency observations
formed after the actual native look, audit source sample retention and palette
coverage, and check actual native HEIFs under all original gates. Start with high
ISO and the unresolved daylight cases, retaining the passing control; then check
original warm-face, indoor and clothing controls. Do not add local processing or
RAW-only parameter prediction on the strength of these failed surrogates. A
successful per-image fit proceeds to shared training/automatic selection; a
persistent failure requires attribution to input, clipping/detail, solver,
coverage or truly spatial residuals before increasing capacity.

## Reproduction and source context

Use the standalone harness README for commands. Private manifests, fits, images,
reports and prior-use ledgers stay outside Git and original media folders. No
coefficients in either saved inference model changed. The calibration math
extraction reproduces the old executable's model exactly on the same 199 valid
training exports (maximum curve and LUT difference zero).

This diagnostic follows the model-capacity ladder and convergence caveats in
[original Sony methods](2026-09-27-sony-matching-methods.md), the
[RAW 9 calibration audit](2026-09-30-raw9-calibration-boundaries.md), the
[comparison contract](2026-10-01-camera-match-comparison-method.md), and
[native processing-order evidence](2026-10-02-native-order-fitting-diagnostic.md).
These project results introduce no universal perceptual threshold or claim to
recover Sony's proprietary pipeline.
