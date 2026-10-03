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
| Colour/tone | Frozen format-5 baseline; native comparison of 204 development pairs; 283 training exports available | 77 fail historical unregistered whole-image limits; attributed region failures remain; no accepted matching recipe |
| Region measurement | Pixelwise mean/p95 gate, separate median diagnostics, fixed RAW geometry; six perturbation views and seven-image grid audit | Original hard regions include a warm-face colour failure, a correspondence-sensitivity failure and three inconclusive regions |
| Export reliability | 99 guarded RAW exports, format/metadata/original-integrity/cancellation evidence | That batch did not test matching to camera targets |
| Independent acceptance | 3,768 candidate pairs inventoried; 487 local pairs capture/VV2 verified; prior-use audit | Original 72 temporal groups have prior pixel use; 229 new candidates frozen before pixel use, 208 metadata verified and 21 unavailable; seven temporal candidates across six dates remain below the ten independently checked shoot gate |

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

## Immediate execution

The broad frozen shared-profile baseline has finished: 204/204 exports,
173 whole-image colour passes and 31 failures. Old hard regions remain failing
or inconclusive; whole-image success does not replace them. Report shooting
conditions, tone/colour, detail and lens coverage separately. The temporary training manifest was lost; a newly frozen date-disjoint list
contains 263 candidates, of which 262 are locally copied and capture verified.
Use that explicitly versioned training split rather than claim exact recovery. Historical embedded-camera comparisons and
preview-guided models are excluded; retained RAW-only results require explicit
provenance. See [input audit](../research/2026-10-02-input-provenance-and-local-corpus.md).

The next delivery is a shared RAW-only candidate checked across development
shoots. Sequential/joint fits on 147 and 262 training captures leave the known
failures. Endpoint-inclusive training improves cyan error but still fails; all
four 262-image candidates pass only three of the nine screen captures. Next
compare constant and RAW-WB/ISO-conditioned shared corrections on date-disjoint
development captures, retaining native-order/solver caveats and every hard region; see
[shared-fitting evidence](../research/2026-10-02-shared-training-and-domain-coverage.md). Keep only a
bounded solver audit needed to decide that candidate; stop expanding small-set
diagnostics without a stated decision and stopping condition. Broader fitting
uses training roles only; development roles select candidates; untouched
acceptance remains closed until the candidate is frozen.


Keep frozen inference recipes unchanged. Coupled native colour-field fitting
inside the existing profile produces seven of eight whole-image passes and seven
frozen-region mean passes, with two new correspondence-sensitivity failures. Five
clear those colour diagnostics together. Indoor retains seven region failures;
daylight retains a p95 failure. Signed DE00 component curvature reaches similar
indoor loss sooner without removing those failures. Every fit exhausts its budget.
See [coupled field evidence](../research/2026-10-02-native-coupled-colour-field.md).

Next compare the solver's projected gradient with direct actual-objective finite
differences, including changing tail membership, and audit whether the objective
aligns with every-region gates. Do not infer global incapacity from a coarse
subspace, limited budget or apparent loss plateau. Keep source, field capacity,
fixed geometry and original gates unchanged for that numerical diagnostic. Then
quantify indoor native texture/noise separately and inspect daylight correspondence
and unsampled coverage. Successful justified fits proceed to shared RAW-only
training/selection and the broader development collection, including old hard
regions; no target-assisted per-image model becomes an inference recipe.

Separately attribute the daylight tail to known colour, correspondence and
optical/detail coverage rather than treating unregistered p95 as pure colour.
The completed native range audit found negative channels but no values above1.25;
several indoor failures have nearly no clamped input. Retain source-range/error
associations without asserting cause, and measure noise/detail independently. Do not fit lens defects into colour or change RAW9.
A failed numerical/measurement witness returns to its responsible boundary before
adding local processing or prediction. The unchanged whole-image failures remain
visible and no diagnostic subset replaces acceptance.

Keep the new acceptance reserve pixel-untouched. Metadata verification alone does
not make its seven temporal groups ten independently checked shoots. Complete the
shoot-independence audit and obtain additional eligible groups before final
acceptance; do not manufacture subdivisions or lower that gate.
