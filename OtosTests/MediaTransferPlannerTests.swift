import Foundation
import GRDB
@testable import OtosKit
import Testing

@Suite(.testScope)
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
            fileExtension: relative.fileExtension,
            companions: [],
            contentTypeIdentifier: "public.jpeg"
        )
    }

    private static func snapshot(
        sourceMedia: [PlanningFileFacts],
        destinationRoot: LibraryRootPath = destination,
        destinationOccupants: [MediaRelativePath: DestinationOccupantFacts] = [:],
        libraryContent: [ContentDigest: LibraryRootPath] = [:],
        policy: ImportPolicy
    ) -> ImportPlanningSnapshot {
        ImportPlanningSnapshot(
            generation: 1,
            sourceRoot: source,
            destinationRoot: destinationRoot,
            sourceNamespaceRevision: 1,
            sourceNamingRevision: 0,
            destinationNamespaceRevision: 1,
            sourceMedia: sourceMedia,
            destinationOccupants: destinationOccupants,
            libraryContent: libraryContent,
            policy: policy,
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current,
            destinationCapabilities: .unknown
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
            enumeratedFolders: folders.union(entries.keys.map(DestinationNamespace.folder(of:))),
            capabilities: .unknown
        )
    }

    /// A copy whose size is unknown is counted as unknown, never as zero bytes, so the
    /// plan's byte total says it is a lower bound.
    @Test func aCopyWithAnUnknownSizeIsCountedAsUnknown() {
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        let snapshot = Self.snapshot(
            sourceMedia: [Self.facts(name: "A.JPG", byteSize: 10), Self.facts(name: "B.JPG", byteSize: nil)],
            policy: policy
        )
        let plan = MediaTransferPlanner.planImport(snapshot: snapshot, namespace: Self.namespace())
        #expect(plan.totals.copyCount == 2)
        #expect(plan.totals.copyByteCount == PartialByteCount(knownBytes: 10, unknownCount: 1))
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

    @Test func caseInsensitiveDestinationDoesNotPlanCaseOnlyCopy() {
        let source = Self.facts(name: "IMG_1.JPG")
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        let snapshot = Self.snapshot(
            sourceMedia: [source],
            destinationOccupants: [
                MediaRelativePath(rawValue: "img_1.jpg"): DestinationOccupantFacts(
                    relativePath: MediaRelativePath(rawValue: "img_1.jpg"),
                    byteSize: 10,
                    contentModifiedAt: source.contentModifiedAt
                ),
            ],
            policy: policy
        )
        let plan = MediaTransferPlanner.planImport(
            snapshot: snapshot,
            namespace: Self.namespace([
                MediaRelativePath(rawValue: "img_1.jpg"): .regularFile(
                    byteSize: 10,
                    contentModifiedAt: source.contentModifiedAt
                ),
            ])
        )
        #expect(plan.entries[0].disposition == .skipPreexisting(destination: source.relativePath))
    }

    @Test func caseSensitiveDestinationAllowsCaseOnlyCopy() {
        let source = Self.facts(name: "IMG_1.JPG")
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        let snapshot = Self.snapshot(
            sourceMedia: [source],
            destinationOccupants: [
                MediaRelativePath(rawValue: "img_1.jpg"): DestinationOccupantFacts(
                    relativePath: MediaRelativePath(rawValue: "img_1.jpg"),
                    byteSize: 10,
                    contentModifiedAt: source.contentModifiedAt
                ),
            ],
            policy: policy
        )
        let caseSensitive = ImportPlanningSnapshot(
            generation: snapshot.generation,
            sourceRoot: snapshot.sourceRoot,
            destinationRoot: snapshot.destinationRoot,
            sourceNamespaceRevision: snapshot.sourceNamespaceRevision,
            sourceNamingRevision: 0,
            destinationNamespaceRevision: snapshot.destinationNamespaceRevision,
            sourceMedia: snapshot.sourceMedia,
            destinationOccupants: snapshot.destinationOccupants,
            policy: snapshot.policy,
            calendar: snapshot.calendar,
            timeZone: snapshot.timeZone,
            destinationCapabilities: .caseSensitive
        )
        let plan = MediaTransferPlanner.planImport(
            snapshot: caseSensitive,
            namespace: DestinationNamespace(
                entries: [
                    MediaRelativePath(rawValue: "img_1.jpg"): .regularFile(
                        byteSize: 10,
                        contentModifiedAt: source.contentModifiedAt
                    ),
                ],
                enumeratedFolders: [""],
                capabilities: .caseSensitive
            )
        )
        #expect(plan.entries[0].disposition == .copy(destination: source.relativePath))
    }

    @Test func zeroByteMediaIsExcludedFromCopyAndNaming() {
        let source = Self.facts(name: "empty.jpg", byteSize: 0)
        let plan = MediaTransferPlanner.planImport(
            snapshot: Self.snapshot(sourceMedia: [source], policy: ImportPolicy.from(.default)),
            namespace: Self.namespace()
        )
        #expect(plan.entries[0].disposition == .excluded(.empty))
        #expect(plan.totals.copyCount == 0)
        #expect(plan.totals.excludedCount == 1)
    }

    /// Exercises `buildImportPlan`, the entry point production actually calls,
    /// against a real destination directory rather than a hand-fed namespace.
    /// `planImport` is the pure pass over an already-read namespace; a live-mismatch
    /// scenario like this one is only observable at the boundary that reads the
    /// destination folders off the filesystem.
    @Test func differentLiveSizeAdvancesTheWholeBundleSuffix() throws {
        let destinationDir = try makeTestDirectory()
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

    /// ADR 0018: a card item whose current digest a library holds — renamed, in another
    /// folder, or in another library — is not copied again, and the plan counts where it is.
    @Test func anItemALibraryHoldsByContentIsNotCopiedAgain() throws {
        let held = try #require(ContentDigest(data: Data(repeating: 1, count: ContentDigest.byteCount)))
        let other = try #require(ContentDigest(data: Data(repeating: 2, count: ContentDigest.byteCount)))
        let backup = LibraryRootPath(rawValue: "/tmp/backup")
        func withDigest(_ name: String, _ digest: ContentDigest?) -> PlanningFileFacts {
            let base = Self.facts(name: name, captureWallCompact: 20_260_101_120_000)
            return PlanningFileFacts(
                id: base.id,
                sourceURL: base.sourceURL,
                relativePath: base.relativePath,
                byteSize: base.byteSize,
                contentModifiedAt: base.contentModifiedAt,
                captureWallCompact: base.captureWallCompact,
                mediaKind: base.mediaKind,
                fileExtension: base.fileExtension,
                companions: [],
                contentTypeIdentifier: base.contentTypeIdentifier,
                contentHash: digest
            )
        }
        let snapshot = Self.snapshot(
            sourceMedia: [withDigest("IMG_1.JPG", held), withDigest("IMG_2.JPG", other), withDigest("IMG_3.JPG", nil)],
            libraryContent: [held: backup],
            policy: {
                var policy = ImportPolicy.from(.default)
                policy.destinationFolderPolicy = .none
                policy.destinationNamePolicy = .original
                return policy
            }()
        )

        let plan = MediaTransferPlanner.planImport(snapshot: snapshot, namespace: Self.namespace())

        let dispositions = Dictionary(uniqueKeysWithValues: plan.entries.map { ($0.source.relativePath.rawValue, $0.disposition) })
        #expect(dispositions["IMG_1.JPG"] == .skipInLibrary(library: backup))
        #expect(dispositions["IMG_2.JPG"].map {
            if case .copy = $0 {
                true
            } else {
                false
            }
        } == true)
        #expect(dispositions["IMG_3.JPG"].map {
            if case .copy = $0 {
                true
            } else {
                false
            }
        } == true)
        #expect(plan.totals.copyCount == 2)
        #expect(plan.totals.skipCount == 1)
        #expect(plan.totals.skipElsewhereCount == 1)
        #expect(plan.eraseManifest.entries.contains { $0.relativePath.rawValue == "IMG_1.JPG" })
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
        #expect(plan.entries[0].destination == expected)
    }

    @Test func blocksWhenNoUsableDate() {
        let source = Self.facts(name: "nodate.jpg", modified: nil, captureWallCompact: nil)
        let snapshot = Self.snapshot(sourceMedia: [source], policy: .from(.default))
        let plan = MediaTransferPlanner.planImport(snapshot: snapshot, namespace: Self.namespace())
        #expect(plan.entries[0].disposition == .blocked(.noUsableDate))
    }

    /// Original names at the library root: every candidate lands in the one folder the
    /// test namespace reads, so a plan's entries copy rather than block.
    private static let rootOriginalNames: ImportPolicy = {
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        return policy
    }()

    private static let base = MediaRelativePath(rawValue: "same.jpg")
    private static let firstSuffix = MediaRelativePath(rawValue: "same_001.jpg")

    @Test func concurrentPlansIntoOneDestinationClaimDisjointNames() {
        let snapshot = Self.snapshot(sourceMedia: [Self.facts(name: "same.jpg")], policy: Self.rootOriginalNames)
        let firstPlan = MediaTransferPlanner.planImport(snapshot: snapshot, namespace: Self.namespace())
        let secondPlan = MediaTransferPlanner.planImport(
            snapshot: snapshot,
            namespace: Self.namespace(),
            additionalReserved: Set(firstPlan.entries.compactMap(\.destination))
        )
        #expect(firstPlan.entries.map(\.disposition) == [.copy(destination: Self.base)])
        #expect(secondPlan.entries.map(\.disposition) == [.copy(destination: Self.firstSuffix)])
    }

    /// A companion lands beside its primary under the primary's name. Original naming
    /// keeps every member's exact spelling, the companion's extension included; date-time
    /// naming gives the companion its kind's extension.
    @Test func companionNamesFollowThePolicy() {
        let primary = MediaRelativePath(rawValue: "IMG_1.JPG")
        let sidecar = MediaCompanion(
            relativePath: MediaRelativePath(rawValue: "IMG_1.XMP"),
            primaryRelativePath: primary,
            kind: .xmp,
            byteSize: 5,
            contentModifiedAt: nil
        )
        let base = Self.facts(name: "IMG_1.JPG", captureWallCompact: 20_260_101_120_000)
        let source = PlanningFileFacts(
            id: base.id,
            sourceURL: base.sourceURL,
            relativePath: base.relativePath,
            byteSize: base.byteSize,
            contentModifiedAt: base.contentModifiedAt,
            captureWallCompact: base.captureWallCompact,
            mediaKind: base.mediaKind,
            fileExtension: base.fileExtension,
            companions: [sidecar],
            contentTypeIdentifier: base.contentTypeIdentifier
        )
        var dated = ImportPolicy.from(.default)
        dated.importSidecarFiles = true
        dated.destinationFolderPolicy = .none
        dated.destinationNamePolicy = .captureDateTime
        var original = dated
        original.destinationNamePolicy = .original

        let originalPlan = MediaTransferPlanner.planImport(
            snapshot: Self.snapshot(sourceMedia: [source], policy: original),
            namespace: Self.namespace()
        )
        let datedPlan = MediaTransferPlanner.planImport(
            snapshot: Self.snapshot(sourceMedia: [source], policy: dated),
            namespace: Self.namespace()
        )
        #expect(originalPlan.entries.map(\.companionDestinations) == [[sidecar.relativePath: sidecar.relativePath]])
        #expect(datedPlan.entries.map(\.companionDestinations) == [[
            sidecar.relativePath: MediaRelativePath(rawValue: "20260101_120000.xmp"),
        ]])
    }

    @Test func settledNameIsObservedAsOccupancyByNextBuild() throws {
        let source = Self.facts(name: "same.jpg")
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        let snapshot = Self.snapshot(sourceMedia: [source], policy: policy)
        let occupied = MediaTransferPlanner.planImport(snapshot: snapshot, namespace: Self.namespace())
        let settledName = try #require(occupied.entries[0].destination)
        let next = MediaTransferPlanner.planImport(
            snapshot: snapshot,
            namespace: Self.namespace([settledName: .foreign(kind: .other)])
        )

        #expect(settledName == Self.base)
        #expect(next.entries[0].destination == Self.firstSuffix)
    }

    @Test func conflictCheckUsesCurrentLedgerNotBuildStartSnapshot() {
        let snapshot = Self.snapshot(sourceMedia: [Self.facts(name: "same.jpg")], policy: Self.rootOriginalNames)
        let buildStart = MediaTransferPlanner.planImport(snapshot: snapshot, namespace: Self.namespace())
        let resumed = MediaTransferPlanner.planImport(
            snapshot: snapshot,
            namespace: Self.namespace(),
            additionalReserved: Set(buildStart.entries.compactMap(\.destination))
        )
        #expect(buildStart.entries[0].destination == Self.base)
        #expect(resumed.entries[0].destination == Self.firstSuffix)
    }

    @Test func policyThatNeverConsultsDateDoesNotWait() {
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .none
        policy.destinationNamePolicy = .original
        #expect(!ImportNaming.needsDate(policy))

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
        let destinationDir = try makeTestDirectory()
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
        #expect(plan.entries[0].destination == next)
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
            #expect(entry.destination.map { folders.contains(DestinationNamespace.folder(of: $0)) } == true)
            if case .blocked = entry.disposition {
                Issue.record("expected entry not to be blocked")
            }
        }
        #expect(Set(plan.entries.compactMap(\.destination)).count == 4)
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
            namespace: DestinationNamespace(entries: [:], enumeratedFolders: [], capabilities: .unknown)
        )

        #expect(plan.entries.map(\.disposition) == [
            .blocked(.filesystemObservationUnavailable(destination: MediaRelativePath(rawValue: "2026/01/20260101_120000.jpeg"))),
        ])
        #expect(plan.totals.copyCount == 0)
    }

    /// A file holding the destination folder's name (or a folder above it) makes the
    /// folder impossible to create: the entry is blocked with that cause, not copied and
    /// not retried as if the folder were briefly unreadable.
    @Test func aFileInTheWayOfTheDestinationFolderBlocks() {
        let source = Self.facts(name: "a.jpg", captureWallCompact: 20_260_101_120_000)
        var policy = ImportPolicy.from(.default)
        policy.destinationFolderPolicy = .yearMonth
        policy.destinationNamePolicy = .captureDateTime
        let plan = MediaTransferPlanner.planImport(
            snapshot: Self.snapshot(sourceMedia: [source], policy: policy),
            namespace: DestinationNamespace(entries: [:], enumeratedFolders: [], occupiedFolders: ["2026/01": "2026"], capabilities: .unknown)
        )
        #expect(plan.entries.map(\.disposition) == [.blocked(.destinationFolderOccupied(occupant: "2026"))])
    }

    /// Reading the folders finds a file where a folder belongs, at the folder itself or
    /// above it, and records it as an occupied folder — not as an unreadable one.
    @Test func enumerationRecordsAFileInTheWayOfAFolder() throws {
        let rootURL = try makeTestDirectory()
        try Data("x".utf8).write(to: rootURL.appending(path: "2024"))
        try FileManager.default.createDirectory(at: rootURL.appending(path: "2025"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: rootURL.appending(path: "2025/05"))
        let namespace = try FilesystemNamespaceSemantics.enumerateNamespace(
            root: CatalogPath.normalizedDirectoryPath(for: rootURL),
            folders: ["2024/05", "2025/05", "2026/05"],
            capabilities: .caseInsensitive
        )
        #expect(namespace.occupiedFolders == ["2024/05": "2024", "2025/05": "2025/05"])
        #expect(namespace.unreadableFolders.isEmpty)
        #expect(namespace.occupancy(of: MediaRelativePath(rawValue: "2026/05/a.jpg")) == .absent)
    }

    /// A folder that does not exist yet is still fully observed: every candidate in it
    /// is free. This is the first import into a fresh `YYYY/MM`.
    @Test func absentDestinationFolderPlansCopies() throws {
        let destinationDir = try makeTestDirectory()
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

    /// A file whose bytes could not be opened cannot be copied, so it must be blocked
    /// rather than silently skipped — and it must not hold the naming gate open, since
    /// nothing about it is transient on a removable volume (ARC-057).
    /// The verdict must not outlive the attachment that produced it. Without a detach
    /// boundary a single unreadable file stays blocked for the life of the process —
    /// through eject and re-insert, and even once it reads cleanly again — and the set
    /// grows without bound. Re-inserting a card re-evaluates from observation.
    @Test func anUnreadableVerdictIsForgottenWhenTheRootDetaches() async throws {
        try await withCatalogedLibrary(fileCount: 1, fileNamePrefix: "card") { card in
            let other = try makeTestDirectory()
            try Data([0]).write(to: other.appending(path: "other-0.jpg"))
            try await card.store.addLibrary(url: other)
            let otherPath = try CatalogPath.normalizedExistingDirectoryPath(for: other)
            let otherID = MediaAssetID(libraryRootPath: otherPath, relativePath: MediaRelativePath(rawValue: "other-0.jpg"))
            _ = try await waitForCatalogStoreState(card.store) { !$0.isScanning && $0.testAssets.count == 2 }
            let id = card.ids[0]

            await card.store.markSourceUnreadable(id)
            await card.store.markSourceUnreadable(otherID)
            #expect(try await Self.plansAsUnreadable(id, in: card.store))
            #expect(try await Self.plansAsUnreadable(otherID, in: card.store))

            await card.store.forgetUnreadableSources(under: card.rootPath)

            #expect(try await !Self.plansAsUnreadable(id, in: card.store), "the verdict outlived its attachment")
            #expect(try await Self.plansAsUnreadable(otherID, in: card.store), "another root's verdicts must be untouched")
        }
    }

    /// Plan 0117 step 6: a planning read that fails hands the planner nothing, and its log line
    /// carries the error by domain and code, so the failure says why.
    @Test func aFailedPlanningReadLogsItsError() async throws {
        let directory = try makeTestDirectory()
        let databaseURL = directory.appending(path: "db/catalog.sqlite")
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: directory, files: ["a.jpg"], database: databaseURL)
        let database = try makeTestDatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try await database.write { db in
            try db.execute(sql: "ALTER TABLE media_companion RENAME TO media_companion_hidden")
        }
        let since = Date()

        let media = await library.store.windowReads.planningMedia(for: library.rootPath)

        try await database.write { db in
            try db.execute(sql: "ALTER TABLE media_companion_hidden RENAME TO media_companion")
        }
        #expect(media == nil)
        let lines = try LoggedLines.read(
            .catalog, since: since, prefix: "op=reorganization.snapshot phase=failed", naming: library.rootPath.rawValue
        )
        #expect(lines.count == 1)
        let fields = try LoggedLines.fields(of: #require(lines.first))
        #expect(fields["error"]?.isEmpty == false)
        #expect(fields["errorCode"].flatMap(Int.init) != nil)
        await library.store.shutdown()
    }

    /// The verdict as planning reads it: the planning facts the Store hands the planner.
    private static func plansAsUnreadable(_ id: MediaAssetID, in store: CatalogStore) async throws -> Bool {
        let facts = try #require(await store.windowReads.planningMedia(for: id.libraryRootPath))
        return try #require(facts.first { $0.id == id }).isSourceUnreadable
    }

    @Test func unreadableSourceIsBlockedNotSilentlySkipped() {
        let root = LibraryRootPath(rawValue: "/Volumes/Card")
        let relative = MediaRelativePath(rawValue: "IMG_0001.JPG")
        let facts = PlanningFileFacts(
            id: MediaAssetID(libraryRootPath: root, relativePath: relative),
            sourceURL: root.url.appending(path: relative.rawValue, directoryHint: .notDirectory),
            relativePath: relative,
            byteSize: 100,
            contentModifiedAt: Date(timeIntervalSince1970: 1000),
            captureWallCompact: 20_260_426_145_735,
            namingFactState: .terminal,
            isSourceUnreadable: true,
            mediaKind: .image,
            fileExtension: "JPG",
            companions: [],
            contentTypeIdentifier: "public.jpeg"
        )
        let snapshot = ImportPlanningSnapshot(
            generation: 1,
            sourceRoot: root,
            destinationRoot: LibraryRootPath(rawValue: "/Pictures"),
            sourceNamespaceRevision: 1,
            sourceNamingRevision: 0,
            destinationNamespaceRevision: 1,
            sourceMedia: [facts],
            destinationOccupants: [:],
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
        let plan = MediaTransferPlanner.planImport(snapshot: snapshot, namespace: .empty)
        let entry = plan.entries.first
        #expect(entry?.disposition == .blocked(.sourceUnreadable))
        #expect(plan.totals.copyCount == 0)
        #expect(plan.totals.skipCount == 0, "an unreadable file must not read as already imported")
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
