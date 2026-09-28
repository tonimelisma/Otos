# Sony rendering: native geometry correspondence audit

September 27, 2026. Plan 0105 measurement follow-up; no Otos application
rendering behavior or saved Sony model changed. The [first harness pass](2026-09-27-sony-render-harness.md)
found 2–16 native-pixel equivalent disagreement from downscaled features. This
pass measures image patches at native resolution, independently of the preview
homography used for color scores. It confirms a large, repeatable 18 mm edge
pattern and identifies insufficient high-ISO correspondence. No lens correction
was accepted or applied to a product renderer.

## Fixed method and private data

For each pair, the native Apple neutral RAW and Sony camera render retain their
own 6192 × 4128 coordinate systems. Fifteen 192 × 192 tiles lie in a fixed 5 × 3
grid spanning near-center, edges and corners. Within each tile, one 41 × 41
gradient patch is selected from 25 offsets using **only Sony texture**. A bounded
±28-native-pixel correlation search finds the corresponding RAW patch, followed
by one-pixel refinement and quadratic subpixel estimation. Weak, ambiguous,
flat and boundary matches are counted as rejected. The result stores point
positions, displacements and correlations privately. A median translation is
removed from each image, leaving crop/scale/distortion residuals. A p95 is
reported only when at least 8/15 tiles match; that reporting floor does not
certify the release geometry target or establish an uncertainty bound.

Synthetic odd/even pixel translation and flat-patch rejection fixtures pass.
Six known-regression native result records are identical on repeat. Native
results were generated from already local verified ARW/HEIF pairs with the same
immediate `SF_DATALESS` byte-read gate as the first harness. All paths, manifests,
per-image metadata, vectors, tiles and output images remain private outside Git.

A new, deterministic metadata-only probe chose the minimum and maximum focal
length in each of 21 verified training sessions before any native scores were
read: 42 training pairs, including 13 at 16–22 mm and ten at ISO 2500 or above.
Its private manifest SHA256 is
`e35ee6f1984d29541b8da2bda2c796dc965404275111b3898c05e71bc4bac518`.
The 72-pair untouched acceptance set was neither read nor scored.

## Results

| Development role | Pairs | Pairs with ≥8/15 matches | Median p95 among reported pairs | Reported p95 range | Pairs at ≤0.5 native pixel |
| --- | ---: | ---: | ---: | ---: | ---: |
| Focal-extreme training probe | 42 | 17 | 8.07 px | 0.95–25.73 px | 0 |
| Permanent known failures | 6 | 3 | 23.41 px | 2.60–23.66 px | 0 |
| Earlier selection dates | 18 | 8 | 5.12 px | 0.70–12.44 px | 0 |

In the training probe's 16–22 mm bin, eight of 13 pairs have sufficient
coverage. Their median native p95 is 24.39 pixels (21.87–25.73). The usable
exact-18 mm training images span eight separate sessions and show the same
outward corner/edge pattern; two known 18 mm failures with sufficient coverage
show approximately 23–24 pixels. This is a strong geometry mismatch, not a
small color metric artifact. The present patch matcher does not prove a physical
lens model, and the remaining images need reliable coverage before making a
whole-scope claim.

None of the ten high-ISO training examples had 8/15 reliable unsmoothed matches.
A fixed native sigma-1.2 blur before matching improved that subset to 3/10 but
reduced overall training coverage from 17/42 to 12/42 and median matched tiles
from seven to six. That ablation was rejected; the saved diagnostic remains
unsmoothed. A high-ISO geometry claim is still unsupported.

## Profile capacity probe, not a selected correction

The preserved [18 mm preview residual](sony-vv2-reference/lens-residual-candidate/README.md)
was extrapolated to these native vectors without rerendering. On two reliable
known 18 mm failures, it lowered p95 only about 7%, leaving roughly 22 pixels.
It cannot be promoted as a native correction.

An exploratory least-squares ladder used **only eight usable exact-18 mm
training images**, with per-image translation as a nuisance term and regularized
global radial terms. It tested shared x/y radial degrees 1–6 and independent
x/y radial degrees 1–6 at three fixed ridge strengths. A compact shared model
left roughly 9 native pixels median in leave-session-out training validation.
The most flexible independent-axis setting reached 1.98 pixels median across
eight session holdouts, 1.58 on two usable known failures and 1.84 on one usable
earlier selection image, based only on vector arithmetic. Its high degree and
sparse selection coverage make it a capacity diagnostic, not a deployable lens
profile. It was not rendered, checked for interpolation artifacts or retained
as a model, and none of these results passes the 0.5-pixel gate.

## Next step and limits

Stage 1 correspondence remains open because fewer than half the development
images reach the native reporting floor and high-ISO coverage is absent. Stage
2 must investigate the embedded lens parameters or a measured native correction
with proper focal/focus variation, then verify actual corrected images at native
resolution. A stronger correspondence oracle and quantitative native detail/noise
checks are still needed before color fitting or photographic acceptance. The
browser A/B validation remains unavailable after automatic approval review
rejected loading derived private media; the page was not routed elsewhere. Plan
0105 and its accuracy claim remain open.
