# Full-size camera rendering inside ILCE-6700 ARW

September 28, 2026. Plan 0105 alternative-input investigation. This is a
measured candidate for a camera-look HEIF, not a claim that the sensor data has
been developed into 10-bit output. The 72-pair untouched acceptance set was not
read or scored during this investigation.

## Source and contract

The inspected Sony ILCE-6700 ARWs contain a camera-rendered JPEG in the third
TIFF IFD. It measures 6192 × 4128 pixels on the tested files; the earlier IFDs
hold smaller previews. A metadata-only IFD scan of all 188 verified training
ARWs found a bounded JPEG span with a JPEG header in 188/188 files. EXIF
orientation was 1 in 142, 6 in 37, and 8 in 9. All byte reads were preceded by
the repository's dataless-file check. The separate Sony companion HEIF was used
only as a comparison target.

This embedded source is eight bits per component and already includes Sony's
camera development, lens correction, color and tone. Re-encoding it as a 10-bit
HEIF does not recover sensor precision, highlight range, or texture discarded
by JPEG. It is a full-resolution camera rendering, not a developed sensor image.
The source contract must be visible wherever this route is used.

## Development and regression measurements

The existing fixed color scorecard compared the embedded JPEG to the separately
captured Sony HEIF. On 60 development pairs, every image met the broad color
gate (mean low-frequency CIEDE2000 ≤ 2 and p95 ≤ 5). Across images, mean
low-frequency error averaged 0.271 and reached 0.294; p95 averaged 0.425 and
reached 0.515. The six preselected difficult regressions also met the broad
gate. These results are diagnostic until the final encoder and acceptance run
are frozen.

For native geometry, the fixed tile matcher found sufficient correspondences
in 46 of the 60 development images; all 46 measured p95 displacement ≤ 0.5
pixel, with median 0.091 and maximum 0.470. The other 14 lacked enough reliable
features for a geometry verdict. All six difficult regressions had sufficient
coverage and passed, with maximum p95 0.156. Coverage cannot be represented as
a pass for the unmeasured cases.

The standalone harness renderer encoded all six difficult regressions as
10-bit HEIF at quality 0.95. The encoded outputs met the same broad color and
native geometry gates. Measured low-frequency color mean was 0.34–0.64,
p95 0.73–0.92;
native geometry p95 was 0.02–0.12 pixels with 9–15 reliable tiles. Nine
512-pixel native crops per image gave a high-pass energy ratio to the Sony target
of 0.971–1.077 (median 1.037). This is a numerical detail diagnostic; visual
artifact inspection and flat-region noise checks remain open.

On those six local RAWs, the command-line rendering step completed in 0.27–0.47
seconds per image, with maximum resident size 216–253 MB and outputs 15–24 MB.
These are process-level measurements on this machine, not an app-interaction
latency claim. The macOS HEIF encoder returned `nilError` in the restricted
command sandbox; the same executable succeeded on all six with ordinary encoder
service access. A stale private scorecard binary initially reported one portrait
dimension mismatch; rebuilding it from the checked source confirmed that the
portrait output and Sony target both decode at 4128 × 6192 and the pair meets
the color gate.

## Engineering result and limits

A narrow TIFF IFD reader, full-size decode, orientation normalization and HEIF
writer now share source with the research harness's inspection decode. The
service rejects unsupported models, missing full-size JPEGs, dataless originals,
and existing destinations. A synthetic full-size fixture proves orientation,
output dimensions, no overwrite and original preservation. The tool writes a
real HEIF from a verified local regression RAW, with the original unchanged.

The current output has an sRGB/BT.709 profile and 10-bit HEIF encoding, but its
source is eight-bit JPEG. Camera EXIF capture metadata has not yet been carried
into the output. Full acceptance, native visual review, and a final-tree
standalone verification remain before any release claim.
The plan's sensor-development objective also remains a separate contract unless
the product explicitly adopts the embedded camera-render route.
