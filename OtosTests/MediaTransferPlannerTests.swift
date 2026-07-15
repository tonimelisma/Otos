import Foundation
@testable import Otos
import Testing

struct MediaTransferPlannerTests {
    @Test func matchingImportProvenanceSkipsWithoutComparisonProbe() {
        let source = LibraryRootPath(rawValue: "/tmp/card")
        let destination = LibraryRootPath(rawValue: "/tmp/library")
        let relative = MediaRelativePath(rawValue: "IMG_1.JPG")
        let destinationRelative = MediaRelativePath(rawValue: "IMG_1.jpg")
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let facts = PlanningFileFacts(
            id: MediaAssetID(libraryRootPath: source, relativePath: relative),
            sourceURL: source.url.appending(path: relative.rawValue),
            relativePath: relative,
            byteSize: 10,
            contentModifiedAt: modified,
            captureWallCompact: nil,
            mediaKind: .image,
            fileExtension: "JPG",
            companions: []
        )
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        let occupant = DestinationOccupantFacts(
            relativePath: destinationRelative,
            byteSize: 10,
            contentModifiedAt: modified,
            importSourceRootPath: source,
            importSourceRelativePath: relative,
            importSourceByteSize: 10,
            importSourceModifiedAt: modified,
            importDestinationByteSize: 10,
            importDestinationModifiedAt: modified
        )
        let snapshot = ImportPlanningSnapshot(
            generation: 1,
            sourceRoot: source,
            destinationRoot: destination,
            sourceOccupancyRevision: 1,
            destinationOccupancyRevision: 1,
            sourceMedia: [facts],
            destinationOccupants: [destinationRelative: occupant],
            knownForeignOccupants: [],
            policy: policy,
            calendar: .current,
            timeZone: .current
        )
        let request = NamespaceOccupancyRequest(rootPath: destination, relativePath: destinationRelative)
        let outcome = MediaTransferPlanner.planImport(
            snapshot: snapshot,
            occupancy: [request: .regularFile(byteSize: 10, contentModifiedAt: modified)]
        )
        guard case let .ready(plan) = outcome else {
            Issue.record("matching provenance requested a byte comparison")
            return
        }
        #expect(plan.entries[0].disposition == .skipPreexisting(destination: destinationRelative))
    }

    @Test func changedSourceMtimeFallsBackToComparison() {
        let source = LibraryRootPath(rawValue: "/tmp/card")
        let destination = LibraryRootPath(rawValue: "/tmp/library")
        let relative = MediaRelativePath(rawValue: "a.jpg")
        let facts = PlanningFileFacts(
            id: MediaAssetID(libraryRootPath: source, relativePath: relative),
            sourceURL: source.url.appending(path: relative.rawValue),
            relativePath: relative,
            byteSize: 10,
            contentModifiedAt: Date(timeIntervalSince1970: 200),
            captureWallCompact: nil,
            mediaKind: .image,
            fileExtension: "jpg",
            companions: []
        )
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        let occupant = DestinationOccupantFacts(
            relativePath: relative,
            byteSize: 10,
            contentModifiedAt: Date(timeIntervalSince1970: 100),
            importSourceRootPath: source,
            importSourceRelativePath: relative,
            importSourceByteSize: 10,
            importSourceModifiedAt: Date(timeIntervalSince1970: 100),
            importDestinationByteSize: 10,
            importDestinationModifiedAt: Date(timeIntervalSince1970: 100)
        )
        let snapshot = ImportPlanningSnapshot(
            generation: 1, sourceRoot: source, destinationRoot: destination,
            sourceOccupancyRevision: 1, destinationOccupancyRevision: 1,
            sourceMedia: [facts], destinationOccupants: [relative: occupant],
            knownForeignOccupants: [], policy: policy, calendar: .current, timeZone: .current
        )
        let request = NamespaceOccupancyRequest(rootPath: destination, relativePath: relative)
        let outcome = MediaTransferPlanner.planImport(
            snapshot: snapshot,
            occupancy: [request: .regularFile(byteSize: 10, contentModifiedAt: nil)]
        )
        guard case let .needsProbes(_, comparisons) = outcome else {
            Issue.record("changed provenance did not fall back to comparison")
            return
        }
        #expect(comparisons.count == 1)
    }

