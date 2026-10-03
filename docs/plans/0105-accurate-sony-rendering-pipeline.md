# 0105 — Accurate Sony RAW to vivid HEIF rendering

Status: active; photographic matching is not accepted. Original plan opened
September 27, 2026. This revision restores its target after an unjustified change
to independent authored-look acceptance. The framework remains iterative: measured
failures determine the next operation and escalation, not a predetermined model.

## Objective and supported scope

Develop Sony ILCE-6700 sensor RAW into native-resolution 10-bit SDR sRGB HEIF with
the same visible rendering as the user's verified Sony VV2 camera HEIFs. Those
HEIFs are the training/evaluation targets. Inference uses only sensor RAW, capture
metadata available from RAW and the frozen recipe/model; never target HEIFs,
camera JPEGs, embedded previews, their pixels or their statistics. Embedded camera
images are also excluded from fitting, evaluation and visual inspection; use the
separate verified HEIF targets for supervised work.

Keep macOS Core Image decoder 9 as the foundation. Run outside the Otos app.
Separate normalization, tone, colour, local/detail processing where justified,
and display/encoding. Separately owned adjustments can interact and be jointly
fitted; separate ownership is not evidence of independent effects. Lens correction
has independent controls and diagnostics: retain supported Apple correction,
report unsupported/residual correction, and defer custom profiles as requested.
Do not learn lens defects into the shared colour recipe.

The objective is image rendering, not identical compressed-file bytes or recovery
of Sony's proprietary implementation. Existing difficult indoor, skin, cyan,
warm-clothing and green-tent cases remain in scope. Successful exports alone,
fitted examples alone, lower average error or plausible vivid appearance do not
complete this plan. Other cameras, looks, JPEG output and app integration are
outside scope. GitHub CI is outside the user's requested work; local checks remain.

Originals remain read-only. Check SF_DATALESS immediately before every byte read;
use deliberate non-blocking provision requests when needed. Existing authorization
covers OneDrive provisioning. Keep private manifests, pixels and outputs outside
Git and media folders. The user-authorized working corpus lives in the primary
checkout’s ignored `build/sony-paired-corpus/`, independent of OneDrive and
worktree cleanup. Copy only after the immediate materialization gate, verify
SHA256 and size, preserve source provenance and assigned roles in private manifests,
and use the local paths for subsequent runs. Never commit media or private manifests.
No new third-party dependency without the required ADR.

## Current evidence and limits

| Area | Verified progress | Remaining gate |
| --- | --- | --- |
| Native input/output | RAW 9, explicit floating-point colour boundaries, shared native owner, native 10-bit SDR HEIF | Retest photographic/detail effects after changes |
| Input independence | Denied camera-image reads and changed embedded previews yield identical output pixels | Preserve for every final implementation |
| Colour/tone | Frozen format-5 baseline; native comparison of 204 development pairs; 463 verified training captures with endpoint-inclusive exports available | Historical authored baseline failed 77; current static profile fails 31/204 whole-image limits; attributed region failures remain; no accepted matching recipe |
| Region measurement | Pixelwise mean/p95 gate, separate median diagnostics, fixed RAW geometry; six perturbation views and seven-image grid audit | Original hard regions include a warm-face colour failure, a correspondence-sensitivity failure and three inconclusive regions |
| Export reliability | 99 guarded RAW exports, format/metadata/original-integrity/cancellation evidence | That batch did not test matching to camera targets |
| Independent acceptance | 3,768 candidate pairs inventoried; 463 training and204 development pairs locally capture/VV2 verified; prior-use audit | Original 72 temporal groups have prior pixel use; 229 new candidates frozen before pixel use, 208 metadata verified and 21 unavailable; seven temporal candidates across six dates remain below the ten independently checked shoot gate |

