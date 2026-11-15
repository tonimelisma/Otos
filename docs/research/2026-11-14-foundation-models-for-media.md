# Foundation models over the library: descriptions, and what they make possible

Date: 2026-11-14. A survey for the owner's question: what could Otos do with foundation
models over its photos and videos, and could the facts Otos already holds (people, places,
dates, text, labels, embeddings) feed a model that writes an English description of each
photo? What would that description be used for? It reads Apple's WWDC26 sessions, shipping
products (Google Photos, Apple Photos, Lightroom, PhotoPrism, LibrePhotos, Immich, Ente) and
2026 research papers. No code or behavior changed in this pass, and nothing here is a
decision. Tags: **[measured]** Otos's own probes (from `2026-11-09-keyword-search.md`),
**[source]** a primary source, **[press]** secondary reporting, **[untested]** an idea this
pass did not try.

## Summary

- **Yes, a grounded description is buildable on the Mac today, with no download.**
  macOS 27's Foundation Models framework takes an image in a prompt (`Attachment(…)` with
  `CGImage`, `NSImage`, `CVPixelBuffer` or a file URL) on the on-device model, with an
  8,192-token context **[source: WWDC26 241]**. Otos measured about 2.4 s a photo warm,
  9.7 s cold, English only **[measured]**: about 13 hours for the owner's ~19,400 assets as
  background enrichment. LibrePhotos ships the same idea with LFM2.5-VL-450M (about 370 MB,
  under a second a photo on a recent CPU) and feeds the model the recognised people's names
  and the reverse-geocoded place **[source]**.
- **English-only output is not the obstacle it was for search.** Otos already translates
  every query to English before it embeds it (ADR 0048). An English description sits in the
  same language as the translated query, so a plain English full-text index over
  descriptions avoids the Finnish inflection problem that ruled captions out as a search
  index in `2026-11-09-keyword-search.md` §4.
- **The description should not bake in mutable facts.** People are renamed and reassigned,
  and place names change with the Mac's language; a description that says "Max" goes stale
  the moment Max is renamed, and re-describing costs 2.4 s a photo. The blank-slate shape is
  a **visual description written against face slots** ("[P1] holds a fish beside [P2] on a
  jetty") plus Otos's own facts composed when it is read **[untested]**. LibrePhotos bakes
  names into the text; it has no rename story in its docs.
- **The strongest uses, in the order the evidence supports them:**
  1. **Search that knows who and what together.** "Max holding a fish", "kids on the jetty
     at the cottage": SigLIP finds the scene but cannot know names; the face filter knows
     names but not the scene. A description, or a filter + embedding combination, answers
     both.
  2. **Questions answered from the catalog by an agent.** "When did we last go to Lapland?",
     "how many times did we visit Grandma in 2024?". 2026 papers show the winning shape is a
     model that calls metadata filters and search as tools, not one that reads captions
     (§4).
  3. **Accessibility text** for every tile and the loupe (VoiceOver).
  4. **Titles and summaries** for On This Day stories, trips and events.
  5. **Exported files carrying a description** in their own metadata (export writes new
     files, so this never touches an original).
  6. **Natural-language editing** that sets RAW9 controls, as Lightroom's Prompt to Edit
     does.
  7. **Video scenes**: per-scene descriptions with timestamps, searchable to the moment.

## 1. What Apple provides on macOS 27

- **Foundation Models, image input** **[source: WWDC26 241, 102]**: an attachment in the
  prompt builder beside text; any size and aspect ratio; a larger image costs more tokens
  and time (one developer measured about 323 input tokens for one photo **[press]**). The
  on-device `SystemLanguageModel.contextSize` printed 8,192 in the session. Apple's demos:
  answering questions about a photo, caption generation, a recipe from a fridge photo, a
  file name from an image (the `fm` command-line tool). Guided generation (`@Generable`)
  returns typed Swift values, so a description can come back as a struct, not prose to
  parse.
- **Vision as Foundation Models tools** **[source: WWDC26 237]**: an OCR tool (over 30
  languages) and a barcode reader the model can call; tool arguments can be images
  (`ImageReference`).
- **New Vision requests** **[source: WWDC26 237]**: `GenerateIterativeSegmentationRequest`
  (tap or lasso to a mask, downloaded model) and `GenerateObjectnessBasedSaliencyImageRequest`
  (salient-object rectangles).
- **Private Cloud Compute model** **[source: WWDC26 241]**: 32,000-token context, needs an
  entitlement. It is off the device, which the owner's search decision ruled out (memory
  `search-quality-is-my-call`: on-device only).
