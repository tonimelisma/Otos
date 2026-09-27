# RAW-to-camera-render matching: methods and experimental practice

Research date: September 27, 2026. Literature review and recommendations only.
No new photographic experiment, model change, dependency or product behavior is
claimed. This follows the [measured failures and candidates](2026-09-26-sony-lens-and-indoor-color.md).

## Conclusion for Otos

Treat the task as paired camera-render emulation, with two separate questions:
can a model represent the target rendering, and can its parameters be determined
without the separate target image? The current pointwise RGB/temperature model
has not answered the first question adequately for difficult scenes. Increasing
its table size or adding residuals is not yet an evidence-backed solution.

The most useful next tests are (1) compact per-image calibration, with spatially
held-out validation; (2) checking the RAW's embedded preview as a possible
per-image reference; (3) comparing input-development boundaries; and then
(4) predicting the successful adjustments using image context and metadata.
A spatial model follows only if repeatable local residuals justify it.
These priorities are our synthesis, not a claimed universal ranking from papers.

Keep three deployment situations distinct:

| Situation | Information available when rendering | Appropriate success claim |
| --- | --- | --- |
| RAW without using its camera preview | Developed sensor data and available RAW metadata | Predict Sony-like output on unseen captures |
| RAW with a usable camera preview | Sensor data, metadata and an embedded camera rendering | Match the preview's low-frequency look while developing full-resolution sensor data |
| Other neutral image | An RGB image with a specified color/development contract; metadata may be absent | Transfer a learned style within the tested input domain |

A preview-assisted renderer is a legitimate separate mode, but must not be
reported as prediction from sensor values alone. A generic RGB input cannot be
assumed equivalent to our Apple RAW8 neutral development. Nor does matching the
output identify Sony's unique internal algorithm: different combinations of
white balance, exposure, matrices and curves can produce similar final pixels.

## What the primary sources establish

### Compact camera calibration before a large model

