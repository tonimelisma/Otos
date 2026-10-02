# Native profile objective and residual feedback

Date: October2,2026. Plan0105 development diagnosis. No inference model changed,
no acceptance pixels used, and no lens defect learned into the colour model.

## Frozen experiment

The prior point-RGB fit does not certify native HEIF capacity. This pass evaluates
the existing format-2 profile after native Metal application, colour-managed
Lanczos reduction and encoded-space Gaussian sigma1.2. Fixed corresponding regions
sample every eight evaluation pixels with inset8 and equal-region weights. There
is no source-noise or target-error exclusion. The direct objective is meanDE00
plus0.25times the weighted worst-five-percent mean; original acceptance gates stay.

Two initializers are compared: the saved shared profile and the previous native
joint per-image model. Four cases are frozen before fitting: high ISOJuly6,
daylightJuly8/11 and the passingMay23control. Six affine directions scale each
channel's curve and LUT together and add constant-LUT offsets before clamp.
Gain bounds0.5–2 and offset bounds+/-0.1; two passes use gain logsteps0.04/0.02
and offset steps0.01/0.005, giving25native trials. This leaves the runtime family,
source decoder controls and curves/LUT representation unchanged.

The residual maps subsequently show opposite signed colour biases by brightness
in the indoor image: many middle/dark bins have positive delta-b, while several
bright areas have negative delta-b. A second frozen experiment adds three smooth
channel-curve directions within the same model: delta*4*t*(1-t), t the original
bounded knot value. Bounds+/-0.1 and gain>=0.5 preserve a monotone base curve.
Two curve steps0.04/0.02 produce37trials. This specifically tests curve shape
rather than adding an unmotivated runtime stage.

## Actual native HEIF results

| Capture / initializer | Before mean/p95 | After affine mean/p95 | Added curve directions |
| --- | --- | --- | --- |
| July6highISO / shared | 3.056 / 6.009 | 2.734 / 5.193 | No accepted bend; same output |
| July6highISO / joint | 2.459 / 5.974 | 2.467 / 5.879 | No accepted bend; same output |
| July8 / shared | 1.740 / 5.718 | 1.740 / 5.718 | No accepted bend; same output |
| July8 / joint | 1.820 / 6.170 | 1.820 / 6.170 | No accepted bend; same output |
| July11 / shared | 1.581 / 4.858 | 1.581 / 4.858 | No accepted bend; same output |
| July11 / joint | 2.059 / 6.839 | 2.074 / 6.338 | No accepted bend; same output |
| May23control / shared | 0.980 / 1.963 | 0.980 / 1.963 | No accepted bend; same output |
| May23control / joint | 0.941 / 2.334 | 0.941 / 2.334 | No accepted bend; same output |

No new failing case passes whole-image limits. The shared indoor fit still fails
all18fixed reliable region means; the joint indoor fit fails14of18. The unchanged
sharedJuly11profile and both controls retain passing colour means, without
establishing full photographic/native-detail acceptance. Candidate sensitivity is
still checked separately: do not silently drop a newly sensitive region from the
frozen baseline set. In particularJuly8joint retains16baseline-eligible regions,
while one candidate-region sensitivity becomes too high.

The native fitted objective can improve while historical unregistered whole-image
mean worsens. These are different weightings/coverage, and those worse means remain
reported. Neither initializer nor the two small coordinate passes prove a global
optimum. The extra curve directions all remain zero: reject this bounded change
rather than add more ad hoc controls or promote per-image recipes.

## Residual localization and independent boundaries

The new actual-HEIF audit uses the declared baseline report/image hash and fixed
correspondences. Unknown regions are gray; unregistered whole-image residuals are
reported separately. It computes pixelwise signed Lab/error summaries in fixed
lightness bins (<25,25–60,>=60). These diagnostic bins have no acceptance threshold.
No statistical noise/camera-detail conclusion is inferred from a low mean alone.

July8shared has22,531whole-image pixels aboveDE00five;8,590are inside fixed reliable
regions. About62percent of that tail is outside reliable coverage. Its registered
map visibly emphasizes many edges. This is evidence to investigate correspondence
and optical/detail contributions, not proof that all residuals are geometry and
not permission to excuse the whole-image p95failure. July11shared has17,505such
pixels,16,813inside reliable coverage; it cannot be explained by the same coverage
argument. HighISOshared has22,788,with20,328inside reliable coverage.

The indoor photograph visibly differs in noise/texture as well as colour. Signed
middle/dark casts and opposite bright casts are measured, but a precise split
between colour error, camera noise and Apple denoising is not yet established.
The native-point reports also record combined input-domain clamping:0.66percent
of accepted high-ISO samples,16.90percentJuly8,7.997percentJuly11 and31.36percent
July4. These sparse source samples are not whole-image coverage, and the combined
statistic does not distinguish negative input channels from channels above1.25.
It warrants an input-clipping attribution audit; it does not establish causality.

## Primary-source refresh: RAW9 controls

Apple's [WWDC26RAW9session](https://developer.apple.com/videos/play/wwdc2026/305/)
confirms combined CoreML demosaic/denoise, an effective luminance-noise control,
automatic colour denoising with no effect from colorNoiseReductionAmount, and
unsupported detail/moire controls. Therefore changing a colour-noise property
cannot recover camera grain. RAW9remains the user's required foundation. Any
future detail/input change must be separately measured and invalidate derived
training inputs when appropriate; this pass changes none of those controls.

## Feedback decision and next bounded work

Do not continue adding scalar knobs. The next capacity experiment fits a coupled
colour-field correction within the existing profile, against the same native
low-frequency observations. Use a coarse3-cubed additive basis interpolated into
the existing9-cubed table, retain curves/source/geometry and all original gates,
and solve its81directions jointly with bounded native finite-difference Jacobians
and actual-objective line search. Calibrate derivative step/quantization and
report finite budgets/convergence rather than claiming full-family incapacity.
Start with the genuine high-ISO colour failure and the passing control. Keep
July8's coverage/edge attribution and source clipping as separate diagnostics;
none can be fixed by training a lens warp into colour.

Successful individual expression proceeds to shared RAW-only training/parameter
selection. Failed or numerically unstable expression returns to input, clipping,
noise, correspondence or solver attribution; it does not automatically authorize
local processing or a larger predictor. This follows Plan0105's existing feedback
branches and changes no final gate or target.

## Reproduction and verification

Commands and fixed scopes are in the standalone README. Private outputs/manifests
stay outsideGit and original media folders. The shared native observation/loss
extraction reproduces all25trial losses and the fitted recipe exactly for the
previous passing-control diagnostic. Synthetic fixtures verify zero identity,
known affine CPU/Metal colours, alpha, curve knot colours/monotonicity, invalid
gains and acceptance/wrong-baseline rejection before nonexistent original reads.
See [preceding normalization/profile evidence](2026-10-02-native-normalization-and-profile-capacity.md)
and [comparison contract](2026-10-01-camera-match-comparison-method.md).
