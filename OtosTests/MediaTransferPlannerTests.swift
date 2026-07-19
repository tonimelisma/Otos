import Foundation
@testable import Otos
import Testing

struct MediaTransferPlannerTests {
    private static let source = LibraryRootPath(rawValue: "/tmp/card")
    private static let destination = LibraryRootPath(rawValue: "/tmp/library")

    private static func facts(
        name: String = "IMG_1.JPG",
        byteSize: Int64? = 10,
        modified: Date? = Date(timeIntervalSince1970: 100),
        captureWallCompact: Int64? = nil
    ) -> PlanningFileFacts {
        let relative = MediaRelativePath(rawValue: name)
        return PlanningFileFacts(
            id: MediaAssetID(libraryRootPath: source, relativePath: relative),
            sourceURL: source.url.appending(path: relative.rawValue),
            relativePath: relative,
            byteSize: byteSize,
            contentModifiedAt: modified,
            captureWallCompact: captureWallCompact,
            mediaKind: .image,
            fileExtension: "JPG",
            companions: [],
            contentTypeIdentifier: "public.jpeg"
        )
    }

    private static func snapshot(
        sourceMedia: [PlanningFileFacts],
        destinationOccupants: [MediaRelativePath: DestinationOccupantFacts] = [:],
        policy: ImportPolicy
    ) -> ImportPlanningSnapshot {
        ImportPlanningSnapshot(
            generation: 1,
            sourceRoot: source,
            destinationRoot: destination,
            sourceOccupancyRevision: 1,
            destinationOccupancyRevision: 1,
            sourceMedia: sourceMedia,
            destinationOccupants: destinationOccupants,
            knownForeignOccupants: [],
            policy: policy,
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current
        )
    }

    @Test func matchingLiveFactsSkipEvenWhenDestinationIsNotInCatalog() {
        let source = Self.facts()
        let relative = source.relativePath
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        let snapshot = Self.snapshot(
            sourceMedia: [source],
            destinationOccupants: [
                relative: DestinationOccupantFacts(
                    relativePath: relative,
                    byteSize: 999,
                    contentModifiedAt: Date(timeIntervalSince1970: 999)
                ),
            ],
            policy: policy
        )
        let request = NamespaceOccupancyRequest(rootPath: Self.destination, relativePath: relative)

        let outcome = MediaTransferPlanner.planImport(
            snapshot: snapshot,
            occupancy: [request: .regularFile(byteSize: 10, contentModifiedAt: source.contentModifiedAt)]
        )

        guard case let .ready(plan) = outcome else {
            Issue.record("matching live facts did not produce a ready plan")
            return
        }
        #expect(plan.entries[0].disposition == .skipPreexisting(destination: relative))
    }

    @Test func differentLiveSizeAdvancesTheWholeBundleSuffix() {
        let source = Self.facts(name: "a.jpg")
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        let snapshot = Self.snapshot(sourceMedia: [source], policy: policy)
        let ideal = source.relativePath
        let next = MediaRelativePath(rawValue: "a_001.jpg")
        let idealRequest = NamespaceOccupancyRequest(rootPath: Self.destination, relativePath: ideal)
        let nextRequest = NamespaceOccupancyRequest(rootPath: Self.destination, relativePath: next)

        let outcome = MediaTransferPlanner.planImport(
            snapshot: snapshot,
            occupancy: [
                idealRequest: .regularFile(byteSize: 11, contentModifiedAt: source.contentModifiedAt),
                nextRequest: .absent,
            ]
        )

        guard case let .ready(plan) = outcome else {
            Issue.record("size mismatch did not produce a ready plan")
            return
        }
        #expect(plan.entries[0].disposition == .copy(destination: next))
    }

    @Test func differentLiveMtimeAdvancesTheWholeBundleSuffix() {
        let source = Self.facts(name: "a.jpg", modified: Date(timeIntervalSince1970: 100))
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        let snapshot = Self.snapshot(sourceMedia: [source], policy: policy)
        let ideal = source.relativePath
        let next = MediaRelativePath(rawValue: "a_001.jpg")
        let idealRequest = NamespaceOccupancyRequest(rootPath: Self.destination, relativePath: ideal)
        let nextRequest = NamespaceOccupancyRequest(rootPath: Self.destination, relativePath: next)

        let outcome = MediaTransferPlanner.planImport(
            snapshot: snapshot,
            occupancy: [
                idealRequest: .regularFile(byteSize: 10, contentModifiedAt: Date(timeIntervalSince1970: 101)),
                nextRequest: .absent,
            ]
        )

        guard case let .ready(plan) = outcome else {
            Issue.record("mtime mismatch did not produce a ready plan")
            return
        }
        #expect(plan.entries[0].disposition == .copy(destination: next))
    }

    @Test func missingLiveMtimeDoesNotClaimPreexisting() {
        let source = Self.facts(name: "a.jpg")
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        let snapshot = Self.snapshot(sourceMedia: [source], policy: policy)
        let ideal = source.relativePath
        let next = MediaRelativePath(rawValue: "a_001.jpg")
        let idealRequest = NamespaceOccupancyRequest(rootPath: Self.destination, relativePath: ideal)
        let nextRequest = NamespaceOccupancyRequest(rootPath: Self.destination, relativePath: next)

        let outcome = MediaTransferPlanner.planImport(
            snapshot: snapshot,
            occupancy: [
                idealRequest: .regularFile(byteSize: 10, contentModifiedAt: nil),
                nextRequest: .absent,
            ]
        )

        guard case let .ready(plan) = outcome else {
            Issue.record("missing live mtime did not produce a ready plan")
            return
        }
        #expect(plan.entries[0].disposition == .copy(destination: next))
    }

