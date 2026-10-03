# Standalone Sony RAW rendering and measurement harness

This standalone tool develops Sony ILCE-6700 sensor RAWs into native-resolution
10-bit SDR sRGB HEIFs to match the user's Sony VV2 camera rendering. It runs outside
Otos. The checked-in fixed recipe is a baseline; matching acceptance remains open.
Rendering takes sensor RAW, capture metadata and a versioned recipe only; embedded
previews, camera companions and fitting data never enter inference. Apple's native
lens correction is independently owned and reported. Camera HEIFs are paired
training/evaluation targets. See [ADR 0029](../../docs/adr/0029-standalone-authored-raw-look-boundary.md)
and the [photographic validation and feedback contract](../../docs/research/2026-10-01-vivid-raw9-pipeline-validation.md).
Keep all photo manifests, output PNGs and model fitting data
outside Git. The tool reads originals but never writes to their directories.

## Build and private inputs

Use the full repo Xcode toolchain. Build with `build.sh /private/output-dir`.
The script compiles the standalone RAW 9 look evaluator and runs the published
CIEDE2000 cases, scorecard/geometry fixtures, and 560 synthetic RAW 9 model
CPU/Metal conformance cases, capture-audit fixtures and calibration input guards.
The saved model is
`docs/research/sony-vv2-raw9-reference/model.json`. An installed
ExifTool is needed only for the independent capture metadata audit; the native
renderer and Otos app do not depend on it.

Input manifests have this shape and must remain private:

```json
{"pairs":[{"id":"capture_name","raw":"/absolute/original.arw","target":"/absolute/companion.heif","session":"capture_session","role":"regression"}]}
```

Roles are `training`, `authoring`, `selection`, `regression`, and `acceptance`. A session must
have one role. The public split scripts select by capture names and frozen seed,
but require private inventory/manifests as arguments. The metadata verifier
checks that each ARW and companion have the same camera, time, exposure, lens,
focal length and declared Sony VV2 settings. It checks `SF_DATALESS` immediately
before ExifTool reads either file. Rejected or unavailable pairs do not enter its
verified manifest. Keep its report and the SHA256 of each frozen private manifest.
The look audit requests Sony's namespace explicitly and checks CreativeStyle,
PictureProfile, DRO, contrast, saturation, sharpness, clarity, highlights,
shadows, fade and sharpness range on both files.

### Calibrate the comparison before selecting renderer changes

```text
sony-render-harness comparison-calibrate development.json capture_name /private/audit-whole.json
sony-render-harness comparison-calibrate development.json capture_name /private/audit-native.json native-crop
```

Only `selection` or `regression` roles are accepted; acceptance data is rejected.
The command reads the camera target with its colour profile/orientation, uses a
768-long-edge whole view or an unresized central native crop, and produces known
colour/detail/shift perturbations, DE00 maps and a numerical response report.
Identity and colour round-trip must score zero; known integer shifts must recover
zero local error when the supplied correspondence is correct. All perturbations
use the same display-clamped reference. Extended-range decoded values and the
historical effect of clamping are reported separately. The ordinary linear-light
Gaussian alternative is explicitly not S-CIELAB. PNGs are visual diagnostics;
actual HEIF colour measurements retain floating-point inputs.

Region reports name pixelwise matching outcomes separately from
`diagnosticOutcome` / `diagnosticPasses` for median-colour diagnostics. Whole-image
historical scores are unregistered; separately measured geometry does not itself
make them aligned. Use reliable fixed RAW-derived region correspondence and report
unknown coverage before attributing a failure to colour. See the
[comparison research](../../docs/research/2026-10-01-camera-match-comparison-method.md).
Optional offline FLIP measurement follows
[ADR 0031](../../docs/adr/0031-offline-camera-match-perceptual-diagnostic.md);
it has no app/renderer dependency or accepted release threshold.

### Offline expression diagnostics

