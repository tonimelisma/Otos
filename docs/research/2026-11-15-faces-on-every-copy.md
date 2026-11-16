# A photo's faces on every copy, its copies read once each, and choices on every held copy (2026-11-15)

Supports ADR 0047's "A photo's copies" and ADR 0054's sections on faces and the window's held
choices: the three things #784 reported and did not fix.

## Questions

1. Are two identical copies — a library file and its Immich mirror — read for faces from the
   same pixels, so that one reading could serve both?
2. What do the new reads cost on an owner-shaped catalog: the copies People resolves a photo's
   faces through, and the unchecked tally that counts a photo once?

## 1. Not the same pixels

What each copy's faces are read from (`PreviewFaceReader`, `PreviewFaceSQL.previewSize`):

| copy | stored preview | drawn by | size |
| --- | --- | --- | --- |
| library file | Otos's rendering (ADR 0035) | RAW9 for a RAW, Image I/O otherwise | 2560 px long edge, HEIC |
| Immich asset (mirror or upload) | the server's `preview` (ADR 0046 §7), until its original is local for another reason | libvips, RAW development included | 1440 px short edge (admin-configurable), JPEG |

So the same bytes reach `FaceAnalyzer` as two different images: a different size, a different
encoder, and for a RAW a different development. The 2026-11-12 measurement of one decoder at two
sizes (`2026-11-12-faces-from-the-preview.md`) already shows what that does to a reading:
Vision's quality score moves by a median −0.014, 39 % of the faces between 0.30 and 0.35 on one
are lost on the other, and RAWs, read through a different development, have embeddings below
0.9 cosine. The two copies' readings therefore hold different face sets and slightly different
boxes, and a box read from one cannot be drawn on the other's pixels.

**Conclusion:** keep reading every copy for its own faces. Electing one copy's reading would
need a correspondence between two different detections, a move of the user's acts whenever the
elected copy changes with availability, and outlines drawn on pixels they were not read from.
Instead every surface resolves the photo's faces through the copies relation, and every count
counts the photo once.

Work this keeps: one preview reading per copy, stamped and never repeated, so on the owner's
shape 16,000 readings more than photos (the mirrors' account copies), once.

## 2. Cost of the new reads

Method as `2026-11-15-photo-level-copies.md`, and no owner data read: one generated catalog,
built by a test that was not committed, migrated to v64 and `ANALYZE`d. 166,000 rows: 16,000
library rows, 150,000 account rows of which the first 16,000 mirror the library (same SHA-1).
Faces: one person on all 16,000 mirrored photos, on both copies (32,000 faces), one on 1,660
unmirrored account rows, one on 24. Pages are the misses of a fresh read-only connection with no
memory map (`SQLITE_DBSTATUS_CACHE_MISS`); times are the best of three, on a machine running
other sessions' checks.

| read | rows | pages | best ms |
| --- | --- | --- | --- |
| copies of photos with faces (new, once per People pass) | 32,000 copies of 16,000 photos, from 33,684 faces | 4,024 | 181 |
| unchecked tally, nothing owed: `origin/main` | 0 | 18 | 0 |
| unchecked tally, nothing owed: this change | 0 | 18 | 1 |
| unchecked tally, the mirrors' account copies owed: `origin/main` | 16,000 | 1,081 | 4 |
| unchecked tally, the mirrors' account copies owed: this change | 16,000 | 2,540 | 42 |
| unchecked tally, every still owed (a first sync): `origin/main` | 166,000 | 8,792 | 40 |
| unchecked tally, every still owed (a first sync): this change | 150,000 | 11,705 | 163 |

- The copies read seeks each file with a face by its key and only a file with a present copy
  reads the digest index (`SEARCH face_copy USING COVERING INDEX idx_media_asset_content_sha1`);
  it never scans `media_asset`.
- The tally reads the rows it read before from their partial indexes; a row with a present copy
  adds one digest-index seek (`SEARCH copy USING INDEX idx_media_asset_content_sha1`). With
  nothing owed, the steady state, its cost is unchanged. While a first sync owes every still it
  costs about 120 ms more per tally, off the main actor, and it now says 150,000 photos rather
  than 166,000 files: the 16,000 mirrored photos were counted twice.
- With only the mirrors' account copies owed, the photos are still not checked on every copy,
  so the tally says 16,000 either way; it counts a photo once, not a photo as checked by one copy.

## Conclusions

- Keep the copies read a read of its own, once per People pass: 181 ms for 16,000 mirrored
  photos with faces, against a pass that reads and assigns every face.
- Keep the tally's copy test inside its counts. Its cost falls on a sync that owes thousands of
  previews, off the main actor; a cheaper test by the shown copy alone would call a photo
  checked while one of its copies is still unread.
- Benchmarks were not run for this change, by the owner's rule; the evidence is the page
  counts above and the plan tests (`PhotoCopiesTests`, `CatalogStoreQueryPlanTests`).
