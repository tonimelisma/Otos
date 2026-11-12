# Unrecognisable faces: the direction AdaFace gives a face it cannot tell anyone by

Date: 2026-11-13. Question: after the person rule turned objects away
(`docs/research/2026-11-12-face-person-admission.md`), a new unnamed person formed from real
faces of different people that the model cannot tell apart. What do they share, and how does
assignment keep them apart?

**Answer:** AdaFace places such faces near one common direction, whoever they show. That
direction is the mean embedding of face crops blurred until no identity is left. A face whose
cosine with it reaches 0.2 is unrecognisable. Otos never guesses it, groups it, or compares
another face with it, and a bare person's unrecognisable seeds lapse. Decision: ADR 0047.

The research material is in `~/Development/Otos-face-research` (owner photos, never
committed). The tools named below are in its `tools/`, and the numbers come from its `run3/`.

## 1. What the new person was

Catalog person 47 of the installed app formed while the library was being re-read from
previews (analysis revision 3). It had 12 faces:
- a baby drinking from a bottle;
- a small round avatar photo;
- a child photographed upside down;
- the two Halloween costume faces and the same baby again;
- a man and a woman in large sunglasses and caps;
- a baby in a pink sun hat;
- a red-haired toddler biting a toy;
- a bald man in profile;
- the lace that the person rule kept (0.23).

**What it was:** they are different people, yet their seeds link at 0.68 to 0.81, well above
the 0.434 at which only 0.1% of different-person pairs match. It spans four days, so the
two-day rule could not dissolve it.

## 2. The direction

**Building it:** `tools/blurcrops` shrinks aligned 112 px crops to 8 px and enlarges them back,
which leaves no identity. `tools/facenorm crops` embeds them with the shipped model, and the
direction is their normalised mean.

**Two sources agree.** Built from 221 run-1 crops and from 400 run-2 crops, the two directions
have a cosine of 0.943. Crops shrunk only to 12 px keep some identity: that direction agrees
with the 8 px one at 0.701 and separates worse (below). Otos ships the 400-crop, 8 px direction.

**Measured on the live catalog's stored embeddings**, cosine with the run-2 8 px direction:

| Faces | n | highest | over 0.2 |
| --- | --- | --- | --- |
| Named, on the user's word | 1,821 | 0.092 | 0 |
| Named, Otos's guess | 3,314 | 0.183 | 0 |
| Other unnamed people | 1,286 | under 0.14 | 0 |
| Person 47 | 12 | (lowest 0.223) | 12 |
| No person | 1,216 | 0.316 | 2 |

The 12 px direction puts 6 to 9 of person 47 under 0.2 and reaches 0.189 on a face the user
named, so it was not used.

**On the labelled set:** with the direction built from run 1's crops, the stored embeddings of
run 2 show the following.
- **Labelled faces:** 1 of the 2,196 reaches 0.2 (one adult face, 0.21).
- **Children:** none of the 744 children's faces does (highest 0.190).
- **Unlabelled detections:** 114 of 2,253 do. Checked by eye, they are misaligned and sideways
  crops, extreme close-ups, babies seen from above, and objects.

## 3. What assignment does with them

**The rule is in assignment, not admission.** An unrecognisable face is still a face. It is
stored and shown, and the user can name it. Only its embedding says nothing about who it is.

**What assignment does:**
- **No guess, no group:** it is never a face to guess and never grouped into a new person.
- **No comparison:** it is never evidence a face is compared with, and it never counts toward a
  person's likeness or ranking.
- **It still holds its photo:** given a person on the user's word, it keeps that person out of
  the rest of its photo, so the hard rule still holds.
- **Its seeds lapse:** a bare person keeps none of its unrecognisable seeds, and the two-day
  rule counts only the recognisable ones. Person 47's seeds are all unrecognisable, so it
  dissolves.

**No re-read:** the rule reads only stored embeddings, so nothing is analysed again.

**The direction belongs to the model:** a new model needs a new one, built the same way.
