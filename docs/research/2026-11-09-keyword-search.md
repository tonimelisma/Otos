# Keyword search: which models and mechanisms could find "dog on the beach" in the library

Date: 2026-11-09 to 2026-11-10. Question: how could Otos let the owner type a word or a phrase,
in any of many languages, and get the photos and videos that show it? Which current models can
do it under about 500 MB, and what does Apple already provide?

**Answer:** search by a contrastive image–text embedding (the CLIP family) is the only approach
that finds long-tail phrases. Apple provides no such embedding, so it needs a model of Otos's
own. The bake-off on the owner's library (section 7) found one clear best design, and the app
built from it (section 8) measures within three points of it:

- **Translate the query to English with Apple's on-device Translation, then search with
  SigLIP 2 B/16-256.**
- **Quality:** it found 85% of the attainable relevant photos in its top 10 for English queries,
  and 72–84% (mean 80%) for queries in 15 other languages.
- **Against the alternatives:** every multilingual model searched with the untranslated query
  did worse (at best a mean of 66–68%), and so did a distilled cross-lingual text encoder (44%).
- **Languages Translation cannot read** (Estonian in the test): SigLIP 2's own multilingual text
  tower still reached 50%.

Two Apple APIs complement it at no download cost: Vision's 1,303-label scene classifier and
Vision's text recognition.

Sources marked **[measured]** were run on this Mac (M1 Pro, macOS 27, Xcode 27.2 SDK) during this
research. The probes live in the session scratchpad, not in the repository. **[source]** is a
figure read from the cited page. **[estimate]** is an extrapolation.

## 1. Three ways to search pixels

| Approach | What is stored per asset | What it finds | What it misses |
| --- | --- | --- | --- |
| **Embedding search** (CLIP family) | one 512–1152-d vector | any phrase the text tower can encode: "red umbrella on a pier", "lapsi pulkassa" | gives a ranking, not a yes/no; a cutoff must be calibrated per model; no explanation of why a photo matched |
| **Fixed-vocabulary tags** (Vision classifier, RAM++) | a few labels with confidences | the concepts in the vocabulary, with calibrated precision | anything outside the 1–5k labels; combinations ("dog *on* beach") |
| **Captions** (a small vision-language model) | a sentence or keyword list | what the model chose to mention, 3–6 salient things | everything it did not mention; costs seconds per photo |

Every shipping product that does free-text search uses embeddings: Immich (CLIP ViT-B/32 by
default), Ente (MobileCLIP S2, on-device), Peakto, Excire, Synology Deep Search, and probably
Apple Photos. Products without embeddings search tags only: digiKam (YOLOv11 + EfficientNet
labels; CLIP search is an open request, KDE bug 515936), Mylio (SmartTags), PhotoPrism
(classifier labels plus optional Ollama captions). Lightroom desktop's natural-language search is
cloud-only; its local mode searches metadata. Lightroom Classic has no visual search.

## 2. What Apple provides on macOS 27

Checked in the macOS 27 SDK interfaces and by running probes **[measured]**:

- **`ClassifyImageRequest` (`VNClassifyImageRequest`), revision 2:** 1,303 English snake_case
  labels from `supportedIdentifiers` (`beach`, `snow`, `dog`, `lake`; no `sauna`). Each label has
  an Apple-calibrated precision/recall curve, used through `hasMinimumPrecision(_:forRecall:)`.
  About 15–19 ms per image warm, after a 2.6 s first load. No download. The labels are not
  localized: Finnish search needs an Otos-owned table of 1,303 Finnish names.
- **`RecognizeTextRequest` (revision 3) and `RecognizeDocumentsRequest`:** Finnish (`fi`) is
  among the 33 recognition languages. No download. Speed not measured.
- **`CalculateImageAestheticsScoresRequest`:** `isUtility` marks screenshots and receipts; a
  possible facet.
- **No image–text embedding anywhere.** Vision's `GenerateImageFeaturePrintRequest` is
  image–image only. PhotoKit exposes no scene, caption or search index, and it covers only the
  Photos library anyway.
- **Foundation Models image input (new in 27):** `Attachment(cgImage:)` in a prompt, with
  `capabilities.contains(.vision)` true on this Mac. A beach photo gave "beach, sea, ocean,
  shore, coast". 9.7 s cold, about 2.4 s warm per image: about 13 hours for the owner's 19,415
  assets, before decode. Finnish is not in `supportedLanguages`, and a request for Finnish
  keywords returned English. The `.contentTagging` use case with an image failed
  (`ModelManagerError 1001`). WWDC26 session 241.
- **Translation (`TranslationSession(installedSource:target:)`):** Finnish → English is
  supported and installed on this Mac. This makes an English-only image model usable with
  Finnish queries, at the cost of translating each query.
- **Natural Language:** `NLEmbedding.sentenceEmbedding(for: .finnish)` is nil.
  `NLContextualEmbedding` covers Finnish, but in a text-only space that is not aligned with any
  image space.
- **Not useful for this:** Core Spotlight semantic search (`CSUserQuery`) is text-only and
  reported not to work for third-party apps (Apple forums threads 793867 and 767355).
  `SpotlightSearchTool` lets the on-device LLM query an app's Spotlight donations, which would
  put Otos's index into the system store. `VisualIntelligence` only feeds an app's results to the
  system camera search.

## 3. Embedding models

Finnish ("Fi") is Immich's per-language benchmark: the mean of R@1, R@5 and R@10 for
text-to-image retrieval on Crossmodal-3600 **[source]**. It is the only Finnish number published
for any of these models. Sizes are fp32 checkpoints **[source]**; fp16 and int8 are a half and a
quarter **[estimate]**.

