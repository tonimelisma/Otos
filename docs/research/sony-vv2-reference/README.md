# Sony VV2 algorithm reference — no media required

The original fixed model has known indoor-color and edge-geometry failures.
The [failure analysis](../2026-09-26-sony-lens-and-indoor-color.md) preserves an
improved [temperature-conditioned candidate](temperature-candidate/README.md)
and a narrow [18 mm lens residual](lens-residual-candidate/README.md). These are
separate experimental supplements, not replacements silently applied below.

This package preserves the learned algorithm and numerical data needed to
implement it later, without retaining any training media. It contains no photo,
thumbnail, image crop, capture metadata manifests, sampled photo pixels, or private path
manifest. There are no third-party runtime dependencies.

- `model.json`: exact final channel curves and residual LUT, with format version.
- `test-vectors.json`: 560 entirely synthetic input/output RGB cases, including
  gray ramps, channel extremes, and out-of-domain values. These are numeric
  unit-test fixtures, not encoded media.
- `training.md`: the exact fitting algorithm in language-independent form.
- [NativeReference.swift](NativeReference.swift.md): exact CPU and Metal evaluation.
- [Develop.swift](Develop.swift.md): full-resolution Core Image RAW boundary.
- [Verify.swift](Verify.swift.md): executable synthetic conformance checks.
- [Comparison.swift](Comparison.swift.md): native pixel-comparison harness.
- `validation-summary.json`: aggregate historical held-out measurements.
- `native-detail-summary.json` and `raw-controls-summary.json`: aggregate native
  resolution and RAW-control experiments.
- The parent [research note](../2026-09-23-sony-vv2-raw-rendering-poc.md) records
  the original experiment's evidence and limits.

The training pictures are not required to evaluate the saved filter, verify a
port against the synthetic fixtures, or understand how the parameters were
learned. Repeating the old photographic experiment after discarding its data
would be impossible; applying its learned result remains possible.

## Input/output contract

Input is finite, unpremultiplied, extended-sRGB-encoded RGB from the documented
neutral Apple RAW decoder v8 development, not linear-light RGB and not an
embedded camera preview. RAW pixels are opaque. A caller handling transparency
must unpremultiply before the RGB function and premultiply after it; preserve
alpha separately. Reject NaN and infinity.

Clamp each input component to [0,1.25] for both curve and LUT lookup. Evaluate
both at that original clamped input. Add curve and residual values, then clamp
outputs to [0,1]. Output is SDR sRGB-encoded RGB. Do not treat output numbers as
linear light, apply the grade twice, or apply the learned function to an existing
Sony HEIF/JPEG. Converting into another display/output space occurs afterward.

Curve channel order is RGB. Residual JSON nesting is [red][green][blue][RGB],
with blue varying fastest if flattened. Interpolate linearly between curve
knots and trilinearly between cube nodes. At a maximum coordinate, use the last
cell with interpolation fraction one; out-of-range values use endpoints.

The exact CPU reference uses Float64; the native Metal path uses Float32. The
synthetic fixtures specify 1e-12 and 2e-6 absolute tolerances respectively.
Do not preclip residual coefficients or combined cube-node values: intermediate
negative values or values above one can be necessary for correct interpolation.

## RAW boundary

Use `CIRAWFilter` on the sensor data. Explicitly require/select decoder v8 and
fail if unavailable; never silently substitute a newer decoder. Set boost,
local tone mapping, contrast, sharpness, and detail to zero. Retain camera white
balance, baseline exposure, shadow bias, highlight recovery, lens correction,
gamut mapping, and the documented per-file native noise defaults unless a
separately measured detail recipe says otherwise. Changing these conventions
changes the function's input and invalidates an unqualified quality claim.

The historical decoder listing captures the exact original API calls. Its
768-pixel scale was an experiment setting, not an input-image dimension required
by the pointwise learned function. The [full-resolution pass](../2026-09-23-sony-vv2-native-detail.md) supports
retaining this boundary with no mandatory extra sharpening. Apple decoder behavior still depends on macOS and supported RAW
formats; preserving this package cannot freeze Apple's implementation forever.

Check `SF_DATALESS` immediately before any original-file byte read. The look
function itself accepts already available pixels and performs no file access.

## Compile and verify without photographs

Extract each listing's single Swift code block. Save the verification listing as
`main.swift`, and the evaluator as `NativeReference.swift`. With full Xcode selected:

```sh
xcrun swiftc -O NativeReference.swift main.swift -o verify-reference
./verify-reference model.json test-vectors.json
```

Only Foundation, Metal, the model, and synthetic fixtures are required. The RAW
listing additionally uses Core Image and Darwin; compile it alongside the
reference when developing real RAW files. All work and GPU waits belong off the
main actor. This synchronous research reference specifies numerical behavior;
app scheduling, allocation-failure handling, and UI/export ownership remain normal
implementation work. There is no third-party package to install.

Use `LookModel(json:)` as the loading entry point; JSON decoding validates the
model invariants through either initializer. Unknown model
versions, malformed dimensions, non-finite inputs, and changed RAW contracts
must fail explicitly rather than silently render a different look.

## Preserved and disposable material

Keep this entire small directory together. The learned coefficients, format
contract, fitting math, native listings, synthetic expected outputs, and aggregate
evidence are sufficient to implement this measured recipe. Private originals,
decoded arrays, crops, registration manifests and local experiment environments
are not runtime dependencies. The local A/B gallery is optional visual evidence;
it can also be removed after review. No media was deleted by this research.
