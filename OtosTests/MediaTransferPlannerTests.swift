import Foundation
@testable import OtosKit
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
            // Derived from `name`, not hardcoded: the planner builds destination
            // candidates from this extension verbatim (see `destinationExtension`),
            // so a fixture whose extension case disagrees with its own name produces
            // a candidate the fixture's own expectations never match.
            fileExtension: (name as NSString).pathExtension,
            companions: [],
            contentTypeIdentifier: "public.jpeg"
        )
    }

    private static func snapshot(
        sourceMedia: [PlanningFileFacts],
        destinationRoot: LibraryRootPath = destination,
        destinationOccupants: [MediaRelativePath: DestinationOccupantFacts] = [:],
        policy: ImportPolicy
    ) -> ImportPlanningSnapshot {
        ImportPlanningSnapshot(
            generation: 1,
            sourceRoot: source,
            destinationRoot: destinationRoot,
            sourceOccupancyRevision: 1,
            destinationOccupancyRevision: 1,
            sourceMedia: sourceMedia,
            destinationOccupants: destinationOccupants,
            policy: policy,
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current
        )
    }

    /// Namespace whose enumerated folders are derived from the entries themselves
    /// plus the destination root, so an omitted entry reads as a proven-free name
    /// rather than an unread folder.
    private static func namespace(
        _ entries: [MediaRelativePath: NamespaceOccupancyResult] = [:],
        folders: Set<String> = [""]
    ) -> DestinationNamespace {
        DestinationNamespace(
            entries: entries,
            enumeratedFolders: folders.union(entries.keys.map(DestinationNamespace.folder(of:)))
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
        let plan = MediaTransferPlanner.planImport(
            snapshot: snapshot,
            namespace: Self.namespace([
                relative: .regularFile(byteSize: 10, contentModifiedAt: source.contentModifiedAt),
            ])
        )

        #expect(plan.entries[0].disposition == .skipPreexisting(destination: relative))
    }

    /// Exercises `buildImportPlan`, the entry point production actually calls,
    /// against a real destination directory rather than a hand-fed namespace.
    /// `planImport` is the pure pass over an already-read namespace; a live-mismatch
    /// scenario like this one is only observable at the boundary that reads the
    /// destination folders off the filesystem.
    @Test func differentLiveSizeAdvancesTheWholeBundleSuffix() throws {
        let destinationDir = try makeCatalogStoreTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destinationDir) }
        let destinationRoot = LibraryRootPath(rawValue: destinationDir.path)

        let source = Self.facts(name: "a.jpg")
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        let snapshot = Self.snapshot(sourceMedia: [source], destinationRoot: destinationRoot, policy: policy)
        let next = MediaRelativePath(rawValue: "a_001.jpg")

        let idealFile = destinationDir.appending(path: source.relativePath.rawValue)
        let modifiedAt = try #require(source.contentModifiedAt)
        try Data(repeating: 0, count: 11).write(to: idealFile)
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: idealFile.path
        )

        let plan = MediaTransferPlanner.buildImportPlan(snapshot: snapshot)
        #expect(plan.entries[0].disposition == .copy(destination: next))
    }

    @Test func differentLiveMtimeAdvancesTheWholeBundleSuffix() throws {
        let destinationDir = try makeCatalogStoreTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destinationDir) }
        let destinationRoot = LibraryRootPath(rawValue: destinationDir.path)

        let source = Self.facts(name: "a.jpg", modified: Date(timeIntervalSince1970: 100))
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        let snapshot = Self.snapshot(sourceMedia: [source], destinationRoot: destinationRoot, policy: policy)
        let next = MediaRelativePath(rawValue: "a_001.jpg")

        let idealFile = destinationDir.appending(path: source.relativePath.rawValue)
        try Data(repeating: 0, count: 10).write(to: idealFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 101)],
            ofItemAtPath: idealFile.path
        )

        let plan = MediaTransferPlanner.buildImportPlan(snapshot: snapshot)
        #expect(plan.entries[0].disposition == .copy(destination: next))
    }

    /// Stays on `planImport` with a directly injected `NamespaceOccupancyResult`
    /// rather than `buildImportPlan`: a real regular file's mtime is unreadable only
    /// when `resourceValues` throws (for example a race where the file vanishes
    /// between the `lstat` and the resource-values read), which a test cannot
    /// deterministically reproduce on disk. `.regularFile(byteSize:contentModifiedAt:
    /// nil)` is itself a documented, legitimate case of that public value type, so
    /// injecting it directly into the pure planning function is the only reachable way
    /// to exercise `catalogDecision`'s handling of it.
    @Test func missingLiveMtimeDoesNotClaimPreexisting() {
        let source = Self.facts(name: "a.jpg")
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        let snapshot = Self.snapshot(sourceMedia: [source], policy: policy)
        let ideal = source.relativePath
        let next = MediaRelativePath(rawValue: "a_001.jpg")

        let plan = MediaTransferPlanner.planImport(
            snapshot: snapshot,
            namespace: Self.namespace([ideal: .regularFile(byteSize: 10, contentModifiedAt: nil)])
        )

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
        let plan = MediaTransferPlanner.planImport(
            snapshot: snapshot,
            namespace: Self.namespace([
                source.relativePath: .regularFile(byteSize: 10, contentModifiedAt: expected),
            ])
        )

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
        let plan = MediaTransferPlanner.planImport(
            snapshot: snapshot,
            namespace: Self.namespace([
                source.relativePath: .regularFile(
                    byteSize: 10,
                    contentModifiedAt: source.contentModifiedAt
                ),
            ])
        )

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

        let plan = MediaTransferPlanner.planImport(
            snapshot: snapshot,
            namespace: Self.namespace(folders: ["2026/01"])
        )
        #expect(plan.entries[0].finalDestination == expected)
    }

    @Test func blocksWhenNoUsableDate() {
        let source = Self.facts(name: "nodate.jpg", modified: nil, captureWallCompact: nil)
        let snapshot = Self.snapshot(sourceMedia: [source], policy: .from(.default))
        let plan = MediaTransferPlanner.planImport(snapshot: snapshot, namespace: Self.namespace())
        #expect(plan.entries[0].disposition == .blocked(.noUsableDate))
    }

    @Test func concurrentPlansIntoOneDestinationClaimDisjointNames() {
        let first = Self.facts(name: "same.jpg")
        let second = Self.facts(name: "same.jpg")
        let firstPlan = MediaTransferPlanner.planImport(
            snapshot: Self.snapshot(sourceMedia: [first], policy: .from(.default)),
            namespace: Self.namespace()
        )
        let secondPlan = MediaTransferPlanner.planImport(
            snapshot: Self.snapshot(sourceMedia: [second], policy: .from(.default)),
            namespace: Self.namespace(),
            additionalReserved: Set(firstPlan.entries.map(\.finalDestination))
        )

        #expect(Set(firstPlan.entries.map(\.finalDestination)).isDisjoint(with: secondPlan.entries.map(\.finalDestination)))
    }

    @Test func conflictingPublishReplansAndNeverEvicts() {
        let source = Self.facts(name: "same.jpg")
        let snapshot = Self.snapshot(sourceMedia: [source], policy: .from(.default))
        let winner = MediaTransferPlanner.planImport(snapshot: snapshot, namespace: Self.namespace())
        let loserStart = MediaTransferPlanner.planImport(snapshot: snapshot, namespace: Self.namespace())
        let loserReplanned = MediaTransferPlanner.planImport(
            snapshot: snapshot,
            namespace: Self.namespace(),
            additionalReserved: Set(winner.entries.map(\.finalDestination))
        )

        #expect(loserStart.entries[0].finalDestination == winner.entries[0].finalDestination)
        #expect(loserReplanned.entries[0].finalDestination != winner.entries[0].finalDestination)
        #expect(winner.entries[0].finalDestination != loserReplanned.entries[0].finalDestination)
    }

    @Test func claimIsReleasedOnDetach() {
        let source = Self.facts(name: "same.jpg")
        let snapshot = Self.snapshot(sourceMedia: [source], policy: .from(.default))
        let first = MediaTransferPlanner.planImport(snapshot: snapshot, namespace: Self.namespace())
        let released = MediaTransferPlanner.planImport(snapshot: snapshot, namespace: Self.namespace())

        #expect(released.entries[0].finalDestination == first.entries[0].finalDestination)
    }

    @Test func claimIsReleasedOnCancel() {
        let source = Self.facts(name: "same.jpg")
        let snapshot = Self.snapshot(sourceMedia: [source], policy: .from(.default))
        let first = MediaTransferPlanner.planImport(snapshot: snapshot, namespace: Self.namespace())
        let afterCancel = MediaTransferPlanner.planImport(snapshot: snapshot, namespace: Self.namespace())

        #expect(afterCancel.entries[0].finalDestination == first.entries[0].finalDestination)
    }

    @Test func claimIsReleasedOnFailure() {
        let source = Self.facts(name: "same.jpg")
        let snapshot = Self.snapshot(sourceMedia: [source], policy: .from(.default))
        let first = MediaTransferPlanner.planImport(snapshot: snapshot, namespace: Self.namespace())
        let afterFailure = MediaTransferPlanner.planImport(snapshot: snapshot, namespace: Self.namespace())

        #expect(afterFailure.entries[0].finalDestination == first.entries[0].finalDestination)
    }

    @Test func settledNameIsObservedAsOccupancyByNextBuild() {
        let source = Self.facts(name: "same.jpg")
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        let snapshot = Self.snapshot(sourceMedia: [source], policy: policy)
        let occupied = MediaTransferPlanner.planImport(snapshot: snapshot, namespace: Self.namespace())
        let settledName = occupied.entries[0].finalDestination
        let next = MediaTransferPlanner.planImport(
            snapshot: snapshot,
            namespace: Self.namespace([settledName: .foreign(kind: .other)])
        )

        #expect(next.entries[0].finalDestination != settledName)
    }

    @Test func conflictCheckUsesCurrentLedgerNotBuildStartSnapshot() {
        let source = Self.facts(name: "same.jpg")
        let snapshot = Self.snapshot(sourceMedia: [source], policy: .from(.default))
        let buildStart = MediaTransferPlanner.planImport(snapshot: snapshot, namespace: Self.namespace())
        let currentLedger = Set(buildStart.entries.map(\.finalDestination))
        let resumed = MediaTransferPlanner.planImport(
            snapshot: snapshot,
            namespace: Self.namespace(),
            additionalReserved: currentLedger
        )

        #expect(resumed.entries[0].finalDestination != buildStart.entries[0].finalDestination)
    }

    @Test func policyThatNeverConsultsDateDoesNotWait() {
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        #expect(!MediaTransferPlanner.needsDate(policy: policy))

        let undated = Self.facts(name: "undated.jpg", modified: nil, captureWallCompact: nil)
        let plan = MediaTransferPlanner.planImport(
            snapshot: Self.snapshot(sourceMedia: [undated], policy: policy),
            namespace: Self.namespace()
        )
        if case .blocked = plan.entries[0].disposition {
            Issue.record("expected entry not to be blocked")
        }
    }

    /// A directory standing where a candidate file would go is foreign occupancy that
    /// only a live read can see. Enumeration finds it without anyone having asked
    /// about that specific path.
    @Test func foreignOccupantAdvancesSuffix() throws {
        let destinationDir = try makeCatalogStoreTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destinationDir) }
        let destinationRoot = LibraryRootPath(rawValue: destinationDir.path)

        let source = Self.facts(name: "a.jpg")
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        let snapshot = Self.snapshot(
            sourceMedia: [source],
            destinationRoot: destinationRoot,
            policy: policy
        )
        let next = MediaRelativePath(rawValue: "a_001.jpg")
        try FileManager.default.createDirectory(
            at: destinationDir.appending(path: "a.jpg"),
            withIntermediateDirectories: false
        )

        let plan = MediaTransferPlanner.buildImportPlan(snapshot: snapshot)
        #expect(plan.entries[0].finalDestination == next)
    }

    /// The invariant that makes planning one pass: the folders declared before any
    /// I/O cover every destination the plan actually chooses, suffix retries included.
    /// If a candidate could ever land outside this set, a single enumeration would no
    /// longer be sufficient and the planner would need a second round.
    @Test func declaredFoldersCoverEveryChosenDestination() {
        let sources = [
            Self.facts(name: "a.jpg", captureWallCompact: 20_260_101_120_000),
            Self.facts(name: "b.jpg", captureWallCompact: 20_260_101_120_000),
            Self.facts(name: "c.jpg", captureWallCompact: 20_260_215_090_000),
            Self.facts(name: "d.jpg", captureWallCompact: 20_260_331_235_959),
        ]
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .yearMonth
        policy.destinationNamePolicy = .captureDateTime
        let snapshot = Self.snapshot(sourceMedia: sources, policy: policy)

        let folders = MediaTransferPlanner.destinationFolders(for: snapshot)
        #expect(folders == ["2026/01", "2026/02", "2026/03"])

        // `a` and `b` share a capture second, so `b` must take a suffix — the case
        // that used to demand another probe round.
        let plan = MediaTransferPlanner.planImport(
            snapshot: snapshot,
            namespace: Self.namespace(folders: folders)
        )
        #expect(plan.entries.count == 4)
        for entry in plan.entries {
            #expect(folders.contains(DestinationNamespace.folder(of: entry.finalDestination)))
            if case .blocked = entry.disposition {
                Issue.record("expected entry not to be blocked")
            }
        }
        #expect(Set(plan.entries.map(\.finalDestination)).count == 4)
    }

    /// An unreadable destination folder must never read as free space. Planning an
    /// overwrite on an unread namespace is the one failure this design could
    /// introduce, so absence is a claim only an enumerated folder can support.
    @Test func unreadableDestinationFolderBlocksInsteadOfCopying() {
        let source = Self.facts(name: "a.jpg", captureWallCompact: 20_260_101_120_000)
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .yearMonth
        policy.destinationNamePolicy = .captureDateTime
        let snapshot = Self.snapshot(sourceMedia: [source], policy: policy)

        let plan = MediaTransferPlanner.planImport(
            snapshot: snapshot,
            namespace: DestinationNamespace(entries: [:], enumeratedFolders: [])
        )

        guard case .blocked = plan.entries[0].disposition else {
            Issue.record("expected entry to be blocked")
            return
        }
        #expect(plan.totals.copyCount == 0)
    }

    /// A folder that does not exist yet is still fully observed: every candidate in it
    /// is free. This is the first import into a fresh `YYYY/MM`.
    @Test func absentDestinationFolderPlansCopies() throws {
        let destinationDir = try makeCatalogStoreTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destinationDir) }

        let source = Self.facts(name: "a.jpg", captureWallCompact: 20_260_101_120_000)
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .yearMonth
        policy.destinationNamePolicy = .captureDateTime
        let snapshot = Self.snapshot(
            sourceMedia: [source],
            destinationRoot: LibraryRootPath(rawValue: destinationDir.path),
            policy: policy
        )

        let plan = MediaTransferPlanner.buildImportPlan(snapshot: snapshot)
        #expect(plan.entries[0].disposition == .copy(
            destination: MediaRelativePath(rawValue: "2026/01/20260101_120000.jpeg")
        ))
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
