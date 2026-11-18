# What took the machine to warning after launch on a934ef17 (2026-11-17)

Sources: the installed app's unified log for two read-only launch-kind tours of a934ef17 on the
owner's library (pid 78993, 84 s; pid 78640, 624 s), the system log of the same seconds
(`/usr/bin/log show`, every process: `modelmanagerd`, `TGOnDeviceInferenceProviderService`,
`launchd`), the scorecard JSONs of both tours, and the app's log of the 12031093 launch tour
an hour earlier (pid 24748). Nothing was launched on the owner's data for this note. The
system log keeps info-level lines of other processes only for minutes: the model service's
lines below exist for the short tour only, captured while they were still kept.

## The first dip: the system language model loading its 3B model

Seconds from the short tour's launch (21:09:22.5 local), with what the app's own samples
(`op=process.memory`, `op=process.usage`) and the system log show:

| s | Otos | The system |
| --- | --- | --- |
| 1.3 | People pass granted (`op=load.admission`) | |
| 3.0 | | `TGOnDeviceInferenceProviderService` (the 300m model) loads its base, safety and image tokenizer |
| 4.2 | text-reading helper started (peak footprint 80 MB) | |
| 4.6 | footprint 313 MB, resident 518 MB; machine compressor 3,675 MB, free 363 MB | `modelmanagerd`: two `createSessionRequest` "from proceess 78993" |
| 4.6–6.7 | | `TGOnDeviceInferenceProviderService` pid 47945 loads `com.apple.fm.language.instruct_3b.base`, `.image_encoder`, `.fm_api_generic.draft` (`loadIn … finished` at 6.7) |
| 6.7–7.9 | | the same process loads the `instruct_3b.fm_api_generic` adapter; the request executes at 7.9 |
| 8.2 | footprint 376 MB, resident 762 MB; machine compressor **5,205 MB**, free **68 MB** | |
| 9.2 | kernel level 2 (warning), 28 % available; the room holds every kind and lets the helper go | output guardrail session for 78993 at 9.5 |
| 10.9 | People pass ends (`assignMs=5783`, 103,210 vectors) | |
| 19.2 | the look finds level 1, 42 % available; the room reopens | |

