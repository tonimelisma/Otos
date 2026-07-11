import Foundation

/// One in-memory record per known catalog root. Durable identity remains the filesystem
/// path on `LibraryRoot`; this struct is the single runtime projection of that root's
/// row ID, availability, activity, and ejectability so Store transitions cannot leave
/// parallel dictionaries out of sync.
nonisolated struct RootRuntimeState: Equatable {
    var root: LibraryRoot
    var rowID: Int64
    var availability: LibraryAvailability
    /// Stored activity (idle / enumerating / …). `.scanning` is derived from `activeScan`
    /// in `CatalogStore.activity(for:)` and is not written here.
    var activity: CatalogLibraryActivity
    var isEjectable: Bool
    /// Package directories skipped by the last completed scan (AVCHD and similar).
    /// Surfaced as import-footer attention in Stage D; inventory-only here.
    var skippedPackageCount: Int

    var path: LibraryRootPath {
        root.path
    }

    init(
        root: LibraryRoot,
        rowID: Int64,
        availability: LibraryAvailability,
        activity: CatalogLibraryActivity,
        isEjectable: Bool,
        skippedPackageCount: Int = 0
    ) {
        self.root = root
        self.rowID = rowID
        self.availability = availability
        self.activity = activity
        self.isEjectable = isEjectable
        self.skippedPackageCount = skippedPackageCount
    }
}
