# Sony rendering: indoor color and edge geometry

September 26, 2026. Research only; no Otos application behavior changes.

The previous saved recipe is implementable, but its quality is not a solved Sony
match. User review exposed poor indoor color and a systematic edge mismatch in
original gallery photos 2, 3 and 6. This pass preserves two improved candidates
with explicit limits. Neither is silently promoted into the original model.

## Outcome

- A temperature-conditioned residual color model improves the original session
  holdouts from mean CIE76 2.3684 to 2.1783, including the indoor session from
  4.8225 to 3.6154. On 19 earlier dates excluded from coefficient fitting, the
  mean improves from 3.0587 to 2.8038; 15 of 19 images improve.
- An additional radial geometry correction fitted to photo 2 transfers to photos
  3 and 6 at the same 18 mm setting. Their estimated displacement RMS drops from
  approximately 0.90 to 0.10 pixels in 2048-pixel previews. Direct edge-detail
  squared error falls 27.8% and 26.3%, respectively.
- Warm indoor color is better, but not solved. A green-tent image worsens from
  CIE76 7.545 to 8.121. Geometry remains a narrow preview calibration, not a
  validated general lens profile or native-resolution correction.

The user authorized earlier OneDrive downloads and requested native macOS APIs,
no external dependencies, no media in Git, and enough numerical documentation to
implement the results later. These are research constraints, not new implemented
product requirements. Preserve coefficients and references; do not discard all
paired calibration media on the assumption broader matching is finished.

## Data access and scope

The original 344 decoded/aligned sample sets remained available privately even
when originals had been evicted. They support the original-session color pass.
Historical alignment was produced by the earlier experiment; this follow-up
uses Python standard-library ZIP/NPY parsing, with correct Fortran-order handling,
to read those existing arrays. No third-party numerical package participates.

A new request selected one pair per earlier capture date: 51 dates, plus four
previous failure cases for diagnosis. The initial 55-pair batch planned
2,382,700,544 bytes. Nineteen earlier pairs decoded successfully, representing
19 dates from May 23 to August 23 and 794,390,528 original-file bytes. Thirty-two
earlier pairs and four old diagnostic pairs were unavailable during that batch.
Errors included POSIX code 3 and timeouts; unavailable is not evidence of deletion.
Later targeted retries successfully materialized all three user-selected geometry
pairs, including one previously unsuccessful pair and two added requests. These
three are not additional color-validation dates.

Every ordinary original read was preceded by an `lstat` regular-file and
`SF_DATALESS` check. Explicit hydration attempts were identified as such before a
one-byte read triggered OneDrive. Apple's ubiquitous-item download request did
not yield local files within the initial bounded attempts; the subsequent native
file reads did for some pairs. A two-worker private batch bounded failed requests.
The initial decode batch finished in 187.7 seconds. Download timings vary with
provider state and are not application performance claims. Originals were never
modified, relocated, deleted, or added to Git. Checks cannot atomically prevent a
provider eviction between inspection and reading.

Image I/O reports the 19 newly decoded companions as Sony ILCE-6700, 10-bit SDR
sRGB, with consistent PictureStyle ColorMode fields. This follow-up did not
independently decode the proprietary VV2 tag for those new files; consistency of
Apple's field is weaker evidence than explicit look identification. The original
344-pair metadata verification is documented separately.

## Color: conditioning on the RAW white balance

A fixed RGB transform cannot distinguish all lighting conditions. A diagnostic
per-image affine fit, which is allowed to see its own Sony target, reduces mean
error further than a global affine fit. It is an explanatory upper-bound probe,
not an algorithm available when developing a new RAW alone.

A temperature/tint-conditioned affine correction modestly improved the whole
original set, but regressed some scenes. The preserved candidate instead adds two
smooth 9³ residual cubes to the original model: a base residual and a residual
multiplied by a mired-temperature coordinate. It uses the native RAW white balance,
not a temperature inferred from Sony target pixels. Coefficients are learned on
original images only. Exact fitting, interpolation, clamping, array layout,
regularization and validation boundaries are in the
[temperature candidate](sony-vv2-reference/temperature-candidate/README.md).