`matching-colour-diagnostic-fit` accepts the existing capacity arguments followed
by an explicit `withheldRegions` / `wholeImageExpression` scope and `encodedRGB` /
`normalizedLab` objective. `matching-tone-diagnostic-fit` accepts the existing
`authored-capacity-fit` arguments followed by the same scope. Both call the existing
fitting owner, reject non-regression roles and existing output directories, and
mark expression reports as non-validation evidence. Whole-image expression fits
sampled target pixels; it cannot establish held-out accuracy or global incapacity
when an initializer fails. Actual native HEIFs and independent RAW geometry are
required for checking. No per-photo recipe lookup enters inference.

### Reproduce the fixed baseline

After capture verification, use a manifest containing only `training` roles:

```text
sony-render-harness calibration-export-one training.json capture_name /private/samples
sony-render-harness calibration-fit training.json /private/samples /private/model.json
```

Export each training capture once. Existing pair directories and model files
are rejected. The exporter rejects unsupported camera originals before reading
the target. The fitter requires at least 100 training pairs and finite,
little-endian six-channel Float32 samples under the fixed baseline domain.
It also requires each exported `recipe.json` to match the RAW 9 decoder, neutral
controls, native lens state, sample count, scale and calibration blur.
Sample directories and the fitted model must be outside original media roots.
Fitting uses native Accelerate, with the saved reference's equal-image weights,
isotonic curves, ridge and neighbor smoothness. The exporter retains the original
calibration blur-radius recipe; this is separate from the release scorecard's
Gaussian sigma. Its calibration sample exclusions never change scoring masks.
The explicit `calibration-export-domain-one`, `calibration-fit-domain` and
`calibration-joint-fit-domain` modes retain finite, opaque training samples at
model-domain endpoints. Source samples use the runtime [0,1.25] input clamp and
target samples use [0,1] display limits. Contract 3 records `modelDomain`; ordinary
baseline reproduction retains contract 2 and its interior-only sampler. Fits
reject mismatched sample contracts. This changes training support only: scoring
masks, thresholds, native decoder and runtime capacity are unchanged. The RGB
sample fit remains a surrogate and must pass actual native HEIF evaluation.

`calibration-joint-fit training.json samples initial-model.json output-directory`
reuses the constrained joint curve/LUT solver for one shared training candidate.
It requires at least 100 training-role pairs, rejects existing output directories,
and writes model.json plus coefficient/objective/convergence provenance in fit.json.
Its RGB surrogate is not the native photographic gate. Compare with the sequential
fit on the same frozen samples and evaluate actual HEIFs on date-disjoint
selection captures before promoting either. No per-image fitted model enters runtime.

Native fitting reproduces the saved model to numerical precision. See the
[calibration investigation](../../docs/research/2026-09-30-raw9-calibration-boundaries.md)
for the remaining accuracy gap and rejected candidates.

`sony-render-materialize request input.json status.json` deliberately asks the
File Provider to download dataless originals without a blocking byte read.
`sony-render-materialize status input.json status.json` reports local, dataless,
unknown and requested counts using only inode facts. Requests may fail or remain
pending; do not treat a request as proof that bytes are local. Provisioning entries
require `id` and `raw`; `target` is optional for RAW-only captures. File counts
reflect the actual originals listed, including optional companions. Each command
writes a new receipt outside every listed original's containing directory and
rejects an existing receipt. The manifest itself must already be local. The evaluation
command checks `SF_DATALESS` immediately before every original byte read and
reports unavailable originals rather than hydrating them implicitly.

Run `sony-render-harness sensor-raw-heif original.arw output.heic media-root`
for Apple default development, or `sony-render-harness sensor-model-heif
original.arw output.heic media-root model.json` for the saved fixed look model.
All modes decode native-resolution sensor pixels with RAW decoder 9 and encode
an SDR sRGB HEIF. Apple's lens correction is enabled when supported; unavailable
correction is reported disabled and missing lens identity remains unknown. The media
root argument must contain the original; outputs inside that root and existing
output files are rejected. A JSON result names
the lens, focal length, decoder, correction state, output size, and look mode.
The output preserves whitelisted capture, camera, lens, exposure, and GPS
metadata and normalizes orientation into the pixels. A complete HEIF is
published without replacing an existing file. Batch evaluation uses one
process per image to bound memory retained by the graphics stack.
The callable renderer cooperates with Swift task cancellation between byte reads,
RAW development, model application and encoding. Cancellation observed before
publication throws `CancellationError` and removes the temporary HEIF. A
synchronous framework or GPU operation already in progress finishes before its
next check; cancellation does not interrupt that operation internally.

