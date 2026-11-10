import Foundation
import GRDB
import MediaMetadata
@testable import OtosKit

extension CatalogQueryGateway {
    /// The ordered-ID SQL for a scope without a date dimension, whose clause reads
    /// nothing from the catalog, so an empty database stands in for the read.
    static func orderedAssetIDQuery(
        descriptor: CatalogQueryDescriptor,
        scope: CatalogScopePredicate
    ) throws -> SQLQuery? {
        try DatabaseQueue().read { db in
            try orderedAssetIDQuery(descriptor: descriptor, scope: scope, db: db)
        }
    }
}

struct CatalogStoreTestState: Equatable {
    var libraries: [CatalogLibraryState]
    var removableSources: [CatalogLibraryState]
    var assets: [MediaAsset]

    /// Store tests inspect values rather than ordering. Production ordering is
    /// deliberately owned by CatalogProjection, so this helper stays test-only.
    var testAssets: [MediaAsset] {
        assets
    }

    var allSources: [CatalogLibraryState] {
        libraries + removableSources
    }

    var isScanning: Bool {
        allSources.contains { $0.isScanning }
    }
}

func catalogStoreTestState(_ store: CatalogStore) async throws -> CatalogStoreTestState {
    let roots = await store.currentLibraries()
    let libraries = roots.filter { $0.kind == .library }
    let removableSources = roots.filter { $0.kind != .library }
    let allLibraryPaths = Set(roots.map(\.path))
    let ids = try await store.orderedAssetIDs(for: .allMedia, availableLibraryPaths: allLibraryPaths)
    let assetsByID = try await store.mediaAssets(for: ids)
    return CatalogStoreTestState(
        libraries: libraries,
        removableSources: removableSources,
        assets: Array(assetsByID.values)
    )
}

struct ProjectionFixture {
    var libraries: [CatalogLibraryState]
    var orderedAssetIDs: [MediaAssetID]
}

func orderedAssetIDs(for assets: [MediaAsset]) -> [MediaAssetID] {
    assets
        .sorted { left, right in
            if left.sortKey != right.sortKey {
                return left.sortKey < right.sortKey
            }
            if left.libraryRootPath.rawValue != right.libraryRootPath.rawValue {
                return left.libraryRootPath.rawValue < right.libraryRootPath.rawValue
            }
            return left.relativePath.rawValue < right.relativePath.rawValue
        }
        .map(\.id)
}

// MARK: - Capture timestamp fixtures

extension CaptureTimestampRecord {
    /// A UTC-anchored record, as the library reports an absolute time: its UTC wall
    /// components at offset 0. It feeds `capture_instant_unix` ordering and supplies no
    /// naming fact (`captureWallClock` takes local-authority times only).
    static func absolute(_ role: CaptureTimestamps.Role = .original, instant: Date) -> CaptureTimestampRecord {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant)
        return CaptureTimestampRecord(
            role: role.rawValue,
            instant: instant,
            utcOffsetSeconds: 0,
            precision: CaptureTime.Precision.absolute.rawValue,
            year: parts.year,
            month: parts.month,
            day: parts.day,
            hour: parts.hour,
            minute: parts.minute,
            second: parts.second
        )
    }

    /// A floating local record: wall-clock components with no offset and no instant, as
    /// an Exif time without `OffsetTimeOriginal` reads.
    static func floating(_ role: CaptureTimestamps.Role = .original) -> CaptureTimestampRecord {
        CaptureTimestampRecord(
            role: role.rawValue,
            instant: nil,
            utcOffsetSeconds: nil,
            precision: CaptureTime.Precision.localFloating.rawValue,
            year: 2026,
            month: 4,
            day: 25,
            hour: 14,
            minute: 51,
            second: 34
        )
    }
}

extension AssetMetadata {
    /// Metadata whose only capture record carries an **absolute instant** and no
    /// local wall-clock components.
    ///
    /// It therefore feeds `capture_instant_unix` — and so `best_capture_local` ordering —
    /// without supplying a naming fact, because `CaptureWallClock` selects only
    /// local-authority records with full components. That is exactly what a bare
    /// `timestampFacts.original` used to produce when paired with an empty
    /// `AssetMetadata()`, so fixtures converted to this helper assert what they
    /// always asserted — the difference is that the value is now one coherent
    /// thing rather than two halves that were free to disagree.
    /// A nil instant yields no record at all, which is what "this role has no
    /// usable absolute timestamp" always meant.
    static func absoluteCapture(role: CaptureTimestamps.Role = .original, instant: Date?) -> AssetMetadata {
        guard let instant else { return AssetMetadata() }
        return AssetMetadata(timestamps: [.absolute(role, instant: instant)])
    }

    /// Metadata carrying a local-authority capture record: an instant *and* the
    /// wall-clock components. This feeds best-date ordering and the naming fact,
    /// which is what a photo with an embedded local `DateTimeOriginal` produces.
    static func localCapture(
        role: CaptureTimestamps.Role = .original,
        instant: Date,
        timeZone: TimeZone = TimeZone(secondsFromGMT: 0) ?? .current
    ) -> AssetMetadata {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant)
        return AssetMetadata(timestamps: [
            CaptureTimestampRecord(
                role: role.rawValue,
                instant: instant,
                utcOffsetSeconds: nil,
                precision: "localFloating",
                year: parts.year,
                month: parts.month,
                day: parts.day,
                hour: parts.hour,
                minute: parts.minute,
                second: parts.second
            ),
        ])
    }
}
