# Shared RAW-only fitting and model-domain training coverage

Date: October 2, 2026. Standalone Plan 0105; no app integration.

## Broad unchanged baseline

The local 204-pair development corpus completed 204 native HEIF exports with zero
operational failures. The saved RAW 9 profile passes 173 whole-image mean/p95
colour gates and fails 31, across 21 capture dates. These are development results,
not independent acceptance. The earlier 77 failures belong to the separately
reported authored format-5 baseline and are not comparable recipe identities.

All five July 6 images fail; all five 16 mm images fail, but those are the same
warm/high-ISO group. This is confounding, not evidence that lens identity causes
colour error. Thirteen of sixteen images with RAW neutral temperatures rounded
to 3000 K fail; all six ISO 12,800 images fail. Among ISO 100 images, twelve of
142 fail. Warm-lighting, colour support and native noise/detail need separate
attribution. Every development pair passed a fresh same-capture/Sony-look audit.

The six old region controls were rescored with the committed, separately rendered
RAW-derived geometry recipe. Existing failures persist: warm face/towel, green-lit
face, foliage and cyan. Cyan toy has mean DE00 16.373 despite its whole-image pass;
its mean correspondence sensitivity is 0.099. The region cannot be hidden by an
image average. Wall, warm white shirt and green tent remain inconclusive. Geometry,
mean-colour failures and diagnostic median statistics retain separate labels.

## Persistent data and split recovery

The temporary private directory was cleared between runs. Local development copies
and completed benchmark outputs survived in the ignored primary-checkout build
folder. Further manifests, binaries, logs, sample files and reports now live there.
The lost prior training manifest is not silently reconstructed or treated as an
identical split. A new name-only, SHA256-seeded selection freezes up to eight
candidates per eligible date before metadata/pixel inspection. All development
dates and every date from September 24 onward are excluded. The result is 263
training candidates across 36 dates. 262 pairs were copied, hash/size checked and
capture/VV2 verified; one file remains unavailable. They retain training roles.
These are capture-date groups, not certified semantic shoots.

## Shared fitting, first feedback

Both sequential and constrained joint curve/LUT fits used the same first 147
available, verified training captures across 29 dates, with 353,011 observations.
The joint owner reuses the existing solver, preserves monotone channel curves,
identity/ridge/neighbour priors, and records finite-budget convergence diagnostics.
All joint channels exhausted 600 iterations; this does not prove a global native
photographic optimum. Runtime still receives one shared profile, never a lookup
of target-assisted per-photo coefficients.

On the predeclared six-image native HEIF screen, neither candidate clears the
known failures. Indoor mean/p95 changes from 3.056/6.009 to 2.578/5.322 sequential
and 2.561/5.294 joint; warm face image mean changes from 3.029 to 2.719/2.733.
The good control remains a pass. Daylight p95, foliage and green-lit image failures
remain. Joint fitting adds little benefit here. Neither candidate is promoted.
Expanded fitting on all 262 verified captures uses 624,929 observations. The
sequential indoor mean/p95 is 2.692/5.521 and joint is 2.671/5.485; warm image
means are 2.778/2.789. Both still pass only the good control in this six-image
whole-image screen. Increasing training size does not remove these errors, and
neither expanded candidate is promoted. This is a measured data-size comparison,
not evidence that all larger datasets or global models are incapable.

## Endpoint-support ablation

Inspection of the retained calibration exporter finds an explicit interior-only
sample rule: source channels must all exceed 0.005 and stay below 1.245; target
channels must exceed 0.005 and stay below 0.99. This omits source-domain boundaries,
including saturated colours with zero/negative encoded channels, and target
clipping. The badly failing cyan control makes coverage a concrete next question;
these observations do not establish that sample exclusion caused its error.

An explicit modelDomain training policy retains finite, opaque samples and applies
the unchanged runtime source-domain clamp [0,1.25] and target display clamp [0,1].
Contract 3 records this policy; the historical interior reproduction contract
remains separately selectable. Loader contract checks prevent mixing policies.
Synthetic tests check saturated/negative endpoints and rejection of nonfinite
values. Role guards reject selection/regression/acceptance before sampled-media
reads. This is a controlled data-support ablation, not increased inference capacity
or relaxed photographic masks. Fitting blurred sample RGB is still a surrogate;
only actual native HEIF and fixed-region results can select a candidate.

Keep RAW 9, supported native lens correction, profile capacity, comparison limits,
old regions and date-disjoint development images fixed. Compare ordinary and
endpoint-inclusive fits on the same expanded training captures. Reject promotion
when hard controls or successful captures regress. If shared fits still leave a
condition-dependent error, investigate RAW-only adaptation and native-order
observations; do not fit lens defects into colour. Native detail and final independent
acceptance remain open.

## Endpoint-support result and next decision

All 262 endpoint-inclusive exports complete without failures, yielding 655,000
observations. A multiset differential confirms that all 624,929 interior training
observations occur byte-for-byte unchanged in the expanded observations. This
isolates training support rather than a changed RAW or target development.

Both ordinary and endpoint-inclusive sequential/joint fits pass three of nine
whole-image screen captures and fail the same six. The old cyan region improves
from 14.889 sequential / 14.867 joint to 12.848 / 12.750 with endpoint support,
but remains far outside the mean limit of two. Warm face, green-lit face and
correspondence-sensitive foliage remain failing; flat/ambiguous regions remain
inconclusive. The expanded sampler is useful evidence, not a sufficient matching
algorithm. No inference model is promoted and no comparison gate is changed.

The next bounded comparison is a constant shared correction versus a shared
correction conditioned only on RAW white balance/tint and ISO. Keep the current
native input, lens owner and comparison frozen. A compact conditional colour
field can test whether the measured warm/high-ISO pattern is predictable across
date-disjoint captures; metadata-conditioned matrices previously failed and are
not assumed sufficient. Native actual-output and old-region feedback decide
whether conditioning merits further work. Target paths/pixels never enter the
runtime predictor. Native-order surrogate and solver limitations stay explicit.
