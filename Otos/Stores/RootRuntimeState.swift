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
    /// Stored activity (idle / enumerating / …). `.scanning` is derived from the scan leases
    /// in `CatalogStore.activity(for:)` and is not written here.
    var activity: CatalogLibraryActivity
    var isEjectable: Bool
    /// Process-local attachment generation for removable roots. It advances on
    /// every attach, including a reconnect at the same path, so consumers can
    /// distinguish a new connection even when detach and attach are coalesced.
    var attachmentGeneration: UInt64
    /// Probed comparison rules for this root's filesystem namespace. Unknown or
    /// detached roots use the shared conservative fallback.
    var capabilities: VolumeNamespaceCapabilities
    /// Package directories skipped by the last completed scan (AVCHD and similar).
    /// Surfaced as import-footer attention by the coordinator (ARC-047);
    /// inventory-only here.
    var skippedPackageCount: Int
    /// Monotonic general planning revision. Bumped whenever reorganization planning
    /// inputs may have changed, including no-op rescans and event deferrals. Reorg
    /// planning polls this. Import planning does NOT key staleness on it — it churns
    /// under cloud-sync/enrichment materialization noise that never changes what an
    /// import reads. See `namespaceRevision` and `namingRevision`.
    var planRevision: UInt64
    /// Monotonic namespace revision: which paths this root occupies. Bumped only when
    /// the occupied media namespace actually changes — a media asset added, removed,
    /// renamed, or resized; a companion inventory change; an import/reorg settlement;
    /// or a discovered foreign occupant. Enrichment overlay writes and identical
    /// rescans never bump it.
    ///
    /// An import plan reads this for **both** its source and its destination: the
    /// destination's occupied names decide collisions, and the source's inventory
    /// decides what there is to copy.
    var namespaceRevision: UInt64
    /// Monotonic naming revision: what Otos would *call* this root's assets. Bumped
    /// when an enrichment write changes an asset's `capture_wall_compact`, which is
    /// the fact date/time import naming is derived from.
    ///
    /// An import plan reads this for its **source only**. Enriching an asset already
    /// in the destination cannot change the plan: Otos never writes into media
    /// folders, so no file is renamed, and `fetchDestinationOccupants` reads only
    /// `relative_path`, `byte_size`, and `content_modified_at_unix` — never a capture
    /// wall. Keying destination staleness on naming is what livelocked planning
    /// against an enriching cloud library (ARC-046; fixed once in pull request 111,
    /// then regressed by `40261bf` and fixed again later).
    ///
    /// Every namespace or naming bump also advances `planRevision` — both are
    /// planning changes for reorganization, which legitimately depends on capture
    /// dates and polls `planRevision` directly.
    var namingRevision: UInt64
    /// Process-local proof generation for destructive full-scan reconciliation. Any
    /// independent namespace mutation advances this value and retains typed dirty
    /// work, so an older observation may upsert facts but cannot delete rows.
    var namespaceMutationEpoch: UInt64
    /// Process-local: an eject has quiesced this source. It stays available — the
    /// sidebar keeps the row until the unmount — but no new enrichment is claimed on
    /// it, so the work an eject drains is finite. Resume clears it; a new attachment
    /// starts from a fresh state.
    var isQuiesced = false
    /// Process-local: the import batches now copying from this root. While a card
    /// (`.removableVolume`) is being imported, enrichment does not read it: the copier
    /// needs the card reader, and every copy reuses the overlay the card already has, so
    /// card work started now only slows the import it competes with (ARC-053, ENR-017).
    /// A camera keeps enriching, because import copies its enrichment staging (ARC-049).
    var importingBatches: Set<ImportBatchID> = []

    var path: LibraryRootPath {
        root.path
    }

    /// Whether an import is copying from this card, so enrichment leaves it alone.
    var isCardBeingImported: Bool {
        root.kind.pausesEnrichmentWhileImporting && !importingBatches.isEmpty
    }

    /// Available, enriched from its originals, not quiesced, and not a card being
    /// imported: enrichment may claim this root's assets.
    var isEnrichable: Bool {
        root.kind.enrichesFromOriginals && availability == .available && !isQuiesced && !isCardBeingImported
    }

    init(
        root: LibraryRoot,
        rowID: Int64,
        sortIndex: Int64,
        availability: LibraryAvailability,
        activity: CatalogLibraryActivity,
        isEjectable: Bool,
        attachmentGeneration: UInt64 = 0,
        capabilities: VolumeNamespaceCapabilities = .unknown,
        skippedPackageCount: Int = 0,
        planRevision: UInt64 = 0,
        namespaceRevision: UInt64 = 0,
        namingRevision: UInt64 = 0,
        namespaceMutationEpoch: UInt64 = 0
    ) {
        self.root = root
        self.rowID = rowID
        self.sortIndex = sortIndex
        self.availability = availability
        self.activity = activity
        self.isEjectable = isEjectable
        self.attachmentGeneration = attachmentGeneration
        self.capabilities = capabilities
        self.skippedPackageCount = skippedPackageCount
        self.planRevision = planRevision
        self.namespaceRevision = namespaceRevision
        self.namingRevision = namingRevision
        self.namespaceMutationEpoch = namespaceMutationEpoch
    }
}
