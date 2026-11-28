# Vision's text reading can stay broken for the rest of its process after a slow first reading

Date: 2026-11-14. Context: `SearchReadingTests.textInAPictureIsRead` fails when many checks run
at once. The earlier note (`2026-11-13-e5rt-shared-compiled-model-cache.md`) saw `e5rt` errors
10 and 13 and concluded that a reading after a failed one is warm. This pass measured what a
process does after a slow first reading.

**Superseded in part:** its "Not changed" conclusions were overtaken by
`2026-11-15-text-reading-lost-to-a-cache-purge.md`, which found the cause (a purge of the
compiled-model cache, status 13) and moved text reading into a child process (ADR 0048).

## Method

A standalone binary outside Otos runs `SearchTextReading.read`'s request (accurate level,
automatic languages, language correction, the `main` stage pinned to the CPU or left on the
default device) on the 1,200 × 800 sign the test draws ("OTOS SEARCH 2026"). Each run reads N
times, optionally pausing between readings, and prints every error's domain, code and
underlying error. Each process got a new executable name, so it had its own, empty
`~/Library/Caches/<name>/com.apple.e5rt.e5bundlecache`. The machine was under the other
sessions' parallel checks: load average 30–68 on 8 cores. Nothing extra was added for load.

## Results

| Processes | Device | First reading | Later readings |
| --- | --- | --- | --- |
| a, b, r1 | CPU | read, 248–605 s | all read (29, 29, 11), 0.15–3.4 s each |
| c, rdef, def1, def3 | default | read, 206–649 s | all read |
| base, d, e, f, g, h, r2, r3, r4, r5, ctl1, ctl2 | CPU | read, 115–611 s | every one failed |
| def2, def4, def5 | default | read, 436–577 s | every one failed |
| d2, e2 (same names as d and e, run again) | CPU, default | read, 118–257 s | all read |

- **The failure:** every failed reading threw `TextRecognition.CRImageReaderError` code 1, with
  no underlying error, in 7–870 ms. In 15 processes, 141 readings failed this way, and none
  failed in any other way. No `e5rt` error was thrown this time.
- **It does not pass.** The first reading succeeds, and every later reading in the same
  process fails. r2–r5 read every 30 s for 5½ minutes and failed every time (11 of 11 in r2).
- **A new process recovers.** d2 and e2 ran the executables d and e again, and read every time.
- **The CPU pin does not cause it or avoid it.** It broke 12 of 15 CPU-pinned processes and 3
  of 7 on the default device. The pin is still needed for the reason ADR 0045 gives.
- **Its trigger inside Vision is not established.** Every broken process had a slow first
  reading, but so did processes that went on reading: a fine one took 649 s, a broken one
  115 s. The error carries nothing more.

## What this means

- **For the test:** `readAsTheIndexDoes` retries three times in the same process. Against this
  failure the retries fail within a second, so they recover nothing. `textInAPictureIsRead`
  reads twice: the sign, then a blank picture. In a process this breaks, the second reading
  throws although the first succeeded. Every Vision test in that xctest process is exposed
  the same way. This is a platform state that Otos neither owns nor can reset, short of a new
  process.
- **For the app:** in a broken process, every text reading fails until Otos relaunches. Each
  failure leaves its still owed and logs `op=search.text phase=failed`, and
  `PhotoSearchIndex` pages past it to the rest. A pass therefore decodes every owed preview
  and logs one error for each, then the index waits its backoff (30 s, doubling to 15
  minutes) before trying again. This is not a tight loop, but the cost of a pass grows with
  the number of stills owed.
- **Installed app, last 48 hours:** six `op=search.text phase=read` passes, including one of
  15,600 readings in 15,403 s, 2,071 of them with text, and no `phase=failed` line. The
  failure has not shown up in the installed app on the test Mac.

## Not changed

The reader and the index are unchanged. Without the cause, nothing here shows whether a
failed recognition says something about one photo or about the whole process. Stopping a
pass at the first recognition failure would end the futile pass. But if one photo always
fails, it would also hold back every photo after it, newest first.