The checked-in recipe is a frozen comparison baseline, not a release-quality
matching result. Its training priority on six examples is not an acceptance rule.
The complete user collection must be used in assigned roles, rather than limiting
learning/evaluation to a small convenience set. Known prior use disqualifies an
image/group from untouched acceptance; it remains useful development material.
See [current evidence](../research/2026-10-01-vivid-raw9-pipeline-validation.md),
[original methods](../research/2026-09-27-sony-matching-methods.md) and
[paired-data research](../research/2026-10-01-paired-vivid-camera-learning.md) and
[comparison-method research](../research/2026-10-01-camera-match-comparison-method.md).

## Acceptance contract

Retain the original colour/detail/generalization gates. Later median-region
limits are supplementary diagnostics, not substitutes. These are project
engineering limits, not universal perceptual guarantees. Any necessary measurement
revision requires demonstrated invalidity, an explicit reason/version and fresh
acceptance; observed failures cannot justify relaxing a target.

| Aspect | Gate |
| --- | --- |
| Whole-image colour/tone | Each acceptance image: valid low-frequency mean CIEDE2000 <= 2.0 and p95 <= 5.0; also report unblurred errors |
| Difficult regions | Every preselected region: mean low-frequency pixel CIEDE2000 <= 2.0; no visible broad cast, brightness mismatch or new artifact |
| Native detail | No systematic halos, softened texture, fringes or excess noise; report edges, texture and flat-region noise. Matching individual random noise realizations is not required |
| Generalization | At least 50 untouched verified RAW/HEIF pairs across at least 10 independently checked shoots, separate from training/development; use more eligible pairs when available and report coverage |
| Regressions | Every failed image/region and excluded/uncertain area remains reported; include worst cases and lighting/ISO/lens groups; averages cannot buy failures |
| Reproducibility | One versioned pipeline/model for CPU/Metal evaluation, actual native HEIF and comparison assets; boundary/malformed-model fixtures |
| Operation | Guarded reads, no silent decoder/model substitution, no original writes, complete no-overwrite publication, cancellation and measured latency/memory |

Colour scoring retains 768-pixel long edge and Gaussian sigma 1.2, identical
profile/crop/transfer/resampling, validated D65 Lab/DE00 and separately reported
valid fraction/clipping. Exclude unreliable correspondence, never high error alone.
The original half-native-pixel geometry gate cannot be claimed satisfied: custom
lens work was explicitly deferred. Report native geometry independently, use only
reliable correspondence for colour, and keep that scope limitation explicit.
No target-specific registration becomes a runtime lens correction.

## Feedback and escalation rule

Every experiment records baseline, named failure group, one hypothesis, expected
residual change, allowed inputs, at most two variants, fitting/checking groups,
predeclared pass/regression rules, actual native outputs, adopt/reject/inconclusive,
and the next stage supported by evidence. Freeze comparison masks and unchanged
stages. Numerical solver or coverage failure is not proof of model incapacity.
No open-ended sweep, silent target change or promotion based only on an average.

## Milestone 1 — Verified collection and honest split

Inventory all candidate RAW/HEIF pairs using filesystem facts first. Verify camera,
capture identity and VV2 settings through guarded metadata reads. Record unavailable,
rejected and unknown cases. Audit all prior training, fitting, selection and visual
inspection. Group whole bursts/shoots; time gaps/dates are clues, not independent
scene proof. Freeze final reserve before new fitting. Assign remaining eligible
shoots to training/development with lighting/ISO/lens/exposure coverage. Do not
train on everything and then reuse those pairs as an independent test.

Deliver: private manifests, prior-use ledger, group/coverage counts and split rules.
Gate: no cross-role shoot leakage; actual reserve independence verified. If reserve
coverage is insufficient, continue development and keep final acceptance open.

## Milestone 2 — Broad frozen-baseline failure report

