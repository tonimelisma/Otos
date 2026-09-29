# Sony rendering: Apple RAW lens switch audit

September 28, 2026. Plan 0105 Stage 2 decoder/geometry investigation.
This audit did not change Otos rendering or select a lens model. It tested the
documented `CIRAWFilter` lens-correction switch at native 6192 × 4128 resolution
with decoder version 8. The [native geometry audit](2026-09-27-sony-native-geometry-audit.md)
had found about 24 pixels of 18 mm edge disagreement with the Sony render.

## Method

The harness develops each verified RAW twice with identical neutral settings:
once with `isLensCorrectionEnabled = true`, once with it set to `false`. It records
`isLensCorrectionSupported` and the untouched filter's default. Both outputs
and the independently decoded Sony companion use the same unregistered native
dimensions. The fixed 15-tile native matcher measures corrected-to-Sony,
uncorrected-to-Sony, and corrected-to-uncorrected correspondence. It reports a
p95 only at eight or more reliable tiles and does not use the 768-pixel Vision
registration. The third comparison isolates what the Apple switch changes;
the first two show agreement with the camera render. The bounded ±28-pixel
search means a lack of coverage cannot be interpreted as a measured large error.

The previously frozen six known-regression pairs and ten exact-18 mm examples
from the preselected training probe were used. The ten training examples span
eight sessions. Private output, manifests and original paths remain outside
Git. The 72 untouched acceptance pairs were not read or scored. The six
regression records were repeated with identical JSON.

| Role | Pairs | Apple supports correction | Apple enables it by default | Corrected-to-Sony sufficient | Uncorrected-to-Sony sufficient | Corrected-to-uncorrected sufficient |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Known regressions | 6 | 6 | 6 | 3 | 0 | 3 |
| Exact-18 mm training probe | 10 | 10 | 10 | 8 | 0 | 4 |

Among the sufficient 18 mm training records, corrected-to-Sony median p95 is
24.39 native pixels. Corrected-to-uncorrected median p95 is 22.69 pixels among
four reported records. In the regression records, those medians are 23.41 and
22.99 pixels respectively. The geometry metric removes each pair's median
translation. The result confirms Apple's switch materially changes geometry
and was already active in the neutral baseline. Turning it off removes nearly
all reliable Sony correspondences within the present search window. It does
not show that Apple's enabled profile matches Sony's; the large residual says
otherwise. Neither its sign nor a physical distortion model follows from
these p95 summaries alone.

## Decision and open questions

Retain the decoder's default lens correction as a measured baseline. Do not
stack a second assumed correction or label the default a verified Sony match.
Next, inspect displacement vectors with a stronger correspondence oracle and
investigate Sony's embedded lens parameters or a measured correction across
focal length and focus. The native 0.5-pixel gate, high-ISO coverage and native
detail/noise score remain open. No acceptance claim is made.
