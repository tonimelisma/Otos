# Derived owners' rebuilds, People's face check, stack candidates, truncated AVIs (2026-11-14)

## Questions

1. Duplicates and People rebuilt on every catalog change other than added rows. What does each
   one's answer depend on? How often did a change outside those facts rebuild them?
2. Does a partial index of the faces given a person make the People scope's face check cheap?
3. Can an index remove the table reads from the stack candidates' read?
4. Do the three truncated MJPEG AVIs answer AVFoundation's `unknown` (-11800) over -12344 as
   reliably as the codes already counted as verdicts?

## Method

- The installed app's unified log, last three hours on 2026-11-14 (`script/logs.sh show
  --last 3h`): every `duplicates.groups`, `people.assignment` and
  `catalog.enrichment.batch` line.
- The reads of `DuplicatesProjection.build` (`duplicateCopies`, `samePhotoCandidates`,
  `samePhotoDetails`) and `CatalogStore.peopleSnapshot` (faces, people, stacks, the
  unchecked tally), column by column.
- A clone of `build/catalog-backups/catalog-v53-before-v55.sqlite` in the worktree's
  `build/`, opened only by `sqlite3` 3.54 and Python's `sqlite3` and deleted afterwards. A
  cold read means the first read of a freshly cloned file, which has its own page cache.
- AVFoundation on synthetic files (`ffmpeg` `testsrc`, MJPEG with and without PCM, H.264
  MP4 and MOV) truncated at 2–90%. A small probe read each file's frames the way
  `VideoFaceReader.frames` does: six samples, zero tolerance. The same probe read the
  owner's three AVIs, which are local (no `SF_DATALESS`). Nothing else read them.

## Findings

### 1. What each derived owner reads, and what woke it

In three hours the installed app built the duplicate groups 231 times, 6–9 s each when
quiet (one 78-minute build at launch). It ran People 139 times, a pass reading for 9 s and
assigning for 25 s. Over the same window, 117 `people.applyAssignment` writes (faces) each
rebuilt the duplicate groups, which read no face. Digest and render-signature writes
(`.copies`) each re-ran People, which reads neither. The enrichment batches named
`captureDate,detail` 154 times, `faces,detail` 46, `location,faces,detail` 20,
`captureDate,location,detail` 54 and `detail` alone 13.

`.detail` covered thumbnails, previews, edits and the bytes' metadata record. Both owners
read some of those:

- The same-photo rule compares the record (dimensions, orientation, camera, serial,
  capture instant) and a render signature that is current only for the thumbnail it was
  read from. A group lists whether a copy is edited.
- A face's tile is cut from the photo's preview, with its edit, or from a video's face
  frames.

So `.detail` is split. `.images` is a row's thumbnail, preview, face frames and the edit
they show. `.mediaRecord` is the record's facts beyond date, kind, grouping and location.
`.detail` keeps what only a tile, a pane or enrichment reads. Each owner names what its
answer is built from:

- `DuplicatesProjection.inputs`: rows shown, grouping, copies, kinds, capture dates, the
  record, choices, images.
- `PeopleAssignment.inputs`: faces, rows shown, grouping (its stacks), kinds, capture dates,
  choices (stack keys), images.

A clearing of a malformed face row's stamp now also names `.faces`, because it changes
People's unchecked tally.

The benchmark case `projection.derived.afterFacesWrite` measures what a faces write costs
once the window and both owners settle, on the benchmark library (10,000 faces). It was run
three processes each, and the "before" run was the same tree with both owners asked on every
change:

| | M instructions | ms |
| --- | --- | --- |
| Both owners asked (before) | 8,008.1 | 559 |
| Each owner asked on its inputs (after) | 6,350.2 | 540 |

That is −20.7%, one duplicates build fewer. `script/bench.sh compare` against ccf36ae9
flagged no case. `immich.listing.batch500.of20k` went +0.9% within its 8.5% noise, and
`duplicates.build` and `people.pass.10k` each moved +0.1–0.2%.

### 2. People's face check

The People scope tests each row of the order with
`EXISTS (face of the photo, a person, not "not a face")`. It went through the face table's
key, which reads each face's row (embeddings included) to test the two columns. Over every
row of the copy (98,359 faces, 88,027 given a person, 67,109 photos matching):

| | Cold | Warm |
| --- | --- | --- |
| By the face table's key | 4.83 s | 0.44 s |
| `idx_face_assigned_photo` (partial: `person_id IS NOT NULL AND is_not_face = 0`) | 0.13 s | 0.13–0.15 s |

The plan is `SEARCH face EXISTS USING INDEX idx_face_assigned_photo (library_root_id=? AND
relative_path=?)`. Building the index took 0.7 s on the copy. It is added as v57.

### 3. Stack candidates

`PhotoStackSQL.candidateQuery` over every root of the copy returned 26,637 stills (10,917
RAW folders, 13 burst stills). With v55's indexes it reads each still's table row for the
columns it returns: 2.0 s cold, 0.14–0.17 s warm.

- Widening `idx_media_asset_stack_candidate` with the returned columns: 0.65 s cold and
  0.19 s warm. The index grows by 117 MB, and a whole-index read sharing it (kinds and
  formats over every root) went from 6.3 s to 8.3 s cold.
- A separate partial covering index over stills: 0.57 s cold and 0.12 s warm. It adds
  110 MB, and an index entry for every still the listing writes. That is the insert path of
  the flagged `immich.listing.batch500.of20k` case.

Neither is added. The read runs inside an order read. Since #745 an order read happens only
when a fact it depends on moves, and with whole-second capture times (#746) most stills'
reads no longer move one. What is left is about 1.4 s on a cold first grid, which does not
pay for either index's cost.

### 4. The truncated AVIs

| File | AVFoundation |
| --- | --- |
| Intact MJPEG AVI, with and without PCM | `decodeFailed` (-11821) over -12911 |
| The same, truncated at 2, 10, 30, 60, 90% (10 files, read twice) | `unknown` (-11800) over -12344, every read |
| Intact H.264 MP4 and MOV | decoded |
| Truncated MP4 (30, 90%) | -11821 over -12911 |
| Truncated MOV (30, 90%) | `fileFailedToParse` (-11829) over -12848 |
| The owner's three AVIs | -11800 over -12344 |

In the installed app's log the pair came only from those three AVIs. They had 9 reads each
in three hours, never a different answer. The one other `unknown` seen
(`docs/research/2026-11-14-videos-avfoundation-cannot-decode.md`) was over -17761, from
MKVs during an outage. The pair identifies a truncated AVI the way the parse codes identify
unparsable bytes. `VideoFaceReader.isUndecodable` now counts `unknown` over
`NSOSStatusErrorDomain` -12344 as a verdict, and every other `unknown` as a failed read. A
verdict is keyed to the file's size and modification time and to the decoder's identity, so
a changed file or a new macOS reads it again.