Run the current recipe against development camera HEIFs using actual native output.
Retain old hard controls; extend evaluation across the verified collection.
Report whole-image/region gates, residual maps, clipping, geometry uncertainty,
native crops and grouped/worst-case failures. Establish repeatability and a
self-comparison error floor before tuning. Audit the metric with known colour,
geometry, clipping, noise and detail perturbations at fixed viewing scales. Compare
linear-light/spatial preparation and an explicitly supplementary LDR-FLIP candidate
without silently changing old scores or gates. Add original mean-region scoring where
current median diagnostics cannot establish it.

### Required comparison contract

1. Compare actual final HEIFs in the same colour space, orientation, crop and
   scale. Never compensate exposure, white balance or saturation during scoring.
2. Measure alignment independently of the candidate recipe. Publish both the
   unregistered output and colour scores over reliably corresponding locations;
   report excluded/unknown coverage explicitly. Alignment cannot hide lens errors.
3. Compute colour differences at corresponding pixels before pooling. Report
   mean, p95, error maps and every frozen difficult region. Independently pooled
   median colours are diagnostic only and cannot pass matching acceptance.
4. Check native detail separately using identical crops and edge/halo/noise
   measurements. Test LDR-FLIP as a supplementary perceptual map under declared
   viewing conditions; adoption requires calibration and the dependency ADR.
5. Report every image's outcome, worst cases and equal-shoot summaries. Neither
   an overall mean nor a median can conceal an image or region that fails.

### Measurement feedback loop

Freeze a development-only calibration set and known perturbations before running
it. Test identity, colour round-trip, known shifts, exposure/saturation changes,
local casts, opposing local errors, clipping, blur/halos and noise. Record which
measurement detects each change, its geometry sensitivity and numerical floor.
Compare historical encoded-space blur with linear-light/spatial preparation while
retaining both scores; changed measurement values are not algorithm improvements.

Deliver: a versioned comparison contract, perturbation response report, colour
error maps, native crops and baseline failure attribution with coverage. A metric
that misses a deliberately introduced relevant defect returns to measurement work.
Unknown correspondence returns to alignment work. Neither outcome authorizes
increasing recipe complexity.

Gate: the comparison reliably detects the declared defects and distinguishes
colour, alignment and detail failures on development material. Keep original
engineering thresholds until a demonstrated measurement defect justifies a
versioned revision. Do not adopt new rendering coefficients while this audit is
open. Research identifies candidates; only measured calibration selects them.

## Milestone 3 — Capacity versus automatic selection

For representative recurring failures and good controls, fit individual settings
against targets offline. Begin with existing explicit stages; expand the compact
matrix/tone/global-field diagnostic only if necessary. Separate spatial fit/check
areas with support buffers, audit colour coverage and convergence, and inspect
signed residuals. Fitted regions measure expression only, not generalization. Reduced-linear-input
fitting is an initializer: verify native-order loss and sampling/convergence before
treating its failure as insufficient global capacity. The native-order audit now
confirms material order differences; bounded four-control native fits still fail
the original whole-image gates. Native direct-DE00 tone/normalization fits improve whole-image results on five
of seven failures, but every failure still has reliable-region failures. A native
per-image channel-curve/9-cubed profile with joint monotone RGB fitting also fails;
the high-ISO surrogate converges without passing HEIF matching. Other channel
solves remain bounded, not globally certified. Sparse source-edge/noise sampling
and a point-RGB objective do not establish insufficient global capacity. Continue
with a native-order low-frequency fitting-objective and sampling audit before
adding prediction or local capacity. See
[normalization and solver evidence](../research/2026-10-02-native-normalization-and-profile-capacity.md). See
[native-order evidence](../research/2026-10-02-native-order-fitting-diagnostic.md). The completed bounded colour
and sequential-tone diagnostics are recorded in
[expression research](../research/2026-10-01-global-expression-and-tone-diagnostics.md).

Branches: individual fits work/shared recipe fails -> Milestone 4 parameter
prediction; both fail -> inspect native input/clipping/representation/solver before
adding capacity; reliable spatial residual persists -> Milestone 5. Diagnose each
failure class; six fitted controls do not prove capacity everywhere.