| Evaluation | Original model | Candidate | Interpretation |
| --- | ---: | ---: | --- |
| Original 344, session-held-out | 2.3684 | 2.1783 | 290 images improve |
| Original warm indoor session, 18 images | 4.8225 | 3.6154 | 25.0% lower mean error |
| Earlier 19 dates, excluded from fitting | 3.0587 | 2.8038 | 15 images improve |
| Earlier warm indoor example, 3313 K | 5.2966 | 3.3869 | 36.1% lower error |
| Earlier green-tent example | 7.545 | 8.121 | Demonstrated regression |

Scores are mean CIE76, lower better, equally averaged per image. Earlier photos
were evaluated for the affine hypothesis before the richer candidate; they are
out of coefficient fitting but no longer an untouched acceptance set for further
model selection. Two original session means also regress. Average improvement is
not permission to claim every indoor scene now matches. Mixed or spectrally
filtered light is not fully described by color temperature.

New comparisons use Vision homography for measurement, Core Image Gaussian blur
radius 1.2, and encoded-sRGB-to-D65-Lab conversion. Display images are not warped
to their own targets. Metrics slightly differ from historical sampling/conversion;
compare original and candidate within this pass, not tiny cross-report changes.

## Geometry: Apple correction is present, but not identical to Sony

All original 344 decode records report lens correction supported and enabled.
On all 19 new pairs, disabling it changes pixels; mean absolute on/off difference
ranges from 0.00623 to 0.08862. This includes geometry and other correction effects,
not an isolated distortion score. Apple exposes correction capability and an
on/off flag; that is not a promise to duplicate Sony's rendering.
[Apple lens-correction documentation](https://developer.apple.com/documentation/coreimage/cirawfilter/3801632-lenscorrectionenabled).

The three user-selected RAWs report the same 18 mm setting and lens-model string.
Native Core Image metadata and a bounded read-only TIFF parser found embedded
Sony distortion fields 0x7036 and 0x7037. Their identification agrees with the
[ExifTool tag reference](https://www.exiftool.org/TagNames.pdf). No ExifTool program
or library was installed or used. The embedded parameter evaluation remains
unresolved; its presence alone does not establish how Apple or Sony applies it.

Apple Vision optical flow revealed similar nonlinear radial edge displacements
in all three existing 2048 × 1366 gallery previews. A six-parameter fit learned
only from photo 2 generalizes to photos 3 and 6. Direct high-pass image comparison
also improves after rendering that same fixed correction. The preserved
[lens residual candidate](sony-vv2-reference/lens-residual-candidate/README.md)
contains its mapping, calibration grid, coefficients, measurement procedure,
synthetic tests and held-out results. It requires Apple's original correction
first and does not use a new photo's Sony target at inference.

Flow across differently developed images is estimated correspondence, not a
physical lens calibration. These results do not establish full-resolution
quality, arbitrary zoom/focus settings, portrait orientation, crop changes or
chromatic-aberration matching. Keep those limits alongside the coefficients.

## Review artifacts and implementation readiness

The private local viewer has an indoor comparison with old/candidate/Sony views,
including the green-tent regression. A separate edge page presents photos 2, 3
and 6 with full frames and all four corner crops. Old/corrected switching changes
only geometry. Local image assets were inspected and all referenced assets were
checked. Browser automation refused the local file URL, so interactive browser
validation was unavailable; no alternate access route was used to bypass it.
No gallery files, private paths, original metadata manifests or RGB samples are
in the repository.

The saved color candidate includes 448 synthetic RGB/temperature fixtures; the
lens candidate includes 21 synthetic coordinate fixtures. Extracted Swift listings
compile with Xcode 27.0 (27A266a), use Apple frameworks only, reject malformed
models/invalid inputs, and pass their numerical checks without media access.
This is numerical conformance, not proof of photographic quality outside the
measured data. Fitting uses Swift/Metal/Accelerate; the saved inference references
use Foundation plus the original native evaluator. No app build is required for
this documentation-only increment.

The previous native-detail conclusion remains: there is no demonstrated need for
mandatory additional sharpening. Color correction, geometry and detail are
separate effects; sharpening cannot repair either lighting color or distortion.
Implementing the saved candidates no longer needs the photographs. Improving
those candidates, independently validating a new default, or building a broader
lens solution still needs paired examples. No claim of complete Sony replication
or a finished Otos filter feature is made.
