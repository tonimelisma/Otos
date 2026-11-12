# ADR 0047: Face recognition with Vision detection and AdaFace IR-101

## Status

Accepted, 2026-11-10; assignment rewritten 2026-11-12, when the owner redesigned People
around auto-tagged faces; the person-admission rule and lapsed seeds added 2026-11-12, after
objects Vision took for faces became a person of their own. The model, precision and
face-admission rules are decided on measured evidence
(`docs/research/2026-11-07-face-recognition-models.md`,
`docs/research/2026-11-12-face-person-admission.md`); assignment on
`docs/research/2026-11-12-face-auto-assignment.md`.

Built: detection, the analyser and the model (#593), faces as a stored enrichment product
(#601), faces for Immich accounts from their stored previews (`PreviewFaceReader`, #605),
and People (`docs/design/people.md`): `PeopleAssignment` gives every face its person and
publishes the gallery, and every act of the user's is one `PeopleAct` that
`CatalogStore.perform` applies in one transaction, returning the record that undoes it.

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
  - **A person:** Vision's image classifier (`VNClassifyImageRequest`, revision 2), shown a
    square twice the face box, gives a person label (`people`, `adult`, `child`, `baby`,
    `teen` or `crowd`) a confidence of at least 0.2. Capture quality says how well a face was
    photographed, not whether it is one. Measured on the owner's catalog: every face the user
    named reads 0.28 or more, while lace, a bucket, a storefront and drawings that had passed
    every other rule read 0.01 to 0.13. Of the 2,196 labelled faces of the model bake-off, one
    reads under 0.2.
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
  revisions and the admission rules, stored with each face. A new revision ships with a
  migration that clears the faces stamp of every still whose faces it can change, as metadata's
  revision changes do, so the claim stays a pure stamp predicate. Revision 2 (the person rule)
  only turns more detections away, so it re-reads only stills that have a face.

### Storage

- **The `face` table:** a catalog table, keyed by the asset's path, with `ON UPDATE CASCADE`
  and `ON DELETE CASCADE`. A move carries an asset's faces, including witnessed moves (ADR
  0034), and the overlay lifecycle of ADR 0008 purges them with the asset.
- **A face row** holds:
  - the face box and the five landmarks, as fractions of the upright photo;
  - the quality;
  - the embedding, as 512 little-endian Float32 values;
  - the analysis revision that read it.

  Its person and whose word it is come with assignment.
- **The faces stamp** is on the asset (`faces_source_size`, `faces_source_mtime`): the
  `(size, mtime)` the reading was made from, a product of its own in ADR 0009's sense. A reading
  replaces every face of its asset, and a still with no face has the stamp and no rows, so it is
  not read again until it changes.
- **The claim:** only a fixed library's rows owe faces, under their own claim
  (`EnrichmentClaim.library`) and its own pair of partial indexes. A card's or camera's rows are
  read for faces once imported into a library, which is where their overlay lives on.
- **People** are catalog rows: an optional name, an optional birthday, a hidden mark, a
  favourite mark, and a stable row ID. A person is not a media asset, so this is not an asset
  identity, which stays the path. A person is the set of their faces, each with its capture
  date. No average face is stored.
- **Whose word a face's person is** (`face.assignment` beside `face.person_id`): none, Otos's
  guess, a seed (one of the faces a person was first found from), the user's, or held (the
  user removed the name). The user's faces and the seeds are the anchors; every guess is
  rebuilt from them. Also on the face: its likeness to its person (the likeness sort) and
  whether it is its person's key photo (`is_key_photo`), at most one per person.
- **Media folders:** nothing is written to them. Names exist only in the catalog. Otos never
  reads or writes face regions in files' XMP, and export writes no names (owner decision,
  2026-11-10).

### Assignment

`FaceAssignmentPolicy`, pure; `PeopleAssignment` runs it and writes what changed.

- **Every face gets its most likely person.** There is no review: a face shows the person it
  is assigned to wherever faces are shown (DES-111), and the user corrects what is wrong.
- **Reach:** a face is compared with each person's faces: all of them for a person who was an
  adult (18 or older) on the face's date, those within two years otherwise, and whenever the
  age is unknown. Measured: an adult's face pairs ten or more years apart still reach the
  threshold 84% of the time, a child's six or more years apart 5% (owner question, 2026-11-10).
  No index and no vector database: a family library holds tens of thousands of faces.
- **Chaining:** from the anchors, faces are given out strongest first, round by round. A face
  whose best person reaches the threshold (0.434, 0.1% of different-person pairs accepted)
  and beats the runner-up by the margin (0.16) joins that person and is evidence for the next
  round, which follows a child from year to year.
- **Close calls:** a face whose best person reaches the threshold but whose runner-up is within
  the margin goes to the best person — siblings are guessed too (owner decision, 2026-11-12)
  — but is evidence for nobody, so a guess between two siblings never carries one into the
  next year. Measured with one year seeded per person: 5 of 2,196 labelled faces given the
  wrong person, 1 of them a sibling; 224 of 225, 487 of 487 and 32 of 32 of the children's
  faces reached (research note, margin sweep).
- **New people:** faces left over are grouped among themselves: each keeps its ten strongest
  links of 0.65 or more, joined strongest first, never two faces of one photo. A group of
  faces from two or more days becomes a new, unnamed person seeded with them, and chaining
  runs again from scratch with the seeds as anchors. A face like no one, or seen on one day
  only, stays unidentified, so a stranger caught once never becomes a person.
