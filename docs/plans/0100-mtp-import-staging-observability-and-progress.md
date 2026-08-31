# 0100 — Camera import: prove naming from ranges, stage only what is imported

Everything found during the 2026-08-30 live MTP session (Sony ILCE-6700, 991 items,
36.5 GB) plus the research it triggered. Evidence is from that session's logs, the
catalog, the staging tree, a process sample, an ImageCaptureCore probe against the
camera, a 991-file corpus scan, and the format specifications. Where a cause is
unproven this says so.

Research backing: `docs/research/removable-volume-and-camera-sources.md`, 2026-08-30
section (which also supersedes part of its own 2026-07-06 POC).

## Target state

Planning a camera import reads **byte ranges, not files**. The capture wall comes from
the container's own index — a few KB per item — and the grid thumbnail comes out of the
same read, so the Import button appears in **about a minute and a half** for a 991-item
card instead of after a full-card transfer. Staging then holds only the items actually
being imported, and releases each one the moment its copy settles. Quit clears the cache
and says so while it does.
Instrumentation logs state changes rather than every pass, so the log remains readable
under load. The bar reports the work that is actually happening.

**The headline number, stated honestly.** This plan's own measured per-file figures are
77 ms (ARW), 91 ms (HIF) and 234 ms (MP4) per chunked fetch. ImageCaptureCore serialises
on one `ICDeviceCommandQueue`, so those costs are sequential, and ARC-057 withholds a
date-dependent plan until **every** row's naming fact is proven. For this card that is
464 x 77 + 464 x 91 + 63 x 234 ms = **~93 seconds**, not "seconds". That is a 27x
improvement on the 45 minutes measured, and it is the number to design against. Two
consequences follow and are carried below: C3's "momentary Preparing" premise stays
false, so C1 and C2 remain load-bearing; and the ~97 MB estimate is optimistic — at
128 KB chunks the same card reads 113-143 MB depending on per-format chunk size. Log the
figure the run actually reads (R5) rather than asserting a constant.

## Session facts (the ground truth this register is measured against)

- 991 items, 36.5 GB, all staged and enriched; plan reached Ready at ~20:15.
- First download 19:25:21, last staged file written 20:09:32 — ~45 minutes.
- Peak log volume 2,336 lines/second; 239,655 lines captured; ~836 download events lost.
- After Import the staged 36.5 GB is still on disk; only app close removes it.
- Corpus scan: the capture wall was recovered from ranged reads for **991 of 991** items,
  each matching the wall full-file enrichment had written, in ~2 s of CPU. A naive prefix
  scan needed 208 MB (ARW 64 KB, HIF 256 KB, MP4 1 MB tail); the `MediaMetadata` package's
  own directed reads need only **1–12 KB per file**, about 3 MB for the whole card.

---

## D · Planning without staging (the root cause)

### D1 — A camera import stages the whole card before Import can be offered (severity: high)

ARC-057 withholds a date-dependent plan until every source row's naming fact is proven,
and states that ICC's dates are absolute instants that cannot yield a local wall clock.
That is true — the probe confirmed `exifCreationDate` is nil on this body, `duration` is
0.0 for a 335 MB video, and `requestMetadataDictionary` fails with -20150 — so the
implementation stages every file to read its bytes locally. Measured cost: 36.5 GB and
~45 minutes before the button appears, then 36.5 GB copied, ~73 GB written for one
import.

**What is proven, and the one step that is not.** Two halves are measured and the
composition is not, so state it here rather than in an assumptions list at the end:

| | Status |
| --- | --- |
| Fetching an arbitrary byte range from this camera over MTP | **Proven, live.** 512 B reads at arbitrary offsets, median 42.6 ms; chunked fetches timed at 77 ms (64 KB ARW), 91 ms (128 KB HIF), 234 ms (MP4 head+tail) |
| Recovering the exact capture wall from those ranges | **Proven, 991/991**, each matching what full-file enrichment had already written |
| The two joined: fetch-from-camera → parse → date, over a whole card | **Not run.** The 991/991 corpus was parsed from the *staged local copies*, not over the wire |

The gap is small — a parser cannot tell where its bytes came from, which is exactly what
package requirement R8 tests — but it is the difference between "each part works" and
"this works". **Increment D1 therefore opens with an end-to-end spike before any
production code changes**: attach the camera, read ranges over MTP for a few hundred
items, parse each, and compare against the walls already in the catalog. That run also
produces the first honest per-card timing, replacing the ~93 s extrapolation with a
measurement. If it disagrees anywhere, D1's design is wrong and better found in an
afternoon than after the refactor.

**The fix: a range-driven metadata reader.** The formats are self-describing. One 12-byte
read identifies the family, and the family's own index states where the metadata is:

- **ISO-BMFF** (MP4, MOV, HEIC/HEIF, AVIF, CR3) — ISO/IEC 14496-12 §4.2: every box header
  carries its total size ("this facilitates general parsing of the file"), `size==1`
  meaning 64-bit `largesize`, `size==0` meaning to end of file; §4.3.1 puts `ftyp` first.
  The spec places **no constraint** on `moov` versus `mdat` order, so the reader walks
  the top-level box chain (8–16 bytes per box) and finds `moov`/`meta` wherever it is.
  §4.2's "boxes with an unrecognized type shall be ignored and skipped" is what makes the
  walk safe against vendor boxes and future formats.
- **TIFF** (ARW, NEF, CR2, DNG, RW2, ORF) — the first 8 bytes give byte order and the
  absolute offset of IFD0; IFDs may be anywhere at even offsets ≥ 8; entry values over
  4 bytes are absolute offsets from the file start. Read the header, follow `ExifIFD`
  (0x8769), read `DateTimeOriginal` (0x9003) and `OffsetTimeOriginal` (0x9011).
- **JPEG/Exif** — CIPA DC-008 requires `APP1` immediately after `SOI`, so a small fixed
  prefix is correct *by the standard* rather than by observation.
- **Anything else** (Fuji RAF, future containers) — no public index rule, so the terminal
  fallback applies: transfer the file and enrich normally.

There is a **second fallback axis**, and the earlier draft missed it: the fallback above
covers an unrecognised *container*, not an uncooperative *transport*.
`requestReadDataAtOffset` sits on MTP's `GetPartialObject` (opcode 0x101B), which is
**optional** — it is absent from the mandatory PTP command set, so a body or phone may
not implement it at all. Devices that do implement it can still be wrong: libmtp#8
documents Samsung Galaxy devices failing `GetPartialObject` **by timeout** whenever the
offset lands on `size - (N x 512) + 500`, roughly one file in 512. And FB7663947
documents `requestReadData` on iPadOS returning **empty `Data` with a nil error** — a
failure wearing the shape of a success.

So D1 needs a per-session capability gate, cheap and stated:

1. On the first item of a newly attached device, read 12 bytes at offset 0.
2. Require the returned length to be exactly 12 and the magic to identify a family
   consistent with the item's extension (the package's `identify(source:)`, requirement
   R10). Anything else — short read, empty data, error, family mismatch — marks the
   **whole session** as not range-capable.
3. A session that is not range-capable stages as today. Log the decision once per
   attach with the reason, so a vendor that silently lacks ranged reads is visible as a
   named fact rather than as an unexplained slow import.

This gate is what keeps "an unrecognised container costs bytes, never accuracy" true of
transports as well as of formats.

That fallback is what makes this safe for the whole supported surface. `MediaEligibility`
catalogs anything UTType classifies as image, raw image, or movie — an open set, not a
list — so the design must be correct for containers nobody here has seen. It is: an
unrecognised container costs **bytes, never accuracy**, and ARC-057's "proven, not
assumed" invariant is untouched. The fact obtained is in fact *stronger* than what the
gate rejects: a local wall clock with an explicit UTC offset, rather than an instant.

**The parsers already exist.** Otos does not read metadata itself: `MediaEnricher` calls
`MediaMetadataReader.read(url:)` from the `MediaMetadata` package (pinned 0.3.0), which
already contains `ISOBMFFMetadataParser`, `TIFFMetadataParser`, `RIFFMetadataParser` and
`ID3MetadataParser`, all working by directed reads against a `FileByteSource` that is
already a ranged-read abstraction. An earlier draft of this plan proposed writing a TIFF
reader; that would have duplicated working code. What blocks reuse is only that
`FileByteSource` is a concrete `final class` bound to `FileHandle`.

