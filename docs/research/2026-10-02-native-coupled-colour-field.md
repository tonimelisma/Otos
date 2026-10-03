# Native coupled colour-field experiment

## Question and frozen experiment

Can coupled colour directions inside the existing format-2 profile remove the
remaining registered native residual, after affine and curve-bend trials failed?
This is target-assisted per-image expression, not an inference model or acceptance.
RAW9 mapped native input, channel curves, lens handling, fixed correspondence,
region eligibility and all existing acceptance limits stay frozen.

Fit 81 RGB coefficients on an aligned 3-cubed additive field, represented exactly
in the existing 9-cubed LUT. Bounds are +/-0.25 encoded RGB. Unit neighbour-edge
quadratic penalty and 0.1 identity ridge restrain unobserved nodes. Objective is
equal-region native mean CIEDE2000 plus 0.25 times weighted worst-five-percent
mean, plus half the field quadratic penalty. Apply the full native Metal profile
before managed Lanczos reduction and sigma1.2 Gaussian observation.

Use central finite differences at0.005; compare0.0025 on all RGB components of
corner/middle/corner nodes0,13,26 before fitting. A meaningful column with
half-step weighted RMS above1e-5 and relative RMS disagreement above0.25 returns
a failed derivative diagnostic and the unchanged model. This threshold diagnoses
measurement stability, not photographic acceptance. At coefficient bounds,
differences use feasible intervals. Six bounded iteratively reweighted quadratic
steps at most; actual-loss line search fractions1,0.5,0.25,0.125,0.0625. Report
convergence, stalled search or exhausted budget distinctly. A gradient measured
before an accepted step is labelled pre-step, never final convergence.

Start with indoor high ISO20260706_193840 and the passing20260523_145654 control.
Then test remaining hard controls if the numerical witness is valid. Export native
HEIF and evaluate unchanged whole-image and original fixed-region criteria.
Keep the independent reserve pixel-untouched. No fitted model is promoted here.

## Research basis

