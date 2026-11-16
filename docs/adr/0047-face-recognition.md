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
    (61 of 3,293 measured detections).
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
  - the analysis revision that read it.

  Its person and whose word it is come with assignment.
- **A face's embedding** is its own row in `face_embedding` (since v66): 512 little-endian
  Float32 values, keyed by the face with `ON UPDATE CASCADE` and `ON DELETE CASCADE`, so a
  move and a deletion carry it with its face. In the face row it was 2,048 of 2,100 bytes:
  one row filled a page, and every read of who the faces are read 403 MB on the owner's
  catalog to learn about 100 bytes a face. Its `id` (`AUTOINCREMENT`) is the reading's
  number: every reading inserts a new vector row and no number is given twice, so the
  vectors written since a reader last looked are the rows above the largest number it holds.
  The number is never an identity; a face is its photo's path and its place in the reading.
  Rejected: dropping the column in place, which rewrites every row of the table and so writes the
  whole table to the log beside the copied vectors, and a covering index beside the wide rows, which
  keeps the 403 MB table and still gives no reading a number.
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
  A still's faces are not an enrichment product, so no enrichment claim owes them; a
  video's are (see Videos). A card's or camera's
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
- **The kernel and its memory:** a face keeps, per person, only a best of 0.264 or more (a
  lower one decides nothing: a decision reads a best at the threshold and a runner-up within the
  margin of it); on the owner's faces that is about six people of 752. Each round raises those
  bests a block of 512 faces and a chunk of 2,048 evidence faces at a time, the faces in capture
  order so the faces an evidence face reaches are at most two runs of the block, with one
  vectorised maximum per evidence face and run. What the kernel needs only while it runs —
  its blocks, products and transposed columns, and grouping's links between faces, sorted
  in place — is mapped memory of its own (`ScratchBuffer`), unmapped as it returns; a
  person's run of faces is ordered by position, never through copies of every face with its
  time: on macOS 27 memory `malloc` frees stays in the footprint
  (`docs/research/2026-11-16-freed-memory-stays-in-the-footprint.md`). What it builds per face
  is a few flat arrays, never an allocation per face: the kept bests are lists threaded
  through four arrays (`Bests`), and the snapshot's faces are columns over one table of the
  photos' IDs held once (`PeopleFaces`). People holds the
  vectors at half precision (105 MB for 103k faces): on the owner's 102,978 vectors it changed
  no best person, threshold or margin decision in 3,029 faces sampled
  (`docs/research/2026-11-16-people-memory-and-kernel.md`). They are held in a file of their
  own, never on the heap (`FaceVectors`, `FaceVectorFile`): created in the temporary directory
  and unlinked at once, written with `pwrite`, read through a read-only shared mapping, so their
  pages are clean and file-backed and the footprint never counts them. The file is made again
  from `face_embedding` every launch, as the vectors were read before, so it is never stale and
  never a second source of truth, and nothing is left on disk after a crash; dropped vectors
  stay in it until a quarter of its slots are dropped, when the kept ones are written into a
  new file. Measured on a generated catalog of the owner's shape, the first pass that assigns
  added 175 MB to the footprint with the vectors on the heap and 79 MB with them in the file
  (`docs/research/2026-11-16-people-passes-in-a-live-session.md`). Rejected: the dense table
  of every face's best per person (310 MB on the owner's catalog, rebuilt every run of
  chaining); single precision resident (211 MB, against People's share of a 700 MB app); the
  vectors on the heap at half precision (105 MB of footprint, held for the session); and a file
  kept across launches, which would save the launch's one read of every vector (under a second
  of a background reader) at the cost of a commit point in the catalog, a check against a
  restored catalog whose vector numbers run again, and a file to remove with its faces.
