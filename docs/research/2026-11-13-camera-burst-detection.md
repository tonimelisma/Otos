# Camera bursts: what the reference library says about detecting them

Date: 2026-11-13. Plan 0115 increment 6, ADR 0052. Question: can Otos stack a camera's
continuous-shooting burst the way it stacks an iPhone burst, from facts it already reads,
without guessing?

## Method

Read-only queries against the installed catalog (166,531 rows, 46,322 metadata records). For
each camera model, each record's `original` capture timestamp plus its sub-second digits
(`metadata_extra_json.timestamps`), one shot per exact capture time, so a RAW and its HEIF or
JPEG count once, also on the Immich account where they sit in different folders. Then the gaps
between consecutive shots, and the runs a gap threshold would join. One local a6700 RAW (not a
cloud placeholder, so nothing was downloaded) was read with ExifTool 13.55 for its maker note.

## Findings

**Which cameras.** The Sony ILCE-6700 dominates: 9,970 shots with sub-seconds. Then the
iPhone 15 Pro (1,309), the iPhone 18 Pro (585) and a Nikon Z 8 (7).

**Gaps between consecutive a6700 shots:**

| Gap | Shots |
| --- | --- |
| ≤ 0.15 s | 58 |
| 0.15–0.3 s | 630 |
| 0.3–0.5 s | 1,378 |
| 0.5–1 s | 2,235 |
| 1–2 s | 1,536 |
| > 2 s | 4,132 |

The a6700's continuous modes shoot at about 11, 8, 6 and 3 frames a second, gaps of 0.09–0.33 s.
The library shows no cluster there: gaps rise smoothly into the 0.3–1 s range of quick
single shots. A threshold therefore decides by itself what a burst is:

| Join gaps up to | Runs | Shots in runs | Share of shots | Longest |
| --- | --- | --- | --- | --- |
| 0.15 s | 23 | 81 | 0.8 % | 15 |
| 0.3 s | 316 | 1,004 | 10.1 % | 15 |
| 0.5 s | 870 | 2,936 | 29.4 % | 26 |

Between 0.15 s and 0.5 s the stacked share grows 36-fold with no break that would mark the
right value. Any threshold either misses Lo-speed bursts (0.33 s) or swallows deliberate quick
single shots.

**The camera says what it did.** The a6700's maker note records its drive mode per frame. The
sampled RAW, a single shot, reads `ReleaseMode: Normal`, `ReleaseMode2: Normal`,
`SequenceNumber: Single`, `SequenceImageNumber: 1`, `SequenceLength: 1 file` (ExifTool's Sony
tags). A continuous burst writes a continuous release mode and numbers its frames, so a burst
is a fact the file states, not a guess from timing. MediaMetadata does not read these tags today.

**The iPhones.** Their files carry no maker-note drive mode Otos reads. Their bursts carry
Apple's burst identifier, which increment 4 stacks. Only 4 photos in the catalog carry one
(2 bursts): exports from Photos rarely keep every frame.

**A gap found on the way.** On the Immich account each asset sits in its own folder, so a RAW
and its HEIF are in different folders, and the pair rule (ARC-062: one folder, one stem key)
never pairs them. The account's Sony shots show twice. Immich groups such files itself (its
stacks); pairing them needs the account's own grouping read from the sync stream, not the
folder rule.

## Conclusion

- Timing alone cannot detect camera bursts in this library without inventing a threshold the
  data does not support. No timing rule should ship.
- The deterministic signal is the camera's own drive-mode record. A rule would be: consecutive
  frames from one body whose maker note says continuous release, numbered in sequence. That
  needs MediaMetadata to read Sony's `ReleaseMode` and `SequenceImageNumber` (and their Nikon
  and Canon counterparts for other bodies), then a metadata re-read from local bytes only
  (ADR 0039).
- Separately, the Immich account's RAW+HEIF pairs need the account's own stack data.