## Milestone 4 — Shared fit and justified RAW-only adaptation

Fit with the eligible training collection and balanced shoot/condition sampling.
Keep natural-distribution evaluation unchanged. Compare increasing training sizes
against fixed development groups to identify data versus model limits.
If justified by Milestone 3, compare a compact metadata/statistics parameter
predictor with the fixed baseline. Allowed features come only from RAW. Basis-LUT
blending is an escalation when current controls cannot represent successful global
fits. Use ablations and neighbouring frames to reject unnecessary inputs and abrupt
changes. Fit interacting stages jointly where necessary.

Gate: all development limits and old hard controls pass, native quality is retained,
and unseen-shoot benefit supports the added complexity. Failures return to their
measured cause; do not merely increase model size or weight a few anchors harder.

## Milestone 5 — Local processing and native detail, only as needed

Prove a spatially varying residual that global per-image fits cannot remove before
adding bounded edge-aware local tone/colour processing. Fit/check separated areas
and inspect halos/skin boundaries/highlights. Handle denoise/sharpening as separate
native-detail operations, with ISO and neighbour stability checks. Retain technical
and lens ownership. Changing native development invalidates derived training data.

Gate: actual native HEIF passes colour and detail checks on development groups;
otherwise reopen the responsible boundary with a bounded diagnostic.

## Milestone 6 — Frozen independent paired acceptance and delivery

Freeze source, decoder controls, recipe/predictor, output and measurement contract.
Test untouched paired targets against every acceptance gate. Camera HEIFs are
mandatory matching targets here; RAW-only/public files supply additional export
reliability checks only. Run final input-independence, cancellation, metadata,
format, CPU/Metal and resource checks on the same final tree.

A failed test becomes development data and reopens the measured failure stage;
obtain fresh independent acceptance. Unavailable data/API limits are limitations,
not completion. Keep reproducible calibration and verification instructions.

Run the repository's monitored script/check.sh for source changes and standalone
checks, self-review fidelity/architecture, update current-state docs, integrate
through PRs, and complete cleanup. Delete this plan only after matching acceptance
and delivery both succeed. Document-only corrections use the lightweight gates.

## Execution contracts after the October 3 research synthesis

Follow [pipeline and improvement-loop research](../research/2026-10-03-camera-match-improvement-loop-synthesis.md).
Retain RAW9, separate lens ownership, all old difficult controls and current limits.
Reduced guidance may predict native transforms; reduced point-RGB fitting must
prove that it predicts actual native improvements. Separate ownership permits
joint fitting of interacting tone/colour stages.

1. **Native source:** finish verification and integration of the existing source
   contract. Its matched100-capture pilot cleared no failure; do not rerun463
   exports for source scale alone or promote that pilot model.
2. **Objective audit:** freeze existing green/cyan/foliage/daylight failures and good
   controls, one model family and at most two variants. Compare fitting predictions
   with actual native look-before-reduction and emitted HEIF colour/region outcomes.
   Isolate source preparation, blur and loss/prior effects. Report signed residuals,
   loss ranking, resolved/introduced failures and unchanged optical coverage. Repair
   only demonstrated mismatches; a changed metric or lower surrogate is not acceptance.
3. **Expression by class:** obtain bounded native diagnostic evidence for unresolved
   green/foliage and other classes. Successful individual fits permit shared inference
   work for that class. Nonconvergence/budget exhaustion reopens numerical diagnosis;
   reliable failures with adequate fits reopen representation/input boundaries.
4. **RAW-only selection:** compare declared exposure, colour-distribution, clipping
   and gradient summaries plus existing metadata against metadata-only conditioning,
   retaining the bounded correction field. Use training groups and group-held-out
   validation; no target features at inference. A learned thumbnail-to-basis-LUT
   selector is an escalation only when this experiment and residuals justify it.
