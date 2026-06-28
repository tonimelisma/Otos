# Otos Metadata & Thumbnail Enrichment — Implementation Plan

> TEMPORARY working document at repo root. Self-contained: an implementing agent
> should build the whole feature from this file alone, and an architect should be
> able to review correctness from it alone. When the work lands, its decisions move
> into ADR 0009 / spec 0022 / `docs/requirements.md` and this file is deleted. It is
> not a living doc; do not link to it from permanent docs.

## How to use this document
- §1–§3: context and the locked decisions.
- §4: the MediaMetadata library contract (a dependency you own; used **as-is**).
- §5–§11: the design, precise enough to implement.
- §12: the ordered, independently-landable increments.
- §13–§18: tests, instrumentation, edge cases, workflow.

---

## 1. Orientation: what exists today

Otos is a native macOS (SwiftUI, Swift 6 strict concurrency, single window)
Lightroom-style browser. The **filesystem is the single source of truth**; the catalog
and every overlay are a subordinate, rebuildable projection. Most media lives in
cloud-synced folders as **dataless placeholders** (APFS `SF_DATALESS`): filesystem
facts are free to read, reading bytes forces a download ("materialization").

### Product invariants this feature must honor
- Filesystem is truth; the catalog reconciles to it.
- Overlay (thumbnails, metadata) is held while the asset exists, purged in full only on
  **proven deletion** (absent from a completed scan of a reachable root), never on
  temporary absence. Identity is the path `(library_root_id, relative_path)` — no
  durable IDs, fingerprints, sidecars.
- Never fabricate facts (MED-002): unknown stays `nil`.
- Originals are read-only (MED-001); overlay lives only in Application Support.
- Single window; views are passive (no DB/scan/sort in `body`); no media/IO/DB/decode on
  the MainActor.
