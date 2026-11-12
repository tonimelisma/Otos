# Face admission: Vision's classifier tells faces from objects

Date: 2026-11-12. Question: an unnamed person in the owner's People gallery was 13 photos of
lace, a bucket, a storefront, a mascot, pixel art and costumed children. What let them in, and
what keeps such detections out without losing real faces?

**Answer:** Vision's image classifier (`VNClassifyImageRequest`, revision 2), run on a square
twice the size of the face box. A detection is read only when its highest person-label
confidence reaches 0.2. AdaFace's own feature norm was measured first and does not separate
them. Separately, a person the user said nothing about keeps its seeds only while they span two
or more days. Decision: ADR 0047.

The research material is in `~/Development/Otos-face-research` (owner photos, never
committed). The tools named below are in its `tools/`, and the numbers come from its `run3/`.

## 1. What the person was

Catalog person 18 of the installed app had 13 faces. Every one had a Vision capture quality of
0.32 to 0.45, just over the 0.3 floor.

**Its faces:**
- **Not faces (9):** black lace (its key photo), framed pictures on a wall, the Salesforce
  Astro mascot, a storefront, a red bucket, clasped hands, a cartoon drawing, a carved puppet
  face, a pixel-art avatar.
- **Faces the model cannot recognise (4):** two children in tiger-costume hoods, the same baby
  three seconds later, and a child photographed upside down.

**How unlike it is:**
- **To everyone else:** every face is at most 0.28 cosine from every named person's faces.
- **To itself:** the median pairwise cosine within the group is 0.42, below the 0.434
  assignment threshold. The least alike pair is 0.06, so it is one chain, not one face.