Measured cost of a parse over the corpus (via the package's own read metrics):

| Format | read calls | bytes read | distinct read regions |
| --- | --- | --- | --- |
| HEIF | 138 | 1,533 | **1** (`0 … 100,893`) |
| TIFF/ARW | 21 | 1,155 | **1** (`0 … 43,829`) |
| ISO-BMFF/MP4 | 168 | 11,526 | **3** (head, an `mdat` header probe, tail) |

So a parse needs ~1–12 KB, but issues up to 168 read calls. On a local disk that is free.
Over MTP it is not, and both halves are now **measured against the attached camera**
rather than extrapolated:

| Measurement | Result |
| --- | --- |
| Ranged-read latency (512 B reads) | median **42.6 ms** (min 38.6, max 73.2) |
| Uncached parse, at that latency | **~5.9 s per HEIF file** → 464 files ≈ 45 min, no better than staging |
| Chunked ARW (one 64 KB fetch) | **77 ms/file** |
| Chunked HIF (one 128 KB fetch) | **91 ms/file** |
| Chunked MP4 (head + tail fetches) | **234 ms/file** |

Extrapolating the chunked figures across this card's composition (464 ARW, 464 HIF,
63 MP4) gives **~93 seconds** against 45 minutes, and **~113-143 MB** against 36.5 GB —
the byte range depends on the chunk size chosen per format, and is the figure to log
rather than assert (an earlier draft's "~97 MB" assumed the smallest chunk for every
format). The uncached row is why the caching in package requirement R3 is not an
optimisation: without it this approach is no faster than downloading the card.

The package changes are specified for another agent in
`docs/plans/0101-mediametadata-byte-source-requirements.md`: a `MediaByteSource` protocol,
a `read(source:filename:)` entry point (the `url` is used only for `pathExtension`), the
caching decorator, public read metrics, a stated concurrency contract (the package is
fully synchronous while ICC reads are completion-based), and — load-bearing for ARC-057 —
a transport failure must surface as `.readFailure` rather than as a definitive "no
metadata", or Otos will treat a detached camera as proof that no capture date exists and
name from mtime.

**Staging does not go away; only the *eager* seeding of it does.** D1 removes the code
that pushes all 991 items into materialization demands the moment a camera attaches. It
does not remove staging, and every fallback in this plan depends on that distinction being
implemented rather than assumed. Four cases must still reach local bytes:

| Case | What happens |
| --- | --- |
| Container the reader cannot index (Fuji RAF, an unknown format) | Stage **that one item**, enrich it normally from local bytes |
| Session that cannot serve ranged reads (capability gate failed) | Stage the whole card, exactly as the shipped build does |
| A ranged read fails mid-parse | `.readFailure` -> retry; on repeated failure, stage that item |
| The user opens a loupe on an unstaged item | Stage that one item at interactive priority |

**The mechanism already exists and D1 must not break it.**
`DeviceStagingRegistry.materialize(_ url:)` stages exactly one file — it routes the URL to
its camera session, checks free space, downloads, and returns a `MaterializationResult` —
and it is already wired as the device materialization provider
(`CatalogWindowViewModel.swift:302`). Nothing about it is eager. So the work is not to
build a fallback path; it is to change **what triggers** the existing one: today the
trigger is `stageDevice` seeding everything at attach, and after D1 it must be the
enrichment route answering "this specific row needs local bytes", one row at a time.

That is also why A1 (release staged bytes on settlement) still matters after D1: the card
is no longer staged in bulk, but individual items still land in staging and must be
released when their copy settles.

**The Otos-side seam is larger than an earlier draft of this inventory said.** Read
before being listed:

- **There are three readiness guards, not one.** `MediaEnricher.live`'s *first*
  statement is `guard readinessChecker.status(of: url) == .materialized else { return
  .notMaterialized }` (`MediaEnricher.swift:50`), before hashing and before any parse.
  Two more follow (`:87` after hashing, `:163` inside `parseAndComplete`). Only the
  third sits after `MediaMetadataReader.read`, so the favourable shape is real for the
  *inner* guard and false for the entry point: today an unstaged device file returns
  `.notMaterialized` without a single byte being read.
- **Readiness has no vocabulary for "remote, reachable by range".**
  `LiveEnrichmentReadinessChecker` is `FileMaterialization.status(of: url)` — a local
  file concept. A camera item has no local file, `lstat` fails, and the answer is
  `.unknown`. D1 therefore needs a **route**, not a bypass: a device row must be
  admissible to enrichment on the strength of a reachable session, with the
  `.materialized` guard continuing to protect only thumbnail generation.
- **The `enrich` closure signature is the injection seam.** `MediaEnricher` is a struct
  wrapping `@Sendable (id, url, sourceSize, sourceMTimeSeconds, shouldHash) async ->
  EnrichmentOutcome`. **26 test doubles across 5 files** construct it as a closure
  literal. Any signature change touches all of them; the Tests table below is corrected
  accordingly.
- **No execution context exists for a blocking parse.** The package API is synchronous
  and a camera read blocks ~50-90 ms per fetch, so ~100-300 ms per file. Enrichment runs
  inside `withDiscardingTaskGroup` on Swift's **cooperative pool**
  (`EnrichmentCoordinator.swift:477`), which is sized to core count; blocking several of
  its threads is a forward-progress hazard, not a slowdown. The repo has no dedicated
  thread and no `DispatchSemaphore` anywhere — the only two `DispatchQueue(label:)`
  instances serve DiskArbitration and FSEvents. So D1 must **create** this owner, and it
  belongs in the ADR rather than in a change-inventory row that reads as though the seam
  already exists.

**Design constraints for the Otos side.**



- The parser is **range-driven**: it asks a transport for byte ranges and the transport
  satisfies them — a local file, `ICCameraFile.requestReadDataAtOffset`, or a cloud file.
  One reader then serves camera, card, and cloud, and bytes-consumed becomes a measured
  outcome to log, not a constant to tune.
- Do not route RAW through ImageIO: `CGImageSource` validates the whole container and
  returned nothing from a 16 MB ARW prefix, while an IFD walk found the tag 4.5 KB in.
  The package's `TIFFMetadataParser` already does the walk, which is another reason the
  reader belongs there rather than in Otos.
- Video duration comes from `moov`/`mvhd` in the same tail read, which removes the reason
  ENR-012's `mtime − duration` derivation currently downloads whole videos.
- Do **not** name from `fileCreationDate`. It matched the enrichment wall for 991/991
  items here, but every item was shot in the machine's current UTC offset, so the round
  trip is lossless by construction and proves nothing about travel. Keep it as a
  cross-check, never as the naming source.

**Docs this carries.** An ADR for the range-driven reader and its transport boundary;
an ARC-057 amendment stating that a naming fact may be proven from a ranged read;
ENR-012 updated for duration from the container; requirements rows for both.

**Import already works without enrichment staging — verified.** The largest risk in D1
was that removing eager staging would leave import with no bytes.
`DeviceStagingRegistry.ensureImportBytes` already handles both cases: if an
enrichment-staged file exists *and* its size matches the camera's `fileSize`, it copies
that file into import staging; **otherwise it downloads the item directly from the camera
into import staging** (`session.download(relativePath:to:)`). D1 therefore does not need a
new import path — it makes the existing second branch the normal one.

The same reading corrects this plan's earlier arithmetic. Today the reuse branch *copies*
rather than moves, so during a run the bytes exist in three places at once: enrichment
staging, the per-file import staging temp, and the destination. After D1 a camera item is
transferred exactly once, at import.

### D1b — Consequence of D1: the whole card's transfer moves onto a path E1 does not cover (severity: high)

Discovered while verifying D1's "no new import path" claim, and it is the single largest
risk in this plan. The claim is true — and that is the problem.

