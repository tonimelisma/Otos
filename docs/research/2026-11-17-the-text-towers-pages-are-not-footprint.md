# The text tower's pages are not footprint (2026-11-17)

## Questions

1. On a brand-new library the first search waits on the text tower's prediction, which read
   about 330 MB back from disk when macOS had evicted the tower's pages
   (`op=search.tower phase=predicted ms=860 pageIns=21058 diskReadMB=332`,
   `2026-11-17-a-new-library-at-the-owners-size.md`). Is that memory part of the app's
   `phys_footprint`, so that keeping it resident would cost the footprint target?
2. What did the search field's focus do to a tower that was already prepared?

## 1. Where the tower's memory lives

A hosted probe (a test run once through `script/check.sh --only` and not committed) loaded
the real tower (`SearchTextTokenizer`, `SearchTextModel`, CPU only) on a 16 GB Mac running
macOS 27.0.1. It read `phys_footprint` and `vmmap --summary` of its own process at four
points:

| Point | Footprint | `mapped file` virtual | `mapped file` resident | `mapped file` dirty | Swapped | Process resident |
| --- | --- | --- | --- | --- | --- | --- |
| before the load | 41.8 MB | 34.6 MB | 1.5 MB | 0 | 0 | 146 MB |
| after the load | 61.3 MB | 563.7 MB | 14.4 MB | 0 | 0 | 180 MB |
| after the first prediction (50 ms) | 61.6 MB | 563.7 MB | 341.4 MB | 0 | 0 | 509 MB |
| after a second prediction (21 ms) | 61.6 MB | 563.7 MB | 341.5 MB | 0 | 0 | 509 MB |

Malloc stayed at 73.2 MB of zones (25.5 MB resident) from the load on; IOSurface was 80 KB.

- The load added about 20 MB of footprint: the model's description, its buffers and the
  tokenizer's tables. The predictions added none.
- The first prediction touched about 327 MB of mapped file: the compiled model's weights and
  the four token tables, mapped by Core ML and by `Data(contentsOf:options: .alwaysMapped)`.
  Those pages are clean and file-backed: 0 KB dirty, nothing swapped. The process's resident
  size counts them; its footprint does not.
- That probe's first prediction took 50 ms with 23 page-ins: the files were in the buffer
  cache already. The 0.86–1.18 s on the tours is the same 330 MB read from disk because the
  system had evicted both the mapping and the cache.

**Answer.** The ~330 MB is not in the footprint. Keeping it resident would not cost the 700
MB target. But the only way for an app to keep clean pages resident against the system's
eviction is to wire them (`mlock`). Wiring 330 MB on a 16 GB Mac, under exactly the memory
pressure that evicts them, takes that memory from every other process. That is rejected.
Residency stays the system's decision.

## 2. What the focus did before

The search field's focus calls `CatalogWindowViewModel.searchFieldFocused`, which asks the
index to prepare (`PhotoSearchIndex.prepareForSearch`). The index's loop asked the reader to
prepare (`SearchQueryReader.prepare`) and the vectors to be read ahead (`MADV_WILLNEED`). The
reader's loop asked the tower whether it was prepared and, when it was, marked the intent
covered. It touched no model page. The 158 ms in `search.prepare phase=done admitted=false
ms=158` on the owner's log is the index's step: the hop to the reader and the vectors'
advice. The log does not split the two.

## Conclusion

The focus is a fact that arrives before the query. It now asks a prepared tower for one
warm prediction (`SearchTextTower.warm`, ADR 0048 "The intent to search warms a prepared
tower"). The page-in then happens while the person types:
`op=search.tower phase=warmed cause=focus ms= pageIns= diskReadMB=`.

What stays true is that a query submitted in the same instant as the focus still pays the
page-in inside its first search. The tour types its query that way. `script/scorecard.sh
--search-after-warm` types it once the app reports the warm prediction ended, and labels those
numbers `after warm`, beside the immediate ones.

## Sandbox tours after the change

Two tours of a seeded sandbox library (`script/scorecard.sh --tour --dev --optimized --seed
2000 --idle 20`, the second with `--search-after-warm`), on the same Mac with 65 MB free at
its lowest and 6.6 GB of swap in use. The generated photos show no sky, so both first
searches matched nothing (`items=0`) and were answered by the tower's reading.

| Tour | Focus to query | First search, first results | The focus's warm prediction | Peak footprint |
| --- | --- | --- | --- | --- |
| immediate | 0 ms | 275 ms | `ms=14 pageIns=0 diskReadMB=0` | 604 MB |
| after warm | 35 ms | 204 ms | `ms=15 pageIns=0 diskReadMB=0` | 631 MB |

- In both, the tower's pages were resident when the field took focus (no page-in), so these
  tours show the mechanism and its cost, about 15 ms of prediction, not the evicted case.
- The app's own `search.encoder phase=loaded footprintDeltaMB=` read 173 and 276 MB in these
  tours, against 20 MB in the probe. It is the whole process's footprint across the load,
  while the launch's owners were running beside it, so it does not measure the tower.

Eviction was not produced on this Mac: doing so safely needs a memory hog beside other
sessions' builds. The scripted tests in `OtosTests/SearchQueryReaderTests.swift` carry the
evicted case: a warm prediction held at its gate stands for one that is reading pages back.

## Sources

- The probe's output (`logs/probe-tower-footprint.txt` in the worktree, not committed):
  `vmmap --summary <pid>` and `ProcessResourceSample.current()` at the four points.
- `Otos/Services/SearchQueryEncoder.swift` (`SearchTextTower`),
  `Otos/Services/SearchQueryReader.swift`, `Otos/Services/PhotoSearchIndex.swift`.