**How it formed** (ADR 0047's assignment):
- **The seed group.** Four leftover faces linked at 0.65 or more across three days, so they
  became a new person: a costumed child links to the framed pictures at 0.78 and to the
  mascot at 0.70.
- **Chaining.** Each face joined through one that had joined before it:
  - the storefront through a costumed face, at 0.62;
  - the bucket through the storefront, at 0.64;
  - the lace through the bucket, at 0.64.

  The lace is at most 0.35 from any seed.
- **The margin.** Each crop's runner-up person scores about 0.2, so the 0.16 margin held for
  all of them.

**The other small unnamed people:** the catalog's eleven others were checked by eye, and every
one is a real person.

**Why the capture-quality floor does not help:** 815 of the catalog's 5,473 faces (15%) have
quality under 0.4, and a named adult's median is 0.43. Capture quality says how well a face was
photographed, not whether it is a face.

## 2. AdaFace's feature norm: rejected

**The idea:** AdaFace is trained so that the length of its feature vector, before
normalisation, grows with how recognisable the input is (Kim, Jain and Liu, CVPR 2022). The
converted model normalises it away.

**The edit:** `tools/expose_norm.py` edits the shipped int8 package's ML program so that the
normalisation's own `reduce_l2_norm` is a second output. Only `model.mlmodel` changes. On 300
crops its embeddings were identical to the shipped package's (largest difference 0.0).

**Measured:**
- **Research crops:** `tools/facenorm crops` over run 2's 4,449 crops gave the 2,196 labelled
  faces a minimum norm of 13.2 (1st percentile 18.5).
- **Live catalog:** `tools/facenorm catalog` read all 5,477 catalog faces, re-aligned from
  their stored landmarks on Otos's stored previews. Those crops' embeddings match the stored
  ones at median cosine 0.995.

| Faces | n | min | 1st pct | median |
| --- | --- | --- | --- | --- |
| Named, on the user's word | 1,821 | 13.5 | 19.4 | 22.6 |
| Person 18 (the junk) | 13 | 12.8 | 12.9 | 15.2 |
| No person | 1,016 | 11.7 | 17.8 | 22.6 |

**Why it fails:**
- **Junk can read high.** The cartoon reads 21.9 and the mascot 17.8.
- **Real faces can read low.** A clear frontal photo of a named adult reads 9.99, and two of
  another 15.6 and 15.9.

No cut removes the junk without removing real faces. The norm measures how confident the model
is about the faces it was trained on, not whether a crop is a face.

## 3. Vision's image classifier: chosen

**Method:** `tools/faceclass` ran `VNClassifyImageRequest` (revision 2, 1,303 labels) on every
catalog face, in two crops from the stored preview:
- the aligned 112 px crop;
- a square twice the face box, centred on it and kept inside the photo (the context crop).

A face's score is its highest confidence among the person labels: `people`, `adult`, `child`,
`baby`, `teen`, `crowd`.

| Faces | n | aligned crop, min / 1st pct / median | context crop, min / 1st pct / median |
| --- | --- | --- | --- |
| Named, on the user's word | 1,821 | 0.074 / 0.248 / 0.601 | 0.279 / 0.424 / 0.847 |
| Named, Otos's guess | 1,340 | 0.029 / 0.187 / 0.612 | 0.108 / 0.381 / 0.755 |
| Other unnamed people | 642 | 0.201 / 0.371 / 0.738 | 0.312 / 0.493 / 0.898 |
| Person 18 | 13 | 0.012 / 0.012 / 0.077 | 0.012 / 0.013 / 0.127 |
| No person | 1,016 | 0.013 / 0.293 / 0.702 | 0.038 / 0.373 / 0.851 |

**The crop:** the context crop separates better. The aligned crop shows the classifier only
skin and features, and with them a real face reads as low as 0.03.

**Faces turned away by a context-crop cut** (person 18 out of 13):

| Cut | User's faces | Guesses | Person 18 | No person |
| --- | --- | --- | --- | --- |
| 0.1 | 0 | 0 | 5 | 2 |
| 0.2 | 0 | 1 | 7 | 5 |
| 0.3 | 4 | 6 | 8 | 6 |
| 0.5 | 54 | 57 | 11 | 45 |

**Cut chosen: 0.2.** No face the user named is lost, and every face it removes was checked by
eye.
- **Person 18 (7):** the bucket, the pixel art, the drawing, the mascot, the storefront, the
  framed pictures, the clasped hands. They read 0.01 to 0.13, labelled `material`, `art`,
  `structure` and similar.
- **Elsewhere (6):**
  - **Not faces (3):** a cartoon avatar, a car tyre, a hand.
  - **Real but hidden (3):** a child behind a paper mask, a child behind a net, and a photo of
    a named adult printed on a document.
- **Kept from person 18:** the lace (0.23), the carved puppet (0.43), and the four real
  children (0.33 to 0.62).

**The labelled set:** `tools/cropclass` ran the same request on run 2's 192 px review crops,
which frame each face at about half the square, as the context crop does. Of the 2,196 faces
the owner labelled, 1 reads under 0.2 (one of Sam's, at 0.187, labelled `structure` and
`furniture`). The 744 children's faces have a minimum of 0.187 and a 1st percentile of 0.440.
47 of the 2,253 unlabelled detections read under 0.2.

**Cost:** `tools/faceclass` took 14 min for 10,954 classifications: about 80 ms each, including
reading and writing the crops. Decoding the original each face comes from takes about 1.5 s.

## 4. Seeds that no longer stand

Admission alone leaves person 18 standing:
- **Its seeds stay.** Its four seeds were the two costumed children (both Halloween) and two
  objects. Re-reading under the classifier removes the objects, and the two children carry
  their seed mark over by their boxes (`FaceCarryOver`).
- **Seeds anchor until the user moves them.** So the person keeps the costumed and upside-down
  children and the puppet, chained at 0.45 to 0.60.

**The rule that dissolves it:** a person the user said nothing about keeps its seeds only while
they span two or more days, which is what a new person needs in the first place. Here the seeds
left are from one day, so they lapse. They and their guesses go back to being Otos's to decide,
and the person, with no face left, is forgotten.

**Links at 0.65 or more among what is left:**
- **The two costume faces:** 0.81 to each other.
- **The upside-down child:** 0.57 and 0.60 to them.
- **The puppet:** 0.45.

So no new group forms. The two costume faces link to each other but are from one day.
