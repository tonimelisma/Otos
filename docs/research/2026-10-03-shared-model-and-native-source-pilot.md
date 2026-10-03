# Shared-model rejections and native calibration source pilot

Date: October 3, 2026. Plan0105 development evidence; no accepted recipe.
Only sensor RAW9 and separate verified VV2 HEIF targets participate. Embedded
camera images and untouched acceptance pixels are excluded.

## Fixed question and prior experiments

The existing bounded field can express the original cyan/face/white rendering in
a target-assisted native fit, but the shared RAW-only predictor does not learn it.
That witness cannot certify automatic inference, all regions or native detail.

Two bounded capacity/metadata hypotheses were tested on the same463 training
captures across36 assigned dates,1157500 endpoint observations, equal20000
observation mass per date, frozen base and unchanged native export/score gates.
Dates are weighting groups, not certified independent shoots. The fixed nine-image
screen precedes original regions and full204 evaluation; a candidate must preserve
passing controls and clear a named failure before expansion.

| Variant | Result | Decision |
| --- | --- | --- |
| WB × ISO × native tint,12 shared3-cube fields | Five of nine pass, no additional passing case. Green mean/p95 3.117/5.279 still fails; cyan1.881/6.455 still fails. Indoor1.950/4.501 passes. | Reject; do not sweep tint knots or run full204. |
| Five-cube WB × ISO, six fields | Four of nine pass. Previously passing stone control now2.003/4.431; green3.623/6.215 is worse. Cyan1.807/5.881 still fails despite improvement. | Reject; do not sweep cube degree, priors or run full204. |

The tint endpoints0.1473024/20.2918472 were already frozen from initial262
training metadata percentiles; no development target selected them. The finer
field normalized mean-node/edge-gradient energy explicitly: ridge54/125,
colour135/(300 × 0.25²), metadata270/125. It did not use a regularization sweep.
Actual native HEIF outputs established these failures; training loss did not
substitute for photographic results. Private prototype executables/models remain
experimental; neither enlarges the committed inference format.

## Native source consistency hypothesis

Shared export previously set CIRAWFilter scaleFactor to the reduced evaluation
scale, while runtime uses scaleFactor1. Force full-resolution encoded RAW9 pixels
through the existing native owner before reduction. Keep the point grid, blur,
base, bounds, metadata axes and fitting priors fixed. This corrects a source
contract difference; applying nonlinear look to averaged RGB remains approximate.
RAW-only preparation audits previously measured this mismatch, without reading
camera targets. They do not establish it as the cause of matching failures.

Freeze100 training captures across all36 dates by name-only hash and round-robin
selection before new exports. Compare old and native preparations on exactly
these captures, with the same equal-date mass. Both variants use the same nine
controls; sample-size changes cannot be credited to preparation. The reduced
control passes five of nine: green3.160/5.401, cyan1.942/6.311,
foliage2.597/7.883 and daylight1.718/5.699 remain failures.

Native exports use source-stamped sample contract4 (model-domain) or3 (interior).
Old reduced exports are rejected. Lens-supported and enabled facts stay separate;
unsupported Apple lens correction is reported, not reclassified as unsupported
sensor RAW or fed to a colour predictor. Originals remain read-only and guarded.

### Reproduced opacity boundary

The first native export retained zero samples. Diagnostics measured native alpha
0.9995117..1.0, then aligned/blurred maximum0.9983608, below the existing0.999
sample-support cutoff. Old reduced export retained2500 samples for that capture.
Native sensor pixels were finite; this was not a colour or registration acceptance
failure. The new path validates all native pixels and alpha above0.999, then marks
that verified opaque source before resampling. Runtime look application likewise
emits opaque pixels. Registration still creates excluded borders; genuinely
transparent native input remains rejected. An observable constant-frame reduction
fixture and a transparent-frame rejection fixture verify this boundary. No
colour limit, alignment mask, sample threshold or model capacity was relaxed.

## Pilot outcome and next decision

All100 exports completed in363.33seconds,250000 observations, zero operational
failures after the opacity repair. Measured maximum resident size1.349GB, peak
footprint2.151GB and zero swaps. The native-input equal-date fit took437.6ms.

Actual native HEIF screen remains five of nine, with no lost pass and no cleared
failure. Green3.069/5.457, cyan1.910/6.257, foliage2.499/7.813 and
daylight1.713/5.698 still fail. Seven means improve and two worsen; these averages
do not clear gates. Reject this pilot as a promoted photographic candidate and
close reduced-decoder preparation as a sufficient explanation of those failures.
Keep the corrected full-native source contract as the consistent training input;
that architectural correction is distinct from camera-matching acceptance.
No full204 run or reserve pixel use follows this failed screen.

The shared RAW-only learning problem remains open. Metadata and colour-capacity
sweeps are exhausted under these bounded contracts. The existing research's next
adaptive hypothesis is RAW-derived image context predicting the same bounded
correction field, compared against metadata conditioning. Exact native
look-before-reduction fitting is another unresolved approximation; neither has
been shown to explain the remaining failures. Freeze any next experiment's
features, objective and gates before target-based selection. Do not call the
current model or Plan0105 complete.

## Code audit and next-work boundary

The current shared fitter constructs a bounded quadratic encoded-RGB residual
from averaged source points (`ConditionalProfile.fitConditionalProfile`). The
renderer applies the nonlinear profile at native resolution before HEIF encoding
(`SonySensorRAWHEIFRenderer.render`). The scorecard decodes actual HEIF, reduces
and computes pixelwise DE00 with an explicit Gaussian sigma; the training exporter
retains a Core Image blur radius. These are demonstrably different objectives and
operation orders. Their existence is verified; their share of remaining error is
not established by this pilot.

The successful cyan expression witness changes both the fitting objective and
absolute-prior role, and still has a reliable grid failure. It cannot prove that
metadata is the sole bottleneck or that every failure supports a global predictor.
Before implementing another adaptive variant, quantify the shared surrogate's
agreement with actual native colour/region outcomes on the already-used controls
and retain per-class expression limits. RAW image statistics remain a justified
candidate from prior research, not a verified solution. Current photographic,
native-detail and independent-acceptance gates all remain open.