- **Lapsed seeds:** a person the user said nothing about (no name, birthday, favourite, hidden
  mark or key photo, and no face on their word) keeps their seeds only while the seeds span two
  or more days, as a new person's must. When faces leave such a person (re-read under stricter
  admission, deleted, or moved by the user), the seeds left are Otos's to decide again, and the
  person is forgotten once no face is theirs. A person the user said anything about keeps
  their seeds.
- **Hard rules:**
  - Two faces in one photo are never the same person.
  - A face from before a person's birthday is never theirs. A birthday may be only a year,
    which counts from 1 January (owner decision, 2026-11-10).
  - A face the user said is not someone (`This Is Not Sam`, or `Not the Same Person` in an unnamed person's own photos) is held: Otos never gives it a person
    again, and never offers that person for it.
- **Corrections propagate:** a correction is a new anchor, and every guess is rebuilt from the
  anchors, so moving one face moves the guesses reached through it (owner decision,
  2026-11-12). From a cold start, ten moves left nothing wrong on the owner's
  labels.
- **Settles on its own output:** assignment reads only the anchors, so run on what it wrote it
  writes nothing. A pass that wrote is followed by one that publishes.
- **What the user's acts store** (overlay, ADR 0008; undoable): a face's person on their word;
  a held face and its rejection; `This Is Not a Face`, until the photo's file changes; a person's
  name, birthday, hidden and favourite marks and key photo. A person Otos found is
  deleted once no face is theirs and the user said nothing about them.
- **Immich accounts:** their photos are read for faces from the stored Immich preview, never
  the original (measured in the 2026-11-07 research note, section 7: no wrong match, about 7%
  of small faces missed). Their originals are downloaded only for the user's own work
  (ADR 0046).

### Work and placement

- **Owner:** face analysis is an enrichment product, run by `EnrichmentCoordinator`'s workers.
- **Downloads:** for a dataless original, the download goes through
  `MaterializationCoordinator` at background priority, under the free-space floor (ADR 0027).
- **Rendering and threads:** faces come from the same read of the original as the rendering
  (`ImageRenderer.read(_:rendering:upright:)`), decoded a second time from those bytes, upright,
  at full resolution and with no edit. The model never runs on the main actor.
- **Assignment:** `PeopleAssignment`'s loop, asked after every catalog change, reads every face
  in one transaction, assigns off its actor, and writes a guess only where the face is still
  Otos's to decide, so an act the user made meanwhile always wins.
- **People UI:** the People gallery, a person's photos as the leaf under it
  (`SidebarSelection.person`, so the sidebar keeps People highlighted and Back to People
  exists only there), the People filter, whose several people are photos of them together,
  the face acts in
  the photo menus and the Info pane (`docs/design/people.md`).

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
  school-age child. A person's faces, each with its date, keep each year's face.
- **A vector database or an approximate index:** exact comparison over a family's faces is cheap,
  and an index adds an owner and a staleness problem for no measured need.
- **A review to confirm every suggestion (2026-11-10 to 11-12):** it made the user confirm
  521 suggestions by hand to reach the children, and kept unnamed groups as a second kind of
  entry beside people. The owner rejected it: guesses are made, and corrected where wrong.
- **Chaining through every guess:** close calls carried as evidence put 7 to 10 siblings
  wrong (margins 0 to 0.12) against 1 at 0.16.
- **Keeping guesses once made (Immich's way):** a correction would then fix only the faces it
  names; rebuilding from the anchors makes it move the guesses chained through it.
- **Writing names into the user's files or sidecars:** forbidden by ADR 0008. Names are overlay.
- **Reading face regions from files' XMP (MWG):** never (owner decision, 2026-11-10).
- **AdaFace's feature norm as the admission rule:** AdaFace trains the length of its feature
  vector to track how recognisable a face is, and the shipped package can expose it without
  changing a weight. On the owner's catalog it does not separate objects from faces: a cartoon
  reads 21.9 and a mascot 17.8, while a clear frontal face reads 9.99.
- **A higher capture-quality floor:** 15% of the catalog's faces are under 0.4 and a named
  adult's median is 0.43, so a floor high enough for the objects would drop real faces.
- **Classifying the aligned crop:** the 112 px crop shows the classifier only skin and features.
  On it a face the user named reads as low as 0.074, and on the wider square 0.279.
- **Seeds that anchor until the user moves them, for every person:** a person Otos found from
  objects and a few unrecognisable faces outlived the objects' removal through the seeds left,
  all from one day.

## Consequences

- **Accuracy is checked on the owner's labels:** a change to the model, the analysis or the
  assignment rules runs `script/face-accuracy.sh` on the labelled set and reports the cold
  start, the seeded run and the corrections against the last run.
- **App size:** the app grows by 66 MB.
- **Downloads and time:** analysing a library means downloading and decoding every original
  photo once: about 1.5 s a photo, mostly decode, in the background. The person rule adds one
  classification per detected face.
- **Hidden faces are turned away too:** a face behind a mask or a net, or a face printed on a
  document, can read under the person rule and stay unread (3 of 5,477 measured).
- **Model change:** a new model is a new revision that re-analyses every photo, and stored names
  carry over through the user's faces and the seeds.
- **Wrong guesses are shown:** a face can carry the wrong person until the user corrects it;
  the likeness sort puts the faces least like a person first, where the wrong ones are.
- **Licence check:** WebFace260M's terms are recorded as unread. They are checked when the site
  is reachable, and again if Otos is ever distributed beyond its owner.