`MediaImportExecutor.workerCount = 8` (`MediaImportExecutor.swift:92`), and each worker
calls `cameraImport.ensureImportBytes` -> `session.download(relativePath:to:)`
(`DeviceStagingRegistry.swift:285`). That call **bypasses `MaterializationCoordinator`
entirely**. It is not a request, it is not admitted, no policy sees it.

Today this is harmless: the reuse branch usually wins, so the 8 workers perform local
`copyfile` transfers, where 8-way concurrency genuinely helps. **After D1 the reuse
branch never wins for a camera item**, so those 8 workers become 8 concurrent
ImageCaptureCore downloads funnelling into the same serial `ICDeviceCommandQueue` that
E1 identifies as costing 3-40x throughput. D1 therefore relocates the entire 36.5 GB
transfer from a path E1 fixes onto a path E1 does not touch, and the sequencing in the
earlier draft landed D1 at step 3 and E1 at step 6 — the regression before the fix.

**Fix, and it is part of D1's increment, not E1's.** Device concurrency must be a
property of the **device session**, not of `MaterializationCoordinator`: one in-flight
ICC operation per attached device, whoever asks — enrichment ranged reads, enrichment
downloads, or import downloads. That is the only placement that survives D1, because
after D1 the coordinator no longer sees the traffic. The alternative — routing import
bytes through `MaterializationCoordinator` — is a larger change that also inverts the
executor's byte-progress reporting, and is rejected for that reason.

Consequence for E1 below: the cap E1 describes is still needed for the pre-D1 staging
path, but the session-level cap is the one that must exist when D1 lands. Write one owner,
not two.


### D1a — Consequence of D1: camera thumbnails stay provisional until import

Discovered while verifying, not anticipated. Today a camera item gets an ICC thumbnail
written immediately as a *provisional* file
(`CatalogWindowViewModelSourceMonitoring.writeProvisionalThumbnail` →
`ThumbnailStore.writeProvisionalJPEG`), and enrichment later replaces it with the real
256 px QuickLook thumbnail generated from the **staged** bytes (ADR 0009: QuickLook, real
imagery only, `.icon` rejected). QuickLook needs a local file, so if D1 stops eager
staging, camera grids keep the provisional 160×120 image until the item is imported.

This is a user-visible quality regression that D1 causes, so it is part of D1's decision,
not separate polish. Three ways to answer it, in increasing cost:

1. Accept provisional quality while a card is attached — the grid is being triaged, and
   library rows get real thumbnails after import.
2. Stage on demand for what the user actually looks at. The interactive-priority path
   already exists (`docs/research/2026-07-14-interactive-materialization-priority.md`),
   so a loupe open pulls that one file.
3. Extract the embedded preview through the same range reader. **Measured, and it is
   better than expected:**

   | Format | Source | Extra cost | Result |
   | --- | --- | --- | --- |
   | HIF | embedded thumbnail in the **same 128 KB prefix already fetched for the wall** | **none** | **256×170** — exactly the `ThumbnailStore.maxPixelSize` target |
   | ARW | IFD0 preview, offset 196,770, length 292,799 | one ~286 KB read (~90–150 ms) | valid **1616×1080** JPEG (`ffd8`…`ffd9`) |

   ARW's IFD1 holds a **160×120** thumbnail — exactly what ICC serves, confirming the
   device simply returns the embedded EXIF thumb rather than generating anything.

**So D1a is not a regression after all** — but option 3 is the *only* option that
answers it, which the earlier draft got wrong.

For HEIF the full-quality thumbnail is free: it arrives in the bytes the naming read
already fetches. For RAW it costs one small extra ranged read, and where the camera
shoots RAW+JPEG pairs the displayed member is usually the HEIF, so even that may be
unnecessary.

**Options 1 and 2 are not fallbacks; they are dead ends.** Checked against the claim
predicate: `MediaAsset.needsEnrichment(hashRequired:)` is `metadataStale || (hashRequired
&& hashStale)` (`CatalogModels.swift:511`) — **thumbnail presence does not participate**.
Once D1 stamps a device row from a ranged read, the row is never re-claimed, so there is
no path that regenerates its grid thumbnail later. Option 1 ("accept provisional quality")
and option 2 ("stage on demand for the loupe") therefore leave the grid at 160x120 for as
long as the card is attached, permanently, not temporarily. Option 2 still helps the
*loupe* — `PreviewImageLoader` is a separate path and can materialize one file on demand —
but it never upgrades a tile.

So D1a option 3 is promoted from "nice, and measured" to a **requirement of D1**, and it
is why package requirement R11 (embedded-preview descriptors) exists rather than being
deferred.

**APP-015 is unaffected either way**, and this was verified rather than assumed: a
`.complete` outcome carrying `generatedThumbnail: nil` does not delete anything —
`CatalogStore.swift:1484` promotes only when the value is non-nil — and
`ThumbnailStore.writeProvisionalJPEG` writes to the same deterministic final name the
grid loads by. No painted tile blanks. It simply stays provisional.

### D2 — Thumbnail quality: answered by D1a, no separate decision needed

This was raised as an open owner decision: ICC returns 160×120 against
`ThumbnailStore.maxPixelSize = 256`. D1a's measurement answers it for this body — but the
earlier draft's *reason* was wrong, and the correction changes what to expect elsewhere.

The observation is sound: Otos already passes `imageSourceThumbnailMaxPixelSize: 256`
without `ICImageSourceShouldCache` (`CameraSourceMonitor.swift:433`), which is the
combination the SDK requires, and 160×120 is what comes back. But the claim "160×120 is
all ImageCaptureCore ever returns" is contradicted by the framework's own header, which
documents the opposite:

> Only the embedded EXIF thumbnail, or a created thumbnail of EXIF standard size
> (160x120) will be cached. […] Multiple calls to both cache the EXIF thumbnail, and
> subsequently retrieve a larger thumbnail will work as defined.
> — `ICCameraItem.h`, `ICImageSourceThumbnailMaxPixelSize`, macOS 27 SDK

160×120 is what the framework *caches*; a larger thumbnail is documented as retrievable.
So the honest, device-scoped claim is: **this body, over PTP, serves only its embedded
EXIF thumb.** That is a device limitation after all, not a framework one — and it means
another vendor may well answer a 256 px request directly, making D1a option 3 unnecessary
for that vendor. Reading the container directly yields 256×170 for HEIF at no extra cost
and 1616×1080 for ARW at one small read, so option 3 remains the design that is correct
everywhere; the point of the correction is that the *reason* must not be over-generalised
into a framework fact it is not.

## A · Staging lifetime

With D1 landed, staging holds only items being imported plus whatever the fallbacks in D1
staged one at a time, which makes A1 the normal path rather than a cleanup. A1–A3 are
worth fixing regardless: they are wrong today and D1 does not repair them.

**Staging is cleared at three points, and all three are needed.** They are listed together
because each covers a case the others cannot:

| When | Why it exists | Item |
| --- | --- | --- |
| On settlement, per item | The bytes are durably in the library, so the cache copy is dead weight. Reclaims during a run rather than after it | A1 |
| At quit, whole tree | Staging is a session cache; quitting clears it. Owner decision 2026-08-30, with a visible "clearing" state | A2 |
| At launch, whole tree | The crash backstop — a process that died never ran its quit path. Also covers a quit whose delete failed | A3 |

An eject does **not** clear staging: those bytes are already off the camera, and discarding
them would re-download the whole device on the next attach (APP-018).

### A1 — Staged bytes are never released after a successful import (severity: high)

No call site deletes a device-staged file after it is copied into the library. The only
deletions discard the entire tree at launch or quit. An import costs 2× the bytes on disk
and reclaims nothing until the app closes. The 2026-07-06 research asked for exactly this
("an eviction policy for never-imported files"); it was never implemented.

**Fix.** Release is a *consequence of settlement*, not a sweep: when an entry's copy is
verified and its journal row settles, the executor releases that one staged file, through
one registry intent, so there is a single path from "durably in the library" to "cache
copy gone". A failed or blocked entry keeps its bytes so a retry does not re-download.