On this host, full-resolution Core Image HEIF encoding needs normal macOS
graphics access; the restricted command sandbox returns `nilError` even for a
synthetic HEIF. The originals stay read-only.

`sensor-raw-evaluate verified.json /private/output-dir`,
`sensor-model-evaluate verified.json model.json /private/output-dir` render
actual HEIF files and score their decoded pixels against the separate camera
HEIF targets. Each pair gets a JSON result, a full-frame preview and native
corner crops. These commands do not register away native lens differences.
Use development and regression roles while a fresh RAW 9 acceptance set remains
frozen and untouched. The earlier 72-pair set influenced the RAW 9 design.

Run `sony-render-harness evaluate verified.json model.json /private/output-dir`.
The RAW 9 model path is `sony-vv2-raw9-reference/model.json`.
The output directory must be outside all media directories. Each pair writes
one JSON record, full-frame PNGs, and four unregistered 512-pixel native corner
crops. `summary.json` records complete/failure counts; `index.html` compares
only those same outputs. It is a private local page, never a public gallery.

## Score interpretation

- RAW decoding is pinned to `CIRAWDecoderVersion("9")`. The saved fixed model
  receives Apple neutral development; Apple default and neutral are separate
  baselines. The harness errors if the decoder or dimensions do not match.
  Each comparator uses a fresh RAW filter: repeated requests from a rendered,
  scaled RAW 9 filter can change its output extent on this beta toolchain.
- Every color frame is encoded to extended sRGB with a fixed 768-pixel long edge.
  A Vision homography from the fixed-model image establishes common measurement
  coordinates. That same transform is applied to the two Apple baselines. Viewer
  frames remain unregistered so crop and edge discrepancies stay visible.
- Color uses D65 sRGB to Lab and CIEDE2000. A separable Gaussian with sigma 1.2
  evaluation pixels yields low-frequency mean and p95, alongside unblurred mean
  and p95. Invalid/transparent correspondence is excluded, never high color
  error. Valid and clipped fractions are reported separately.
- Independent local gradient correspondence checks 40 spread-out locations after
  the homography. Flat, ambiguous and search-boundary locations count against
  coverage. The score removes only a global translation, then reports median and
  p95 residual in native-pixel units. It is a diagnostic on a downscaled image,
  so it cannot alone certify the plan's half-native-pixel geometry target.
- The native crops provide visual detail/noise/halo evidence but no automated
  native detail pass yet. A separate native geometry diagnostic reads the same
  full-resolution RAW and Sony images at 35 fixed frame locations, selecting a
  textured subpatch inside each tile from the Sony image alone. It matches
  gradient patches without using the preview homography. Flat, ambiguous and
  search-boundary tiles are counted. Its p95 displacement is withheld below
  18/35 reliable tiles or fewer than six outer-frame matches; these are reporting
  floors, not release certification. The
  private JSON retains each matched position, displacement and correlation.
  `prepare-geometry-probe.py` selects the focal extremes of each verified
  training session before results are inspected. Geometry and color failures
  remain separate. Do not fit or select a model using `acceptance` images before
  the final pipeline is frozen.

Run `sony-render-harness lens-audit verified-development.json /private/output-dir`
to compare Apple neutral RAW development with its documented lens correction
explicitly enabled and disabled. This command uses the same native tile matcher
and writes one private JSON record per pair plus a completion summary. It also
records whether the correction is supported and enabled by default. Neither
output is registered to the Sony target; low match coverage is reported, not
treated as a large measured error. Use only development/regression manifests
while the acceptance set remains untouched.

