# 0105 — Implement an accurate Sony rendering pipeline

Status: active implementation plan; no stage below is newly completed by writing
this document. Opened September 27, 2026. The user requests a staged plan from
simple to complex that ends in an actually accurate, implemented transformation.

## Objective and completion boundary

Implement a native macOS rendering component that develops supported Sony
ILCE-6700 RAWs into images closely matching the verified Sony VV2 companions,
including the currently poor indoor cases and visible edge discrepancies. Supply
a callable full-resolution renderer, reproducible training/calibration and
validation tools, and a faithful A/B inspection surface. Saved equations alone,
synthetic conformance alone and lower average error alone do not complete this plan.

The first accuracy claim is camera/look/input-contract specific. A separate
neutral-RGB entry point must declare its input color space, transfer, range and
prior development; arbitrary bland-looking RGB is not an interchangeable input.
Validate any generic-input claim separately. Do not claim exact Sony internal
pipeline recovery or byte-identical JPEG/HEIF reconstruction.

Retain the user's constraints: Apple-native frameworks, no new external
training/runtime dependencies, originals read-only, no media or sampled RGB in
Git. The user's authorization covers deliberate earlier OneDrive materialization.
Gate original reads with the materialization detector and use the existing demand
coordinator in product code. Keep datasets, photo-specific manifests and viewer
assets private. Do not delete originals or calibration material as part of this
plan without an explicit deletion request.

## Existing evidence and its limits

- [Original recipe](../research/sony-vv2-reference/README.md): reproducible RAW8
  development and color mapping; a baseline, not accepted photographic accuracy.
- [Native detail study](../research/2026-09-23-sony-vv2-native-detail.md): useful
  crop comparisons; no demonstrated need for mandatory extra sharpening in that
  sample. Re-evaluate after changes to development/color/geometry.
- [Failure analysis](../research/2026-09-26-sony-lens-and-indoor-color.md): temperature
  correction improves averages but regresses some images; 18 mm residual warp
  helps three previews but lacks broad and native-resolution validation.
- [Methods review](../research/2026-09-27-sony-matching-methods.md): primary sources
  for calibration, adaptive LUTs, local transforms and preview-assisted matching.
  Its proposals have not been executed.

Freeze the initial supported scope from the inventory before tuning. It must
include the already identified indoor/green-tent failures and original gallery
photos 2, 3 and 6. Do not retroactively declare difficult cases unsupported to
obtain a pass. New camera bodies and looks remain explicit later expansions.

Do not promote the current candidates to defaults merely because their artifacts
are complete. Preserve them as named baselines throughout the work.

## Acceptance contract — set before model selection

Stage 1 must implement this scorecard and record baselines before tuning. The
following are proposed engineering release targets, not published universal
perceptual thresholds. Freeze their exact measurement implementation and dataset
before evaluating candidates. If a target proves unsuitable, record why and
version the contract before a fresh acceptance run; never quietly loosen a gate
to pass an already inspected test set.

| Aspect | Initial acceptance target |
| --- | --- |
| Broad color/tone | On each acceptance image, mean CIEDE2000 <= 2.0 over valid low-frequency comparison pixels; 95th percentile <= 5.0. Also report unblurred error. |
| Known hard regions | Every preselected failure region has mean low-frequency CIEDE2000 <= 2.0, and no visible broad cast/brightness mismatch or new artifact in agent-operated A/B review. Include indoor and green-tent regressions. |
| Geometry | 95th percentile residual displacement <= 0.5 native pixel over independently checked reliable features, including edges/corners; no systematic curvature/crop error. Report rejected coverage and uncertainty. |
| Detail | No systematic edge halos, softened texture, chromatic fringes or excess noise in native-resolution crops. Report edge/detail and flat-region noise measures; do not optimize for reproducing Sony's individual noise realization. |
| Generalization | An untouched acceptance set targeted at >= 50 pairs from >= 10 distinct sessions, separate from training/selection sessions, with verified coverage of the claimed lighting/ISO/lens scope. Insufficient available coverage limits the claim; it is not a pass. |
| Regressions | Report every failed image/region, worst examples and predeclared lighting/ISO/focal strata. Existing accurate scenes must remain within the absolute gates; no trade of severe indoor failure for lower outdoor average. |
| Reproducibility | Final CPU/GPU conformance, full-resolution photographic evaluation and A/B assets come from the exact same versioned pipeline and model. Synthetic tests cover malformed models and domain boundaries. |
| Operation | No silent decoder/model/input substitution, accidental hydration, original writes, stale-result application or media work on MainActor. Measure latency/memory/cancellation; keep MainActor below the repository hang limit. |