The drive-mode record was chosen (2026-11-13). MediaMetadata 0.9.5 reports it as
`continuousShootingFrame`, and Otos stacked a camera's frames by it (ADR 0052).

## Follow-up: the frame number does not bound a burst (2026-11-13)

A review found that "one camera's frames while their numbers rise in capture order" joins
bursts the user culled: burst A kept to its frame 2 and burst B, another day in another
folder, kept to its frames 3 and 5 read as one rising sequence, and a collapsed stack hid B's
keepers while Move to Trash on the tile took all three. Deleting a burst's frame 1 inside Otos
had the same effect. A rule needs a fact that names the sequence, not the frame's place in it.

What the a6700 records, read with ExifTool 13.55 from the 668 ARW files of the reference a6700 copied
into a research corpus outside the library (nothing in the library read or downloaded):

- `SequenceNumber` / `SequenceImageNumber` / `SequenceFileNumber`: the frame's place, 1 up.
- `ShutterCount` (Tag9050d, `0x000a`): ExifTool documents it as mechanical actuations only,
  "does not increase during electronic shutter". Across the corpus it reads 11142 on every
  shot from 23 to 25 May 2026 and 11146 from 29 to 31 May: it cannot tell two bursts apart.
- `ShotNumberSincePowerUp` (Tag9400c, `0x000a`): ExifTool lists the models it is valid for,
  and the ILCE-6700 is not one of them; the a6700 is not in Tag9400c's documented models.
  It would reset at every power-up even where valid.
- Undocumented Tag9400c bytes change from shot to shot, but no reference decodes them, and
  a rule built on them would be a guess.

Conclusion: no fact the a6700 records, as documented, bounds one sequence. Camera frames do
not stack (ADR 0052, schema v46); the frame number stays in each stored metadata record.

## Follow-up: the file-number rule is rejected too (2026-11-13)

Candidate: two frames of one camera in one folder are one burst exactly when, in capture
order, the difference of their camera file numbers (the digits of `DSC01234`) equals the
difference of their frame numbers. A burst writes its frames consecutively on the camera's
counter, so culled frames keep the equality.

- **The reference library cannot carry it.** Of the corpus's 668 ARW files, 667 are named by
  capture time (`YYYYMMDD_HHMMSS`, then `_001`, `_002`… for files sharing a second: 538 with
  no suffix, 108 `_001`, 18 `_002`, 4 `_003`) and one is `original.arw`. That is Otos's own
  import naming (`ImportNaming`, collision suffix `_%03d`), so an import removes the camera's
  counter, and the RAW itself records no file number (ExifTool finds no `FileNumber`,
  `ImageNumber` or `FolderNumber`). No file in the corpus can test the rule.
- **Counter-example: a trailing number that is not the counter.** Burst A's frames 1 and 2 in
  one second import as `20260503_104710` and `20260503_104710_001`; burst B three weeks later
  as `…_090000`, `…_090000_001`, `…_090000_002`, all in one `2026/05` folder. Keeping A2 and
  B3, the trailing digits differ by 1 and the frame numbers by 1: they join. A strict camera
  name pattern avoids this only by stacking nothing in the reference library.
- **Counter-example: a counter reset.** Two bursts satisfy the equality exactly when they
  started at the same counter value. Sony's `File Number: Reset` restarts the counter when a
  card is formatted: A at `DSC00004`–`DSC00006` kept to A2 (`DSC00005`), then B at
  `DSC00004`–`DSC00008` kept to B3 (`DSC00006`, free because A3 was deleted), imported with
  their names into one folder, differ by 1 in both and join.
- **Two bodies of one model.** The a6700 RAW carries no Exif `SerialNumber`, only the
  MakerNote's `InternalSerialNumber`, which MediaMetadata does not read for TIFF/ARW, so two
  a6700 bodies are one camera to Otos.

Conclusion: rejected; camera frames still do not stack (ADR 0052).