The browser-based A/B controls could not be agent-validated in this environment:
automatic approval review denied opening the private derived-media page. PNG
assets can be inspected locally. That limitation keeps the visual acceptance
gate open; do not route the private page through another browser path.


## Controllable authored look (experimental)

These commands use the same native development and full-resolution renderer.
Recipe format 5 uses extended linear BT.2020 observations developed in an extended
linear sRGB context, RAW 9, and explicit normalization/tone/colour/gamut stages.
A saved recipe has no reference-image dependency at inference.

```sh
sony-render-harness authored-heif original.arw output.heic media-root recipe.json
sony-render-harness authored-evaluate verified-development.json recipe.json /private/output
sony-render-harness authored-calibration-export-one training.json capture_name /private/samples registration-model.json mapped
sony-render-harness authored-fit training.json /private/samples mapped rgbRatio /private/recipe.json
sony-render-harness score-regions candidate.heic anchor.heif geometry-baseline.heic look-card.json capture_name
```

`mapped` / `unmapped` change only native gamut mapping. The offline registration
model and HEIF target never enter rendering. Training requires >=100 unique pairs,
training roles and actual capture-date grouping. Calibration contract 10 rejects
observations exported through the invalid earlier colour boundary. The four fitted
base parameters are contrast, pivot, skew and saturation; technical WB/exposure remain
identity until a diagnosed need justifies adaptation. A reduced-sample fit is an
initializer, not full-resolution photographic acceptance.

The [current input investigation](../../docs/research/2026-10-01-authored-linear-input-and-fitting.md)
records input investigations and rejected experiments. Synthetic conformance is
separate from the measured photographic evidence linked above.


The optional format-5 creative residual is a smooth 5-cubed linear-sRGB colour
field, neutral-protected and independently switchable, before the sole gamut/
transfer stage. Its native constrained solve must satisfy gradient and coefficient
bounds. `authored-colour-fit training.json samples base-recipe.json regularization
output.json` fits the spatial-grid initializer; `authored-colour-palette-fit` uses
the diagnosed source-only palette sampler. Both remain subject to actual HEIF gates.

`authored-capacity-fit regression.json samples mapped perChannel output-directory
look-card.json` produces offline per-image diagnostic recipes. Export regression
observations with the ordinary calibration exporter. Every look-card region plus
12 evaluation pixels is excluded from fitting; actual native HEIFs validate those
regions. These recipes are never a deployed inference lookup. Acceptance roles are
rejected. Measurement report format 6 reports unregistered/locally aligned colour, measured native
correspondence support and common region-placement sensitivity separately. Unknown
correspondence is inconclusive; it never receives a fabricated zero uncertainty.


Recipe format 5 requires `gamutPolicy` (`smoothRadial` or `radialProjection`). The
latter preserves in-gamut display-linear colours and projects only out-of-gamut
chroma. It is a controlled experimental option, not a promoted recipe.
`authored-colour-display-fit training.json samples initial-recipe.json regularization
grid|palette|balanced-palette|global-palette output.json` refines the same bounded colour field through the actual
final gamut/transfer function. The sampling scheme must match the frozen initializer.
`authored-colour-capacity-fit regression.json samples base-recipe.json output-directory
look-card.json regularization` tests offline per-image colour capacity, excluding
all look-card regions and their 12-pixel support buffers from both samplers. Reference
mutation independence, acceptance rejection and no-overwrite fixtures cover this path.

Both executable builds use Swift 6 and complete strict concurrency. Native lens
identity is optional metadata; supported native profiles remain enabled, unsupported
profiles are explicitly disabled/reported and never substituted into colour stages.
Calibration currently uses the known supported-lens subset; rendering does not infer
lens support from the presence of an EXIF lens name. No custom lens profile is applied.

