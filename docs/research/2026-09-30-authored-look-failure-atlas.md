# Initial authored-look failure atlas

Date: September 30, 2026. Baseline diagnosis for Plan 0105, before the next input
or display-transform candidate. Exact revised RAW-only binary, saved RAW 9 model,
fresh full-resolution exports on the six frozen development regressions.

## Exact HEIF measurements

All six exports succeed at native dimensions with decoder 9/native lens correction.
The established HEIF scorecard reports these unregistered offline Sony comparators;
validFraction is 1 for each. Geometry is independently measured at native scale.
Residual displacement is after the native scorer's global translation removal;
it does not prove a dense lens map or chromatic aberration.

| Capture | Mean / p95 low-frequency DE00 | Median / p95 native residual px | Reliable / attempted geometry patches |
| --- | --- | --- | --- |
| `20260920_131849` | 1.346 / 2.937 | 1.88 / 3.31 | 22/35 |
| `20260921_124945` | 2.138 / 7.032 | 1.87 / 24.22 | 20/35 |
| `20260921_124534` | 3.029 / 5.397 | unverified (insufficient coverage) | 8/35 |
| `20260921_162050` | 2.551 / 7.829 | 1.87 / 23.17 | 35/35 |
| `20260921_103245` | 1.931 / 4.372 | 1.94 / 22.69 | 35/35 |
| `20260710_203257` | 2.765 / 4.610 | unverified (insufficient coverage) | 3/35 |

Values reproduce the saved baseline. Two of six pass the old Sony-match thresholds;
that count is a comparator, not newly certified authored-appearance acceptance.

## Frozen look regions and signed diagnostic

Rectangles are x0, y0, x1, y1 fractions of the displayed image, origin at top left.
Signed differences are candidate minus offline anchor: L brightness, a red/green,
b yellow/blue. These diagnostic medians use exported **8-bit sRGB PNGs**, Pillow
Gaussian radius 1.2 and D65 Lab. They are not the full precision release scorecard
or an interchangeable implementation of its exact Gaussian kernel. There is no
registration or exclusion mask, so edges/motion/geometry may affect a region.
Freeze the regions now; use exact HEIF/valid correspondence before tolerance fitting.

| Capture / region | Rectangle | Median delta L, a, b |
| --- | --- | --- |
| `20260920_131849` / face | 0.29, 0.44, 0.37, 0.57 | -0.35, +0.39, +0.00 |
| `20260920_131849` / white wall | 0.67, 0.03, 0.88, 0.22 | -0.90, -0.16, -0.00 |
| `20260920_131849` / colour chair | 0.67, 0.3, 0.81, 0.57 | -0.62, +0.15, +0.09 |
| `20260921_124945` / face | 0.41, 0.3, 0.49, 0.42 | +0.28, -0.52, +0.27 |
| `20260921_124945` / white shirt | 0.37, 0.41, 0.45, 0.52 | -0.19, +0.00, +0.50 |
| `20260921_124945` / cyan toy | 0.23, 0.72, 0.32, 0.81 | -2.42, +2.50, -0.49 |
| `20260921_124534` / face | 0.4, 0.22, 0.61, 0.43 | +0.16, +1.96, +3.45 |
| `20260921_124534` / towel | 0.69, 0.5, 0.86, 0.8 | -0.26, +1.16, +3.09 |
| `20260921_124534` / white shirt | 0.39, 0.56, 0.53, 0.7 | +0.65, +2.23, +5.24 |
| `20260921_162050` / water | 0.51, 0.43, 0.58, 0.68 | -0.04, -0.24, +0.72 |
| `20260921_162050` / sunlit foliage | 0.09, 0.39, 0.23, 0.58 | -0.29, -1.05, +2.65 |
| `20260921_162050` / dark forest | 0.69, 0.22, 0.84, 0.38 | -0.59, -1.15, +1.17 |
| `20260921_103245` / stone | 0.34, 0.39, 0.46, 0.5 | -0.72, +1.06, +0.77 |
| `20260921_103245` / ground | 0.46, 0.26, 0.58, 0.39 | -0.66, +0.93, +0.66 |
| `20260710_203257` / face | 0.58, 0.33, 0.67, 0.49 | -0.54, +0.02, +2.05 |
| `20260710_203257` / white jacket | 0.76, 0.54, 0.87, 0.7 | -0.90, -0.34, -0.31 |
| `20260710_203257` / tent | 0.09, 0.13, 0.26, 0.4 | -1.78, -3.73, +9.94 |

Private artifacts: `raw-only-final-regression/` holds exact HEIFs, native corner
crops and scores; `raw-only-failure-atlas/` holds six A/B/signed-L/residual maps
and `regions.json`. No media or sampled pixels enter Git. Existing registered
colour diagnostics are additional evidence only; they improve waterfall error
but leave appearance residuals, and cannot silently replace unregistered scores.

## Failure routing and next bounded experiment

- Bathroom skin/shirt/towel show a coherent positive a/b residual with relatively
  small median L shifts. Hypothesis: a colour/illuminant residual, not simply
  incorrect global exposure. A global brightness change alone is unsupported.
  This does not yet distinguish technical WB/profile from tone-related chroma.
- Tent fabric has a large yellow/green residual while the white jacket is close;
  one uniform WB shift may damage the jacket. Inspect spatial and colour dependence
  before adding adaptation or local processing; do not force green ambient light neutral.
- Cyan toy differs in brightness and a; examine display colour handling and gamut.
- Water is close in median L while foliage differs in b; geometry and foliage
  texture remain confounders. Keep lens/fringing investigation separate.
- Stone/ground and the indoor control are useful regression controls: retain their
  subtle colour/detail when improving difficult illuminated scenes.

First input experiment changes **native gamut mapping alone**, retaining native
shadow bias, WB/exposure, denoise, lens state and full-resolution decode. Compare
range and controlled ramps, then refit identical downstream families for fair
actual-output comparison. If information is preserved but appearance worsens,
diagnose fitting/colour handling before stacking corrections. Do not add a
predictor until exact-export capacity is demonstrated.

Decision: retain baseline, do not promote a new look. M2 remains open: exact-region
uncertainty, dense correspondence limits and appearance tolerances are not yet
settled. Initial residual maps narrow the questions; they do not prove root causes.