| Model (release) | Image + text params | fp32 → int8 | IN-1k zero-shot | Flickr T→I R@1 | Fi | Licence | Core ML |
| --- | --- | --- | --- | --- | --- | --- | --- |
| NLLB-CLIP base, SigLIP image tower (2023) | 86M + ~400M | 2,030 → ~510 MB | – | – | **78.9–79.4** | CC-BY-NC-4.0 | none |
| mSigLIP B/16-256 i18n (2023) | 86M + ~280M | 1,483 → ~370 MB | ~75 | – | 63.2 | Apache-2.0 | none |
| CLIP ViT-B/32 + XLM-R base (LAION, 2022) | 88M + 278M | 1,465 → ~370 MB | ~63 | – | 63.1 | MIT | none |
| SigLIP 2 B/16-256 (Feb 2025) | 86M + ~282M | 1,501 → ~375 MB | 79.1 | 81.7 | 40.3 | Apache-2.0 | community 8-bit port (palmier-io, cosine ≥ 0.99 against PyTorch) |
| SigLIP 2 L/16-256 | 303M + ~400M | ~2.8 GB | 82.5 | 84.1 | 57.1 | Apache-2.0 | – |
| MobileCLIP2-S2 (Aug 2025) | 35.7M + 63.4M | 398 → ~100 MB | 77.2 | 74.8 | English only | apple-amlr (research only) | none official; v1 has one |
| MobileCLIP2-B | 86.3M + 63.4M | ~600 → ~150 MB | 79.4 | 76.5 | English only | apple-amlr | as above |
| MobileCLIP v1 S2 | 35.7M + 63.4M | Core ML 71 + 127 MB | 74.4 | – | English only | card says apple-ascl; linked weights licence 404s | **official** (`apple/coreml-mobileclip`) |
| PE-Core B16 (Apr 2025) | 90M + 310M | ~1.6 GB | 78.4 | – | English only | Apache-2.0 | none |
| MetaCLIP 2 worldwide B32 (distilled, Nov 2025) | – | 2,351 MB (≈900k-token vocabulary) | – | – | not published | CC-BY-NC-4.0 | none |
| jina-clip-v2 (Dec 2024) | 304M + 561M | ~3.5 GB | – | – | (89 languages) | CC-BY-NC-4.0 | ONNX |
| FG-CLIP 2 base (Oct 2025) | SigLIP 2 B/16 based | 1,535 MB | – | – | English and Chinese only | Apache-2.0 | none |
| OpenAI CLIP ViT-B/32 (Immich default) | 88M + 63M | ~600 → ~150 MB | 63.2 | ~59 | English only | MIT | many |

No 2026 release in this family turned up: no SigLIP 3, MobileCLIP 3, Perception Encoder 2 or
MetaCLIP 3. The newest are MetaCLIP 2's distilled models and FG-CLIP 2. TULIP (Mar 2025) starts
above 1B parameters.

