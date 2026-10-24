import Foundation
@testable import OtosKit
import Testing

/// The plan-building boundary is a real substitution seam.
/// The live builder remains `Sendable`, performs work off the coordinator actor,
/// and returns plan plus namespace counts and timing. The controlled builder
/// records requests, suspends selected builds, resumes with real results, and
/// records cancellation without assuming cancellation ends the continuation.
@Suite(.testDirectory)
struct ImportPlanBuilderTests {
    /// A path identifier only: planning never reads the source root.
    private static let sourceRoot = LibraryRootPath(rawValue: "/Volumes/PLAN-BUILDER-CARD")

    /// A destination library of the test's own, so the live enumeration reads only what
    /// the test put there.
    private static func makeDestination() throws -> LibraryRootPath {
        try CatalogPath.normalizedExistingDirectoryPath(for: makeTestDirectory())
    }

    private static func facts(
        name: String = "IMG_1.JPG",
        captureWallCompact: Int64? = 20_250_101_120_000
    ) -> PlanningFileFacts {
        let relative = MediaRelativePath(rawValue: name)
        return PlanningFileFacts(
            id: MediaAssetID(libraryRootPath: sourceRoot, relativePath: relative),
            sourceURL: sourceRoot.url.appending(path: relative.rawValue),
            relativePath: relative,
            byteSize: 10,
            contentModifiedAt: Date(timeIntervalSince1970: 100),
            captureWallCompact: captureWallCompact,
            mediaKind: .image,
            fileExtension: (name as NSString).pathExtension,
            companions: [],
            contentTypeIdentifier: "public.jpeg"
        )
    }

    private static func snapshot(
        sourceMedia: [PlanningFileFacts],
        dest: LibraryRootPath,
        occupants: [MediaRelativePath: DestinationOccupantFacts] = [:]
    ) -> ImportPlanningSnapshot {
        ImportPlanningSnapshot(
            generation: 1,
            sourceRoot: sourceRoot,
            destinationRoot: dest,
            sourceNamespaceRevision: 1,
            sourceNamingRevision: 0,
            destinationNamespaceRevision: 1,
            sourceMedia: sourceMedia,
            destinationOccupants: occupants,
            policy: ImportPolicy(
                destinationFolderPolicy: .yearMonth,
                destinationNamePolicy: .captureDateTime,
                importSidecarFiles: false,
                deleteSourceAfterImport: false,
                autoEjectAfterImport: false
            ),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current
        )
    }

