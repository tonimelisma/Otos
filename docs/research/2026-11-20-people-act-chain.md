# People's act chain: where an act's shown result is owned, measured against its fixes (2026-11-20)

## Question

Plan 0117 step 2, "de-risk first". Is People's fragility caused by who owns an act's result
while it is shown before it lands? Today `PendingPeopleActs` holds it in the view model
(`Otos/ViewModels/CatalogWindowViewModelPeople.swift`), laid over the published People state
and retired by `CatalogPeopleState.covers`. The other acts are held by Projection instead: a
hide, a choice and a stack expansion. ADR 0004 rejects a view-model overlay for choices as "a
second owner of what is shown".

The plan sets the stop condition in advance. Stop if fewer than a third of the classified
People fixes are overlay timing, and no interleaving test fails on unmodified code.

## Method

1. **Classification.** I took every `fix:` commit on `main` from 2026-10-20 to 2026-11-20
   that touched a People, Face or Person file under `Otos/` (`git log --since=2026-10-20 --
   ':(glob)Otos/**/*People*' …`), 49 commits. Eight more fix commits have a People subject
   and touched only other files, making 57. Each was classified from its diff, not its
   subject, into exactly one root cause. A commit with several People parts was classified by
   its largest People product change.
2. **The act chain.** I traced the chain from the code at `5938d8dd`.
3. **Interleaving tests.** These ran on unmodified product code, with no test seam added. The
   view model is not started, and its People intents are taken off the stream by hand
   (`PeopleViewModelTests.Fixture(consumesIntents: false)`). Each test therefore delivers the
   competing event at the exact suspension it names: a People state, a second act, an undo or
   another merge. The store writes are real. Each answer's `covers` is set by the test, as
   the gallery's request numbering would set it.

## 1. Classification