**Hook point — verified.** The per-entry settlement is
`request.store.settleImportedAsset(...)` in `MediaImportExecutor.swift:1302`, immediately
before the `mediaOperation.copy phase=finish` log. Releasing that entry's staged source on
the success path there gives exactly one route from "durably in the library" to "cache copy
gone". The crash-recovery equivalent is `settleIfOwned` / `settleRecovered` (`:1528`,
`:1601`), which must release the same way so a recovered run does not leak staged bytes.

**Scope note.** After D1 there is usually nothing to release, because staging only holds
what is being imported. A1 still matters for the transition, for on-demand staging (a loupe
open pulls one file), and for any retry that leaves bytes behind.

### A2 — Quit-time deletion cannot finish, so staging survives a clean quit (severity: high)

`OtosApp.swift:18` deletes the whole tree synchronously inside `applicationWillTerminate`.
macOS bounds that window; 36.5 GB across thousands of files does not finish, the process
dies mid-delete, and the staging survives — the behaviour the owner observed. It also
makes Quit hang. The earlier "verified staging clears on quit" evidence was gathered at
101 MB, which fits the window and hid the defect.

**Fix — owner decision 2026-08-30: the bytes are deleted at quit, and the app shows
that it is doing it.** Deferring the delete was rejected. Staging is a cache; quitting
clears it; taking a few seconds to do so is acceptable as long as the user is told.

The defect is not that the delete is slow — it is that `applicationWillTerminate` is a
**bounded** window. macOS kills the process partway through, which is why 36.5 GB survived
a clean quit while the 101 MB test case did not. Letting it "just hang" there does not
work: the OS ends the process regardless.

The mechanism that actually delivers the decision:

1. `applicationShouldTerminate(_:)` returns `.terminateLater`, which gives an **unbounded**
   window instead of a bounded one.
2. Show a small modal "Clearing cached camera files…" with an indeterminate spinner. This
   is the "tell the user" half, and it is what makes a multi-second quit acceptable rather
   than a hang.
3. Perform the recursive delete **off the main thread**, so the window paints and the app
   does not beachball while it works.
4. Call `replyToApplicationShouldTerminate(true)` when the delete finishes, and also on
   failure — a failed delete must not trap the user in an app that will not quit. The
   launch sweep is the backstop for that case, as it already is for a crash.

`DeviceStagingRegistry.discardAllStaging()` keeps its current contract. What changes is
where it is called from, that it no longer runs on the main thread, and that quitting is
now a visible operation rather than a silent one.

**Progress detail, deliberately omitted.** A file count would be honest but requires
enumerating the tree before deleting it, which doubles the work for a spinner. Revisit
only if the clearing step measures long enough to warrant it.

### A3 — The launch sweep deletes gigabytes on the main actor (severity: high)

`startDeviceStagingSweepThenCameraMonitoring` creates its `Task` inside a `@MainActor`
type, so it inherits MainActor isolation and performs the recursive delete on the main
thread. The `await MainActor.run { … }` right after it is a no-op hop and evidence the
author believed the work was off-main.

**Fix.** `Task.detached(priority: .utility)` or a `nonisolated` async function, hopping to
MainActor only to start monitoring.

### A4 — The sweep is not instance-safe (severity: medium)

The launch sweep deletes the whole root including directories owned by another running
Otos instance. Two instances ran on this machine today; the second would have destroyed
the first's in-flight staging.

**Fix.** Give each launch its own staging directory, `DeviceStaging/<instance-uuid>/`.
The launch sweep then deletes every directory that is not its own, and a second instance's
in-flight staging is untouched. Crash-safe and instance-safe, no cross-process state.

Rejected: making one-main-window true at the process level and refusing a second launch.
That is a different invariant (ARC-014 is about one *window*) and a user-visible product
change, which is a large answer to a bug whose cause is a shared directory name. The
tooling already covers the case that matters — `script/smoke-run.sh` calls
`refuse_if_app_already_running` before both of its modes.

### A5 — Dead code (severity: low, smell)

`deleteStaging(identity:)` and `sweepAbsentDeviceStaging(exceptIdentities:)` are never
called. `deleteStaging` became unreachable when `unregister` stopped deleting staging.
Remove both; A1 gets a purpose-named intent rather than reviving an orphan whose contract
was "delete this whole camera".

### A6 — One word, two lifecycles (severity: low, smell)

"Staging" means both device staging (cached camera bytes) and import staging (the hidden
`.otos-import-staging` temp file beside the destination). `removeOrphanedStaging` is about
the second and reads as though it cleans the first. Rename one.

---

## B · Observability

### B1 — Log flood causes real message loss (severity: high)

2,336 lines/second at peak; the session recorded 155 of ~991 download completions, and a
fully working pipeline read as dead for 40 minutes. This produced a false diagnosis of a
permanent ImageCaptureCore wedge, corrected only by checking file mtimes on disk.

**Fix.** The enrichment route line logs on *state change* — when claimed/dispatched/
in-flight/pending differ from the last emission — collapsing identical passes into one
line carrying a suppressed-pass count.

### B2 — The readiness retry map spins the scheduler at zero delay (severity: high)

**Root cause identified — a defect, not a cadence problem.** The wake signal already
coalesces (`AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))`,
`EnrichmentCoordinator.swift:247`), so queued duplicate signals are not the cause. The
spin comes from `readinessRetryNotBefore`:

- A row reading `.unknown` gets a deadline: `readinessRetryNotBefore[asset.id] =
  Date().addingTimeInterval(1)` (`EnrichmentCoordinatorWorkSelection.swift:81`).
- Entries are cleared in exactly two places: when *that same row* is re-examined after its
  deadline (`:59`), and wholesale at shutdown (`EnrichmentCoordinator.swift:321`). **Stale
  entries are never pruned.**
- `scheduleReadinessRetrySignal` (`:120`) takes `readinessRetryNotBefore.values.min()` and
  sleeps `max(nextRetry.timeIntervalSinceNow, 0)`.

So as soon as any entry's deadline passes without that row being re-examined — which
happens the moment a row is routed to materialization (those stay independently claimed,
so later queries skip them) or leaves the claim index — the minimum is permanently in the
past, the delay is **zero**, and the loop becomes
`sleep(0) → signal → pass → schedule → sleep(0)`. That is the observed hundreds of
identical `dispatched=0` route lines inside one second, and it accounts for the CPU burn
and the `MediaGridViewController.reconfigureVisibleItems` main-thread stalls recorded in
the same window.

**This makes B1 a symptom.** The flood that cost ~836 dropped events is produced by this
spin; fixing B2 removes the volume. B1's state-change logging remains worth doing as
hygiene, but it is not the primary defect.

**The trigger is more specific than "a row leaves the claim index", and the difference
matters for the test.** A row can only hold a stale entry if it is never re-examined, and
the structural reason it is never re-examined is the loop's own early exit: the `.dataless`
branch bails with `guard materializationDemands.count < handoffPolicy.globalOutstandingLimit`
(`EnrichmentCoordinatorWorkSelection.swift:65`) and the pass breaks outright at `:93` on
the same condition. During device staging `materializationDemands` sits **saturated at 16**
by `admitPendingDeviceSeeds`, so every pass breaks early and past-deadline entries are
*structurally guaranteed* to go unexamined. That is why the spin was reliable rather than
occasional.

**Fix.** Prune the map rather than damp the loop — but the drafted rule cannot be written:
a pass sees only `claimed.ready`, so it cannot know which rows it did *not* examine. The
expressible and provably correct rule is simpler: **at the end of every pass, drop every
entry whose deadline is already in the past.** Either the row was examined (the entry was
cleared at `:59`) or it was unreachable and its deadline means nothing. `min()` is then
always a genuine future deadline, and if nothing remains, schedule nothing. A
minimum-delay floor would hide this rather than fix it — the zero delay is a symptom of
state that should have been removed.

Regression test, aimed at the real trigger: saturate `materializationDemands` to the
outstanding limit, run a pass that consequently breaks early while a past-deadline entry
is present, and assert the coordinator schedules **no** immediate wake.

### B3 — `publish()` throttles by time, so alternating states are invisible (severity: medium)

