# Native objective order and expression by failure class

Date: October 3, 2026. Plan0105 diagnostic evidence; no promoted model.
Sensor RAW9 and separate verified VV2 HEIFs only. Embedded camera images and
acceptance reserve pixels are excluded. Originals are guarded/read-only.

## Frozen nine-control order audit

Compare the static profile with the previously frozen shared WB/ISO candidate on
the same nine development captures. Both retain their existing runtime family.
No fitting, parameter sweep or camera-dependent normalization takes place.
Use identical unregistered50-by-50 sampling support, finite/opaque checks and
existing input/target domains. Report averaged-input-before-look RGB MSE,
native-look-before-reduction RGB MSE with the same calibration radius, native
RGB MSE with release sigma, and actual emitted native HEIF DE00 mean/p95.
These are data losses, not the complete regularized shared training objective.
Unregistered optical differences remain; no metric or acceptance limit changes.
The private observation initially lost alpha support after reduction; explicitly
marking the verified opaque native output before resampling repaired that
observation path. The original failed run stays recorded. Actual HEIF scoring
was unchanged, and completed support is2500 points per capture.

Eight of nine point/native RGB loss rankings agree. Stone20260921_103245 reverses:
conditional-minus-static point MSE is-0.00003037, but native calibration-order
MSE is+0.00001964. Release-sigma native MSE is+0.00001967, so this reversal
persists after changing the blur observation. RGB versus actual HEIF perceptual
mean rankings disagree on May23, July8 and September20 controls. These small
changes are reported without inferring visible worsening or improvement solely
from their sign. The green/foliage failures worsen under both compared RGB paths.
Actual HEIF and pre-encoding perceptual means differ by up to0.07959; pre-encoding
loss cannot certify the encoded file. All18 native HEIFs completed.

Decision: verify native outcomes for every shared candidate. The point surrogate
is not an exact native objective, and perceptual ranking cannot be inferred from
RGB MSE alone. This comparison does not establish that objective replacement will
resolve a failure, or that adding image context is necessary. Do not claim the
full regularized fitting objective was reproduced; no model is promoted.

## Two expression checks with unchanged capacity

Use green20260710_203257 and foliage20260921_162050. Retain static49-channel-knot
curves,9-cube base, bounded3-cube additive field, RAW9.mapped, regional fitting
target1.9, six outer iterations and20 halving trials. Keep original three regions
plus the same17 uniformly placed grid regions used in the cyan diagnostic.
Independent existing RAW geometry is frozen before fitting. Unknown/sensitive
regions remain excluded from fitting and reported in final scoring.

- Green:12 reliable regions. Signed-component derivative calibration fails after
  37 observations, before a step. Actual unchanged static HEIF mean/p95 is
  2.76505/4.60964. This is numerical failure, not a capacity conclusion.
- Foliage:8 reliable regions already satisfy the sampled target, so the diagnostic
  takes no step. Actual unchanged HEIF still fails2.55141/7.82896. Sunlit foliage
  has mean2.059 and correspondence sensitivity1.05074, above the fixed1.0 limit;
  that failing region did not enter fitting. Sampled satisfaction is not full
  expression. Reopen correspondence/detail attribution, not successful prediction.

## Bounded Cartesian-residual numerical repair

The signed polar DE00 residual has square-root directional sensitivity as source
chroma approaches zero. A synthetic low-chroma central-difference fixture shows
half-step relative disagreement0.292895, exceeding the existing0.25 diagnostic
limit. Define a Cartesian alternative: Lab difference direction multiplied by
DE00 divided by its Euclidean length. Exact identity returns zero. Its norm is
exactly the same DE00; only the residual direction/curvature changes. This is not
a smoothed metric, relaxed derivative limit or larger correction field.

The same fixture's Cartesian half-step disagreement is0.00000629735. Test metric
norm equality in both directions against all34 published Sharma/Wu/Dalal test
pairs, plus identity/chromatic fixtures. Keep existing distance and component
variants and defaults unchanged; `cartesian` is an explicit diagnostic choice.
Source: [published DE00 supplemental data](https://hajim.rochester.edu/ece/sites/gsharma/ciede2000/dataNprograms/ciede2000testdata.txt).
No guarantee of differentiability at every branch of the original metric is made.

One frozen Cartesian green fit passes the existing derivative gate and takes all
six bounded steps:1015 observations, loss0.565610 to0.068931, budget exhausted.
Actual HEIF mean/p95 improves to2.05309/4.26374, but mean still fails2.0. Face
1.6819 and white jacket1.6560 pass. Tent1.8583 remains inconclusive because
correspondence is unknown. Of20 declared regions,10 pass,4 fail,6 inconclusive.
Reliable grid-4-0 andgrid-5-0 remain2.6583/2.4492; there is no all-region
expression or convergence certificate. No field, floor, target or budget sweep
follows. Keep the numerical repair as explicit diagnostic functionality, not a
shared RAW-only recipe. No render coefficient or acceptance gate is changed.

## Reproduction and next decision

Private receipts: `build/sony-paired-corpus/control/objective-order-contract.json`,
`objective-order-summary.json`, `green-foliage-expression-contract.json`,
`cartesian-residual-contract.json`; actual outputs in `diagnostics/objective-order-nine-v2/`
and `evaluation/green-cartesian-residual/`. Private prototype source preserves
all audit paths; it is not a new production owner. Native class fitting uses the
committed `matching-native-profile-field` command and `score-regions`.

Continue RAW-only prediction work for demonstrated expression classes such as
original cyan. Keep green's whole/grid failures and numerical-budget limitation
explicit. Foliage/daylight require independent correspondence/detail attribution;
do not feed lens/geometry defects to a colour predictor. Any predictor uses
training-only source features, group-held-out validation, the fixed screen and
full204 development gates. Never count these per-image fits as shared inference
or untouched acceptance. Numerical progress and photographic progress stay distinct.