5. **Local/detail:** add edge-aware local processing only for reliably spatial errors
   surviving adequate global expression. Inspect native edges, texture, halos,
   fringes and flat-region noise separately; retain noise-realization tolerance.
6. **Broad/final:** a screen candidate must resolve a declared image/region failure
   while preserving old passes before full204 expansion. Report every regression,
   group/worst case and native crop. Freeze the complete candidate before consuming
   >=50 unused verified pairs from >=10 independently checked shoots. Acceptance
   failure becomes development evidence and requires fresh final-test material.

Every cycle has a written hypothesis, allowed inputs, unchanged stages, named
failure group, at most two variants, compute budget, fit/check groups and frozen
regression rules before fitting. End with adopt/reject/inconclusive and the one
next action supported by evidence. Distinguish photographic progress from numerical
or infrastructure repairs. Keep actual HEIF, pixelwise mean/p95, fixed regions,
unregistered/reliable-correspondence views and native detail; median diagnostics
and offline LDR-FLIP do not replace acceptance. An unsuccessful fixed screen ends
that bounded experiment rather than starting a knot, prior or iteration sweep.

### Completed order/class checkpoint

The frozen nine-control data-loss audit finds one point/native RGB ranking
reversal and three RGB/actual-HEIF perceptual-mean ranking disagreements. No shared
model is changed or promoted. Green's component residual failed derivative
calibration; one Cartesian-direction residual preserves exact DE00 and passes that
numerical gate. Its bounded native fit improves whole mean/p95 to2.053/4.264,
but still fails mean and four declared regions; six remain inconclusive. Foliage's
eight eligible regions already pass while whole HEIF and excluded sunlit foliage
fail. Neither provides universal global expression. Close these bounded fits
without iteration/target/floor sweeps. Keep explicit numerical diagnostics and
route green failures to representation/spatial attribution, foliage to independent
correspondence/detail attribution, and demonstrated original-cyan expression to
shared RAW-only prediction. See
[order and class evidence](../research/2026-10-03-native-objective-order-and-class-expression.md).

### Completed native-opacity and RAW-context checkpoint

The existing native source includes image-dependent Apple denoising. A guarded
zero-luminance-denoising comparison on green produces invalid native encoded alpha
before the look, including at a full-float tap. Its grain/brightness comparison is
invalid; retain default controls. Saved/conditional rendering and calibration now
share finite/opaque source validation. Invalid source support stops publication;
valid green HEIF scores are unchanged. This is a reliability repair, not a look gain.

One frozen RAW-context centroid selector retains six bounded fields and uses
RAW-only brightness/chroma/clipping/gradient features. Matched77-capture fits,
23 group-excluded checks and nine actual-HEIF controls complete: both models pass
23/23 and5/9, with no resolved failure. Context worsens held-out equal-image and
equal-date means. Reject this selector; do not expand it, tune affinity parameters,
or infer that all image-context learning fails. Next, test the fixed field bank's
native blending against the demonstrated original-cyan witness before investing
in another selector. Target-assisted weights measure expression only; successful
blending proceeds to supervised RAW-guide selection, inadequate numerical evidence
to solver diagnosis, and reliable residual to bank/native-training investigation.
See [native opacity and RAW-context evidence](../research/2026-10-03-native-opacity-and-raw-context.md).

## Immediate execution

Continue the plan; photographic acceptance remains open. The original static
profile passes 173/204 development images. The frozen shared RAW-WB/ISO candidate
passes 186/204, resolves thirteen whole-image failures and introduces none; eighty
captures nevertheless have higher mean error. Eighteen whole-image failures,
original hard-region failures, native detail and independent acceptance remain
open. No experimental model is promoted. See
[conditioning evidence](../research/2026-10-02-raw-metadata-conditioning.md).

