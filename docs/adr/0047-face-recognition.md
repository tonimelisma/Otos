# ADR 0047: Face recognition with Vision detection and AdaFace IR-101

## Status

Accepted, 2026-11-10. The model, precision and face-admission rules are decided on measured
evidence (`docs/research/2026-11-07-face-recognition-models.md`).

Built: detection, the analyser and the model (#593), faces as a stored enrichment product
(#601), the stored acts, the people and the grouping policy (#604), faces for Immich
accounts from their stored previews (`PreviewFaceReader`, #605), and People itself: the
list, a person's scope and the review (`docs/design/people.md`), published by
`PeopleProjection`, with every act one `PeopleAct` that `CatalogStore.perform` applies in
one transaction and returns the record that undoes it.

## Context

The owner wants the people in their photos found and named. The hard case is their own
children across years: a child's face changes a great deal from one year to the next, and
siblings at the same age can look more alike to a model than one child does to themselves a
few years later.

**No Apple API is enough.** Apple Vision detects faces, landmarks and capture quality, but has
no public API that returns a face embedding. Photos' own people recognition is not available
to other apps. Recognition therefore needs a face-embedding model of Otos's own.

**Owner decisions (2026-11-07):**
- Otos is non-commercial, so non-commercial model licences are acceptable.
- Downloading dataless originals for face analysis is approved.
- A model of about 250 MB is acceptable if it gets great results.

**Measured** on 5,810 of the owner's photos from 2012–2026, against 2,196 faces of 33 people
that the owner labelled, including 744 faces of the three children
(`docs/research/2026-11-07-face-recognition-models.md`):

| Candidate | Children's faces matched to the wrong child | Hard child faces found (of 42) | int8 size |
| --- | --- | --- | --- |
| AdaFace IR-101 (WebFace12M) | **0** | **42** | 66 MB |
| AdaFace IR-50 (WebFace4M) | 2 | 32 | 44 MB |
| ArcFace R100 (Glint360K) | 3, one accepted | 35 | 66 MB |
| ArcFace R50 (WebFace600K) | 1 | 37 | 44 MB |

Every wrong first choice on a child, by any model, was a sibling. Hard faces are those no
grouping had put with the right child.

**Two further measurements shape the design:**
- **Years:** every model accepts fewer than a third of a child's face pairs three or more years
  apart.
- **Siblings:** about 3–4% of same-age sibling pairs clear every model's single-pair threshold.

## Decision

### Detection and admission

- **Detector:** Apple Vision's face landmarks and face capture quality, run on the original at
  full resolution.
- **Admission:** a face is embedded only when all of these hold:
  - **Quality:** Vision's capture quality is at least 0.3.
  - **Alignment:** the face box height in pixels times the alignment scale is between 50 and
    150. Below that, Vision's landmarks were spread over the scene, and the crop is not a face
    (59 of 3,293 measured faces).
- **Alignment:** a least-squares similarity transform from five Vision points to the ArcFace
  112 × 112 template. The points are the eye centres, the lowest nose-crest point, and the
  outer-lip corners.
- **Opaque crop:** the area of the crop outside the photo is filled with one fixed colour before
  the model sees it. A crop with transparent pixels embeds differently depending on how it is
  read (cosine as low as 0.92 against the same crop read another way).

### The model

- **Model:** AdaFace IR-101 trained on WebFace12M (CVLFace weights), converted to Core ML.
- **Input and output:** a 112 × 112 RGB image, with normalisation folded into the input, and a
  unit-length 512-d embedding.
- **Weights:** linear symmetric per-channel 8-bit weights, 66 MB, shipped as an `.mlpackage` in
  `Otos/Resources` like the models of ADR 0045.
  - **Why int8:** against fp32 it changed one decision of 2,196 (an adult's face left
    unassigned, not a wrong match), and none on a child's face.
  - **Why not fp16:** 131 MB, which exceeds GitHub's 100 MB per-file limit.
- **Engine:** the CPU only, the same as ADR 0045. 33 ms a face, against about 1.5 s to decode
  the original it comes from.
- **Model revision:** a revision number (`FaceAnalyzer.revision`) that names the model, Vision's
  revision and the admission rules, stored with each face. A new revision ships with a migration
  that clears every faces stamp, as metadata's revision changes do, so the claim stays a pure
  stamp predicate and every still is read again.

### Storage

- **The `face` table:** a catalog table, keyed by the asset's path, with `ON UPDATE CASCADE`
  and `ON DELETE CASCADE`. A move carries an asset's faces, including witnessed moves (ADR
  0034), and the overlay lifecycle of ADR 0008 purges them with the asset.
- **A face row** holds:
  - the face box and the five landmarks, as fractions of the upright photo;
  - the quality;
  - the embedding, as 512 little-endian Float32 values;
  - the analysis revision that read it.

  The person a face is assigned or confirmed to comes with grouping.
- **The faces stamp** is on the asset (`faces_source_size`, `faces_source_mtime`): the
  `(size, mtime)` the reading was made from, a product of its own in ADR 0009's sense. A reading
  replaces every face of its asset, and a still with no face has the stamp and no rows, so it is
  not read again until it changes.
- **The claim:** only a fixed library's rows owe faces, under their own claim
  (`EnrichmentClaim.library`) and its own pair of partial indexes. A card's or camera's rows are
  read for faces once imported into a library, which is where their overlay lives on.
- **People** are catalog rows: a name, an optional birthday, and a stable row ID. A person is
  not a media asset, so this is not an asset identity, which stays the path. A person is the set
  of their confirmed faces, each with its capture date. No average face is stored.
- **Media folders:** nothing is written to them. Names exist only in the catalog. Otos never
  reads or writes face regions in files' XMP, and export writes no names (owner decision,
  2026-11-10).

### Grouping

- **Comparison:** every new face against the confirmed faces, by exact cosine with Accelerate.
  For a person who was an adult (18 or older) on the face's date, all their confirmed faces
  count; otherwise, and whenever the age is unknown, only those within two years. Measured: an
  adult's face pairs ten or more years apart still reach the threshold 84% of the time, a
  child's six or more years apart 5%, and dropping the window gave adults full coverage with no
  wrong match, while for children it added two sibling first choices (owner question,
  2026-11-10). No index and no vector database: a
  family library holds tens of thousands of faces.
- **Acceptance:** a suggestion is made only when the best person reaches the threshold and beats
  the second-best person by a margin: threshold 0.434 (0.1% of different-person pairs
  accepted), margin 0.08, faces compared within ± 2 years. Measured by simulating the review
  on the owner's labels: every child face reached, 9 wrong suggestions out of 521 (research
  note, section 8).