Format 5 replaces luminance-division hue preservation with interpolation between
the independently tone-mapped minimum and maximum RGB channels. It preserves the
input RGB hue at full strength and keeps the pre-saturation result bounded, including
mixed-sign inputs with nearly zero luminance. It does not claim luminance/energy
preservation. Earlier fitted recipes are invalidated; measurement is separately versioned.

Offline final-display fitting can reweight the unchanged source-only palette:
`balanced-palette` mixes half image-weighted mass with half equal mass per occupied
8-cubed source-colour bin; `global-palette` uses equal occupied-bin mass throughout.
The bins and weights never read target colour. The 5-cubed field, coefficient bounds,
regularizer and runtime recipe remain unchanged. These experimental objectives require
native regression and selection evidence; they are not accepted presets.


### Reproduce the current matching baseline

`authored-look-fit training.json training-samples authoring.json authoring-samples
base-recipe.json look-card.json authoring-fraction encodedRGB|normalizedLab output-directory` fits one shared
bounded field. Authoring inputs have role `authoring`; selection, regression and
acceptance roles are rejected. Training and authoring capture-date groups must be
disjoint. These fitted regions are training controls and are never reported as
holdouts or proof that the camera rendering is matched.
The working 0.55 `normalizedLab` recipe is checked in as
[`recipe.json`](../../docs/research/authored-raw9-reference/recipe.json).
It is reproducible byte-for-byte in canonical encoded form. Its photographic
evidence and limitations are recorded in the validation report. It is not an exact
camera reconstruction or a preset validated for other cameras.

Render it without any camera companion or training data:

```sh
sony-render-harness authored-heif original.arw output.heic media-root docs/research/authored-raw9-reference/recipe.json
```


### Fixed geometry for appearance measurement

`score-regions` requires a separately rendered fixed RAW geometry baseline. Use
[`geometry-baseline.json`](../../docs/research/authored-raw9-reference/geometry-baseline.json)
with `authored-heif` on the same RAW. Keep that baseline identical across candidate
recipes; it has no creative residual and is not a camera preview. Candidate tone/
colour must not change correspondence confidence or coverage. Measurement report
format 6 contains `geometryBaselineSHA256`, `correspondencePolicy` and `scores`.
Native-gradient matching preserves confident fine-scale results and retries an
ambiguous match after Gaussian sigma 1.2 smoothing, with the same correlation,
ambiguity and reciprocal-match thresholds. The look-card schema is format 5.
Brightness, colour, chroma and measured relative-correspondence sensitivity limits
are unchanged. Common +/-4-pixel patch-placement sensitivity is reported only as
a diagnostic: it changes the scene content being summarized while retaining the
alignment. Flat/ambiguous matches
remain inconclusive and geometry never enters inference.

`encodedRGB` retains the earlier fitting objective. `normalizedLab` minimizes
squared D65 CIELAB differences divided by 100 (a DE76 proxy); it does not claim to
optimize CIEDE2000 exactly. Only final nonlinear colour-field fitting changes;
RAW input, tone, sampler, bounds and regularization stay fixed. Actual native HEIF
measurement uses the independent CIEDE2000 scorecard.

### Native processing-order diagnosis

`matching-native-order-audit manifest.json capture recipe.json exported.heic report.json`
compares the full-resolution shared Metal look, followed by colour-managed
reduction, with the actual HEIF and the reduced-linear initializer. Selection or
regression data only; unregistered results diagnose processing order and encoding,
not matching acceptance.

`matching-native-order-refine regression.json capture recipe.json grid.card.json frozen-grid.json output-directory`
performs at most 17 native evaluations of existing contrast, pivot, skew and
saturation controls. It freezes independently established baseline grid
correspondences and excludes inconclusive/high-sensitivity areas before fitting.
Equal-region normalized Lab loss uses full scored rectangles after the
historical blur, with a uniform budget of at most 1024 points per region. Small
regions retain all eligible pixels; no inset removes small saturated objects. The field, normalization, decoder and lens settings stay fixed.
This local expression diagnostic does not establish convergence or generalization;
its fitted recipe must go through actual native HEIF and the original scorecards.
No diagnostic target or per-image fitted recipe enters automatic inference.