    /// The live builder reads the destination as it is on disk and plans against it.
    /// The destination already holds an unrelated file at the first shot's date name,
    /// so that shot takes the first suffix while the second lands on its own name; the
    /// one folder both names live in is the one folder read.
    @Test func liveBuilderPlansAgainstTheDestinationOnDisk() async throws {
        let dest = try Self.makeDestination()
        let occupied = dest.url.appending(path: "2025/01/20250101_120000.jpeg")
        try FileManager.default.createDirectory(
            at: occupied.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 7, count: 99).write(to: occupied)
        let first = Self.facts(name: "IMG_001.JPG", captureWallCompact: 20_250_101_120_000)
        let second = Self.facts(name: "IMG_002.JPG", captureWallCompact: 20_250_102_120_000)

        let built = await LiveImportPlanBuilder().build(
            snapshot: Self.snapshot(sourceMedia: [first, second], dest: dest),
            additionalReserved: []
        )

        #expect(built.namespace.folderCount == 1)
        #expect(built.namespace.entryCount == 1)
        #expect(built.namespace.unreadableFolders.isEmpty)
        let suffixed = MediaRelativePath(rawValue: "2025/01/20250101_120000_001.jpeg")
        let free = MediaRelativePath(rawValue: "2025/01/20250102_120000.jpeg")
        #expect(built.plan.entries == [
            MediaOperationPlanEntry(
                source: first,
                companionDestinations: [:],
                disposition: .copy(destination: suffixed)
            ),
            MediaOperationPlanEntry(
                source: second,
                companionDestinations: [:],
                disposition: .copy(destination: free)
            ),
        ])
        #expect(built.plan.totals == MediaOperationPlanTotals(
            copyCount: 2,
            skipCount: 0,
            blockedCount: 0,
            companionCopyCount: 0,
            copyBytes: 20
        ))
    }

    @Test func controlledBuilderCanSuspendAndResumeTwoIndependentBuilds() async throws {
        // Use distinct source roots so the builder can suspend each independently.
        let sourceA = LibraryRootPath(rawValue: "/Volumes/PLAN-BUILDER-CARD-A")
        let sourceB = LibraryRootPath(rawValue: "/Volumes/PLAN-BUILDER-CARD-B")
        let dest = try Self.makeDestination()
        let mediaA = [PlanningFileFacts(
            id: MediaAssetID(libraryRootPath: sourceA, relativePath: MediaRelativePath(rawValue: "A1.JPG")),
            sourceURL: sourceA.url.appending(path: "A1.JPG"),
            relativePath: MediaRelativePath(rawValue: "A1.JPG"),
            byteSize: 10,
            contentModifiedAt: Date(timeIntervalSince1970: 100),
            captureWallCompact: 20_250_101_120_000,
            mediaKind: .image,
            fileExtension: "JPG",
            companions: [],
            contentTypeIdentifier: "public.jpeg"
        )]
        let mediaB = [PlanningFileFacts(
            id: MediaAssetID(libraryRootPath: sourceB, relativePath: MediaRelativePath(rawValue: "B1.JPG")),
            sourceURL: sourceB.url.appending(path: "B1.JPG"),
            relativePath: MediaRelativePath(rawValue: "B1.JPG"),
            byteSize: 10,
            contentModifiedAt: Date(timeIntervalSince1970: 100),
            captureWallCompact: 20_250_102_120_000,
            mediaKind: .image,
            fileExtension: "JPG",
            companions: [],
            contentTypeIdentifier: "public.jpeg"
        )]
        let snapA = ImportPlanningSnapshot(
            generation: 1,
            sourceRoot: sourceA,
            destinationRoot: dest,
            sourceNamespaceRevision: 1,
            sourceNamingRevision: 0,
            destinationNamespaceRevision: 1,
            sourceMedia: mediaA,
            destinationOccupants: [:],
            policy: ImportPolicy(
                destinationFolderPolicy: .yearMonth,
                destinationNamePolicy: .captureDateTime,
                importSidecarFiles: false,
                deleteSourceAfterImport: false,
                autoEjectAfterImport: false
            ),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current
        )
        let snapB = ImportPlanningSnapshot(
            generation: 1,
            sourceRoot: sourceB,
            destinationRoot: dest,
            sourceNamespaceRevision: 1,
            sourceNamingRevision: 0,
            destinationNamespaceRevision: 1,
            sourceMedia: mediaB,
            destinationOccupants: [:],
            policy: ImportPolicy(
                destinationFolderPolicy: .yearMonth,
                destinationNamePolicy: .captureDateTime,
                importSidecarFiles: false,
                deleteSourceAfterImport: false,
                autoEjectAfterImport: false
            ),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current
        )

        let controlled = ControlledImportPlanBuilder()
        await controlled.suspendNextBuild(for: sourceA)
        await controlled.suspendNextBuild(for: sourceB)

        async let buildA = controlled.build(snapshot: snapA, additionalReserved: [])
        async let buildB = controlled.build(snapshot: snapB, additionalReserved: [])

        try await waitForPendingBuilderCount(controlled, source: sourceA, count: 1)
        try await waitForPendingBuilderCount(controlled, source: sourceB, count: 1)
        let pending = await controlled.pendingSources()
        #expect(pending.count == 2)
        #expect(pending.contains(sourceA))
        #expect(pending.contains(sourceB))

        await controlled.resumePendingBuild(for: sourceA)
        await controlled.resumePendingBuild(for: sourceB)

        let resultA = await buildA
        let resultB = await buildB
        #expect(resultA.plan.entries.count == 1)
        #expect(resultB.plan.entries.count == 1)
        #expect(resultA.plan.entries.first?.destination != resultB.plan.entries.first?.destination)
    }

    @Test func cancellingSuspendedBuildRecordsCancelAndReleasesContinuation() async throws {
        let source = LibraryRootPath(rawValue: "/Volumes/PLAN-BUILDER-CARD-C")
        let dest = try Self.makeDestination()
        let media = [PlanningFileFacts(
            id: MediaAssetID(libraryRootPath: source, relativePath: MediaRelativePath(rawValue: "C1.JPG")),
            sourceURL: source.url.appending(path: "C1.JPG"),
            relativePath: MediaRelativePath(rawValue: "C1.JPG"),
            byteSize: 10,
            contentModifiedAt: Date(timeIntervalSince1970: 100),
            captureWallCompact: 20_250_101_120_000,
            mediaKind: .image,
            fileExtension: "JPG",
            companions: [],
            contentTypeIdentifier: "public.jpeg"
        )]
        let snap = ImportPlanningSnapshot(
            generation: 1,
            sourceRoot: source,
            destinationRoot: dest,
            sourceNamespaceRevision: 1,
            sourceNamingRevision: 0,
            destinationNamespaceRevision: 1,
            sourceMedia: media,
            destinationOccupants: [:],
            policy: ImportPolicy(
                destinationFolderPolicy: .yearMonth,
                destinationNamePolicy: .captureDateTime,
                importSidecarFiles: false,
                deleteSourceAfterImport: false,
                autoEjectAfterImport: false
            ),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current
        )
        let controlled = ControlledImportPlanBuilder()
        await controlled.suspendNextBuild(for: source)

        let task = Task { await controlled.build(snapshot: snap, additionalReserved: []) }
        try await waitForPendingBuilder(controlled, source: source)
        let pendingBeforeCancellation = await controlled.pendingSources()
        #expect(pendingBeforeCancellation.contains(source))

        task.cancel()
        try await waitForCancellationSettled(controlled, source: source)

        let cancelled = await controlled.recordedCancelled()
        let pendingAfterCancellation = await controlled.pendingSources()
        #expect(cancelled.contains(source))
        #expect(!pendingAfterCancellation.contains(source))

        // A cancelled build yields a dummy that cannot install a plan.
        let result = await task.value
        #expect(result.plan.generation == snap.generation)
        #expect(result.plan.entries.isEmpty)
    }
}
