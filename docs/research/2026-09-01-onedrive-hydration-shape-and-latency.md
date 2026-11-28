# Research: OneDrive hydration shape and first-byte latency (2026-09-01)

The healthy-provider baseline `2026-08-03-post-increment-review-experiments.md` §4c said
"should be decided against a healthy-provider baseline, **which does not exist yet**", plus
the hydration-shape measurement the persistent-materialization work needed. Both were taken against the
production library on the machine that produced the 2026-08-31 loupe failures.

## Method

Direct probes outside Otos, because the app itself had nothing to measure: the scan found
10,585 assets across 9 roots and started **zero** enrichment. Those rows were enriched
before OneDrive evacuated their bytes, and overlay is kept for the life of the item
(ADR 0008), so there was no background materialization to observe.

Probe sources: `probe-request-vs-read.swift` (one request then poll, versus a plain blocking
read) and `probe-hydration-shape.swift` (request, then sample `st_blocks` and `SF_DATALESS`
every 250 ms until the flag clears).

**Precondition, per the `2026-08-03` methodology rule:** provider readiness was verified by an
actual read, not inferred from a process listing. Every file below was served.

## Finding 1 — hydration is atomic

`st_blocks` stays at 0 for the entire download and jumps to full on completion. Exactly two
transitions per file, across every file measured:

```
20260830_150158.arw      36.5 MB   materialized after 6801 ms
  t=  153 ms  blocks=    0 (  0.0 MB)  dataless=yes
  t= 6801 ms  blocks=71224 ( 36.5 MB)  dataless=no

20260830_180337.arw      34.4 MB   materialized after 1804 ms
20260830_180340_002.arw  34.4 MB   materialized after 1540 ms
```

**Consequences.**

1. `st_blocks` carries no progress information. The `op=materialization.progress` instrumentation
   added alongside the persistence change logs exactly one transition per file. It still timestamps arrival
   and proves atomicity, but it cannot drive a progress bar.
2. **Otos cannot distinguish "downloading slowly" from "stalled" with the filesystem API alone.**
   This is not a gap in the implementation; the information is not exposed. It is precisely the
   fact whose absence let PR 172 read a 3 s `ETIMEDOUT` as a definitive refusal.
3. Therefore a determinate progress indicator for a cloud original requires
   `NSFileProviderManager`'s `NSProgress`. That is now the *only* route to progress, not a
   convenience — which changes how the NSFileProviderManager option should be weighed if progress is
   ever wanted.
4. And it is the empirical justification for never giving up: with no signal on which to base a
   give-up decision, persisting is the only defensible behaviour.

## Finding 2 — first-byte latency straddles the 3 s probe timeout

Blocking reads of the first 4 KB, on just-imported originals OneDrive had evacuated:

| file | size | first byte |
| --- | --- | --- |
| .arw | 42.7 MB | **4.14 s** |
| .arw | 42.3 MB | 2.41 s |
| .arw | 41.8 MB | 2.25 s |
| .arw | 42.6 MB | 2.58 s |
| .arw | 42.6 MB | 2.16 s |
| .jpg | 0.3 MB | **4.57 s** |
| .jpg | 1.5 MB | 0.78 s |
| .jpg | 0.2 MB | 0.52 s |

Median ~2.4 s against a **3 s** probe timeout. Two of eight exceed it outright. The threshold
sits inside the provider's normal latency distribution, so the two-strike short-circuit can
abort a transfer that is working. Full-hydration times of 6801 ms (above) and the 8.9 s measured
in `2026-07-11` are both past the ~5 s the short-circuit allows.

This is the baseline PR 172 should have been decided against. Its own captures were taken
against a provider `2026-08-03` §4a later proved was **down**.

## Finding 3 — a single request sufficed in every idle-machine trial

One `startDownloadingUbiquitousItem`, then poll, no re-requests: 5 of 5 materialized in
1.78–6.23 s.

