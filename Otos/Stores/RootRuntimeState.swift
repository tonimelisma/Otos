import Foundation

/// One in-memory record per known catalog root. Durable identity remains the filesystem
/// path on `LibraryRoot`; this struct is the single runtime projection of that root's
/// row ID, availability, activity, and ejectability so Store transitions cannot leave
/// parallel dictionaries out of sync.
nonisolated struct RootRuntimeState: Equatable {
    var root: LibraryRoot
    var rowID: Int64
    /// User-controlled order, authoritative only for library-kind roots — the
    /// first available one is the deterministic import destination. Removable
    /// sources carry it too (every row needs a value,
    /// `nextLibraryRootSortIndex` is not kind-scoped) but their sidebar order
    /// comes from display name at query time regardless.
    var sortIndex: Int64
    var availability: LibraryAvailability
    /// Stored activity (idle / enumerating / …). `.scanning` is derived from `activeScan`
    /// in `CatalogStore.activity(for:)` and is not written here.
    var activity: CatalogLibraryActivity
    var isEjectable: Bool
    /// Package directories skipped by the last completed scan (AVCHD and similar).
    /// Surfaced as import-footer attention by the coordinator (ARC-047);
    /// inventory-only here.
    var skippedPackageCount: Int
    /// Monotonic general planning revision. Bumped whenever reorganization planning
    /// inputs may have changed, including no-op rescans and event deferrals. Reorg
    /// planning polls this. Import planning does NOT key staleness on it — it churns
    /// under cloud-sync/enrichment materialization noise that never changes import
    /// occupancy. See `occupancyRevision`.
    var planRevision: UInt64
    /// Monotonic import-occupancy revision. Bumped only when the root's occupied
    /// media namespace actually changes: a media asset added, removed, renamed, or
    /// resized; a companion inventory change; an import/reorg settlement; or a
    /// discovered foreign occupant. Enrichment overlay writes and identical rescans
    /// never bump it. Import-plan staleness keys on this so planning settles while a
    /// large cloud destination keeps enriching. Every `occupancyRevision` bump also
    /// advances `planRevision` (an occupancy change is a superset planning change).
    var occupancyRevision: UInt64
    /// Process-local proof generation for destructive full-scan reconciliation. Any
    /// independent namespace mutation advances this value and retains typed dirty
    /// work, so an older observation may upsert facts but cannot delete rows.
    var namespaceMutationEpoch: UInt64

    var path: LibraryRootPath {
        root.path
    }

    init(
        root: LibraryRoot,
        rowID: Int64,
        sortIndex: Int64,
        availability: LibraryAvailability,
        activity: CatalogLibraryActivity,
        isEjectable: Bool,
        skippedPackageCount: Int = 0,
        planRevision: UInt64 = 0,
        occupancyRevision: UInt64 = 0,
        namespaceMutationEpoch: UInt64 = 0
    ) {
        self.root = root
        self.rowID = rowID
        self.sortIndex = sortIndex
        self.availability = availability
        self.activity = activity
        self.isEjectable = isEjectable
        self.skippedPackageCount = skippedPackageCount
        self.planRevision = planRevision
        self.occupancyRevision = occupancyRevision
        self.namespaceMutationEpoch = namespaceMutationEpoch
    }
}