- **Settles on its own output:** assignment reads only the anchors, so run on what it wrote it
  writes nothing; the hash of its inputs says when it need not run at all (Work and placement).
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
- **Assignment:** `PeopleAssignment`'s loop, asked after a catalog change of a kind assignment
  reads. A pass reads every stored face's row and whose word its person is, never its vector
  nor its tile, in one transaction (the snapshot, assignment's alone), and writes each
  person's gallery facts that moved (below). A pass costs what changed: the first pass of a
  launch, and a pass after a change that names no rows or touches more than faces and their
  photos' dates, kinds and images (`PeopleAssignment.incrementalInputs`), reads every face;
  any other reads only the faces of the photos the changes named, each by key
  (`CatalogStore.peopleSnapshot(of:)`, logged as `peopleFaces`), with the people, their facts
  and the key photos whole, and lays them over the read it holds in the order a whole read
  gives (`PeopleSnapshot.replacing`), so the hash below is a whole read's. A reading and
  assignment's own writes name their photos. Measured before: 20 whole reads, 136 s of
  reader time, in one session of 152 metadata changes. It then hashes what assignment reads (each face's
  identity, vector number, capture time, rejections and anchor; each person's birthday and
  whether the user said anything about them; which file stands for which photo; the policy's
  constants and revision). The catalog keeps the hash of the inputs whose assignment it holds
  (`people_assignment_settled`, v67); while the two are equal nothing is assigned, so a launch
  with nothing changed, a new tile, a stack or copy that moves no face's photo, a renamed
  person, all assign nothing. Otherwise the pass reads the vectors it does not hold — every
  vector once per launch, then only the rows above the largest number it holds — assigns off
  its actor, writes a guess only where the face is still Otos's to decide, so an act the user
  made meanwhile always wins, in pages of at most 256 rows (`CatalogStore.writeInPages`), and
  records the hash. A guess is assignment's output, never its input, so the pass after a write
  that moved only guesses finds the hash equal; a write that seeded a person, released a seed or
  forgot a person moved an input, and the pass after it assigns once more and writes nothing.
  Rejected: re-reading every vector each pass (211 MB a pass on the owner's catalog, the
  `peopleSnapshot` reader time), publishing only after assignment (48.8 s to the first People
  paint, measured), a timestamp or change counter as the trigger (a fact kind is too coarse:
  `captureDate` and `copies` fire on most enrichment flushes and moved no face), and holding
  the hash in memory alone (every launch would assign once, reading every vector).
- **People UI:** the People gallery, a person's photos as the leaf under it
  (`SidebarSelection.person`, so the sidebar keeps People highlighted and Back to People
  exists only there), the People filter, whose several people are photos of them together,
  the face acts in
  the photo menus and the Info pane (`docs/design/people.md`).
- **A face tile holds its own pixels:** a tile is drawn from the uncached preview, so Image I/O
  decodes only the part of the preview the face covers. It is drawn at the cell's backing size
  into a `MappedImage` (`Otos/Support/MappedImage.swift`), pixels of its own that leave the
  footprint when the tile goes. `FaceTileImages` costs each tile at what it holds, up to
  48 MB. Rejected: `CGImage.cropping(to:)` of a scaled decode. A crop keeps the whole image it
  was cut from, so 24 small faces in a Retina window held 812 MB in the test process
  (`docs/research/2026-11-16-image-memory-while-used.md`).
- **The gallery paints from its own read** (`PeopleGallery`, the window's, not a heavy load):
  the people, each with the gallery facts the catalog stores for them (`person_summary`, v73:
  their photo and video counts, a photo's copies and a stack's files counted once, and their
  newest face) and the tiles of their key photo and newest face, each sought by key; the faces
  on the user's word or a seed, the hard rules' facts, from a partial index of them
  (`idx_face_anchor`); and the unchecked tally. It never walks every face, and it runs as soon
  as the window's first grid is published, so People's first paint never waits for the
  snapshot or for its turn among the heavy loads. Measured on the owner's catalog before it:
  the gallery was published only after the whole snapshot, 6.5 s after the click, of which
  the face-to-photo join was 7.5–7.9 s of reader time cold. `PeopleAssignment` computes the
  facts from scratch from its snapshot after every pass (`PeopleSnapshot.computedGalleryFacts`)
  and writes those that differ, announcing `.peopleGallery`, which assignment does not read;
  so an act, a reading, a deleted or hidden photo reaches the counts with the pass its change
  rings, and a test holds the stored facts equal to a computation from scratch after random
  acts, readings and deletions. A person People has not yet written facts for is not shown
  until it has, and while no person has facts (the first launch after v73) the gallery is not
  known and claims nothing. The newest face follows its face's moves and is cleared when the
  face is deleted, until the next pass names another. Rejected: maintaining the counts in
  every write that changes them (triggers or each writer's own SQL), which would make every
  writer of trash, copies, stacks and kinds a second owner of People's count rule; and the
  join of every face per visit, 31k pages on the narrow `media_asset` of v71.
- **A photo's faces are read by key** (`CatalogStore.photoFaces(of:)`): the photo menus and the
  Info pane read the faces of exactly the targets and of their present copies when the
  targets change and after each People state, and the Person sheet reads its row of a
  person's newest faces as it opens (`newestFaces(of:limit:)`). No surface holds every face.
- **What the People UI reads:** `CatalogPeopleState` is built off the main actor with
  everything its surfaces look up already derived: the visible and the hidden people in
  gallery order, the names the Person sheet suggests, and each person's index. The hard rules (`mergeRefusal`, `moveRefusal`, `sheetRefusal`)
  are functions over that state, so the window holds no second index to keep in step with
  it. A gallery cell renders from its own person and selection alone and is equal to the
  cell it replaces while they are, so a People update, published every few seconds while
  faces are read, re-renders only the cells whose person changed; the gallery is equal to the
  one it replaces while its People state and selection are, so the window's other
  publications render nothing in it. A cell's `PersonMenu` is
  built only as its context menu or VoiceOver opens it, and it is the same value the menu
  bar's person items and the toolbar menu of a person's photos render; that toolbar menu
  judges a merge into every named person, so it is built once per People state or scope,
  never in a view's body. Rejected: building every cell's menu with the state (the merge
  targets are the window's selection, and a selection of every person makes that quadratic),
  and an AppKit menu host for the cells (SwiftUI does not evaluate the body of a context
  menu's or an accessibility-actions content view while the cell renders, measured in a
  hosted test on 2026-11-14, so a child view already defers the menu's cost to its use).
- **Which person the window shows:** one view-model owner (`reconcileShownPeople`) decides it,
  with the filter's people, from the published People state and the writes the store has not
  answered. Each write's submission — an act, an undo, a redo — takes a number
  (`PendingPeopleActs`), and the store's answer comes back under it. The store commits a merge
  and rings the projection before its answer returns, so the People state without the person
  merged away can arrive first: while that merge is outstanding, the person stays shown and
  filtered. Its confirmation takes the window to the person merged into, who takes their
  place; its refusal hands them back to the published state. A redo of a merge is that merge,
  answered on the same path (`didAnswerPeopleWrite`), though it writes back the state the
  merge left rather than merging again; an undo of one puts the person back and takes no one
  away. Hide, and a person Otos deletes once empty, have no successor: the window returns to
  the gallery whichever arrives first, and so does the undo of a New Person, whose person is
  gone.

### A photo's copies

A face on any identical copy of a photo is the photo's (ADR 0054; owner, 2026-11-15). Faces
are still read from each copy's own preview and stay on that copy, and the user names a face on
the copy in front of them. A person's photos, People and the People filter find a photo by a
face on any of its present copies (`PhotoFaceSQL`), and a person's photo count counts the photo
once (`PeopleSnapshot.computedGalleryFacts`), so a photo mirrored by an Immich account is not two photos of
that person.

**Each copy is read for its own faces** (2026-11-15). Identical bytes are not identical
pixels to the reader: a library file is read from Otos's 2560 px rendering (RAW9 or Image I/O,
ADR 0035), its Immich copy from the server's 1440 px short-edge JPEG preview (libvips, ADR 0046
§7). Resolution alone moves Vision's quality score by a median −0.014 and loses 39 % of the
faces just above the 0.30 floor, and a RAW's development moves embeddings below 0.9 cosine
(`docs/research/2026-11-12-faces-from-the-preview.md`), so the two readings find different
face sets and boxes. A face stays on the copy whose pixels it was read from; nothing is copied
between copies, and no copy's reading replaces another's, so no user act moves or is lost when a
copy comes or goes.

**Every surface resolves a photo's faces through one relation**, the copies `PhotoFaceSQL`
finds a photo by (`PhotoFaceSQL.presentCopiesOfDigest`, read into `PeopleSnapshot.copies`). The
faces' own read carries each file's digest while it has a present copy (`PeopleFaceColumn.copiedDigest`),
so only such a photo is asked for its copies, through the digest index. A separate walk of every
face, seeking each file with one, cost 188 M instructions of the snapshot at 10,000 faces; read
with the faces, the column costs 24 M and the 257 photos with copies 47 M (2026-11-16):
- **A photo's faces** (Info's People section, the photo menus, `SelectionFaces`) are the shown
  file's own faces, then, for each visible person a present copy holds and this file does not,
  that copy's face, from the first copy in shown order (`PhotoFaces.faces(of:)`). Another
  copy's unidentified faces are not listed: they are this file's own detections, read again
  from other pixels. Several selected copies list a face once.
- **A face's box belongs to its own copy's pixels**, so it is outlined only where that copy
  shows (`outlinedFaceBoxes` is keyed by the face's file); a person named only on another copy
  is listed with that copy's face tile and no outline on this one.
- **An act acts on the face's own copy.** `This Is Not Sam` on a face listed from another copy
  takes that copy's name, and the person leaves this copy's list unless its own face holds
  them; naming this copy's own face is the way to give it the person.
- **Nothing is counted twice:** a person's photo count and the Person sheet's row count and
  show each photo once (`PeopleSnapshot.photoOf`, `CatalogStore.newestFaces(of:limit:)`); a face's
  likeness is to the person's faces in other photos only, never to its own photo's other copy
  or stack file (`FaceAssignmentPolicy.assign(photoOf:)`); and the unchecked tally counts a
  photo once while any present copy of it is unread (`PreviewFaceSQL.uncheckedSQL`). A
  person is still at most once per file, so each copy's face can be the person.
- Assignment reads each copy's faces on their own: the same face read twice is near-identical
  (cosine ≥ 0.95), so a face named on one copy makes its twin's guess, and grouping, which
  needs faces from two days, gains nothing from a twin of the same day.

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
