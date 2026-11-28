# Autoreleased chunks in the footprint: enrichment's launch memory (macOS 27, 2026-11-16)

## Question

Plan 0116's last unmet target is a peak footprint of at most 700 MB. On the reference library
(installed build d07bec4f), a switch-off tour with only enrichment running peaked at
832 MB, against a floor of 350–494 MB with every owner off. It read 1,073 MB from disk in
an 18-second session; the other owners read 14–235 MB alone. What does enrichment allocate
in its first seconds?

## Evidence from the reference session (unified log, read-only)

Enrichment started at +1.0 s (`Enrichment coordinator started`), 16 ms after the first
grid painted. In the first second it claimed 32 rows: 2 were local and 16 went to download.
Every local claim was hash-only. The log shows `enrichment.contentHash phase=applied` and
no `enrichment.item` or `render.still` lines, so nothing was parsed, rendered or read for
faces. The hashes, and the footprint at the next checkpoint after each:

| Time | Hashed | Footprint |
| --- | --- | --- |
| +1.0 s | (enrichment starts) | 173 MB |
| +1.1 s, +1.3 s | two 34 MB ARWs | — |
| +1.1 → +1.8 s | a 470 MB mp4 (718 ms) | 480 MB at +1.5 s, 659 MB at +1.9 s |
| +3.6 → +4.1 s | a 403 MB mp4 just downloaded | 822 MB, peak 832 MB |
| +10.5 s | — | 268 MB, when the system's memory pressure purged it |

The 1,073 MB disk read is these originals (34 + 34 + 470 + 403 MB) plus the catalog.

## Mechanism

`ContentHasher` read each file with `FileHandle.read(upToCount: 1 MiB)` in a synchronous
loop. On Darwin that call returns an autoreleased `NSData`. The loop runs inside one
Swift-concurrency job (a task-group child of the coordinator's pass), and a job's
autorelease pool drains only when the job ends or suspends. So every chunk of the file
stays alive until the hash finishes, and then it is freed into malloc. Freed blocks of that
size stay counted in `phys_footprint` on this OS
(`2026-11-16-freed-memory-stays-in-the-footprint.md`).

A standalone program, with no Otos code, hashes a 400 MB file in a task-group child the
same way (footprint before → after the task):

| Read loop | Footprint |
| --- | --- |
| `FileHandle.read(upToCount:)`, synchronous | 1 → 403 MB |
| the same, each chunk inside `autoreleasepool` | 1 → 4 MB |
| the same, `await Task.yield()` after each chunk | 1 → 4 MB |

The last row shows the shape of the defect: a job boundary drains the pool. A loop that
suspends between items holds one item's autoreleased objects, and a synchronous loop holds
all of them.

`ImageRenderer.StillSource` reads a still's original whole with `Data(contentsOf:)`, which
mallocs it whole. That buffer is freed into the same malloc pages after the render. In
the test process, reading 64 MB that way and letting it go left the footprint 64 MB higher
(below).

## Measured in the test process (generated reference-shaped catalog, 167,215 rows)

`EnrichmentLaunchMemoryTests` (`OTOS_SCALE_TEST=1`), one run with the old reads and one with
`FileBytes`:

| Measured | Old reads | `FileBytes` |
| --- | --- | --- |
| 200 enrichment passes over the backlog: footprint added | 0 MB (48 → 48) | 0 MB (57 → 57) |
| Demands held after 200 passes (bound: window 32 + hand-off 16) | 37 | 37 |
| Parked, paced and readiness-recheck rows | 0 | 0 |
| After shutdown gave back its claims | +0 MB over the floor | +0 MB over the floor |
| Hash-only enrichment of a 300 MB local file, in a task-group child | **+300 MB** | **+0 MB** |
| Read a 64 MB still whole and let it go | **+64 MB** | **+0 MB** |

The scheduler holds its window, not its backlog. It claimed twice in 200 passes, because
the window and hand-off stayed full of demands whose transfers never return. The whole
launch cost is in the reads of local bytes.

## Sweep: the same shape elsewhere

A synchronous loop that makes autoreleased Foundation, Image I/O or AVFoundation objects
per item, inside one job:

- **Fixed:** `ContentHasher` (enrichment, import and import recovery) and
  `ImageRenderer.StillSource`. Both now read through `FileBytes`
  (`Otos/Support/FileBytes.swift`), the one home for bulk file reads. It uses `read(2)` into
  one `ScratchBuffer`, and its whole-file read returns `Data` that owns a mapped region.
- **Checked, bounded:**
  - Render signatures, search embeddings, preview faces and descriptions decode thumbnails or
    previews in pages of 128, 16, 32 and 16. Each page is one job, and each image is a CF
    object released by ARC. A page's autoreleased objects are freed at the page's `await`.
  - The scanner flushes on its cadence; the reference session's log shows 127–220 files a batch, so one
    job holds a few hundred URLs.
  - The search vector file's compaction appends 4,096 slots a batch (about 6 MB) and awaits
    each write.
  - `VideoFaceReader.frames` awaits each frame.
  - `SearchTextChild` reads one short answer line at a time.
  - Import and export copy with `copyfile(3)`, which allocates nothing per byte.
  - `FileMaterialization` reads one byte.

## Conclusion

Bulk file bytes go through `FileBytes`, never through `FileHandle.read` or
`Data(contentsOf:)`. Enrichment's resident state is its claim window and hand-off, and a
hash or a whole read adds at most one buffer to the footprint.