For low-frequency color evaluation, use a fixed 768-pixel long-edge evaluation
scale and Gaussian sigma 1.2 evaluation pixels, not an image-dependent blur. Both
images use the same crop, transfer/profile and resampling convention. Masks
exclude unreliable correspondence, never merely high-error colors. Record valid
fraction and clipping separately; inspect excluded/clipped regions visually.
Fix D65 Lab conversion and test CIEDE2000 against published reference cases.
The targets may require refinement after a registration/noise error-floor audit;
uncertain correspondence cannot certify subpixel accuracy.

## Stage 1 — Build one trustworthy measurement harness

**Work**

- Inventory pairs safely, verify capture identity and exact look/settings, and
  sample deliberately across lighting, ISO, lens/focal length and exposure.
  Treat unavailable files as unavailable; log materialization outcomes and bytes.
- Split by capture session/burst before fitting. Use the already reviewed worst
  photos as a permanent regression set, not as untouched acceptance data.
  The previously examined 19 dates belong to development/selection evidence.
- Separate training, model selection, regression and untouched acceptance roles.
  Store private manifests outside Git; retain portable split rules and aggregate
  coverage in research. Once acceptance examples influence changes, move them to
  development and obtain a fresh acceptance set.
- Implement consistent color, alignment, native detail and clipping measurements.
  Give images equal aggregate weight; report strata and session-level uncertainty.
- Make the viewer use those same render outputs, with fixed profile, crop, zoom,
  full-frame toggle, corners, native crops and labeled baseline/candidate/Sony.
  Report unregistered output geometry separately from measurement registration.

**Deliverable:** a native command-line evaluation harness, private corpus/splits,
scorecard and A/B page with the current failures reproduced.

**Gate:** repeated baseline runs agree within a documented numerical tolerance;
color-space mistakes, mismatched captures and registration confidence are checked.
No optimization starts while the comparison itself is unreliable.

## Stage 2 — Correct input, output and geometry fundamentals

**Work**

- Audit sensor development versus embedded preview, decoder version, white balance,
  exposure, working/output profiles, transfer functions, extended values, clipping,
  orientation and scale. Use floating point until final output conversion.
- Confirm native processing controls actually change the image as expected;
  preserve a complete development recipe and reproducible output contract.
- Decode the relevant embedded lens parameters or establish a measured native
  correction model. Separate distortion, image scale/crop, vignetting and lateral
  chromatic aberration. Avoid applying the same correction twice.
- Extend geometry validation beyond three 18 mm previews: focal-length range,
  orientation, focus variation where observable, and full resolution. Do not use
  unrestricted per-target warps as the deployed correction.
- Establish reliable correspondence/masks for color fitting. Track remaining
  geometry defects separately instead of letting a LUT compensate for them.

**Deliverable:** a stable decode/output boundary and geometry correction with
explicit supported scope; baseline color samples are regenerated if it changes.

**Gate:** comparison conventions are proven and geometry meets its target within
supported coverage. Missing lens metadata remains a measured limitation to solve,
not an excuse to declare the entire pipeline finished.

## Stage 3 — Find the simplest transform that can match each image

This is a target-assisted diagnostic, not a deployable RAW-only predictor.

**Work:** on representative failures and good controls, fit this ladder in order:

1. Exposure and black offset; white-balance gains/tint.
2. A color matrix and smooth tone curve, comparing luminance versus channel curves.
3. A regularized global 3D LUT; try a small resolution first and increase only
   when held-out-region improvement demonstrates insufficient capacity.

Use separated spatial fitting/validation blocks with filter-support buffers,
repeat partitions, and report color coverage. Constrain exposure/matrix scale and
curve endpoints to avoid redundant free parameters. Use robust fitting, multiple
initializations for nonlinear models and fixed comparison masks. Inspect signed
channel errors and residual maps in addition to scalar loss.

**Deliverable:** a per-image error breakdown showing which operation removes each
kind of mismatch, with fitting and held-out-region results.

**Gate/branch:** if compact global models meet the color gate, move to Stage 5.
If they do not, execute Stage 4 before assuming that a larger learned model is
necessary. Poor optimization or inadequate sample coverage is not proof that a
model family cannot work.

