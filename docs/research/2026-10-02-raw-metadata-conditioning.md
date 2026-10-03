# Shared RAW white-balance/ISO conditioning

## Hypothesis and boundaries

The fixed profile cannot account for capture-condition-dependent residuals.
Test a single shared predictor using native RAW neutral temperature and EXIF ISO;
never use a target image at inference, camera embedded images anywhere, or lens
identity as a colour predictor. Retain RAW9, native lens handling, normalization,
base profile, actual HEIF encoding and all original measurement gates.

Fit 262 date-disjoint verified training captures with 655,000 contract-3
observations. The same baseline and bounded 3-cubed correction fields are used by
a constant control and six-field temperature/ISO predictor. Each coefficient is
bounded to +/-0.25 encoded RGB; convex reciprocal-temperature/log-ISO blending
preserves those bounds and continuity, capped outside the declared knots. Fixed
ridge 2 and neighbour penalties 10; no target-driven parameter sweep. Offline
RGB least squares is an initializer, not the native HEIF comparison objective.

## Frozen first screen

Nine unchanged development controls, then all 204 development captures. Constant
and combined predictors were frozen before rendering those outputs. Whole-image
limits remain mean DE00 <=2 and p95 <=5; the original fixed regions retain their
mean/correspondence gates. Reserve pixels remain untouched.

| Capture | Constant mean/p95 | RAW WB+ISO mean/p95 |
| --- | --- | --- |
| Indoor 20260706_193840 | 2.774/5.674 | 1.960/4.537 |
| Warm 20260921_124534 | 2.826/5.106 | 1.934/4.240 |
| Green 20260710_203257 | 2.770/4.703 | 3.375/5.572 |
| Cyan 20260921_124945 | 1.955/6.753 | 1.872/6.336 |
| Forest 20260921_162050 | 2.446/7.794 | 2.576/7.870 |

Combined predictor passes 5/9 whole-image limits; constant passes 3/9. Warm face
and towel mean errors improve to 1.673 and 1.470 and pass their frozen checks.
Green face worsens to 2.645; cyan remains 14.095. Foliage still fails, and three
regions remain inconclusive. No candidate is promoted from this screen.

## Input ablation

One bounded follow-up removes one metadata dimension at a time, retaining data,
base and priors. White-balance-only passes 4/9: warm mean 1.932, indoor 2.172.
ISO-only passes 3/9: warm 2.174, indoor 2.026. Combined is needed to clear both
whole-image cases in this screen, but all variants worsen green compared with
the fixed baseline. This does not establish either feature is needed universally.

## Decision and next feedback

Implementation exposes reproducible experimental fitting and RAW-only rendering;
no accepted model replaces the baseline. Complete the frozen 204-image combined
check, report every resolved and introduced failure, then diagnose remaining
source coverage/native objective/condition ambiguity. Do not enlarge the model
or promote it from average error. Any later variant gets a named hypothesis and
separate freeze before evaluation. Native detail and independent acceptance
remain open. Private manifests, coefficients, HEIFs and logs are ignored under
build/sony-paired-corpus/; no external dataset or new dependency is used.

## Completed broad development check

204 planned/completed native exports, zero operational failures. Fixed-profile
baseline passes 173; combined RAW WB+ISO passes 186. Thirteen failures resolve and
zero new whole-image gate failures appear. Mean error nevertheless worsens on 80
captures, including the green control; this is not universal improvement. No
reserve pixels were consumed. Known regional failures remain and block promotion.

| Remaining capture | Mean DE00 | p95 DE00 | ISO |
| --- | --- | --- | --- |
| 20260523_134923 | 2.125 | 5.233 | 320 |
| 20260524_162204 | 2.191 | 4.739 | 1250 |
| 20260704_211430 | 2.844 | 5.769 | 12800 |
| 20260706_193728 | 2.060 | 5.113 | 12800 |
| 20260706_194332 | 2.173 | 5.277 | 12800 |
| 20260708_184432_001 | 1.709 | 5.709 | 100 |
| 20260708_184439_001 | 1.701 | 5.510 | 100 |
| 20260710_203257 | 3.375 | 5.572 | 6400 |
| 20260920_164418 | 1.818 | 5.332 | 100 |
| 20260920_164921 | 1.913 | 5.985 | 100 |
| 20260920_164922 | 2.014 | 6.501 | 100 |
| 20260920_164922_001 | 2.080 | 6.830 | 100 |
| 20260920_164923 | 2.100 | 6.996 | 100 |
| 20260920_164924 | 2.043 | 6.799 | 100 |
| 20260921_124945 | 1.872 | 6.336 | 640 |
| 20260921_124945_001 | 1.867 | 6.109 | 640 |
| 20260921_131352 | 2.153 | 5.026 | 100 |
| 20260921_162050 | 2.576 | 7.870 | 100 |

The hardened fitting implementation reproduces the frozen model bytes exactly.
Rendering the indoor control from an isolated input directory containing only RAW
produces identical Image I/O native integer-pixel hashes (4128x6192, 16-bit decoded
components; this is not the encoded bit depth). Independent floating-point colour
conversion differs by at most 1.192e-7 per channel; low-frequency and unblurred
DE00 differences are zero. Synthetic tests cover convex endpoint interpolation,
CPU/Metal agreement, required-input rejection, invalid coefficient models,
duplicate metadata, forbidden evaluation roles and output overwrite rejection.
All fixtures run from the source used for this increment. Fitting emits a named
Rendering signpost and structured operation with kind, count and elapsed time.

Decision: retain as an experimental candidate and reproducible implementation;
do not promote or close Plan0105. Next diagnose green/high-ISO residuals versus
WB representation, and separately investigate cyan colour coverage and daylight
correspondence/detail. Native temperature alone omits the available tint axis;
a same-capacity temperature/tint versus temperature/ISO experiment is justified
if its knots are frozen from training metadata and it retains the broad gate.
This is a hypothesis, not a causal explanation or an accepted adjustment.
