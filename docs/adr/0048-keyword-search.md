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
   typed 65. A non-English query takes about 0.35 s, mostly the translation. The query is
   translated as a photo's caption, in the language's word for a photo ("사진: 호수"), and that
   word is taken off the English: a lone word otherwise has no context, and Translation reads
   it wrongly (Korean "호수", lake → "the number of houses"; Swedish "tåg", train → "march").
   Over 15 languages through the app, recall@10 rose from 78.3 to 80.5 and facts precision
   from 0.847 to 0.855.
3. **Read through Otos's glossary** a language Translation does not offer, when the user
   searches in it (`SearchGlossary`, Estonian): the picture's words it holds become English
   (Estonian 80 on the app's Core ML embeddings, against 49 as typed; English 85). The
   glossary is written for Otos: Vision's 1,303 scene-label names, then about 150 common words
   of a photo search (people, colours, qualities, places, times, actions with their verb
   forms), nominative and genitive, with the language's case endings; a typed word is read when
   forms cover it end to end. A form is listed once, for the sense a photo search means by it
   ("kell" a clock, not a bell; "aed" a garden, not a fence), and a glossary listing a form twice
   does not load: 125 Estonian forms meant two readings, and the order of the lines had chosen.
   A form of three letters or fewer is read only as the whole word, never with an ending or in
   a compound ("kuus", six, is not the moon; "seal", there, is not a pig), which also lets
   "öö" (night) be listed; "või" (butter, and the word for "or") is not listed.
4. **Fall back to the text as typed** for every other word, and for a language with no
   installed pack and no glossary, or none recognised. SigLIP 2's own multilingual tower
   reads it.

### Who reads a query: its own owner, never the window's loop

`SearchQueryReader` reads what the user searches for, through `SearchQueryEncoder`, one query
at a time on one loop woken by a doorbell (ADR 0032): the newest query is read next, and a
reading in flight is never cancelled, because a Translation session killed mid-request can
stall Translation for many minutes. `CatalogProjection` only asks it what it holds for the
query shown (`status(for:)`), so the window's publication never waits on Translation or Maps.
The projection publishes which of three states the shown query is in
(`CatalogWindowState.searchPhase`), and the window only renders it:
- **Being read** (`reading`): the pass builds nothing and republishes the last state as it
  is, marked as searching, so the window keeps what it shows and its subtitle says
  `Searching…`. Nothing is covered: the reader's report that the reading ended rings the
  projection, and that pass builds the answer. There is no deadline: the reader knows when a
  reading ends, so time never stands in for that report (ADR 0033), however long Translation
  or Maps take. A reading takes about 40 ms in English and 0.35 s translated. Ending the
  search publishes at once; a scope, filter or catalog change under the same query waits
  for its reading, still marked as searching.
- **Read** (`read`): the matches, or `No Results`.
- **Could not be read** (`failed`): the scope shows none of its items and the empty state
  says the search could not be made, until a retry reads it. A failed reading is read again
  after a backoff, 2 s doubling to a minute (`time: backoff`), not by the window's cadence,
  and logged with its error's domain and code; every failure is the same state, so nothing
  reads the error's text.

The reader:
- **What is kept:** only what does not change with time or with the Mac — a text's
  translation from a language, a text's embedding, Maps' answer for a name (found, or no place;
  a failed lookup is not kept). Recognition, which packs are installed and the facts are read
  on each reading; a date is kept as the rule the query names (`SearchDate`: "today", "last
  week", "September") and becomes a span when the query is answered, so a window left open
  past midnight answers "today" for the new day. The reader holds one answer, for the query
  shown, and lets it go when the field empties, so a query typed again is read again and a
  pack installed meanwhile counts.

Rejected:
- **Awaiting the encoding inside the projection's pass.** One publication loop serves the whole
  window: a wedged Translation or a hanging Maps request held every publication, and a failed
  translation re-ran the pass, and Translation, once a second.
- **A deadline after which the scope shows unsearched.** The grid then shows every photo
  under the field's text, which reads as the search's answer and is not one, and the
  deadline stands in for a fact the reader reports.
- **Keeping what the window shows when a reading fails.** A failure has no end the reader
  can report, and under a scope change the kept grid would be another scope's photos; the
  empty state is the one answer true for every scope.
- **A cross-lingual embedding instead of translation.** It scored 44–68, against 78.
- **A word-by-word translation model.** A sentence translator already handles a single word.
- **For a language Translation lacks:** the system language model (Foundation Models)
  translated half the Estonian queries wrongly ("rand", beach → "Random"; 38.5); prompt
  templates around the typed text (42–47); a cloud translator, which would send the user's
  search text off the Mac; and a downloaded third-party dictionary, a data dependency. The
  glossary is Otos's own data, read offline.
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
- **Undecodable thumbnails:** no reading. Nothing is recorded, so the asset stays owed and is
  tried again after the index's backoff; a pass pages past it, and past a prediction that
  failed, so neither holds up the assets after it, nor the text readings after every
  embedding. Recording one as an empty reading had the Info pane say `Nothing Recognized` for
  a picture nothing had read (ADR 0050). A preview that does not decode for text is the same.
  The readings recorded that way before this rule cannot be told from a preview that holds
  no text, so schema v53 drops every empty text reading of an asset with a stored preview,
  and each is read once more from that preview (1,498 of 1,930 readings on the owner's
  catalog; at about 0.15 s each, some four minutes of reading, and nothing downloads).

### The index: one owner, in memory

`PhotoSearchIndex` (an actor):
- **Embedding loop:** woken by the Store's change notifications, it reconciles memory with
  the catalog's current embeddings, then embeds what is owed, newest capture first, 16 at a
  time, on `SearchImageEmbedder`'s queue.
- **Memory:** every current embedding as one matrix. A query is one matrix–vector product
  (about 3 ms over 19,000 photos), with no SQLite read.
- **Answers:** `CatalogProjection` hands it the query's encoding, its facts resolved for the
  pass's now, and the scope's assets, and shows the matches. The index's `changes` stream
  asks for a new publication while a search is shown. The index's `revision` moves in the
  same step as every change to its memory, and each answer carries the revision it was
  computed at. The projection holds the last answer (`CatalogProjectionReads.Search`) and
  reuses it while the index, its revision, the encoding, the resolved facts and the scope
  are what they were and, for a query naming facts, no kind of fact the Store's fact
  matches read (rows shown, capture dates, locations, faces) moved. A window lap that took
  up only other facts asks the index nothing: at 164k items one match is 350–500 ms.

### Where results stop: a cutoff relative to the best match

A photo matches when its cosine is at least the best photo's minus 0.04, and at least 0.08
(`SearchCutoff.calibrated`). The best photo is the best in the scope searched (the folder,
source, person or filter shown), not in the library: a folder whose best photo of a dog scores
below the library's best still shows it. The label gate's near-best band follows the same
best. It was calibrated over the whole library, which is also a scope; within a narrower scope
the cut is no stricter than the scope's own photos warrant. Scores depend on the query: a short word scores lower than a
precise phrase, so a single cosine either cuts good queries short or floods weak ones.
Measured on the judged queries in 16 languages:

| Cutoff | Judged relevant kept | Median shown | 90th percentile shown |
| --- | --- | --- | --- |
| best − 0.04, floor 0.08 | 83% | 123 | 418 |
| cosine ≥ 0.09 | 84% | 140 | 854 |

About 65% of what the cut shows is relevant, measured on judged photos including a random
sample from inside it. A query for something the library hardly holds (soccer, a bath) still
shows photos, nearly all wrong: their best scores overlap those of queries with hundreds of
right answers, so no cut on the cosine can tell them apart. The label gate below narrows that.

### A second reading of each picture: scene labels gate a query that names a thing

Vision's scene classifier (1,303 labels, built in) reads the same stored thumbnail as the
embedding, and its labels are stored with it (`SearchEmbedding.revision` 3, which also stores the labels that pass
Vision's high-precision test for the Info pane, ADR 0050). A query names a
label when SigLIP's text tower puts the label's name within cosine 0.95 of the query's English
(`SearchLabelVocabulary`, the names embedded ahead of time by the shipped text path): "cat"
names cat, kitten and feline; a phrase names none. A named query keeps a photo only where the
classifier saw one of its labels at 0.05 or more, or SigLIP scores it within 0.02 of the best
(`SearchLabelGate`). Measured on the judged queries: precision inside the cut 0.65 → 0.70,
relevant photos kept 87% → 81%, the top 10 unchanged (recall@10 84.6 either way); horse showed
150 photos, two of them right, and shows 27. Rejected: a hand-made list of labels too generic to
gate on (same result, a list to keep), the classifier's confidence added to the cosine (smaller
gain), and a stricter cut (less precision for the same loss).

### Text in the photo

Searched for a word Vision reads in the owner's photos, SigLIP alone put a photo holding it in
its top 10 for 21% of them. So each still's stored preview is read for text (`search_text`,
`SearchTextReading`), and a photo whose text holds every typed word, at the start of a word,
ignoring case and diacritics, matches whatever the cut. It ranks first only for a query that
names no scene label: on 49 judged word queries recall@10 rose from 0.13 to 0.84, while
picture queries kept 0.846; ranking text matches first for every query dropped picture
queries to 0.739 ("cat" and "lake" are written on many signs and screens).

The preview is read at Vision's accurate level, pinned to the CPU, and every line from 0.3
confidence is stored with its confidence (`docs/research/2026-11-12-text-and-labels-in-the-info-pane.md`).
On the 60 judged word queries it matched 213 of the 222 relevant photos against the fast
level's 212, with 59 judged misreadings against 84, and about 180 real matches the fast level
missed. Its lines at full confidence read cleanly, which the Info pane shows (ADR 0050); the
fast level reported only 0.3 and 0.5 and misread texture at both. On the CPU it takes a median
0.15 s a preview; on the default device it stalled for 32 s under load. A reading that fails
about one picture stays owed and is retried after the index's backoff. A reading that fails
with `CRImageReaderError.e5rtError` status 13 is not about the picture: the runtime's compiled
model lost a file — macOS purges `~/Library/Caches` under disk pressure, and concurrent first
readings do the same — and every later reading in the process fails, whatever request, device
or API, while a new process reads again (`docs/research/2026-11-15-text-reading-lost-to-a-cache-purge.md`).
So text is read in a child process of Otos's own: its executable started with `--read-text`
(`SearchTextChild`, `SearchTextReadingProcess`), which serves one JSON line per preview and
never starts the app. A child whose reader is lost answers that it ended and exits; the page
ends there, every still not read stays owed, `op=search.text phase=sessionEnded` says so, and
the index's retry after its backoff (30 s doubling to 15 minutes) starts a new child, which
recompiles what the purge removed (4 s for a file, minutes for an emptied cache) and reads the
rest. The backoff bounds the recompiling a disk purged every few minutes would cause to one
child a backoff, where a reader lost for the app's process read nothing until the owner
relaunched. A child that exits while reading a picture, without answering, may have been ended by that picture (a decoder or recognizer crash), so the picture is paged past for the pass like a failed reading (`phase=sessionExited`) and the rest of the page is read by a new child: one such picture would otherwise come first in every page and stop every other still from being read. A child that neither answers nor exits is ended after 20 minutes and its picture is paged past the same way (`phase=sessionOverran`): nothing reports a reading that will never finish — the child's output stays open, and a heartbeat from it would beat on while Vision is stuck in another of its threads — so this is a deadline (ADR 0033), set at about twice the slowest reading measured, a cold first one under parallel load at 649 s, where a warm one takes 0.15–3.4 s (`docs/research/2026-11-14-vision-text-reading-breaks-for-its-process.md`). A child never
outlives the Otos that started it: its requests pipe has one writer, Otos (`Process` closes
every other descriptor in a child it starts), so the pipe ends when Otos ends the session,
quits, crashes or is killed, and the child reads that pipe on a thread that never reads a
picture and exits at its end at once, mid-reading or not (`phase=childInputEnded`). Read
between readings, as it first was, the end reached the child only after Vision's reading
finished, and every quit left a child holding Vision's model for minutes. The window's
teardown ends the live child and waits for its exit (`SearchTextReader.shutdown`); a quit needs
no step of its own. The still whose reading was cut short is stamped nothing, so it stays owed
(`docs/research/2026-11-15-text-reading-child-outlived-otos.md`). One serial queue reads every
preview, so Otos never starts two first readings at once. At 512 px the fast level read noise, so the full preview is read; an original
is not, since nearly every original in the owner's library is a cloud placeholder. Text is read
after every embedding is made.

### Facts in the query: when, where, who

A query is read for facts before the picture (`SearchQueryParser`, `SearchPlaces`):
- **Who:** a person the user named, matched in the typed text before translation (translation
  mangles names), as whole words ignoring case and diacritics.
- **When:** from the English reading, a month (the most recent), a month and year, a year, or
  today, yesterday, this or last week, month or year. In what the user typed, "may" is the
  month only beside "in", "of" or a year. In a translation, a month counts only when the text
  it was translated from names that month in its language, by Foundation's two month names as
  far as they agree ("syyskuu" covers "syyskuussa"): Translation reads Swedish "tåg" (train) as
  "march", and a query is translated as a caption whose first word Translation capitalises
  ("Photo: Lake"), so case says nothing. Joining words ("in", "at") are trimmed only beside a
  fact taken out, so Turkish "at" (horse), recognised as English, is not emptied. A language
  Translation cannot read now (Estonian; any whose pack is not installed) has its months found
  before recognition by Foundation's month names in the user's languages as whole words, or
  one of the case forms Otos knows for the language (Estonian genitive and in, from, into and
  until cases: "septembris", "maist"; Finnish on the standalone name: "syyskuussa"). A prefix
  match made "mail", "main" and "Maine" a May filter with Estonian among the languages, and
  Dutch "meisje" and French "maison" months.
- **Where:** the first name `NLTagger` calls a place or a person in the English reading (it
  often calls a place a person; an organisation's name is not a candidate, which no measured
  query needed), located by Apple Maps (`MKLocalSearch`, addresses and areas): a place only
  when Maps names it so, a case ending of up to three letters aside ("San Franciscos", Estonian for in
  San Francisco), and it covers 0.03° or more, a photo in it within 1.5 times the area's
  half-diagonal and at least 15 km. A name that is nowhere stays a picture word, and so does a
  one-word name an ordinary word follows ("Ferris wheel", which Maps places in Texas,
  "Christmas tree"); a longer one before a noun is a place ("San Francisco skyline"). "Paris
  cafe" is searched as a picture with the compounds, the milder miss. A query
  that may be in a language nothing recognises (not translated, from a user with such a
  language) takes the run of capitalised words around the tagger's name, or the first such
  run that is not a lone first word (a sentence's capital: "Orange cat", "Nice sunset"), under
  the same compound rule, because the English tagger finds only "San" in "koer San
  Franciscos".
- **What is sent to Maps:** that one name, as the query holds it (typed, or as translated),
  and nothing else of the query. Maps answering that nothing is called so (`MKError`
  `placemarkNotFound`) is remembered; a lookup that fails (offline, a server error) is not, and
  the name searches the picture for that reading. Maps names what it finds in the Mac's
  language and `MKLocalSearch.Request` has no language to ask in, so on a Mac in another
  language a place may be named otherwise than the query names it ("Lontoo" for "London") and
  be refused; that is unmeasured.

The Store answers the facts (`searchFactMatches`: capture time, GPS, confirmed faces); the rest
of the query searches the picture, and a query of facts only keeps the scope's order and day
sections. On 204 queries in 17 languages ("beach in September", "dog in San Francisco"),
precision@10 was 0.82 against 0.56 for the whole phrase as a picture query.

### The user's languages

Recognising a query's language favours the languages the user searches in (Settings ▸ General
▸ Search Languages, default the system's preferred languages) ten to one: a user's own were
recognised 95% of the time instead of 80%, a third language 83% instead of 85%, and mean
recall@10 across 16 languages rose from 75.0 to 76.0 (told the language: 77.1).

A language Translation cannot read is not one the recogniser knows either (Estonian is taken
for Finnish). When the user searches in one, a recognition outside their languages is not
trusted and the query is read as typed, so "jäätis" (ice cream) is not translated from
Finnish as "I froze". On the facts queries Estonian rose from 32 to 53 with this and the
inflected place names above; no other language moved.

The recogniser chooses only among English and Translation's languages, so an Estonian word
is often called English ("lennuk", airplane; "hobune", horse). A query recognised as English
from a user with a glossary language is read through the glossary when the glossary reads a
word of it and English spelling (`NSSpellChecker`, English alone) rejects a word of it. Of the
52 test queries in English, none is glossed; an English word the glossary also holds ("tool",
Estonian chair) is spelled right and stays English. Facts are read from the typed text before
the glossary, so a place's name is never read as a word ("Kassel" is no cat). On the facts
queries, Estonian rose from 56 to 86 and the total from 0.832 to 0.847.

### Reading while hidden

Otos holds one process activity for the session (`BackgroundReading`,
`.userInitiatedAllowingIdleSystemSleep`): with the owner away, App Nap had every Otos thread at
priority 4 and indexing stopped. It does not keep the Mac awake, and an idle Otos does no work.

A pass that leaves work owed it could not do rings the index's loop again after a backoff, 30 s
doubling to 15 minutes (ADR 0033 `time: backoff`). On a full disk the installed app, hidden,
had three predictions fail; with no catalog change to ring the loop, it read nothing more until
relaunch. Nothing reports when a full disk or a failed Core ML load clears.

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
- **First indexing:** about 20 minutes for 15,000 items in the dev build, newest first, then
  their previews' text, while hidden too.
- **Network:** a query holding a name the tagger calls a place or a person (or, read as typed,
  a capitalised run) sends that name, and only it, to Apple Maps; offline, the name searches
  the picture instead.
- **Unread items:** until indexing finishes, a search shows only what has been read. The
  empty state counts what has not.
- **A language Translation lacks** is read through Otos's glossary of it where one exists
  (Estonian, 80 against 85 in English); a word it lacks, and a language without one, is read
  by the multilingual tower as typed ("unistav", dreaming). A word that is both English and
  in the glossary, typed alone, reads as English ("rand", beach and a currency). A glossary
  applies only when its language is among the user's search languages (Settings ▸ Search
  Languages; default, the system's). Another language takes its own
  `SearchGlossary-<code>.tsv`.
- **A new model or preprocessing** bumps `SearchEmbedding.revision`, and every embedding is
  read again from the stored thumbnails. No original is read.
