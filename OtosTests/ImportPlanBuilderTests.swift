import Foundation
@testable import OtosKit
import Testing

/// The live plan builder performs work off the coordinator actor and returns the plan
/// plus namespace counts and timing.
@Suite(.testScope)
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
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current,
            destinationCapabilities: .unknown
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
}
