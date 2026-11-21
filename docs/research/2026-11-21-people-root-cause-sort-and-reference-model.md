# People: where its fixes come from, and a reference model of its acts (2026-11-21)

Plan 0117's closing question was why People takes the most fixes (41 of 202 in two weeks).
This pass did two things:

- Sorted every People fix by root cause, against a criterion set in advance.
- Built a reference model of People's acts and ran it against the catalog.

## The root-cause sort

All 46 `fix:` commits on `main` touching People or faces between 2026-10-20 and 2026-11-21
(People shipped 2026-11-09). Each was read from its diff, or from its body, stat and test
names for the performance ones. Each was classified by:

- the bug a user saw;
- the cluster;
- the layer that held the defect;
- whether one domain rule had to change in two or more layers ("rule split");
- whether a model of the acts checked against the stored state would have caught it.

| Cluster | Fixes |
| --- | --- |
| When People recomputes (wakes, paging, cost, the disk floor) | 13 |
| Act timing in the window | 7 |
| What counts as a face read | 6 |
| Interaction and labels | 5 |
| Other (descriptions, a benchmark, diagnostics) | 5 |
| Merge rules | 3 |
| Assignment rules | 3 |
| Faces across copies and edits | 3 |
| Test harness | 1 |

| Layer that held the defect | Fixes |
| --- | --- |
| Store SQL | 12 |
| Window | 10 |
| Enrichment (the face readers) | 8 |
| Assignment | 7 |
| View | 5 |
| Models | 3 |
| Test | 1 |

**Criterion, set before the sort:** if 40 % or more of People's fixes trace to one rule
split across layers, that boundary gets one owner.

- **Result:** 8 of 46 (17 %), or 6 of 46 (13 %) strictly. The criterion is not met, so there
  is no People owner refactor.
- **Spread:** the splits are spread evenly over two boundaries.
  - Store ↔ window, 4 fixes: #728, #732, #781, #983.
  - Store ↔ assignment and models, 4 fixes: #720, #784, #789, #989.
- **Merge:** merge semantics are the common thread in 4 of the 8.

Catchable by a model of the acts: 8 of 46.

- Four are catchable at the store's level: #720, #727, #837, #989.
- Two more if the model includes copies: #784, #789.
- Two more if the acts go through the window's undo and merge question: #728, #732.

None of the recompute, act-timing or interaction fixes is catchable by such a model; that half
of People's fixes is scheduling and user interface, not rules.

## The reference model

`OtosTests/PeopleReferenceModelTests.swift` holds People's rules as a small in-memory statement
of what each act does to the stored faces, people and rejections. It walks six seeded random
sequences of 60 steps over ten photos of four generated people on twelve days. Each step is
one of:

- an act;
- an undo;
- a redo;
- a new reading of a photo;
- an assignment pass.

After every step it checks the catalog's own tables, read beside the store.

- **Each act** must match the model exactly, refusals included. A merge's one choice by
  likeness, which face of a photo both people are in stays theirs, is checked for legality
  instead: exactly one survivor, and it was one of the candidates.
- **An undo performed at once** must restore the catalog exactly, and its redo and second undo
  must too.
- **Every step** must keep the rules no single act owns:
  - no row the reader refuses;
  - a person in a photo once;
  - no held or rejected face given back;
  - one key photo per person;
  - no face before its person's birthday;
  - `person_photo` exactly what the faces say.
- **A pass** must leave the user's word, held faces, marks and the people the user named as
  they were.
- **Coverage:** each walk must perform at least 15 acts and find people, so a walk that tests
  nothing fails.

### What it found

The first runs passed in 1.3 s, which was too fast to trust. The coverage counts showed zero
acts performed. The fixture's `sizeOffset` makes a reading claim another preview's bytes,
which the store rejects whole (`aReadingOfOtherBytesStoresNoFaces`), so no face was stored.
`theGallerysStoredFactsEqualAComputationFromScratch` passed a random `sizeOffset` too. Since
#671 (2026-11-12) it has most likely compared an empty People: about 999 readings in 1,000
were rejected, and nothing checked whether any landed. Both walks now read the preview as
stored, and both now check that people were actually found.

