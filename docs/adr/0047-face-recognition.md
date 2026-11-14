# ADR 0047: Face recognition with Vision detection and AdaFace IR-101

## Status

Accepted, 2026-11-10; assignment rewritten 2026-11-12, when the owner redesigned People
around auto-tagged faces; the person-admission rule and lapsed seeds added 2026-11-12, after
objects Vision took for faces became a person of their own; the image read rewritten
2026-11-12, when faces moved from the original at full resolution to the stored preview;
unrecognisable faces kept out of assignment 2026-11-13, after faces of different people the
model cannot tell apart became a person of their own; a library's videos read for faces
2026-11-13, when the owner asked for faces in videos. The
model, precision and face-admission rules are decided on measured evidence
(`docs/research/2026-11-07-face-recognition-models.md`,
`docs/research/2026-11-12-face-person-admission.md`); the image read on
`docs/research/2026-11-12-faces-from-the-preview.md`; assignment on
`docs/research/2026-11-12-face-auto-assignment.md` and
`docs/research/2026-11-13-unrecognisable-faces.md`; videos on
`docs/research/2026-11-13-faces-in-video-frames.md`.

Built: detection, the analyser and the model (#593), stored faces (#601), faces read from
stored previews (`PreviewFaceReader`, for Immich accounts in #605 and for every still since),
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

**Owner decisions:**
- Otos is non-commercial, so non-commercial model licences are acceptable (2026-11-07).
- A model of about 250 MB is acceptable if it gets great results (2026-11-07).
- Face size does not matter much: a tiny face in a photo is one the owner does not care about,
  and his children's faces are prominent in theirs (2026-11-12).

**Most originals are not on this Mac:** 2,993 of 3,000 random originals in the owner's library
are dataless cloud placeholders, and decoding an original at full resolution takes about 1.5 s.
Every still already has a stored preview (ADR 0035, ADR 0046 §7).

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

### The image read

- **The stored preview, never the original:** every still in a library or an Immich account is
  read for faces from its stored preview, decoded upright: Otos's 2560 px rendering, or until
  Otos renders it, the source's own preview (Immich's). No original is downloaded or decoded
  for faces. `PreviewFaceReader` is the one reader.
- **Measured** (`docs/research/2026-11-12-faces-from-the-preview.md`), from previews against
  originals, on the owner's 1,819 hand-placed faces and on the bake-off's labels:
  - no labelled face goes to the wrong person in the owner's library, and no sibling is
    confused that was not before;
  - embeddings move little: median cosine 0.993 between a face's two readings;
  - the faces the preview loses are those at the quality floor, not the small ones.
- **An edit:** a preview shows the photo's saved edit. A face read from it is carried back
  through the edit's geometry (`EditGeometry`) onto the upright photo, where faces are stored.
  A preview of an edit the photo no longer holds is not read until its new rendering lands; an
  unedited preview is read as the unedited photo until the rendering of a first edit replaces it.
  A tone edit is not undone.

### Videos

- **Which:** a library's videos and an Immich account's (owner decisions, 2026-11-13). A
  card's and a camera's are read once imported, as their stills are. A Live Photo's movie
  is left out of People: its still holds its faces (ADR 0041).
- **The read:** a video has no stored preview, so its faces are an enrichment product, made in
  the same read of its local bytes as its other products under the library claim
  (`EnrichmentClaim.library`). Enrichment downloads the video once for all of them, in the
  background and above the free-space floor (ADR 0027); a library's 1,939 videos are
  627 GB (owner decision, 2026-11-13). `VideoFaceReader` decodes the frames at 0, 10, 25,
  50, 75 and 90% upright at full resolution with no time tolerance, so a re-read finds the
  same frames, and reads each with `FaceAnalyzer`.
- **A video AVFoundation cannot decode** is no failed read: its faces are stamped with none
  and the decoder that said so is stored, and it is read again once that decoder changes
  (ADR 0009, ENR-031). An Immich account's MKV videos are among them: AVFoundation does not
  read the format.
- **A read that fails:** a frame that cannot be read or a failed analysis stamps no faces,
  and is its own outcome, never the whole read's failure: the video's other products are
  written and only its faces stay owed, paced for 900 s on the retry ledger. A model that
  cannot be loaded holds every video's faces for 900 s, so a missing model does not download
  and decode every library video in turn. The hold is the scheduler's process state
  (`EnrichmentSchedule.videoFaces(at:)`), passed to every Store claim as a value
  (`VideoFacesAdmission`): held, a library is claimed under the products' claim and an
  account under the metadata claim (`EnrichmentClaim.admitting`), whose predicates are the
  wider claims' without the faces, so a video that owes only its faces is never claimed —
  no claim and release written for it on every wake — and one that owes more is claimed
  for the rest.
- **An Immich account's videos are read in byte ranges,** never downloaded: AVFoundation asks
  a resource loader for each range it needs (`RemoteVideoAsset`), and each is read with the
  account's `RemoteRangeReader`, the access its metadata takes (ADR 0046 §5), under the
  account claim (`EnrichmentClaim.account`: metadata and a video's faces). The account's
  18,201 videos are 3.0 TB on a Mac with 21 GB free, so a staged download of each, kept
  until quit (ADR 0046 §7), cannot be the read. A range the server does not answer makes
  the read `unanswered`, paced and tried again, never a video with no faces. Measured on 24 of the owner's videos: these
  six frames find a face in each of the 12 that hold one, and of 60 faces read, 31 matched a
  named person past the margin, the same person in every frame of a video.
- **One face per person:** faces taken sharpest first join the person they are most like at
  the assignment threshold (0.434) who has no face in that frame. Measured: one person's
  frames score 0.54–0.98 against each other within a video, and different people at most
  0.17. Two faces of one frame stay two people, and an unrecognisable face is never joined.
- **Frames:** the frames the kept faces were read in are stored as the images of one HEIC of
  the preview's size (`media_asset.face_frames_path`), a derived image like the preview,
  deleted and renamed with it; each face names its image (`face.frame_index`), and its tile
  is cut from it. A face's box is a fraction of its frame.
- **What a video's face cannot do:** it is never outlined, since its box is one frame's and the
  video shows others, and it is no key photo (owner decisions, 2026-11-13).
- **Counts:** a count says what it holds (`MediaCount`): `photos`, `videos`, or `photos and
  videos` once both are (owner decision, 2026-11-13).

### Detection and admission

- **Detector:** Apple Vision's face landmarks and face capture quality, run on the preview.
- **Admission:** a face is embedded only when all of these hold:
  - **Quality:** Vision's capture quality is at least 0.28. On the preview Vision scores a face
    about 0.015 lower than on the original, so 0.28 admits as many faces as the bake-off's 0.3
    did on originals (with the person rule, 5,493 against 5,471 on the owner's library).
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
  unit-length 512-d embedding. Otos holds it as `FaceEmbedding`, which is unit length by
  construction (scaled on read from the model, checked on read from the catalog), because
  every rule below is a cosine and assignment computes cosines as plain dot products.
- **Weights:** linear symmetric per-channel 8-bit weights, 66 MB, shipped as an `.mlpackage` in
  `Otos/Resources` like the models of ADR 0045.
  - **Why int8:** against fp32 it changed one decision of 2,196 (an adult's face left
    unassigned, not a wrong match), and none on a child's face.
  - **Why not fp16:** 131 MB, which exceeds GitHub's 100 MB per-file limit.
- **Engine:** the CPU only, the same as ADR 0045. 33 ms a face; reading a preview and its faces
  takes about 66 ms a still.
- **Model revision:** a revision number (`FaceAnalyzer.revision`) that names the model, Vision's
  revisions and the admission rules, stored with each face. A new revision ships with a
  migration that clears the faces stamp of every still whose faces it can change, as metadata's
  revision changes do. Revision 2 (the person rule) only turns more detections away, so it
  re-reads only stills that have a face. Revision 3 (the preview, and the 0.28 floor) re-reads
  every still, from its preview.

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
  `(size, mtime)` of the source the preview read was made from. A reading replaces every face
  of its asset, and a still with no face has the stamp and no rows, so it is not read again
  until a preview of other bytes arrives. An edit is not a new source and is not read again.
  Beside it, the source the faces were read from (`faces_read_source_size`,
  `faces_read_source_mtime`): a migration clears the stamp to owe a re-read, and the re-read
  compares against this pair, so a file that changed meanwhile is read afresh.
- **A preview that cannot be read:** only a preview that decoded and held no face is stamped
  with none. A preview that cannot be read or decoded, or whose analysis failed, writes
  nothing; the still stays owed and is offered again after 900 s, or at once when its preview
  changes. A model that cannot be loaded stops the reader until the same 900 s pass: the
  model is loaded before any Vision work, and a failed load is not kept.
- **Who owes faces:** a library's and an Immich account's stills (`LibraryRootKind.readsFaces`).
  Faces are not an enrichment product, so no enrichment claim owes them. A card's or camera's
  rows are read for faces once imported into a library, which is where their overlay lives on.
- **People** are catalog rows: an optional name, an optional birthday, a hidden mark, a
  favourite mark, and a stable row ID. A person is not a media asset, so this is not an asset
  identity, which stays the path. A person is the set of their faces, each with its capture
  date. No average face is stored.
- **Whose word a face's person is** (`face.assignment` beside `face.person_id`): none, Otos's
  guess, a seed (one of the faces a person was first found from), the user's, or held (the
  user removed the name). The user's faces and the seeds are the anchors; every guess is
  rebuilt from them. Also on the face: its likeness to its person (the likeness sort) and
  whether it is its person's key photo (`is_key_photo`), at most one per person. Choosing a
  key photo is the user's word that the face is that person: Make Key Photo makes it theirs
  on the user's word (since 2026-11-13), so a re-read carries the cover and
  assignment never moves it. A likeness
  is rewritten only when it moves by more than 1e-5: Accelerate's matrix product rounds
  differently from process to process (up to 4.8e-7 on the owner's faces), and a write
  starts the next assignment, so writing that wobble would never let People settle
  (`docs/research/2026-11-13-people-assignment-scale.md`).
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
- **Unrecognisable faces:** AdaFace places a face it cannot tell anyone by (blurred, upside
  down, hidden by a costume, seen too close) near one common direction, whoever it shows, so
  such faces of different people link as strongly as one person's. `FaceRecognisability`
  holds that direction: the mean embedding of aligned crops shrunk to 8 px, which keeps no
  identity. A face whose cosine with it reaches 0.2 is never guessed, grouped or compared
  with. One the user gave a person still keeps that person out of the rest of its photo.
  Measured on the owner's catalog: no face the user named reaches 0.13, and every face of
  the group they found wrong reaches 0.22 (`docs/research/2026-11-13-unrecognisable-faces.md`).
- **Lapsed seeds:** a person the user said nothing about (no name, birthday, favourite, hidden
  mark or key photo, and no face on their word) keeps none of their unrecognisable seeds, and
  their others only while those span two or more days, as a new person's must. When faces leave such a person (re-read under stricter
  admission, deleted, or moved by the user), the seeds left are Otos's to decide again, and the
  person is forgotten once no face is theirs. A person the user said anything about keeps
  their seeds.
- **Hard rules:**
  - Two faces in one photo are never the same person.
  - A face from before a person's birthday is never theirs. A birthday may be only a year,
    which counts from 1 January (owner decision, 2026-11-10). One rule holds Set Birthday and
    a merge: the user's faces from before it refuse the act, and Otos's guesses and seeds
    from before it lose the person.
  - A face the user said is not someone (`This Is Not Sam`, or `Not the Same Person` in an unnamed person's own photos) is held: Otos never gives it a person
    again, and never offers that person for it.
- **Corrections propagate:** a correction is a new anchor, and every guess is rebuilt from the
  anchors, so moving one face moves the guesses reached through it (owner decision,
  2026-11-12). From a cold start, ten moves left nothing wrong on the owner's
  labels.
- **Settles on its own output:** assignment reads only the anchors, so run on what it wrote it
  writes nothing. A pass that wrote is followed by one that publishes.
- **A new reading** of the same source keeps the user's word: each act, and each seed, moves
  to the new face that matches it — a still's by box overlap, a video's by likeness, since a
  video's boxes belong to different frames — and a face with the user's word that the reading
  does not find is kept as it was read (`CatalogStorePersistence.writeFaces`). A reading of a
  changed file is read afresh. A stored face row no reading writes is not a fact: the People
  read leaves its photo out and owes it a re-read, which replaces the row.
- **What the user's acts store** (overlay, ADR 0008; undoable): a face's person on their word;
  a held face and its rejection; `This Is Not a Face`, until the photo's file changes; a person's
  name, birthday, hidden and favourite marks and key photo. A person Otos found is
  deleted once no face is theirs and the user said nothing about them.

### Work and placement

- **Owner:** `PreviewFaceReader`, one loop woken by the catalog's change notifications and by
  its own retry wake. It reads the stills whose faces stamp does not name their preview's
  source, a page at a time, and writes a reading only while the row still has the preview it
  read. What is owed faces is read from partial indexes over only the rows that owe them, so a
  catalog with nothing owed reads no row on a catalog change.
- **Downloads:** none. A still waits for its preview, which enrichment renders from the
  original when that is local or downloaded for the rendering (ADR 0035), or which an Immich
  sync fetches (ADR 0046 §7).
- **Threads:** the preview is decoded off the reader, and Vision and the model run on
  `FaceAnalyzer`'s own queue, never on the main actor.
- **Assignment:** `PeopleAssignment`'s loop, asked after every catalog change, reads every face
  in one transaction, assigns off its actor, and writes a guess only where the face is still
  Otos's to decide, so an act the user made meanwhile always wins.
- **People UI:** the People gallery, a person's photos as the leaf under it
  (`SidebarSelection.person`, so the sidebar keeps People highlighted and Back to People
  exists only there), the People filter, whose several people are photos of them together,
  the face acts in
  the photo menus and the Info pane (`docs/design/people.md`).
- **Which person the window shows:** one view-model owner (`reconcileShownPeople`) decides it,
  with the filter's people, from the published People state and the acts the store has not
  answered. Each act's submission takes a number (`PendingPeopleActs`), and the store's answer
  comes back under it. The store commits a merge and rings the projection before its answer
  returns, so the People state without the person merged away can arrive first: while that
  merge is outstanding, the person stays shown and filtered. Its confirmation names the person
  merged into (`PeopleActOutcome.person`), who takes their place; its refusal hands them back
  to the published state. Hide, and a person Otos deletes once empty, have no successor: the
  window returns to the gallery whichever arrives first.

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
- **The original at full resolution (2026-11-10 to 11-12):** the 112 px crop the model sees
  comes from more pixels, but no decision measured better for it, and it downloaded every
  cloud original and decoded it for about 1.5 s, again at every analysis revision.
- **The original downscaled to the preview's size:** the same pixels as the preview for an
  unedited photo, but read only when the original is local, so a library whose originals are
  in the cloud would download them for faces, or read the faces of only some.
- **The preview at the original's 0.3 floor:** it loses 212 of 5,471 faces against 123 at 0.28,
  52 of them faces the owner placed against 27, because Vision scores the preview lower.
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
- **The first frame, or QuickLook's thumbnail, of a video:** QuickLook made a thumbnail for 15
  of 24 measured videos and its frame held a face in 3; any one fixed frame found faces in at
  most 9 of the 12 videos that hold one.
- **Downloading an account's videos to read them:** 3.0 TB through a staging folder kept
  until quit would fill the disk long before the account was read, and the frames need only
  the ranges around six points of each file.
- **A video's six frames as six faces:** each person would be up to six faces of one video,
  six times the work and counts for one appearance.
- **Every sampled frame stored for a video's faces:** about 2.4 MB a video against the frames
  kept, and only the kept faces' frames are shown.
- **A higher capture-quality floor:** 15% of the catalog's faces are under 0.4 and a named
  adult's median is 0.43, so a floor high enough for the objects would drop real faces.
- **Classifying the aligned crop:** the 112 px crop shows the classifier only skin and features.
  On it a face the user named reads as low as 0.074, and on the wider square 0.279.
- **Turning unrecognisable faces away at admission:** they are real faces the user may name.
  The embedding alone says the model cannot tell who they are, so assignment leaves them alone
  and nothing is analysed again.
- **A direction built from 12 px crops:** some identity survives at 12 px. It reaches 0.19 on a
  face the user named and leaves half the wrong group under the limit.
- **Seeds that anchor until the user moves them, for every person:** a person Otos found from
  objects and a few unrecognisable faces outlived the objects' removal through the seeds left,
  all from one day.

## Consequences

- **Accuracy is checked on the owner's labels:** a change to the model, the analysis or the
  assignment rules runs `script/face-accuracy.sh` on the labelled set and reports the cold
  start, the seeded run and the corrections against the last run.
- **App size:** the app grows by 66 MB.
- **No downloads for faces:** a library is read for faces from what Otos already stores, about
  66 ms a still. A new analysis revision re-reads the whole library from its previews, not from
  its originals. The person rule adds one classification per detected face.
- **A still waits for its preview:** a still that has none yet is read once its rendering
  lands; a still no decoder renders has no faces Otos can read.
- **A re-read never drops the user's word:** a reading of the same source carries each act to
  the new face that overlaps it, and keeps, as it was read, a face the user named, removed the
  name of, rejected someone for or marked not a face that it does not find. So the 27 of the
  owner's 1,819 placed faces that the preview does not find keep their names, and a crop or a
  dark edit that hides a face does not take what the user said about it. Such a face keeps the
  embedding it was read with; a new model must re-embed it from the preview at its stored
  landmarks, or leave it out of assignment. Only a changed file is read afresh.
- **A preview's size is part of the analysis:** a change to the stored preview's size or its
  renderer is checked with `script/face-accuracy.sh` like any analysis change.
- **Hidden faces are turned away too:** a face behind a mask or a net, or a face printed on a
  document, can read under the person rule and stay unread (3 of 5,477 measured).
- **Videos download for a new revision:** a video's faces are read from its original, so a new
  analysis revision that changes them downloads every library video again. A face the user
  said something about that a re-read does not find keeps its word and loses its frame: the
  re-read replaced the frames file, and its tile shows the placeholder.
- **Model change:** a new model is a new revision that re-analyses every photo, and stored names
  carry over through the user's faces and the seeds. `FaceRecognisability.direction`
  is rebuilt for it the same way.
- **Wrong guesses are shown:** a face can carry the wrong person until the user corrects it;
  the likeness sort puts the faces least like a person first, where the wrong ones are.
- **Licence check:** WebFace260M's terms are recorded as unread. They are checked when the site
  is reachable, and again if Otos is ever distributed beyond its owner.