## Stage 4 — Test an earlier development boundary, only if needed

**Work**

- Compare current encoded neutral RGB with a documented linear, extended-range
  representation on exactly the same captures. Test premature clipping and gamut
  mapping explicitly. Do not merely undo sRGB gamma and call the result sensor RGB.
- Probe `CIRAWFilter.linearSpaceFilter` and other exposed controls experimentally;
  do not assume undocumented stage order or an unprocessed sensor-RGB tap.
- In a suitable linear domain, compare a matrix against a compact root-polynomial
  color basis before tone styling. Define handling of negative/out-of-gamut inputs.
- Refine only the controllable native stages shown to matter. Treat Apple RAW
  decoding as a black box for optimization unless gradients are actually available.

**Deliverable:** an evidence-backed choice of input boundary and exact stage order.

**Gate:** repeat Stage 3 with the chosen boundary. If neither boundary permits
adequate global fits and residuals are spatially structured, mark Stage 8 required.
If Apple development demonstrably loses needed information, investigate a native
replacement for the offending operation; do not hide an incompatible dependency
or silently substitute a different input pipeline.

## Stage 5 — Implement and test a fixed shared pipeline

**Work:** fit the smallest successful Stage 3/4 structure across training images.
Start with matrix/curves; add a smooth residual LUT only if necessary. Select
regularization and table size on development sessions. Test robust/color-balanced
fitting while retaining natural-distribution evaluation. Jointly or alternately
refine the selected stages rather than indefinitely stacking corrections on a
clamped baseline. Keep the original recipe as a separately measured comparator.

**Deliverable:** a reusable native renderer with fixed parameters, used by the
harness and viewer; synthetic CPU/GPU fixtures and input validation.

**Gate/branch:** if it meets selection-set color gates, skip unnecessary adaptation
and proceed toward Stage 9. If individually fitted models succeed but this shared
model fails, proceed to Stage 6: the problem is choosing parameters per image.

## Stage 6 — Add adaptation, from simple metadata to image context

**Work, in order**

1. Smooth metadata conditioning: WB gains or temperature/tint, then log ISO,
   exposure and verified camera-look settings. Ablate each addition.
2. Small regressors using image statistics such as luminance/chroma distributions,
   with and without metadata. Handle unavailable metadata explicitly.
3. A small image-context predictor blending a few basis LUTs, only if the first
   two approaches leave a substantial prediction gap. Use native training tools.

Training and inference may use only inputs actually available in the declared
mode. A field read exclusively from a companion HEIF cannot become an implicit
runtime requirement. Avoid hard scene categories that introduce discontinuities;
check similar frames and exposure variations for stable rendering.

**Deliverable:** the smallest predictor that closes the gap to successful per-image
fits on unseen development sessions, with ablations and regression results.

**Gate:** compare the predictor against the per-image diagnostic and fixed model.
If fit capacity is adequate but prediction remains poor, improve coverage/features
before increasing LUT resolution. If prediction is good but fit capacity is poor,
return to the representation or execute Stage 8.

## Stage 7 — Evaluate preview-assisted matching as a separate mode

This bounded experiment may run immediately after Stage 3. It must not delay or
replace the general transformation path, and it may be omitted from the product
if previews prove unsuitable.

**Work**

- Check native preview availability, provenance, dimensions, crop, orientation,
  encoding and agreement with the separate Sony target across difficult captures.
- If suitable, estimate a smooth tone/color adjustment from sensor development to
  that preview, and apply it to full-resolution sensor development. Begin with
  histogram/tone matching, then matched-region matrix/LUT fitting if needed.
- Keep the separate HEIF withheld from inference and use it only for evaluation.
  Test missing, tiny, differently styled and differently cropped previews.

**Deliverable:** a measured decision to retain or reject this mode, with an explicit
fallback to the general renderer. Never upscale the embedded preview and describe
it as full-resolution RAW development.

**Gate:** it must improve difficult images without introducing preview artifacts
or silently changing the claimed input contract. Its success does not certify the
no-preview or generic-neutral-image renderer.

## Stage 8 — Add spatial processing only for proven local residuals

**Work:** first test a constrained edge-aware local luminance adjustment, then a
small bilateral grid of local color transforms if needed. Escalate to a learned
grid/LUT combination only when simpler alternatives fail. Separate local color/
tone behavior from denoising and texture. Check halos, boundaries, crop dependence,
image-size dependence and stability across nearby frames.

