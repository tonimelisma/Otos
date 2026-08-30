import Foundation

/// The single pure rule for the filesystem mtime stamped on an imported primary.
/// Planner and executor must compare the same integer-second fact; unknown dates
/// stay unknown instead of using a wall-clock fallback that would prevent convergence.
nonisolated enum ImportDestinationDate {
    static func expected(for source: PlanningFileFacts) -> Date? {
        // A *derived* wall names the file but must not stamp it. The derivation is
        // `mtime − duration`, so stamping the destination with it would make the copy's
        // own mtime the derived value; enriching that copy would then derive
        // `wall − duration` again and drift by one duration per generation, corrupting
        // grid order and reorganization naming. Overlay reuse cannot rescue this
        // either — `settleImport` short-circuits reuse for `.removableVolume` sources
        // (ADR 0018 never hashes a card in place), so the copy is enriched afresh.
        //
        // Stamping the source's real mtime instead is idempotent: the copy keeps the
        // mtime the derivation was computed from, so its own enrichment reproduces the
        // same wall. Convergence still holds because planner and executor apply this
        // one rule (ARC-046A).
        if source.captureWallPrecision == CaptureWallClock.derivedFromDurationPrecision {
            return source.contentModifiedAt
        }
        if let compact = source.captureWallCompact,
           let date = CaptureWallClock.date(fromCompact: compact)
        {
            return date
        }
        return source.contentModifiedAt
    }
}