The training corpus now contains 463 capture-verified pairs on the same 36 assigned
training dates. The added 201 were selected by materialized-file availability
before pixel reads; the revised split is explicit and is not an exact recovery of
the lost temporary manifest. Development dates and the new reserve stay excluded.
WB/tint substitution, equal-date 262/463 fits, capped source-colour weighting,
combined WB/ISO/tint and a five-cube colour field failed the fixed nine-control
screen or removed no failures. Reject those variants;
do not continue weighting or knot sweeps without a new measured cause.

The native sampler previously erased the original eight-by-eighteen-pixel cyan
region with its inset. Full scored-region support corrects that omission. A bounded
six-iteration native field fit now passes the whole image (mean/p95 1.738/4.759),
face (1.030) and white shirt (0.910), but cyan remains a measured failure at 2.108
and one reliable grid region fails at 2.043. Five of twenty declared regions fail
and three remain inconclusive. This target-assisted witness is not inference;
budget exhaustion is not global incapacity. RAW-only source/preparation audits and
expanded training results are recorded in
[source coverage and region support](../research/2026-10-03-source-coverage-and-native-region-support.md).

A matched100-capture native-input pilot corrects reduced-decoder training input
and a reproduced opacity/sample-support defect. It still passes five of nine:
no failed case becomes a pass. Keep the consistent native source contract but
reject the model as a promoted camera match. Close source-scale consistency as a
sufficient explanation; do not export the entire corpus for that hypothesis.
The shared-learning gap remains. The native order/class audit and bounded
RAW-context cycle are completed above. Test fixed-bank native blending for the
demonstrated original-cyan witness; keep green representation/spatial attribution
and foliage correspondence/detail attribution open. See
[shared models and native source](../research/2026-10-03-shared-model-and-native-source-pilot.md).

Next actions and feedback loops:

1. The bounded gradient audit and reproduced small-residual solver repair are
   complete. Actual cyan HEIF outcomes are unchanged, so close that investigation;
   do not extend iterations or floor/step sweeps. Residual derivative uncertainty
   remains a limitation. The bounded region-feasibility fit now passes the original
   cyan/face/white regions and whole native HEIF within the existing field. One
   reliable grid colour failure and unknown/sensitive areas remain. Close that
   original-cyan expression investigation without more sweeps. The shared objective audit and first RAW-context cycle are complete. Test native
   blending inside the fixed shared field bank before another predictor; retain
   this target-assisted witness as expression evidence only. All old hard regions, native detail and full204 regression remain
   gates. See [gradient evidence](../research/2026-10-03-native-objective-gradient-and-curvature.md)
   and [region feasibility](../research/2026-10-03-native-region-feasibility.md).
2. Separately attribute daylight tails to colour, fixed correspondence and optical/
   detail coverage. Publish unregistered results and reliable corresponding-area
   results together. Unknown geometry stays unknown; deferred lens work cannot be
   absorbed into the colour recipe or hidden through registration.
3. Quantify native texture, edge/halo and flat-region noise against separate HEIF
   targets. Source ranges are association diagnostics, not a reason to alter RAW9.
   Change detail processing only for a demonstrated defect; re-export derived
   training data if native development changes.
4. Successful expression witnesses proceed to shared RAW-only prediction/training,
   fixed development screens and the full 204-image regression collection. Every
   old difficult region remains a gate. Add capacity or local processing only when
   reliable residuals and numerical evidence justify it.
5. Keep the reserve pixel-untouched until a candidate and measurement contract are
   frozen. Its seven provisional groups are below ten independently checked shoots.
   Complete the independence/coverage audit and obtain eligible additional groups;
   neither date subdivisions nor development results may replace final acceptance.

Historical embedded-camera comparisons and preview-guided recipes remain excluded.
Private media/provenance remain in the user-authorized ignored persistent corpus;
see [input audit](../research/2026-10-02-input-provenance-and-local-corpus.md). No
app integration or custom lens profile work is introduced. Delete this plan only
after every matching, native-quality, generalization and operation gate succeeds.