At most one line per 250 ms per source. The session alternated `.planning` →
`.waitingForMetadata` every ~1.1 s with the pair ~140 ms apart, so the log showed 33
`planning` publishes and zero `waitingForMetadata` ones, and it was impossible to tell
from logs whether the counting frames reached the view.

**Fix.** Log on state change with a repeat count, not on a timer.

### B4 — The apply log cannot distinguish the two Preparing frames (severity: medium)

`phase=apply` records `drawnKind` only, and both `.planning` and `.waitingForMetadata`
draw kind `.preparing`. The number the user sees is absent from the log.

**Fix.** Record the drawn secondary line and progress track.

---

## C · Progress honesty

### C1 — The progress signal measures the wrong quantity (severity: high)

The bar counts naming decisions settled. The work consuming the time was a 36.5 GB
transfer. Four quantities were in play and none were equal: settled walls (152), enriched
rows (97), staged files (99), completed downloads (58). No bytes, no rate, no estimate.
The owner could not distinguish slow from stalled, and neither could the agent.

**The rule, stated plainly: the bar's track shows the progress of the stage the bar is
in.** There is one bar (one surface, fixed height, DES-018/DES-053) and it moves through
states. While preparing, the track is preparation progress. Once a plan is ready there is
no track, just the Import button. Once import runs, the track is import progress. That is
already the specified design — state A calls for `Checking the card…` with `112 of 181
items` and a **determinate** track — and it is broken in exactly two ways: the track
blanks and flips to indeterminate every cycle (C2), and the number it counts during
preparation was not the work the user was waiting on (C1, below).

**Fix, and D1 changes what the preparation number should be.** The finding above is true
of the shipped build and false of the build D1 produces, so the two must be written
together or C1 will be implemented for a world that no longer exists.

- **Before D1** the honest quantity is bytes: 36.5 GB is moving and the count of settled
  walls is not what the user is waiting for.
- **After D1 no bytes move during Preparing at all.** Planning reads ranges — ~93 seconds
  and ~113-143 MB for this card — and the work being done *is* the naming reads. The
  count of naming facts settled therefore becomes the truthful measure of exactly the work
  in flight, which inverts this section's original conclusion.

So C1 lands as: **Preparing's track reports items read of the settled total** (C2's held
count, now honest, and still withheld while enumeration is in flight per ADR 0024), and
**byte/rate/estimate stay with Working**, which is where the 36.5 GB actually moves and
where `MediaOperationProgress` already carries `completedCount`, `totalCount` and
`completedBytes`. Naming-settled is only "internal readiness" while something larger is
happening behind it; after D1 nothing is, so it becomes a truthful measure of exactly the
work in flight.

### C2 — The count blanks ~140 ms of every 1.1 s cycle (severity: medium)

`presentation(for:)` maps `.building → heldPlanState ?? .planning`; no plan is ever proven
while naming is pending (correct per ARC-047), so every rebuild frame publishes
`.planning`, which draws no L3 line and an indeterminate bar. `import-bar.md:198-201`
requires determinate whenever a real total exists.

**What the user sees:** during preparation the progress track cannot hold still — it
shows a determinate bar with a count, then ~140 ms of indeterminate bar with no count,
then back, about once a second. That is the preparation stage failing to report its own
progress, which is the whole of C1's rule.

**Fix.** Preparing needs the memory Ready already has. `heldPlanState` holds the last
proven *plan*; nothing holds the last *naming progress*, though Preparing is the state
that owns a count. Hold `(done, total)` for the attachment and present it across
`.building`. The count is monotonic and already proven, so showing it during a rebuild
asserts nothing new, and the track stays determinate for the whole stage.

### C3 — Preparing was specified as momentary; on MTP it was the whole session (severity: medium)

`import-bar.md` scopes state A to "only before this attachment has ever produced a plan".

**D1 shortens the wait but does not restore "momentary".** An earlier draft assumed it
would. The plan's own arithmetic puts Preparing at **~93 seconds** for a 991-item card
(see Target state), which is 29x better than the 45 minutes measured and still two orders
of magnitude longer than the spec's premise. A state that lasts a minute and a half is one
the user watches, so it needs a count that does not blank (C2), a quantity that describes
the work actually happening (C1), and a determinate track.

Re-check the spec against the measured ~93 s rather than against "brief". The likely
outcome is that state A's wording changes and its content requirements harden — not that a
separate long-running variant is written.

---

## E · Device concurrency

### E1 — 16-way device concurrency is fictional and measurably costs throughput (severity: high)

`globalOutstandingLimit = 16` is applied to device materialization, but ImageCaptureCore
funnels every request through one serial `ICDeviceCommandQueue` — a process sample showed
1,465 of 1,481 samples inside `requestDownloadWithOptions`. Fifteen of the sixteen sit
inside ICC where Otos cannot observe, time, or cancel them. The 2026-07-06 POC measured
40 MB/s single-stream; this session measured 0.9–8.5 MB/s under the 16-way window,
averaging ~13.5 MB/s.

**Measured 2026-08-30, against the attached camera.** Single-stream `requestDownload`:
**37.2 MB/s** for a 32 MB ARW and **39.9 MB/s** for a 320 MB MP4 — matching the
2026-07-06 benchmark of 40 MB/s. The shipped 16-way window delivered 0.9–8.5 MB/s during
the session, averaging ~13.5 MB/s across the card. The window is therefore **3–40×
slower than a single stream**, and it is the reason the card took ~45 minutes rather than
the ~15 minutes 36.5 GB would need at 40 MB/s.

**Fix, and where it goes.** Device concurrency of 1 — but **not** by lowering the global
limit. Two separate caps of 16 exist and they are different things:

- `EnrichmentCoordinator.handoffPolicy.globalOutstandingLimit = 16` — how many enrichment
  demands may be outstanding.
- `MaterializationAdmissionPolicy.production.globalConcurrency = 16`
  (`MaterializationAdmissionPolicy.swift:36`) — how many materializations run at once,
  **globally across every transport**, alongside `byteBudget` 2 GB,
  `largeVideoThresholdBytes` 256 MB, `largeVideoCap` 2, `backgroundPerRootCap` 1.

They are different *concepts* but they are **not independent values**:
`EnrichmentMaterializationHandoffPolicy.production` is literally
`globalOutstandingLimit: materialization.globalConcurrency`
(`EnrichmentAdmissionPolicy.swift:81`). The earlier draft treated them as two unrelated
16s; they are one 16 read twice.

Setting `globalConcurrency` to 1 would throttle cloud and local materialization as well,
which is not the finding. The cap must be per-transport, and the policy is the right home:
`MaterializationCoordinator.Priority` has had a `.device` case since it was written
(`MaterializationCoordinator.swift:24`), while `MaterializationAdmissionPolicy` contains
**zero references to `.device`** — which is precisely why device requests escape both
`.backgroundReserve` and `.rootBackgroundCap` (both test `priority == .background`) and
sixteen of them run at once. Adding a device cap alongside a `deviceCount` in `Snapshot`
fits the shape that is already there.

**Say what happens to the other fifteen.** Capping admission does not reduce *demand*:
`dequeueMaterializationSubmissions` still selects up to `globalOutstandingLimit -
materializingCount` device works, and each becomes a parked `await requester.materialize(…)`
inside the coordinator's queue. That is acceptable — the queue is what the coordinator is
for, and only one reaches ICC — but it must be stated, because sixteen parked awaits with
no deadline is exactly the shape E2 is about.

**And note the scope limit that D1b makes decisive.** This cap governs materialization
only. After D1 the card's transfer no longer flows through materialization at all, so this
fix alone leaves the import path at 8-way ICC concurrency. The cap that survives D1 is the
**per-device-session** one described in D1b; this one covers the pre-D1 staging path and
any on-demand staging that remains. One owner, expressed once, applied at the session.

### E2 — A device transfer has no deadline, and only a completion frees its slot (severity: medium)

`EnrichmentCoordinatorCompletion.swift:173` states that a completed download is "the only
moment a queued device seed can be admitted". There is no timeout, cancellation, or
watchdog. If ICC ever stops delivering completions, all slots are held forever, every
queued item waits behind them, and the UI keeps drawing a determinate bar. This did
**not** happen in this session — the pipeline completed — but nothing prevents it.

