# The text read in photos, matched by an index in the catalog (2026-11-16)

## Question

#887 made the first search's words answer correct by reading every text reading into memory
before the index's first pass reconciled its embeddings (`search.texts phase=loaded`). On the
reference library's tour of 1a54ff7d that load took 4,548 ms, the words answer waited for it, and the
footprint rose from 241 to 645 MB over the same seconds (412 MB before #887). How much of the
rise is the text load, and what does a blank-slate design hold instead?

## Attribution: the launch pass, step by step

A hosted probe on a generated catalog of the reference shape (`ReferenceShapedCatalog` at scale 1:
164,699 embeddings, 75,795 text readings of which 12,633 hold text, 2.7 MB of folded text; the
reference catalog, read-only: 75,823 readings, 13,545 with text, 6.47 MB of stored JSON, 10.9 lines
and 478 bytes a reading) ran the reads of the index's launch pass in its order, on 1a54ff7d,
in a quiet test process, sampling the kernel's footprint and malloc's live bytes after each:

| Step | Footprint | Live heap | ms |
| --- | --- | --- | --- |
| start (store open, vector file built) | 85 MB | 14 MB | |
| vector file opened (`SearchVectorFile.open`) | 85 MB | 18 MB | 210 |
| `currentSearchTextIDs` | 85 MB | 19 MB | 384 |
| every reading read and folded (`searchTextRows`, 38 pages) | 89 MB | 23 MB | 522 |
| `currentSearchEmbeddingIDs` | 89 MB | 24 MB | 383 |
| all released | 89 MB | 18 MB | |

So the text load costs about 4 MB of footprint and 0.9 s of reads in a quiet process. It is
not the several hundred MB the tour saw: that rise is elsewhere in the launch (the tour ran
while another project's build loaded the Mac, which also inflated the load's 4.5 s), and its
attribution belongs to the whole-launch memory work, not to search. What the load does cost is
time on the first query's path: the words answer could not come before the readings were in.

## Decision

The text of every reading is matched by an index in the catalog (ADR 0048, "Text in the
photo"; schema v74), and the index's memory holds no text:

- `search_text_folded`: one row per reading that holds a word, its key, and the reading folded
  as matching compares it. Its `id` is an explicit `INTEGER PRIMARY KEY`, because the launch's
  `VACUUM` may renumber the rowid of a table without one (`search_text`'s).
- `search_text_word`: a contentless FTS5 table keyed by that `id`, holding the reading's words
  (`SearchTextWords`), `tokenize = 'ascii'`, `detail = none`. A trigger deletes a row's words
  when its folded row goes; the folded row goes with its reading by cascade, and the reading
  with its asset.
- The Store writes both in the transaction that stores the reading (`applySearchTexts`,
  `SearchTextStorage.index`), and v74 writes them from the stored readings.
- A query's words are one read on the window lane (`CatalogStore.searchTextMatches`): the
  index's prefix match, then each returned row's reading and asset by key, keeping a reading
  only while its source is its asset's current one. Each row is decided by the existing match
  (`SearchTextQuery.matches(folded:)`), so the answer is exactly the old one.
- A search held by the projection is asked again when the text match's inputs move
  (`CatalogChangedFacts.searchTextInputs`: membership, images, search content), as a query's
  facts already were.

Removed: the index's text memory (`SearchIndexMemory.texts`), its whole and keyed reconciles
(`reconcileTexts`), the readings' currency read (`currentSearchTextIDs`), their paged load
(`searchTextRows`) and keyed read (`currentSearchTexts`), and the `search.texts` log line.

## Why not SQLite's own tokenizers

Matching is: every query word of two or more characters, at the start of a word of the text
(after any character that is not a letter), or anywhere for a word of a script written without
spaces (Chinese, Japanese); case, diacritics and width folded by Foundation. Measured with the
`sqlite3` of macOS 27 (3.54) on text Otos had already folded:

- `unicode61 remove_diacritics 2` with prefix queries misses a word after a number (`1abc`
  holds one token, so "abc" finds nothing; matching finds it) and a Chinese or Japanese word
  inside a run (`東京タワー` is one token; "京タ" finds nothing).
- `trigram` cannot ask for a word under three characters: `MATCH` returns nothing for `東京`
  or `ok`, and `LIKE '%ok%'` scans the table. Two-character words are common in Chinese,
  Japanese and Korean.

Neither can be the answer; as a candidate filter, unicode61 would lose matches. So Otos writes
the words itself (`SearchTextWords`): in each run of letters and numbers, the run from every
place a word can start (its first character and each one after a number; every place, in a run
holding a character of a script written without spaces), cut to 8 characters, in canonical
composed form. The `ascii` tokenizer splits only at ASCII characters that are neither letters
nor numbers, which no such word holds, so FTS5 keeps each as written; a query asks for each word's
first 8 characters as a prefix. The index returns a superset of the matches, and the exact match
decides each.

`SearchTextIndexTests.theIndexMatchesExactlyWhatEveryReadingMatches` is the differential: 30
readings in eleven scripts and many shapes (ß, full-width forms, decomposed accents, numbers beside
letters, Chinese, Japanese, Korean, Thai, Devanagari, emoji, a 42-letter word), every run of
2, 3, 5 and 9 characters at every position as written and as folded, and pairs of words: the
index answers each exactly as matching every reading does.

## Measured on the generated reference-shaped catalog

All three are on-demand runs at scale 1 (`OTOS_SCALE_TEST=1`), each alone, while other
agents' checks loaded the Mac:

- **v74's cost** (`CatalogMigrationCostTests`, through the Store's own migration pass on the
  2.27 GB file): 2,809 ms, of which 2,785 ms is writing 12,633 readings' rows; 6,678,552 WAL
  bytes; the file grew by 8 KB, since the rows took free pages. The index takes 6.6 MB: the
  folded readings 3.6 MB and their key 0.8 MB, the FTS5 table's data 1.9 MB and its document
  sizes 0.16 MB.
- **The launch pass** (`SearchIndexLoadMemoryTests`, the vector file mapped, the embeddings
  reconciled, the backlogs asked; no reading session): 6,681 ms, footprint 94 → 132 MB, and it
  visited no row of `search_text`, `search_text_folded` or `search_text_word`.
- **A query's words** (`searchTextMatches`, the window lane, `StatementVisits`): every
  candidate costs four keyed visits (its words, its folded row by integer key, its reading's
  source, its asset) and nothing else, 4.0 rows visited per row returned. The generated
  readings repeat a small vocabulary, so these words are far broader than a real query: `open`
  matched every reading with text, 12,633, in 550 ms cold; `ca` 11,410 in 67 ms; `営業` 4,209 in
  24 ms. On the reference library the tour's `sky` matched 12.
- `EXPLAIN QUERY PLAN` (`aMatchReadsTheIndexFirstAndEachRowByItsKey`): the FTS5 table first,
  then `search_text_folded` by its integer key, `search_text` by `idx_search_text_source`, and
  `media_asset` by its key. No table is scanned.

## Other per-asset search facts in memory

None has this shape now. The vectors are a mapped file, and the scene labels ride in its keys
(confidences, read by slot). Named people are read from the catalog for each query
(`namedPeople`, a few rows). Places are looked up through Maps and cached by name. Descriptions
(ADR 0053) are not searched at all, and searching them would change what a query finds, which
is a product decision this change does not make.

## Not measured here

- The reference library's tour after the change (first search and launch footprint): the next tour.
- Bench cases that may move (the reference-shaped catalog's readings now take the reference widths): not
  measured until the next daily run.