**What the table says** (published numbers; section 7 measures them on the owner's library):
- **Untranslated Finnish follows the text tower.** The models that do well on Finnish carry a
  large multilingual text encoder (NLLB, XLM-R, mSigLIP's 250k vocabulary). Its token-embedding
  table is most of the download. SigLIP 2 is multilingual in name, but at B size it scores 40 on
  Finnish against 66 on Swedish. The bake-off reproduced that gap (41 against 60), and showed
  that translating the query first closes it.
- **Licences are not the barrier they would be elsewhere.** Otos is non-commercial (owner
  decision, ADR 0047), so CC-BY-NC models are acceptable. The Apple ML Research licence
  (`apple-amlr`) on MobileCLIP2 and FastVLM is narrower: it covers research use, and whether a
  personal non-commercial app falls under it needs reading before relying on it.
- **Size against GitHub's 100 MB file limit** (memory `core-ml-in-otos`): every multilingual
  candidate's int8 text tower exceeds it as one file. The options are splitting the weights
  across files, trimming the vocabulary to the tokens of the languages used, or shipping the
  model outside the repository. Trimming is plausible because the table is a lookup by token ID,
  but it is untested here.
- **Speed is not a constraint.** Apple publishes 3.6 ms image + 3.3 ms text for MobileCLIP2-S2 on
  an iPhone 12 Pro Max Neural Engine; Immich publishes 5.8 ms for SigLIP 2 B/16 and 6.9 ms for
  mSigLIP on a server CPU **[source]**. A B/16 image tower at 224–256 px should take tens of ms on
  this Mac's CPU **[estimate]**. Decoding the input costs more than the model.

## 4. Taggers and small vision-language models

| Option | Size | Finnish | Per image | Verdict |
| --- | --- | --- | --- | --- |
| Vision `ClassifyImageRequest` | 0 | via a 1,303-row table | ~15 ms **[measured]** | complement: explainable tags, facets, exact concepts |
| RAM++ (Swin-L, 4,585 tags) | 3.0 GB + 479 MB tag embeddings | via a table | not published | too big for 3.5× the vocabulary; no successor found |
| Florence-2 base (0.23B) | ~0.5 GB fp16 | no | not published | English only |
| SmolVLM2 256M / 500M | 0.8 / 1.2 GB memory | weak | not published | English-centred |
| Apple FastVLM 0.5B | 0.8B params | weak | not published | research-only licence |
| LFM2.5-VL-450M | 0.4B params | not among its 9 languages | not published | no Finnish |
| Qwen3.5-0.8B (Feb 2026) | ~0.6 GB at 4-bit **[estimate]** | claims 201 languages | not published | the one small captioner worth testing for Finnish |
| Gemma 4 E2B | 5.1B total | 35+ supported languages | not published | over budget |
| Foundation Models image prompt | 0 | no | ~2.4 s **[measured]** | English captions only, slow |

Every published VLM speed figure is MLX or llama.cpp on the GPU. Otos runs Core ML on the CPU
because the GPU deadlocked under concurrent predictions (memory `core-ml-in-otos`), so a VLM
would be slower than those figures or would need a GPU engine and its own ADR. Captions also run
into Finnish inflection in SQLite FTS5: "koira" does not match "koiran" or "koiria". Embeddings
avoid that, and a fixed tag table can list the forms.

Open-vocabulary detectors (OWLv2, Grounding DINO, YOLO-World) take the query at run time, so
they could re-check top results but cannot build an index.

## 5. Retrieval

**No vector index is needed at this scale [measured].** An exact scan of 100,000 vectors, off
the main actor:

| Dimensions | Float32 `cblas_sgemv` | Float16, SIMD, 16-way `concurrentPerform` | Float16 matrix |
| --- | --- | --- | --- |
| 512 | 7.3 ms | 9.7 ms | 102 MB |
| 768 | 10.5 ms | 16.2 ms | 153 MB |
| 1152 | 15.1 ms | 26.0 ms | 230 MB |

The owner's library (19,415 assets) at 768-d Float16 is about 30 MB. Picking the top k costs
under 1 ms. sqlite-vec is still pre-1.0 (v0.1.10 alphas), and as a loadable extension it would
need a custom SQLite under GRDB. USearch and FAISS pay off only past a million vectors.

**Matches or a ranking.** Immich returns the top N by distance with no score and no cutoff
(`search.repository.ts`). Ente keeps photos with cosine ≥ 0.175 for MobileCLIP S2
(`services/ml/clip.ts`, mobile `kMinimumSimilarityThreshold`), commented as a heuristic. A
cutoff belongs to one model; it must be calibrated again for any other.

**Combining with what the catalog already knows.** Immich and Ente apply people, places, dates
and file type as hard filters, not as fused scores. Ente offers typeahead chips per facet
(dates parsed with chrono-node) and the user combines them. Google's Ask Photos uses an LLM to
pull people, places and dates out of the sentence; Apple Photos and Lightroom desktop accept
them in one sentence without saying how. A local, deterministic version is to match the
catalog's own people names, place names and date expressions in the query, turn them into
filters, and send the remainder to the text encoder. Where rankings must be merged (embedding
with OCR or filename hits), reciprocal rank fusion, Σ 1/(60 + rank), needs no score calibration
(Cormack et al., SIGIR 2009).

## 6. What fits Otos's architecture

- **Input without downloads.** 10,065 of the installed catalog's 19,415 assets already have the
  stored 2560 px preview, and every asset has the 256 px thumbnail (ADR 0035). The model input
  is 224–384 px, so the stored renderings are enough. Embedding them materializes no original.
  An Immich account's previews are stored the same way.
- **Immich.** `POST /api/search/smart` needs only the `asset.read` permission and does not write
  to the server. But it returns no scores, its model is whatever the server administrator chose
  (CLIP B/32 by default, English), and its results could not be ranked together with local
  folders. Embedding the stored Immich previews locally gives one ranking for every source.
- **Videos.** Immich embeds one preview frame per video. Otos's videos keep only the Quick Look
  thumbnail and get no preview (ADR 0035), so the simplest equal is to embed that frame. Several
  frames per video, scored by the best frame, would also let a hit seek to its moment.
- **Lifecycle.** A vector is derived overlay: keyed by the asset's path like the `face` table,
  stamped with a model revision, stale when the rendering it came from changes.
- **Engine.** Core ML on the CPU, owned like `EditAnalyzer`; the measured scan above needs only
  Accelerate.

## 7. Bake-off on the owner's library

The published numbers could not decide this. Crossmodal-3600 captions are not the owner's
queries, and the face research had already shown that a measured run on the owner's library can
overturn a published ranking. The material lives in `~/Development/Otos-search-research`, outside
the repository, because it holds the owner's photos. This section keeps the method and the
numbers.

### Method

- **Corpus:** all 19,221 non-trashed assets of the installed catalog that have a stored
  rendering. Each is downscaled to a 512 px long edge: the 2560 px preview where there is one
  (10,065 assets), otherwise the 256 px thumbnail (videos and un-rendered stills). No original
  was read.
- **Queries:**
  - 52 concepts chosen from what a random sample of the library shows: beach, swing, bouncy
    castle, child riding a bike, birthday cake, phone screenshot, restaurant menu, Golden Gate
    Bridge, child wearing a red hat, and so on.
  - Each concept was written as a person would type it in 17 languages: en, fi, sv, de, fr, es,
    it, nl, pl, ru, ja, zh, ko, ar, hi, tr, et.
  - Single words and phrases are mixed.
- **Two ways to handle a language:**
  - **Native:** the query as typed goes to the model's own text encoder.
  - **Translated:** Apple Translation (`TranslationSession(installedSource:target:)`) turns it into
    English first. Every test language except Estonian had an installed pack; Estonian is
    unsupported, so it stays untranslated.
  - The translations were good with realistic slips: Arabic "bouncy castle" became "Nattata
    Castle", and Japanese became "Fluffy playground equipment".
- **Candidates** (PyTorch fp32, open_clip weights):
  - SigLIP 2 B/16-256;
  - mSigLIP B/16-256 i18n;
  - CLIP B/32 + XLM-R base;
  - NLLB-CLIP base SigLIP;
  - MobileCLIP2-S2 and MobileCLIP v1 S2 (Ente's model);
  - PE-Core B16;
  - OpenAI CLIP B/32 (Immich's default);
  - the cross-lingual idea itself: `sentence-transformers/clip-ViT-B-32-multilingual-v1`, a
    multilingual text encoder distilled into CLIP B/32's text space, used with B/32's image
    tower.
- **Relevance:**
  - Judged once per concept, by pooling: the union of every run's top 10 (model × mode ×
    language), 23,603 photos plus 1,107 more from a first pool.
  - Judged on shuffled contact sheets against a one-line written criterion per concept.
  - Judging agents did the sheets. On two sheets judged independently by a second judge, 96
    photos with 16 relevant, the two agreed on every photo.
  - Every run's top 10 is therefore fully judged.
- **Metric:**
  - **Pooled recall@10:** the relevant photos in the top 10, divided by the smaller of 10 and the
    number of relevant photos any run found. Averaged over the 51 concepts that have at least
    one.
  - "Child in the bathtub" had none.
  - Several concepts have only 1–8 relevant photos (sushi, soccer ball, horse, Christmas tree,
    cat, plane, rain), so a single hit moves them a lot.
- **Harness defect found and fixed:** open_clip's `set_language` does not change NLLB's
  language-prefix token, so every NLLB query was first encoded as English ("dog"/"koira"
  cosine 0.47 → 0.99 once fixed). NLLB was re-run with `tokenizer.src_lang`, and the 283 photos
  its new top 10 brought in were judged.

### Results

Pooled recall@10, %. "Translated mean" covers the 15 languages Translation handled; Estonian is
always untranslated.

| Model | en | Translated mean (min) | Untranslated mean (min) | fi untranslated / translated | et |
| --- | --- | --- | --- | --- | --- |
| **SigLIP 2 B/16-256** | **85** | **79.7** (72) | 66.0 (41) | 41 / 78 | 50 |
| MobileCLIP2-S2 | 81 | 76.0 (72) | 38.8 (0) | 15 / 74 | 11 |
| mSigLIP B/16 i18n | 79 | 73.0 (66) | 65.8 (50) | 60 / 73 | **53** |
| CLIP B/32 + XLM-R | 76 | 70.8 (66) | **67.5** (52) | 60 / 69 | 47 |
| MobileCLIP v1 S2 | 75 | 69.9 (64) | 24.9 (0) | 7 / 69 | 11 |
| OpenAI CLIP B/32 | 73 | 67.6 (59) | 19.2 (0) | 11 / 68 | 7 |
| Distilled multilingual CLIP B/32 | 71 | 66.8 (64) | 44.3 (32) | 37 / 66 | 32 |
| PE-Core B16 | 71 | 65.9 (60) | 26.7 (1) | 16 / 65 | 17 |
| NLLB-CLIP base SigLIP | 63 | 59.1 (52) | 55.3 (50) | 50 / 60 | 49 |

**SigLIP 2 + translation against the rest** (paired bootstrap over concepts, translated
languages, 5,000 resamples):

| Against | Difference | 95% interval |
| --- | --- | --- |
| MobileCLIP2-S2 | +3.8 points | −0.2 to 8.2 |
| mSigLIP i18n | +6.7 points | 2.1 to 11.5 |
| CLIP B/32 + XLM-R | +9.0 points | 3.8 to 14.5 |
| MobileCLIP v1 S2 | +9.9 points | 4.6 to 15.8 |
| OpenAI CLIP B/32 | +12.1 points | 6.8 to 18.0 |
| PE-Core B16 | +13.9 points | 7.8 to 20.7 |

**What the results say:**

1. **Translation beats every cross-lingual embedding.** Each model does better on translated
   queries than on its own multilingual encoding of them. The best untranslated score (CLIP
   B/32 + XLM-R, 67.5) is below the best translated one (79.7) by 12 points. Distilling a
   multilingual encoder into CLIP's text space (the "embedding between the languages" idea)
   reached 44 untranslated, and SigLIP 2 B/16's own Finnish only 41. A sentence translator also
   covers the word-for-word case, since a single word is a sentence to it.
2. **The image side decides the ranking once queries are English.** The translated order
   follows the English order. SigLIP 2 B/16 leads clearly against every candidate but
   MobileCLIP2-S2, whose interval touches zero.
3. **Published multilingual numbers did not carry over.** NLLB-CLIP leads Crossmodal-3600 on
   Finnish, but it was last here in English and in every translated language. It led no
   language untranslated either, though it was the most even.
4. **Translation has a gap.** A language Apple Translation cannot read falls back to the model's
   own text tower. There SigLIP 2 (50) and mSigLIP (53) hold up, and the English-only models
   collapse (7–17).

### Cost of the two leaders

Measured in PyTorch fp32 on this Mac's CPU, one image at a time. Core ML numbers come with the
conversion.

| | SigLIP 2 B/16-256 | MobileCLIP2-S2 |
| --- | --- | --- |
| Parameters | 93M image + 282M text, of which 197M is the 256k-token vocabulary table | 36M image + 63M text |
| Size at 8-bit | ~375 MB | ~99 MB |
| CPU image encode | 55 ms | 649 ms (not reparameterized here; it is designed for the Neural Engine) |
| CPU text encode | 28 ms | 25 ms |
| GPU (MPS) batch throughput | 19,221 images in 429 s, 22 ms an image | 19,221 in 257 s |
| Licence | Apache-2.0 | Apple ML Research (research use) |

**The English-only text side:**
- With translation, SigLIP 2's text tower only ever sees English. Every word in the system
  English dictionary (235,976 words, in three casings) tokenizes into 58,183 of the 256,000
  vocabulary entries.
- Keeping only those would shrink the table from 197M to about 45M parameters, and the model to
  roughly 225 MB at 8-bit. It would also bring each file under GitHub's 100 MB limit when split
  by tower.
- **Not tested here:** whether a trimmed tokenizer reproduces the full one's embeddings for every
  query. It also gives up the 50% untranslated fallback for languages Translation lacks.

**Also measured:** PyTorch's MPS backend hung in `MTLCommandBuffer waitUntilCompleted` when two
processes used the GPU at once (NLLB image encoding next to text encoding). The run was idle at
0% CPU for 13 minutes. This is the same failure that made Otos run Core ML on the CPU (memory
`core-ml-in-otos`).

### Settled in §8

The query's language, the Core ML conversion and its 8-bit drift, the match cutoff and the
resize are measured in §8, with the code Otos ships.

## 8. From the bake-off to the app

Everything here ran the code Otos ships — the converted Core ML models, the Swift tokenizer,
resize and query encoder (`SearchQueryEncoder`) — on the same 19,221 photos, and every result
it showed was judged (1,469 more photos, by the same contact-sheet method), so no score below
counts an unjudged photo.

### Core ML and 8-bit weights

- **The conversion is exact:** at full precision the Core ML image tower reproduces PyTorch
  (median cosine 1.0000 on 300 photos).
- **Plain 8-bit was not:** linear per-channel int8 gave a median cosine of 0.917, and English
  recall@10 fell from 85 to 81. Per-block (0.945) and asymmetric (0.913) int8 were no better.
- **One tensor caused it.** Quantizing each weight group alone (`tools/sensitivity.py` in the
  research folder): every block, the patch embedding and the attention pool stay at 0.9999;
  the positional embedding alone drops to 0.914. It is one (1, 256, 768) tensor, so "per
  channel" gives 196,608 values a single scale.
- **Kept at full precision**, the int8 tower matches at 0.9994 (5th percentile 0.9986), 94 MB.
- **Text tower:** int8 weights and the int8 token table move scores by under a point.

### The resize

The first Swift path drew the thumbnail into a 256 × 256 Core Graphics context. Against
PyTorch on the same thumbnails its embeddings had a median cosine of 0.973. Fed a square
resized by PIL, the same path gave 0.999: the gap was the filter. open_clip hands torchvision
a PIL image, which PIL resizes with its bicubic filter (a = −0.5, widened when shrinking,
8-bit rounding between passes) and without converting an embedded colour profile.
`SearchImageResampler` reproduces that (every channel within 1 of PIL on the test fixtures)
and brings the shipped path to a median of 0.997; what is left is JPEG decoding, which
differs slightly between ImageIO and libjpeg. In a Debug build the first, per-pixel version
took 74% of indexing time; as one matrix product per pass and channel (Accelerate) it costs
under 10 ms.

### Thumbnail or preview

Fully judged, the 256 px thumbnail loses nothing against the bake-off's input (the 2,560 px
preview downscaled to 512 px where one existed): with Translation told the language, 77.1
against 77.3 across 16 languages, 85 in English for both. Before judging, the thumbnail had
looked 2 points worse; that was the photos it ranks that nobody had judged.

### The query's language

The app is never told a query's language. `NLLanguageRecognizer` was run on all 884 queries:

| Recogniser | Correct | Mean recall@10, 16 non-English languages |
| --- | --- | --- |
| Told the language | 884 | 77.1 |
| Constrained to English + Translation's languages (shipped) | 704 | 75.0 |
| Unconstrained | 678 | 74.4 |
| No translation, as typed | — | 65.4 |

- **Most mistakes cost nothing:** a cognate read as a neighbouring language translates the
  same ("strand" as Dutch, "pizza" as Italian).
- **Those that cost** are words that are ambiguous alone: Turkish "at" (horse) read as English,
  Polish "kot" (cat) translated from Finnish as "cluck", Swedish "glass" (ice cream) read as
  English.
- **Estonian**, which Translation lacks and NaturalLanguage does not recognise, is mostly read
  as Finnish and translated badly: 37, against 52 as typed.
- **Fusing** the native and translated embeddings (74.0) and gating on the recogniser's
  confidence (75.7–76.5) did not beat constrained recognition by more than the judging
  resolves.
- **Latency:** asking Translation for every language's availability on every query cost
  0.67 s; the shipped encoder reads the language list once and asks only about the language
  it recognised (16 ms). Translating a word takes most of the rest: 884 queries ran in 306 s,
  0.35 s each, 50 ms of it CPU.

### Where results stop

Scored over every judged photo, English queries, the app's embeddings:

| Cutoff | Judged relevant kept | Median shown | 90th percentile shown | Precision of what is shown |
| --- | --- | --- | --- | --- |
| best − 0.04, floor 0.08 (shipped) | 83% | 123 | 418 | 0.65 |
| best − 0.03, floor 0.08 | 72% | 78 | 269 | 0.73 |
| cosine ≥ 0.09 | 84% | 140 | 854 | 0.61 |
| cosine ≥ 0.10 | 75% | 82 | 523 | 0.70 |

Precision is estimated from the judged photos inside the cut, which include a random sample
of six per concept from anywhere inside it, so it is not only the top of the list. A query for
something the library hardly holds still shows photos: soccer (one relevant photo), bath
(none), horse and Christmas tree (two each) show 30–150, nearly all wrong. No cut separates
them, because their best scores (0.108–0.130) overlap those of queries with hundreds of right
answers (plane 0.101, beach 0.119). With Relevance order the best matches come first.

### The app on the owner's library

The dev build indexed its own catalog: 14,846 assets in about 20 minutes, 12 a second, while
enrichment ran. Where its stored thumbnail is the same file as the installed catalog's, its
stored embedding equals the offline run of the same code (cosine 1.0000); the rest differ
because the dev catalog rendered its own thumbnails. Its embeddings with its own query
encoder, over the photos it holds:

| | English | Mean of 16 other languages | Estonian |
| --- | --- | --- | --- |
| The app (dev catalog, `SearchQueryEncoder`) | 82 | 74.4 | 34 |
| The same code on the installed catalog's thumbnails | 83 | 75.0 | 37 |
| Bake-off: PyTorch, previews, told the language | 85 | 77.3 | 48 |

**App Nap.** With the owner away (`UserIsActive 0`), macOS App Naps Otos as it does Mail and
Safari: every thread runs at priority 4 and indexing, like enrichment, all but stops until the
window is seen again. The measurement run turned App Nap off for the dev build
(`NSAppSleepDisabled`) and removed the setting afterwards.

## 9. Raising precision, and searching by what else a photo holds

Run 2026-11-10 on the same library, with the shipped code wherever the app does the work.

### The user's languages

A user of language L who also uses English, simulated for each of 16 languages, with
`NLLanguageRecognizer`'s hints favouring L and English:

| Hint ratio (own : other) | Own languages recognised | A third language recognised |
| --- | --- | --- |
| none | 80.1% | 85.3% |
| 2:1 | 86.4% | 84.9% |
| 6:1 | 93.3% | 83.5% |
| 10:1 (shipped) | 95.3% | 82.5% |
| 50:1 | 96.9% | 78.7% |

Through the shipped encoder at 10:1, wrong recognitions fell from 180 to 101 of 884 queries, and
recall@10 rose from 83 to 85 in English and from 75.0 to 76.0 across the 16 other languages
(told the language: 77.1). Polish gained most (72 → 80: "kot" is read as cat, not as Finnish).
This Mac lists only `en-US`, which is why the languages are a setting.

### Precision: Vision's scene labels as a gate

Score statistics cannot tell a query for something absent from one with many answers: the
best match's cosine (0.101–0.188) and its z-score over the library (3.2–8.0) overlap
completely, soccer (one relevant photo) at z 6.1 among concepts with hundreds. So a second,
independent reading was tried: `VNClassifyImageRequest` on the stored thumbnail (31 ms).

| Rule | Recall inside the cut | Precision inside the cut | Median shown | 90th pct |
| --- | --- | --- | --- | --- |
| cut alone (§8) | 0.866 | 0.651 | 141 | 368 |
| cut best − 0.03 | 0.72 | 0.73 | 78 | 274 |
| + label confidence added to the cosine (×0.02) | 0.829 | 0.692 | 95 | 298 |
| + gate, labels named lexically, a stoplist | 0.799 | 0.717 | 88 | 299 |
| + gate, labels named by text cosine ≥ 0.95 (shipped) | 0.810 | 0.700 | 92 | 296 |

The top 10 is untouched (recall@10 0.846, precision@10 0.786 → 0.796). The gate helps where the
library lacks the thing: horse 150 shown → 27, cat 105 → 44, Christmas tree 45 → 16, and dog
225 → 135 with 82 of 87 relevant kept. It costs where the classifier is weak at a concept:
museum kept 9 of 27, train 39 of 76. Labels from the 256 px thumbnail gate as well as from a
512 px render (0.810 / 0.700 against 0.811 / 0.701).

### Text in the photo: needed

Words Vision reads in the owner's photos, searched with SigLIP alone: a photo holding the word
reached the top 10 for 21% of 74 words, names and brands included. So text is read.
Recognition on macOS 27: the accurate level failed for every image after a process's first
(`e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options`, error
13), pinned to the CPU or not, while the fast level never failed and reads a 2,560 px preview in
0.07 s, cleanly on screenshots. At 512 px the fast level read noise. The shipped reader uses the
fast level on the preview.

Read over all 10,065 previews with the shipped reader, 5,322 held some text. 60 words sampled
from the readings (in 2–25 photos each, in the dictionary or capitalised), every top 10 and
every text match judged for whether the word is visibly written (one judge also ran Vision on
its 512 px copies to read tiles too small to see, which leans toward the reader):

| Text matches rank | Picture queries (51 concepts) recall@10 | Word queries (49 with a visible match) recall@10 |
| --- | --- | --- |
| not lifted (picture only) | 0.846 | 0.132 |
| + 0.05 | 0.822 | 0.712 |
| first, every query | 0.739 | 0.982 |
| first when the query names no scene label (shipped) | 0.846 | 0.842 |

Of the photos a reading matched, 72% visibly hold the word; the rest are misreadings, and
the fast level's line confidence (mostly 0.5) does not tell them apart. 8 of the 49 word
queries name a scene label ("kitchen", "gloves") and so are ranked as pictures.

### Facts in the query

204 queries, 12 concepts × 17 languages, each a concept word from §7's hand-written queries with
a month or a place in that language's own grammar ("ranta syyskuussa", "9月のビーチ",
"koer San Franciscos"). Ground truth: the judged relevant photos captured that month, or within a
fixed circle of the place by GPS.

| | Precision@10 = recall@10 |
| --- | --- |
| The whole phrase as a picture query | 0.558 |
| Facts read out and applied, the rest as the picture (shipped) | 0.820 |

By language: en 92, fi 92, de 88, fr 87, it 87, nl 87, ru 87, hi 87, ja 85, ko 85, ar 84, es 83,
zh 82, tr 80, pl 79, sv 78, et 32. Estonian rose from 24 when its months were read by
Foundation's month names in the user's languages; its places were not read (the name
arrives inflected, "San Franciscos"; § Estonian below). The parser's misses were translations that mangle a
name ("Lake Taihao") and a possessive ("October's swing", fixed). Of the place candidates the
tagger returned, Maps answered the false ones ("City view", "Panorama") with a street of that
name somewhere; requiring an exact name and an area of 0.03° or more rejected all of them.
Generating the test queries with Translation (English → each language) was tried first and
discarded: it produced wrong words ("heilua", to sway, for a swing; "mantelit", almonds, for
pumpkins).

### Estonian: a language nothing recognises

Two faults held Estonian at 32 on the facts queries. Queries the recogniser took for Finnish
were translated from it ("jäätis San Franciscos", ice cream in San Francisco, became "I froze";
"linna siluett", city skyline, "linen silhouette"). And its place names are inflected:
the English tagger tags only "San" in "koer San Franciscos" and nothing in "batuut Walnut
Creekis", while Maps, asked for "San Franciscos" or "Walnut Creekis", answers San Francisco
and Walnut Creek. Three changes, each measured on the 204 queries:

| Change | Total | Estonian |
| --- | --- | --- |
| before | 0.820 | 32 |
| + a recognition outside the user's languages is read as typed when one of theirs is untranslatable; Maps' name may lack a case ending of up to 3 letters; as-typed queries take the first capitalised run as the place | 0.828 | 47 |
| + that applies to every untranslated query of such a user, the run grown around the tagger's name (shipped) | 0.832 | 53 |

No other language moved, and every place read was right (San Francisco, Lake Tahoe, Mount
Shasta, Walnut Creek). The rest of Estonian's gap is the picture: "rand" (beach) read as
typed by the multilingual tower, and "Tahoe järve ääres" (by Lake Tahoe), whose name Maps
answers as "Lake Tahoe".

Over the 884 picture queries of §7, the encoder read 3 places, all wrong and all one
case that predates these changes: Japanese, Chinese and Korean "carousel" translate to "Ferris
wheel", and Maps places "Ferris" (Texas). The case-ending and capitalised-run rules added no
false place. Rejecting a name an ordinary word follows leaves 0 places in the 884, and the
204 facts queries unchanged (0.832, Estonian 53): every right place in them ends its query.
It also lost "San Francisco skyline". Rejecting only a one-word name before a noun (shipped)
keeps 0 false places in the 884 and the facts queries the same (0.829 for both rules, on the
catalog re-read by the installed app). Of nine phrases tried by hand, it places "San Francisco
skyline" and "Lake Tahoe sunset" and none of "Ferris wheel", "Christmas tree", "Teddy bear",
"Disney castle" or "Golden Gate bridge"; "Paris cafe" and "New York pizza" are not placed.

Estonian queries read as typed were also tried inside a prompt, on the bake-off's full-precision
embeddings and judgments (recall@10 over 51 concepts): as typed 50.1, "pilt: …" 46.8,
"… (foto)" 44.1, "foto: …" 43.6, "a photo of …" 42.1. None helps; the query stays as typed.

The on-device system language model (Foundation Models, available on this Mac, reporting
neither Estonian nor Finnish as supported) was asked to translate the 52 Estonian queries to
English. Half came back wrong ("rand", beach → "Random"; "kiik", swing → "Bird"; "kass", cat →
"Cash register"): recall@10 38.5, and fused with the typed embedding 41.3, against 50.1 as
typed. With Translation offering no Estonian and no Estonian dictionary among the system's
(86 dictionary assets checked), no reader on the device does better than the multilingual
tower.

### Estonian through a glossary written for Otos

A glossary, written for Otos, maps Estonian forms to English. To keep it independent of the
52 test queries, its vocabulary is Vision's 1,303 scene-label names, the words search
already reads photos with, not the test's. Each name gets its Estonian nominative and
genitive (965 readings), plus 24 case endings. Two forms first written in were taken out
because the test could have suggested them ("siluett" under cityscape, a plural under
pumpkin). A typed word is read when forms cover it end to end, the last followed by nothing
or one case ending. Words the glossary lacks stay as typed.

| Reading of the 52 Estonian queries | Full precision (bake-off) | The app, Core ML int8, catalog | The app, thumbnails |
| --- | --- | --- | --- |
| English (ceiling) | 84.7 | | |
| As typed | 50.1 | 49.3 | 51.6 |
| Glossary, unread words as typed | 70.4 | 69.4 | 68.9 |
| Glossary, unread words dropped | 66.3 | | |
| Glossary fused with as typed | 64.5 | | |
| Glossary with the common words | | 77.2 | 77.5 |
| … and "ratas", "müts" in their everyday sense | | 80.2 | 80.7 |

The app's column is the encoder itself (a user whose languages are Estonian and English). It
glosses 45 of the 52 queries: 7 hold no word the glossary reads ("vanaauto", "kõrvitsapõld"),
or are words English spells ("rand", "sushi").

NaturalLanguage recognised 22 of the Estonian queries as English. Its English probability does
not separate them: "owl" 0.38, "lilled" (flowers) 0.99. English spelling does. Unified
checking (`checkString`) identifies the language itself and passed "koer" and "bassein" on a
Mac with several spelling languages. `checkSpelling(of:language: "en")` passed "seas",
"tools", "selfie" and "screenshot", and rejected "lennuk", "hobune" and "koer". Of the
glossary's forms, 92 are English words ("tool", chair; "sea", pig's genitive; "seen",
mushroom), so a query recognised as English is glossed only when spelling also rejects a word
of it. No English query among the 52 is glossed, and neither are the other languages'
readings for that user.

