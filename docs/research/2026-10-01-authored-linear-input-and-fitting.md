# RAW 9 linear input and controllable look implementation

Status: active investigation; no photographic candidate promoted.

## Question and frozen experiment

Does disabling native gamut mapping alone preserve useful extended values and
support a better authored look? Both variants retain native WB, baseline exposure,
shadow bias and denoise; use full-resolution RAW 9 and native lens correction;
zero boost, local tone mapping, contrast and sharpness. The same compact sigmoid
family is fitted to each input. Evaluation uses actual native HEIFs. No reference
image is accessible to the runtime look.

The explicit stages are linear technical exposure/WB, sigmoid display tone,
creative saturation, radial sRGB gamut compression and one sRGB transfer. The
first family preserves RGB ratios; the predeclared alternative blends per-channel
tone with luminance-ratio hue preservation. No predictor or local correction is
justified yet. Technical exposure/WB are identity in this first fit.

Training minimizes equally image-weighted RGB squared error using a fixed 12x12
interior grid, bounded four-parameter Gauss–Newton, two predeclared starts and
Accelerate's positive-definite solve. Reduced aligned native observations initialize
the model; actual full-resolution HEIFs establish appearance. They are not an
exact-export capacity oracle. Target Lanczos overshoot is clamped to the SDR range,
consistent with the existing scorecard; source extended linear values are retained.

## Split audit

The earlier 199-pair training manifest contained captures from development dates
under artificial session labels. Those labels did not establish independence.
The replacement has 152 pairs from 28 actual capture dates, disjoint from all
24 development images' 21 dates. It consists of 80 valid older training pairs and
72 previously consumed acceptance pairs, explicitly reclassified as training.
The 119 overlapping old training pairs are excluded from the replacement fit.

Capture date is a conservative grouping, not proof of independent trips. The
metadata-only inventory has 58 RAW dates; earlier training/development/acceptance
work touched 57. The remaining date has two RAWs without companion HEIFs.
Final untouched 50-image/10-session acceptance is not available merely by renaming
old captures. No final acceptance media have been consumed in this investigation.

## Synthetic and baseline evidence

CPU/Metal conformance covers extended/negative RGB, both tone modes, non-default
skew/WB/exposure/saturation, monotone neutral ramps and stage ablations. Maximum
measured CPU/Metal difference is 0.000002026 (limit 0.00002). A non-default skew
fixture caught a CPU-only omission before candidate adoption; the affected fits
were invalidated. Native fitting recovers a known synthetic curve with maximum
held-out RGB error 0.0000001612.

Moving native development into one shared owner leaves all decoded pixels of the
six saved-model baseline HEIFs identical. Rendering and calibration now call that
owner; offline reference access belongs solely to measurement/calibration.

## Colour-space failure and correction

The initial linear input used a linear Display P3 working context and explicit
linear BT.2020 output. Both fitted candidates had a systematic cyan/green cast;
all 24 development comparator gates failed for both variants. Saturation hit its
lower bound. Those are invalid input experiments, not evidence against sigmoid
capacity or the isolated gamut toggle.

An audit compared the direct native encoded sRGB render with linear BT.2020 pixels
converted by the standard BT.2020-to-sRGB matrix and sRGB transfer. At four frozen
points in the indoor anchor, the P3-context result disagreed markedly:

The exact sampled coordinates and RGB values remain in the private audit artifacts.