**After D1 this stops being a video-download concern and becomes the planning path.**
The dominant device operation during Preparing is the ranged read, the package API is
synchronous, and a read blocks its thread until the transport answers. There is
externally documented precedent for a transport that never answers: libmtp#8 records
Samsung Galaxy devices failing `GetPartialObject` **by timeout** at offsets where
`size mod 512 == 500`, about one file in 512. A blocking read with no deadline is
unbounded, and unlike a download it holds a thread rather than a slot.

**Fix.** A per-operation deadline that frees the slot and marks the item retryable, plus
an honest stalled state in the bar — and the deadline must cover **every** ICC operation
the session issues: downloads, thumbnail requests, and ranged reads. A ranged read that
exceeds its deadline fails as a transport failure (never as absence — see D1 and package
requirement R7), which demotes the session to not-range-capable and falls back to
staging, rather than retrying the same offset forever. Recovery constraint: a request
already parked in Apple's semaphore cannot be cancelled, so real recovery means closing
and reopening the device session.

---

## F · Diagnostic failures during this session (process, not product)

- **F1.** A permanent ImageCaptureCore wedge was diagnosed from *missing log lines* plus a
  semaphore wait, without consulting the filesystem — the repository's declared source of
  truth. `find -newermt` refuted it in seconds. Absence of evidence in a flooded log is
  not evidence of absence.
- **F2.** The owner's report that the bar was stuck was answered twice with "it is merely
  slow". The counter was live but measuring the wrong quantity (C1), so both readings
  were wrong for different reasons.
- **F3.** Three mechanisms were shipped and reported as fixed without being made to fire:
  `--pid` (reached only `stream`), the stall detector (integer-only arithmetic, returned
  a constant, would have false-killed a healthy run), and the guard hook (denied reading
  its own files). A mechanism is not delivered until it has been observed doing its job.
- **F4.** The ImageCaptureCore capabilities were re-derived by probing hardware when
  `docs/research/removable-volume-and-camera-sources.md` had recorded them on 2026-07-06,
  including "partial reads work… this is the door to header-parsing EXIF". Read the
  research before measuring. A second research file was created on a topic that already
  had a MECE home; it has been merged and deleted.
- **F6.** The capability was recorded in July and not acted on for seven weeks. The
  2026-07-06 research noted that partial reads work and called it "the door to
  header-parsing EXIF", then stopped — it never established *how many bytes* a naming fact
  needs, which is the fact that makes the idea actionable. Eager staging was adopted
  instead. The sizing work happened on 2026-08-30 and took an afternoon. A capability noted
  without its cost is not yet a finding anyone can plan against; record the number, or say
  explicitly that the number is unknown and blocking.
- **F5.** A prefix-escalation ladder was proposed as the way to locate metadata. The
  formats are self-describing and the specifications answer it directly; the ladder was a
  guess presented as a strategy.

---

## Change inventory

What each increment touches. Every row was read before being listed; nothing here is
inferred from a filename.

**Code**

| Area | Files | Why |
| --- | --- | --- |
| D1 camera byte source | **New, Otos-owned.** A `MediaByteSource` over `ICCameraFile.requestReadDataAtOffset`, wrapped in the package's `CachingByteSource` at an Otos-chosen chunk size | The split: the package owns *which ranges to read* and the caching *mechanism* (0101 R3 — the read pattern that makes it necessary is the package's own); Otos owns *what a read costs* and therefore the *number*. Measured need: HEIF touches one region of ~101 KB, ARW one of ~44 KB, MP4 three regions — so ~128 KB chunks collapse a parse into 1–3 fetches. Uncached the same parse costs 138 round trips ≈ 5.9 s/file, no better than downloading. The source is created, used and closed inside one `read(source:)` call and never escapes it (0101 R4), which is what keeps it out of `@unchecked Sendable` territory |
| D1 parse execution | **New, Otos-owned.** A dedicated-thread executor for blocking device parses | The package API is synchronous and a camera read blocks ~50–90 ms per fetch, ~100–300 ms per file. This is fine on a dedicated thread and **not** fine on Swift's cooperative pool, which is sized to core count — blocking several of its threads is a forward-progress hazard. This owner does not exist today: enrichment runs in `withDiscardingTaskGroup` on the cooperative pool (`EnrichmentCoordinator.swift:477`), and the repo has no dedicated thread and no `DispatchSemaphore` anywhere (the only two `DispatchQueue(label:)` serve DiskArbitration and FSEvents). It is a new mechanism with a named owner, and it belongs in the ADR |
| D1 metadata acquisition | `Otos/Services/MediaEnricher.swift`, `Otos/Services/EnrichmentReadinessRouter.swift`, `Otos/Services/CameraSourceMonitor.swift` (`DeviceCameraSession` gains a ranged-read byte source over `requestReadDataAtOffset`) | Naming facts from ranges instead of staged files. **Three** readiness guards exist, not one (`MediaEnricher.swift:50`, `:87`, `:163`), and the first is the outermost statement of `MediaEnricher.live` — an unstaged device file returns `.notMaterialized` before any read. Readiness itself is `FileMaterialization.status(of:)`, a local-file concept that answers `.unknown` for a camera item, so this needs a **route** for reachable-by-range rows, not a bypass. The `enrich` closure signature is the injection seam: **26 test doubles across 5 files** construct it. See "The Otos-side seam is larger…" in D1 |
| D1 scheduling | `Otos/Services/EnrichmentCoordinator.swift` (`stageDevice` / `admitPendingDeviceSeeds`), `EnrichmentCoordinatorWorkSelection.swift`, `EnrichmentCoordinatorCompletion.swift` | Stop eagerly seeding the whole device. Verified mechanism: `stageDevice` seeds **every** enumerated item into `materializationDemands` up to `globalOutstandingLimit` — this, not the `.unknown` readiness retry, is what downloads the card |
| D1 hash policy | `Otos/Models/CatalogModels.swift` (`isContentHashRequired`) | `.deviceMTP` becomes hash-not-required once its bytes are no longer local (ADR 0018) |
| A1 release | `Otos/Services/MediaImportExecutor.swift` (settle path), `Otos/Services/DeviceStagingRegistry.swift` (one release intent) | Staged bytes freed when a copy settles |
| A2 quit | `Otos/OtosApp.swift`, `Otos/Services/DeviceStagingRegistry.swift`, a small quit-progress window | `applicationShouldTerminate` + `.terminateLater` + off-main delete + `replyToApplicationShouldTerminate`, with a visible "Clearing cached camera files…" state. Replaces the bounded `applicationWillTerminate` window that macOS kills partway through |
| D1b device session cap | `Otos/Services/CameraSourceMonitor.swift` (`DeviceCameraSession`), `Otos/Services/MediaImportExecutor.swift` | One in-flight ICC operation per attached device, enforced at the session so it survives D1. `MediaImportExecutor.workerCount = 8` workers each call `session.download` (`DeviceStagingRegistry.swift:285`), which bypasses `MaterializationCoordinator` entirely — after D1 that is the whole card's transfer |
| A3/A4 launch | `Otos/ViewModels/CatalogWindowViewModelSourceMonitoring.swift`, `Otos/Services/DeviceStagingRegistry.swift` | Off-main sweep; per-instance staging directory so the sweep cannot delete another instance's in-flight staging |
| A5/A6 | `Otos/Services/DeviceStagingRegistry.swift`, `Otos/Services/MediaImportExecutor.swift` | Remove dead code; rename the colliding "staging" concept |
| B1/B2 | `Otos/Services/EnrichmentCoordinatorWorkSelection.swift`, `EnrichmentCoordinator.swift` | Log on state change; stop re-signalling while materialization-bound |
| B3/C2 | `Otos/Services/MediaOperationCoordinator.swift` | Publish logging on change; hold last naming progress across `.building` |
| B4 | `Otos/ViewModels/CatalogWindowViewModelMediaOperations.swift` | Apply log records the drawn line and track |
| C1/C2 | `Otos/Views/ImportBarPresentation.swift` | Preparing reports **items read** of the settled total and keeps its count across `.building`; byte/rate/estimate belong to Working, not Preparing (see C1) |
| E1/E2 | `Otos/Services/MaterializationAdmissionPolicy.swift` (a `.device` cap and a `deviceCount` in `Snapshot` — the policy has **zero** `.device` references today, which is why sixteen run at once), `Otos/Services/MaterializationCoordinator.swift` | Device concurrency for the materialization path; per-operation deadline covering downloads, thumbnail requests **and** ranged reads |

