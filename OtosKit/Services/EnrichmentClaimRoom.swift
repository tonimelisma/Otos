import Foundation

/// How many more background claims each root may take (ENR-009): the claim window's limit
/// less that root's claimed work, queued, reading or waiting on a transfer.
///
/// Each root has a window of its own. A claim that cannot start holds its place until
/// something outside the coordinator moves — a download the machine's memory holds, a
/// transfer slot another root fills — so one window shared by every root is filled by the
/// root that waits longest: a cloud library's held downloads left a card attached after
/// them, and an account read in ranges, with no room at all, read only while on screen
/// (ENR-011). Per root, the root that waits holds only its own room.
nonisolated struct EnrichmentClaimRoom: Equatable, Sendable {
    /// The claimed work a root may hold.
    let perRoot: Int
    /// Each root's claimed work the window counts.
    let claimed: [LibraryRootPath: Int]

    func room(for root: LibraryRootPath) -> Int {
        max(perRoot - claimed[root, default: 0], 0)
    }

    /// The room across `roots`.
    func total(over roots: Set<LibraryRootPath>) -> Int {
        roots.reduce(0) { $0 + room(for: $1) }
    }

    /// Whether a root that had no room in `earlier` has room now. A claim that found nothing
    /// at `earlier` asked every root with room, and each had no row to give, so only a root it
    /// could not ask may have rows it did not reach; more room for a root that had some
    /// reaches none.
    func opensARootFull(in earlier: EnrichmentClaimRoom) -> Bool {
        earlier.claimed.keys.contains { earlier.room(for: $0) == 0 && room(for: $0) > 0 }
    }
}
