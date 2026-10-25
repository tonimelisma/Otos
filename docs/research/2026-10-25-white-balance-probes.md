# White balance probes (2026-10-25)

What the Color section (plan 0108, increment 6) rests on. The measurements came from
three throwaway Swift probes, compiled with `swiftc -O` on macOS 27.0 / Xcode 27.1, run
against a Sony ARW from the library opened read-only, and against synthetic gray images.

## `CIRAWFilter` white balance

- As shot, the probe RAW reports `neutralTemperature` 3836 K and `neutralTint` 6.2. Its
  orientation is 8 (rotated), native size 6192×4128, and output extent 4128×6192.
- **Directions match Lightroom.** +2000 K moves the mean from r/g/b 0.482/0.440/0.398 to
  0.601/0.461/0.280 (warmer). +50 tint moves it to 0.505/0.394/0.513 (magenta). Setting
  the as-shot values back restores the mean exactly.
- **Setting temperature alone keeps the as-shot tint**, and the reverse holds too.
- **`neutralLocation` takes a point in the output image**: oriented, after `scaleFactor`,
  with a bottom-left origin.
  - A point given in native (unrotated) coordinates that falls outside the rotated
    extent leaves white balance as shot.
  - At `scaleFactor` 0.25, only output-space bottom-left points neutralized the
    measured spot: chroma 0.118 and 0.062, against 0.27–1.02 for the native and
    top-left alternatives.
- After `neutralLocation` is set, the filter reports the temperature and tint it
  chose, so a pick can be stored as ordinary slider values.
- The header gives the ranges as 2000–50000 K and −150…150 tint
  (`CIRAWFilter.h`, the white balance block).

## `CITemperatureAndTint` on a still

Mid-gray (0.5) in, sRGB out, with the target neutral fixed at (6500, 0):

| Source neutral | r | g | b |
| --- | --- | --- | --- |
| 2500 K | 0.063 | 0.516 | 1.022 |
| 4000 K | 0.410 | 0.508 | 0.663 |
| 5000 K | 0.461 | 0.503 | 0.573 |
| 6500 K | 0.500 | 0.500 | 0.500 |
| 8000 K | 0.521 | 0.499 | 0.460 |
| 10000 K | 0.538 | 0.498 | 0.428 |
| 15000 K | 0.556 | 0.498 | 0.390 |
| tint −100 | 0.375 | 0.551 | 0.426 |
| tint +100 | 0.587 | 0.454 | 0.599 |

A source neutral above the target warms the output, and a positive source tint makes it
magenta: the same directions as the RAW pipeline. The relative ±100 slider therefore
moves the source neutral by one mired per step: +100 is 1,000,000 / (153.8 − 100) ≈
18,600 K, and −100 is ≈ 3,900 K. Tint moves one unit per step.

## Conclusions

- A RAW stores absolute kelvin and tint. Nil means as shot, which only the open filter
  can report, so the panel opens the photo before its controls act.
- A RAW's temperature slider moves evenly in mireds between 2000 and 50000 K, so the
  common 3000–8000 K span takes most of its width instead of a fifth of it.
- A RAW pick uses `neutralLocation` with the point mapped to the output extent's
  bottom-left coordinates. A still's pick solves numerically for the two relative
  values that render the sampled color gray, because `CITemperatureAndTint` has no
  location input.
