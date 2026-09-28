# Sony RAW rendering: frozen corpus and baseline measurement

September 27, 2026. Plan 0105 Stage 1 research and tooling. No Otos application
rendering behavior changed. The saved Sony fixed model remains a baseline, not an
accepted photographic match. Stages 1 and 2 remain open because geometry and
native detail are not yet certified; no new color model was fitted in this pass.

## Private corpus and capture audit

The existing name-only inventory has 3,150 ARW/companion pairs across 53 dates.
The original 344-pair September corpus and 19 previously examined earlier dates
are development evidence. Known indoor, green-tent and gallery failures were
frozen as a separate permanent regression suite before scoring. Original capture
bursts within ten minutes stay together; bursts containing a regression capture
are excluded from training. A fixed name-hash seed chose additional training and
untouched acceptance captures by previously unexamined date. No score or image
from the acceptance role has been viewed or used to change the renderer.

| Role | Verified pairs | Sessions | Use |
| --- | ---: | ---: | --- |
| Training | 188 | 21 | Later fitting; not fitted yet |
| Model selection | 18 | 18 | Previously examined earlier dates |
| Permanent regression | 6 | 3 | Known hard scenes |
| Untouched acceptance | 72 | 12 | Membership and metadata frozen; unscored |

The acceptance manifest SHA256 is
`48d5ea600f342e7386990897478b2bfff405e2095d3662e39863b61198d2d770`;
its independent metadata report is
`69b6f1553539e78a134dbcea1225ec68b1873f01ef951786c5a001b09557f66f`.
Training, selection and regression manifest SHA256 values are respectively
`28ce3b5f189b38be92c53220ed93fe55b18c6422528ee9572de0e812bb75dcd2`,
`39d74aee4302bff18de35c34f20af3561e9a996287d9798ac3ade9121eb25fac`,
and `ea040ba7cecf1a53ca630d50c65b250e505600321faa03716cb1128e059bd67c`.
All manifests, original paths, individual metadata and render assets remain
private outside Git. Hashes identify the frozen local files; they do not make the
photographs reproducible without the owner's originals.

The metadata audit verifies camera/capture identity, exposure, lens/focal length,
Sony VV2 look tags and companion SDR transfer/primaries for every admitted pair.
All 188 training and 72 acceptance candidates passed. The acceptance set has 67
captures with the 18–50 mm Sigma lens across all 12 dates; 35 are ISO 100 and 18
are ISO 2500 or higher. Five examples use other lenses, which is too little to
claim those lenses supported. Training has 174 examples with that Sigma zoom,
including 26 at ISO 2500 or higher. The selection set has only one such high-ISO
image. Lighting categories have not been independently labeled or audited yet,
so broad lighting coverage is not established by date counts alone.

The materialization utility issued deliberate nonblocking requests, then used
`lstat`/`SF_DATALESS` to determine when originals were local. At the end, all
376 training files were local (7,981,068,288 logical bytes), as were all 144
acceptance files (3,103,621,120 logical bytes). A retry returned File Provider
error 4099 for 49 then-dataless files, which subsequently became local. Requests
and availability are separate facts; no media byte read was used to force these
downloads. Evaluation and metadata extraction each check `SF_DATALESS` immediately
before their reads. Originals were not modified or moved.

## Measurement implementation

The native harness pins Apple RAW decoder 8 and uses the exact saved fixed model,
plus Apple default and neutral development baselines. Its comparison boundary is
an extended-sRGB encoded frame with a fixed 768-pixel long edge. A Vision
homography establishes common score coordinates; all baselines receive the same
measurement transform. The viewer PNGs remain in each output's own geometry.
Color scores use D65 Lab and CIEDE2000 with the [published 34-case reference
dataset](https://hajim.rochester.edu/ece/sites/gsharma/ciede2000/). A fixed
separable Gaussian sigma 1.2 gives low-frequency mean and 95th percentile error;
unblurred error, clipped fraction and valid fraction are also recorded. Identity
and flat/structured geometry fixtures pass. Six regression JSON records were
bit-for-bit identical in two runs of the same measurement algorithm.

An independent 40-location gradient matcher estimates local displacement after
homography. It rejects flat, ambiguous and search-boundary patches, reports
reliable coverage, removes only global translation and expresses residuals in
native-pixel units. This is a *downscaled correspondence diagnostic*: its local
patches are not full-resolution feature measurements, and uncertainty still
needs an error-floor study before it could certify a 0.5-native-pixel target.
Native 512-pixel corner crops are emitted from the same source reads for detail
inspection. Automated native edge/noise scores are not yet implemented.

## Reproduced baseline failures

Scores below average each image equally. They describe the saved fixed model
under the new measurement contract, not a new model. The six regression images
include the preselected indoor/green-tent/gallery failures.

| Development role | Fixed mean low-frequency ΔE00 | Apple default mean | Images passing both mean ≤2 and p95 ≤5 | Geometry p95 median (native px) | Geometry p95 range (native px) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Known regressions, 6 | 2.659 | 7.014 | 1/6 | 10.05 | 2.07–11.14 |
| Selection dates, 18 | 1.836 | 6.437 | 12/18 | 3.03 | 1.34–15.72 |

All six regression and all 18 selection images fail the proposed 0.5-pixel
geometry threshold on this diagnostic. Their reliable feature fractions average
0.708 and 0.832 respectively. The regression fixed-model low-frequency mean
ranges from 1.694 to 3.700; selection ranges from 1.106 to 3.125. Reported
color valid fractions were 1.0, but a valid homography footprint is not proof of
local correspondence. Clipped fractions average 0.036 and 0.028 respectively.
One inspected full frame and native crop still show color and edge differences.
No acceptance score was computed.

The private browser A/B page could not be exercised: automatic approval review
rejected opening derived private media in the browser connector. Local PNGs were
inspected directly; no alternate browser route was used. This leaves interactive
viewer validation and agent-operated visual acceptance unfinished.

## Decision

The frozen data and scorecard make the saved baseline's failures measurable, but
Stage 1's registration/native detail gate is not complete. Continue with an
independent native geometry error-floor audit, explicit capture/crop/profile
checks, and the lens correction investigation in Stage 2. Do not optimize color
against the misaligned pairs or inspect the untouched acceptance images to pick
a model. The release accuracy gates and plan 0105 remain open.