Kim et al. studied more than 10,000 images from over 30 cameras and found that
conventional radiometric models were insufficient. Their camera-model work is
closer to our target than generic attractive-photo enhancement, although its
results do not establish performance on this Sony body/look.
[Kim et al., TPAMI 2012](https://www.microsoft.com/en-us/research/publication/new-camera-imaging-model-color-computer-vision-application/).

Rank-based calibration estimates a color transform using ordering relationships,
then a rank-preserving tone mapping and a gamut correction. It reports calibration
from a single RAW/rendered pair under its assumptions. This is a useful compact
baseline for our per-image diagnostic, not evidence that one pair covers arbitrary
Sony scenes or lighting. Local processing and clipping can violate its assumptions.
[Gong et al., 2018](https://ueaeprints.uea.ac.uk/id/eprint/68055/).

Root-polynomial color correction offers a nonlinear color basis whose terms
scale with exposure, unlike ordinary polynomial features of mixed degrees. It is
worth testing in a genuinely linear, unsaturated input domain before tone styling.
Its exposure property must not be attributed to our already nonlinear encoded RGB
or assumed to reproduce a creative look. Negative/out-of-gamut values need an
explicit domain policy; do not silently clip them to make fractional roots work.
[Finlayson et al., TIP 2015](https://ueaeprints.uea.ac.uk/id/eprint/52673/1/root_polynomial_accepted_preprint2.pdf).

Adobe's DNG specification separates camera color transforms, illuminant-dependent
hue/saturation/value maps, and profile tone curves. Chapter 6 describes interpolation
of multiple calibration tables according to white balance. This is a useful
structural precedent for separating calibration from appearance, not evidence
that Sony implements DNG's pipeline or that these fields are available in ARW.
[Adobe DNG 1.7.1, chapter 6 and profile tags](https://helpx.adobe.com/content/dam/help/en/camera-raw/digital-negative/jcr_content/root/content/flex/items/position/position-par/download_section_733958301/download-1/DNG_Spec_1_7_1_0.pdf).

### Metadata and image context are different inputs

ParamISP combines fixed canonical operations with learned local/global processing
and parameter conditioning. Its parameter inputs include exposure time, sensitivity,
aperture and focal length; canonical parameters include white balance and color
conversion. Its datasets include Sony A7R3, which is not our ILCE-6700. This supports
ablating metadata beyond temperature, not importing its weights or headline scores
as evidence for our camera. Use only metadata obtainable from the allowed inference
input, even if a research dataset stores equivalent values in its target JPEG.
[Kim et al., CVPR 2024, ParamISP](https://arxiv.org/html/2312.13313v2).

Scene-dependent camera modeling explicitly investigates global and local context
rather than one deterministic color transform shared by every scene. This makes
scene adaptation plausible, but does not prove our current failures require it.
[Nam and Kim, ICCV 2017](https://arxiv.org/abs/1707.08350).

Image-adaptive 3D LUTs learn several basis tables and use a small network operating
on a reduced-resolution image to predict blending weights. This is a practical
next family if individually fitted global transforms succeed. It changes the
transform between images while retaining a global color-to-color mapping within
an image. Published GPU timings are not macOS performance measurements.
[Zeng et al., 2020](https://arxiv.org/abs/2009.14468).

AdaInt also learns where to allocate LUT sample coordinates. That addresses table
resolution/capacity; it does not by itself provide spatial context. Test it only
if sampling density is the demonstrated bottleneck. Trilinear versus tetrahedral
interpolation is another controlled variable, not an assumed cure for indoor color.
[Yang et al., CVPR 2022](https://openaccess.thecvf.com/content/CVPR2022/html/Yang_AdaInt_Learning_Adaptive_Intervals_for_3D_Lookup_Tables_on_Real-Time_CVPR_2022_paper.html).

### Local operators when global color mapping is insufficient

HDRnet predicts coefficients for local affine transforms on a bilateral grid from
a small image, then applies them at full resolution through edge-aware slicing.
It is directly concerned with approximating paired reference processing. A grid
indexes spatial position and a guidance/intensity dimension, making it different
from an RGB LUT. [Gharbi et al., SIGGRAPH 2017](https://groups.csail.mit.edu/graphics/hdrnet/).

The 2024 LUT-with-bilateral-grid work combines spatial features with adaptive LUTs.
It uses reconstruction, color, perceptual and regularization terms; its evaluation
is photo-enhancement benchmarking, not a guarantee of Sony emulation. Smoothness
and monotonicity constraints are useful candidates, but their strength should be
validated: a creative hue mapping need not be componentwise monotonic everywhere.
[Kim and Cho, ECCV 2024](https://www.ecva.net/papers/eccv_2024/papers_ECCV/papers/06517.pdf).

ReconfigISP searches combinations of pipeline operations and parameters, using
learned differentiable proxies for operations that are not differentiable. It
shows that pipeline structure is itself an optimization dimension. For Otos,
first test a small explicit stage set; do not introduce architecture search or
assume Core Image's RAW decoder exposes gradients.
[Yu et al., ICCV 2021](https://openaccess.thecvf.com/content/ICCV2021/html/Yu_ReconfigISP_Reconfigurable_Camera_Image_Processing_Pipeline_ICCV_2021_paper.html).

### Embedded preview: a separate practical opportunity

RawTherapee's implementation derives a tone curve by histogram matching to an
embedded thumbnail. It handles missing or too-small thumbnails by declining that
match. This demonstrates an established preview-assisted approach; histogram
matching alone does not establish spatial correspondence or reproduce all color
and detail effects. Source was inspected as evidence, not copied or installed.
[RawTherapee histogram-matching implementation](https://github.com/RawTherapee/RawTherapee/blob/dev/rtengine/histmatching.cc).

Apple exposes an optional `CIRAWFilter.previewImage`. Availability, resolution,
orientation, color encoding and agreement with the separate Sony HEIF must be
measured on our files. A rendered preview must remain a reference, never be
substituted for the full-resolution sensor development and called a RAW result.
[Apple previewImage](https://developer.apple.com/documentation/coreimage/cirawfilter/previewimage).

Proposed test: compare preview and HEIF at a common scale/crop/profile first. Only
if their low-frequency color and tone agree, fit a compact correction from neutral
sensor development to the preview and apply it to full-resolution development.
Evaluate against the withheld HEIF, without using it during parameter estimation.
This could eliminate a separate companion-file dependency; it does not eliminate
original RAW reads/materialization or serve images with no suitable preview.

### Geometry and evaluation are part of the problem

The inaccurately aligned supervision literature reports blur and shifted results
when RAW/rendered pairs do not correspond correctly. Its multicamera task differs
from our same-capture pairs, but the failure mechanism is relevant. Align before
color fitting, preserve masks, and report alignment confidence and rejected coverage.
[Zhang et al., ICCV 2021](https://arxiv.org/abs/2108.08119).

Darktable distinguishes embedded lens metadata, database profiles, and manual
corrections. It separates distortion, transverse chromatic aberration, vignetting
and image scale, and warns about duplicate chromatic-aberration correction. Our
small residual warp should not become a substitute for understanding those
components and Sony's embedded parameters.
[darktable 5.6 lens correction](https://docs.darktable.org/usermanual/5.6/en/module-reference/processing-modules/lens-correction/).

For metrics, CIEDE2000 is a useful addition to the existing CIE76 record; validate
its implementation against the authors' supplemental cases. SSIM measures a
structural aspect of similarity and complements, rather than replaces, color
error. Neither is a universal perceptual acceptance threshold for photographs.
[Sharma et al., implementation resources](https://hajim.rochester.edu/ece/sites/gsharma/ciede2000/),
[Wang et al., SSIM](https://ece.uwaterloo.ca/~z70wang/research/ssim/).

## Proposed controlled experiment

The following protocol is an Otos recommendation derived from the evidence above;
it has not been executed or adopted as implemented product behavior.

### 1. Fix the data and measurement contract

- Separate known camera-look/settings groups; verify the new files' proprietary
  look identification instead of relying only on Apple's consistent field values.
- Specify allowed inputs for each mode. Prevent companion HEIF information from
  leaking into a predictor claiming to use RAW/metadata only.
- Split entire capture sessions/bursts into training, selection and untouched
  acceptance sets. Our previously examined 19-date set is no longer untouched.
  Report scene/date diversity; millions of pixels are not millions of independent
  lighting examples. Resample uncertainty by session, not individual pixel.
- Audit transfer functions, color profiles, orientation, crop, extended values,
  alpha and clipping. Fix the decoder for each experiment arm. Include clipping
  rates, signed channel residuals and residual maps, not only scalar averages.
- Fit geometry with constrained models; exclude occlusion/motion/unreliable regions
  from photometric scoring. Keep their coverage visible. Do not let flexible
  target-specific warps conceal a lens defect, and never display such warps as
  deployable RAW-only correction.

### 2. Measure model capacity on the difficult images

Use spatially separated fitting and validation blocks, with a buffer exceeding
the blur/filter support; random neighboring pixels leak nearly identical content.
Repeat the partition to expose poor color coverage. Keep fitting masks unchanged
across model comparisons. Fit a nested diagnostic ladder:

1. Exposure/black-level and white-balance adjustment.
2. Matrix plus smooth tone curve; compare shared luminance and channel curves.
3. Smooth 3D LUT with held-out selection of resolution/regularization.
4. A bounded, smooth, edge-aware local residual only if global models leave
   repeatable region-specific error.

Call these target-assisted diagnostic fits, not production validation or a proven
global optimum. Report train and held-out-region errors separately. Inspect dark,
clipped, skin-like, foliage and neutral regions; avoid identifying people or
assuming a region is neutral merely because of its apparent color.

Compare the current encoded RGB boundary with a documented linear/extended-range
boundary on exactly the same pairs. Earlier processing is not automatically better.
Apple's `linearSpaceFilter` permits an intervention in linear space, but the public
API does not promise an unprocessed sensor-RGB tap or control over every internal
stage. Verify its working-space/ordering empirically before assigning physical
meaning to a matrix. [Apple linearSpaceFilter](https://developer.apple.com/documentation/coreimage/cirawfilter/linearspacefilter).

Keep exposure and matrix normalization constrained so both cannot freely absorb
the same scale. Anchor curves and use identity/smoothness penalties where suitable.
Initially freeze unaffected stages; once a useful stage set is identified, jointly
or alternately optimize its parameters. Run multiple initializations before
concluding that an unsuccessful nonlinear fit proves insufficient model capacity.

### 3. Measure parameter prediction separately

If per-image global fits are good, compare a fixed profile, a metadata-conditioned
profile, an image-statistics-conditioned profile and their combination. Start
with small regressors or smooth blends of a few basis LUTs. Candidate inputs are
RAW WB gains or temperature/tint, log ISO/exposure, verified look settings and
preview histograms/brightness/chroma summaries. Do not assume every metadata
field causes a processing change; require an ablation on unseen sessions.

If the diagnostic fit succeeds but prediction fails, improve conditioning/data,
not table size. If both fail, examine the development boundary, model family,
correspondence and optimization. If a local model succeeds only on training
regions, it is memorizing rather than demonstrating a deployable solution.

### 4. Evaluate color, geometry and detail at appropriate scales

Use masked low-frequency color error to isolate broad rendering, plus unblurred
full-image/crop checks so blur cannot hide halos or edge errors. Report per-image
mean/median and high-percentile CIEDE2000, luminance/chroma/hue residuals, geometry
error and native-resolution structural/detail diagnostics. Preserve CIE76 for
historical continuity; do not compare its numeric values directly with CIEDE2000.

Give images equal aggregate weight and also report predeclared strata: difficult
indoor light, daylight, ISO ranges, focal lengths and clipping levels. Averages
must include regression counts and worst examples. For fitting, compare robust
RGB losses and color-balanced sampling; retain a natural-distribution evaluation
so rare-color weighting does not silently redefine reported success. Learn color
first, then validate native-resolution noise/sharpening without treating one
camera's stochastic noise realization as detail to reproduce exactly.

Use identical zoom, crop, display transform and backdrop in blinded/toggle A/Bs.
Compare the same final pipeline in metrics and the viewer. No unvalidated universal
quality threshold is set here; acceptance must include improvement of the visible
failure cases, not only an overall mean.

## Native macOS implementation implications

The small calibration fits can use Swift and Accelerate; the existing native
reference already establishes a practical LUT/Metal route. Core Image supplies
RAW development and image operations, while Vision can supply diagnostic alignment.
Availability of these frameworks is not proof that every paper's operator maps
one-to-one to a built-in filter.

If a learned coefficient predictor becomes justified, MPSGraph supports variables,
training graphs and automatic differentiation. A native training implementation
is possible, but published research code would still need to be reimplemented and
verified; this review has not trained such a network. Core ML inference alone is
not a replacement for that training work. [Apple MPSGraph training](https://developer.apple.com/videos/play/wwdc2020/10677/).

No external training/runtime dependency is proposed. No generative image model,
unpaired adversarial training or semantic texture synthesis is needed to test
these hypotheses. Preserve model weights, exact input/output contracts, synthetic
tests, data-split definitions without private paths, and aggregate failures.
Retaining those makes a fitted model implementable without the photographs;
further calibration and independent validation still require paired examples.

## Limits of this review

These sources establish methods and failure mechanisms, not which mechanism
explains the remaining ILCE-6700 differences. No new quality numbers, embedded-
preview verification, lens-table decoding or native performance measurements were
produced. No original files were read or downloaded. Papers targeting human
retouching, smartphone-to-DSLR matching or inverse ISP are relevant methodological
references, not interchangeable benchmarks for exact Sony HEIF reproduction.