**External package** — `docs/plans/0101-mediametadata-byte-source-requirements.md`, which
is the upstream brief for `github.com/tonimelisma/MediaMetadata` and is written in
package-general terms rather than as Otos requirements. D1 depends on:

| Req | What Otos needs it for |
| --- | --- |
| **R1** byte-source protocol | The camera source exists at all |
| **R2** `read(source:filenameHint:)` | Camera items have a name, never a URL |
| **R4** execution contract | Says a source is confined to one call, so Otos needs no `@unchecked Sendable` — which `script/check-no-unchecked-sendable.sh` forbids (ARC-042) |
| **R5** public read metrics | Log what a parse actually cost; verify Otos's chunk cache |
| **R6+R7** failure channel | A transport failure must never read as "no metadata". Load-bearing for ARC-057 and for D1's capability gate |
| **R10** `identify(source:)` | The 12-byte capability probe in D1 |
| **R11** embedded-preview descriptors | D1a option 3, promoted to a requirement |

R3 (a caching decorator) was withdrawn from that document by an earlier draft on the
grounds that cache sizing is a transport property. That is now **partly reversed**: the
*number* is Otos's, but the *mechanism* is generic and the read pattern that makes it
necessary is the package's own, so the package ships `CachingByteSource(wrapping:chunkSize:)`
and Otos supplies the chunk size. See 0101 R3 for the argument.

Otos still owns, and must not push upstream: transport lifecycle, session and retry,
deadlines, concurrency caps, thread policy, chunk sizing, and every naming decision.

**ADRs**

- **New ADR** — range-driven metadata acquisition: the byte-source boundary, the terminal
  fallback to full transfer, and why naming facts from ranges still satisfy "proven".
- `docs/adr/0009-enrichment-storage-and-staleness.md` — enrichment no longer implies local
  bytes for the naming fact.
- `docs/adr/0018-xxh3-128-content-hash-overlay.md` — **amend**. It gates hashing on *byte
  locality*: "Enrichment computes a digest only for roots whose bytes it reads in place:
  fixed libraries and device-staging roots." D1 removes that premise for `.deviceMTP`, so
  it must join `.removableVolume` as hash-not-required, receiving its digest after import
  from the destination's local bytes — which is exactly what the ADR already prescribes for
  removable media. Implementation is one line: `Root.isContentHashRequired` is literally
  `kind != .removableVolume` (`CatalogModels.swift:219`). **No migration is needed** — the
  metadata-only claim indexes already exist from `v13_hash_gated_enrichment_claim_indexes`,
  and `EnrichmentLeaseGateway` already selects between the broad and metadata-only index by
  `hashRequired`.
- `docs/adr/0024-import-source-readiness-gate.md` — **read; constrains C1 but does not
  conflict with it, and needs no change.** An earlier draft of this plan called it a
  blocker on the strength of its summary sentence. The rule turns on one word: "there is
  no partial/growing **total**" — the prohibition is against a count whose *total* is still
  moving while enumeration runs. `ImportSourceReadiness.evaluate` is a pure function of
  availability and activity, returning `.preparing` only while `.scanning`/`.enumerating`.
  Once it reports `.ready` the total is stable, which is precisely when
  `waitingForMetadata(done, total)` shows a count today. C1 must therefore keep showing
  nothing while enumeration is in flight and may report progress against the settled
  total afterwards — which is what it already proposes.
- `docs/adr/0009-enrichment-storage-and-staleness.md` — thumbnails are QuickLook-generated
  from a real file, which is why D1a exists.
- `docs/adr/0026-settled-naming-and-card-erase.md` — **read; the standard it sets is what
  D1 must preserve.** "A row with no embedded wall clock may use its filesystem
  modification date once enrichment has *read the file and established that no embedded
  date exists*." A ranged read that reaches the container's metadata region and finds no
  date meets that standard — absence is proven, not assumed. A ranged read that *fails*
  does not, which is exactly why package requirement R7 (transport failure ⇒
  `.readFailure`) is load-bearing rather than cosmetic.
- `docs/adr/0013-removable-and-device-sources.md` — **read, and no change needed.** It
  covers root identity, path remapping and All-Media scoping; it says nothing about
  staging or byte access. Listing it earlier was speculation from its title.

**Requirements rows** (`docs/requirements.md`)

- **ARC-057** — a naming fact may be proven from a ranged read; ICC's own dates remain
  rejected as a naming source.
- **ENR-012** — **precision correction.** The row selects the wall from local-authority
  timestamps in role order `original → digitized → quickTimeCreation → quickTimeContentCreate`
  and explicitly *excludes UTC-anchored candidates*. So a video's naming fact comes from
  `quickTimeCreation` (`com.apple.quicktime.creationdate`, offset-carrying), **not** from
  `mvhd`, whose time is UTC and would be excluded. `mvhd` supplies only the duration that
  ENR-012's `mtime − duration` derivation currently obtains by downloading the file. An
  earlier draft of this plan conflated the two.
- **ENR-011** — **one clause replaced, not the row.** An earlier draft said "replaced,
  not amended", which is too broad: the row carries three separate rules and D1 reverses
  only the third.
  1. *Removable roots are claimed before fixed roots* — untouched by D1, still true.
  2. *MTP staging submits still/image items before videos, then capture date, then path* —
     survives D1 and still governs on-demand staging and import ordering. Deleting it
     would drop live behaviour, which is why the test that encodes it is re-aimed rather
     than deleted (see Tests).
  3. *"Every offered device seed is staged … never discarded, so a camera larger than that
     limit still stages and enriches in full"* — this is the clause D1 reverses, and only
     this clause is rewritten.
- **APP-018** — staging lifetime: release on settlement; quit deletes staged bytes in an
  unbounded window with a visible "clearing" state instead of a bounded
  `applicationWillTerminate` the OS kills partway through; off-main launch sweep over a
  per-instance staging directory.
- **ARC-047** — the session holds last known naming progress across a rebuild.
- **APP-029** — Preparing reports transfer progress and stays determinate.

**Design docs**

- `docs/design/import-bar.md` — state A's content (C1), determinacy across rebuilds (C2),
  and re-check the "momentary" premise once D1 lands (C3).
- `docs/architecture.md` — the new byte-source boundary and the fact that planning no
  longer depends on the materialization pipeline.

**Tests**

