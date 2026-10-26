import Foundation
import MediaMetadata

/// The capture-timestamp roles Otos persists in `metadata_extra_json`: the library's own
/// roles (`CaptureTimestamps.Role`, whose raw values are its field names and are stable to
/// store), less the audio-only ones Otos never catalogs (MED-004).
///
/// `CaptureTimestampRecord.role` stays a `String` on purpose — the persisted JSON must
/// decode a role this build does not know rather than failing — but no code spells a role
/// as a literal.
nonisolated extension CaptureTimestamps.Role {
    static let cataloged: [CaptureTimestamps.Role] = allCases.filter { !$0.isAudioOnly }
}

nonisolated extension CaptureTimestampRecord {
    /// The record of one library timestamp, under its role.
    init(role: CaptureTimestamps.Role, time: CaptureTime) {
        self.init(
            role: role.rawValue,
            instant: time.instant,
            utcOffsetSeconds: time.utcOffsetSeconds,
            precision: time.precision.rawValue,
            year: time.year,
            month: time.month,
            day: time.day,
            hour: time.hour,
            minute: time.minute,
            second: time.second
        )
    }
}

/// The four timestamp roles the `best_capture_unix` generated column coalesces,
/// projected out of the stored records.
///
/// This is a *derivation*, not a second stored fact: the four instants are read from
/// `metadata.timestamps`, the one stored copy, so no constructed value can carry a
/// pair that disagrees.
///
/// `metadata.timestamps` is the stored truth. `ts_*_unix` and
/// `capture_wall_compact` (see `CaptureWallClock`) are both projections of it,
/// derived where they are written.
nonisolated struct BestCaptureInstants: Equatable, Sendable {
    let original: Date?
    let quickTimeCreation: Date?
    let digitized: Date?
    let gps: Date?

    static let none = BestCaptureInstants(original: nil, quickTimeCreation: nil, digitized: nil, gps: nil)

    /// Roles whose *absolute* instant participates in best-date ordering. A role
    /// without a usable UTC instant projects to nil here while its local
    /// components stay preserved in the record for `CaptureWallClock`.
    static func from(_ records: [CaptureTimestampRecord]) -> Self {
        func instant(_ role: CaptureTimestamps.Role) -> Date? {
            records.first { $0.role == role.rawValue }?.instant
        }
        return BestCaptureInstants(
            original: instant(.original),
            quickTimeCreation: instant(.quickTimeCreation),
            digitized: instant(.digitized),
            gps: instant(.gps)
        )
    }
}
