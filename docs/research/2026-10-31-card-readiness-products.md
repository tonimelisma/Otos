# What a card's import readiness waits on (2026-10-31)

**Question.** How much of a card's time to import-ready is the metadata the planner needs,
and how much the thumbnails and previews it does not?

**Setup.**
- **Card:** one Sony SD card holding 429 catalog rows (196 ARW, 196 HEIF, 37 MP4), in a
  USB reader.
- **Builds:** dev builds with an empty dev catalog for every run.
- **Readiness:** the time from launch until every card row's metadata stamp matches its
  file, which is the import planner's naming-settled fact. A scratch script polled the
  catalog every 0.5 s.
- **Logs:** every item logged `op=enrichment.item` with its metadata read and its product
  time measured apart (`MediaEnricher`).
- **Load:** the machine was loaded by unrelated builds, with load averages of 14–83.
- **Card unchanged:** after every run, by a size and mtime manifest of every file,
  excluding `.fseventsd`.

**Page cache.** Whether the card's bytes were still in the page cache from an earlier run
decided the time more than load did. The metadata read's median shows which state a run
was in: about 70–96 ms cold, 4–9 ms cached. A run that reads every HEIF whole evicts the
cache, so the next run is cold again. The cache was not controlled, so the comparison
holds within each state.

## Results

Readiness, with each run ordered by its own cache state:

| Variant | Cold card reads | Cached |
|---|---|---|
| First pass with products (`06da3f7`: HEIF rendered, RAW QuickLook) | 53.3 s, 58.3 s, 52.5 s | 23.2 s |
| Metadata only (measurement build, products skipped) | 15.4 s, 17.8 s | 3.9 s, 3.9 s |

Per item, from one cold run with products:

| Kind | n | Metadata read (median / p90) | Products (median / p90) |
|---|---|---|---|
| ARW (QuickLook thumbnail) | 196 | 53 / 192 ms | 6 / 12 ms |
| HEIF (Image I/O render, preview + thumbnail) | 196 | 54 / 184 ms | 1,126 / 2,271 ms |
| MP4 (QuickLook thumbnail) | 37 | 7 / 9 ms | 6 / 20 ms |

## What the numbers show

- **Rendering HEIFs dominated.** In the first pass, rendering the HEIFs was most of
  readiness. The metadata the planner needs was 15 s cold and 4 s cached.
- **Ordering matters as much as decoupling.** Each enrichment worker read an item's
  metadata and then rendered it before taking the next item. So the last metadata read
  finished at 50.3 s against 50.9 s for the last item. Publishing metadata early, with
  that ordering unchanged, would gain nothing; reading every row's metadata before any
  rendering is what gains.
- **Scanning comes first.** In the metadata-only runs, the scan finished at 2.4–6.9 s,
  and the metadata reads then ran for about 10 s cold.
- **The card's digest pass overlapped readiness.** It read 15–113 whole files at a median
  of 20–40 MB/s within the readiness window.

## Conclusion

A card's first pass reads metadata only, with a QuickLook thumbnail as a provisional,
unstamped thumbnail. Its renderings and digests come in a later pass of their own.
Import readiness waits on the metadata stamp alone (ADR 0009, ADR 0035, plan 0110).