Proven: the load Otos started in those 3.6 s that raised the machine's memory is a
FoundationModels request from Otos's own process: `modelmanagerd` names pid 78993 as the
session's client and resolves its assets to the `foundation_models_framework` guardrails of
`/Applications/Otos.app/Contents/MacOS/Otos`, and the system then loaded the 3B model and its
image encoder into `TGOnDeviceInferenceProviderService`. In exactly those seconds the
machine-wide compressor grew 1,530 MB and free memory fell to 68 MB, while Otos's footprint
grew 63 MB and the helper's never passed 80 MB (the scorecard's process tree: helpers' peak
169 MB over the session). The warning came 1.3 s after the model's last asset loaded. The
requester inside Otos is the description writer: it was the only owner whose request carries a
picture (the image encoder loaded), and its first page of candidates had been read by 2.8 s. The short tour wrote
no description line before it quit (the request's answer is not in the log); the long tour's
first description, asked 2.6 s after its launch, took 10,734 ms.

Not proven: how much of the 1,530 MB is the model's own memory and how much the People pass's
scratch outside Otos's footprint, the file cache, or other processes; the model service's own
footprint was not sampled in that session.

## The later dips: each reopen started a cold model load again

The long tour (pid 78640), each reopen and what followed:

| Reopen (s) | Available | Granted in that step | Description started | Warning | Its description took |
| --- | --- | --- | --- | --- | --- |
| launch, 0.2 | 59 % | People | 2.7 | 8.2 | 10,734 ms |
| 18.4 | 42 % | duplicates, then People | 18.4 | 22.9 | 8,093 ms |
| 32.9 | 57 % | duplicates, People | 32.9 | 36.7 | 6,639 ms |
| 46.7 | 57 % | People | 46.7 | 50.5 | 5,968 ms |
| 60.5 | 58 % | People | 60.5 | none | 5,962 ms |

(The start of each description is its `op=description phase=written` line less its `ms`.) Each
reopen let a description request, a People pass and a text-reading helper start in the same
step. Each of the four dips came 3.7–5.6 s after a description began; each of those requests
took 6.0–10.7 s, while every description after the fifth reopen took 3.1–4.4 s and the machine
stayed normal for nine minutes with People passes and text reading running beside them. So a
cold request costs the machine what a warm one does not, and the reopens kept making requests
cold. Suspected, not proven: that the model service drops its model at warning, which would
make every request after a hold cold.

## Why 12031093 did not dip

Its launch tour (pid 24748) began at 69–70 % available and ran the same stack — People granted
at 1.9 s, a text-reading helper at 4.7 s, a cold description of 8,482 ms from 3.0 s — and
stayed at level 1. The a934ef17 tours began at 59 % and 63 %. The same loads at once fit in
the larger headroom and not in the smaller one.

## The sandbox reproduces it without People

A launch tour of the dev build with the installed app's settings (`script/scorecard.sh --tour
--dev --optimized --seed 160000 --seed-media small`: 160,000 generated 64 x 64 photos, no
faces, so every People pass took 1–50 ms), on the tree of main 7432fd6f, from 65 % available:

| s | What happened |
| --- | --- |
| 0.6 | first grid; the launch's loads (People, duplicates, the derived folder, the search index, readying search) all ran by 1.3 s |
| 4.9 | text-reading helper started |
| 40.6 | a description request began (its `written` line at 48.4 says 7,826 ms) |
| 45.7 | warning, 23 % available |
| 55.9 | normal, 56 % |
| 224–226 | `modelmanagerd` creates sessions for the app's pid and loads `instruct_300m`, then `instruct_3b.base`, `.image_encoder` and the adapter |
| 228.7 | warning, 29 % |
| 239.1 / 243.1 | normal at 57 %, warning again 4.0 s later at 25 % |
| 253.6 / 256.6 | normal at 56 %, warning again 3.0 s later at 29 % |

Scorecard: `memory pressure caused` FAIL, 41.4 s at warning of 273.6 s, four dips; peak
footprint 483 MB, the largest text-reading helper 53 MB. Every model session in that window
was the app's (45 `createSessionRequest … from proceess` lines, all its pid). So a cold
description request alone, with no heavy load beside it, takes this machine from 56–65 %
available to warning, and each reopen that re-grants it does so again: a turn that keeps it
from stacking is not enough, the request must not be started again into the room it ran out
of.

## The same sandbox tour with the fix

The same command on the fix's tree, from 64 % available: the first description request was
granted its turn at 125.2 s (`waitMs=9`), and the kernel went to warning at 133.7 s, 29 %
available; the admission logged `phase=pressureRaised load=description availableAtGrant=63
available=29`. The room reopened at 138.8 s (42 %), and the description stayed waiting for
more than 63 % to the end of the session. Its last status named `memoryWarning`, the hold
as it was when the request began to wait; the status now reads the hold when it is taken
(`memoryHeadroom` in that case). Scorecard: one dip,
5.1 s at warning of 151.0 s (before: four dips, 41.4 s of 273.6 s); `memory pressure caused`
still FAIL, for the first cold request; peak footprint 406 MB. The session was shorter than
the one before, so the before run's later dips (at 228–267 s) fall outside it; what the log
shows is that no description was granted again after the dip.

So the first cold request still takes a machine at 63–65 % available to warning: no fact a
process can read says in advance what the model will take. What the fix removes is the
repetition.

## What follows for the design (ADR 0055, ADR 0057)

- A description request is a bounded load of the kind ADR 0055 admits: cold, it makes the
  system hold more than a gigabyte for seconds. It takes a turn in `LoadAdmission`, so it
  never stacks with a People pass, a duplicates build or the search index's build, at launch
  or at a reopen.
- After a hold, the held loads resume one at a time (one turn), and the load the room let in
  last before the level rose waits until the kernel reports more available memory than it
  started with, behind the others, so a load that raised the pressure is not started again
  into the same room.
- Reopening waits on the kernel's level. Neither tour's source ever reported (`source=none` on
  every change), so the room's 5 s look stays where nothing will report; when the source
  has reported the rise, the kernel owes it the return to normal and the room waits for that
  report instead of looking.