With faces stored, the walks found four defects, each now fixed with its own regression test:

1. **A face People leaves out and that comes back is never compared again.**
   - **Cause:** the snapshot left out faces marked not a face, photos in the Trash and Live
     Photo movies, so the vector store dropped their vectors. Vectors are read only above the
     highest number held. On Undo or Put Back the face returned with its old vector, which no
     read ever fetched.
   - **Effect:** every pass then found a vector missing, never recorded itself settled, and
     left the face unassigned until the next launch. `settle()` looped forever, with
     `missing=1 written=0` on every pass.
   - **Fix:** the snapshot names the vectors of the faces it sets aside, and only a vector no
     stored face names is dropped (`PeopleSnapshot.setAsideVectors`, `heldVectors`).
   - **Test:** `aFaceThatComesBackIsComparedAgain`.
2. **A merge carried a rejection onto the merged person's own face.**
   - **Cause:** a face the user said is not Sam, then gave Ian, was "not Ian" yet Ian's
     once Sam was merged into Ian.
   - **Fix:** the merge carries rejections except onto a face that is the merged person's.
   - **Test:** `aMergeCarriesNoRejectionOntoTheMergedPersonsOwnFace`.
3. **The store accepted a merge of a person into themself.**
   - **Cause:** deleting the person merged away deleted them, and `ON DELETE SET NULL` left
     their seeds with no person but still marked seeds. The reader takes such a row as open
     (`FaceAssignmentColumn.assignment`), while every write tests the column, so assignment
     planned the same new person on every pass and the catalog refused half its seeds. Person
     IDs climbed 56, 57, 58, and the pass never settled.
   - **Reach:** no surface offers the act (the window's merge targets exclude the person), so
     only the owner's boundary was open.
   - **Fix:** the store refuses it (`PeopleRuleViolation.mergeIntoSelf`).
   - **Test:** `aPersonIsNeverMergedIntoThemself`.
4. **A new reading of a cover's photo changed the gallery without saying so.**
   - **Cause:** `writeFaces` deletes and reinserts the photo's face rows, and the foreign key
     clears `person_summary`'s cover. The write announced only `.faces`. The change-coverage
     guard (#993) caught it on the model's walk.
   - **Fix:** the reading names `.peopleGallery` when the photo held a cover, from
     `idx_person_summary_cover`.

### What the model proved about itself

- A bug planted in the model (Move keeping a rejection of the person it gives the face to) was
  reported as "rejection missing" on two seeds.
- The model's two false alarms were the walk's own:
  - re-reading a photo under a new date;
  - a pass deleting a person with the rejections that named them (a cascade, and correct).

  The walk keeps a photo's date, and the pass rule allows that cascade.

## Open observations

- **A photo's date can move under a face's person.** A new reading that dates the photo before
  its person's birthday keeps the user's face and seeds there: the birthday rule runs at Set
  Birthday and Merge, not at a reading. This happens only when a file's capture date changes
  after it was named. Nothing in this pass decides which word wins.
- **A hidden person's merge is refused only in the window** (#743). The store accepts it. No
  surface sends it, so the window's rule is the only statement of it.
- **The reader and the writers disagree about a face whose person row is gone.** The reader
  reads such a row as open; the writers test the column. With self-merge refused, the paths
  left that orphan a row (Undo of New Person after a pass guessed for them) leave only guesses,
  which both read as guessable. A schema trigger that resets a deleted person's faces would
  make the two agree by construction.
- **The model covers the store, not the window.** The two window-side splits (#728, #732) and
  copies (#784, #789) are outside it.

## Sources

- `git log` and `git show` of every commit named above.
- `OtosKit/Stores/CatalogStore.swift`: `perform`, `restore`, `mergePerson`, `touched`,
  `applyPreviewFaces`, `peopleSnapshot`.
- `OtosKit/Services/PeopleAssignment.swift`: `settle`, `readThenAssign`, `syncVectors`,
  `FaceVectorStore.keep`.
- `docs/adr/0047-face-recognition.md`.
