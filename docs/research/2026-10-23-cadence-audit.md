# Cadence audit: which rate limits stand on a measurement

Date: 2026-10-23. Plan 0106, increment 4. A rate limit (a cadence or a debounce)
states that work is not worth doing more often. That is a performance claim, so it
either stands on a recorded measurement or the work is coalesced through its owner
(ADR 0032) instead. This pass took each of the six named in the plan in turn.

## Method

A temporary Swift Testing harness (removed after the run; its code is below) ran in
the unhosted `OtosTests` bundle on the development Mac (Xcode 27.1, Debug build) with
an on-disk catalog in a temporary directory:

- **Scan flush.** A tree of 20,000 one-byte `.jpg` files in 100 folders, added as a
  library to a fresh store at four scan cadences, two runs each, timed from
  `addLibrary` until no root reports scanning and `isFilesystemQuiescent` holds.
- **Enrichment apply.** The same tree, scanned once; then `applyEnrichmentBatch` with
  synthetic results at batch sizes 1, 8, 32, 128 and 512, ten samples each.
- **Copy progress.** `copyfile(COPYFILE_ALL)` of one 512 MB file with the status
  callback Otos installs, counting `COPYFILE_PROGRESS` callbacks.

Scan flush (20,000 files, two runs each; a first pass whose completion check queried
every asset every 20 ms ranked the cadences the same way):

| Cadence | Run 1 | Run 2 |
| --- | --- | --- |
| every file (0) | 64.5 s | 77.0 s |
| 10 ms | 13.3 s | 14.3 s |
| 100 ms | 11.9 s | 11.0 s |
| 1 s | 8.3 s | 9.2 s |


Enrichment apply (median of ten, then per row):

| Batch | Median | p90 | Per row |
| --- | --- | --- | --- |
| 1 | 0.37 ms | 2.23 ms | 0.375 ms |
| 8 | 0.99 ms | 1.54 ms | 0.124 ms |
| 32 | 3.38 ms | 4.52 ms | 0.106 ms |
| 128 | 13.68 ms | 15.47 ms | 0.107 ms |
| 512 | 46.45 ms | 54.33 ms | 0.091 ms |

Copy progress: 512 callbacks for 512 MB in 278 ms — one per megabyte, about 1,840 a
second for one worker on the internal SSD. The executor runs eight copy workers.

## Decisions

| Rate limit | Decision | Why |
| --- | --- | --- |
| Projection publication, 1 s | Stays; cites `grid-reorder-cadence-and-appkit-diffable-apply.md` | Each reordering publication costs the MainActor ~25 ms (trickle) to ~200 ms (reloadData-class) at 23k items. User intents never wait for it. |
| Filesystem-event debounce, 1 s | Removed: one pass per root acts on events as they arrive; events that land while it awaits join the next pass | No measurement stood behind it, and the reconcile it delayed already coalesces dirt that arrives mid-pass. A trailing-edge debounce with no maximum wait also deferred a long copy's updates until the copy stopped. |
| Scan flush, 1 s | Stays; cites this document | Flushing every file made a 20,000-file scan seven to eight times slower, and 100 ms still cost ~25% over 1 s: each flush is a write transaction and a catalog-change notification. |
| Enrichment apply flush, 1 s | Removed: the one apply in flight takes every result that completed meanwhile | A write's fixed cost is ~0.3 ms over ~0.1 ms a row, so a timer saved under a millisecond a second while delaying every visible thumbnail by up to one. |
| Import progress emit, 100 ms | Stays; cites this document | `copyfile` reports once a megabyte, ~1,840 times a second per worker. Each delivered sample is a coordinator pass and a MainActor presentation apply; the samples are already newest-wins downstream, and the limit keeps the producers from waking that chain thousands of times a second. |
| Grid scroll coalescing, 16 ms window / 100 ms maximum wait | Stays; cites `2026-09-04-grid-day-header-pinning-and-scroll-edge-effect.md` | Measured: 3,594 scroll-bounds ticks against 221 flushes when the trailing edge stood alone. |

The grid's 250 ms scroll-quiet window is not a rate limit but a stand-in for "the user
stopped scrolling". AppKit reports that for gesture and scroller tracking
(`NSScrollViewWillStartLiveScrollNotification` / `DidEndLiveScroll`), but its header
states that legacy mice send no such pair. With nothing to report the end for those,
the window stays as a product decision, documented in `MediaGridAnimation`.

The filesystem-event change also routes FSEvents through one ordered stream with one
consumer, replacing a `Task {}` per event (ADR 0032, rule 5).