- **Hard rules:**
  - Two faces in one photo are never the same person.
  - A face from before a person's birthday is never theirs. A birthday may be only a year,
    which counts from 1 January (owner decision, 2026-11-10).
- **Years:** a child across three or more years is reached by chaining through the years between
  them. Chained matches are suggestions that the user confirms, never automatic assignments.
- **Unsure faces:** a face whose best person reaches the threshold but whose runner-up is within
  the margin is not a suggestion. It is an *unsure* face, offered in a list of its own
  with both candidates and no answer (owner decision, 2026-11-10; `docs/design/people.md`).
- **Unnamed groups:** faces that match no person are grouped among themselves, so a library with
  nobody named yet gets something to name. Each face keeps its ten strongest links of 0.65 or
  more, joined strongest first, never two faces of one photo; hierarchical linkage was as pure
  but cannot hold a large library's pairs in memory, and ten links per face give the same
  groups as all of them (measured: 102 groups, 1,983 faces, none wrong), at a cost that grows
  with the faces rather than their pairs. A group is offered only when its faces come from at least two different days, so a
  stranger caught once never enters the review (owner decision).
- **What the user's acts store** (overlay, ADR 0008; undoable):
  - a confirmed face's person;
  - a rejection, `Not Sam`, as a (face, person) exclusion, so the same suggestion never
    returns;
  - `Not a Face`, which takes a detection out of People until the photo's file changes;
  - an ignored unnamed group, whose faces are never grouped or suggested again.

  Removing a person returns their faces to the review as unnamed and forgets their
  rejections. A person's name is optional: a split creates an unnamed person, named later
  (owner decision).
