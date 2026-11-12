# Face auto-assignment (2026-11-12)

**Question.** The owner redesigned People around auto-tagged faces (2026-11-12): every face
goes to its most likely person, siblings included, with no review queue, and named and
unnamed people are one kind (ADR 0047, `docs/design/people.md`). How many faces does
assignment then give the wrong person, how much of each child does it reach, and how much
work is it for the user to correct? Which margin should separate a face that is evidence
for the next year from a close call that is only guessed?

## Method

The owner's labelled set from 2026-11-07 (`docs/research/2026-11-07-face-recognition-models.md`):
3,293 faces, 2,196 of them labelled across 33 people, including the three children, with
the shipped AdaFace IR-101 embeddings. The set lives outside the repository.

`FaceAssignmentPolicy` was run three ways, first from a standalone harness compiled with
`swiftc -O` against the policy source, then through `script/face-accuracy.sh`
(`OtosTests/FaceAccuracyTests.swift`), which runs the same three:

- **Cold start:** nobody named. Each found person is judged by most of their labelled
  faces.
- **Seeded:** each person's most-photographed year given by the user, as the 2026-11-07
  review simulation seeded it.
- **Corrections:** from the cold start, every person named after most of their faces; then
  round after round the user moves the ten wrong faces least like their person, and
  assignment runs again, until nothing is wrong.

The rules measured: threshold 0.434 and the ± two-year window for anyone not known to be
an adult (both from 2026-11-07); chaining strongest first, round by round; a face whose
runner-up is within the margin goes to the best person but is evidence for nobody; faces
left over are grouped at 0.65 (ten links per face), and a group of two or more days is a
new person.

## Results

Margin sweep, seeded (wrong = labelled faces given someone else; sibling = a child given
another child):

| margin | wrong | sibling | Ian reached | split people | corrections from cold start |
| --- | --- | --- | --- | --- | --- |
| 0.00 | 14 | 10 | 215 / 225 | 6 | 17 |
| 0.04 | 12 | 8 | 217 / 225 | 6 | 17 |
| 0.08 | 11 | 7 | 218 / 225 | 6 | 17 |
| 0.12 | 12 | 8 | 217 / 225 | 6 | 10 |
| **0.16** | **5** | **1** | **224 / 225** | **6** | **10** |
| 0.20 | 5 | 1 | 224 / 225 | 7 | 10 |
| 0.30 | 3 | 1 | 224 / 225 | 8 | 7 |
| 0.40 | 2 | 1 | 223 / 225 | 10 | 7 |

Sam (487 faces) and Tyler (32) were reached in full at every margin up to 0.20; above
it Tyler loses a face and more people are split into pieces the user has to merge.

At 0.16, `script/face-accuracy.sh` (2026-11-12):

```
op=faceAccuracy phase=coldStart faces=3293 labelled=2196 people=102 wrongFaces=10 siblingWrong=0 unassignedLabelled=33 splitPeople=18
op=faceAccuracy phase=seeded people=94 wrongFaces=5 siblingWrong=1 unassignedLabelled=20 splitPeople=7
op=faceAccuracy phase=corrections moves=10 rounds=1 wrongLeft=0
```

with the children reached 224 / 225, 487 / 487 and 32 / 32 when seeded. Cold start: 102
people found, 10 labelled faces with the wrong person, no sibling among them, 33 labelled
faces left without a person (each seen on a single day or like no one else), and 18 extra
pieces of people split across found persons (the harness counted 11 people split; Sam
into five, one per stretch of years no chain bridged), which naming each piece the same
name merges. Corrections: one round of 10 moves leaves nothing wrong. (`splitPeople`
counts the pieces beyond the first, the margin table's column the people split.)

Assignment run on its own output — the seeds as anchors, the guesses stored — gives the
same guesses and finds nobody new (`assigningItsOwnOutputChangesNothing`); the harness
checked the same on the labelled set. Cost in the `-O` harness: 87 ms cold, 143 ms seeded,
for 3,293 faces.

For comparison, the confirm-first review of 2026-11-07 reached every child too, with 9
wrong suggestions out of 521, but each of the 521 had to be confirmed by hand.

## Conclusions

- **Margin 0.16.** Below it, sibling close calls chain wrongly (7–10 sibling errors); at
  0.16 there is one; above it, people split for little gain.
- **Close calls are guessed, never carried.** A guess between two siblings goes to the
  likelier, so every face has a person, but it never becomes evidence for the next year,
  which is what keeps the sibling errors from spreading.
- **The likeness sort is the correction tool.** Moving the ten faces least like their
  person per round cleared every error in one round here.
- **A split person is merged by name.** The cold start splits a child across the years no
  chain bridges; naming each piece the same name asks to merge them.