    @Test func captureWallMtimeIsTheSharedExpectedDestinationFact() throws {
        let source = Self.facts(
            name: "IMG_1.JPG",
            modified: Date(timeIntervalSince1970: 50),
            captureWallCompact: 20_260_101_120_000
        )
        let expected = try #require(CaptureWallClock.date(fromCompact: 20_260_101_120_000))
        #expect(ImportDestinationDate.expected(for: source) == expected)

        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        let snapshot = Self.snapshot(sourceMedia: [source], policy: policy)
        let request = NamespaceOccupancyRequest(rootPath: Self.destination, relativePath: source.relativePath)
        let outcome = MediaTransferPlanner.planImport(
            snapshot: snapshot,
            occupancy: [request: .regularFile(byteSize: 10, contentModifiedAt: expected)]
        )

        guard case let .ready(plan) = outcome else {
            Issue.record("capture-wall mtime did not produce a ready plan")
            return
        }
        #expect(plan.entries[0].isSkipPreexisting)
    }

    @Test func rawSourceMtimeDoesNotSkipWhenCaptureWallMtimeDiffers() {
        let source = Self.facts(
            name: "IMG_1.JPG",
            modified: Date(timeIntervalSince1970: 50),
            captureWallCompact: 20_260_101_120_000
        )
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        let snapshot = Self.snapshot(sourceMedia: [source], policy: policy)
        let next = MediaRelativePath(rawValue: "IMG_1_001.JPG")
        let idealRequest = NamespaceOccupancyRequest(
            rootPath: Self.destination,
            relativePath: source.relativePath
        )
        let nextRequest = NamespaceOccupancyRequest(rootPath: Self.destination, relativePath: next)
        let outcome = MediaTransferPlanner.planImport(
            snapshot: snapshot,
            occupancy: [
                idealRequest: .regularFile(byteSize: 10, contentModifiedAt: source.contentModifiedAt),
                nextRequest: .absent,
            ]
        )

        guard case let .ready(plan) = outcome else {
            Issue.record("raw source mtime incorrectly produced a non-ready plan")
            return
        }
        #expect(plan.entries[0].disposition == .copy(destination: next))
    }

    @Test func copiesIntoYearMonthCaptureDateTimeName() {
        let source = Self.facts(
            name: "IMG_1.JPG",
            modified: Date(timeIntervalSince1970: 1_700_000_000),
            captureWallCompact: 20_260_101_120_000
        )
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .yearMonth
        policy.destinationNamePolicy = .captureDateTime
        let snapshot = Self.snapshot(sourceMedia: [source], policy: policy)
        let expected = MediaRelativePath(rawValue: "2026/01/20260101_120000.jpeg")
        let request = NamespaceOccupancyRequest(rootPath: Self.destination, relativePath: expected)

        let outcome = MediaTransferPlanner.planImport(snapshot: snapshot, occupancy: [request: .absent])
        guard case let .ready(plan) = outcome else {
            Issue.record("expected ready plan")
            return
        }
        #expect(plan.entries[0].finalDestination == expected)
    }

    @Test func blocksWhenNoUsableDate() {
        let source = Self.facts(name: "nodate.jpg", modified: nil, captureWallCompact: nil)
        let snapshot = Self.snapshot(sourceMedia: [source], policy: .from(.default))
        let outcome = MediaTransferPlanner.planImport(snapshot: snapshot)
        guard case let .ready(plan) = outcome else {
            Issue.record("expected ready blocked plan")
            return
        }
        #expect(plan.entries[0].disposition == .blocked(.noUsableDate))
    }

    @Test func foreignOccupantAdvancesSuffix() throws {
        let source = Self.facts(name: "a.jpg")
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        let snapshot = try ImportPlanningSnapshot(
            generation: 1,
            sourceRoot: Self.source,
            destinationRoot: Self.destination,
            sourceOccupancyRevision: 1,
            destinationOccupancyRevision: 1,
            sourceMedia: [source],
            destinationOccupants: [:],
            knownForeignOccupants: [source.relativePath],
            policy: policy,
            calendar: Calendar(identifier: .gregorian),
            timeZone: #require(TimeZone(secondsFromGMT: 0))
        )
        let next = MediaRelativePath(rawValue: "a_001.jpg")
        let nextRequest = NamespaceOccupancyRequest(rootPath: Self.destination, relativePath: next)
        let outcome = MediaTransferPlanner.planImport(snapshot: snapshot, occupancy: [nextRequest: .absent])
        guard case let .ready(plan) = outcome else {
            Issue.record("expected ready plan")
            return
        }
        #expect(plan.entries[0].finalDestination == next)
    }
}

struct FilesystemReconcilerScanRaceTests {
    @Test func activeScanStillClassifiesWhenUnarmedIsFalse() {
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
