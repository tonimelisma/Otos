# Broad survey, static part: what disk, the catalog and the logs say before any session

Date: 2026-11-16, 23:55 to 00:40 local. Scope: one look at the whole picture before any
hypothesis is drilled into: disk growth, downloads, the backlog, past runs, and the machine.
Everything here was read without launching the installed app: `du`, `stat` and `lstat` of
Otos's folders and a sample of library originals (flags only, no bytes read), the installed
catalog opened `mode=ro`, the unified log, and the system's diagnostic reports. Nothing was
written or copied. The session part (CPU by function, memory over time, I/O while running) is
`script/survey.sh`, described at the end. It runs on a quiet machine after this merges.

Numbers and kinds only. No paths, file names, people or search text.

## 1. The machine Otos runs in

| Fact | Value |
| --- | --- |
| Hardware | MacBook Pro (M1 Pro, 8 cores), 16 GB RAM, macOS 27.0.1, up 6 days |
| Data volume | 460 GiB; 18 to 24 GiB free during this survey (95 to 96 % used) |
| Swap | 5 swap files of 1 GiB; 4.0 to 4.3 GB used |
| Free memory | about 60 to 110 MB free; 3.1 GB in the compressor; pressure level 1 (normal) |
| Since boot | 36.7 M pageouts, 24.7 M swapouts, 21.6 M swapins |
| Load | load average 21 to 27: eight `swift-frontend` at 50 % each (other agents' builds) |

Heaviest residents (top MEM, Otos not running): a Virtualization VM 2.4 GB, a Claude helper
1.1 GB, a WebKit content process 936 MB, WindowServer 638 MB, `claude` CLIs 621 and 193 MB,
the Claude app 527 MB, OneDrive 439 MB, Mail 388 MB, two `TGOnDeviceInferenceProviderService`
(the system language model) 271 and 139 MB, and each `swift-frontend` about 200 MB.

Otos therefore starts on a machine with no free memory and about 4 GB already in swap, and on
a disk with about 20 GB free.

## 2. Disk: what Otos owns

| Location (installed app) | Size | Files |
| --- | --- | --- |
| Application Support, Thumbnails | **52.9 GiB** | 322,377 |
| Application Support, Catalog: the catalog | 2.39 GiB (WAL 132 KB) | 3 |
| Application Support, Catalog: two pre-migration copies (Oct 24, Oct 26) | 77 MB + 62 MB | 4 |
| Application Support, Diagnostics: July JSONL from a sink ADR 0015 removed | 17 MB | 20 |
| Application Support, HandOff | 0.7 MB | 1 |
| Caches (URL cache 3.6 MB, Core ML e5rt 2 MB, remote and device staging empty) | 5.7 MB | 6 |
| Per-user cache folder (Metal shader caches) | 7.2 MB | 12 |
| Per-user temporary folder | none | 0 |

The dev bundle (`net.melisma.Otos.dev`) adds 1.67 GiB, of which 1.42 GiB are thumbnails
(21,176 files).

**The thumbnails folder is where the disk goes.** By kind:

| Kind | Files | Allocated | Median | Largest |
| --- | --- | --- | --- | --- |
| HEIC previews | 154,766 | 49.3 GiB | 282 KB | 3.1 MB |
| JPEG thumbnails | 167,608 | 3.6 GiB | 20 KB | 55 KB |
| Leftover `.tmp-*` and one file with no extension | 4 | 0 | | |

Against the catalog (every `thumbnail_path` and `preview_path`, one read-only walk of 7 to
17 s):

- References by root kind: Immich account 146,869 thumbnails and 128,673 previews; folder
  libraries 17,691 and 15,737; phone (MTP) 1,982 thumbnails and no previews; cards 66 and 26.
- **Orphans: 11,334 files, 3.58 GiB**, present on disk and named by no row: 10,330 previews,
  1,000 thumbnails and the 4 leftovers. None is missing: every reference has its file.
- The previews of the Immich account alone are 128,673 files, about 35 GiB at the median size.
  The account's originals stay on its server (3.45 TiB by the catalog's byte sizes), so the
  previews are a local copy of a remote library at about 1 % of its size.

Growth, by the day each thumbnail file was last written (a rewrite moves a file's day, so
this is a lower bound on what each day added, not a creation history):

| Day | Files | Written |
| --- | --- | --- |
| Oct 25 | 15,238 | 3.6 GiB |
| Oct 31 | 2,841 | 0.7 GiB |
| Nov 11 | 1,718 | 0.4 GiB |
| **Nov 12** | **104,261** | **16.8 GiB** |
| **Nov 13** | **183,137** | **28.1 GiB** |
| Nov 14 | 9,112 | 2.7 GiB |
| Every other day since Jul 19 | 0 to 858 a day | under 0.2 GiB a day |