| sha | PR | cause | what the People part fixed | deciding hunk |
| --- | --- | --- | --- | --- |
| 083a8ea8 | #985 | a | A named face's twin stayed Unidentified for 133 s. The pass the act asked for waited behind a memory hold, and is now promoted as a load the user waits on. Borderline (b). | Otos/Services/PeopleAssignment.swift:181 |
| d0a74c52 | #983 | c | The merge hard rule: a photo both people are in keeps the face most like the merged person. | Otos/Stores/CatalogStore.swift:2777 |
| ca01a04d | #980 | c | A VP9 video is undecodable before any frame, and a frame that cannot be decoded is read at its sync frame. | Otos/Services/VideoFaceReader.swift:101 |
| 0b810359 | #981 | e | Face outlines are removed from grid and filmstrip thumbnails. | Otos/ViewModels/CatalogWindowViewModelPeople.swift:1425 |
| 22c2d21e | #969 | e | No focus ring around the gallery. | Otos/Views/PeopleView.swift:137 |
| ed9454c2 | #958 | e | Face tiles hold a `DisplayImage` drawn off the main thread. | Otos/Views/FaceTileView.swift:55 |
| 12031093 | #937 | d | The faces read keys copies by `copy_key` (v79). | Otos/Stores/FaceStorage.swift:342 |
| 7138219e | #884 | b | At the free-space floor, only the vector reads and assignment are gated. | Otos/Services/PeopleAssignment.swift:291 |
| 62e160b4 | #883 | b | Faces are ordered by path bytes from the identity table. | Otos/Models/PeopleModels.swift:215 |
| c45bcd6d | #882 | b | One writer of the vector file, and a floor hold with a backoff wake. | Otos/Services/PeopleAssignment.swift:351 |
| 6479f179 | #880 | f | The People part is a measured-cost comment and a new memory test. | Otos/Views/FaceTileView.swift:134 |
| 6c973892 | #872 | b | The gallery reads only what a request owes. | Otos/Services/PeopleAssignment.swift:470 |
| 86433200 | #869 | b | The face reader holds its debt instead of draining every stale row on each ring. | Otos/Services/PreviewFaceReader.swift:168 |
| 4a2741c0 | #837 | b | Vectors written after the snapshot are kept, not re-read. | Otos/Services/PeopleAssignment.swift:627 |
| 63c02c9d | #828 | b | A date, kind or render of a faceless photo never wakes People. | Otos/Services/PeopleAssignment.swift:50 |
| fd928ae7 | #816 | b | People paints from stored facts, and assigns only when its inputs moved (v68). | Otos/Services/PeopleAssignment.swift:135 |
| 109ea194 | #812 | b | Copies come from the faces read's own row. Borderline (d). | Otos/Stores/FaceStorage.swift:343 |
| 5d80f22e | #807 | b | The face reader wakes only on facts its SQL reads. | Otos/Services/PreviewFaceReader.swift:89 |
| 191ffe1a | #789 | d | Every copy shows the photo's people, counted once. | Otos/Models/PeopleModels.swift:74 |
| 827a78cf | #788 | e | HIG alert-title casing and typographic quotes in refusals. | Otos/ViewModels/CatalogWindowViewModelPeople.swift:89 |
| 3f935cbe | #784 | d | A mirror's or an identical copy's files are one photo. | Otos/Models/PeopleModels.swift:70 |
| 5088b9c2 | #781 | a | An act's effect is shown from its submission (`PendingPeopleActs.shown`) and retired by a covering state. | Otos/ViewModels/CatalogWindowViewModelPeople.swift:122 |
| 79a24a5d | #778 | g | Scope navigation: the gallery shows by `detailPane`. | Otos/Views/PeopleView.swift:233 |
| c59912c8 | #774 | g | Scope navigation: `showsPeopleList` reads `detailSurface`. | Otos/ViewModels/CatalogWindowViewModelPeople.swift:364 |
| fe856c19 | #775 | g | A scope the user left does not act (APP-080). | Otos/ViewModels/CatalogWindowViewModelPeople.swift:691 |
| 059a0797 | #754 | g | Every gallery act goes through `inGallery`. | Otos/ViewModels/CatalogWindowViewModelPeople.swift:1159 |
| 1870af73 | #752 | b | Gallery render cost: equatable cells, and menus built as they open. | Otos/Views/PeopleView.swift:265 |
| 72dfc9b8 | #748 | c | A truncated AVI is a verdict. A smaller (b) part adds rebuild triggers. | Otos/Services/VideoFaceReader.swift:41 |
| eb5b0613 | #745 | b | The unread-faces counts walk partial indexes. | Otos/Stores/FaceStorage.swift:424 |
| ea6bd96d | #743 | e | Refusal and count wording names photos and videos. A hidden person is not draggable. | Otos/ViewModels/CatalogWindowViewModelPeople.swift:201 |
| 8d95d381 | #742 | a | A redo of a merge is numbered as that merge, so its answer lands on the person merged into. | Otos/ViewModels/CatalogWindowViewModelPeople.swift:90 |
| d6397ec5 | #741 | c | An undecodable video is stamped with its decoder's verdict. | Otos/Services/VideoFaceReader.swift:25 |
| 627a1e04 | #734 | a | A merge's own state arrived before its answer. The person merged away is kept until the answer (`PendingPeopleActs`, `reconcileShownPeople`). | Otos/ViewModels/CatalogWindowViewModelPeople.swift:90 |
| 6b1f5c84 | #727 | c | A failed face read is its own outcome, and a re-read keeps the user's word. | Otos/Services/PreviewFaceReader.swift:149 |
| 9748c1cc | #732 | a | A merge answered while an earlier act was unpublished was re-judged against the stale state and dropped. The store now judges it in stream order. | Otos/ViewModels/CatalogWindowViewModelPeople.swift:515 |
| 03ab15c3 | #730 | b | Rows only added run a tally-only pass. | Otos/Services/PeopleAssignment.swift:171 |
| 083bfdc4 | #728 | e | Sheet refusals, one `PersonMenu`, gallery keys. Borderline (a): it also adds `PeopleUndoRecord`'s write-back order. | Otos/ViewModels/CatalogWindowViewModelPeople.swift:508 |
| 85bad4be | #720 | c | An unread frame, a missing preview or a malformed row is never "no faces". | Otos/Services/VideoFaceReader.swift:56 |
| ad786690 | #700 | g | Build and test infrastructure: one Core ML model path per checkout. | Otos/Services/FaceEmbeddingModel.swift:34 |
| 0f0a26ce | #679 | c | An unrecognisable face is never guessed, grouped or compared. | Otos/Services/FaceAssignmentPolicy.swift:68 |
| e4df714c | #673 | e | A face tile is cut through the photo's edit. | Otos/Views/FaceTileView.swift:132 |
| 2885ed94 | #670 | c | A face is read only with a person seen around it, and a found person dissolves without two days of seeds. | Otos/Services/FaceAnalyzer.swift:173 |
| 760311f7 | #654 | e | Unnamed Person, Add Name…, and the face act titles. | Otos/Models/PeopleModels.swift:141 |
| ecd3d81f | #650 | b | FaceAnalyzer makes its `CIContext` lazily, a launch cost. | Otos/Services/FaceAnalyzer.swift:54 |
| 47840ae4 | #624 | b | Alignment sums named points, so the benchmark is steady. | Otos/Services/FaceAlignment.swift:28 |
| 8907221c | #644 | a | An undo revealed the restored person before the restore committed, and a redo bypassed the act path. | Otos/ViewModels/CatalogWindowViewModelPeople.swift:937 |
| ded2cb9d | #642 | e | Keys typed in the name field are the field's. | Otos/Views/PeopleReviewView.swift:318 |
| 0dcbbd8b | — | g | The app-wide local capture time (ADR 0039). People's part is dates. | Otos/Models/PeopleModels.swift:16 |
| 17f85200 | #620 | a | An acted face is hidden until a state at the act's committed revision arrives. | Otos/ViewModels/CatalogWindowViewModelPeople.swift:62 |
| f46bf4ba | #832 | f | The quiescence wait asks again what was published. | OtosTests/AsyncTestSupport.swift:121 |
| 6b5aca8d | #821 | f | The vector-read test waits for each read to be counted. | OtosTests/PeopleStoreTests.swift:536 |
| 3853e440 | #779 | b | A person scope too large to seek walks the order. | Otos/Stores/CatalogQueryGateway.swift:1576 |
| ad84ab33 | #765 | b | A person's photos are found from their faces' index. | Otos/Stores/CatalogQueryGateway.swift:1288 |
| f2a0247a | #735 | b | A held face model claims no video for its faces. | Otos/Services/EnrichmentSchedule.swift:332 |
| c6aeeec1 | #666 | e | A one-face photo menu puts its acts at the top level. | Otos/Models/MediaItemMenuModel.swift:83 |
| 7b773c03 | #646 | c | A still is decoded as its extension's type, so ARWs are read for faces. | Otos/Services/ImageRenderer.swift:175 |
| 743990ba | #620 | a | The merge commit of 17f85200: the same fix. | Otos/ViewModels/CatalogWindowViewModelPeople.swift:62 |

