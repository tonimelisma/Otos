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

    var path: LibraryRootPath {
        root.path
    }
}