The 204 facts queries, through the same encoder: precision@10 0.832 → 0.843, Estonian 56 → 78,
no other language lower (en 91, fi 92, de 87, sv 78).

A second pass added about 150 common words of a photo search that are not scene labels:
people, colours, qualities, places, times of day and year, and actions with their verb forms
(the -v participle, the third person, -mas, -mine: "magav", "magab", "magamas" sleeping).
The list was written as a general vocabulary. Four words first written in came from the test
queries rather than from it (crayon, menu, selfie, skyline) and were taken out before
measuring; the rest still overlaps the test where a test query uses an everyday word ("old",
"red", "field"), so the gain is an upper bound for words outside the list. Through the app's
encoder: 50 of 52 queries glossed, recall@10 69 → 77 (English 85). Facts: 0.843 → 0.847,
Estonian 78 → 86. English, Finnish, Swedish and German queries for an Estonian user read as
before; none of the 52 English queries is glossed.

A third pass compared each Estonian query with its English one. The gap sat in four queries.
Two were mistranslations: "ratas" meant wheel before bicycle, though "rattaga sõitma" is
riding a bike; and "müts" meant beanie, though it is the general word for hat. Both now list
the everyday sense first: recall@10 77 → 80 (catalog 80.2, thumbnails 80.7); facts unchanged,
0.847. These two were found on the test queries themselves, so they are fitted to it. The other
two stay: "rand" typed alone is spelled as English and read as English, the right reading
when English is a user's language too; "südame joonistus liivas" already reads "heart
drawing sand".

