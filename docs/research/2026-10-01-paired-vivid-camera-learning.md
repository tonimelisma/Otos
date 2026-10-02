# Paired RAW / vivid camera HEIF learning

Date: 2026-10-01. This research pass addresses how to use the user's existing
paired collection to reproduce the camera's vivid HEIF appearance from sensor RAW.
It proposes an execution protocol; it does not report a new trained model,
new corpus inventory, or successful photographic acceptance.

## Objective and boundary

The camera HEIF is the target for training and evaluation. Inference consumes only
sensor RAW and capture metadata available from that RAW. Retain macOS decoder 9,
standalone processing, native-resolution 10-bit SDR HEIF and separate lens handling.
Custom lens profiles remain deferred. Read originals only with the existing
immediate materialization guards; keep generated data outside original folders.

The previous change from camera matching to independent authored-look acceptance
was unjustified. RAW-only inference does not imply target-free evaluation.
Successful exports do not establish camera matching. No matching acceptance gate
is waived by this research. Existing original thresholds and independent paired
acceptance remain pending; later median-region measurements do not automatically
satisfy the original mean-region gate.

## Primary evidence and applicability

1. [Nam and Kim, ICCV 2017](https://arxiv.org/abs/1707.08350) model scene-dependent,
   spatially varying camera processing using global and local context. Their
   RAW-to-sRGB problem is directly relevant in direction and purpose. It supports
   testing context dependence; it does not establish which Sony VV2 operations
   vary or that their model meets our acceptance limits.
2. [ParamISP, CVPR 2024](https://arxiv.org/html/2312.13313v2) separates canonical
   demosaic/WB/colour conversion from learned global and local processing. It
   conditions processing on capture parameters and reports controlled ablations.
   Its global module predicts parameters for explicit transforms. This supports
   retaining a native decoder and learning downstream corrections and settings.
   Its examples, training recipe and reconstruction scores are not ILCE-6700
   HEIF acceptance proof. Our predictor must obtain parameters from RAW, even
   where the paper obtains corresponding fields from rendered-image EXIF.
3. [Image-adaptive 3D LUTs](https://arxiv.org/abs/2009.14468) learn basis tables and
   predict blending weights from a reduced input image. A different global colour
   transform can therefore be selected for each image, while application remains
   inexpensive at native resolution. This does not provide local correction:
   equal input RGB values within one image still receive the same output.
   [Author implementation](https://github.com/HuiZeng/Image-Adaptive-3DLUT).
4. [HDRnet](https://groups.csail.mit.edu/graphics/hdrnet/) learns paired reference
   processing through predicted local affine transforms on a bilateral grid and
   full-resolution edge-aware application. This supplies a concrete escalation
   family when whole-image transforms demonstrably leave spatial errors. Published
   speed does not measure our macOS implementation.
5. [CameraNet](https://arxiv.org/abs/1908.01481) separates restoration and
   enhancement. This supports distinguishing detail/noise reconstruction from
   broad tone and colour matching. Its two-target training procedure is not
   immediately applicable: we have camera targets, not a separate verified clean
   restoration target.
6. [MIT-Adobe FiveK](https://data.csail.mit.edu/graphics/fivek/) demonstrates paired
   photographic adjustment over 5,000 RAWs and five expert renditions, with broad
   scene and illumination coverage. It establishes a supervised-learning precedent,
   not a substitute target for the user's camera style.
7. [SID author repository](https://github.com/cchen156/Learning-to-See-in-the-Dark)
   explicitly separates scene IDs and sequence/burst indices and documents known
   misaligned pairs. Its low-light, different-exposure task is different from ours;
   the relevant lessons concern grouped examples and correspondence validity.
8. [Samsung S24 RAW-sRGB dataset](https://github.com/SamsungLabs/time-aware-awb/blob/main/s24-raw-srgb-dataset/README.md)
   describes 3,224 RAWs with separate camera-generated and expert/style targets,
   metadata, explicit splits and a small RAW/rendered pixel shift from ISP crop.
   This is a recent same-camera paired-data precedent. Different target styles
   must remain distinct; even same-camera capture pairs need crop verification.

Much of this methodology was already present in the September 27 research and
original Plan 0105. This pass reinforces their paired supervision, conditional
processing and capacity-versus-prediction framework. The principal correction
is executing that framework against the actual target and larger collection.

## Recommended protocol (not yet executed)

### 1. Establish the usable collection and reserve

Inventory all candidate pairs, then verify camera, same capture, look/settings,
orientation, crop/profile and allowed metadata. Keep unknown settings explicit.
Record prior training, fitting, selection and visual inspection. Previously
consumed images can provide development evidence but cannot become untouched.

Group entire bursts and shoots together. Dates/time gaps are useful grouping clues,
not proof of independent scenes. Reserve the final paired test before tuning.
Allocate the remaining shoots to training and development with lighting, ISO,
colour and lens coverage. Publish the coverage table and counts; percentages
cannot be chosen responsibly before inspecting the available group distribution.

Do not train on every pair and then claim an independent test on the same data.
Use all verified eligible pairs within their assigned roles. Imbalance matters:
1,000 nearby baby photographs are not 1,000 independent lighting conditions.

### 2. Measure the frozen baseline broadly

Render the current recipe using the actual native renderer and score its decoded
HEIF against each development target. Use geometry independently of candidate
colour. Retain valid coverage and all excluded/inconclusive regions. Keep lens
residuals separate from colour fitting.

Report per-image and per-shoot colour errors, fixed difficult-region errors,
clipping and full-resolution detail/noise differences. Include every original
threshold failure, worst cases and predeclared groups. Broad low-frequency colour
scores and full-resolution artifact checks have distinct jobs. Do not treat the
aggregate mean or successful encoding as completion.

### 3. Identify capacity versus prediction

On a development diagnostic subset covering recurring failure types plus good
controls, fit the existing global stages individually against each target.
Separate spatial fitting and checking areas with buffers. Verify colour coverage
and optimization convergence before interpreting failed fits. Target-assisted
fits remain offline diagnostics, never runtime procedures or independent accuracy
proof. A fitted patch establishes fit quality only.

- Individual fits work, shared recipe fails: test predicting global settings from
  RAW metadata and RAW-derived image statistics. Compare metadata, image statistics
  and their combination against the fixed baseline on separate development shoots.
- Both fail with global structured residuals: investigate the input boundary,
  irreversible clipping, colour representation, transform capacity or solver.
- Both fail with reliable spatial residuals: test one bounded local-processing
  family, such as a bilateral-grid correction, with the same held-out areas.
- Alignment uncertain: repair measurement and retain the affected accuracy result
  as inconclusive. Do not increase model complexity to explain an unknown error.

### 4. Fit and compare justified candidates

Use the eligible training collection, balanced across shoots and relevant
conditions, to fit shared operations or an evidence-justified predictor. Preserve
natural-distribution evaluation, so colour-balanced training cannot redefine
success. Test larger training subsets on the same development shoots to determine
whether additional data improves performance or the model is limiting it.

Keep technical normalization, tone, colour and detail stages explicit, but allow
joint fitting of interacting parameters. Stage ablations establish contribution,
not independent physical correctness. At most two variants per hypothesis; freeze
pass and regression rules before results. Require improved named failures without
concealing existing failures in an average. Inspect neighbouring frames for abrupt
settings changes. Do not add focal/lens dependence to shared colour processing to
absorb uncorrected lens defects.

A compact parameter predictor is the preferred first adaptive candidate when
individual global fits succeed. Basis LUT blending is the next global option if
current controls are insufficient. Local processing requires spatial evidence.
A full RAW-to-RGB network is an escalation only if native development demonstrably
prevents matching; the cited literature does not justify replacing decoder 9 now.

### 5. Freeze and accept against paired targets

Freeze decoder settings, source, recipe/predictor, colour/output contract and
measurement. Run the untouched paired test with the original scope requirement
of at least 50 pairs from 10 independent sessions. This is the project's existing
minimum, not a universal statistically sufficient sample size. Report coverage,
all failures and session variability; use more pairs when available.

A failed final test reopens diagnosis and consumes that test set for development;
it cannot remain labelled untouched. Matching, native detail and operational
reliability must pass together. If coverage or an API boundary prevents proof,
keep the plan active and state that limitation. Research cannot guarantee exact
Sony reproduction or establish that hidden camera state is recoverable from RAW.

## Feedback record for every experiment

Record: baseline version; named failure group; hypothesis and expected residual;
allowed inputs; single change and up to two variants; training/development groups;
predeclared improvement/regression limits; actual native outputs and metrics;
adopt/reject/inconclusive; and the specific next stage justified by the result.

## Current evidence boundary

The existing 18-image development comparison has seven original whole-image
threshold failures. The six explicitly fitted hard examples are training controls,
not independent generalization evidence. Three region measurements remain
inconclusive. The 99 RAW-only exports support operational/format claims, not paired
camera-match acceptance. These facts are from current local artifacts and the
existing validation report, not new photographic testing in this research pass.

No originals were read, downloaded or modified in this research pass. No pipeline
coefficient, runtime dependency or app behavior changed. The next measurable
artifact is a verified paired-corpus coverage/split table and a broader frozen
baseline failure report, followed by the bounded capacity diagnosis above.

## Filesystem inventory refresh

A metadata-only traversal of the current OneDrive Pictures tree finds 3,969 RAWs,
3,768 same-directory/stem RAW/HEIF candidate pairs and 201 unpaired RAWs across
57 paired capture dates. Of those pairs, 487 have both files local and 573 have
a local RAW. Candidate names do not establish camera/look/capture verification.

Grouping all RAWs by adjacent gaps greater than two hours yields 72 temporal
groups, 70 containing pairs. After including actual previous pixel artifacts and
known fitting/selection inputs, every temporal group contains recorded prior use.
This conservative audit finds zero untouched paired temporal-group candidates;
it does not certify semantic shoot boundaries or prove that finer independent
shoots cannot exist. Do not manufacture a new untouched split by renaming groups.

The unmaterialized paired RAWs account for 113.62 GB of logical bytes; available
disk space is approximately 54.07 GB at audit time. Downloading all originals is
therefore not viable. Use a representative, coverage-balanced training expansion
and bounded development batches within measured space, preserving originals and
all generated evidence. Metadata verification of the 487 local pairs is running.
Private evidence: `/tmp/otos-sony-harness/paired-corpus-v2/` inventory, groups,
prior-use ledger and summary. This refresh reads filesystem facts, not media bytes.