## Harness

```swift
import Foundation
@testable import OtosKit
import Testing

/// Temporary measurement harness for plan 0106 increment 4. Not committed.
@Suite(.serialized)
struct CadenceMeasurementHarness {
    static let out = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "cadence-measure.txt")

    static func record(_ line: String) {
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: out) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: out)
        }
    }

    static func makeTree(files: Int, folders: Int) throws -> URL {
        let root = try makeCatalogStoreTemporaryDirectory().appending(path: "Lib", directoryHint: .isDirectory)
        for folder in 0 ..< folders {
            let dir = root.appending(path: String(format: "%04d", folder), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for index in 0 ..< files / folders {
                try Data([0xFF]).write(to: dir.appending(path: "IMG_\(index).jpg"))
            }
        }
        return root
    }

    @Test func scanFlushCadence() async throws {
        let tree = try Self.makeTree(files: 20000, folders: 100)
        for cadence in [Duration.zero, .milliseconds(10), .milliseconds(100), .seconds(1)] {
            for run in 0 ..< 2 {
                let dbDir = try makeCatalogStoreTemporaryDirectory()
                let store = CatalogStore(
                    location: .databaseFile(dbDir.appending(path: "catalog.sqlite")),
                    scanCadence: cadence
                )
                try await store.start(scansSavedLibraries: false)
                let started = ContinuousClock.now
                try await store.addLibrary(url: tree)
                try await waitUntil(every: .milliseconds(20)) {
                    let roots = await store.currentLibraries()
                    let quiescent = await store.isFilesystemQuiescent
                    return !roots.isEmpty && !roots.contains { $0.isScanning } && quiescent
                }
                let elapsed = started.duration(to: .now)
                let count = try await catalogStoreTestState(store).assets.count
                Self.record("scan cadence=\(cadence) run=\(run) files=\(count) elapsedMs=\(Int(elapsed / .milliseconds(1)))")
            }
        }
    }

    @Test func enrichmentApplyBatchCost() async throws {
        let tree = try Self.makeTree(files: 20000, folders: 100)
        let dbDir = try makeCatalogStoreTemporaryDirectory()
        let store = CatalogStore(
            location: .databaseFile(dbDir.appending(path: "catalog.sqlite")),
            scanCadence: .seconds(1)
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: tree)
        var ids: [MediaAssetID] = []
        try await waitUntil(every: .milliseconds(20)) {
            let state = try await catalogStoreTestState(store)
            ids = state.assets.map(\.id)
            return ids.count == 20000 && !state.isScanning
        }
        var offset = 0
        for size in [1, 8, 32, 128, 512] {
            var samples: [Double] = []
            for _ in 0 ..< 10 {
                let batch = ids[offset ..< offset + size].map { id in
                    EnrichmentResult(
                        id: id,
                        metadata: AssetMetadata(),
                        thumbnailPath: nil,
                        sourceSize: 1,
                        sourceMTimeSeconds: 1,
                        contentHash: nil
                    )
                }
                offset += size
                let started = ContinuousClock.now
                _ = await store.applyEnrichmentBatch(batch)
                samples.append(Double(started.duration(to: .now) / .microseconds(1)) / 1000)
            }
            samples.sort()
            Self.record(String(format: "apply size=%d medianMs=%.2f p90Ms=%.2f perRowMs=%.3f", size, samples[5], samples[9], samples[5] / Double(size)))
        }
    }

    @Test func copyProgressCallbackRate() async throws {
        let dir = try makeCatalogStoreTemporaryDirectory()
        let source = dir.appending(path: "big.bin")
        let chunk = Data(count: 8 * 1024 * 1024)
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        for _ in 0 ..< 64 { handle.write(chunk) }
        try handle.close()
        let destination = dir.appending(path: "copy.bin")
        final class Box: @unchecked Sendable { var count = 0 }
        let box = Box()
        let started = ContinuousClock.now
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        let callback: copyfile_callback_t = { what, stage, _, _, _, ctx in
            if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS, let ctx {
                Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue().count += 1
            }
            return COPYFILE_CONTINUE
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(box).toOpaque())
        let result = copyfile(source.path, destination.path, state, copyfile_flags_t(COPYFILE_ALL))
        let elapsed = started.duration(to: .now)
        Self.record("copyfile result=\(result) bytes=\(64 * 8)MB callbacks=\(box.count) elapsedMs=\(Int(elapsed / .milliseconds(1)))")
    }
}
```