About 45 GiB arrived on Nov 12 and 13, which matches the Immich account's 147,064 assets being
given thumbnails and previews. Outside such events the folder grows by tens of MB a day.

The system recorded the same writes: `/Library/Logs/DiagnosticReports` holds 22 **disk-writes
resource reports** for the installed app between Nov 10 and Nov 15, plus 1 for the dev build.
Eighteen of them record 2.1 GB of file-backed memory dirtied faster than the 24.86 KB/s
daily budget. The fastest took 25 s (87.6 MB/s, Nov 13). The other four record 8.6 GB each,
against a 99.42 KB/s budget, over 1,306 s to 15,765 s. Action taken: none.

Outside Otos's folders, test runs leave `OtosTests-*` folders in the per-user temporary
folder. 312 of them were older than an hour (0.49 GB, since Nov 15 12:34); two live runs held
4.4 GB each at the time. They are test leaks, not the app's, but they share the 20 GB of
headroom.

## 3. Downloads Otos holds: none found

Both folder libraries live in a cloud-provider folder. An `lstat` (flags only, which never
materializes a file) of every asset of the small library (559 found by the sample) and of
1,926 random assets of the large one (16,910 assets, 887 GB by the catalog) found **every
sampled original cloud-only (`SF_DATALESS`)** and none local. The remote and device staging
folders are empty. Whatever enrichment downloaded has been evicted by the provider. The disk
Otos holds is its own derived data (section 2), not originals.

## 4. The backlog

Counts on the installed catalog (166,986 assets: Immich account 147,064, folder libraries
17,698, phones 2,151, cards 73). The partial-index counts each took under 0.2 s. The joined
counts come from one timed walk of `media_asset` with its three derived tables (35.9 s, the
app not running). That walk read more than the 545 MB table, but this survey allowed one.

| Product | Owed now | How counted |
| --- | --- | --- |
| Text readings | **85,834** (85,795 Immich, 26 cards, 13 libraries) | walk, exact predicate |
| Descriptions | 53,077 describable (plan 0116 due diligence, same day); 138,889 stills with a preview have never been described; 5,547 description rows exist | upper bound by walk; the exact predicate needs current text and embeddings first |
| Search embeddings | 960 (894 phones, 66 cards) | walk; counts Live Photo movies too, which the app skips |
| Metadata refresh | 27,592 | partial index |
| Content hashes | 162,287 assets without one (all 147,064 Immich, 12,999 library, all phone and card) | walk; a cloud-only file is hashed only after a download |
| Render signatures | 1,781 (phones and cards) | walk |
| Stills awaiting a preview | 1,954 | partial index |
| Video faces | 896 | partial index |
| Still faces | 26 | partial index |
| Unrendered edits | 0 | partial index |
| Undecodable | 52 | partial index |

Rates. The retained log cannot give them (section 5). Measured instead on this Mac by
`script/survey.sh` on a generated library of 156 photos in a sandbox home, under the same
build load, all read from stored previews and thumbnails as on the owner's catalog:

| Product | Rate | Time to drain the owner's backlog, app running |
| --- | --- | --- |
| Text readings | 156 in 276 s (1.8 s each) | 85,834 × 1.8 s ≈ **43 h** |
| Descriptions | about 4.5 s each (36 measured; 3.5 to 9.4 s) | 53,077 ≈ **66 h**; all 138,889 ≈ 174 h |
| Search embeddings | 156 in 12.4 s (80 ms each) | 960 ≈ 1.3 min |

Descriptions wait on text readings (`describableStill` requires a current reading), so at
these rates the text backlog gates descriptions for about two days of running time.
Metadata refresh and content hashes for cloud-only files need downloads. Their rate is a
download rate, which the session survey measures.

## 5. Past runs, from the logs and reports

- Unified log retention is short. For the Otos subsystem, `.info` lines go back only to
  Nov 14 00:06 and `op=sessionStart` notices only to Nov 15 19:53. In the window, 155,031
  lines came from dev builds and test hosts against 2,222 from the installed app: the
  volume of development logging rotates the installed app's history out within about a day.
- In that window the installed app logged 22 processes (some are its text reader) and
  about 1.0 h of activity between first and last line. Diagnostic reports show longer runs:
  disk-write windows of 6.1 h (Nov 15) and 4.4 h (Nov 14).
- **Main-thread stalls: 178 `op=mainThreadStall`** in about 1.0 logged hour: longest
  2,614 ms, 80 s in all. **Store waits: 145 `op=catalog.store.stall` lines**. The 31 that carry
  `waitMs` add up to 81 s, the longest 8,637 ms.