| Test | Change |
| --- | --- |
| `EnrichmentCoordinatorTests.eagerDeviceStagingDownloadsStillItemsBeforeVideos` (:66) | **Rewritten or deleted.** It encodes ENR-011's eager-staging ordering, which D1 removes |
| `EnrichmentCoordinatorTests.stageDeviceQueuesEverySeedPastTheOutstandingLimit` (:623) | **Deleted/replaced.** Asserts "every seed is staged, never discarded" — the exact behaviour D1 reverses |
| `EnrichmentCoordinatorTests.stageDeviceSkipsSeedAlreadyMaterializing` (:652) | Same family; re-aimed at on-demand staging |
| **New — B2 regression** | `readinessRetryNotBefore` has **no test coverage today**: the existing `retryLedger*` / `materializationSuccessClearsRetryLedgerEntry` tests cover the *failure ledger*, a different mechanism. That absence is why the zero-delay spin shipped. Assert that a pass routing rows to materialization and then finding nothing to do schedules **no** immediate wake, and that a stale past-deadline entry cannot produce a zero delay |
| `DeviceStagingRegistryTests.discardAllStagingRemovesEverythingAPreviousSessionLeft` (:76) | **Changes shape** for A2: quit renames to `-trash-<uuid>` (root gone, trash present); launch sweep removes trash |
| `DeviceStagingRegistryTests.stagedBytesSurviveDetachAndAreStillThereOnReattach` (:33) | **Unchanged** — detach still keeps bytes (APP-018); only release-on-settlement and quit mechanics change |
| `DeviceStagingRegistryTests` path tests (:11, :20) | Unaffected |
| `ImportPlanningNamingFactsTests` | A device row reaches `.terminal` from a ranged read with no staged bytes |
| `MediaEnricherTests` | Source-based reading; identical results file vs source |
| `DerivedVideoCaptureWallTests` | Duration from the container header (ENR-012) |
| `MediaImportExecutorTests` | Settlement releases exactly one staged file; failures retain theirs; the no-staging branch of `ensureImportBytes` is the normal path |
| `ImportBarPresentationTests` | Count survives `.building`; transfer-progress wording |
| `MaterializationCoordinatorTests`, `…ProviderBreakerTests` | Per-transport device cap (not a lowered global); deadline frees a slot and marks retryable |
| `CameraFileDateTests`, `CameraSourcePolicyTests` | `fileCreationDate` stays a cross-check, never the naming source |
| **New — differential oracle** | An earlier draft proposed comparing range-derived against full-file walls "for every file that *is* staged during import" — after D1 that is essentially none, so the oracle would never run. Aim it at the **destination** instead: every imported item is enriched from local bytes at its destination path anyway, so compare the device row's range-derived wall against the destination row's full-file wall. Free, continuous, runs in production rather than only in tests, and it covers the vendors that cannot be tested here. A disagreement is logged as a named defect (the file is already misnamed by then), and the same comparison runs over the fixture corpus as an assertion |
| `EnrichmentCoordinatorTests` **doubles** | `MediaEnricher` is constructed as a closure literal in **26 places across 5 files**. Any change to the `enrich` signature touches all of them; budget for it rather than discovering it |
| **New — D1b session cap** | Concurrent import of N camera entries issues at most one ICC operation at a time against one device session, with the other workers waiting rather than queueing inside ImageCaptureCore |
| **New — D1 capability gate** | A session whose first 12-byte probe short-reads, errors, returns empty data, or yields a family inconsistent with the extension is marked not-range-capable and stages instead; the decision is logged once per attach with its reason |

## Sequencing

1. **B2 then B1** — the retry-map spin first, since it *causes* the flood, then the
   state-change logging as hygiene. Nothing else can be diagnosed reliably while
   instrumentation is lossy, and this pair caused a false diagnosis today. Both are cheap
   and isolated.
2. **E1 + E2** — the device cap on the materialization path and the operation deadline.
   **Moved ahead of D1**, for two reasons the earlier ordering missed. The single-stream
   benchmark it was waiting on has already been run (37.2 / 39.9 MB/s, see E1), so nothing
   blocks it; and it is the fix that makes the *current* build three times faster, which
   should not wait behind the largest change in the plan.
3. **A2 + A3** — quit and launch staging correctness, with A2 carrying the per-instance
   live root that closes A4. Independent of D1, user-visible now.
4. **D1 + D1b together**, opening with the **end-to-end spike** described at the head of
   D1 — ranges over MTP, parsed, compared against known walls, before any production code
   moves. Then the range-driven reader, its capability gate, its dedicated-thread owner,
   the embedded-preview read, **and** the per-device-session cap. D1b is not a
   follow-up: shipping D1 without it moves the whole card's transfer onto an uncapped
   8-way path and is a net throughput regression. Carries the ADR, the ARC-057 amendment,
   ENR-011 clause 3, and ENR-012.
5. **A1** — release on settlement, which D1 makes the normal path.
6. **C2 + C1** — hold the Preparing count, then make Preparing report items-read and move
   byte/rate/estimate to Working. After D1, because D1 is what makes items-read the honest
   quantity.
7. **A5, A6, B3, B4, C3, D2** — hygiene and the spec re-check. C3 now expects a ~93 s
   Preparing rather than a momentary one, so re-check the spec against that, not against
   "brief".

**Depends on the package.** Step 4 cannot start until `MediaMetadata` ships R1, R2, R4,
R5, R6/R7, R10 and R11 and Otos moves its pin. Steps 1–3 and 5–7 are independent of it, so
the package work and everything before D1 proceed in parallel.

## Verified versus assumed

**Verified.** Every A, B, C, E item is read from current code and this session's evidence.
Verified during this review specifically:

- **APP-015 is not at risk from D1.** A camera item's ICC thumbnail is written at
  enumeration as a *provisional* file (`writeProvisionalThumbnail` →
  `ThumbnailStore.writeProvisionalJPEG`), so tiles paint from a real thumbnail before any
  staging. D1 removes nothing that is already painted, so no tile regresses to placeholder.
- **Camera rows do leave the enrichment claim index today.** Queried against the live
  catalog: of the 991 device rows, zero have a null `content_modified_at_unix`, null
  `enriched_source_mtime`, or null hash, and **zero** still satisfy the broad claim
  predicate. A concern that camera items might carry an epoch-zero mtime and be re-claimed
  forever was checked against the data and is unfounded. D1 must keep this true, which is
  what moving `.deviceMTP` to the metadata-only predicate achieves.
- **E1, D1's transport cost, and D1a option 3** are measured against the attached camera
  rather than extrapolated (see those sections).
D1's reader is validated against 991 real files with zero mismatches, and its family rules
are taken from the format specifications, not from sampling.

**Still assumed — nothing below has been verified, and each is called out where it is
relied upon.**

1. **Other vendors' containers.** Only Sony ARW/HIF/MP4 were available. Canon CR2/CR3,
   Nikon NEF, Fuji RAF, and phone MTP were not tested. Bounded by the terminal fallback:
   an unreadable index costs a transfer, never a wrong name.
2. **Whether ranged reads exist at all on other devices.** `GetPartialObject` is optional
   in MTP/PTP and absent from the mandatory command set, and libmtp#8 records a shipping
   device that advertises it and fails by timeout on ~1 file in 512. D1's capability gate
   exists for this and is itself untested against a non-supporting device, because none
   was available.
3. **ICC ranged-read behaviour under load.** `requestReadDataAtOffset` was verified for
   two files, sequentially, while the app held its own session. Throughput and latency for
   ~1,000 sequential ranged reads, and whether they contend with a concurrent download on
   the same serial `ICDeviceCommandQueue`, are unmeasured. This is the single biggest risk
   to the ~93 s per-card figure, which extrapolates from per-file measurements rather than
   from a measured full run.
4. **The package API.** `docs/plans/0101` is a brief; the implementation does not exist
   yet. Integration details will need revisiting against what actually ships.
5. **Vendor-specific preview layout.** D1a option 3 is measured for Sony ARW and HIF only;
   other RAW vendors place previews differently, and a vendor whose ICC thumbnail honours
   a 256 px request (which the SDK header says is possible — see D2) may not need the
   extra read at all.
6. **The dedicated-thread executor.** New mechanism, no precedent in this repo, and its
   interaction with enrichment cancellation and shutdown is unproven.

**Removed from this register because they are no longer assumptions.** Both were listed
here while the body of the plan already contained their measurements — exactly the drift
F4 names, aimed at a future reader of this file:

- *E1's throughput hypothesis.* Measured 2026-08-30 against the attached camera: 37.2 MB/s
  for a 32 MB ARW and 39.9 MB/s for a 320 MB MP4, single stream, against 0.9–8.5 MB/s
  observed under the shipped 16-way window. The single-stream benchmark this register kept
  asking for **has been run**; the sequencing above no longer budgets for it.
- *Embedded preview extraction.* Measured: HIF yields 256×170 from the 128 KB prefix the
  naming read already fetches, ARW yields 1616×1080 from one ~286 KB read at a declared
  IFD0 offset. Item 5 above carries what genuinely remains unknown.

**Resolved while reviewing.** Video offset is not an open question: the package already
surfaces `CaptureTimestamps.quickTimeCreation` from
`com.apple.quicktime.creationdate` / Sony NRTM, with an explicit
`localWithOffset` / `localFloating` / `absolute` precision, and
`VideoInfo.durationSeconds` from the movie header. Both were listed as unknowns before the
package was read.