**This does not generalise and must not be cited as evidence about the loaded case.** n=5,
sequential, idle machine, provider already warmed by earlier reads, no import and no enrichment
running. The failures being investigated occurred during 38 GB of upload with eight concurrent
enrichment transfers. Recorded only so nobody mistakes it for a baseline under load.

The working position — that a saturated provider can discard queued requests, since
`startDownloadingUbiquitousItem` returns no acknowledgement — remains the operating assumption,
and is the safe one: hammering when unnecessary costs one XPC round trip, while failing to
hammer when necessary costs the image the user is looking at.

## Finding 4 — re-asserting does not restart an in-progress transfer

The one result that could have inverted the interactive re-assert cadence. Two arms, interleaved over the
same file population so provider state drifts across both equally: arm A re-asserts
`startDownloadingUbiquitousItem` every 500 ms, arm B asks once and waits.

```
  A-hammer  materialized   5481 ms  asserts=12   36.8 MB
  B-once    materialized   1535 ms  asserts=1    35.8 MB
  A-hammer  materialized   2331 ms  asserts=6    36.4 MB
  B-once    materialized   1822 ms  asserts=1    37.6 MB
  A-hammer  materialized   1822 ms  asserts=5    37.3 MB
  B-once    materialized   1785 ms  asserts=1    37.3 MB
  A-hammer  materialized   1801 ms  asserts=5    37.5 MB
  B-once    materialized   2313 ms  asserts=1    37.5 MB
  A-hammer  materialized   1811 ms  asserts=5    37.2 MB
  B-once    materialized   1803 ms  asserts=1    36.9 MB

  A hammered  n=5  median=1822 ms
  B once      n=5  median=1803 ms
```

Medians differ by 19 ms — noise at this sample size. Twelve re-assertions on a 36.8 MB file did
not prevent or delay its completion, and no arm-A file failed. **Hammering is safe**: it neither
restarts nor measurably slows a transfer, which is what was needed before defaulting
interactive work to a 500 ms cadence.

This is a *safety* result, and safety is the direction that generalises least badly from an idle
machine: a restart-on-re-assert would have shown up here as arm A losing outright, and it did not.
It remains unmeasured under load, where contention could change the picture — but the failure mode
it was guarding against is not present.

**Still unmeasured:** whether a saturated provider discards queued requests. If it does, hammering is what recovers them. The historical captures (114 re-requests over
120,276 ms) remain consistent with both "persistence failing" and "the provider was simply down",
and `2026-08-03` §4a proved the provider *was* down for those. Given finding 4, hammering costs
nothing; given no acknowledgement from the API, it is the only insurance available. The two-arm
experiment under real load in under real load has not been run.

## Context: why the library is in this state

Of the 999 originals imported at 22:24 on 2026-08-31, **300 were `SF_DATALESS` within hours —
11.5 GB evacuated**, verified by the kernel flag rather than `du`. The destination was
`OneDrive/Pictures/Camera Roll`, and the disk had ~17 GB free, so Files On-Demand
reclaimed the space after upload. A sample of 3,000 OneDrive catalog rows found **2,803 dataless
(93%)**, which makes materialization the normal path for that library rather than an edge case.

The same behaviour was recorded once before, in
`2026-07-14-import-planning-state-and-concurrency.md`: "OneDrive had already evicted
(`compressed,dataless` in `ls -lO`) many just-imported `.arw`/`.hif` files."

## Single-environment caveat

Every measurement here comes from one OneDrive Personal account on one Mac at ~19 GB free.
No other provider (iCloud Drive, Dropbox) and no healthy-disk machine has been measured.

## Closed unrun

The two-arm experiment under real load was **closed unrun by decision on
2026-09-01** — reproducing the conditions means writing tens of gigabytes into a
cloud-synced folder on a nearly-full disk, which the measurement does not justify.
The cadence therefore rests on finding 4 (hammering is safe) and on asymmetric cost
(a wasted syscall versus an image that never appears), not on a measured optimum.
