# ADR 0048: Keyword search with SigLIP 2 and on-device translation

## Status

Accepted, 2026-11-10. Measured on the owner's library with the shipped code
(`docs/research/2026-11-09-keyword-search.md` §7–8): the app as built finds 82% of the
findable relevant photos in its top 10 for English queries and 74.4% across 16 other
languages, every result judged.

## Context

The owner wants to find photos by typing what is in them, in many languages, not only
Finnish and English (owner, 2026-11-09). Their library holds no keywords or captions, so
search has to read the pictures themselves. No Apple API returns a picture's embedding,
and Vision's classifier knows 1,303 English labels. The owner set two bounds: a model of
about 500 MB at most, and the eval is what works on their own photos.

**Measured on 19,221 of the owner's photos:** 52 queries in 17 languages, every model's
top 10 judged. SigLIP 2 B/16-256 with Apple Translation led nine candidates. In English it
put 85% of the findable relevant photos in its top 10. The best untranslated multilingual
model reached 68%, and a multilingual text encoder distilled into CLIP's space reached 44%.

## Decision

### The model: SigLIP 2 B/16-256, int8, CPU

- **Image tower:** `SigLIP2Image.mlpackage`, 8-bit linear per-channel weights, 94 MB.
  The positional embedding stays at full precision: it is one (1, 256, 768) tensor, so
  "per channel" gives it a single scale, and quantized it alone moved embeddings to cosine
  0.91 against full precision. Kept, the tower matches at 0.9994.
- **Text tower:** `SigLIP2Text.mlpackage`, 8-bit weights, 87 MB, from the token embeddings
  on. The 256,000 × 768 token table is 197M of the tower's 282M weights. It ships as four
  int8 files of 64,000 rows with per-row scales, so no file reaches GitHub's 100 MB limit.
  They are memory-mapped, and a query reads only its own rows.
- **Tokenizer:** Gemma's BPE, in Swift (`SearchTextTokenizer`). It matches open_clip's ids
  on 2,682 strings in 17 languages.
- **The resize:** `SearchImageResampler` reproduces the PIL bicubic resize the model was
  trained with (raw values, no profile conversion). Core Graphics' own interpolation moved
  embeddings to a median cosine of 0.973 against the reference; this one gives 0.997.
- **CPU only**, as ADR 0045 runs every Otos model. Measured in the dev build: 12 photos a
  second while enrichment ran, about 40 ms to embed a query.
- **Download:** 380 MB in all.

### Queries: recognise, translate to English, embed

`SearchQueryEncoder`:

1. **Recognise the language.** `NLLanguageRecognizer` is constrained to English plus the
   languages Apple Translation offers, read once. A query never states its language.
   Constrained recognition scored 75.0 against 77.1 when the true language was given;
   unconstrained scored 74.4.
2. **Translate to English** on the device (`TranslationSession(installedSource:target:)`: no
   network, no UI) when that language's pack is installed — asked for that language alone and
   remembered once installed (16 ms, against 0.67 s for asking about every language). This is
   the one large lever: translated queries scored 77 across 16 languages, the same queries as
   typed 65. A non-English query takes about 0.35 s, mostly the translation.
3. **Fall back to the text as typed** for a language with no installed pack, or none
   recognised. SigLIP 2's own multilingual tower reads it (Estonian: 50).

Rejected:
- **A cross-lingual embedding instead of translation.** It scored 44–68, against 78.
- **A word-by-word translation model.** A sentence translator already handles a single word.
- **Fusing the native and translated embeddings.** It scored 74.0, below translation alone.
- **Confidence gates** for when to fall back to the text as typed. They moved the mean by
  under half a point, which the judging cannot resolve.

### What is embedded: the stored thumbnail

Each asset's 256 px stored thumbnail is embedded, not its original. That means:
- Search never downloads an original.
- It covers videos (their frame), cards, cameras and Immich accounts as soon as their
  thumbnails exist.
- It costs one 256 px decode per asset.

Fully judged, the thumbnail scores the same as the 2,560 px preview where one exists (77.1
against 77.3, 85 in English for both), and every asset has one.

### Storage, staleness and lifecycle

- **Storage:** an embedding is overlay in `search_embedding`, one row per asset. Moves and
  proven deletions reach it by cascade (ADR 0008).
- **Staleness:** the row names the thumbnail it was read from and the model revision
  (`SearchEmbeddingStorage.currentSource`, built on `StoredThumbnailSQL.identity`, which
  render signatures also use). A new thumbnail or a new revision makes it stale, and no
  thumbnail writer knows search exists (ADR 0009).
- **Undecodable thumbnails:** recorded with no vector, so they are not retried until the
  thumbnail changes.

### The index: one owner, in memory

`PhotoSearchIndex` (an actor):
- **Embedding loop:** woken by the Store's change notifications, it reconciles memory with
  the catalog's current embeddings, then embeds what is owed, newest capture first, 16 at a
  time, on `SearchImageEmbedder`'s queue.
- **Memory:** every current embedding as one matrix. A query is one matrix–vector product
  (about 3 ms over 19,000 photos), with no SQLite read.
- **Answers:** `CatalogProjection` asks it when the descriptor carries a search, and narrows
  the scope to the matches. The index's `changes` stream asks for a new publication while a
  search is shown.

### Where results stop: a cutoff relative to the best match

A photo matches when its cosine is at least the best photo's minus 0.04, and at least 0.08
(`SearchCutoff.calibrated`). Scores depend on the query: a short word scores lower than a
precise phrase, so a single cosine either cuts good queries short or floods weak ones.
Measured on the judged queries in 16 languages:

| Cutoff | Judged relevant kept | Median shown | 90th percentile shown |
| --- | --- | --- | --- |
| best − 0.04, floor 0.08 | 83% | 123 | 418 |
| cosine ≥ 0.09 | 84% | 140 | 854 |

About 65% of what the cut shows is relevant, measured on judged photos including a random
sample from inside it. A query for something the library hardly holds (soccer, a bath) still
shows photos, nearly all wrong: their best scores overlap those of queries with hundreds of
right answers, so no cut can tell them apart. Relevance order puts the best first.

### The surface

`docs/design/search.md`:
- **Field:** the system search field at the toolbar's trailing end, focused by Edit ▸ Find
  (⌘F). It narrows whatever scope is shown, together with the filter.
- **Order:** Relevance, Lightroom's default for search results, is offered in the Sort menu
  only while a search is shown. Any other sort shows the matches in that order.
- **Empty:** the empty state says `No Results for “…”` and how many items search has not
  read yet.
- **Not persisted:** a search is not restored on relaunch.

## Consequences

- **App size:** about 380 MB more.
- **First indexing:** about 20 minutes for 15,000 items in the dev build, newest first. Like
  enrichment, it is App Napped when Otos is hidden and the owner is away, and resumes when the
  window is seen.
- **Unread items:** until indexing finishes, a search shows only what has been read. The
  empty state counts what has not.
- **A language Translation lacks** is searched by the multilingual tower: weaker (Estonian
  50 against 78 translated), but not empty.
- **A new model or preprocessing** bumps `SearchEmbedding.revision`, and every embedding is
  read again from the stored thumbnails. No original is read.
