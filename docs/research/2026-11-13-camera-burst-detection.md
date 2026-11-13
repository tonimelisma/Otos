# Camera bursts: what the owner's library says about detecting them

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

The owner decides whether camera bursts proceed on the drive-mode record (plan 0115 increment 6).
