import Foundation
@testable import OtosKit
import Testing

struct RootRegistryTests {
    private let libraryPath = LibraryRootPath(rawValue: "/Pictures")
    private let otherPath = LibraryRootPath(rawValue: "/Other")
    private let volumePath = LibraryRootPath(rawValue: "/Volumes/Card")

    private func libraryState(
        path: LibraryRootPath,
        rowID: Int64,
        availability: LibraryAvailability = .available,
        deviceIdentity: DeviceIdentity? = nil
    ) -> RootRuntimeState {
        RootRuntimeState(
            root: LibraryRoot(
                path: path,
                kind: .library,
                deviceIdentity: deviceIdentity,
                displayName: path.rawValue
            ),
            rowID: rowID,
            sortIndex: rowID,
            availability: availability,
            activity: .idle,
            isEjectable: false,
            capabilities: .unknown
        )
    }

    private func volumeState(rowID: Int64, availability: LibraryAvailability = .available) -> RootRuntimeState {
        RootRuntimeState(
            root: LibraryRoot(
                path: volumePath,
                kind: .removableVolume,
                deviceIdentity: .volume(uuid: "card"),
                displayName: "Card"
            ),
            rowID: rowID,
            sortIndex: rowID,
            availability: availability,
            activity: .idle,
            isEjectable: true,
            capabilities: .unknown
        )
    }

    // Validates: ARC-003, ARC-022
    @Test func scopePredicateHonorsAllMediaAndLibraryScope() {
        var registry = RootRegistry()
        registry.upsert(libraryState(path: libraryPath, rowID: 1))
        registry.upsert(libraryState(path: otherPath, rowID: 2))
        registry.upsert(volumeState(rowID: 3))

        let allMedia = registry.scopePredicate(
            selection: .allMedia,
            availableLibraryPaths: [libraryPath, otherPath, volumePath],
            duplicatesReach: .withinEachLibrary
        )
        #expect(allMedia == CatalogScopePredicate(rootIDs: [1, 2], showsOneCopy: true, holdsEveryCopyRoot: true))

        let libraryOnly = registry.scopePredicate(
            selection: .library(libraryPath),
            availableLibraryPaths: [libraryPath, otherPath],
            duplicatesReach: .withinEachLibrary
        )
        #expect(libraryOnly == CatalogScopePredicate(rootIDs: [1]))

        let unavailableLibrary = registry.scopePredicate(
            selection: .library(libraryPath),
            availableLibraryPaths: [otherPath],
            duplicatesReach: .withinEachLibrary
        )
        #expect(unavailableLibrary.selectsNothing)
    }

    /// A batch selects the fixed libraries *and* the batch stamp. Resolving it to no
    /// roots is what made batch-scoped counts and filter options silently answer zero.
    @Test func scopePredicateCarriesBatchStampAcrossFixedLibraries() {
        var registry = RootRegistry()
        registry.upsert(libraryState(path: libraryPath, rowID: 1))
        registry.upsert(libraryState(path: otherPath, rowID: 2))
        registry.upsert(volumeState(rowID: 3))

        let batch = registry.scopePredicate(
            selection: .importBatch(ImportBatchID(unixMilliseconds: 1_785_908_514_176)),
            availableLibraryPaths: [libraryPath, otherPath, volumePath],
            duplicatesReach: .withinEachLibrary
        )

        #expect(batch == CatalogScopePredicate(rootIDs: [1, 2], importBatchUnixMs: 1_785_908_514_176, holdsEveryCopyRoot: true))
        #expect(batch.selectsNothing == false)
    }

    @Test func enrichableRootIDsByRemovablePrioritySplitsKinds() {
        var registry = RootRegistry()
        registry.upsert(libraryState(path: libraryPath, rowID: 1))
        registry.upsert(volumeState(rowID: 2))
        registry.upsert(libraryState(path: otherPath, rowID: 3, availability: .unavailable))

        let prioritized = registry.enrichableRootIDsByRemovablePriority()
        #expect(prioritized.removable == [2])
        #expect(prioritized.fixed == [1])
    }

    // Validates: APP-017
    /// An ejecting source stays available for the sidebar, but enrichment claims
    /// nothing new on it, so the eject drain waits on finite work.
    @Test func aQuiescedSourceIsNotEnrichable() {
        var registry = RootRegistry()
        registry.upsert(libraryState(path: libraryPath, rowID: 1))
        var volume = volumeState(rowID: 2)
        volume.isQuiesced = true
        registry.upsert(volume)

        #expect(registry.enrichableRootIDsByRemovablePriority().removable.isEmpty)
        #expect(registry.enrichableRootIDsByFirstClaim().metadataFirst.isEmpty)
        #expect(registry.enrichableRootIDsByRemovablePriority().fixed == [1])
    }

    @Test func enrichableRootIDsByHashRequirementSplitsKinds() {
        var registry = RootRegistry()
        registry.upsert(libraryState(path: libraryPath, rowID: 1))
        registry.upsert(volumeState(rowID: 2))
        registry.upsert(libraryState(path: otherPath, rowID: 3, availability: .unavailable))

        let partitioned = registry.enrichableRootIDsByFirstClaim()
        #expect(partitioned.library == [1])
        #expect(partitioned.metadataFirst == [2])
    }

    /// The rule is byte locality, not kind for its own sake (ADR 0018): a digest costs
    /// every byte, so it is only free where enrichment reads those bytes anyway.
    ///
    /// `.deviceMTP` moved into the not-required group when camera rows began enriching from
    /// a few kilobytes of ranged reads instead of a downloaded copy. Requiring a digest
    /// would have reintroduced exactly the whole-file transfer that removal was for. Those
    /// rows are hashed after import, from the destination's local bytes — which is what the
    /// ADR already prescribes for a removable volume.
    @Test func contentHashIsRequiredOnlyWhereEnrichmentAlreadyReadsEveryByte() {
        let path = LibraryRootPath(rawValue: "/x")
        #expect(LibraryRoot(path: path, kind: .library).claimsEveryProductTogether)
        #expect(
            !LibraryRoot(path: path, kind: .deviceMTP).claimsEveryProductTogether,
            "a camera row is read as ranges, so hashing it would re-download the file it avoided"
        )
        #expect(!LibraryRoot(path: path, kind: .removableVolume).claimsEveryProductTogether)
        #expect(LibraryRoot(path: path, kind: .removableVolume).isRemovableSource)
    }

    @Test func ownsLeaseRequiresMatchingPathAndRowID() {
        var registry = RootRegistry()
        registry.upsert(libraryState(path: libraryPath, rowID: 9))
        #expect(registry.ownsLease(rootPath: libraryPath, rootRowID: 9))
        #expect(!registry.ownsLease(rootPath: libraryPath, rootRowID: 8))
        #expect(!registry.ownsLease(rootPath: otherPath, rootRowID: 9))
    }

    @Test func validateNoOverlapRejectsNestedCandidate() throws {
        var registry = RootRegistry()
        registry.upsert(libraryState(path: libraryPath, rowID: 1))
        let nested = LibraryRootPath(rawValue: "/Pictures/Nested")
        do {
            try registry.validateNoOverlap(nested)
            Issue.record("Expected overlappingRoot for nested candidate")
        } catch let CatalogStoreError.overlappingRoot(existingPath, _) {
            #expect(existingPath == libraryPath)
        }
        try registry.validateNoOverlap(otherPath)
    }
}
