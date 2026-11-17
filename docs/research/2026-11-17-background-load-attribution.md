# What Otos's background work makes the machine carry (2026-11-17)

Sources: the installed app's unified log for today's sessions on the owner's library (read
only, `log show` for the installed image; three launch-kind tours of 609–610 s: pids 64416,
4485, 10258), a machine sampler beside a sandbox tour (every 5 s: the kernel's pressure level
and available share, the load average, `top` for Otos's processes, the system language model's
service and the indexing daemons, and other agents' compiler processes), and the survey of
installed ef4492e6 (`build/surveys/eighth-ef4492e6`, local). Nothing was launched on the
owner's data.

## The owner's library: what each owner asked for per unit time

Pid 10258 (installed f398d5dc), 609 s:

| Owner | Asked | Per minute | How many at once | Bounded by |
| --- | --- | --- | --- | --- |
| Background downloads of cloud originals, then hashing | 475 dispatched, 470 completed, 13,028 MB hashed | about 47 files, 1.3 GB | up to 4, up to 1,344 MB in flight | per-root cap 4 (233 refusals), large-video cap 2 (478 refusals), 2 GB byte budget, the free-space floor |
| Descriptions | 143 written | about 14, one every 4.3 s, continuously | one | one at a time |
| Text reading | 5 helper sessions, 331 pictures read | sporadic | one helper | one helper; 4 of 5 sessions ended by Vision's `e5rtError` 13 |
| App process | 48.1 s CPU, 14.9 GB read, peak footprint 367 MB | | | |

Text reading's cold starts: the first reading of each helper waited 116,409, 2,712, 33,603,
70,345 and 3,211 ms (the text model compiled each time it was not warm).

The app's own pressure reports (`event=memoryPressure`, the dispatch source) in the three
tours: 10258 warning at 119 s, normal at 271 s, warning at 534 s; 4485 warning at 11 s, normal
at 80 s; 64416 warning at 118 s, normal at 165 s. The kernel's level sampled from outside in
the same kind of tour read 2 from 30 s on, so the source's reports are fewer than the kernel's
level changes; the room reads the kernel's level at launch and the source's changes after.

The log does not attribute pressure to an owner: in every tour downloads, descriptions and
text reading ran at once from the first seconds. In 4485 the first 30 s hashed 2.8 GB and the
warning came at 11 s; in 10258 the first 60 s hashed 2.1 GB and the warning came at 119 s, two
seconds before a text helper's 116 s cold start failed. Correlation only; no owner is named as
the cause.

## The survey's "three readers"

The survey summary's per-phase `readers` column counted every reader seen so far
(`rusage_by_snapshot` kept the last row of each), and `readers_footprint_mb` summed them. Rerun
on the same raw capture with the alive count: one reader at every moment (63, 63, 35, 66, 126
MB). Only one helper ever ran at a time; the reader keeps it alive between pages.

## A sandbox library: the work the window drives, without downloads

`script/scorecard.sh --tour --dev --optimized --seed 2000 --idle 300` (2,000 camera-size
photos on a volume of its own, a launch-kind tour then 300 s idle; build f398d5dc+; nothing
else built during it). Its originals are local, so no download runs; it measures renders,
faces, embeddings, text reading and descriptions.

| | Before launch | Otos running |
| --- | --- | --- |
| kernel pressure level | 1 | 1 throughout |
| memory available | 46–49 % | 36–44 % |
| Otos and its helper (top) | — | CPU 129 % median, 247 % max; up to 664 MB; 2 processes at most |
| system language model service | 411 MB | 411–925 MB; CPU 9.5 % median, 59 % max |
| indexing daemons | 0–2 % CPU | 0–4 % CPU |

The app read 624 MB and used 455 s of CPU in the session: 2,002 rows enriched (590–661 a
minute until the backlog was done), 62 descriptions (about 15 a minute), one text helper (135
pictures). The machine stayed at normal pressure, so on this machine the in-process work
(renders, faces, embeddings) and a describing model service do not by themselves move the
level from normal. What the sandbox cannot reproduce is the owner's download path: 13 GB in
ten minutes through the provider's process into the file cache.

## The same tour with the background room (ADR 0057)

The same seeded tour on the branch that adds `BackgroundRoom`, other agents' builds running
before and during it (load average 32 at the start, 13.6 median; up to 8 compiler processes):

| | Before the room | With the room |
| --- | --- | --- |
| kernel pressure level (sampler) | 1 throughout | 1, except 2 for about 34 s during other agents' builds |
| the app's pressure line (`op=system.pressure`) | not logged (older build) | launch `normal` (72 % available), no change reported |
| the room's conditions | — | roomy for the whole session: no change was delivered, and the app was never the active app (a tour launched from a shell is not brought to the front) |
| scorecard `machine.pressureCaused` | — | PASS (0 s above normal) |
| Otos and its helper | CPU 129 % median, up to 664 MB, 2 processes | CPU 122 % median, up to 591 MB, 2 processes |
| model service | 411–925 MB | 411–926 MB |
| rows enriched a minute | 590–661 (2,002 in about 3.3 min) | 326–630 (2,002 in about 4 min, under the builds' load) |
| descriptions | 62 (about 15 a minute) | 53 (8–16 a minute) |
| text helpers | one | one |
| window targets | every one passed, 0 failures | every one passed, 0 failures |

The room held nothing in this tour, so the throughput is unchanged but for the other
builds' load; its holds are proven by the deterministic tests (ENR-033). The kernel's level
reached 2 for 34 s with no report from the pressure source; the source's reports are the
platform's fact the room listens to, and a level the source does not report holds nothing.
That session's helper logged no usage line, since its usage was logged only as its session
ended and a helper alive at the app's quit ends with the app; the helper now logs after each
page as well.

## Conclusions

- The system language model's service holds about 514 MB more while descriptions run: the
  largest memory Otos causes in another process.
- One text helper at a time, as designed; its cold start is long.
- Downloads are the one load the sandbox cannot show and the largest by bytes.
- These justify a hold on new heavy units by the platform's own facts (ADR 0057), not a
  throttle by time.
