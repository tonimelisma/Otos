# RAW source coverage and native fitting-region support

Date: October 3, 2026. Scope: Plan 0105 development experiments, not photographic
acceptance. RAW decoder 9 and the frozen runtime base remain unchanged. Separate
verified camera HEIFs are supervised targets; embedded camera images are excluded.
No app implementation or inference recipe is promoted by these experiments.

## Training expansion and bounded rejections

201 additional pairs were frozen from filesystem availability before metadata or
pixel reads, copied with immediate materialization checks, and independently
capture/VV2 verified. All belong to the already assigned training dates. The
expanded cohort contains 463 captures on the same 36 dates and 1,157,500 endpoint-
inclusive observations. Availability selection is a coverage limitation. Dates
are weighting groups, not independently certified shoots. Development and the
pixel-untouched acceptance reserve remain excluded.

| Bounded experiment | Whole-image passes on nine fixed controls | Decision |
| --- | --- | --- |
| Original 262-capture WB/ISO shared model | 5/9 | Reference experimental candidate |
| Same capacity, WB/tint replacing ISO | 4/9 | Reject; loses indoor pass |
| Equal-date weights, original 262 | 5/9 | No resolved gate |
| Equal-date weights, expanded 463 | 5/9 | No resolved gate |
| Expanded 463, capped source-colour importance | 4/9 | Reject; loses indoor pass, green worsens |

Equal-date fits retain 20,000 observation mass per date. Capped source-colour
importance uses source bins over [0,1.25], square-root inverse-frequency weighting
capped at eight, and per-date normalization. Target errors do not select weights.
All keep the same six WB/ISO fields, coefficient bounds, base and priors. The
expanded equal-date green mean/p95 improves only from 3.437/5.679 to 3.312/5.550;
cyan remains 1.882/6.318. Capped weighting produces green 3.670/6.100 and indoor
2.027/4.604. These failures stop those variants before full-204 evaluation.

The earlier original shared model remains the best tested broad candidate:
186/204 whole-image passes versus 173 for the static base, thirteen resolved and
zero new whole-image failures. Eighty captures have higher mean error. Eighteen
whole-image failures and difficult-region failures still block promotion.

## Source coverage diagnostic

A new RAW-only owner exports uniform source palettes over entire fixed reliable
native rectangles. It records signed source range counts separately from samples
projected onto the runtime domain. It reads no camera target. At most 4096 samples
per region bound output size. Unknown/sensitive geometry is reported, not scored
as reliable.

Private nearest-training-colour analysis uses 128 fixed source samples per region
and 32 neighbours. RAW-condition support restricts WB/ISO interpolation-weight L1
distance to 0.5, frozen before target analysis. Retrieval distances and neighbour
statistics describe support; they are not photographic metrics.

The cyan region's nearest-source RGB distance median is approximately 0.0356 in
both cohorts; expanded training does not fill the nearest palette gap. The green
face's similar-condition contributors increase from two captures to eight, while
nearest-source distance improves from 0.0117 to 0.0082. This does not establish
sufficient training coverage or representational capacity. More captures under
unchanged fitting assumptions have not resolved the photographic failures.

## Calibration preparation audit

RAW-only diagnostics compare full native development followed by reduction with
the reduced decoder tap, then optionally compare frozen-model application before
reduction with the point-RGB initializer. Both retain Gaussian radius 1.2. Signed
RGB and display-clamped source DE00 are reported; neither measures camera matching
or HEIF codec effects.

| Original region | Native/reduced source mean DE00 | Native look/current point initializer mean DE00 |
| --- | --- | --- |
| Cyan object | 0.162 | 0.271 |
| Cyan frame face | 0.318 | 1.104 |
| Cyan frame white | 0.240 | 0.984 |
| Green frame face | 0.258 | 0.587 |
| Green frame white jacket | 0.291 | 0.668 |
| Green frame tent | 0.325 | 0.522 |

These measured differences do not explain the cyan camera-match mean near 14.
They do not prove preparation irrelevant elsewhere. The reviewed cyan forward
run took 4.51 seconds, with 2.24 GB maximum resident memory, 2.81 GB peak footprint
and zero swaps. No optimization machinery is introduced.

## Corrected native objective support

The former eight-evaluation-pixel inset could erase a tiny scored region entirely:
the original cyan rectangle is only eight by eighteen pixels at evaluation scale.
It was absent from that fitting stencil. Historical results using that stencil
cannot establish expression for the original cyan object.

Native matching observations now sample the full scored rectangle uniformly,
with at most 1024 points and equal total weight per reliable region. Gaussian
support comes from the already blurred full frame. Correspondence and sensitivity
rules remain unchanged; excluded/unknown regions remain visible in final scoring.
An observable fixture verifies all 144 pixels of the tiny region are retained,
its weight sums to one, and the total sampling budget remains bounded. Coupled
field reports increment to contract 2 and name their sampling policy.

The bounded cyan capacity diagnostic freezes the original three regions plus
seventeen content-independent grid rectangles before fitting. Fourteen regions
have reliable baseline correspondence. It retains the existing three-cubed
additive field represented inside the nine-cubed profile, ±0.25 bounds, fixed
priors and six-iteration budget. It is a single target-assisted expression test;
it is neither shared inference nor independent validation. Every original region,
whole native HEIF and unknown grid area must remain reported. Budget exhaustion
cannot establish global incapacity. The interrupted first run produced no model;
the same frozen experiment was restarted without changing its contract.


### Bounded result and decision

The restarted fit completed 1015 native evaluations in 247.3 seconds and retained
11,988 observations across fourteen reliable regions. Half-step derivative checks
have relative RMS differences below 0.009. The actual mean/tail objective falls
from 6.9274 to 2.7182; all six steps are accepted. Termination is explicitly
`iteration-budget-exhausted`. Its last pre-step projected gradient is 0.2556;
this is not a convergence certificate for the nonsmooth actual objective.

Actual native HEIF whole-image mean/p95 is 1.7383/4.7587, passing both original
limits. Original face and white-shirt means are 1.0305 and 0.9098, with reliable
correspondence and passing diagnostics. Cyan mean is 2.1081, versus approximately
14.095 for the shared candidate and 16.373 for the static base. Its correspondence
sensitivity is 0.0308, so it is a measured colour failure, not unknown alignment.
It also fails the supplementary brightness diagnostic. No threshold is relaxed.

Across all twenty declared regions, twelve pass, five fail and three are
inconclusive. Fourteen regions were eligible for fitting: cyan and grid-4-1
(mean 2.0425) fail their colour limits. The remaining three failed grid areas have
excess correspondence sensitivity; three others have unknown correspondence.
All remain reported. A whole-image pass does not erase those outcomes. These are
fitted development results, not withheld expression or generalization evidence.

The sampler correction removes a real omission and greatly improves the cyan
expression witness. It does not certify that the current family is sufficient.
The next bounded investigation is the actual-objective gradient and per-region
loss/coverage alignment, retaining the current field, source, priors and limits.
Do not extend the same solver budget repeatedly or escalate field/local capacity
from this budget-exhausted result. Shared training must eventually express the
correction using RAW-only inputs, and independent acceptance remains closed.

Private receipts and media remain under the ignored persistent corpus. Public
records retain contracts, aggregate results and decisions without media, local
manifests or identifying image content. Standalone builds include numerical,
CPU/Metal, tiny-region, invalid-role, finite-input and no-overwrite fixtures.
