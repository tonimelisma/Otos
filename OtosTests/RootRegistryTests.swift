import Foundation
@testable import Otos
import Testing

struct RootRegistryTests {
    private let libraryPath = LibraryRootPath(rawValue: "/Pictures")
    private let otherPath = LibraryRootPath(rawValue: "/Other")
    private let volumePath = LibraryRootPath(rawValue: "/Volumes/Card")

    private func libraryState(
        path: LibraryRootPath,
        rowID: Int64,
        availability: LibraryAvailability = .available,
        deviceIdentity: String? = nil
    ) -> RootRuntimeState {
        RootRuntimeState(
            root: LibraryRoot(
                path: path,
                kind: .library,
                deviceIdentity: deviceIdentity,
                displayName: path.rawValue
            ),
            rowID: rowID,
            availability: availability,
            activity: .idle,
            isEjectable: false
        )
    }

    private func volumeState(rowID: Int64, availability: LibraryAvailability = .available) -> RootRuntimeState {
        RootRuntimeState(
            root: LibraryRoot(
                path: volumePath,
                kind: .removableVolume,
                deviceIdentity: "volume:card",
                displayName: "Card"
            ),
            rowID: rowID,
            availability: availability,
            activity: .idle,
            isEjectable: true
        )
    }

    @Test func upsertIndexesPathAndRowID() {
        var registry = RootRegistry()
        registry.upsert(libraryState(path: libraryPath, rowID: 7))

        #expect(registry[libraryPath]?.rowID == 7)
        #expect(registry.path(forRowID: 7) == libraryPath)
        #expect(registry.rowIDSnapshot() == [libraryPath: 7])
    }

    @Test func removeClearsBothIndexes() {
        var registry = RootRegistry()
        registry.upsert(libraryState(path: libraryPath, rowID: 7))
        let removed = registry.remove(path: libraryPath)

        #expect(removed?.rowID == 7)
        #expect(registry[libraryPath] == nil)
        #expect(registry.path(forRowID: 7) == nil)
    }

    @Test func setAvailabilityNoopsWhenUnchanged() {
        var registry = RootRegistry()
        registry.upsert(libraryState(path: libraryPath, rowID: 1, availability: .available))

        #expect(registry.setAvailability(.available, for: libraryPath) == false)
        #expect(registry.setAvailability(.unavailable, for: libraryPath) == true)
        #expect(registry[libraryPath]?.availability == .unavailable)
    }

    @Test func scopePredicateHonorsAllMediaAndLibraryScope() {
        var registry = RootRegistry()
        registry.upsert(libraryState(path: libraryPath, rowID: 1))
        registry.upsert(libraryState(path: otherPath, rowID: 2))
        registry.upsert(volumeState(rowID: 3))

        let allMedia = registry.scopePredicate(
            selection: .allMedia,
            availableLibraryPaths: [libraryPath, otherPath, volumePath]
        )
        #expect(allMedia == CatalogScopePredicate(rootIDs: [1, 2]))

        let libraryOnly = registry.scopePredicate(
            selection: .library(libraryPath),
            availableLibraryPaths: [libraryPath, otherPath]
        )
        #expect(libraryOnly == CatalogScopePredicate(rootIDs: [1]))

        let unavailableLibrary = registry.scopePredicate(
            selection: .library(libraryPath),
            availableLibraryPaths: [otherPath]
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
            availableLibraryPaths: [libraryPath, otherPath, volumePath]
        )

        #expect(batch == CatalogScopePredicate(rootIDs: [1, 2], importBatchUnixMs: 1_785_908_514_176))
        #expect(batch.selectsNothing == false)
    }

    @Test func availableRootIDsByRemovablePrioritySplitsKinds() {
        var registry = RootRegistry()
        registry.upsert(libraryState(path: libraryPath, rowID: 1))
        registry.upsert(volumeState(rowID: 2))
        registry.upsert(libraryState(path: otherPath, rowID: 3, availability: .unavailable))

        let prioritized = registry.availableRootIDsByRemovablePriority()
        #expect(prioritized.removable == [2])
        #expect(prioritized.fixed == [1])
    }

    @Test func availableRootIDsByHashRequirementSplitsKinds() {
        var registry = RootRegistry()
        registry.upsert(libraryState(path: libraryPath, rowID: 1))
        registry.upsert(volumeState(rowID: 2))
        registry.upsert(libraryState(path: otherPath, rowID: 3, availability: .unavailable))

        let partitioned = registry.availableRootIDsByHashRequirement()
        #expect(partitioned.hashRequired == [1])
        #expect(partitioned.hashNotRequired == [2])
    }

    @Test func contentHashRequiredIsKindDerived() {
        let path = LibraryRootPath(rawValue: "/x")
        #expect(LibraryRoot(path: path, kind: .library).isContentHashRequired)
        #expect(LibraryRoot(path: path, kind: .deviceMTP).isContentHashRequired)
        #expect(!LibraryRoot(path: path, kind: .removableVolume).isContentHashRequired)
        #expect(LibraryRoot(path: path, kind: .removableVolume).isRemovableSource)
    }

    @Test func rootForDeviceIdentityFindsMatchingRoot() {
        var registry = RootRegistry()
        registry.upsert(libraryState(path: libraryPath, rowID: 1, deviceIdentity: "camera:1"))
        #expect(registry.rootForDeviceIdentity("camera:1")?.path == libraryPath)
        #expect(registry.rootForDeviceIdentity("missing") == nil)
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