Key: (a) act overlay timing, retirement or ownership; (b) build cost or performance; (c)
face-reading or ML correctness; (d) copy identity (ADR 0054); (e) UI, keys or wording; (f)
test-only; (g) other.

| Cause | Commits |
| --- | --- |
| (a) overlay timing, retirement or ownership | 8: 7 distinct fixes, since 743990ba merges 17f85200 |
| (b) build cost or performance | 18 |
| (c) face reading or ML correctness | 9 |
| (d) copy identity | 3 |
| (e) UI, keys or wording | 10 |
| (f) test-only | 3 |
| (g) other | 6 |

**(a) is 8 of 57 (14 %), or 7 of 56 distinct fixes (12.5 %).** Counting both borderline
commits as (a), #728 and #985, gives 9 of 57 (16 %). Every way of counting stays under a third.

Three of the seven distinct (a) fixes are about merges and where the window lands (#734,
#742, #732). One was the first form of the overlay (#620 → #781). One is undo and redo
ordering (#644). One (#985) is load admission, not ownership: the act was shown at once, and
its twin's guess waited behind a memory hold. None would have been prevented by moving the
same overlay into Projection. The merge fixes are about which scope and filter the window
keeps, which is view-model state (`queryDescriptor`), not what Projection publishes.

## 2. The act chain

Every People act takes one path. The undo and redo of an act take it too, with
`PeopleIntent.flip` in place of `.perform`.

1. **Intent (main actor, synchronous).** `submitPeopleAct` (or `flipPeopleAct`) reads the act's
   known effect from what the window shows (`PeopleAct.overlay(in:faces:)`). It numbers the
   write (`PendingPeopleActs.submit`, request *r*), registers the undo, lays the effect over the
   published state (`showPendingPeopleActs`) and yields the intent on `peopleIntentStream`
   (`.unbounded`, one consumer).
   - *What can arrive before the consumer takes it:* more acts, undos and redos (each numbered
     *r+1*, …), People states (`applyPeopleState`), target changes, and the reads of the
     targets' faces. Nothing here awaits, so the only hazard is ordering, and the stream
     keeps it.
2. **Store write (`CatalogStore.perform` / `.restore`, awaited by the consumer).** One
   transaction. Before the await returns, it rings `notifyCatalogChanged(.changed(.faces))`.
   - *What can arrive during the await:* every People state the projection publishes, and
     every faces read, can reach the window. Some were read before the write and carry any
     `covers` the gallery gave out so far. Some were read after it, rung by its own change. A
     merge's own state can arrive with the person merged away already gone (#734). A library
     removal or Trash can change what the write finds; the store then refuses the act, and the
     answer withdraws it. More acts queue behind this one in the stream.
3. **Change notification → Projection (`actOnDelivered`).** `.faces` is in both
   `PeopleAssignment.inputs` and `PeopleGallery.inputs`, so the next pass forwards a request
   to each of them: assignment by unnamed rows, a whole pass, and the gallery by `request()`.
   - *What can arrive:* other catalog changes coalesced into the same pass, and a scope switch
     (a new query generation). Neither touches the People request numbers.
4. **`requestPeopleBuild` (consumer, after the write returned).**
   `PeopleAssignment.requestForUser()` (#985), then `PeopleGallery.request()`, returns *N*.
   That is the gallery's `OwnerActivity.requested` after this ring.
   - *What can arrive:* a gallery read already in flight finishes. It began from a request
     below *N*, so it publishes `covers < N`, and its read may predate the write. The gallery
     loop then reads again, because `requested != startedFrom`. That read began after
     `request()` returned, so after the write, and publishes `covers ≥ N`.
     **This covering state can be published before step 6** (below).
5. **`PeopleAssignment` pass, then the gallery facts.** The pass assigns and writes the
   guesses and `person_summary` facts that moved. It announces `.peopleGallery`, which rings
   the gallery again. For a rename, hide, favourite or key photo, the hash of the inputs is
   unchanged and nothing is written or announced (ADR 0047, "Work and placement"). The only
   gallery read after such an act is the one step 4 asked for.
6. **Answer (consumer, main actor).** `applyPeopleIntentEvent` fills the undo record
   (`record.restore`) and calls `didAnswerPeopleWrite(r, covers: N)`. That sets the entry's
   `covers`, and for a merge it runs `didMerge` and `reconcileShownPeople`. It neither looks
   at the People state already applied nor asks for a faces read.
7. **Projection publication → view model apply (`applyPeopleState`).** When
   `published != previous.people`, every entry with `covers ≤ published.covers` is marked as
   in People (`retire(coveredBy:)`). The effect still held is laid over `published`, and
   `refreshTargetFaces` rings a faces read asked with `landed = answered`. A read that lands
   with `landedThrough ≥ r` marks the entry as in the faces (`retireFaces(through:)`), and an
   entry in both leaves.
   - *Can a stale build arrive after a newer one?* No. The gallery reads in one loop, and its
     `covers` only grows. Projection takes the newest gallery build into every publication
     (`publishPeople`, and `publish` re-reads `people` after `preparePublication`'s await).
     The window applies the newest publication (`NewestValueMailbox`). So a state the window
     applies never covers less than the one before it. The tests still deliver older states,
     to show that no act depends on that.

Per act, what step 1 shows and what retires it:

| Act | Shown at submission | Retired by |
| --- | --- | --- |
| Name / Rename / Set Birthday (`.edit`) | the person's name and birthday | a state with `covers ≥ N` |
| Add to/Remove from Favorites, Hide/Unhide | the person's mark (and the gallery order) | the same |
| Make Key Photo | the cover tile | the same |
| Change to ▸ / Assign to ▸ (`.move`) | the face's person in the photo menus and Info | a state with `covers ≥ N`, and a faces read with `landedThrough ≥ r` |
| This Is Not X / Not the Same Person (`.removeName`) | the face with no person | the same |
| This Is Not a Face (`.notAFace`) | the face removed | the same |
| New Name… / Someone Else… with a new name (`.moveToNewPerson`) | nothing: it needs a read | — |
| Merge (`.merge`) | nothing: the person merged away is kept shown and filtered while it is outstanding (`isMergingAway`) | the answer: `didMerge`, then `reconcileShownPeople` |
| Undo | the effect the act replaced (`record.shown.before`); for a merge, nothing | as for the act |
| Redo | the act's effect; a redo of a merge is numbered as that merge (#742) | as for the act |

## 3. Interleaving tests

`OtosTests/PeopleActChainTests.swift`, on unmodified code:

| Test | Delivered at | Asserts |
| --- | --- | --- |
| `aStateReadBeforeTheWriteNeverTakesTheNameBack` | a pre-write state between submission and write; again between write and answer; again after the answer with an older `covers` | the name typed shows at every step; the covering state retires the act |
| `aCoveringStateBeforeTheAnswerKeepsTheHide` | the covering state between step 4 and step 6 | the person stays hidden through the state, the answer and a later state |
| `aStateCoveringTheActNeverTakesItsUndoBack` | the act's covering state while its undo is outstanding, and again after the undo's answer | the old name shows from ⌘Z on; the redo title is right |
| `twoMergesInFlightLandOnTheLastPersonMergedInto` | the state both merges publish, before either answer; a state between the two answers | the window never leaves for the gallery; it ends on the person both merged into, filter and selection with it |
| `aMergeUndoneBeforeItsAnswerEndsOnAPersonWhoExists` | ⌘Z before the merge is answered; the merge's own state before its answer | the window ends on the person merged into, who exists, as an undo after the answer leaves it; the person merged away is back |
| `aFaceActSurvivesReadsThatArriveBeforeItsAnswer` | the covering state, and the faces read it rings (asked before the answer), both before the answer | the face is Sam's on every surface at every step |

**All six pass on unmodified code.** No interleaving reverts what the window shows,
applies an act twice, or lands it or the window on the wrong person. They land on `main` as
guards.

### Findings: two retirement tests fail

**Fixed in the follow-up (`fix/people-act-retires-at-answer`):** `PendingPeopleActs` keeps the newest
People request an applied state covers (`builtThrough`), so an answer that arrives after its
covering state retires the act in its own step, and an answer to a landed act on faces rings
a read of the targets' faces. Both tests below now pass and live in `PeopleActChainTests`.

Two more tests assert ADR 0004's retirement rule itself, beyond what the window shows. An act
"retires when a state whose build covers the request the write's answer named arrives". Both
deliver that state *before* the answer, at the hop step 4 names. Neither lands on `main`.
They are kept on the local branch `test/people-act-chain-failing`, in
`OtosTests/PeopleActChainFindingsTests.swift`, for the follow-up. Run with
`script/check.sh --only PeopleActChainTests --only PeopleActChainFindingsTests`, the six above
passed and these two failed:

1. `aCoveringStateBeforeTheAnswerRetiresTheAct`: Hide Sam. The store writes. A state read
   after the write, covering 5, arrives. Then the answer, covering 5, arrives.
   - It fails at `PeopleActChainFindingsTests.swift:34`:
     `pendingPeopleActs.effect.isEmpty` is `false`. The effect is still
     `PersonEdit(isHidden: true)` for Sam.
   - What the window shows is still correct: Sam is hidden (line 33 passes).
2. `aCoveringStateBeforeTheAnswerRetiresTheFaceAct`: Change to ▸ Sam on the stranger's face.
   The store writes. The covering state arrives, and so does the faces read it rings, asked
   before the answer. Then the answer arrives.
   - It fails at `:60`: `targetPhotoFaces.landedThrough` is 0 while `answered` is 1. No read
     of the photo's faces is asked after the answer.
   - It fails again at `:64`: the face's `.person(Sam)` override is still held.
   - The face shows Sam (line 59 passes).

**Diagnosis.** `didAnswerPeopleWrite`
(`Otos/ViewModels/CatalogWindowViewModelPeople.swift:793`) records the answer's `covers`, but
never compares it with the People state already applied (`parts.people?.covers`). It does not
ring the faces read either (`facesReadDoorbell`). Retirement happens only in `applyPeopleState`
and `applyTargetPhotoFaces`, so a covering state or read that arrived first retires nothing. The
act then stays laid over every later state until some other People state arrives
(`applyPeopleState` runs only when `published != previous.people`). After a rename, hide,
favourite or key photo, assignment writes nothing (step 5), so on a quiet catalog that can be
the rest of the session.

**Reachability.** `PeopleGallery.request()` rings the gallery's loop from inside
`requestPeopleBuild`. The loop's read, the projection's republish and the relay into the
window's mailbox all run off the main actor. The answer waits for the intent consumer's
main-actor turn. Nothing orders the two, so the covering state can be applied first.

**Why the window still shows the truth.** The overlay is set-only: a lingering effect equals
the value the covering state already holds. Every change to a field it holds is a People
write or a catalog change of a kind the gallery reads (`.faces`, `.membership`, `.faceTiles`,
`.peopleGallery`). Each of those rings a gallery read whose state has a larger `covers`, and
that state retires the lingering act in the same apply. So the defect is latent today. It
breaks ADR 0004's retirement rule, it costs a re-sort of the people on every People apply
while it lingers, and it would show a stale value the day any People fact can change without
a gallery read.

**Its fix does not need a new owner.** In the step that applies the answer, retire against
the People state already applied and ring the faces read. A Projection hold that set its
retirement point from the store's answer would need the same comparison.

## Stop condition

The plan stops step 2 if fewer than a third of the classified fixes are overlay timing and no
interleaving test fails.

- **The fix share: 8 of 57 (14 %), well under a third.** Most People fixes are build cost (18),
  UI and wording (10) and face reading (9). Of the seven distinct overlay fixes, three are
  where a merge leaves the window's scope and filter. That is view-model navigation state,
  which a Projection hold would not own.
- **The interleavings.** All six tests of what the window shows pass. The two that fail
  assert the retirement rule itself. The fault is one omission in the answer step, and the
  window shows the truth throughout.

**Verdict: stop the owner change.** Moving `PendingPeopleActs` into Projection removes neither
the fixes' causes nor the one defect found. The defect gets its own `fix:` increment, which
retires at the answer against the applied state, using the two tests on
`test/people-act-chain-failing`. The plan's step 2 is closed as stopped, with this note as
its evidence.

## Sources

- `Otos/ViewModels/CatalogWindowViewModelPeople.swift`: `PendingPeopleActs`,
  `submitPeopleAct`, `flipPeopleAct`, `runPeopleIntent`, `applyPeopleIntentEvent`,
  `didAnswerPeopleWrite`, `applyPeopleState`, `applyTargetPhotoFaces`.
- `Otos/Services/PeopleAssignment.swift`: `PeopleGallery.request()`, `read()`,
  `PeopleAssignment.requestForUser()`.
- `Otos/Services/CatalogProjection.swift`: `requestPeopleBuild`, `publishPeople`, `publish`,
  `removeContinuation`.
- `Otos/Stores/CatalogStore.swift`: `perform(_:)` and `restore(_:)`.
- ADR 0004 ("Every other act is shown first too"), ADR 0047 ("Work and placement", "Which
  person the window shows"), ADR 0054, ADR 0032.