Every language through the app's encoder, each as its own speaker types it (their language
and English as search languages), on the installed catalog's thumbnails: en 84.6, fi 73.8,
sv 75.0, de 78.1, fr 80.4, es 81.4, it 82.8, nl 76.7, pl 79.7, ru 81.1, ja 76.4, zh 79.4,
ko 72.0, ar 81.4, hi 79.5, tr 76.0, et 80.7. Estonian, through the glossary, is above the mean
of the 15 translated languages, 78.3. The run turned up two queries left with no picture.
Swedish "tåg" (train) translates "march" in lower case, and the parser read it as the month;
Translation capitalises every month it does translate ("i maj" → "in May", "toukokuu" →
"May"), so a translated month is now only a capitalised name, which also reads Finnish
"toukokuu" as May where "May" alone had been skipped. Turkish "at" (horse), recognised as
English, was trimmed as a joining word; joining words now go only beside a fact taken out.
Facts unchanged at 0.847.

### Translating a query as a photo's caption

The weakest languages lost on lone words Translation reads without context: Korean "눈"
(snow) → "an eye", "호수" (lake) → "the number of houses", "초밥" → "vinegared fish and
rice"; Finnish "vene" (boat) → "Veins", "kurpitsat" (pumpkins) → "zucchini"; Swedish "pumpor"
→ "pumps", "tåg" → "march"; Dutch "meer" (lake) → "more"; Turkish "atlıkarınca" (carousel) →
"horse ant". Framed as a caption in the language's own word for a photo, most read right:
"사진: 호수" → "Photo: Lake", "foto: tåg" → "photo: train", "kuva: kurpitsat" → "picture:
pumpkins", "写真：馬" → "Photo: horse"; "사진: 눈" still reads "Photo: Eyes". In every one of
Translation's 24 languages, the caption's word comes back as "photo", "picture" or "image" with
a colon, and is taken off.