- **Limits already measured** **[measured]**: Finnish is not in `supportedLanguages`, and a
  request for Finnish keywords returned English; the `.contentTagging` use case with an image
  failed (`ModelManagerError 1001`). The model changes when the user updates macOS, so a
  description needs the model's identity stored beside it, as `extractionRevision` is for
  MediaMetadata.

## 2. What others ship

| Product | What the model does with media | Where it runs | Source |
| --- | --- | --- | --- |
| **Google Photos, Ask Photos** | Natural-language questions over the library (Gemini): content, people tagged by the user, where and when; writes personalised captions to share | Cloud | Google blog **[source]**; quality complaints and a rollback to classic search **[press]** |
| **Apple Photos** | Natural-language search including scenes inside videos; a Memory movie from a typed description ("my cat in 2024"); Clean Up; iOS 27 adds Reframe and Expand **[press]** | On device | MacRumors, iGeeks **[press]** |
| **Lightroom (2026)** | Assisted Culling out of beta (per-person eyes open and sharp, groups similar shots and suggests the best, a strength dial); natural-language search (Lightroom desktop, cloud); Prompt to Edit; generative expand and upscale | Mostly cloud | PetaPixel, PhotoshopCAFE **[press]** |
| **LibrePhotos** | A caption per photo from LFM2.5-VL-450M, prompted with recognised names ("phrased as a friend would") and the place; each fact a user toggle; captions are searched; manual captions never overwritten | Local CPU | LibrePhotos docs **[source]** |
| **PhotoPrism** | Captions and labels from any Ollama or OpenAI vision model, configured per output; a model honoured the caption language but returned English labels; reasoning models leaked thoughts into captions | Local server (GPU advised) or cloud | PhotoPrism docs **[source]** |
| **Immich, Ente** | CLIP-family embedding search, faces, OCR (Immich 2.2), memories; no VLM descriptions found | Server / on device | release notes **[source]** |

The pattern across the shipping products: embeddings for search, a VLM caption as a second
signal and a human-readable artefact, and the user's own facts (names, place) given to the
model as context rather than inferred by it. Google's experience is the warning: an
LLM-first search replaced a working index and users preferred the old one.

## 3. A grounded description for Otos

### What Otos can give the model

Everything below is already in the catalog (ADRs 0047–0051):

| Fact | Owner | Use in the prompt |
| --- | --- | --- |
| Faces with boxes, assigned to people | ADR 0047 | Label each box as a slot ("P1 is the face at left") so the model says who does what without guessing identity |
| Place name of the map cell | ADR 0051 | Context ("taken in Kuopio"), not to be described from pixels |
| Capture local time | MediaMetadata | Season, time of day, "a birthday" if the date is the person's birthday (not held today) |
| Text read in the photo | ADR 0050 | Grounding for signs, menus, documents |
| Vision scene labels | ADR 0050 | Grounding, and a check against hallucination |
| Stack / burst membership | ADR 0052 | Describe once per burst, not per frame |

### The shape that survives renames

