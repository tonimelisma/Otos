# Face accuracy after the 2026-11-12 and 2026-11-13 face changes (2026-11-14)

Question: `script/face-accuracy.sh` last ran on 2026-11-12, before the unrecognisable-face rule
(#679, `FaceRecognisability`), unit-length embeddings (#691), the assignment's pointer reads
(#722), `PersonBirthday` (#721) and the face-read outcomes (#720, #727). Do the reference labels
still read the same?

## Method

`script/face-accuracy.sh` on main at 14dc81c7 over the three labelled sets the earlier runs
used, all in the research folder outside the repository: run 2's research labels
(`run2/accuracy-set.json`), the reference catalog's labels read from originals
(`run4/full/set-original.json`) and from the preview at revision 3
(`run4/rev3/rev3/f028/set-preview.json`). Then once more on the originals set with
`FaceRecognisability.limit` raised to 2.0 in a scratch build, so no face is unrecognisable.

## Results

| Set | Run | people | wrong | siblings | unassigned | split | corrections | children |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Research labels | 2026-11-12, cold / seeded | 102 / 94 | 10 / 5 | 0 / 1 | 33 / 20 | 18 / 7 | 10 moves | 224/225, 487/487, 32/32 |
| Research labels | 2026-11-14, cold / seeded | 99 / 91 | 10 / 5 | 0 / 1 | 33 / 20 | 18 / 7 | 10 moves | 224/225, 487/487, 32/32 |
| Reference catalog, originals | 2026-11-12 | 30 / 26 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | none | 819/819, 1000/1000 |
| Reference catalog, originals | 2026-11-14 | 29 / 25 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | none | 819/819, 1000/1000 |
| Reference catalog, originals, no unrecognisable faces | 2026-11-14 | 30 / 26 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | none | 819/819, 1000/1000 |
| Reference catalog, preview rev 3 | 2026-11-12 | 31 / 27 | 0 / 0 | 0 / 0 | 0 / 0 | 1 / 0 | none | 806/806, 986/986 |
| Reference catalog, preview rev 3 | 2026-11-14 | 30 / 26 | 0 / 0 | 0 / 0 | 0 / 0 | 1 / 0 | none | 806/806, 986/986 |

## Conclusions

- Every labelled measure is unchanged: no labelled face moved, no sibling is confused, the
  children are reached as before, and the corrections are the same.
- Each set finds one person fewer, in the cold start and seeded alike. With the
  unrecognisable-face rule off the originals set finds 30 and 26 again, so the missing person
  is the one #679 meant to stop: unrecognisable faces of different people chained into an
  unnamed person of their own (`docs/research/2026-11-13-unrecognisable-faces.md`). The
  labelled measures did not move with it, so its removal cost no labelled face a person.
- No regression.