| Through the app, recall@10 | en | fi | sv | de | fr | es | it | nl | pl | ru | ja | zh | ko | ar | hi | tr | mean of 15 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| As typed into Translation | 84.6 | 73.8 | 75.0 | 78.1 | 80.4 | 81.4 | 82.8 | 76.7 | 79.7 | 81.1 | 76.4 | 79.4 | 72.0 | 81.4 | 79.5 | 76.0 | 78.3 |
| As a photo's caption | 84.6 | 80.5 | 82.4 | 78.9 | 82.1 | 80.9 | 83.4 | 76.5 | 83.4 | 81.1 | 78.0 | 81.3 | 78.3 | 83.0 | 82.0 | 76.2 | 80.5 |

Facts precision@10 rose from 0.847 to 0.855. Russian now places "Уолнат-Крик" and Japanese
"シャスタ山"; Italian, Russian and Japanese facts each fell by one query of about 12, a picture
ranking moved by a reworded reading ("Beach" → "beach").

### The surfaces, in a window

With computer-use access denied, the search surfaces were driven in-process. `ContentView`,
hosted in a titled window with its toolbar bridged, takes "dog" typed into the toolbar's
`NSSearchField` through its field editor into the view model's search, and Edit ▸ Find's intent
puts the keyboard in the field (`SearchFieldWindowTests`). The window's frame drawn in-process
shows the search item at the toolbar's trailing end, collapsed to its magnifier while empty in
a 1,100-point window and expanded with its clear button while holding a query; the Settings row
and the empty states were drawn in light and dark, and one in grayscale.

