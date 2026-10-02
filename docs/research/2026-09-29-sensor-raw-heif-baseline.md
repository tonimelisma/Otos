# Standalone sensor RAW-to-HEIF baseline (2026-09-29)

The standalone `sensor-raw-heif` command now uses ILCE-6700 ARW sensor data
through `CIRAWFilter` decoder version 8 at native resolution. The separate lens
stage explicitly enables Apple's supported correction. The current look stage
is Apple's default RAW development. The command writes a ten-bit SDR sRGB HEIF
to a complete temporary file and publishes it without overwriting an existing
file. It refuses dataless originals and an output inside a declared media root.
This is a working RAW-origin HEIF baseline, not the accurate Sony VV2 look.

The first output was 6192 × 4128. `ffprobe` reported `yuv420p10le`, BT.709
primaries and sRGB transfer; the encoded file is SDR. `sensor-raw-evaluate`
decodes the actual published HEIF for color and unregistered native geometry
measurements. The six permanent regressions and 18 previously selected
development captures were run. Untouched acceptance captures were not scored.

| Role | Pairs | Average image mean low-frequency ΔE00 | Mean range | p95 range | Color passes (mean ≤2, p95 ≤5) | Native geometry coverage |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Known regressions | 6 | 7.234 | 5.806–8.887 | 10.447–14.550 | 0 | 4/6 |
| Development selection | 18 | 6.441 | 5.032–8.100 | 9.928–14.409 | 0 | 8/18 |

The reported geometry p95 ranges among covered images are 3.118–24.154 native
pixels for regressions and 0.501–11.980 for selection. Low coverage on flat or
ambiguous scenes is reported, not silently counted as a geometry pass. Mean
render time on the six regressions was under 1.3 seconds per image on this
machine, excluding scorecard work; no peak-memory or cancellation claim yet.

An initial full-size HEIF encode returned `nilError` under the restricted
execution environment, as did a synthetic 768-pixel HEIF and an 8-bit variant.
The synthetic and RAW encodes succeeded with normal macOS graphics access.
Thus this was a graphics-service permission issue in the test environment, not
a RAW or model failure. The build and numerical self-test pass in the restricted
environment; photographic HEIF runs require normal graphics access.

The next look experiment will start from the saved fixed-model baseline and
test a per-image correction derived only from the ARW's embedded camera guide.
That guide may inform color/tone parameters, but output pixels must still be
developed from the sensor. It cannot be substituted as the output image.

## First preview-assisted capacity probe

As a bounded diagnostic, an affine 3 × 4 RGB correction was least-squares fitted
for each of the six regressions between the prior fixed-model 768-pixel output
and the 768-pixel camera guide embedded in its own ARW. About 4,300-5,500
unclipped pixels per image were sampled on an eight-pixel grid. The separate
Sony HEIF was withheld from the fit and used only for the final score. This
probe used eight-bit PNGs and did not produce native HEIFs, so it is not a
candidate renderer or a full-resolution validation.

The six low-frequency means changed from 1.649, 2.296, 3.135, 3.870, 2.202,
3.102 to 1.493, 2.032, 2.230, 3.949, 1.965, 2.134. Two of six met both
color thresholds after the fit; one image regressed in mean and another in
p95. The affine correction is insufficient. A stronger nonlinear tone/color
model and cleaner correspondence are needed before adding preview assistance
to the renderer.

## Sensor-derived fixed-model HEIF

The saved fixed look model now also runs at native resolution, after neutral
Apple sensor development and explicit native lens correction. Its Metal evaluator
works on encoded extended-sRGB values. A first encoded HEIF was visibly too
bright because the output context applied an additional sRGB transfer. The
output boundary now tags the model's encoded values without another transfer;
the same correction was checked on the decoded HEIF, not just a preview buffer.
The output is 6192 × 4128, `yuv420p10le`, BT.709 primaries and sRGB transfer.

| Development role | Pairs | Average mean low-frequency ΔE00 | Mean range | p95 range | Color passes |
| --- | ---: | ---: | ---: | ---: | ---: |
| Permanent regressions | 6 | 2.379 | 1.481–3.022 | 3.242–7.817 | 1/6 |
| Original selection | 18 | 1.626 | 1.121–3.009 | 2.440–5.787 | 16/18 |
| Newly verified selection | 61 | 1.667 | 0.986–3.168 | up to 6.274 | 52/61 |

All 61 newly verified selection RAWs rendered to HEIF with no file failures.
They span 17 capture dates. In that set, the 18-50mm lens passed 51/55 color
gates, the 16mm passed 0/4, and the 10-18mm passed 1/2. All five ISO 12,800
examples failed; 47/50 at ISO 100-400 passed. Five additional 23mm training
captures from two dates rendered successfully and passed 5/5 color gates, but
their measured native geometry p95 was about 5.9-7.0 pixels on four of five
with enough correspondence. These sets are development evidence; the frozen
72-pair acceptance set remains untouched.

The native lens stage is unchanged, and its Sony geometry residual remains
reported under the deferred custom-profile decision. The strongest remaining
look failures are the preselected indoor/green-tent cases, high-ISO captures,
and some 16mm images. The model is an operational RAW-to-HEIF renderer but not
yet a reliable Sony-look match across the intended scope. The standalone safety
fixtures pass for output placement, no-overwrite and original preservation.

## Preview-guided sensor development candidate