Use a target-assisted local fit to test capacity, then a predictor using only
allowed inputs. A grid that memorizes its target is not a production solution.
Use held-out regions and entirely unseen sessions for their respective questions.

**Deliverable:** native spatial processing with explicit regularization, reference
math, reproducible training and a measured contribution to the error breakdown.

**Gate:** retain it only if it improves held-out failures without causing new edge
or texture artifacts. If global models already pass, omit this stage entirely.

## Stage 9 — Finish native-resolution detail and refine the whole pipeline

**Work**

- Reassess luminance/chroma noise reduction, sharpening strength/radius, chromatic
  fringes and highlight handling using the final color and geometry configuration.
  Begin with existing native defaults; add ISO/content conditioning only if proven.
- Evaluate full frames and sampled native-resolution regions, including corners,
  fine texture, flat dark regions and clipped highlights. Preserve sensor detail;
  do not synthesize texture or reward removal of noise by excessive blur.
- Refit/refine the selected stages together where they interact. Confirm output
  quantization, SDR profile/transfer and resizing behavior; freeze a release model.

**Deliverable:** one complete rendering recipe and component, not a collection of
independently favorable experiments. Report each retained stage's ablation.

**Gate:** all selection-set color, geometry, detail and stability targets pass.
No expensive adaptive stage remains without demonstrated benefit.

## Stage 10 — Run untouched acceptance; failures reopen the responsible stage

Run the frozen final pipeline once against the untouched sessions, plus the
permanent known-failure suite. Generate all metrics and viewer images from that
exact build. Inspect full-frame and native A/Bs as agent-owned verification.

**Deliverable:** a release-quality report with coverage, every failed case, masks,
uncertainty, worst regions, performance and supported input/lens/look scope.

**Gate:** all acceptance targets pass. If they do not, classify the failure and
return to the corresponding stage; the consumed acceptance set becomes development
data and a new acceptance set is required for the next claim. Do not label the
pipeline accurate while known significant discrepancies remain. If data/API
limits prevent a target, report the blocker honestly and leave this plan open.

## Stage 11 — Finish the Otos implementation boundary and durable handoff

Build reusable native code from Stage 5 onward so this step packages and verifies
the measured algorithm rather than translating a different prototype at the end.

- Provide one typed rendering entry point with a versioned development/model/input
  contract. The same implementation drives evaluation, full-resolution file output
  and Otos preview use. Do not create separate approximate preview/export grades.
- Integrate through the existing media/materialization owners when connecting to
  Otos. Work stays off MainActor; define cancellation and stale-result rejection.
  Map the actual current architecture before changing ownership. Do not build a
  general editor, export product or speculative rendering framework just to host
  this algorithm; the full-resolution output harness proves the rendering boundary.
- Handle unsupported cameras/looks/decoders, invalid models and missing inputs
  explicitly. A fallback must not be labeled a verified Sony match.
- Exercise CPU/GPU conformance, malformed input, wide/negative domains where
  supported, clipping, orientation, model-version rejection and deterministic
  rendering. Add meaningful tests at public boundaries; no source-text tests.
- Measure preview/full-resolution time, peak memory and cancellation on the actual
  machine. Record instrumentation and worst spans. Optimize only demonstrated
  bottlenecks, without changing the reference behavior.
- Update implemented requirement rows, architectural decisions/map and any UI
  design specs when the actual changes land. Run the full repository check and
  UI verification for code/UI increments; research/planning-only increments use
  the documented lighter path.
- Preserve source, coefficients, exact equations/contracts, synthetic fixtures,
  training procedure, aggregate photographic evidence and known supported scope.
  Verify inference/conformance with access to the private corpus denied. Keep the
  private corpus available through acceptance; no media deletion is implied.

**Completion:** accurate supported rendering is implemented, all gates pass on
final code, required docs/tests are current, changes are merged and cleaned up.
Only then remove this active plan. New camera/look/input domains require separate
calibration and validation; they are not silently covered by the first release.

## Execution and reporting discipline

Each completed stage produces a dated research result and a concrete working
artifact where applicable. State what changed, what improved, what regressed and
what evidence selected the next step. Use separate scoped PRs for meaningful
implementation increments. Keep this plan's status current until full closure.
Do not substitute a paperwork milestone for photographic acceptance, and do not
run every complex branch when a simpler pipeline already meets the gates.
