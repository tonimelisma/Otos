# The first search's words answer that never came (2026-11-16)

## Question

The words reading (`2026-11-16-first-search-while-the-encoder-loads.md`) was meant to put a
first answer on screen while the text tower loads. The owner's next tour on final `main`
3e8fa6d2 (installed app, read-only, the Mac with 67 MB free and 6.1 GB in swap) measured
`search first searchMany first results 2269 ms` and `complete 2269 ms`: no early answer. Why,
and what keeps a first search typed seconds after launch under 1 s?

## Evidence: the session (local times, the app's unified log)

| Time | Line |
| --- | --- |
| 29.871 | `search.index loaded from=file` (vector file mapped) |
| 32.665 | `load.admission granted load=searchPrepare` (the first grid's readying) |
| 34.277 | the tour types `sky` (`Catalog query changed … search=3chars`) |
| 34.305–34.404 | the projection's first pass asks the reader: `searchReading` |
| 34.886 | `search.encoder phase=prepared` (the load took 2,190 ms) |
| 34.915 | `search.encode depth=words ms=510`; the projection's next pass starts |
| 34.953 | `search.match picture=unread matched=0 textMatches=0 ms=7 scopeReused=false` |
| 34.953 | `search.encode depth=full` (the tower's reading, 2 ms) |
| 36.086 | that pass ends `searchReading`; the next starts |
| 36.507 | `search.match picture=embedded matched=433 textMatches=11 ms=392 scopeReused=false` |
| 36.546 | `tour step searchMany firstMs=2269 resultMs=2269` |

The store's hold counters (`op=catalog.store.use`, `name:totalMs:count:maxMs`) between the
samples at 34.277 and 36.547: `searchEmbeddingPendingCount:1132:1:1132` (new),
`searchTextRows` 28 → 37 pages, `searchTextCandidates:448:1` (new).

### A. Why the words reading matched nothing

Both readings compare the same typed text (`sky`) with the same text readings in memory
(`PhotoSearchIndex.matches`, `memory.texts`); the words reading skips only the picture's
cosine and the scene labels it names (`labels=2`, a rank lift). Memory had no text readings
at 34.953: the index's first pass read them in (`reconcileTexts`, 37 pages of 2,000) only after
it had reconciled the embeddings (`currentSearchEmbeddingIDs`, one 1,398 ms read) and walked
the embedding backlog. At 34.277 it had read 28 of the 37 pages; it takes them into memory
after the last one. The revision moved between the two matches (`scopeReused=false` on the
second, nothing else wrote memory), and the text drain, which comes after that load, started at
35.583 (`search.text phase=sessionStarted`). The exact moment the texts landed is not logged;
`search.texts phase=loaded` logs it now.

### B. The 1,554 ms between the tower's reading and the picture's match

The pass that matched the words reading (34.915) did not end until 36.086. After its 7 ms
match it read `searchEmbeddingPendingCount` (`applySearch`, for an empty result's
`stillReadingCount`) — the one such read of the interval, 1,132 ms on the window lane — and
then threw the result away, because a refining reading that matches nothing publishes
nothing. The picture's pass then waited for it, and its match took 392 ms (the first full pass
over the mapped vectors under that memory pressure; the next query's took 71 ms).

`search.prepare` ran twice by design: the search field's focus (617 ms, `scopeReused=false`)
and the first grid's readying (2,241 ms, spanning the encoder's load it awaited, so not inside
the query). Neither prepared the query's scope: both read the grid's 159,130 slots, and every
match is among the projection's 164,979 (stacks' members included). The match's own slot
read, cold for that scope, took under 7 ms. Nothing in the query's path awaits the text
reader's helper process: the session that started at 35.583 is the background text drain's.

The projection's pass that ends with the query being read did not cover its request, so while
a query was read the projection re-ran on its cadence: in a test, a refining reading that
matched nothing was matched again every cadence tick.

### C. The words reading's 510 ms

It started at 34.405 (the encode's own clock), 128 ms after the query: the projection's first
pass, then the reader. The same steps took 36 ms in the next reading, 36 ms later. In a fresh
test process on the same Mac the cold costs were small: the language recogniser 4 ms, English
spelling on the main actor 20 ms, the place tagger 18 ms, a fresh encoder's whole words reading
17–25 ms. So the 474 ms is not those models' cold load alone; it is page-ins under that memory
pressure (15,924 page-ins and 422 MB read from disk during the step) or a wait for the main
actor (the spelling check), and the log cannot separate them. `search.encode` now carries
`spellMs` and `parseMs`.

## Decision (ADR 0048, "The words first" and "The first query")

- **Memory loads in the order the answers need it.** A whole pass opens the vector file (no
  table read), then reads the text readings in, then reconciles the embeddings or builds the
  file, and only then reads either backlog.
- **A words reading that matches nothing reads nothing more.** Only a read answer that is
  empty reads the owed count.
- **A pass that ends with the query being read covers its request**: the reader rings when
  the status changes.
- **The preparation reads no scope**: it loads the encoder and advises the vectors.

On this session's numbers the first answer would have been the 11 photos whose text holds
"sky": the words reading ended at 34.915 and its match took 7 ms, so about 0.7 s after the
query, the 510 ms reading being most of it; the picture's 433 followed the 392 ms match,
about 1.1 s after the query. When the words reading runs as it does in a quiet process
(about 30 ms) the first answer is the projection's two passes and the match, about 0.2 s.

## Not measured here

- A tour on the owner's library after the change: the next tour.
- Which of page-ins or the main actor made the 510 ms (C): the next tour's `spellMs` and
  `parseMs` say.