    @Test func changedDestinationMtimeFallsBackToComparison() {
        let source = LibraryRootPath(rawValue: "/tmp/card")
        let destination = LibraryRootPath(rawValue: "/tmp/library")
        let relative = MediaRelativePath(rawValue: "a.jpg")
        let modified = Date(timeIntervalSince1970: 100)
        let facts = PlanningFileFacts(
            id: MediaAssetID(libraryRootPath: source, relativePath: relative),
            sourceURL: source.url.appending(path: relative.rawValue),
            relativePath: relative,
            byteSize: 10,
            contentModifiedAt: modified,
            captureWallCompact: nil,
            mediaKind: .image,
            fileExtension: "jpg",
            companions: []
        )
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        let occupant = DestinationOccupantFacts(
            relativePath: relative,
            byteSize: 10,
            contentModifiedAt: Date(timeIntervalSince1970: 200),
            importSourceRootPath: source,
            importSourceRelativePath: relative,
            importSourceByteSize: 10,
            importSourceModifiedAt: modified,
            importDestinationByteSize: 10,
            importDestinationModifiedAt: modified
        )
        let snapshot = ImportPlanningSnapshot(
            generation: 1, sourceRoot: source, destinationRoot: destination,
            sourceOccupancyRevision: 1, destinationOccupancyRevision: 1,
            sourceMedia: [facts], destinationOccupants: [relative: occupant],
            knownForeignOccupants: [], policy: policy, calendar: .current, timeZone: .current
        )
        let request = NamespaceOccupancyRequest(rootPath: destination, relativePath: relative)
        let outcome = MediaTransferPlanner.planImport(
            snapshot: snapshot,
            occupancy: [request: .regularFile(byteSize: 10, contentModifiedAt: nil)]
        )
        guard case let .needsProbes(_, comparisons) = outcome else {
            Issue.record("changed destination signature did not fall back to comparison")
            return
        }
        #expect(comparisons.count == 1)
    }

    @Test func copiesIntoYearMonthCaptureDateTimeName() throws {
        let source = LibraryRootPath(rawValue: "/tmp/source")
        let destination = LibraryRootPath(rawValue: "/tmp/destination")
        let relative = MediaRelativePath(rawValue: "IMG_1.JPG")
        let facts = PlanningFileFacts(
            id: MediaAssetID(libraryRootPath: source, relativePath: relative),
            sourceURL: URL(fileURLWithPath: "/tmp/source/IMG_1.JPG"),
            relativePath: relative,
            byteSize: 10,
            contentModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            captureWallCompact: 20_260_101_120_000,
            mediaKind: .image,
            fileExtension: "JPG",
            companions: []
        )
        let snapshot = try ImportPlanningSnapshot(
            generation: 1,
            sourceRoot: source,
            destinationRoot: destination,
            sourceOccupancyRevision: 1,
            destinationOccupancyRevision: 1,
            sourceMedia: [facts],
            destinationOccupants: [:],
            knownForeignOccupants: [],
            policy: ImportPolicy.from(.default),
            calendar: Calendar(identifier: .gregorian),
            timeZone: #require(TimeZone(secondsFromGMT: 0))
        )
        let occupancy: [NamespaceOccupancyRequest: NamespaceOccupancyResult] = [
            NamespaceOccupancyRequest(
                rootPath: destination,
                relativePath: MediaRelativePath(rawValue: "2026/01/20260101_120000.jpg")
            ): .absent,
        ]
        let outcome = MediaTransferPlanner.planImport(snapshot: snapshot, occupancy: occupancy)
        guard case let .ready(plan) = outcome else {
            Issue.record("expected ready plan")
            return
        }
        #expect(plan.entries.count == 1)
        #expect(plan.entries[0].finalDestination.rawValue == "2026/01/20260101_120000.jpg")
        #expect(plan.entries[0].disposition == .copy(destination: plan.entries[0].finalDestination))
        #expect(plan.totals.copyCount == 1)
    }