- Simplicity first; measure before optimizing (AGENTS.md, Pike's rules). Derive over
  maintain where the derivation is cheap (FND-042/043).

### Current architecture
| Owner | Isolation | Owns |
| --- | --- | --- |
| `CatalogStore` | actor | GRDB SQLite + the **fully-resident** in-memory catalog (`assetsByRootPath`) + scan lifecycle (`ActiveScan` lease) + FSEvents-driven rescans. Emits cheap `CatalogStoreChange`; serves `currentSnapshot()`. |
| `CatalogProjection` | actor | read model: 10 Hz coalesced sort/filter/scope → `CatalogWindowState`. |
| `CatalogWindowViewModel` | @MainActor | final `@Observable` UI state + intent lanes + task lifetimes. |
| AppKit grid bridge | @MainActor | `NSCollectionView` viewport/reuse/diffable-apply (knows the viewport; reports nothing upward today). |
| `FileMaterialization` | nonisolated | dataless detection + non-blocking download helpers (dead code today). |
| `MediaEligibility` | nonisolated | the scan only catalogs `.image`/`.movie` files — **the catalog is already media-only**. |
| `CatalogFilesystemWatcher` | service | FSEvents → debounced per-root **full rescans** through the existing scan pipeline (spec 0023). Leaves enrichment staleness to us. |

Key files: `Otos/Stores/CatalogStore.swift`, `Otos/Stores/CatalogStorePersistence.swift`,
`Otos/Models/CatalogModels.swift`, `Otos/Services/CatalogProjection.swift`,
`Otos/Services/CatalogScanner.swift`, `Otos/Services/FileMaterialization.swift`,
`Otos/Services/MediaEligibility.swift`, `Otos/Services/CatalogFilesystemWatcher.swift`,
`Otos/ViewModels/CatalogWindowViewModel.swift`, `Otos/Views/MediaAssetCollectionView.swift`.

Two load-bearing facts:
1. **The catalog is fully resident in RAM** — anything added to `MediaAsset` is resident × N.
2. **`CatalogMediaGridState` is deliberately cheap** (ADR 0007 / FND-043) — image bytes
   must never flow through the 10 Hz publication.

### Inlined prior decisions (so this doc stands alone)
- **Materialization contract (ADR 0008 §6, spec 0021):** byte-reading work must never
  *accidentally* materialize a dataless file by faulting on a read; check
  `FileMaterialization.status(of:)` immediately before any read. Beyond that gate,
  **deliberate, non-blocking, bounded background materialization is permitted**.
  Materialization status is transient and **never persisted**.
- **POC numbers (spec 0021), real 21,904-file OneDrive library, 87% dataless:**
  `status(of:)` ≈ **7 µs/file**; `ubiquitousItemDownloadingStatus` ≈ **317× slower**
  (never use in bulk); non-blocking `startDownloadingUbiquitousItem` **works on OneDrive**;
  a consumer app **cannot evict** another provider's files → downloaded bytes are
  **unreclaimable**.
- **In-memory scan cost:** FND-061 measured a 25k *sort* at ~140 ms; a linear
  `needsEnrichment` predicate scan (a couple of integer compares per asset) is far
  cheaper — single-digit ms even at 1M. So scanning the resident catalog to find work is a
  non-issue; the only per-file cost that matters is the `lstat` status check.
- **FSEvents (spec 0023):** runtime file changes → debounced rescans through the scan
  pipeline → in-memory facts refreshed → scan-completion notification fires.

---

## 2. Goal and scope
**Goal:** every cataloged image/video gets a thumbnail and parsed metadata, prioritizing
what the user is looking at, materializing the whole library in the background, never
blocking the UI, never stalling a worker on a download, never fabricating facts.

**In scope:** the enrichment data model, the scheduling algorithm, the modules, the
viewport channel, thumbnail files, and integration with `CatalogStore`/`Projection`/grid.

**Out of scope (named so they aren't built):** sort/filter by metadata and any grid
**reordering** (data + computed best-date only; no reorder); a film-strip/Image/Compare
view; editing/import; an in-memory thumbnail cache (none until measured); a metadata
inspector and exposure fields; Live Photos / paired-media-as-one-item; the max-zoom
"load original" path (a separate later increment — thumbnails serve up to their native
size, beyond which the grid loads originals).

---

## 3. Locked decisions (with rationale and the rejected alternative)
| # | Decision | Why | Rejected |
| --- | --- | --- | --- |
| D1 | **Eager full-library materialization** of every dataless **media** file. | Owner wants complete coverage; disk is the provider's concern. The catalog is already media-only (`MediaEligibility`), so non-media is never materialized. | On-demand-only: leaves most of the library un-enriched. |
| D2 | **Thumbnails are files on disk**; catalog stores the **path**; **256 px** long edge, HEIC; **QuickLook** generates them (accept its icon fallback). **No in-memory cache.** | 256 px is a true grid thumbnail; max-zoom loads originals (separate path). QuickLook is one API for image/RAW/video (and picks the video frame). ~15 GB per 1M items. | SQLite BLOBs (bloat resident catalog); ImageIO+AVFoundation (per-type code, manual video frame); larger sizes (e.g. 1536 px ≈ 150 GB/1M). |
| D3 | **The full `MediaMetadataResult` is persisted as a typed binary blob** (binary plist via `Codable`, **not** JSON) and is **never resident** — decoded on demand only when a future inspector opens *one* asset. The only enrichment data on `MediaAsset` / in the 10 Hz pipeline is the thumbnail path, a resolved capture date, and the stamps. | Holding the full nested result inline in `MediaAsset` would ride the Projection actor's per-tick `makeSnapshot` rebuild + deep `==` (≈5 GB/s of copying at 1M) **and** cost ~480 B/asset regardless of sparsity (inline `Int?`/`Double?`/`Date?` are 16 B each, nil or not) → ~480 MB at 1M. Nothing reads metadata across all assets (no filter/map/metadata-sort), so it need not be resident. The blob still holds every field. | Full metadata inline+resident (both the 10 Hz-copy and the nil-memory problems); a resident sparse dict / SQL columns (only if a cross-asset feature needs it — not in scope). |
| D4 | **One resolved capture date is stored** (`capture_date_unix`, computed at enrichment from the metadata priority chain); `bestCaptureDate` is computed at display as `capture_date ?? createdAt ?? contentModifiedAt`. | The grid needs a date without the full metadata resident; the fs fallback stays a computed display value (can't drift, upgrades as enrichment lands). The blob preserves all date roles, so a future policy change can re-resolve without re-reading files. | Computing best from full resident metadata (needs metadata resident — D3 forbids); a fully-stored final date (can't apply the fs fallback flexibly). |
| D5 | **Disjoint column ownership**: the scan writes only fact columns; enrichment writes only enrichment columns; the in-memory rescan **merges** (new facts + preserved enrichment) instead of replacing. | Satisfies "scan never overwrites metadata/thumbnail" within one record, no second table/map. | Separate table/map (a join + second structure). |
| D6 | **Staleness = `(size, mtime)` source signature**, stamped on any **definitive** outcome. mtime-only changes count. | mtime is the canonical "content changed" signal; size can stay constant across a real edit. Detected via the **always-firing scan-completion notification** (FND-062 only suppresses the per-batch projection wake, not the scan-lifecycle wake), so the coordinator re-evaluates after every rescan. | Size-only (misses same-size edits); a stored `is_stale` flag (drifts). |
| D7 | **Materialization status is checked live, never persisted**, at exactly one site (the enrichment pull, immediately before the read). | Transient (provider evicts/downloads anytime); the POC proved the check is ~7 µs. | Persist materialized/dataless (stale second source of truth). |
| D8 | **Two pools, fixed sizes: 4 enrichment slots + 4 materialization slots.** Neither is CPU-bound; enrichment is local-file read + QuickLook + parse, materialization is network. | Owner's call; a worker must never block on a multi-second download, so the two are separate concurrency budgets. | Core-count CPU pool (mis-models the I/O-bound work); one pool that gates+downloads+extracts (blocks workers on transfers). |
| D9 | **Cursorless scheduling.** Scan the resident catalog (via snapshot) for the next `needsEnrichment` asset; keep only the **`freshly` handoff** (download→enrichment) and one **`eagerMode` latch** as maintained state. | The in-memory scan is sub-ms (FND-061); `freshly` is the one thing that stops us `lstat`-ing 800k dataless files to find a just-downloaded one. No cursor, no partition set, no state machine. | A maintained `extractionPending`/`downloadPending` partition (scale machinery deferred until measured); a cursor (position gaps + own-write feedback thrash). |
| D10 | **Cancellation only at teardown.** | Eager-everything re-downloads anyway; thumbnails are durable; staleness re-queues — so per-unit cancel for scroll/staleness is pointless. | Per-item scroll/staleness cancellation (complexity, no benefit). |
| D11 | **Metadata + thumbnail are one scheduling unit but two reads** (library reads bytes for metadata; QuickLook reads bytes for the thumbnail), on the already-materialized file, gated once, stamped once. | The library is platform-neutral (no rendering); one materialization, two products. | One read / thumbnailing in the library (breaks platform-neutrality). |
| D12 | **Viewport-dataless downloads immediately; only *non-viewport* eager downloads wait for the latch.** | What the user is looking at must materialize on demand; the "materialized-first" rule governs the *background* fill. | "No downloads at all until the local backlog clears" (scrolling to cloud files would show nothing). |
| D13 | **The tile keys its async thumbnail load on `(thumbnailPath, sourceMTime)`** and reloads only when that changes. | Deterministic thumbnail filenames mean re-enrichment reuses the path; without the stamp in the key, an updated thumbnail wouldn't reload, and a 10 Hz sweep would redundantly reload unchanged ones. | Path-only key (misses re-enrichment) or reload-every-refresh (redundant decodes). |

### Invariant checklist (run down this before merge)
- [ ] No byte read without a `status(of:)` check immediately before it.
- [ ] Scan writes never touch enrichment columns/fields; enrichment writes never touch fact columns/fields; the rescan **merges**.
- [ ] No thumbnail bytes in `MediaAsset` / `CatalogMediaGridState` / the 10 Hz publication — only the path.
- [ ] The full metadata is never resident and never in the 10 Hz pipeline; only `thumbnailPath` + `captureDate` + stamps are on `MediaAsset`; `metadata_blob` is decoded on demand.
- [ ] Materialization status never written to SQLite.
- [ ] `needsEnrichment` depends only on `(size, mtime)` stamps vs facts, never on product presence.
- [ ] A definitive-but-empty outcome (unsupported / icon-fallback) still stamps → not retried until the file changes.
- [ ] Enrichment writes go through `CatalogStore` (single persistence owner).
- [ ] No work on the MainActor; the coordinator and pools are off-main; the latch-confirm sweep is hoisted off the coordinator actor.
- [ ] Thumbnail decode and date formatting run in the tile's off-main task (Main only assigns); decoded thumbnails are held only by on-screen + reuse-pool tiles (no app cache).
- [ ] An asset is in at most one in-flight set; `inFlightEnrich.insert` is on-actor in the same turn as the selection (no `await` between).
- [ ] Cancellation only on teardown.
- [ ] Thumbnail files deleted exactly when the asset row is purged on proven deletion.
- [ ] Viewport-dataless downloads regardless of the latch; eager non-viewport waits.

---

## 4. MediaMetadata library contract (dependency — used as-is)
Package `https://github.com/tonimelisma/MediaMetadata` (SPM, platform-neutral, macOS 13+),
added to the `Otos` target. **No library changes are requested.** Current API:

```swift
public enum MediaMetadataReader {
    public static func read(url: URL) -> MediaMetadataResult   // synchronous, byte-reading
}
public struct MediaMetadataResult: Equatable, Sendable {
    public let outcome: ReadOutcome            // .isDefinitive / .shouldRetry
    public let format: MediaFormat             // .family = image/video/...
    public let timestamps: CaptureTimestamps   // original, digitized, gps, quickTimeCreation, ... (each CaptureTime?)
    public let locations: CaptureLocations
    public let camera: Camera?                 // make/model/lens/serial/orientation/pixelW/H
    public let video: VideoInfo?               // durationSeconds/frameRate/codec
}
public enum ReadOutcome { var isDefinitive: Bool; var shouldRetry: Bool }   // shouldRetry == .readFailure
// CaptureTime { y/m/d/h/m/s, utcOffsetSeconds: Int?, instant: Date?, precision }
```
Notes:
- Call it **off the main actor on an already-materialized file**. It does all byte-parsing
  and returns typed values (no strings, no JSON).
- `outcome.isDefinitive`/`shouldRetry` drive Otos's stamp-vs-retry (D6).
- `timestamps` exposes every typed date role with `instant: Date?`; Otos picks the best at
  display (D4).
- If `MediaMetadataResult` is not `Codable`, add conformance in Otos via an extension (the
  types are simple value types); persistence (D3) needs it.

---

## 5. Data model
### 5.1 SQLite (`v3` migration in `CatalogStorePersistence.swift`), added to `media_asset`, written **only** by enrichment:
```
enriched_source_size   INTEGER   -- byte_size the enrichment was made from
enriched_source_mtime  INTEGER   -- content mtime (unix SECONDS) it was made from
thumbnail_path         TEXT      -- relative path under the thumbnails dir, NULL if none
capture_date_unix      REAL      -- resolved metadata capture date (priority chain), NULL if none
metadata_blob          BLOB      -- binary-plist of the full MediaMetadataResult, NULL until parsed
```
The scan upsert (`upsertScannedFile`) keeps listing only fact columns. `fetchCatalog` reads
the cheap columns (stamps, `thumbnail_path`, `capture_date_unix`) into the resident
`MediaAsset` — it does **not** read or decode `metadata_blob` (no 1M-blob decode at launch).
The blob is loaded and decoded only on demand (a future inspector, one asset at a time).

**Blob format is versioned DB-wide, never per row.** The `metadata_blob` (`AssetMetadata`
`Codable`) format carries a single version owned by the GRDB migrator. When the `AssetMetadata`
shape changes, a new migration bumps that version and **invalidates all blobs in one statement**
— `UPDATE media_asset SET metadata_blob = NULL, enriched_source_size = NULL,
enriched_source_mtime = NULL` — so every asset re-enriches into the new format. No per-row
version byte, no decode-time version branching; an undecodable blob can't occur because a format
change clears them all up front.

### 5.2 In-memory (`CatalogModels.swift`)
`MediaAsset` gains only the cheap, grid-facing enrichment fields — **not** the full
metadata. The full result is the on-demand blob (§5.1).

```swift
nonisolated struct MediaAsset: Identifiable, Hashable {
    // existing facts: libraryRootPath, relativePath, name, contentTypeIdentifier,
    //   byteSize, createdAt, contentModifiedAt, sortKey
    let thumbnailPath: String?            // relative to the thumbnails dir
    let captureDate: Date?                // resolved metadata capture date, NULL if none
    let enrichedSourceSize: Int64?
    let enrichedSourceMTimeSeconds: Int?
}
```
A separate Otos-owned `AssetMetadata` (`Codable, Sendable`) mirrors the full library result;
it is the **blob's shape**, written at enrichment and decoded on demand — it is never a field
on `MediaAsset` and never resident across the catalog. `MediaEnricher` maps
`MediaMetadataResult → AssetMetadata` and resolves `captureDate` from its timestamps.

### 5.3 Derived predicate and computed best-date
```swift
extension MediaAsset {
    var needsEnrichment: Bool {           // depends only on the (size, mtime) signature
        guard let s = enrichedSourceSize, let m = enrichedSourceMTimeSeconds else { return true }
        return s != (byteSize ?? -1) || m != Self.seconds(contentModifiedAt)
    }
    var bestCaptureDate: Date? {          // truest available, never fabricated (MED-002)
        captureDate ?? createdAt ?? contentModifiedAt
    }
    static func seconds(_ d: Date?) -> Int { d.map { Int($0.timeIntervalSince1970.rounded(.down)) } ?? -1 }
}
```

### 5.4 Thumbnail files
- Dir: `Application Support/<bundleID>/Thumbnails/`.
- Name: deterministic from identity (a hash of `"\(library_root_id)\u{0}\(relative_path)"`)
  + `.heic`, stored in `thumbnail_path`. It is an opaque **storage key**, not asset identity.
- 256 px long edge, HEIC, from QuickLook's `CGImage` (accept icon fallback).
- `ThumbnailStore.write` is **atomic** (write a temp file, then `rename` over the path), so a
  tile can never read a half-written file during a re-enrichment overwrite.
- Overwritten in place on re-enrichment; **deleted when the row is purged** on proven deletion.

---

## 6. Scheduling algorithm (cursorless)
### 6.1 The one rule
**Materialization status is checked exactly once: when an enrichment worker pulls an id,
immediately before reading bytes.** That check is both the router (materialized → enrich;
dataless → download) and the safety gate (never fault on a read).

### 6.2 State (all transient, in the coordinator, rebuilt each launch)
- `latestSnapshot` — refreshed from `store.currentSnapshot()` on each coalesced catalog
  change (the source for the cursorless scan; the resident-catalog truth).
- `viewport: [MediaAssetID]` — newest visible+prefetch ids (recency order).
- `freshly: [MediaAssetID]` — **LIFO**, ids *our* download pool just materialized.
- `inFlightEnrich`, `inFlightDownload: Set<MediaAssetID>` — caps + de-dupe.
- `pendingApply: [EnrichmentOutcome]` (+ its id set) — completed-but-unwritten results awaiting
  the batched flush (§6.5); dispatch excludes its ids so they aren't re-enriched.
- `eagerMode: Bool` — the latch.
Persisted (Store): the `(size, mtime)` stamps → `needsEnrichment`. Nothing else.

### 6.3 Finding work (the cursorless scan)
```
nextEnrichmentUnit():                         // returns an id to enrich, or nil
  1. a viewport id, needsEnrichment, not in-flight, that status-checks .materialized  (newest-first)
  2. freshly.pop() that is still needsEnrichment & not in-flight                       (LIFO)
  3. scan latestSnapshot for the first needsEnrichment, not-in-flight, .materialized asset
  -> nil if none (a full scan finding none flips eagerMode = true)

nextDownloadUnit():                           // returns an id to materialize, or nil
  1. a viewport id, needsEnrichment, not in-flight, .dataless                          (LIFO) — ALWAYS (D12)
  2. if eagerMode: scan latestSnapshot for the first needsEnrichment, not-in-flight, .dataless asset
  -> else nil
```
Cost & where `status` runs: the scans touch the cheap `needsEnrichment` predicate freely; the
`status` check (`lstat`, ~7 µs) runs **on the coordinator actor** for each candidate as it's
examined — bounded per dispatch (it stops at the first materialized one; in the initial phase
those are common, so ~a handful of checks = tens of µs). The **one** expensive case is the
**latch-confirm**: the scan that must examine the whole backlog to prove "no materialized left"
before flipping `eagerMode`. That single full sweep is **hoisted off the actor** — a one-shot
classification `Task` does the `lstat` sweep over the snapshot and reports the result back to set
`eagerMode`, so the coordinator never blocks on it. After the latch, enrichment work arrives via
`freshly` (no scanning) and `nextDownloadUnit` finds a dataless in ~one check (the majority).

### 6.4 The two pools (one supervising task, `withDiscardingTaskGroup`)
```
// EnrichmentCoordinator owns ONE supervising task (started by the ViewModel). weak self.
for await _ in signals {                       // coalesced AsyncStream<Void>, bufferingNewest(1)
    while inFlightEnrich.count < 4, let id = nextEnrichmentUnit() {
        inFlightEnrich.insert(id)
        group.addTask { let o = await MediaEnricher.enrich(id, url(id), facts(id)); await self.finishEnrich(id, o) }
    }
    while inFlightDownload.count < 4, let id = nextDownloadUnit() {
        inFlightDownload.insert(id)
        group.addTask { let ok = await FileMaterialization.materialize(url(id)); await self.finishDownload(id, ok) }
    }
}
```
`signal()` (yield to the stream) is called on: a catalog-change notification (refresh
`latestSnapshot` first), a viewport intent, and every `finishEnrich`/`finishDownload`.
`finishDownload` pushes the id to `freshly` on success, then signals (so enrichment picks
it up). `MediaEnricher.enrich` and `materialize` run **off** the actor (inside the task);
only `finish*` and `dispatch` run on the actor.

**No two workers ever touch the same asset:** `inFlightEnrich.insert(id)` runs on the actor in
the **same turn** as the `nextEnrichmentUnit()` that selected it — there is no `await` between
select and insert — so actor isolation serializes dispatch and two passes can't pick the same
id. Both `next*Unit` functions exclude ids in **either** in-flight set, so an asset is in at most
one pool at a time; `finishEnrich`/`finishDownload` remove it.

### 6.5 Outcome and batched apply (the fixpoint)
```swift
enum EnrichmentOutcome: Sendable {
    case complete(metadata: AssetMetadata, captureDate: Date?, thumbnailPath: String?,
                  sourceSize: Int64, sourceMTime: Int)   // definitive → stamp + store
    case transient                                       // readFailure/threw → re-queue
    case notMaterialized                                 // went dataless → route to download
}
```
**Writes are batched (mirrors `recordScannedBatch`), not per asset.** A per-asset SQLite
transaction × 1M assets would crawl, and a notification per asset would re-sort the whole catalog
in Projection per completion. So `finishEnrich`:
1. For `.complete`: append the result to a `pendingApply` buffer and remove the id from
   `inFlightEnrich` (the slot frees). The id stays in `pendingApply`, which dispatch **also
   excludes**, so a buffered-but-unwritten asset is never re-dispatched.
2. For `.transient` / `.notMaterialized`: write nothing (asset stays `needsEnrichment`); for
   `.notMaterialized` route to download.

A **flush** (when `pendingApply` reaches N, e.g. 64, or every ~100 ms) calls
`await store.applyEnrichmentBatch(results)`, which in **one transaction**: per row revalidates the
asset exists (lease) and writes `metadata_blob` + `capture_date_unix` + `thumbnail_path` + the
source `(size,mtime)` stamp; merges only the **cheap** fields into the in-memory `MediaAsset`
(facts preserved; blob not resident); then **one** `notifyCatalogChanged()` for the whole batch.
Ids leave `pendingApply` after the batch commits.

**Fixpoint:** after a definitive write the asset's stamp matches its facts →
`needsEnrichment` is false → no scan re-selects it. If facts changed mid-enrichment the
stamp won't match → it re-queues (self-healing, no cancel).

### 6.6 Events
- **catalog change** (scan/FSEvents-rescan completion): mark the snapshot dirty and `signal()`.
  The coordinator **coalesces** the `currentSnapshot()` refresh to its own cadence (~1 Hz, plus
  on worker starvation) — **not per notification** — because `makeSnapshot` is O(N) and
  enrichment's own batched writes would otherwise trigger a rebuild every flush. This is also how
  mtime-only staleness is caught (the scan-completion notification always fires, D6); a ~1 s lag
  to re-scan for staleness is fine.
- **viewport intent** (newest-value): replace `viewport`; `signal()` (does not force a snapshot
  refresh — viewport ids resolve against the current snapshot).
- A removed asset → drop from `viewport`/`freshly`/guards; `ThumbnailStore.delete` its path.

> **Projection load during a sweep (measure-gate):** enrichment's batched notifications make
> Projection republish ≤10 Hz, and it re-sorts the whole catalog each time (FND-043). But
> enrichment changes `thumbnailPath`/`captureDate`, **never `sortKey`**, so the order is
> unchanged and the re-sort is wasted work. Acceptable off-main at the tested scale; if a cold
> sweep pegs the Projection actor at 1M, the measured fix is order-reuse when the sort-key set is
> unchanged (reversing FND-043 for that case) — deferred until measured (§15).

---

## 7. Modules
| Module | Isolation | Owns | In | Out |
| --- | --- | --- | --- | --- |
| `CatalogStore` (extend) | actor | schema + `applyEnrichmentBatch` (one txn) + rescan **merge** + thumbnail delete on purge + on-demand `metadata(for:)` blob decode | enrichment batches; scan | snapshots, notifications |
| `MediaAsset` (extend) | nonisolated value | the cheap resident fields (`thumbnailPath`, `captureDate`, stamps) + `needsEnrichment` + `bestCaptureDate` | — | — |
| `AssetMetadata` (new) | nonisolated value | the blob's `Codable` shape (full result), **never resident** | mapped from library result | encoded to/decoded from `metadata_blob` |
| `EnrichmentCoordinator` (new) | actor | the cursorless scheduler + the two pools + the transient state + the batched-apply buffer | Store changes/snapshots, viewport intent | calls `MediaEnricher`, `FileMaterialization`, `store.applyEnrichmentBatch` |
| `MediaEnricher` (new) | nonisolated | one unit (async): `MediaMetadataReader.read` + QuickLook thumbnail → `EnrichmentOutcome` | id, url, facts | outcome |
| `ThumbnailStore` (new) | nonisolated | thumbnails dir + naming + write/load/delete | id, CGImage / path | path / NSImage / void |
| `FileMaterialization` (exists) | nonisolated | detection + download | url | status / outcome |
| `CatalogWindowViewModel` (extend) | @MainActor | the `viewport` intent lane; starts the coordinator | grid prefetch | forwards `updateViewport` |
| grid bridge + tile (extend) | @MainActor | report visible ids; async-load thumbnail keyed `(path, mtime)`; show filename + best date | grid state | viewport intent; rendered tile |
| `CatalogProjection` (trivial) | actor | already carries `MediaAsset`; now also the cheap `thumbnailPath`/metadata | — | window state |

Selected signatures:
```swift
actor EnrichmentCoordinator {
    init(store: CatalogStore, enricher: MediaEnricher = .live)   // 4 enrich + 4 download slots
    func start(); func updateViewport(_ ids: [MediaAssetID])
}
struct MediaEnricher: Sendable {            // injectable (like CatalogScanner)
    var enrich: @Sendable (_ id: MediaAssetID, _ url: URL, _ facts: ScannedFacts) async -> EnrichmentOutcome
    static let live: MediaEnricher          // MediaMetadataReader + QLThumbnailGenerator + ThumbnailStore
}                                           // async because QLThumbnailGenerator is async
enum ThumbnailStore {
    static func write(_ image: CGImage, for id: MediaAssetID) throws -> String   // atomic (temp + rename); returns relative path
    static func load(relativePath: String) -> NSImage?                            // off-main
    static func delete(relativePath: String)
}
```
`MediaEnricher.live`: `status` is already checked by the coordinator; it calls
`MediaMetadataReader.read(url:)` (→ map to `AssetMetadata`), then `QLThumbnailGenerator`
requesting a 256 px `.thumbnail` representation (accept fallback), `ThumbnailStore.write`s
the `CGImage`, and returns `.complete` on a definitive metadata outcome (else `.transient`),
or `.notMaterialized` if a read reports the file went dataless.

---

## 8. Concurrency & ownership
- **Pools:** the coordinator owns **one supervising `Task`** (started by the ViewModel)
  running a `withDiscardingTaskGroup`; `dispatch()` tops both pools up to their caps (4/4)
  on each `signal()`. A coalesced `AsyncStream<Void>` (bufferingNewest(1)) is the wake
  channel — no continuation bookkeeping, no lost wakeups.
- **Weak self:** the supervising task captures the coordinator **weakly** across the loop
  (FND-051), so it can deinit and cancel.
- **Off-main:** the coordinator is an actor (not Main); `MediaEnricher`/`ThumbnailStore`
  are nonisolated and run inside the child tasks; only the final `state`/image assignment is
  on Main.
- **Lease revalidation:** `applyEnrichmentBatch` re-reads each row's current facts after `await`s
  and stamps the source `(size, mtime)` that row's enrichment started from (mirrors `ActiveScan`).
- **Cancellation:** only teardown — the ViewModel cancels the supervising task → the group
  cancels children. No per-unit cancel (D10).

---

## 9. Data flow
```
scan/FSEvents ─▶ Store notifies ─▶ Coordinator refreshes snapshot ─▶ dispatch()
  enrich slot: status .materialized ─▶ MediaEnricher (read+QuickLook) ─▶ buffer ─▶ store.applyEnrichmentBatch
                                                              (merge facts+enrichment, stamp, notify)
  enrich slot: status .dataless    ─▶ downloadHigh (viewport) | eager (after latch)
  download slot: materialize() ─▶ freshly.push ─▶ signal ─▶ enrich slot extracts
Projection republishes (thumbnailPath/metadata now set; cheap) ─▶ grid refreshVisible
  ─▶ tile: if (path, mtime) changed, ThumbnailStore.load off-main ─▶ image + best-date on Main
asset removed (proven deletion) ─▶ reconciliation deletes row ─▶ ThumbnailStore.delete
```
Only the cheap fields (`thumbnailPath`, `captureDate`, stamps) flow through the 10 Hz
pipeline — **no bytes and no full metadata**. The `metadata_blob` is never resident; it is
decoded only on demand for a future single-asset inspector.

---

## 10. Integration touch list
- `CatalogStorePersistence.swift`: `v3` migration (§5.1); `fetchCatalog` reads the cheap
  columns (stamps, `thumbnail_path`, `capture_date_unix`) — **not** `metadata_blob`; an
  `updateEnrichment(...)` writer touching only enrichment columns; an on-demand
  `metadataBlob(forRowID:)` reader for the future inspector. Scan upsert **unchanged**.
- `CatalogStore.swift`: `applyEnrichmentBatch(...)` (one transaction, one notification);
  `applyScannedBatchToMemory` **merge** (new facts + preserved enrichment); `reconcileMissingAssets`
  → `ThumbnailStore.delete` per purged asset. (Scan-start/end notifications already fire — the
  coordinator's staleness wake; no change needed there.)
- `CatalogModels.swift`: add `AssetMetadata` (Codable/Sendable, mirrors the library result —
  the blob shape, not a `MediaAsset` field) + the cheap `MediaAsset` fields (`thumbnailPath`,
  `captureDate`, stamps) + `needsEnrichment` + `bestCaptureDate`; extend `StoredAsset` with the
  cheap columns only.
- `CatalogProjection.swift`: no logic change (confirm equality still suppresses no-ops).
- `CatalogWindowViewModel.swift`: `viewportChanged(_:)` newest-value intent →
  `EnrichmentCoordinator.updateViewport`; start the coordinator in `start()`.
- `MediaAssetCollectionView.swift`: adopt `NSCollectionViewPrefetching` + the viewport-coalesce
  (§11). The tile's `configure` starts **one off-main task** that, when `(thumbnailPath, mtime)`
  changed since its last load, both **decodes** the 256 px thumbnail (`ThumbnailStore.load`) and
  **formats** `bestCaptureDate` to a string (a reused `Date.FormatStyle`/`DateFormatter`), then
  hops to Main **once** to assign `{image, dateString}` + filename. `prepareForReuse` **cancels**
  the in-flight task and clears the image. So **the MainActor never decodes or formats** — it
  only assigns; and decoded thumbnails live only in visible + reuse-pool tiles (§11 memory note).
- New: `Otos/Services/EnrichmentCoordinator.swift`, `Otos/Services/MediaEnricher.swift`,
  `Otos/Services/ThumbnailStore.swift`.
- `Otos.xcodeproj`: add the `MediaMetadata` SPM dependency to the `Otos` target.

---

## 11. Viewport channel (views stay passive)
Step by step:
1. The grid controller (MainActor) maintains a `viewportSet = visibleItems ∪ prefetchRing`:
   `NSCollectionViewPrefetching` `prefetchItemsAt:`/`cancelPrefetchingForItemsAt:` maintain the
   ring (AppKit's look-ahead), and `contentView` bounds-change tracks visibility.
2. On change it marks dirty; a **~10 Hz coalescing gate** (the app's existing cadence) maps the
   set's index paths → `MediaAssetID` (O(1) each via the diffable data source, ~60 items) and
   calls `viewModel.viewportChanged(ids)` — an intent like `selectSidebar`; the view derives and
   schedules nothing (FND-033/034).
3. The ViewModel yields to a newest-value `AsyncStream<[MediaAssetID]>` (`bufferingNewest(1)`); a
   forwarding task calls `await coordinator.updateViewport(ids)`, which replaces `viewport` and
   `signal()`s. The next dispatch consults `viewport` first (tiers 1).

**No debounce / no settle-wait.** During fast scroll the gate fires ≤10×/s and the newest-value
stream drops all but the latest, so the coordinator never works a backlog of stale viewports.
We deliberately don't wait for scrolling to *stop* (that would delay prioritizing exactly where
the user lands), and prioritizing a fly-by item is harmless (eager downloads/enriches it anyway;
the thumbnail is durable). The 10 Hz cadence and ring size are tunable knobs, not load-bearing.

**Thumbnail memory:** decoded thumbnails are held only by **on-screen + reuse-pool tiles** — no
app-level cache (D2). A 256 px decode ≈ ~175 KB; ~60 visible + ~20 reuse ≈ **~14 MB total, flat,
independent of library size**. A tile releases its image on `prepareForReuse`. Scrolling back
re-reads+re-decodes off-main (~ms; OS page cache keeps bytes hot). A measured scroll-jank from
re-decode is the only thing that would justify adding a small LRU later (§15 gate).

---

## 12. Implementation sequence (each lands & verifies on its own)
1. **Data model + store write (no scheduling).** `v3` migration; `AssetMetadata` +
   `MediaAsset` fields + `needsEnrichment` + `bestCaptureDate`; `applyEnrichmentBatch`; rescan
   **merge**; thumbnail-delete-on-purge. Tests: a rescan preserves enrichment columns/fields;
   `needsEnrichment` flips on size **and** mtime change and back on stamp; `bestCaptureDate`
   fallback order; purge deletes the thumbnail file.
2. **Enricher + thumbnails (no scheduling).** Add the `MediaMetadata` dependency;
   `ThumbnailStore`; `MediaEnricher.live` (map result → `AssetMetadata`; QuickLook 256 px).
   Tests on committed fixtures: enrich → expected resolved `captureDate` + a round-trippable
   `metadata_blob` (decode equals encode) + a 256 px HEIC written; `readFailure` → `.transient`;
   a non-renderable file → icon fallback accepted.
3. **Coordinator + pools (fake enricher).** `EnrichmentCoordinator` per §6 with injected
   fakes. Tests: viewport-first; `freshly` LIFO; the latch (materialized-first, viewport-
   dataless exempt — D12); status-check routing; the fixpoint (no re-dispatch after
   definitive); mtime-only staleness re-enriches after a rescan. Then wire the real enricher
   + `FileMaterialization` + `store.applyEnrichmentBatch`.
4. **Viewport channel + tile.** Prefetch → intent → `updateViewport`; tile async load keyed
   on `(path, mtime)`; tile shows filename + best date. Tests: viewport reprioritizes; tile
   shows the thumbnail when the path is set and refreshes on re-enrichment; passive-view
   hygiene still passes.
5. **Purge + instrumentation + docs.** Instrumentation (§14); perf evidence (§15); move
   ENR-### into `docs/requirements.md` (Current), finalize ADR 0009 + spec 0022, update the
   index + onboarding, stale-doc + comment audits, DoD, delete this file.

---

## 13. Tests & acceptance
- Narrowest-boundary unit tests per increment, using the `.inMemory` `CatalogStore` and an
  injectable `MediaEnricher`.
- **The coordinator is built to be deterministically testable:** inject the `MediaEnricher`,
  materialization, and status-check, and drive the dispatch loop by an injected signal/clock — so
  priority, the latch, the fixpoint, and the batch flush are asserted without timing races.
- Acceptance examples per requirement (e.g. D6: "a rescan that changes only mtime makes
  `needsEnrichment` true and the asset is re-enriched after the scan-completion wake").
- POC-validated-only (no CI test): the live materialization download (spec 0016/0021
  precedent).
- `script/verify.sh` green gates every increment.

---

## 14. Instrumentation
Categories: `Thumbnails`, `Metadata`, `MediaIO`, `FileAccess`, `Performance`. Batch/boundary
scope, never per-file JSONL, never media payloads:
- Coordinator: signpost spans per dispatch; counters for enriched / materialized /
  transient / latch transition / in-flight depth.
- `MediaEnricher`: signpost per unit with metadata read ms + thumbnail ms; log
  unsupported/failed with the path (paths are allowed) but no metadata payload.
- Materialization: count requested/completed/timed-out + bytes pulled (disk-growth evidence).
- Tile load: signpost only.

## 15. Performance budgets & evidence
- MainActor under 100 ms; the tile thumbnail load is off-main, image-set on Main.
- Increment 5: `script/profile.sh "Animation Hitches" 10s` while scrolling during a sweep;
  `"Time Profiler" 10s` during a cold sweep; `script/logs.sh Thumbnails`/`Metadata` summaries;
  record catalog resident memory and the Projection per-tick snapshot/`==` cost at the test
  library size (the full metadata is **not** resident under D3, so the per-tick cost grows only
  by `captureDate` + `thumbnailPath`).
- Measure-before-optimize gates: no thumbnail cache until a scroll profile demands it; no
  maintained partition set until the cursorless scan is proven too costly at a real large
  library.

## 16. Edge cases & failure modes
- File evicted between the status check and the read → it faults: tiny window; residual is one
  accidental materialization (acceptable; we eager-materialize anyway).
- Facts change mid-enrichment → stamp mismatch → re-queue (no cancel).
- `materialize` times out / provider ignores it → not pushed to `freshly`; stays
  `needsEnrichment`, retried next eager pass.
- QuickLook returns a generic icon → accepted and stored (a tile is better than nothing).
- Asset removed mid-enrichment → `applyEnrichmentBatch`'s per-row revalidation finds it gone,
  skips that row; reconciliation deletes the thumbnail file.
- Relaunch → transient state rebuilt from the persisted `needsEnrichment` set; a
  downloaded-but-unenriched file is materialized + needs-enrichment → enriched, not
  re-downloaded (`materialize` short-circuits).
- Unavailable root → status `.unknown` → the unit drops; re-enriched after the root returns
  and rescans. (Filter candidates to available roots to avoid churn.)
- Selective-sync excluded subtree (ADR 0008 caveat) → unchanged by this feature.

## 17. Glossary
materialize/dataless · enrichment (metadata + thumbnail) · stamp (`(size, mtime)` →
`needsEnrichment`) · `freshly` (our just-downloaded ids, LIFO) · `eagerMode` (latch). New
types: `AssetMetadata`, `EnrichmentOutcome`, `EnrichmentCoordinator`, `MediaEnricher`,
`ThumbnailStore`. Library: `MediaMetadataReader`, `MediaMetadataResult`.

## 18. Workflow obligations when this lands
- **Re-amend ADR 0008 §6 + the AGENTS.md cloud-materialization baseline:** they currently say
  materialization must stay *bounded* and "must not eagerly download a whole library," which D1
  (eager full-library) reverses. Update them to permit eager full-library materialization with the
  unreclaimable disk growth as an accepted cost. (The plan otherwise violates a current ADR.)
- Move ENR-### into `docs/requirements.md` (Current) with acceptance evidence.
- Finalize ADR 0009 to match this plan (thumbnails-as-files-by-path **256 px QuickLook**;
  metadata as a **binary blob, on-demand (not resident), not typed columns**, with only a
  resolved capture date + thumbnail path on `MediaAsset`; `(size, mtime)` staleness;
  computed `bestCaptureDate`); ADR 0009 as currently written says JSON / typed columns / mtime
  vs size — rewrite it.
- Complete spec 0022's Open Decisions with §6–§9; consider a short concurrency ADR for the
  coordinator/pool ownership.
- Repo-wide stale-document audit + code-comment audit; update `docs/onboarding.md` and
  `docs/index.md`; delete this temporary file.
- Per-increment DoD via `script/dod-report.sh`; PRs on `codex/...` branches.
```
