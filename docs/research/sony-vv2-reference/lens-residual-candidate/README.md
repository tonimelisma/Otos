# Experimental 18 mm residual lens correction

Apple RAW lens correction was enabled. It still differed systematically from
Sony at the edges of the three user-selected images. This package preserves a
small **additional** geometry correction, measured on 2048 × 1366 previews.
It is not a replacement for Apple's lens correction or a general lens database.

The three RAWs report ILCE-6700, 18 mm, and lens model string
`Sony E 18-50mm F2.8`. That string is recorded as reported; it is not independent
verification of the lens manufacturer. All three contain Sony distortion flag
0x7036 = 1 and signed distortion parameters in TIFF tag 0x7037. The table has
17 values, starting with 11; subsequent values differ slightly between files.
The embedded table's exact evaluation and its relationship to Apple's profile
were not established. This calibration does **not** consume that table.

## Mapping and fitting

Let x,y be source pixel coordinates, bottom-left origin, width W and height H.
Define nx=(x-W/2)/(W/2), ny=(y-H/2)/(W/2), r=nx²+ny² and s=W/2048.
For the six saved coefficients c:

```text
dx = s * (c0 + c2*nx + c4*nx*r + c5*nx*r²)
dy = s * (c1 + c3*ny + c4*ny*r + c5*ny*r²)
source(x,y) moves to target(x+dx,y+dy)
```

The independent linear x/y terms allow a small scale/aspect residual. Shared
radial terms describe the nonlinear edge displacement. Fit ordinary least
squares to the 63 vectors for photo 2 in `calibration-grid.json`, using rows
`[1,0,nx,0,nx*r,nx*r²]` for dx and
`[0,1,0,ny,ny*r,ny*r²]` for dy. A pivoted six-variable solve reproduces the
coefficients. Photos 3 and 6 are held out completely from this fit.

To render, for each destination x,y start u=x,v=y. Repeat five times:
`(u,v)=(x,y)-displacement(u,v)`. Clamp u,v to source bounds and bilinearly sample
all channels. Keep the output dimensions. Apply once after pointwise color
processing and before final output conversion. The same coordinate mapping can
be implemented in a Metal kernel or a Core Image warp kernel; the provided Swift
reference specifies its math without depending on any third-party package.

Width scaling is defined in the reference and tested synthetically; its native
resolution photographic quality is **not** validated by this preview experiment.
Portrait orientation, different crops, focal lengths, focus distances and other
lenses need new evidence. Do not silently apply this profile to arbitrary RAWs.

## Measurement

Apple Vision `VNGenerateOpticalFlowRequest` at `.veryHigh` estimates source-to-
target flow between the original local A/B gallery's unregistered renderings.
Use a 9 × 7 grid spanning 4–96% of each dimension. Each vector is the component
median of a 25 × 25 patch sampled every three pixels. Reject non-finite vectors
and components with magnitude 40 pixels or more. The saved grid is the exact numeric fit input.

Flow coordinates/signs were checked against direct high-pass image comparison,
not assumed from memory. Luminance is 0.2126R+0.7152G+0.0722B in the existing
encoded preview values. Subtract a Core Image Gaussian blur of radius 2. Evaluate
every eighth pixel inside a 32-pixel border. Edge samples are outside the central
60% rectangle. This is a repeatable alignment diagnostic, not a perceptual score.
Color, sharpening, noise and resampling also affect it.

| Photo | Role | Flow RMS before → after, pixels | Edge high-pass SSE before → after |
|---|---|---|---|
| 2 | Fitting | 0.8484 → 0.1571 | 14.1773 → 9.9631 |
| 3 | Held out | 0.8968 → 0.1058 | 338.2149 → 244.1915 |
| 6 | Held out | 0.9002 → 0.1024 | 261.4401 → 192.5672 |

Optical flow across differently developed images is an estimate, not physical
geometric ground truth. The direct rendered-image improvement corroborates it.
The local viewer exposes all four corners and retains the previous rendering.
Its images are not registered against their own Sony target before display.

## Media-free implementation

Keep `model.json`, `LensResidual.swift.md`, `Verify.swift.md`,
`test-vectors.json`, `calibration-grid.json`, and `validation.json` together.
The grid contains only image-space coordinates and displacement vectors, with
anonymous gallery numbers; it contains no RGB samples, pictures or private paths.
The 21 coordinate fixtures are wholly synthetic. Extract the two Swift blocks,
name the verifier `main.swift`, then compile and run:

```sh
xcrun swiftc -O LensResidual.swift main.swift -o verify-lens
./verify-lens model.json test-vectors.json
```

The saved result can be implemented after media removal. Broader lens calibration
still needs paired images. No media was deleted or added to Git.
