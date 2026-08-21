import Foundation

/// The capture-timestamp roles Otos persists in `metadata_extra_json`.
///
/// `CaptureTimestampRecord.role` stays a `String` on purpose — the persisted JSON
/// must decode a role this build does not know about rather than failing — but no
/// code spells a role as a literal. Producer (`MediaEnricher.mapTimestamps`) and
/// both projections below agree by construction.
nonisolated enum CaptureTimestampRole: String, CaseIterable, Sendable {
    case original
    case digitized
    case tiffDateTime
    case gps
    case quickTimeCreation
    case quickTimeLocation
    case quickTimeContentCreate
    case containerCreation
    case riffRecording
}

/// The four timestamp roles the `best_capture_unix` generated column coalesces,
/// projected out of the stored records.
///
/// This is a *derivation*, not a second stored fact. `EnrichmentResult` used to
/// carry these four instants alongside `metadata.timestamps`, which already held
/// them — a lossy duplicate of the same upstream `CaptureTimestamps`, on the same
/// struct, that nothing kept in agreement. Production could not diverge because
/// both halves came from one source, but any constructed value could, and the
/// only defence was that no one tried.
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
        func instant(_ role: CaptureTimestampRole) -> Date? {
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
