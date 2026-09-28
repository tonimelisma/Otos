# Sony rendering measurement harness

This is a private-data research tool for [plan 0105](../../docs/plans/0105-accurate-sony-rendering-pipeline.md),
not a renderer integrated into Otos. It freezes pair roles, verifies capture
metadata, compares the existing saved model with Apple RAW baselines, and emits
scorecards plus local A/B assets. No photographic accuracy claim follows from a
low average score. Keep all photo manifests, output PNGs and model fitting data
outside Git. The tool reads originals but never writes to their directories.

## Build and private inputs

Use the full repo Xcode toolchain. Build with `build.sh /private/output-dir`.
The script compiles the exact saved numerical model from
`docs/research/sony-vv2-reference/NativeReference.swift.md` and runs the
published CIEDE2000 cases plus scorecard/geometry fixtures. An installed
ExifTool is needed only for the independent capture metadata audit; the native
renderer and Otos app do not depend on it.

Input manifests have this shape and must remain private:

```json
{"pairs":[{"id":"capture_name","raw":"/absolute/original.arw","target":"/absolute/companion.heif","session":"capture_session","role":"regression"}]}
```

Roles are `training`, `selection`, `regression`, and `acceptance`. A session must
have one role. The public split scripts select by capture names and frozen seed,
but require private inventory/manifests as arguments. The metadata verifier
checks that each ARW and companion have the same camera, time, exposure, lens,
focal length and declared Sony VV2 settings. It checks `SF_DATALESS` immediately
before ExifTool reads either file. Rejected or unavailable pairs do not enter its
verified manifest. Keep its report and the SHA256 of each frozen private manifest.

`sony-render-materialize request input.json status.json` deliberately asks the
File Provider to download dataless originals without a blocking byte read.
`sony-render-materialize status input.json status.json` reports local, dataless,
unknown and requested counts using only inode facts. Requests may fail or remain
pending; do not treat a request as proof that bytes are local. The evaluation
command checks `SF_DATALESS` immediately before every original byte read and
reports unavailable originals rather than hydrating them implicitly.

Run `sony-render-harness evaluate verified.json model.json /private/output-dir`.
The model path is the preserved saved `sony-vv2-reference/model.json` baseline.
The output directory must be outside all media directories. Each pair writes
one JSON record, full-frame PNGs, and four unregistered 512-pixel native corner
crops. `summary.json` records complete/failure counts; `index.html` compares
only those same outputs. It is a private local page, never a public gallery.

## Score interpretation

- RAW decoding is pinned to `CIRAWDecoderVersion("8")`. The saved fixed model
  receives Apple neutral development; Apple default and neutral are separate
  baselines. The harness errors if the decoder or dimensions do not match.
- Every color frame is encoded to extended sRGB with a fixed 768-pixel long edge.
  A Vision homography from the fixed-model image establishes common measurement
  coordinates. That same transform is applied to the two Apple baselines. Viewer
  frames remain unregistered so crop and edge discrepancies stay visible.
- Color uses D65 sRGB to Lab and CIEDE2000. A separable Gaussian with sigma 1.2
  evaluation pixels yields low-frequency mean and p95, alongside unblurred mean
  and p95. Invalid/transparent correspondence is excluded, never high color
  error. Valid and clipped fractions are reported separately.
- Independent local gradient correspondence checks 40 spread-out locations after
  the homography. Flat, ambiguous and search-boundary locations count against
  coverage. The score removes only a global translation, then reports median and
  p95 residual in native-pixel units. It is a diagnostic on a downscaled image,
  so it cannot alone certify the plan's half-native-pixel geometry target.
- The native crops provide visual detail/noise/halo evidence but no automated
  native detail pass yet. Geometry and color failures remain separate. Do not fit
  or select a model using `acceptance` images before the final pipeline is frozen.

The browser-based A/B controls could not be agent-validated in this environment:
automatic approval review denied opening the private derived-media page. PNG
assets can be inspected locally. That limitation keeps the visual acceptance
gate open; do not route the private page through another browser path.
