# Keyword search: which models and mechanisms could find "dog on the beach" in the library

Date: 2026-11-09. Question: how could Otos let the owner type a word or a phrase, in Finnish or
English, and get the photos and videos that show it? Which current models can do it under about
500 MB, and what does Apple already provide?

**Answer:** search by a contrastive image–text embedding (the CLIP family) is the only approach
that finds long-tail phrases. Apple provides no such embedding, so it needs a model of Otos's
own. Two Apple APIs complement it at no download cost: Vision's 1,303-label scene classifier and
Vision's text recognition, which reads Finnish. The model is not chosen here. Finnish quality
separates the candidates more than anything else does, and only the published Crossmodal-3600
numbers measure it so far. The next step is a measured bake-off on the owner's own photos with
Finnish and English queries (section 7), as the face-recognition research did.

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

**What the table says:**
- **Finnish is decided by the text tower.** The models that do well on Finnish carry a large
  multilingual text encoder (NLLB, XLM-R, mSigLIP's 250k vocabulary). Its token-embedding table
  is most of the download. SigLIP 2 is multilingual in name, but at B size it scores 40 on
  Finnish against 66 on Swedish.
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

## 7. What must be measured before an ADR

The published numbers cannot decide this. Crossmodal-3600 captions are not the owner's queries,
and none of the candidates has Finnish numbers on photos like the owner's. The face research
showed that a measured run on the owner's library can overturn the published ranking.

1. **A query set** of about 50 queries the owner would actually type, each in Finnish and in
   English ("sauna", "lumiukko", "syntymäpäiväkakku", "koira rannalla", "Lapland", "boat"),
   with the relevant photos labelled among a few thousand of the owner's assets.
2. **Candidates:**
   - NLLB-CLIP base, the Finnish ceiling;
   - mSigLIP B/16 i18n and XLM-R B/32, permissive multilingual;
   - SigLIP 2 B/16, the only one with a Core ML port;
   - MobileCLIP2-S2 or v1 S2 with Finnish queries translated by Apple Translation, the smallest.

   Vision tags with a Finnish table are a baseline.
3. **Metrics:**
   - recall at 10 and 50 per query and language;
   - precision at each candidate's best single cutoff;
   - drift from fp32 after 8-bit weights (memory `core-ml-in-otos`: half precision shifted
     FocalNet's top choice 3.6% of the time);
   - per-image time on the CPU from the stored 2560 px preview.
4. **Size:** whether vocabulary trimming brings a multilingual text tower under 100 MB per file
   with no change in Finnish results.

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