The refinement command optionally accepts `toneAndNormalization` after the output
directory (25 evaluations rather than 17), followed by an explicit objective:
`normalizedLab` or `meanAndTailDE00`. Normalization varies existing red/blue gains
in linear BT.2020; green and exposure stay fixed. It is an input colour-balance
diagnostic, not reconstruction of sensor white balance. The direct DE00 objective
is the equal-region mean plus 0.25 times the mean of the worst five percent of
weighted corresponding samples. It is an optimization experiment; original
mean/p95 acceptance gates and native output checks remain unchanged. Reports
explicitly identify controls, objective and all evaluated parameters.

### Native camera-profile expression and solver audit

`matching-native-profile-fit regression.json capture grid.card.json frozen-grid.json geometry-baseline.heic output-directory [sequential|jointProjected]`
uses the existing saved-profile runtime input: full native RAW 9 mapped output,
encoded extended sRGB, clamped to [0,1.25]. It verifies that the report's SHA256
matches the declared baseline image. Only regression roles are accepted; existing
outputs and outputs under original media directories are rejected. It samples a
24-by-24 native lattice within each fixed reliable region, with an eight-evaluation-
pixel inset. Source-only nine-point variation above 0.03 excludes edge/noise
samples from fitting; all excluded areas remain in output measurement.

`sequential` preserves the historical binned isotonic curves followed by smooth
9-cubed LUT fitting. `jointProjected` jointly solves the same runtime interpolation
coefficients using monotone projected least squares, curve identity weight 1,
LUT ridge 2 and neighbor smoothness 10. It reports its finite iteration budget,
projected gradient and convergence for the regularized RGB surrogate. This is
not optimization of HEIF CIEDE2000 and is not proof of photographic incapacity.
Fitted target-assisted models are private expression witnesses, never automatic
inference recipes or independent validation. Actual native HEIF and unchanged
whole-image/fixed-region limits determine the diagnostic outcome.

### Native profile objective and residual localization

`matching-native-profile-refine regression.json capture model.json grid.card.json frozen-grid.json geometry-baseline.heic output-directory [affine|affineAndCurves]`
keeps the existing format-2 model and its native input. `affine` varies three gains
and three constant-LUT offsets before the existing output clamp (25 trials).
`affineAndCurves` adds three bounded channel-curve bends (37 trials), adding
`delta * 4*t*(1-t)` at each original curve knot, with `t` clamped to [0,1].
Gain bounds [0.5,2] and bend bounds [-0.1,0.1] preserve a monotone base curve.
Two passes use gain-log/bend steps0.04,0.02 and offset steps0.01,0.005. The shared
native observation/loss owner evaluates the actual Metal look before managed
reduction and Gaussian sigma1.2, using direct mean/tail DE00 on fixed corresponding
regions. Reports identify every trial, base-model and baseline-image hashes.
This is a finite subspace diagnostic, not a global capacity or convergence proof.

`matching-residual-audit development.json capture candidate.heic grid.card.json frozen-grid.json geometry-baseline.heic output-directory`
localizes actual exported-HEIF residuals. It writes unregistered and fixed-region
DE00 previews (red intensityDE00/10; gray means unknown), the candidate/target
previews, and signed Lab/error summaries in fixed target-lightness bins below25,
25<=L<60, and at least60. It reports how many whole-image errors aboveDE00five
lie inside reliable regions. These summaries diagnose residuals; they replace no
whole-image, region, sensitivity or native-detail gate. Selection/regression roles
only, baseline SHA256 verified, guarded original reads and no overwrite.

### Coupled native profile field