The ARW's full-size camera JPEG can be used as a *guide* without encoding its
pixels as the output image. The renderer first develops the sensor RAW at native
resolution, applies the saved fixed look model, and then downsamples its result
and the embedded camera image to a 768-pixel long edge. It blurs both in encoded
sRGB with Core Image `CIGaussianBlur` radius 2, subtracts the blurred sensor
result from the blurred camera guide, enlarges that signed correction field to
native resolution, and adds it to the native sensor-developed pixels. The final
RGB is clipped only after this addition and encoded to 10-bit SDR HEIF. The
field's blur covers roughly 16 native pixels on the ILCE-6700; fine texture is
still from sensor development. This mode fails explicitly when the full-size
embedded guide is absent. The separate Sony HEIF is never used for inference.

Radius 4 was a development-only first candidate: the actual encoded files
passed 5/6 hard regressions and 18/18 original selection captures. Radius 2
was selected on those development sets before the untouched acceptance run.
Its actual encoded HEIFs pass 5/6 hard regressions, 18/18 original selection,
61/61 newly verified selection captures, and 5/5 additional 23mm training
captures. The 61-pair set spans 17 capture dates, ISO 100-12800, and the
10-18mm, 16mm and 18-50mm lenses. All 61 files encoded successfully. Their
mean low-frequency ΔE00 spans 0.295-1.378; the highest p95 is 3.614. All
five ISO 12,800 examples pass. The separate 23mm probe spans two dates and
scores mean 0.445-0.504, p95 0.930-1.273.

The remaining known regression is a waterfall/foliage image. Its guided mean
is 1.823 but p95 is 5.625, above the proposed 5.0 gate. Native corner crops
show strong magenta/green branch fringing already present in the un-guided
Apple RAW output and not in Sony's companion. The guided field does not create
that fringe. Apple's enabled lens correction still leaves a measured geometry
residual around 23 native pixels on this image. In one inspected indoor crop,
the mean absolute difference of 3-pixel native high-pass content between guided
and un-guided sensor HEIFs was 0.37/255 per channel; the reference high-pass
energy was 3.07/255. In a high-detail waterfall corner it was 0.44/255 against
16.13/255 of reference high-pass energy. These support RAW detail retention in
those crops, not a complete detail/noise certification.

The first 61-pair radius-4 evaluation was killed after 40 completed captures
with a forced process exit. The harness now evaluates each image in a separate
child process so Core Image, Metal and Image I/O allocations are released
between captures. The radius-2 61-pair run completed with zero failures.
The renderer also carries whitelisted source camera/capture/lens/exposure/GPS
metadata into the HEIF. An inspected landscape and portrait kept their capture
time and lens; portrait pixels were 4128 × 6192 with no stale RAW orientation
tag. A metadata-only change left the inspected photographic score unchanged.

The frozen 72-pair acceptance set has 12 distinct sessions and no capture or
session overlap with the development sets. It remained untouched during the
development checks above. Geometry/profile fidelity, the waterfall fringe,
broader native detail, metadata coverage, memory/latency and cancellation were
then carried into the first acceptance audit below.

## First untouched acceptance run

The frozen radius-2 algorithm with metadata preservation ran once against all
72 untouched HEIF/RAW pairs from 12 disjoint sessions. The same compiled
renderer and saved model were used for every pair; the binary SHA-256 was
`e0152ee2461e07316d6e5afef435b146f7932faada4986c81eec89d573ff82b1`
and the model SHA-256 was
`8dcd2e1a154a815d283580b106d0f7a29d949df127a77d59a0177a2ee650acea`.
There were zero render failures. All 72 passed the predeclared broad color
thresholds (mean ≤2.0 and p95 ≤5.0 low-frequency ΔE00). Their average image
mean was 0.654, individual means 0.334-1.431, and the worst p95 was 4.543.
The acceptance corpus contains 67 captures with the Sigma 18-50mm, three with
the Sigma 23mm, one with the Sigma 16mm, and one with an E 70-300mm F4.5-6.3
A047. One capture does not establish general 70-300mm lens coverage.

Every acceptance output decoded as a native 6192 × 4128 or portrait 4128 ×
6192 HEIF with `yuv420p10le`, BT.709 primaries and sRGB transfer. Image I/O
metadata checks found camera make/model, capture date, lens model and ISO
matching each RAW for all 72; GPS coordinates were retained, with sub-0.2 m
numeric differences from Image I/O rounding. Orientation was normalized in the
pixels without carrying a stale RAW orientation tag. The 72 image render times
had median 2.082 s, p95 approximately 2.336 s and maximum 2.886 s, excluding
evaluation. A separate one-shot process measurement showed 2.48 GB maximum
resident set and 3.21 GB peak memory footprint on this machine. An early
process-termination probe left no published or temporary HEIF; no guarantee is
made for every possible point during final encoder publication.

Native geometry remains separate from this color result: only 27/72 acceptance
images had enough independent matches for a p95. Among those, p95 residual
spanned 0.419-26.044 pixels (median 5.369). The user directed us to defer custom
lens profiles when no complete ready solution existed; these differences are
reported rather than hidden by registration. Inspected native crops show RAW
texture retention, different high-ISO noise from Sony, and some chromatic
fringing already present before the camera-guide stage. The known waterfall
regression still has p95 low-frequency ΔE00 5.625 and visible wide-angle
fringing, so not every photographic/detail target in plan 0105 is satisfied.
