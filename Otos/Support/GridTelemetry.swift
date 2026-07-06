import Foundation
import Synchronization

/// Coarse grid telemetry guide
///
/// Tile loads, cache hits, and preheat callbacks are too frequent for per-event
/// JSONL. The UI path still emits signposts for live tracing; this facade keeps
/// thread-safe scalar counters that the ViewModel periodically snapshots into one
/// bounded diagnostic row. Counters are rendering telemetry only and never catalog
/// truth.
nonisolated struct GridTelemetrySnapshot: Equatable {
    var cacheHits: UInt64 = 0
    var cacheMisses: UInt64 = 0
    var cacheInserts: UInt64 = 0
    var appKitPrefetchRequests: UInt64 = 0
    var appKitPrefetchIDs: UInt64 = 0
    var manualPreheatRequests: UInt64 = 0
    var manualPreheatIDs: UInt64 = 0
    var preheatedIDs: UInt64 = 0
    var tileLoadsStarted: UInt64 = 0
    var tileLoadsApplied: UInt64 = 0
    var tileLoadsDropped: UInt64 = 0
    var tileLoadsNil: UInt64 = 0
    var watchdogCount: UInt64 = 0

    func delta(since previous: GridTelemetrySnapshot) -> GridTelemetrySnapshot {
        GridTelemetrySnapshot(
            cacheHits: difference(cacheHits, previous.cacheHits),
            cacheMisses: difference(cacheMisses, previous.cacheMisses),
            cacheInserts: difference(cacheInserts, previous.cacheInserts),
            appKitPrefetchRequests: difference(appKitPrefetchRequests, previous.appKitPrefetchRequests),
            appKitPrefetchIDs: difference(appKitPrefetchIDs, previous.appKitPrefetchIDs),
            manualPreheatRequests: difference(manualPreheatRequests, previous.manualPreheatRequests),
            manualPreheatIDs: difference(manualPreheatIDs, previous.manualPreheatIDs),
            preheatedIDs: difference(preheatedIDs, previous.preheatedIDs),
            tileLoadsStarted: difference(tileLoadsStarted, previous.tileLoadsStarted),
            tileLoadsApplied: difference(tileLoadsApplied, previous.tileLoadsApplied),
            tileLoadsDropped: difference(tileLoadsDropped, previous.tileLoadsDropped),
            tileLoadsNil: difference(tileLoadsNil, previous.tileLoadsNil),
            watchdogCount: difference(watchdogCount, previous.watchdogCount)
        )
    }

    func diagnosticFields(prefix: String = "") -> [String: String] {
        [
            fieldName("cacheHits", prefix: prefix): "\(cacheHits)",
            fieldName("cacheMisses", prefix: prefix): "\(cacheMisses)",
            fieldName("cacheInserts", prefix: prefix): "\(cacheInserts)",
            fieldName("appKitPrefetchRequests", prefix: prefix): "\(appKitPrefetchRequests)",
            fieldName("appKitPrefetchIDs", prefix: prefix): "\(appKitPrefetchIDs)",
            fieldName("manualPreheatRequests", prefix: prefix): "\(manualPreheatRequests)",
            fieldName("manualPreheatIDs", prefix: prefix): "\(manualPreheatIDs)",
            fieldName("preheatedIDs", prefix: prefix): "\(preheatedIDs)",
            fieldName("tileLoadsStarted", prefix: prefix): "\(tileLoadsStarted)",
            fieldName("tileLoadsApplied", prefix: prefix): "\(tileLoadsApplied)",
            fieldName("tileLoadsDropped", prefix: prefix): "\(tileLoadsDropped)",
            fieldName("tileLoadsNil", prefix: prefix): "\(tileLoadsNil)",
            fieldName("watchdogCount", prefix: prefix): "\(watchdogCount)",
            fieldName("cacheHitRatePermille", prefix: prefix): "\(cacheHitRatePermille)",
        ]
    }

    private var cacheHitRatePermille: UInt64 {
        let lookups = cacheHits + cacheMisses
        guard lookups > 0 else {
            return 0
        }
        return (cacheHits * 1000) / lookups
    }

    private func difference(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }

    private func fieldName(_ base: String, prefix: String) -> String {
        guard let first = base.first, !prefix.isEmpty else {
            return base
        }
        return "\(prefix)\(String(first).uppercased())\(base.dropFirst())"
    }
}

nonisolated enum GridTelemetry {
    private static let storage = Mutex(GridTelemetrySnapshot())

    static func recordCacheHit() {
        increment(\.cacheHits)
    }

    static func recordCacheMiss() {
        increment(\.cacheMisses)
    }

    static func recordCacheInsert() {
        increment(\.cacheInserts)
    }

    static func recordAppKitPrefetchRequest(idCount: Int) {
        storage.withLock { snapshot in
            snapshot.appKitPrefetchRequests += 1
            snapshot.appKitPrefetchIDs += UInt64(max(idCount, 0))
        }
    }

    static func recordManualPreheatRequest(idCount: Int) {
        storage.withLock { snapshot in
            snapshot.manualPreheatRequests += 1
            snapshot.manualPreheatIDs += UInt64(max(idCount, 0))
        }
    }

    static func recordPreheatedIDs(_ count: Int) {
        add(UInt64(max(count, 0)), to: \.preheatedIDs)
    }

    static func recordTileLoadStarted() {
        increment(\.tileLoadsStarted)
    }

    static func recordTileLoadApplied() {
        increment(\.tileLoadsApplied)
    }

    static func recordTileLoadDropped() {
        increment(\.tileLoadsDropped)
    }

    static func recordTileLoadNil() {
        increment(\.tileLoadsNil)
    }

    static func recordWatchdog() {
        increment(\.watchdogCount)
    }

    static func snapshot() -> GridTelemetrySnapshot {
        storage.withLock { $0 }
    }

    private static func increment(_ keyPath: WritableKeyPath<GridTelemetrySnapshot, UInt64>) {
        add(1, to: keyPath)
    }

    private static func add(_ amount: UInt64, to keyPath: WritableKeyPath<GridTelemetrySnapshot, UInt64>) {
        storage.withLock { snapshot in
            snapshot[keyPath: keyPath] += amount
        }
    }
}