1. **Visual description, with slots.** The prompt passes the image, the face slots and the
   stable facts (text read, labels). Guided generation returns a typed value, for example
   `{ summary: "[P1] holds a large fish beside [P2] on a wooden jetty at a lake",
   subjects: [...], setting: "lake, summer evening", activity: "fishing" }` **[untested]**.
   It is stored with the model's identity and the inputs it read, and redone only when one of
   those changes (MetadataRefresher's rule).
2. **Composed when read.** Slots become the people's current names; the place name and date
   are added from the catalog in the reader's language. A rename or a reassignment costs
   nothing.
3. **Translated for display** with Apple Translation when the Mac is not in English (the
   same installed-pack rule as search); the stored text stays English.

Whether the on-device model reliably uses slot tokens is the first thing a probe must
measure. The fallback is LibrePhotos' shape (names in the prompt, re-describe on rename),
which costs a re-description per affected photo.

### Cost and placement

- 2.4 s warm per photo **[measured]**: a background enrichment kind, below faces and search
  embeddings, never on the main actor, read from the stored preview (as faces and search
  read it) so it never materialises an original.
- Foundation Models schedules its own hardware; whether it competes with Otos's CPU-only
  Core ML (ADR 0045) under load is unmeasured.
- A bake-off against LFM2.5-VL-450M (within the ~500 MB model bound; English output is
  enough here) would settle speed and quality; that one would need an ADR (third-party
  model) and Core ML conversion.

### Risks

- **Hallucinated facts.** A description states things a user may read as true ("at a
  wedding"). DES-level rule needed: a generated description is marked as generated.
- **Wrong person.** A face mis-assignment becomes a confident sentence. Composing names at
  read time at least makes the fix (reassign) correct the sentence at once.
- **Guardrail refusals and silence.** The on-device model refuses some content; a refusal
  is not a description and must not be stored as one (ADR 0032 rule 4).
- **OS updates change the model.** Stored model identity makes old descriptions detectable;
  whether to redo them is a cost question (13 h for the library).

## 4. What a description, and the model, can then be used for

### Search
- **Hybrid ranking**: an English FTS5 index over descriptions beside SigLIP embeddings,
  fused (reciprocal rank fusion is the usual choice). The 52-query bake-off set in
  `2026-11-09-keyword-search.md` is the oracle: does fusion raise recall@10 above 82%?
  **[untested]**
- **People and scene together**: "Max fishing" = person filter ∩ "fishing" in the
  description, or person filter ∩ SigLIP ranking without any description at all. The second
  needs no model and should be measured first.
- **Video moments**: describe sampled frames per scene and keep timestamps, so a search
  lands on the second, as Apple Photos does **[press]**.

### Questions about the library
- *Camera Roll VQA* (arXiv 2606.05275, 2026) **[source]**: 50 users, 31,476 photos, 2,500
  questions. An agent with tools (semantic search, BM25 grep, metadata list by time and
  place, get, and a pixel `view` limited to 5 calls) beat stuffing every caption into the
  prompt (70.5% against 63.4% multiple-choice) at about 3.2k tokens against 150k. It stores
  a caption, timestamp, location and event id per photo in SQLite with FTS5.
- *PhotoBench* (arXiv 2603.01493) **[source]**: embedding-only retrieval fails on
  location-based queries; an agent that filters on metadata succeeds.
- For Otos: Foundation Models' tool calling over the catalog's own owners ("photos of P in
  place X between dates", "count by year") answers "when did we last…" and "how many
  times…" from facts, with descriptions as one tool among several. The 8,192-token context
  makes the tool shape mandatory, not optional.

### Presentation
- **Accessibility labels** for tiles and the loupe, from the composed description.
- **Story and event titles**: On This Day cards and trips ("Summer at the cottage, 2019")
  from a handful of descriptions plus place and date.
- **Info pane**: the description beside the text and labels it already shows (ADR 0050).

### Files the user asks for
- **Export metadata**: the composed description into the exported file's caption field
  (XMP `dc:description` / IPTC caption). Export writes new files only, so originals stay
  untouched; whether names go out with the file is a privacy choice.
- **File names on export or reorganisation** from a description, as Apple's `fm` demo does.

### Editing
- **Prompt to edit**: guided generation can return a typed RAW9 adjustment set from "warmer,
  lift the shadows, less contrast", which the edit recipe (ADR 0036) then applies like any
  slider change. One user action, one owner intent: the text only produces values.
- **Assisted culling**: Lightroom's per-person eyes-open check is Vision face-quality work,
  not a language model; Otos's bursts (ADR 0052) are where it would apply.

### Not worth it here
- **Keyword tags from the model**: Vision's calibrated labels already exist; the model's
  free tags are slower and uncalibrated.
- **Generative edits (expand, remove)**: they write pixels Otos did not capture; outside
  the RAW9-first editing scope.

## 5. Open product questions (for the owner)

1. Which of §4's uses matter to you; descriptions are only worth 13 hours of background work
   if a surface reads them.
2. Should a generated description be visible (Info pane) and editable, or only feed search
   and accessibility?
3. May names leave the Mac inside an exported file's description?
4. Video scenes: frames only, or also speech? Transcribing a video's speech reads its audio
   track, which brushes against the no-audio rule; frames alone stay clear of it.
5. On-device only, as for search, or is Private Cloud Compute acceptable for anything?

## 6. Next measurements, in order

1. Person filter ∩ SigLIP ranking on the bake-off queries that name people: no model.
2. Foundation Models probe on 200 of the owner's photos: slot-token reliability,
   hallucination rate against the scene labels, refusals, time warm and under enrichment.
3. Hybrid FTS5 + SigLIP recall@10 on the 52-query set.
4. If 2 is too slow or too loose: LFM2.5-VL-450M through Core ML on the CPU, same set.

## Sources

- Apple, *What's new in the Foundation Models framework*, WWDC26 session 241:
  https://developer.apple.com/videos/play/wwdc2026/241/
- Apple, *What's new in image understanding*, WWDC26 session 237:
  https://developer.apple.com/videos/play/wwdc2026/237/
- Apple, *Platforms State of the Union*, WWDC26: https://developer.apple.com/videos/play/wwdc2026/102/
- Apple, *Foundation Models framework*: https://developer.apple.com/foundation-models-framework/
- I. Magda, *Foundation Models, year two*: https://ivanmagda.dev/posts/wwdc26-foundation-models-year-two/
- Google, *Ask Photos*: https://blog.google/products-and-platforms/products/photos/ask-photos-google-io-2024/
- PhoneArena, *Gemini broke Google Photos search*: https://www.phonearena.com/news/Gemini-broke-Google-Photos-search-and-users-arent-happy_id180791
- MacRumors, *Apple Intelligence*: https://www.macrumors.com/roundup/apple-intelligence/
- iGeeks Blog, *iOS 27 Photos*: https://www.igeeksblog.com/ios-27-photos-app-new-ai-editing-tools-clean-up/
- PetaPixel, *Lightroom updates*, 2026-04-16: https://petapixel.com/2026/04/16/adobe-lightroom-updates-brings-faster-ai-workflows-and-new-tools/
- PhotoshopCAFE, *Lightroom Classic June 2026*: https://photoshopcafe.com/lightroom-classic-update-deep-dive-whats-new-and-what-actually-matters-june-2026/
- LibrePhotos, *Image captioning*: https://docs.librephotos.com/docs/user-guide/image-captioning/
- PhotoPrism, *Using AI models* and *Caption generation*: https://docs.photoprism.app/user-guide/ai/ ,
  https://docs.photoprism.app/developer-guide/vision/caption-generation/
- Immich, *2.2 OCR search*: https://linuxiac.com/immich-2-2-released-with-ocr-search-faster-web-layouts/
- *Personal AI Agent for Camera Roll VQA*, arXiv 2606.05275: https://arxiv.org/html/2606.05275
- *PhotoBench*, arXiv 2603.01493: https://arxiv.org/html/2603.01493
- *PhotoCraft*, arXiv 2606.03099: https://arxiv.org/html/2606.03099
- *Inserting Faces inside Captions*, arXiv 2405.02305: https://arxiv.org/pdf/2405.02305
- Liquid AI, *LFM3-VL-2B*: https://huggingface.co/LiquidAI/LFM3-VL-2B
