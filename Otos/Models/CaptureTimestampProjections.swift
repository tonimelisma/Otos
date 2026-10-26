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

/// The absolute moment of capture the catalog sorts by (`capture_instant_unix`, which
/// `best_capture_unix` falls back from to the file's dates): the library's choice
/// (`CaptureTimestamps.instantPrecedence` — the camera clock's roles, then GPS) applied to
/// the stored records, the first role in that order whose record has a UTC instant.
///
/// This is a *derivation*, not a second stored fact: it is read from
/// `metadata.timestamps`, the one stored copy. A role without a usable instant (a
/// floating Exif time) is passed over here while its local components stay in the record
/// for `CaptureWallClock`.
nonisolated enum CaptureInstant {
    static func select(from records: [CaptureTimestampRecord]) -> Date? {
        let byRole = Dictionary(grouping: records, by: \.role)
        for role in CaptureTimestamps.instantPrecedence {
            if let instant = byRole[role.rawValue]?.lazy.compactMap(\.instant).first {
                return instant
            }
        }
        return nil
    }
}
