# Native source opacity and bounded RAW-context selection

## Purpose and source controls

Plan 0105 retains sensor RAW 9 and the separate verified Sony VV2 HEIF targets.
Embedded camera images are excluded. This pass checks a diagnosed native-detail
difference and tests RAW-only shared colour selection without increasing the
six-field model capacity. Private artifacts are in the primary checkout's ignored
`build/sony-paired-corpus/`; originals remain read-only and guarded before byte reads.

The configured Xcode 27 Core Image SDK's `CIRAWFilter.h` defines independently
supported luminance/colour noise controls and says their defaults vary by image.
Zero boost, local tone, contrast and sharpness do not imply zero denoising. A
sensor-only probe of green capture `20260710_203257` confirms decoder 9 reports
luminance support=true, amount 0.51817983; colour support=false, amount 0.
These are runtime observations, not inferred Sony settings.

## Noise-control experiment: invalid comparison, retain source

Freeze one variant: set supported luminance reduction to zero, leave the existing
fitted green look and all other RAW controls unchanged. The native HEIF is emitted,
but colour evaluation rejects insufficient valid pixel support. Its two fixed
256-pixel upper-left canvas patches have alpha means 0.96868/0.96829, versus 1
for baseline and target. Their brightness and high-frequency differences are
confounded; they cannot establish a denoise improvement. Scene texture is another
confound of these patch statistics, which are not acceptance criteria.

A guarded RAW-only probe localizes invalid support at the native encoded tap,
before the authored look or HEIF writer. Default alpha is 0.9995117–1, with zero
invalid fraction under the frozen source tolerance. With reduction zero, half-float
tap alpha is 0.6381836–1.5449219, invalid fraction 0.9886208. A full-float tap still
has invalid support (0.6386694–1.544976, fraction 0.9922181). This is not merely
half-float rounding. It does not isolate decoder internals from colour conversion
or prove an Apple API defect. Do not unpremultiply, replace alpha, refit the look,
or sweep noise amounts to conceal it. Retain the current native defaults.

Artifacts: `control/raw-noise-zero-contract.json`, `raw-noise-probe.log`,
`green-native-noise-comparison.json`, `green-native-noise-alpha-comparison.json`,
`raw-noise-alpha-default.log`, `raw-noise-alpha-zero.log`, and
`raw-noise-alpha-zero-float.log`. This experiment does not close native-detail
matching or quantify legitimate denoising's effect on the look.

## Implemented native input boundary

Saved/conditional rendering previously let nonopaque sensor pixels reach numeric
look application and HEIF publication. Calibration already rejected below-one
alpha. Both now use `isFiniteOpaqueNativeFrame`: finite channels and alpha in
(0.999,1.001]. Tolerance admits native conversion rounding, not genuine transparency or
unconstrained alpha. Failed rendering emits `sensor.sourceSupport phase=rejected`
and `invalidSourceSupport`; it does not publish a HEIF. Receipt contract is 5.
Calibration's source/sample contract stays unchanged because valid RGB and source
controls are unchanged. No model, denoising, tone, colour or lens change is promoted.
Synthetic fixtures cover valid rounding, transparency, above-one alpha and
nonfinite RGB/alpha. Actual default green HEIF colour scores remain exactly equal
to the prior result. The injected zero-reduction source is rejected before HEIF
publication. Standalone numerical/CPU/Metal fixtures verify the same boundary.

## RAW-context experiment contract

Freeze 100 previously assigned native-pilot training captures and the existing
nine development controls. Name-only hashing assigns 28 date groups/77 images to
fitting and 8 groups/23 images to validation. Dates are not independently certified
shoots, and these images have prior development use; this validation is a matched
group exclusion from the current fit, not final independent acceptance.

Guide features come from an unregistered sensor RAW 9 native encoded frame,
validated and tagged opaque before managed 256-long-edge reduction: log-luminance
10/50/90 percentiles, mean R-G and B-G, dark/clipped fractions and horizontal
luminance gradient. Target pixels, target registration, lens and focal length do
not enter features or runtime selection. Metadata WB/ISO retains its existing
six convex weights. Training-only equal-date statistics standardize features
(std floor 0.05); WB/ISO-weighted source centroids define six affinities
`exp(-squaredDistance/(2*8))`, normalized to one. The single declared variant
blends those weights equally with the metadata weights. Compare a matched
metadata-only control on identical 77 source/target sample exports, equal-date
mass 20000, base, six 3-cube fields, bounds 0.25, ridge 2 and neighbour penalty 10.
No feature/bandwidth/field/prior sweep.

Require a resolved fixed-screen failure with no lost control passes and no worse
held-out mean or failure count before region/native-detail checks and full 204.
The untouched reserve is not consumed. The first source export terminated with
exit 137 before its final report; that code alone does not establish its cause.
The retry preserves the contract and uses per-image autorelease scope and private
checkpoints. This execution repair is not a second model variant.

## Results: reject the centroid selector

All 109 source exports completed on the retry. Both matched fits used 192,500
observations from 77 images. Metadata control fitting took 3.49 s; context fitting
9.64 s. These are initializer fits, not native perceptual optimization. Actual
HEIF evaluation completed 23 held-out plus 9 screen images for each model.

| Group/measure | Metadata control | RAW-context variant |
| --- | ---: | ---: |
| Held-out whole-image passes | 23/23 | 23/23 |
| Held-out equal-image mean DE00 | 1.281721 | 1.291061 |
| Held-out equal-date mean DE00 | 1.275292 | 1.284693 |
| Screen whole-image passes | 5/9 | 5/9 |
| Screen equal-image mean DE00 | 1.873894 | 1.863495 |
| Screen maximum mean DE00 | 2.979553 | 2.692071 |

No failure is resolved and no pass is lost. Nine of 23 held-out means improve;
three of 9 screen means improve. Green improves mean/p95 from 2.980/5.403 to
2.692/5.103 but still fails both gates. Original cyan `20260921_124945`
worsens 1.903/6.272 to 1.965/6.417. Foliage worsens 2.506/7.817 to 2.517/7.815.
Reject this variant. Do not expand it to 204, tune affinity weights/bandwidth,
consume reserve pixels, or promote its wire format/inference code. This rejects
one deterministic centroid selector and its paired RGB initializer; it does not
establish that RAW image context or a supervised guide predictor cannot work.

Artifacts: `control/raw-context-contract.json`, `raw-context-fit.json`,
`raw-context-validation.json`, `raw-context-source-features.json`,
`raw-context-selector.json`, `raw-context-fit-and-evaluate.log`,
`raw-context-results.json`, and `raw-context-summary.json`.
`conditional-fits/context-control-77/` and `context-affinity-77/` retain models,
hashes and fit reports; corresponding heldout/screen evaluation directories retain
all native HEIFs and per-image outcomes. No photographic matching gain is promoted.

## Next bounded action

The unrestricted 3-cube per-image cyan field has a successful original-region
witness. A selector over six prelearned fields has a narrower available transform
set. Before training another selector, test native target-assisted blending of
that fixed bank against the original cyan regions. Keep source, bank and colour
bounds fixed; a target-assisted blend remains a diagnostic, never runtime lookup.
Use actual native observation and HEIF/region checks. Adequate success permits
supervised RAW-guide selection; numerical failure reopens its solver, and an
unsuccessful bounded fit motivates a bank/native-training investigation rather
than declaring global colour capacity impossible. Neither a coefficient projection
nor an exhausted optimization budget can certify universal inability.
