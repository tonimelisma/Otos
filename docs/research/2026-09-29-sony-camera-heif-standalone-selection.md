# Standalone camera-render HEIF selection check

September 29, 2026. Plan 0105 development evidence, not untouched acceptance.
The comparator and evaluator live entirely in `tools/sony-render-harness/`;
no Otos app path is changed. The `embedded-jpeg-evaluate` command calls the
same HEIF writer as `embedded-jpeg-heif`, then decodes the published HEIF for the fixed color
scorecard, native geometry, and private full-frame/corner inspection assets.
Inputs were checked for `SF_DATALESS` immediately before byte reads, and output
was written under a private temporary directory. The 72 untouched acceptance
pairs were not read.

The version-1 input contract is an ILCE-6700 ARW carrying a native 6192 × 4128
eight-bit camera JPEG in its third TIFF IFD. Output is a ten-bit SDR HEIF
encoding of those camera pixels. This is an upper-bound camera-render
comparator, not the requested sensor RAW development; it cannot restore
precision lost in the JPEG.

## Exact-output results

The six previously selected difficult regressions all encoded and met the
broad color gate. Mean low-frequency CIEDE2000 ranged 0.339–0.635 and p95
0.726–0.915. On the 18-pair selection set, all 18 encoded and met the broad
color gate; mean ranged 0.303–0.558 and p95 0.543–0.911. The output score is
computed on the encoded HEIF, including orientation and quantization, not on
the embedded JPEG before conversion.

The original native geometry matcher used 15 fixed tiles and needed eight
reliable matches. It could report a p95 for six of six regressions and 11 of
18 selection images. Before any acceptance run, the matcher was strengthened
to a 7 × 5 grid of 35 tiles, requiring at least 18 reliable locations and six
near the outer frame. With that protocol, six of six regressions had enough
coverage and passed the 0.5-pixel p95 gate (maximum 0.102). Twelve of 18
selection images had enough coverage and passed (maximum 0.294). Six selection
images remain geometrically unmeasured under this gate, mainly because
shallow-focus or flat areas yield ambiguous local correspondence. They are
not counted as geometry passes. Numerical pass counts must not conceal the
missing coverage; either a stronger feature oracle or a versioned acceptance
interpretation is needed before a broad geometry claim.

The comparator was exercised on the real verified captures, including the
encoded file's orientation, size and bit depth. The portable CIEDE2000 and
geometry fixtures pass. Its synthetic full-size encoder fixture could not run
under the restricted graphics environment and was removed from the build gate;
the separate sensor renderer has safety fixtures for output placement,
no-overwrite and original preservation. Real-photo full-resolution detail/noise
review, cancellation behavior, camera metadata retention, and untouched
acceptance remain open for the sensor renderer.
