# Card preparation: where the time goes (2026-10-31)

## Question

Preparing a camera card for import felt slow. Which step sets the pace: reading the card,
developing each still, or something else?

## Method

- **Instrumentation.** `ImageRenderer` reads each still's original whole in one timed read
  (`StillSource`) and develops from those bytes, so `render.still` reports `queueWaitMs`,
  `readMs`, `developMs`, `bytes` and `elapsedMs` (the time on the lane: read plus develop).
- **Card.** A Sony SD card, exFAT: 37 ARW + 37 HIF stills and 12 MP4 clips, 86 media
  files, 4.92 GB.
- **Cold run.** The installed Otos was quit, and the dev build was started with an empty
  catalog, so the card was its only source and nothing else was enriching. The card was
  unmounted and remounted first, so its file data was not in memory.
- **Safety.** The card's file list (size and modification time of all 1,397 files) was
  recorded before and after. It was identical except macOS's own
  `.fseventsd/fseventsd-uuid`, which the remount rewrote.

## Results

The renders ran strictly one at a time on the `background` lane: 74 renders in a 47.8 s
window, totalling 47.76 s.

| Still | Count | Read (median) | Develop (median) | On the lane (median) | Read share |
|---|---|---|---|---|---|
| ARW, RAW9 (~41 MB) | 37 | 160 ms | 987 ms | 1,149 ms | 14% |
| HIF, Image I/O (~9 MB) | 37 | 32 ms | 69 ms | 101 ms | 32% |
| All | 74 | 7.4 s total | 40.3 s total | 47.8 s total | 15% |

- **Card reads ran at 261 MB/s** (median, ARW and HIF alike).
- **Metadata waits on the renders.** Card metadata finished 49.9 s after launch. A row's
  metadata is written in the same `EnrichmentResult` as its rendered preview and thumbnail,
  so the serial develop sets that pace.
- **Checksums ran afterwards and in parallel.** The 86 checksums then took 20.4 s
  (50.2–70.6 s): 114.7 s of per-file hashing across the window. That is 4.92 GB in 20.4 s,
  about 241 MB/s, close to the card's read speed.

Earlier the same day, the installed app on a warm card logged ARW renders at a median of
1,540 ms, without the read/develop split. That run is not comparable: other enrichment was
running, and the read was not separated. The difference is not explained by this data.

## Conclusions

- **Developing RAWs is the bottleneck:** about 85% of the time on the render lane.
  Reading the card is about 15%, and checksumming runs at about the card's read speed.
- **Rendering in parallel would attack the measured cost,** since develop rather than the
  card's I/O dominates. This was not measured, and the lane is serial to bound RAW memory
  (160–340 MB per development).