- **Immich accounts:** their photos are read for faces from the stored Immich preview, never
  the original (measured in the research note, section 7: no wrong match, about 7% of small
  faces missed). Their originals are downloaded only for the user's own work (ADR 0046).

### Work and placement

- **Owner:** face analysis is an enrichment product, run by `EnrichmentCoordinator`'s workers.
- **Downloads:** for a dataless original, the download goes through
  `MaterializationCoordinator` at background priority, under the free-space floor (ADR 0027).
- **Rendering and threads:** faces come from the same read of the original as the rendering
  (`ImageRenderer.read(_:rendering:upright:)`), decoded a second time from those bytes, upright,
  at full resolution and with no edit. The model never runs on the main actor.
- **People UI:** a People sidebar entry, and a review of suggestions grouped by year with
  accept, merge and split. Its design spec (`docs/design/people.md`) comes before any code.

### Licences and attribution

- **Code:** CVLFace and AdaFace are MIT.
- **Weights:** the model card defers to the licence of the training dataset, WebFace260M, whose
  terms page could not be read on 2026-11-09 (the site's TLS certificate does not match its
  host). Otos accepts a non-commercial research licence (owner decision, 2026-11-07).
- **Shipping:** the converted weights ship in the private repository only.
- **Attribution:** the MIT text and the AdaFace citation (Kim, Jain and Liu, CVPR 2022) ship in
  `Otos/Resources/Licenses`. The conversion is stated there.

## Rejected alternatives

- **ArcFace R100:** it keeps a few more pairs three to five years apart above its threshold. But
  it accepted one wrong child and trails IR-101 on every same-age sibling measure. Its fp16
  conversion also drifts ten times more than AdaFace's on the Neural Engine.
- **ArcFace R50 and AdaFace IR-50:** each confused siblings, and IR-50 held back a quarter of the
  hard faces.
- **fp32 weights:** 261 MB, over the repository's file limit, and no better on any decision.
- **fp16 on the Neural Engine:** the most faithful variant (no decision changed), but 131 MB is
  over the file limit. The Neural Engine also departs from ADR 0045's CPU-only rule, and 33 ms a
  face on the CPU is already small.
- **Detecting on the stored preview:** detection on a 2048 px image lost no faces in run 1. But
  the crop the model sees would come from about a quarter of the original's pixels, and the
  owner approved downloading originals for this. Detection and embedding read the full
  resolution.
- **An average face per person:** a child's average across years matches neither the baby nor the
  school-age child. Confirmed faces, each with its date, keep each year's face.
- **A vector database or an approximate index:** exact comparison over a family's faces is cheap,
  and an index adds an owner and a staleness problem for no measured need.
- **Writing names into the user's files or sidecars:** forbidden by ADR 0008. Names are overlay.
- **Reading face regions from files' XMP (MWG):** never (owner decision, 2026-11-10).

## Consequences

- **Accuracy is checked on the owner's labels:** a change to the model, the analysis or the
  grouping rules runs `script/face-accuracy.sh` on the labelled set (research note §9) and
  reports its suggestions, wrong suggestions and unnamed groups against the last run.
- **App size:** the app grows by 66 MB.
- **Downloads and time:** analysing a library means downloading and decoding every original
  photo once: about 1.5 s a photo, mostly decode, in the background.
- **Model change:** a new model is a new revision that re-analyses every photo, and stored names
  carry over through the confirmed faces.
- **Precision of names:** names follow confirmations, so a wrong suggestion costs the user one
  rejection, never a wrong name applied silently.
- **Licence check:** WebFace260M's terms are recorded as unread. They are checked when the site
  is reachable, and again if Otos is ever distributed beyond its owner.