[Ceres numerical derivative documentation](https://github.com/ceres-solver/ceres-solver/blob/master/docs/source/numerical_derivatives.rst)
explains central differences' second-order truncation error, the tradeoff of two
function observations, the roundoff floor when steps become too small, and special
handling for near-zero parameters. This motivates central differences and a
half-step measurement check; it does not establish that our chosen step is adequate
for half-float native observations. No Ceres dependency is added. The native Swift
bounded quadratic owner remains the numerical boundary.

## Numerical measurement feedback

Existing inference recipes remain unchanged.

### First measurement and bounded correction

The initial37-observation calibration stopped both images before optimisation.
HighISO strong columns had relative RMS disagreement0.035–0.082; weak bright-node
columns0.48–2.31. The passing control's strongest dark-green response disagreed
by0.260. No coefficients changed and these are not capacity failures. Peak memory
footprints were approximately32GB from autoreleased native evaluation resources.

Before the next trial, add an evaluation-scoped autorelease boundary and replace
only the diagnostic reduction's final half-float observation with float32. Native
RAW/model input and final HEIF output/scoring stay unchanged. Repeat stability at
0.001/0.0005; keep the same0.25 disagreement threshold, coefficient bounds, priors,
budget and photographic gates. Keep both experiments and report actual HEIF
outcomes independently of the numerical proxy. This is a measurement/resource
repair, not a claim that reducing steps alone establishes accurate derivatives.

The scoped boundary lowered calibration peak footprints to3.27GB (indoor) and
2.98GB (control). Float output alone still left weak-column disagreement and
retained the context's default working precision. Next use explicit float32
working precision throughout the diagnostic reduction. Report absolute RMS
step disagreement too: the numerical guard rejects relative disagreement above
0.25 only when extrapolated to the full coefficient bound it exceeds0.05DE00.
The previous near-zero relative ratios did not measure consequential response;
0.05 is a frozen numerical tolerance, not a changed image acceptance limit.
All observations and coefficients remain in the fit; no region is excluded.

### Signed colour-component curvature variant

[Ceres robust least-squares theory](https://github.com/ceres-solver/ceres-solver/blob/master/docs/source/nnls_modeling.rst)
expresses the gradient and approximate Hessian using residual-vector Jacobians.
Our inference was that differentiating one DE00 distance discards colour-direction
curvature useful to the positive IRLS quadratic. A second variant factors the
existing DE00 chroma/hue rotation term into three signed components:
`[light, chroma + rotation*hue/2, sqrt(1-rotation^2/4)*hue]`.
Their Euclidean norm equals the original DE00. The scalar reference preserves its
original arithmetic and all68 forward/reverse published reference comparisons;
component norm agreement is checked within1e-12. All other fitting contracts stay
fixed. This is our derived numerical experiment, not a Ceres implementation or a
new colour metric. The whole-image and region scorers remain unchanged.

## Measured outcomes

Eight already-used regression images, shared camera-profile initializer, distance
curvature, six native coupled steps. Values below are actual exported native HEIF.
Regions are the original baseline-eligible set, never dropped after fitting.

| Capture | Mean DE00 | p95 DE00 | Region means above2 / frozen eligible | Newly sensitive regions |
| --- | ---: | ---: | ---: | ---: |
| May23 good control | 0.6420 | 1.5631 | 0/20 | 0 |
| May31 | 1.3437 | 3.2368 | 0/20 | 0 |
| July4 | 1.3534 | 4.1009 | 0/20 | 0 |
| July6 indoor | 1.8042 | 4.2380 | 7/18 | 0 |
| July7 | 0.9978 | 2.7937 | 0/20 | 0 |
| July8 | 1.5517 | 5.5980 | 0/16 | 1 |
| July11 | 1.4041 | 4.6252 | 0/18 | 1 |
| July23 | 1.0402 | 2.7950 | 0/16 | 0 |

Seven pass whole-image limits, seven pass frozen-region mean limits, but only five
clear whole/region-mean/sensitivity diagnostics together. July8 retains its whole
p95 failure. July11's new sensitivity failure prevents an unqualified colour pass.
These are target-assisted fits, not independently selected inference recipes.
Every fit exhausted its budget; no stationary/global optimum is certified.
Native fits used1017–1022 evaluations, taking256–292seconds. Corrected native
working/output precision produced stable initial central-difference witnesses;
indoor strong-column relative disagreements were0.0007–0.0099. The largest weak
bright-column disagreement0.056 was only0.000021DE00 over the coefficient bound.
Peak measured memory remained approximately3.2–3.6GB.

The signed-component variant reached the indoor distance variant's final loss
in two steps, but the final HEIF changed little: mean1.8018/p954.2263 and the same
seven failing regions. The control mean0.6398/p951.5602 retains all20 region means
and sensitivity checks. Both still exhausted six steps. Their pre-step projected
gradients remain large despite small final loss changes; the next numerical audit
must compare that approximation with direct whole-objective finite differences,
including the changing tail membership, before interpreting this as capacity.

Original authored25-trial losses and fitted recipe are exactly unchanged after
sharing the interpolation/Lab owner and factoring DE00 terms. Standalone fixtures
also cover the known bounded optimum, continuous trilinear field on CPU/Metal,
identity/alpha, acceptance-role and wrong-baseline guards.

### Native range, quality and independent reserve

The native RAW-only range audit separates negative channels, values above1.25,
values above display one and the union of affected pixels, on the full native
source and fixed corresponding rectangles. Across eight images,1.95–13.75percent
of native pixels contain a negative channel; none exceeds1.25. Several failing
indoor regions have0–0.09percent affected pixels. Therefore source-domain clamping
cannot explain every remaining indoor failure. These are associations, not causal
proof. Earlier sparse combined clamping fractions were not whole-image fractions.

Actual HEIF evaluation and native corner inspection on indoor/control outputs
retain significant indoor texture/noise differences: the camera target has much
stronger chroma grain. Neither all-error-is-noise nor native-detail matching is
proven. Colour fitting must not silently absorb that separate boundary.

Metadata-only reserve audit read RAW capture/location facts for229 candidates,
222 with GPS fields; no acceptance pixels were decoded, fitted or inspected.
Nearby locations within the continuous September26 outing do not justify
manufacturing new independent shoots. The reserve remains208 fully verified pairs
plus21 unavailable targets and seven provisional groups across six dates. A fresh
filesystem-only scan found4198 RAWs and no additional October pairs. One deliberate
retry requested21 unavailable targets without byte faults or request errors;
those requests are not evidence of completed materialization. The ten-shoot gate
remains open. No original or private photograph/location manifest enters Git.

## Decision and next feedback loop

Retain the coupled native fitter as a valid bounded diagnostic and explicit float
observation/resource boundary. Retain both curvature variants for reproducibility;
components are the default numerical option, not a promoted inference recipe.
Reject claims of global incapacity, convergence or full camera matching. Keep both
frozen inference baselines unchanged. Next audit actual-objective gradients and
region-loss alignment on the indoor case, then separately quantify native
texture/noise and daylight correspondence/coverage. Only justified successful
expression proceeds to shared RAW-only training and selection; the original hard
regions, broad204-image development collection and untouched reserve stay required.