### The app with all of it

The dev build re-read its catalog with labels (14,885 assets) and the text of its 2,002
previews (978 with text), at about 15 and 7 a second. Its own stored data through the
shipped encoder, each language's user also listing English, over the photos it holds:
recall@10 83 in English and 75.3 across 16 other languages (§8's app: 82 / 74.4). Its catalog
holds a fifth of the installed catalog's previews, so word queries are measured above, on the
installed catalog's previews.

## Sources

- Immich per-language benchmark and model guidance: <https://docs.immich.app/features/searching>
- Immich smart search source: `server/src/controllers/search.controller.ts`,
  `server/src/repositories/search.repository.ts`, `server/src/services/smart-info.service.ts`
  (<https://github.com/immich-app/immich>)
- Ente: <https://github.com/ente-io/ente> (`rust/crates/ml/src/assets.rs`, web
  `services/ml/clip.ts`); <https://ente.com/ml/>
- SigLIP 2: <https://arxiv.org/abs/2502.14786>; Core ML port
  <https://huggingface.co/palmier-io/siglip2-base-coreml>
- mSigLIP i18n: <https://huggingface.co/timm/ViT-B-16-SigLIP-i18n-256>
- XLM-R CLIP: <https://huggingface.co/laion/CLIP-ViT-B-32-xlm-roberta-base-laion5B-s13B-b90k>
- NLLB-CLIP: <https://huggingface.co/visheratin/nllb-clip-base-siglip>
- MobileCLIP and MobileCLIP2: <https://github.com/apple/ml-mobileclip>,
  <https://arxiv.org/abs/2508.20691>, <https://huggingface.co/apple/coreml-mobileclip>
- MetaCLIP 2: <https://github.com/facebookresearch/MetaCLIP>
- Perception Encoder: <https://arxiv.org/abs/2504.13181>
- jina-clip-v2: <https://huggingface.co/jinaai/jina-clip-v2>
- FG-CLIP 2: <https://arxiv.org/abs/2510.10921>
- RAM++: <https://arxiv.org/abs/2310.15200>
- Florence-2: <https://huggingface.co/microsoft/Florence-2-base>
- SmolVLM: <https://arxiv.org/abs/2504.05299>
- FastVLM: <https://github.com/apple/ml-fastvlm>
- Qwen3.5-0.8B: <https://huggingface.co/Qwen/Qwen3.5-0.8B>
- LFM2.5-VL: <https://huggingface.co/LiquidAI/LFM2.5-VL-450M>
- Gemma 4 E2B: <https://huggingface.co/google/gemma-4-E2B-it>
- Foundation Models image input: <https://developer.apple.com/videos/play/wwdc2026/241/>
- Vision classification: <https://developer.apple.com/documentation/vision/classifying-images-for-categorization-and-search>
- Core Spotlight semantic search reports: <https://developer.apple.com/forums/thread/793867>,
  <https://developer.apple.com/forums/thread/767355>
- sqlite-vec: <https://github.com/asg017/sqlite-vec/releases>
- Reciprocal rank fusion: <https://plg.uwaterloo.ca/~gvcormac/cormacksigir09-rrf.pdf>
- Lightroom 2026-04 search: <https://www.lightroomqueen.com/whats-new-in-lightroom-2026-04/>
- digiKam 8.6: <https://www.digikam.org/news/2025-03-15-8.6.0_release_announcement/>;
  CLIP request <https://bugs.kde.org/show_bug.cgi?id=515936>
- Google Ask Photos: <https://blog.google/products/photos/ask-photos-google-io-2024/>
- Video frame sampling: <https://arxiv.org/abs/2408.03340>
- Distilled multilingual CLIP: <https://huggingface.co/sentence-transformers/clip-ViT-B-32-multilingual-v1>
- Apple Translation: <https://developer.apple.com/documentation/translation/translationsession>
