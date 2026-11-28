# Faces from the stored preview instead of the original

Date: 2026-11-12. Question: can Otos read a library's faces from the 2560 px preview it
already stores, instead of downloading and decoding every original at full resolution
(ADR 0047)? What does the preview lose, and does any identity decision change?

**Answer:** yes. Read from the preview, the reference library's faces make the same identity decisions:
no labelled face goes to the wrong person, and no sibling is confused that was
not confused before. The preview loses faces at the quality floor, not small faces: Vision
scores a face about 0.015 lower on the preview, so faces just above 0.3 on the original fall
under it. A floor of 0.28 on the preview admits as many faces as 0.3 did on originals. Otos
now reads every still's faces from its stored preview, with that floor (analysis revision 3).

The research material is in `~/Development/Otos-face-research` (private photos, never
committed); the harness (`run4/harness`) and its outputs are in its `run4/`.

## Why it matters

- **Downloads.** On the reference library 2,993 of 3,000 random originals are dataless cloud
  placeholders. Reading faces from originals downloads each of them. Every new analysis
  revision does it again: #670's revision 2 re-reads every still with faces.
- **Time.** About 1.5 s a photo to decode an original at full resolution, against 66 ms to
  read and analyse its preview (measured below: 6,945 previews in 12 minutes, analysis
  included).
- **The rule (2026-11-12).** A tiny face is one the user does not care about; the faces
  that matter are prominent in their photos.

## 1. Method

Two sets, both of faces already read from originals, so no original was downloaded:

- **The reference library, current.** A copy of the installed catalog: every still in a fixed
  library with faces read from its original (analysis revision 1) and a stored preview, and
  no edit. 6,945 stills from 2026, 5,471 faces. The user placed 1,819 of them by hand
  (Sam 1,000, Ian 819), so they are the labels. The preview is Otos's own rendering:
  HEIC, 2560 px long edge (ADR 0035).
- **The research labels** (`docs/research/2026-11-07-face-recognition-models.md`): 3,293
  faces in 2,290 photos from 2012–2026, 2,196 of them labelled, 33 people, the three
  children across years. Their originals are on a server that was not reachable, so each
  photo was read from the research run's 1,600 px copy: smaller than the stored preview, a
  lower bound.

Each preview went through the shipped `FaceAnalyzer` at revision 1 with the quality floor
removed, and was decoded as `PreviewFaceReader` decodes it. Its faces were matched to the
original's: in the catalog by `FaceCarryOver`, the box overlap that carries the user's
acts across a re-read; in the research set by the highest cosine above 0.6 within the
photo. Then:

- **Decisions:** `FaceAssignmentPolicy` on both readings with the catalog's own anchors (the
  user's faces and the seeds, carried to preview faces by box).
- **Accuracy:** `script/face-accuracy.sh` on both readings (cold start, seeded,
  corrections).

## 2. What the preview changes

**Embeddings barely move.** Cosine between a face's preview and original embeddings, over
5,259 matched faces: median 0.9926, p10 0.981, p1 0.955. Twelve are under 0.9: costumes, a
baby turned away, and RAWs, whose preview is RAW9's development rather than Image I/O's.

**Vision scores quality lower on the preview.** Preview minus original, per matched face:
median −0.014, mean −0.017, p10 −0.052, p90 +0.014. So the faces just above the 0.3 floor on
the original are the ones lost:

| Quality on the original | Matched | Lost | Lost share |
| --- | --- | --- | --- |
| 0.30–0.35 | 222 | 141 | 39% |
| 0.35–0.40 | 415 | 37 | 8% |
| 0.40–0.50 | 1,235 | 24 | 2% |
| 0.50–0.70 | 3,062 | 9 | 0.3% |
| 0.70 and up | 325 | 1 | 0.3% |

**The faces lost are not the small ones.** Their median height on the original is 455 px
(found faces: 780 px), and many are large:

| Height on the original | Found | Lost |
| --- | --- | --- |
| under 200 px | 41 | 17 |
| 200–400 px | 686 | 73 |
| 400–800 px | 1,872 | 58 |
| 800–1,200 px | 1,322 | 40 |
| 1,200 px and up | 1,114 | 15 |

**The floor, matched to the preview's scale.** The same previews with the floor swept:

| Floor on the preview | Lost | Of them, user-placed | Of them, 600 px or more | Found that the original did not |
| --- | --- | --- | --- | --- |
| 0.30 | 212 | 52 | 82 | 91 |
| 0.29 | 151 | 38 | 47 | 116 |
| **0.28** | **123** | **27** | **35** | **153** |
| 0.27 | 94 | 21 | 21 | 183 |
| 0.26 | 79 | 18 | 13 | 227 |
| 0.25 | 73 | 15 | 12 | 268 |