`matching-native-profile-field regression.json capture model.json grid.card.json frozen-grid.json geometry-baseline.heic output-directory [distance|components] [meanTail|regionFeasibility]`
fits a bounded3-cubed RGB additive field represented in the existing9-cubed LUT.
Curves and native RAW9 input stay fixed. The pure solver uses central native-distance
derivatives with a half-step stability check, bounded coupled quadratic steps,
fixed smoothness/ridge priors and actual-loss line search (six iterations maximum,
at most twenty halving trials per step). Stabilized curvature retains a0.1norm
floor; the bounded quadratic rhs is H*x-g using the declared-objective gradient,
so stabilization does not replace that first derivative.
Report contract 4 retains coefficients, derivative checks, line-search trials,
baseline/model hashes, sample/region counts, full-region sampling policy and
explicit termination status. These per-image
models are private target-assisted diagnostics, not inference or acceptance.

`components` (default) uses three signed DE00 residuals with the same scalar norm;
`distance` reproduces the initial scalar-distance curvature experiment. Both keep
the measured mean/tail objective and photographic gates. Budget exhaustion is
reported, not treated as convergence.

`regionFeasibility` uses equal-region squared positive excess above fitting mean
DE001.9, a stricter target than photographic acceptance2.0. Every reliable region
has explicit sample identity. The same positive prior matrix stabilizes steps;
there is no absolute model penalty competing with feasibility. Reports name the
objective, prior role, fitting target and final sampled-region means. Sampled-target
satisfaction is a fit status, never HEIF or independent acceptance. `meanTail`
retains the pooled objective and absolute prior as the experimental control.


`matching-native-input-range regression.json capture grid.card.json frozen-grid.json geometry-baseline.heic output.json`
reads only the native RAW source, then reports per-channel negative, above1.25 and
above-display-one counts plus affected-pixel unions. Fixed corresponding native
rectangles retain baseline eligibility. No camera target pixel read is needed;
counts diagnose association, not causation or photographic acceptance.

## Shared RAW metadata colour-field experiment

`conditional-profile-fit training.json samples-dir capture-audit.json base-model.json constant|wb|iso|wbISO output-dir`
fits only training-role, endpoint-inclusive contract-3 samples (at least 100
captures). The RAW-derived capture audit supplies ISO; the sample recipe supplies
native decoder white-balance temperature. Neither lens nor focal length is a
predictor. All variants retain the same frozen base profile, bounded 3-cubed
colour fields and fixed ridge/colour/metadata neighbour priors. Temperature uses
reciprocal-temperature knots 125/200/400 mired; ISO uses log2(ISO/100) endpoints
0/7. Convex interpolation caps outside that range. Reports name the RGB surrogate;
only separately rendered HEIFs establish photographic results.

`sensor-conditional-heif original.arw output.heic media-root model.json` uses
only guarded RAW and a frozen shared model. `sensor-conditional-evaluate
verified.json model.json output-dir` uses the same renderer, then scores against
separate HEIF targets. There is no per-photo lookup or target input to rendering.
Missing/invalid required metadata and malformed models fail explicitly. These
models remain experiments until every development and independent acceptance
gate passes; a useful subset cannot promote a model.

## Native source coverage and preparation diagnostics

`matching-native-region-palette development.json capture look-card.json frozen-regions.json geometry-baseline.heic output.json`
exports at most 4096 uniform native source colours per reliable full region, with
separate signed range counts and samples projected onto the runtime [0,1.25]
domain. It verifies fixed RAW geometry and its SHA256. Selection/regression roles
only; no target image is read. Nearest training-colour distances describe coverage,
not photographic acceptance or proof that colour support is sufficient.

`matching-calibration-source-audit development.json capture look-card.json output.json`
compares full native RAW development followed by reduction with the reduced RAW
decoder tap used for shared fitting. Both retain the calibration Gaussian radius
1.2. `matching-calibration-look-audit development.json capture look-card.json conditional-model.json output.json`
also compares native look-before-reduction against reduced look-before-blur and
the current point-RGB initializer. These commands read RAW and the optional frozen
shared model; neither reads a camera target. Their display-clamped DE00 and signed
RGB differences diagnose preparation consistency, not actual HEIF matching. They
fail for training/acceptance roles, invalid inputs and existing output paths.