- Rates of draining products in the window: face reads 27 a minute, still renders 21 a
  minute, enrichment items 22 a minute (each in one active minute), content hashes 8 a minute.
  Descriptions logged only `requestFailed` (6 times). Text and embedding drains were absent.
- **CPU resource reports: 11** for the installed app (Nov 12 to 14), each 90 s of CPU in 137
  to 180 s (50 to 66 %). Disk-writes reports: 22, in section 2.
- Crashes: no Otos crash or hang report in the user's or the system's diagnostic folders. Two
  Jetsam events on Nov 15 do not name Otos.
- Memory-pressure lines: the app has no line named for memory or pressure. The other agent is
  adding `op=process.memory`.

## 6. What this says, before any session

1. "It eats up all disk space" is the thumbnails folder: 52.9 GiB, 93 % of it HEIC previews,
   and about 35 GiB of those previews belong to a remote account whose originals are not on
   this Mac. 3.58 GiB are orphans no row names. This is a measured fact. Whether the previews
   should exist at that size is a product question for the owner. The orphans are a defect.
2. Otos holds no downloaded originals. The provider has evicted them.
3. The machine has 16 GB RAM with about 100 MB free and 4 GB of swap before Otos starts. The
   system language model alone grows from 410 MB to about 1.2 GB once descriptions start
   (measured in the sandbox session, section 7). Otos's own peak, reported this week at
   1 to 1.8 GB resident, lands on that.
4. The backlog is days of running time: about 43 h of text readings, then about 66 h of
   descriptions, at today's per-item cost on this Mac.
5. The log keeps too little of the installed app to read history from. A survey has to
   capture its own session.

## 7. `script/survey.sh`: the session part

One session (default: the installed app launched with `--env` values such as the tour's
flag; `--dev --home <sandbox>` for this checkout's dev build in a sandbox home; `--launch
'<command>'`; `--attach <pid>`). It runs without root and captures:

- CPU: a Time Profiler trace attached to the pid (never `--launch`). It is exported through
  `script/profile-export.sh` and summarized as self time and owners (the first Otos frame on
  each stack), split by main thread and others, by thread and by phase.
- Memory: `phys_footprint` and lifetime peak (`proc_pid_rusage`), `vmmap --summary` by region
  (dirty + swapped) and malloc zone, `footprint`, `vm_stat`, swap and pressure sysctls. These
  are taken at launch +15, +30, +60 and +180 s (`time: measurement`), at each `op=tour
  phase=step` line, at the first `op=description` line (to catch the language model's
  growth), and at the end. Each phase gets pageout, swapout and swap-growth deltas. `heap -s`
  and a 5 s `sample` run at each new footprint high that is 25 % above the last one taken and
  above `--peak-floor-mb` (default 200 MB).
- Disk I/O, CPU and energy for Otos and its text readers, and for every process this user may
  read (`script/lib/proc-rusage.py`, billed energy included), per phase. `iostat` runs over
  the session.
- Neighbours: top's MEM/CPU/POWER for the language model, model manager, media and photo
  analysis, file provider, OneDrive, Spotlight, builds and agents.
- Threads: a `sample` at the peak and after each of the first three stalls the app logs.
- Files: `du` and file counts of every folder Otos owns, before and after.
- Network: `nettop` byte counters for every process.

The output is `build/surveys/<time>-<revision>/`, with `raw/` and one `summary.md` plus
`summary.json`, written by `script/lib/survey-summary.py`. The summary carries only names,
counts and sizes. Log lines are reduced to their `op=` name and numeric fields, and any string
that still looks like a path is replaced.

Not captured without root, and said so in every summary: package power by subsystem
(`powermetrics`), per-file I/O (`fs_usage`), the rusage counters and `footprint` of other
users' processes (root daemons, `_modelmanagerd`'s language model, `_mds_stores`), for which
only top's columns are read. `memory_pressure(1)` is not used, because it applies pressure
rather than reporting it.

Verified end to end three times on the dev build in a sandbox home with a generated library
of 156 JPEGs made from the system wallpapers. Each run built, launched, recorded, quit the
app, and confirmed `app=gone reader=gone` and `recorders stopped`. In the second run the quit,
addressed by bundle identifier, was a no-op, because several worktrees' dev builds share that
identifier. The harness then terminated the pid it had launched. The quit is now addressed by
the bundle's path, and the third run quit cleanly. The sandbox session itself measured,
for 156 photos: footprint peak 946 MB in the first 15 s, 49 s of CPU (thumbnails, the search
model and Core ML on the CPU), 659 MB written at launch, and the language model's two
processes growing from 410 MB to 1,173 MB after the first description. During that phase
the system paged out 210,162 pages and swap grew 188 MB.
