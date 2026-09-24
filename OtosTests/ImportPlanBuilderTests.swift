import Foundation
@testable import OtosKit
import Testing

/// The plan-building boundary is a real substitution seam.
/// The live builder remains `Sendable`, performs work off the coordinator actor,
/// and returns plan plus namespace counts and timing. The controlled builder
/// records requests, suspends selected builds, resumes with real results, and
/// records cancellation without assuming cancellation ends the continuation.
struct ImportPlanBuilderTests {
    private static let destRoot = LibraryRootPath(rawValue: "/tmp/library")
    private static let sourceRoot = LibraryRootPath(rawValue: "/tmp/card")

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
        dest: LibraryRootPath = destRoot,
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
            // swiftlint:disable:next line_length
            policy: ImportPolicy(destinationFolderPolicy: .yearMonth, destinationNamePolicy: .captureDateTime, importSidecarFiles: false, deleteSourceAfterImport: false, autoEjectAfterImport: false),
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current
        )
    }

    @Test func liveBuilderProducesSameOutputAsDirectEnumerationAndPlanner() async {
        // swiftlint:disable:next line_length
        let media = [Self.facts(name: "IMG_001.JPG", captureWallCompact: 20_250_101_120_000), Self.facts(name: "IMG_002.JPG", captureWallCompact: 20_250_102_120_000)]
        let snapshot = Self.snapshot(sourceMedia: media)
        let live = LiveImportPlanBuilder()
        let viaBuilder = await live.build(snapshot: snapshot, additionalReserved: [])
        // Direct enumeration + planner
        let folders = MediaTransferPlanner.destinationFolders(for: snapshot)
        let namespace = FilesystemNamespaceSemantics.enumerateNamespace(root: Self.destRoot, folders: folders)
        let directPlan = MediaTransferPlanner.planImport(snapshot: snapshot, namespace: namespace, additionalReserved: [])
        #expect(viaBuilder.plan.entries.count == directPlan.entries.count)
        #expect(viaBuilder.namespace.entryCount == namespace.entryCount)
        #expect(viaBuilder.namespace.folderCount == namespace.folderCount)
        #expect(viaBuilder.plan.totals.copyCount == directPlan.totals.copyCount)
    }

    @Test func controlledBuilderCanSuspendAndResumeTwoIndependentBuilds() async throws {
        // Use distinct source roots so the builder can suspend each independently.
        let sourceA = LibraryRootPath(rawValue: "/tmp/cardA")
        let sourceB = LibraryRootPath(rawValue: "/tmp/cardB")
        let dest = Self.destRoot
        // swiftlint:disable:next line_length
        let mediaA = [PlanningFileFacts(id: MediaAssetID(libraryRootPath: sourceA, relativePath: MediaRelativePath(rawValue: "A1.JPG")), sourceURL: sourceA.url.appending(path: "A1.JPG"), relativePath: MediaRelativePath(rawValue: "A1.JPG"), byteSize: 10, contentModifiedAt: Date(timeIntervalSince1970: 100), captureWallCompact: 20_250_101_120_000, mediaKind: .image, fileExtension: "JPG", companions: [], contentTypeIdentifier: "public.jpeg")]
        // swiftlint:disable:next line_length
        let mediaB = [PlanningFileFacts(id: MediaAssetID(libraryRootPath: sourceB, relativePath: MediaRelativePath(rawValue: "B1.JPG")), sourceURL: sourceB.url.appending(path: "B1.JPG"), relativePath: MediaRelativePath(rawValue: "B1.JPG"), byteSize: 10, contentModifiedAt: Date(timeIntervalSince1970: 100), captureWallCompact: 20_250_102_120_000, mediaKind: .image, fileExtension: "JPG", companions: [], contentTypeIdentifier: "public.jpeg")]
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
        #expect(resultA.plan.entries.first?.finalDestination != resultB.plan.entries.first?.finalDestination)
    }

    @Test func cancellingSuspendedBuildRecordsCancelAndReleasesContinuation() async throws {
        let source = LibraryRootPath(rawValue: "/tmp/cardC")
        let dest = Self.destRoot
        // swiftlint:disable:next line_length
        let media = [PlanningFileFacts(id: MediaAssetID(libraryRootPath: source, relativePath: MediaRelativePath(rawValue: "C1.JPG")), sourceURL: source.url.appending(path: "C1.JPG"), relativePath: MediaRelativePath(rawValue: "C1.JPG"), byteSize: 10, contentModifiedAt: Date(timeIntervalSince1970: 100), captureWallCompact: 20_250_101_120_000, mediaKind: .image, fileExtension: "JPG", companions: [], contentTypeIdentifier: "public.jpeg")]
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