At 0.28 the preview admits about as many faces as the original did at 0.3 (5,501 against
5,471). The faces it adds are the mirror case: just under 0.3 on the original.

## 3. Identity decisions

**The reference library, current,** labels the 1,819 faces the user placed:

| | Original | Preview, 0.30 | Preview, 0.28 | Preview, 0.25 |
| --- | --- | --- | --- | --- |
| Cold start: labelled faces with the wrong person | 0 | 0 | 0 | 0 |
| Cold start: siblings confused | 0 | 0 | 0 | 0 |
| Cold start: a labelled person split in two | 0 | 1 | 1 | 1 |
| Seeded: wrong / siblings | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| Sam's labelled faces reached | 1,000 / 1,000 | 972 / 972 | 986 / 986 | 989 / 989 |
| Ian's labelled faces reached | 819 / 819 | 795 / 795 | 806 / 806 | 815 / 815 |

**The catalog's own assignment,** the user's anchors carried to the preview's faces by box,
at 0.28, over the 5,348 faces both readings found: 4,327 get the same person, 970 have none
in either, 2 change person, 7 gain one and 42 lose theirs.

- **Changed (2):** two of Tyler's guesses go to Sam or to an unnamed
  person. Their embeddings moved 0.009 and 0.71 (a RAW turned away); both were Otos's
  guesses, so the labels cannot say which reading was right.
- **Lost a person (42):** 40 are guesses of Sam's in one afternoon's burst (2026-10-18),
  reached in the original's assignment through user-placed faces that the preview does not
  find. Their own embeddings are as before (cosine 0.97–0.99).

**The research labels at 1,600 px,** a lower bound on the stored preview:

| | Original | 1,600 px, 0.30 | 1,600 px, 0.28 |
| --- | --- | --- | --- |
| Faces matched (of 3,293) | — | 2,837 | 2,945 |
| Cold start: labelled faces with the wrong person | 10 | 16 | 16 |
| Cold start: siblings confused | 0 | 0 | 0 |
| Seeded: wrong / siblings | 5 / 1 | 4 / 1 | 5 / 1 |
| Corrections to reach none wrong | 10 moves | 10 moves | 10 moves |
| Children reached, seeded | 224/225, 487/487, 32/32 | 215/216, 465/465, 31/31 | 219/220, 473/473, 31/31 |

Here the lost faces do skew small, because 1,600 px is small: at 0.3, 62 of the 133 faces
under 100 px are lost, and 19 of the 463 of 1,000 px or more.

## 4. What the switch costs the user

- **Faces:** about 2% of the faces read from originals are not found in the preview at
  0.28, almost all at the quality floor; about as many others are found.
- **Names:** a re-read carries the user's acts over by box (`FaceCarryOver`). At 0.28, 27 of
  the 1,819 faces the user placed are not found in the preview: 13 of Ian's, 14 of Sam's,
  each in a photo whose quality on the original read 0.30–0.64, most of them in bursts that
  keep other faces of the same child. A re-read of the same source therefore keeps a face the
  user said something about that it does not find, as it was read, so none of these names is
  lost.
- **Edits:** a preview shows the photo's saved edit. 11 of the catalog's photos have a saved
  edit, and none of them has faces; the measurement used unedited photos only. A face read
  from an edited preview is carried back through the edit's geometry to the upright photo,
  where faces are stored; a tone edit is not undone, and was not measured.

## 5. The shipped analysis (revision 3)

The same 6,945 previews through the shipped analyser: the 0.28 floor and #670's person rule
(Vision's classifier sees a person around the face; measured on these previews), against the
faces read from originals before the person rule:

- **Faces:** 5,493 from previews against 5,471 from originals; 5,342 found by both, 129 not
  found in the preview (35 of them 600 px or more on the original), 151 found only there.
- **The reference labels:** cold start, seeded and corrections all with no labelled face on the
  wrong person and no sibling confused; one labelled person split in two at cold start; every
  labelled face of Sam (986) and Ian (806) found in the preview reached.
- **The catalog's own assignment:** 4,325 the same person, 968 none in either, 2 changed (the
  two Tyler guesses of section 3), 6 gain a person and 41 lose theirs, 40 of them in the
  2026-10-18 burst.
- **User-placed faces not found:** the same 27 as at 0.28 without the person rule; they keep
  their names as read.

## 6. Conclusions

- Read faces from the stored preview, never from the original: the decisions hold, and no
  original is downloaded for faces again, at this revision or any later one.
- Lower the capture-quality floor to 0.28 on the preview, a new analysis revision (3).
- Recheck with `script/face-accuracy.sh` whenever the preview's size or its renderer
  changes, as for any analysis change.