    @Test func advancesSuffixWhenDestinationOccupiedWithDifferentSize() throws {
        let source = LibraryRootPath(rawValue: "/tmp/source")
        let destination = LibraryRootPath(rawValue: "/tmp/destination")
        let relative = MediaRelativePath(rawValue: "a.jpg")
        let facts = PlanningFileFacts(
            id: MediaAssetID(libraryRootPath: source, relativePath: relative),
            sourceURL: URL(fileURLWithPath: "/tmp/source/a.jpg"),
            relativePath: relative,
            byteSize: 10,
            contentModifiedAt: Date(timeIntervalSince1970: 100),
            captureWallCompact: nil,
            mediaKind: .image,
            fileExtension: "jpg",
            companions: []
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let occupied = MediaRelativePath(rawValue: "1970/01/19700101_000140.jpg")
        let next = MediaRelativePath(rawValue: "1970/01/19700101_000140_001.jpg")
        let snapshot = try ImportPlanningSnapshot(
            generation: 1,
            sourceRoot: source,
            destinationRoot: destination,
            sourceOccupancyRevision: 1,
            destinationOccupancyRevision: 1,
            sourceMedia: [facts],
            destinationOccupants: [
                occupied: DestinationOccupantFacts(
                    relativePath: occupied,
                    byteSize: 99,
                    contentModifiedAt: nil
                ),
            ],
            knownForeignOccupants: [],
            policy: ImportPolicy.from(.default),
            calendar: calendar,
            timeZone: #require(TimeZone(secondsFromGMT: 0))
        )
        let occupancy: [NamespaceOccupancyRequest: NamespaceOccupancyResult] = [
            NamespaceOccupancyRequest(rootPath: destination, relativePath: occupied): .regularFile(
                byteSize: 99,
                contentModifiedAt: nil
            ),
            NamespaceOccupancyRequest(rootPath: destination, relativePath: next): .absent,
        ]
        let outcome = MediaTransferPlanner.planImport(snapshot: snapshot, occupancy: occupancy)
        guard case let .ready(plan) = outcome else {
            Issue.record("expected ready plan")
            return
        }
        #expect(plan.entries[0].finalDestination == next)
    }

    @Test func skipsEqualSizeEqualBytes() throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let sourceFile = temp.appending(path: "source.jpg")
        let destinationFile = temp.appending(path: "dest.jpg")
        let bytes = Data("identical-bytes".utf8)
        try bytes.write(to: sourceFile)
        try bytes.write(to: destinationFile)

        let source = LibraryRootPath(rawValue: temp.path(percentEncoded: false))
        let destination = source
        let relative = MediaRelativePath(rawValue: "source.jpg")
        let destRelative = MediaRelativePath(rawValue: "dest.jpg")
        let facts = PlanningFileFacts(
            id: MediaAssetID(libraryRootPath: source, relativePath: relative),
            sourceURL: sourceFile,
            relativePath: relative,
            byteSize: Int64(bytes.count),
            contentModifiedAt: Date(timeIntervalSince1970: 50),
            captureWallCompact: nil,
            mediaKind: .image,
            fileExtension: "jpg",
            companions: []
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        // Force original naming into the destination root so dest.jpg is the ideal.
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        let snapshot = try ImportPlanningSnapshot(
            generation: 1,
            sourceRoot: source,
            destinationRoot: destination,
            sourceOccupancyRevision: 1,
            destinationOccupancyRevision: 1,
            sourceMedia: [facts],
            destinationOccupants: [
                destRelative: DestinationOccupantFacts(
                    relativePath: destRelative,
                    byteSize: Int64(bytes.count),
                    contentModifiedAt: nil
                ),
            ],
            knownForeignOccupants: [],
            policy: policy,
            calendar: calendar,
            timeZone: #require(TimeZone(secondsFromGMT: 0))
        )
        // Ideal for original name of source.jpg is source.jpg — put equal file there.
        let ideal = MediaRelativePath(rawValue: "source.jpg")
        try bytes.write(to: temp.appending(path: "source.jpg"))
        let occupantsIdeal = DestinationOccupantFacts(
            relativePath: ideal,
            byteSize: Int64(bytes.count),
            contentModifiedAt: nil
        )
        let equalSnapshot = try ImportPlanningSnapshot(
            generation: 1,
            sourceRoot: source,
            destinationRoot: destination,
            sourceOccupancyRevision: 1,
            destinationOccupancyRevision: 1,
            sourceMedia: [facts],
            destinationOccupants: [ideal: occupantsIdeal],
            knownForeignOccupants: [],
            policy: policy,
            calendar: calendar,
            timeZone: #require(TimeZone(secondsFromGMT: 0))
        )
        let plan = MediaTransferPlanner.buildImportPlan(
            snapshot: equalSnapshot,
            equality: ContentEqualityChecker(authorizeMaterialization: true)
        )
        #expect(plan.entries[0].disposition == .skipPreexisting(destination: ideal))
        #expect(plan.totals.skipCount == 1)
        _ = destinationFile
        _ = destRelative
    }

    @Test func blocksWhenNoUsableDate() {
        let source = LibraryRootPath(rawValue: "/tmp/source")
        let destination = LibraryRootPath(rawValue: "/tmp/destination")
        let relative = MediaRelativePath(rawValue: "nodate.jpg")
        let facts = PlanningFileFacts(
            id: MediaAssetID(libraryRootPath: source, relativePath: relative),
            sourceURL: URL(fileURLWithPath: "/tmp/source/nodate.jpg"),
            relativePath: relative,
            byteSize: 1,
            contentModifiedAt: nil,
            captureWallCompact: nil,
            mediaKind: .image,
            fileExtension: "jpg",
            companions: []
        )
        let snapshot = ImportPlanningSnapshot(
            generation: 1,
            sourceRoot: source,
            destinationRoot: destination,
            sourceOccupancyRevision: 1,
            destinationOccupancyRevision: 1,
            sourceMedia: [facts],
            destinationOccupants: [:],
            knownForeignOccupants: [],
            policy: ImportPolicy.from(.default),
            calendar: .current,
            timeZone: .current
        )
        let outcome = MediaTransferPlanner.planImport(snapshot: snapshot, occupancy: [:])
        guard case let .ready(plan) = outcome else {
            Issue.record("expected ready blocked plan")
            return
        }
        #expect(plan.entries[0].disposition == .blocked(.noUsableDate))
        #expect(plan.totals.blockedCount == 1)
    }

    @Test func foreignOccupantAdvancesSuffix() throws {
        let source = LibraryRootPath(rawValue: "/tmp/source")
        let destination = LibraryRootPath(rawValue: "/tmp/destination")
        let relative = MediaRelativePath(rawValue: "a.jpg")
        let facts = PlanningFileFacts(
            id: MediaAssetID(libraryRootPath: source, relativePath: relative),
            sourceURL: URL(fileURLWithPath: "/tmp/source/a.jpg"),
            relativePath: relative,
            byteSize: 10,
            contentModifiedAt: Date(timeIntervalSince1970: 100),
            captureWallCompact: nil,
            mediaKind: .image,
            fileExtension: "jpg",
            companions: []
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        let ideal = MediaRelativePath(rawValue: "a.jpg")
        let next = MediaRelativePath(rawValue: "a_001.jpg")
        let snapshot = try ImportPlanningSnapshot(
            generation: 1,
            sourceRoot: source,
            destinationRoot: destination,
            sourceOccupancyRevision: 1,
            destinationOccupancyRevision: 1,
            sourceMedia: [facts],
            destinationOccupants: [:],
            knownForeignOccupants: [ideal],
            policy: policy,
            calendar: calendar,
            timeZone: #require(TimeZone(secondsFromGMT: 0))
        )
        let occupancy: [NamespaceOccupancyRequest: NamespaceOccupancyResult] = [
            NamespaceOccupancyRequest(rootPath: destination, relativePath: ideal): .foreign(kind: .knownForeignFact),
            NamespaceOccupancyRequest(rootPath: destination, relativePath: next): .absent,
        ]
        let outcome = MediaTransferPlanner.planImport(snapshot: snapshot, occupancy: occupancy)
        guard case let .ready(plan) = outcome else {
            Issue.record("expected ready plan")
            return
        }
        #expect(plan.entries[0].finalDestination == next)
    }
}

struct FilesystemReconcilerScanRaceTests {
    @Test func activeScanStillClassifiesWhenUnarmedIsFalse() {
        // Active-scan ownership no longer collapses events to a root deferral.
        // Unarmed roots still drop; armed roots accumulate typed scopes.
        let decision = FilesystemReconciler.decide(
            events: [
                FilesystemEvent(
                    path: "/tmp/root/a.jpg",
                    flags: UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
                ),
            ],
            root: LibraryRootPath(rawValue: "/tmp/root"),
            rootExists: true,
            isArmed: true,
            isAvailable: true
        )
        guard case let .accumulate(scopes) = decision else {
            Issue.record("expected accumulate")
            return
        }
        #expect(scopes.first?.scope == .file(MediaRelativePath(rawValue: "a.jpg")))
    }

    @Test func unarmedDropsEvenWithFileEvents() {
        let decision = FilesystemReconciler.decide(
            events: [FilesystemEvent(path: "/tmp/root/a.jpg", flags: 0)],
            root: LibraryRootPath(rawValue: "/tmp/root"),
            rootExists: true,
            isArmed: false,
            isAvailable: true
        )
        #expect(decision == .drop(reason: "unarmed"))
    }
}

struct ContentEqualityCheckerTests {
    @Test func memoReusesVerdictAcrossCalls() throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let left = temp.appending(path: "a.bin")
        let right = temp.appending(path: "b.bin")
        try Data("same".utf8).write(to: left)
        try Data("same".utf8).write(to: right)
        let checker = ContentEqualityChecker(authorizeMaterialization: true)
        let request = ComparisonRequest(
            sourceRoot: LibraryRootPath(rawValue: temp.path),
            sourceRelativePath: MediaRelativePath(rawValue: "a.bin"),
            sourceByteSize: 4,
            sourceModifiedAt: nil,
            destinationRoot: LibraryRootPath(rawValue: temp.path),
            destinationRelativePath: MediaRelativePath(rawValue: "b.bin"),
            destinationByteSize: 4,
            destinationModifiedAt: nil,
            sourceURL: left,
            destinationURL: right
        )
        #expect(checker.result(for: request) == .equal)
        try Data("diff".utf8).write(to: right)
        // Memo keyed by size/mtime facts — unchanged facts reuse equal verdict.
        #expect(checker.result(for: request) == .equal)
    }
}
