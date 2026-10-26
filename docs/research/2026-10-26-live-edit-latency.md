# Live edit latency: why a slider drag took seconds (2026-10-26)

## Question

Moving an edit slider on a RAW showed the change seconds late, with a progress indicator
that came and went. What does the time go to, and what is the right design?

## Method

- `render.liveEdit` and a new `edit.liveRender` log (queue wait and render time per live
  render), read with `log show`, on the dev build editing a Sony ARW (6192 × 4128) in the
  loupe while enrichment ran.
- Stand-alone Core Image probes on the same file: `CIRAWFilter` with a caching
  `CIContext`, rendering 2560 px Display P3 bitmaps as `LiveEditRenderer` does.

## Findings

1. **RAW9's `nativeSize` is not stable.** It reads 6192 × 4128 when the filter is made and
   after `decoderVersion` is set; once `scaleFactor` is set it reads 3302 × 1844 (not even
   the sensor's aspect), and 3096 × 2064 after a render. RAW8 was not checked for this.
   Otos read it after setting the scale — when opening the photo and on every render — so:
   - the scale factor was computed from the wrong size, and live renders came out at
     2560, 4801 or 5120 px (up to four times the pixels asked for);
   - the scale changed between renders, and a change of scale is a fresh development:
     21–27 ms at a stable scale, **3419 ms** jumping from 0.413 to 0.775;
   - the opened photo reported 3302 × 1844, so the loupe's fit magnification was 0.577
     instead of 0.39 and every save started a **2.5 s full-resolution decode**;
   - a save stored a 5120 px preview where 2560 was meant.
2. **Core Image itself is fast enough.** After the first development (0.6 s RAW8, 1.9 s
   RAW9), a temperature or exposure change renders a 2560 px bitmap in 4–9 ms (RAW8) or
   20–35 ms (RAW9).
3. **Background enrichment does not slow it.** Live renders beside a loop of background
   RAW9 developments (about 1 s each): median 28 ms in another process, 31 ms (max 51)
   in the same process, against 28 ms idle. Pausing enrichment while editing is not needed.
4. **A save queued its HEIC encode on the renderer.** Encoding and writing the preview
   (70–215 ms) ran on `LiveEditRenderer`'s queue, ahead of the next live render.
5. **The indicator was a reload, not a wait.** After each save the stored preview is
   reloaded for a pane that already shows the photo, and that request raised the pane's
   progress indicator.

## Changes

- `ImageRenderer.openRAW` returns `OpenedRAW`, whose oriented native size is read once
  when the filter is made; the scale factor and every reported size come from it.
- A save's products are encoded off the renderer (`RenderedEditImages.staging`).
- A request that refreshes the photo a pane already shows raises no indicator (DES-086).

## Result (same file, same drags)

| | Before | After |
| --- | --- | --- |
| Opened size | 3302 × 1844 | 6192 × 4128 |
| Live render | 149–2652 ms, at 2560/4801/5120 px | 21–38 ms, always 2560 px |
| Request to image | up to 3.5 s | 39–104 ms |
| Full-resolution decode after a save | 2.5 s, every save | none |

The first render after opening a RAW stays about 0.9–1.9 s: RAW9's first development.

## Sources

- Apple, `CIRAWFilter.scaleFactor`: values below 1 shrink the output and "can greatly
  improve the drawing performance" — https://developer.apple.com/documentation/coreimage/cirawfilter/scalefactor
- Apple Developer Forums, scale factor matched to the view to bound memory with large RAWs —
  https://developer.apple.com/forums/thread/851397
- WWDC20 10008, Optimize the Core Image pipeline for your video app (render destinations) —
  https://developer.apple.com/videos/play/wwdc2020/10008/
