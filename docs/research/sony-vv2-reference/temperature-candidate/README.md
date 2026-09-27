# Experimental temperature-conditioned correction

This is an improved candidate, not a claim that indoor Sony matching or residual
lens geometry is solved. It supplements the original saved model. It changes no
Otos application behavior. Keep the original model as an explicit baseline.

The source of truth is `model.json` plus the original parent `model.json`.
`TemperatureCorrection.swift.md` is a native Swift scalar reference;
`Verify.swift.md` and 448 synthetic fixtures verify it without photographs.
No external runtime dependency is required. A production implementation can fuse
the extra two trilinear lookups into the existing Metal evaluator; that optimized
candidate GPU implementation has not been provided or benchmarked here.

## Exact evaluation

Let x be the original neutral encoded RGB, p the original model's **already
clamped** output, and T `CIRAWFilter.neutralTemperature` in Kelvin:

```text
t = (1,000,000 / T - 200) / 100
candidate = clamp(p + trilinear(z0, x / 1.25)
                    + t * trilinear(z1, x / 1.25), 0, 1)
```

Clamp lookup coordinates to [0,1]; do not replace x with p for cube lookup.
Both cubes have 9³ nodes, flattened as r*81+g*9+b. Coefficients are channel-major:
3 channels × (729 base-residual nodes + 729 temperature-residual nodes).
The coefficient at channel c, cube b, node i is `coefficients[c*1458+b*729+i]`.
Use trilinear interpolation, Float64 for conformance, and the original color,
alpha and RAW-development contracts. Preserve alpha separately. Require finite
RGB and positive finite T. Native RAW lens correction remains enabled.

The original training temperatures spanned 3002.73–7226.69 K. Arithmetic outside
that range is defined but photographic extrapolation is unvalidated. Temperature
is a useful conditioning variable, not a full spectral description of lighting.
Green-filtered light remains a demonstrated failure case.

## Fitting and validation boundary

The original 344 aligned/blurred paired-pixel arrays and capture-session groups
were retained locally. Read NPY payloads using Python's standard-library ZIP and
array format parsing only; preserve column-major layout when present. The fitting
and evaluation code uses Swift, Apple Metal and Accelerate's LAPACK Cholesky solve.
No NumPy, SciPy, OpenCV or other third-party library was used for this follow-up.
Historical registration/prepared data did originate in the earlier experiment.

For each held-out session, use that session's historical held-out original color
model. Fit the new correction only on the other sessions. From each image's
10,000 historical evaluation samples, take every twentieth sample: 500 samples,
including clipped colors omitted by the original curve/LUT fitting mask. Define
A's row as `[w(x), t*w(x)]`, where w has the eight 9³ trilinear weights. Fit each
channel to target minus the original model's clamped output:

```text
(AᵀA + 2 blockdiag(BᵀB, BᵀB) + 0.4 I) z = Aᵀ(target - p)
```

B is the immediate axis-neighbor cube incidence matrix. These regularization
weights were fixed before this candidate's scores, scaling the original 2,500
sample regularization to 500 samples per image. Solve in Float64. For reporting,
evaluate every tenth historical evaluation sample (1,000/image). Training and
evaluation image groups remain disjoint despite reuse of arrays within training.
The final saved correction uses all 344 images and the original all-data model.

Nineteen earlier capture dates were entirely excluded from fitting. Rendered pairs
were decoded at 768 pixels, aligned using Apple Vision homography, blurred with
Core Image Gaussian radius 1.2, and scored on every sixteenth pixel inside an
eight-pixel border. Errors are per-image means, then equally averaged. CIE76 uses
standard sRGB-to-D65-Lab conversion. This sampling/conversion differs slightly
from the historical 10,000-pixel OpenCV metric; compare methods within this pass.
A simpler affine candidate was evaluated on these dates first. They were not
used for either candidate's coefficients, but no longer constitute an untouched
final acceptance set for further model selection.

Image I/O confirms the earlier companions are Sony ILCE-6700 SDR sRGB, with
consistent PictureStyle ColorMode values among decoded files. The relationship
between that Apple-exposed field and Sony's proprietary VV2 tag was not decoded
independently; do not claim that exact look-tag verification was repeated.

## Compile and check

Extract the two Swift blocks. Name the verifier `main.swift`; also extract the
parent `NativeReference.swift`. With full Xcode selected:

```sh
xcrun swiftc -O NativeReference.swift TemperatureCorrection.swift main.swift -o verify
./verify ../model.json model.json test-vectors.json
```

`validation.json` records aggregate evidence and numeric verification. The
[research report](../../2026-09-26-sony-lens-and-indoor-color.md) explains failures,
materialization outcomes and the distinction between calibration and evaluation.
Preserving this package is sufficient to implement this candidate. Further lens
calibration and better matching still require paired images; do not discard all
calibration material on the assumption those problems have been solved.