Changing only the working context to extended linear sRGB removes the disagreement
at these points. Native WB remains 4556.335 K / tint 23.426832. The explicit output
space remains extended linear BT.2020. This is measured behaviour on this macOS/
RAW 9 toolchain, not a universal statement about P3 contexts or an Apple bug diagnosis.
Full-frame checks initially applied the SDR transfer to negative extended values,
producing a false extreme discrepancy (up to 6.3 in an unmapped case). Apple's
[extended sRGB definition](https://developer.apple.com/documentation/coregraphics/cgcolorspace/extendedsrgb)
uses the signed reflection of the positive transfer. The corrected audit removes
that false extreme. This diagnostic mistake does not affect the authored output:
its declared gamut preparation produces [0,1] before the SDR transfer. The offline
registration proxy's saved comparator clamps negative inputs to zero; it now makes
that policy explicit. A matched full-float-context audit now covers 76,681,728 RGB components per
case/state. Mapped maximum absolute encoded error is 0.000552 across six cases;
mean errors range 0.00000151–0.00000590. Unmapped maxima are <=0.000793 except the
indoor case (0.002831, 37 components above 0.002); all its mean errors are similarly
small. Differences against the older half-float-context baseline are larger in a
few extremes, so decode precision must be held constant in a colour-space audit.

Calibration contract 10 records the development working space and rejects contract
9 observations. Authored recipe format 2 rejects the invalid earlier fits. Both 152-image inputs were re-exported and refitted. Ratio-family native HEIFs
have regression means 4.327 (mapped) / 4.331 (unmapped), selection means 4.051 /
4.075, and 0/24 old comparator passes each. Disabling native gamut mapping preserves
extended range but supplies no accepted appearance improvement here. Retain mapped
for the next colour experiment; this is not promotion of an accepted look.

Apple's [CIRAWFilter documentation](https://developer.apple.com/documentation/coreimage/cirawfilter)
identifies sensor RAW development and its controls; it does not itself certify our
colour-conversion boundary. Runtime differential evidence governs this decision.

## Appearance measurement

The look card freezes provisional tolerances before candidate fitting: absolute
regional median lightness delta <= 2, median-colour DE00 <= 3, absolute chroma delta
<= 3, correspondence sensitivity <= 1 under +/-4 evaluation-pixel displacement,
and complete valid region coverage. These are authored-anchor tolerances, not
physical chart accuracy or newly supplied aesthetic preferences.

The original cyan-toy rectangle mixes a white hatch with the cyan body. An
anchor-only minimum-variance search within it selects a 12x12 cyan patch at
normalized [.25, .779296875, .265625, .802734375]. This selection uses no candidate
error. Baseline median-colour DE00 worsens to 14.876 and common ROI-placement sensitivity
is 2.328: the region remains uncertain, not passed or excluded. It requires a
correspondence diagnosis before appearance acceptance. Other frozen regions are
unchanged. A review found the first sensitivity calculation moved both patches
together: that measures ROI placement, not correspondence error. The corrected
implementation separately shifts only the candidate relative to the fixed anchor (look-card/measurement format 2),
while retaining common placement sensitivity as an additional reported gate. The
baseline must be remeasured; neither uncertainty result is silently accepted.
Measurement and photographic gates remain open.

## Next feedback

1. Re-export and refit both declared inputs through the corrected owner.
2. Verify full-frame conversion and native HEIF results, including selected regions.
3. Diagnose the highest residual before selecting the second tone family or adding
   creative colour capacity. Reject systematic casts rather than compensate for
   an invalid input with learned colour adjustments.
4. Freeze a supported input/look only after these checks; retain the untouched
   acceptance-data gap explicitly.

Private artifacts: `input-colour-audit-{mapped,unmapped,srgb}.log`,
`shared-native-pixel-comparison.log`, `authored-training-verified.json`,
`corrected-authored-export.log`, `authored-linear-srgb-*-training/`,
`look-card-cyan-diagnostic.json`, and native HEIF comparison directories under
`/tmp/otos-sony-harness`. Photos, per-pixel samples and private paths are not in Git.


## Tone-family and held-out-region capacity feedback

The mapped per-channel family improves six-case mean DE00 from 4.327 to 3.775 and
18-selection mean from 4.051 to 3.214. It still has 0/24 old comparator passes.
Per-image four-parameter fitting excludes every frozen appearance rectangle plus a
12-evaluation-pixel support/registration buffer. These reduced-sample initializers
are then applied by the ordinary full-resolution HEIF renderer, and the withheld
regions are scored from actual files. A synthetic reference-patch mutation leaves
the diagnostic recipe byte-identical; acceptance roles and existing output folders
are rejected. They are diagnostic coefficients, never deployed photo lookups.

The cyan toy remains -22.45 median L / 25.64 median-colour DE00, while the cabin
shirt is +0.55 L / 2.24 DE00. A larger global exposure predictor is therefore not
supported by this diagnostic. Warm face/towel brightness improves, but colour
residuals remain. A floating-point endpoint bug in log-parameter decoding was fixed:
`exp(log(0.3))` can fall just below the declared bound. The original bound is now
honoured explicitly, rather than widening validation tolerances.

## Separately controlled creative colour

Recipe format 3 adds a conditional 5-cubed trilinear linear-sRGB residual after
tone/saturation and before the single existing gamut compression/transfer. Lookup
coordinates use bounded encoded display RGB; image values remain extended until
gamut preparation. Subtracting the lookup at the same linear luminance neutral
protects the entire neutral tone ramp. The stage is independently switchable.
This is one fixed body-wide look, with no lens/date/photo/scene lookup.

Native fitting uses equally weighted images, linear target residuals, adjacent-node
smoothness and a small identity ridge. Two predeclared regularization values were
0.00003 and 0.0003. The weaker variant gives regression mean 2.324 / worst p95
7.761 and selection mean 1.935 / worst p95 6.684. It improves warm face/towel
regions, but cyan remains -11.36 L / 16.34 DE00. The stronger prior is worse
(2.590 regression mean, 2.084 selection mean). Neither is accepted.

Nonzero-table CPU/Metal maximum disagreement is 0.000002097. Exact neutrals retain
the tone curve and disabling the residual restores the same base stage result.
An independent known smooth field is recovered on off-grid colours to
0.00000000271. A vertex-only synthetic training set initially left an interior
neutral-subtraction ambiguity; denser known observations resolve it without
relaxing the withheld-colour gate. Palette coverage matters even in a synthetic
recovery test.

## Sampling failure and bounded solve

The original 21,888 spatial-grid observations have no point within encoded RGB
lookup distance 0.05 of the cyan patch, and only one within 0.10. Scanning existing
training images at stride 4 finds 16 points within 0.05 and 179 within 0.10. The
nearest source distance is 0.00659 with target RGB (0.025, 0.916, 1), consistent
with the cyan anchor. This is a sampling gap, not a justification for a larger LUT.

A declared sampler variant retains half each image's weight on the spatial grid
and puts half on equal 8-cubed source-colour bins (centre and most-chromatic
representatives). Selection uses source colour and valid correspondence alpha,
never target error. Stride 4 and a 12-pixel border exclusion are fixed. Tone,
152-image split, 5-cubed capacity, 0.00003 regularization and appearance gates stay
unchanged. This yields 63,115 observations. Cyan improves, but warm pale regions
regress; 38 coefficients exceed the unconstrained bound before clipping.

That report exposes a numerical defect: independent coefficient clipping after a
coupled solve is not the bounded optimum. The revised active-set solver enforces
bounds in each reduced native LAPACK solve and verifies free/bound gradient
conditions before returning. A known two-coefficient case requires (0.5, 0.15),
where naive clipping gives (0.5, -0.1); the revised solver recovers the true solution.
The corrected palette fit has 19 active coefficient bounds. Its regression mean
is 2.681 (worst p95 8.072), selection mean 2.376 (worst p95 12.276); cyan is -7.41 L /
12.22 DE00, but other regions regress. Raising only the bound from 0.5 to 1.0 gives
regression mean 2.978 / selection mean 2.658 and does not improve cyan (-7.47 L /
12.34 DE00). The amplitude hypothesis is rejected. No recipe is promoted.

## Runtime reference independence

The format-3 colour renderer succeeds with a valid HEIF companion readable, then
with that file denied by the macOS filesystem policy. A control read is rejected
by the same policy. Every decoded native pixel is identical. Replacing both embedded
JPEG previews in the sensor-identical private RAW also leaves all pixels identical.
Private artifact `authored-v3-input-isolation-valid.log` records the native
6192x4128, 10-bit output and exact decoded-pixel comparisons. This closes the
companion-denial check for this renderer without modifying originals.

## Untouched-corpus audit refinement

The wider OneDrive inventory adds 178 HEIFs and no RAWs beyond the Camera Roll
inventory; traversal of `.Trash` timed out, so that folder is unverified. A
metadata-only search within consumed dates finds nine untouched clusters with
paired images separated from their neighbours by >=2 hours. Eight have >=5 pairs.
These are candidate temporal clusters, not proof of ten independent capture
sessions. They are reserved without reading their media. The final fresh-data gate
is still open; no consumed date is relabelled as an independent untouched trip.


## Measurement self-oracle and local correspondence

The format-2 relative +/-4-evaluation-pixel sensitivity assumption rejects 11/17
real HEIF regions when an anchor is compared with itself, although all nominal
colour errors are zero. It measures spatial variation under invented uncertainty,
not established correspondence uncertainty. That acceptance evidence is invalid.

Measurement format 4 uses 192-native-pixel gradient-correlation tiles at five
locations per region, with fixed 64-native-pixel surrounding support. It checks
forward/reverse agreement and rejects distant alternative peaks, flat texture,
search-boundary matches and weak correlation. Median local displacement aligns
only the offline colour measurement. One native pixel of discretization plus
observed spatial spread and reverse disagreement form an empirical support envelope;
this is not a calibrated statistical confidence interval. Fractional sampling is
bilinear. Common +/-4-evaluation-pixel placement sensitivity remains separate.
Unregistered colour is also reported. No inference image is warped by this diagnostic.

All 17 exact photographic anchor comparisons pass. Fixtures verify steep-colour
identity, unknown correspondence rejection, a known (+3,-2) native displacement,
flat-region rejection and distant repeated-texture ambiguity. The cyan region can
now be located using surrounding texture: in the display-palette candidate its
shift is (+0.125,-0.121) evaluation pixels, support radius 0.144, and correspondence
colour sensitivity 0.057. Its -9.87 L / 12.82 DE00 residual is therefore a real
appearance failure. Other flat/ambiguous regions stay inconclusive.

## Display-stage ablation and fitting objective

The linear initializer fits colours before the final gamut/transfer function.
That is not the same objective as the encoded HEIF pixels. A reduced-observation
cyan audit also finds that smooth radial gamut compression desaturates colours
near the cube boundary. These two factors are tested separately.

Recipe format 4 names `smoothRadial` and `radialProjection`. Projection preserves
in-gamut values and scales only out-of-gamut chroma radially at fixed luminance;
it is continuous but has a boundary derivative kink. Native CPU/Metal tests cover
in-gamut identity, saturated endpoints and extended colours. With otherwise identical
coefficients, projection changes regression mean from 2.324 to 2.356, and cyan
colour error remains 16.35. It is rejected as a solution to cyan. Darktable's
[AgX documentation](https://docs.darktable.org/usermanual/development/en/module-reference/processing-modules/agx/)
separates tone, look and primaries and advises one display transform. It motivates
explicit stage ownership, not a claim that this projection implements AgX.

The revised offline solver keeps the 5-cubed field, tone, native input, sampling,
regularizer and 0.5 bounds fixed and refines through the actual CPU gamut/transfer.
Finite-difference display Jacobians drive a bounded coupled Gauss-Newton step;
only reductions of the true regularized encoded-RGB objective are accepted. Eight
iterations are a bounded initializer, not a certificate of global optimality.
Known-field recovery on withheld colours has maximum RGB-vector error 0.000604,
with bounded coefficients and >100-fold objective reduction.

The spatial-grid variant reduces training objective 0.002396 to 0.002034, but
native regression mean is 2.344 and cyan remains 16.86 DE00. The palette variant
reduces objective 0.007237 to 0.004585; native regression mean is 2.307 but cyan
remains 12.82 DE00 and warm-shirt error is 3.22. Neither meets appearance adoption.
Lower training loss alone is rejected as acceptance evidence.

## Withheld-region colour capacity

The next diagnostic uses the same shared tone and 5-cubed colour family but fits
one offline field per anchor, excluding every frozen appearance region plus 12
evaluation pixels from both the spatial and source-palette sampler. A synthetic
coloured-reference mutation in the withheld rectangle leaves each recipe byte
identical; acceptance roles and existing destinations are rejected. These are not
photo-specific inference overrides. Actual native HEIFs validate the withheld regions.

At regularization 0.00003, cabin cyan improves to 2.39 DE00 but remains -3.31 L;
cabin skin/shirt pass. Other cases still have failures: indoor skin 5.30 DE00 /
-4.94 L and dark forest 3.74 DE00 / -2.91 L. Ambiguous correspondence remains
inconclusive. This does not yet establish complete native family capacity or justify
predicting per-image coefficients. A second predeclared 0.000003 regularizer tests
whether the smoothness prior limits that diagnostic, without enlarging the model.
That second variant does not close capacity: indoor skin worsens to 5.86 DE00 /
-5.41 L, dark forest remains 3.78 DE00 / -2.83 L, and cyan is unverified with nominal
3.44 DE00 / -3.83 L. It is rejected as a capacity improvement. No further prior
sweep is justified. The next diagnosis must inspect native observations and the
remaining residual rather than deploying a predictor or enlarging the field.

## Lens identity and toolchain boundary

Native correction availability is independent of EXIF lens identity and the
creative look. Unknown lens identity is retained as absent metadata. Unsupported
native profiles render uncorrected with explicit support/enabled facts; no custom
profile is added. A private sensor-identical RAW with its EXIF lens string cleared
renders a 6192x4128 HEIF successfully, reports no invented lens identity, and retains
Apple's supported correction. This verifies missing identity, not an actual
unsupported-profile photographic case. The known supported-lens training subset
remains explicit. Both standalone executables now compile in Swift 6 with complete
strict concurrency; the complete numerical/boundary fixtures pass.


## Mixed-sign hue preservation correctness

Native versus reduced observations agree closely in the frozen cyan region;
resizing is not the primary explanation for that regional failure. Source-only
palette attribution also exposes sparse fitting support: only seven observations
from six training images lie within encoded-source distance 0.05 of the cyan key,
with about 0.0104% of total weight. Negative red channels collapse to the same
clamped lookup coordinate. These remain diagnosed limitations, not permission to
add a predictor or increase field size.

A preceding correctness defect must be removed first. The per-channel hue blend
scaled the original RGB by mapped luminance divided by original luminance. Signed
channels can cancel to nearly zero luminance: a synthetic dark mixed-sign pixel
produces a pre-gamut channel above eight million. Final gamut clipping made the
old finite-output test miss this amplification. The observed fitting samples also
contained extreme pre-gamut excursions. Whether it accounts for visible native
shadow flecks requires photographic verification.

[darktable's sigmoid documentation](https://docs.darktable.org/usermanual/4.2/en/module-reference/processing-modules/sigmoid/)
describes separate per-channel tone mapping and hue preservation. Its implementation
informs the investigation, but no third-party code is incorporated. Our format-5
formula independently interpolates input channel positions between the tone-mapped
minimum and maximum channels, blending this with independent channel mapping.
This is bounded for signed RGB, preserves RGB hue at full strength, and does not
claim energy preservation. The near-zero-luminance regression asserts pre-gamut
bounds and continuity, plus CPU/Metal agreement. This single-factor correctness
change invalidates prior recipes; RAW 9, input development, gamut policy, sampling,
field dimension and bounds remain fixed for its ablation/refit.


The format-5 hue-only native ablation uses unchanged format-4 palette coefficients
strictly as a comparator. Cyan worsens to 14.66 DE00 / -13.30 L and warm-shirt
nominal error to 5.16 DE00; it is not an accepted recipe. The stable mathematical
boundary is retained and the unchanged four-parameter family is refitted before
colour fitting. This is not a photographic quality claim for the formula alone.
A separate residual-disabled native ablation reduces visible blue flecks in the
cabin fireplace. Native threshold counts still include blue pixels without the
field, and the camera image also contains blue pixels in this area. The field
increases their brightness; a new artifact or denoise requirement is not established.
No new denoise stage is introduced.


## Expression versus withheld-region extrapolation

The stable format-5 grid/palette refits have native six-case mean DE00 2.306/2.274,
but cyan remains 18.20/14.23 DE00. The palette variant is not accepted. The unchanged
withheld-region per-image audit still fails indoor skin (6.47 DE00), cyan (-4.00 L /
2.90 DE00), and forest (-2.41 L / 3.19 DE00). These are extrapolation failures, not
proof that the field cannot express the colours: the shared field already scores
indoor skin better than its withheld-region per-image fit.

A private diagnostic oracle explicitly fits equally weighted frozen anchor regions
using dense registered observations, then renders ordinary native HEIFs. Its fitted
regions are never labeled holdouts. Per-image oracle cyan reaches -0.34 L / 0.24
DE00. A single shared field across all six anchors reaches cyan -1.01 L / 0.70 DE00;
all 17 nominal regional colour errors are <=1.64 DE00 and |lightness| <=1.46. Some
correspondences remain inconclusive and cyan common-placement sensitivity is 1.19,
so these are neither acceptance results nor a promoted recipe. They establish that
larger fields or runtime adaptation are not the next justified step. The private
oracle's initial fixed-stride sampler rejected the small cyan region; adaptive
stride with a minimum valid-sample guard corrected that diagnostic run.

The next controlled hypothesis is fitting coverage, not model size. Reweight the
same training-only palette observations by occupied 8-cubed source-colour bins.
Two predeclared objectives mix 50% or 100% global colour-bin mass with the existing
image-weighted objective. Target colour, anchor masks and capture IDs do not choose
the weights. Tone, RAW input, coefficient bounds, regularizer and model size remain
fixed. Fitted-field invariance under repeated frequent colours, target-independent
weights and conserved total mass provide the numerical oracle; actual six-case
native outputs and 18 selection cases determine photographic benefit.

[ACES reference gamut-compression guidance](https://docs.acescentral.com/rgc/specification/)
warns that negative input values and the LUT shaper domain need explicit handling.
That supports examining the earlier clamped lookup, but does not justify expanding
its domain around the unstable tone formula's extreme excursions. No ACES transform,
new runtime dependency or lookup-domain expansion is incorporated here.

## Current-version operational evidence

Format-5 companion access denied by an effective sandbox and both embedded previews
replaced in a sensor-identical private RAW produce exactly identical 6192x4128
native decoded pixels (25,560,576 pixels). The inference boundary holds for the new
recipe. Current authored cancellation observed during real HEIF encoding leaves no
published output and no temporary file. Independent ffprobe inspection of all 35
HEIF tile streams reports Main 10 / yuv420p10le, sRGB transfer and BT.709 primaries,
without stream HDR side data. ImageIO separately confirms composite native dimensions
and 10-bit components. These verify this candidate's format and operational path,
not photographic or fresh-session acceptance.


## Source-coverage result and authored-objective adjustment

The 50%/100% global source-bin objectives improve native cyan to 10.14/8.73 DE00,
but neither passes; warm-shirt nominal error worsens to 3.48/4.12 DE00. Both are
rejected as recipes. The repeated-colour fitted-field invariance, target-independent
weighting and conserved-mass fixtures pass. The implemented weighting is an offline
experimental objective, not a new inference dependency.

The next experiment aligns fitting with the authored brief explicitly. The six
look-brief captures become authoring anchors when used in fitting. Their scores
verify whether the intended authored definition is achieved, not unseen-image
performance. Mix 20% or 50% equal authored-region priorities with the unchanged
152-image broad training objective, using one fixed bounded field. No per-photo
selector or runtime anchor access is added. The 18 other-date selection images
remain independent of these fits; the final untouched 50-image/10-session gate is
unchanged. This adjustment replaces an inadequate average-pixel proxy with declared
style priorities and cannot be used to inflate validation counts.


## RAW-only acceptance correction

The previous final acceptance requirement demanded paired camera HEIFs even though
the task is ready HEIF development when no camera render exists. Final reliability
requires at least 50 untouched RAWs from ten independent sessions; companions are
optional supplemental diagnostics. Native quality, authored appearance, format,
operation and stability remain gates. The two May 26 RAWs were excluded solely for
lacking companions and are now candidate acceptance inputs. A metadata-only RAW
cluster audit excludes previously referenced/derived captures without reading
original image bytes. Temporal separation remains a candidate grouping rule,
not certification of independent shoots. No candidate acceptance pixels are read
before a recipe is frozen.


## Reproducible authored candidate and reserve audit

The 20%/50% authored-priority mixtures bring native authoring cyan to 4.03/1.87
DE00. The selected 50% candidate has cyan -2.23 L, warm-face chroma +3.13 and cyan
common-placement sensitivity 2.04, so it does not meet every strict camera-comparison
tolerance. It improves the intended authored appearance without the previous warm
clothing regression. Independent-date development validation covers 18 images:
mean low-frequency DE00 1.9139, worst image mean 2.5962. Three worst-scoring images
were visually inspected; no new image artifact was established. These images are
validation for this fit, not untouched final acceptance.

An eight-pixel authoring-support expansion brings cyan placement sensitivity to
0.99 but worsens lightness to -2.87 L / 2.86 DE00; it is not selected. The current
recipe remains the 50% exact-region candidate. The canonical explicit-role fitter
reproduces its encoded recipe byte-for-byte: SHA256
`13bd09a22de0f9e620344984210419f3f216403625c9f49b1f5c0e24d424a267`.
The checked-in JSON adds the repository's final newline. Selection/acceptance/
regression author-role rejection and author/training date-leakage rejection pass.
The user's preference between authored-look freezing and strict camera-comparison
release gates was requested; no response has been received at this checkpoint.

A conservative RAW-only reserve audit excludes all previously referenced captures
and captures represented in pixel artifacts. It finds 94 RAWs in eight >=2-hour
candidate groups, including two unpaired May 26 and three unpaired May 29 RAWs.
The earlier nine paired-only reserve groups were incorrect: May 24, July 4 evening
and July 14 evening contain actual prior guided-experiment pixel artifacts and are
excluded. These are eight candidate groups, not ten certified independent sessions.
No reserved acceptance image pixels have been read during this audit.


## Isolated runtime and memory

Three consecutive native exports in one process, without another calibration or
profile workload, complete in 4473/4776/4820 ms. Maximum resident set is 2.023 GB;
resident memory after each export is 1.549/1.603/1.645 GB. A separate five-export
profile run has end-of-export resident memory 1.561/1.676/1.693/1.727/1.680 GB;
this does not show runaway per-image retention. Native allocation pressure remains
substantial; no cache/pool or speculative optimization is added.

A standalone-process 10-second Time Profiler trace is captured privately as
`/tmp/otos-sony-harness/authored-v5-standalone.trace`. The app-launching profile wrapper
is intentionally inapplicable to this standalone task. Repository log tooling with
`--process sony-render-harness` retrieves 24 stage messages across eight renders:
worst development/colour span 5065 ms, encoding 294 ms, complete publication 5319 ms.
The profiled run is not the isolated latency measurement. Trace exports include
process environment and are kept private; the public report uses a summary omitting
that environment. Hardware is a 16 GB MacBook Pro on macOS 27.0 (26A428).


## Native detail and nearby-frame checks

Native 512-pixel gravel and foliage corner crops have visible green/magenta fringing
relative to the camera HEIF. It remains when the creative residual is disabled and
is also visible in Apple-default RAW 9 output. These observations do not establish a
new authored-colour artifact; native decode/lens detail remains a separate limitation.
They do not certify all detail or justify a new correction stage.

Three already-consumed one-second frame pairs (July 19 daylight interior, August 18
warm interior, September 15 warm portrait) produce six native HEIFs successfully.
Visual review shows no abrupt brightness/colour jump. Native WB is identical for the
July pair and changes by small amounts for the other two; baseline exposure is 0.4
throughout. The September pair normalizes portrait orientation to 4128x6192; the
others are 6192x4128. This is development stability evidence, not fresh-session proof.

## Perceptual fitting and independent geometry measurement

A diagnosed one-factor experiment replaces final nonlinear encoded-RGB least squares
with normalized D65 CIELAB/100 least squares. This is a DE76 proxy, not an assertion
that it optimizes the reported CIEDE2000 exactly. Input, base tone, 5-cubed field,
coefficient bound 0.5, regularizer 3e-5, 50% authored priorities and all 152/6/18 splits
remain fixed. Known-field recovery on withheld synthetic colours passes under both
objectives. No runtime stage, scene selector or camera-render dependency is added.

The perceptual variant improves independent-date development mean DE00 from 1.9139
to 1.8693 across 18 actual native outputs. Six image means worsen (largest +0.069),
twelve improve; two difficult means improve by about 0.36/0.38. No image that passed
both historical mean<=2/p95<=5 comparator limits becomes a failure. Those comparator
limits do not alone certify authored appearance. The largest-regression previews
were inspected; no new visible artifact was established.

Candidate-dependent gradient matching exposed a measurement confound: changing only
colour can turn a reliable region inconclusive despite unchanged sensor/lens geometry.
Measurement report format 5 therefore requires a separately rendered, fixed RAW
geometry baseline without a creative field. Both candidates use the same baseline
and consequently identical correspondence facts. The report records that artifact's
SHA256, not its filesystem path. Native dimensions must match. Identity comparison
still requires identical geometry/reference bytes. The look-card schema remains
format 4 and its numeric limits are unchanged; earlier candidate-dependent scores
are supplemental history, not directly interchangeable current coverage evidence.

Under fixed geometry, cyan improves from -2.23 L / 1.87 DE00 to -1.69 L / 1.43 DE00;
warm-face nominal chroma improves from +3.15 to +2.91. Previously passing regions
retain passing nominal colour limits. Cyan common-placement sensitivity is still
2.09 against the limit 1; warm-shirt chroma is 3.09 against 3, and several flat/ambiguous
matches remain inconclusive. These are open gates, not silently relaxed criteria.
The normalized-Lab recipe is the new working candidate, not accepted M3/M5. Its
canonical recipe SHA256 is `43d174a49163102eb38f6acfae0e5af365546233090134c70f1f8db12a24673e`.
The previous RGB candidate remains private as the controlled comparator.


The canonical explicit-objective fitter reproduces the experimental recipe
byte-for-byte, and checked-in values match. The final CLI demonstrates identical
correspondence facts and baseline digest across RGB/perceptual candidates while
measuring different candidate colours; malformed 1e300 region coordinates reject
before image reads. The full standalone numerical/runtime-boundary fixtures pass.

A refreshed metadata-only OneDrive inventory finds 3,969 ARW paths and no new RAW
paths beyond the prior inventory. Clustering all RAW timestamps before exclusion
and counting only nonempty prior-reference/pixel-artifact evidence independently
confirms the same eight conservative groups / 94 RAWs. Empty audit entries are not
use evidence. No acceptance image pixels are read in this refresh. The ten-session
coverage gap remains; these groups still need semantic independence/coverage review.


## Measurement validity and bounded coverage follow-up

A nine-position diagnostic isolated the cyan placement result: the worst common
shift (-4,-4 evaluation pixels) changes DE00 from 1.426 to 3.520. Candidate patch
colour changes by 2.110 DE00 and anchor colour by 1.018; the other eight positions
are 1.335–1.865. This is spatial variation of a colour residual, not a relative
registration error: both patches move together. Look-card schema 5 therefore
retains this reported diagnostic but gates measured relative-correspondence
uncertainty only. Brightness <=2, DE00 <=3, chroma <=3, full coverage and relative
sensitivity <=1 remain unchanged. A synthetic contrast-ramp fixture passes with
known identity despite common-placement variation, while the same pair with four
pixels of relative uncertainty fails. Visible defects remain independent gates.
The change was explained in chat after the initial question was too technical;
no aesthetic preference was inferred from the user's response.

Two predeclared fitting-coverage variants were rejected. Four-pixel expanded
support lowers cyan placement sensitivity from 2.094 to 1.017 but leaves the old
placement gate open and worsens warm-shirt chroma to +3.181. Equal mass for all
nine common placements leaves cyan placement at 1.645 and warm-shirt chroma at
+3.083. Neither warrants a spatial-radius sweep, a bigger field or adaptation.
They never enter the checked-in recipe.

Native match diagnostics attribute several unknown patches to weak high-frequency
correlation across different denoise/detail rendering. A fixed native sigma-1.2
Gaussian measurement recovers four patches but loses cyan, so unconditional blur
is rejected. The accepted two-scale policy retains a confident fine-scale match
and retries only an ambiguous match at sigma 1.2. Correlation >=0.65, rival margin
>=0.02, subpixel peak shape and reciprocal disagreement <=1 native pixel remain
unchanged. All original confident patches survive and four additional patches
become measured: warm face/towel and tent face/jacket. White wall, warm shirt and
tent fabric remain explicitly unknown. Known-displacement, flat and repeated-
texture fixtures pass. An early fixture run without native GPU access produced
black Core Image frames; rerunning with GPU access separates that environment
failure from the algorithm. Measurement report 6 records the fixed geometry hash
and matching policy. This changes measurement only, never rendered pixels.

The provisioning helper now accepts optional companions and counts actual files.
It checks manifest materialization and rejects existing receipts and receipts
inside any listed original's directory before requesting downloads. A mixed
RAW-only/paired runtime fixture verifies three local files, zero requests,
no overwrite, root rejection and byte-identical originals. Receipts remain private.

## Independent public RAW provision research

Public, author-provided A6700 samples can supplement the private reserve without
requiring camera-rendered companions. Three downloaded RAWs have verified capture
metadata: Photography Blog sample 20 (2023-06-27, 10.5mm E PZ 10–20mm F4 G), sample
41 (2023-06-22, 50mm FE 50mm F1.4 GM), and RTINGS compressed sample (2023-10-24,
24mm E 18–135mm F3.5–5.6 OSS), all ILCE-6700 / ISO100. The web page's 75mm value is
an equivalent focal length; the RAW's actual lens/focal metadata is recorded.
Downloads, hashes and metadata are private; image pixels remain untouched pending
recipe freeze. Different dates and independent review teams provide new source
coverage, but five variants do not automatically mean five independent shoots.

Sources: [Photography Blog's original review and RAW section](https://www.photographyblog.com/reviews/sony_a6700_review),
[RTINGS original RAW format tests](https://www.rtings.com/camera/reviews/sony/a6700),
[raw.pixls.us project-owned regression corpus](https://raw.pixls.us/),
[its A6700 sample index](https://raw.pixls.us/data/Sony/ILCE-6700/).
The public corpus expressly serves RAW-decoder regression projects. DPReview also
offers private examination of RAWs in its [A6700 gallery announcement](https://www.dpreview.com/samples/9728852463/sony-a6700-sample-gallery/),
but the gallery HTML request returns HTTP403 here; no access bypass is attempted.
Public photos/derived outputs are not redistributed in Git or the PR.


## Current photographic candidate

The 55% author-priority normalized-Lab recipe supersedes the 50% working comparator.
The [final validation](2026-10-01-vivid-raw9-pipeline-validation.md) records the bounded
selection decision, actual stage ablations, 14 reliable region passes/three unknown
comparisons, final native review and 94 fresh private RAW exports. Five public RAWs
were used only for decoder/export verification; the user questioned their relevance
to the vivid filter, and further online collection stopped. They do not certify
matching accuracy. The previous appearance-focused completion claim was unjustified:
the original paired matching and ten-independent-shoot gates remain open. Seven
whole-image development failures and three uncertain regions prevent acceptance.
See the restored Plan 0105 and paired-data research for continuation.
