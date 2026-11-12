import Foundation
@testable import OtosKit
import Testing

struct FilesystemNameKeyTests {
    @Test func caseInsensitiveCollapsesSpelling() {
        let caps = VolumeNamespaceCapabilities.caseInsensitive
        let upper = FilesystemNamespaceSemantics.nameKey(
            relativePath: MediaRelativePath(rawValue: "IMG_1.JPG"),
            capabilities: caps
        )
        let lower = FilesystemNamespaceSemantics.nameKey(
            relativePath: MediaRelativePath(rawValue: "img_1.jpg"),
            capabilities: caps
        )
        #expect(upper == lower)
    }

    @Test func caseSensitivePreservesSpelling() {
        let caps = VolumeNamespaceCapabilities.caseSensitive
        let upper = FilesystemNamespaceSemantics.nameKey(
            relativePath: MediaRelativePath(rawValue: "IMG_1.JPG"),
            capabilities: caps
        )
        let lower = FilesystemNamespaceSemantics.nameKey(
            relativePath: MediaRelativePath(rawValue: "img_1.jpg"),
            capabilities: caps
        )
        #expect(upper != lower)
    }

    @Test func unicodeNormalizationFollowsVolumePreference() {
        let composed = MediaRelativePath(rawValue: "café.jpg")
        let decomposed = MediaRelativePath(rawValue: "cafe\u{301}.jpg")
        #expect(
            FilesystemNamespaceSemantics.nameKey(
                relativePath: composed,
                capabilities: .caseInsensitive
            ) == FilesystemNamespaceSemantics.nameKey(
                relativePath: decomposed,
                capabilities: .caseInsensitive
            )
        )
    }
}

struct ReorganizationPlannerTests {
    private func media(
        path: String,
        compact: Int64? = 20_260_710_120_000,
        modified: Date? = Date(timeIntervalSince1970: 1000),
        companions: [MediaCompanion] = [],
        contentTypeIdentifier: String? = nil
    ) -> PlanningFileFacts {
        let relative = MediaRelativePath(rawValue: path)
        return PlanningFileFacts(
            id: MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/Library"), relativePath: relative),
            sourceURL: URL(fileURLWithPath: "/Library/\(path)"),
            relativePath: relative,
            byteSize: 100,
            contentModifiedAt: modified,
            captureWallCompact: compact,
            mediaKind: .image,
            fileExtension: relative.fileExtension,
            companions: companions,
            contentTypeIdentifier: contentTypeIdentifier
        )
    }

    private func snapshot(
        media: [PlanningFileFacts],
        folderPolicy: DestinationFolderPolicy = .yearMonth,
        namePolicy: DestinationNamePolicy = .captureDateTime
    ) -> ReorganizationPlanningSnapshot {
        var preferences = ImportPreferences.default
        preferences.destinationFolderPolicy = folderPolicy
        preferences.destinationNamePolicy = namePolicy
        return ReorganizationPlanningSnapshot(
            libraryRoot: LibraryRootPath(rawValue: "/Library"),
            capabilities: .caseInsensitive,
            generation: 1,
            rootRevision: 1,
            policy: ImportPolicy.from(preferences),
            calendar: .current,
            timeZone: .current,
            media: media
        )
    }

    /// Plans against a namespace in which every destination folder was read and holds
    /// `occupants` (plus whatever the caller marks occupied or unreadable).
    private func plan(
        _ snapshot: ReorganizationPlanningSnapshot,
        occupants: [String: NamespaceOccupancyResult] = [:],
        occupiedFolders: [String: String] = [:],
        unreadableFolders: [String: String] = [:]
    ) throws -> ReorganizationPlan {
        let folders = ReorganizationPlanner.destinationFolders(for: snapshot)
        let namespace = DestinationNamespace(
            entries: Dictionary(uniqueKeysWithValues: occupants.map { (MediaRelativePath(rawValue: $0.key), $0.value) }),
            enumeratedFolders: folders.subtracting(occupiedFolders.keys).subtracting(unreadableFolders.keys),
            unreadableFolders: unreadableFolders,
            occupiedFolders: occupiedFolders,
            capabilities: snapshot.capabilities
        )
        let outcome = ReorganizationPlanner.plan(snapshot: snapshot, namespace: namespace)
        let ready: ReorganizationPlan? = if case let .ready(plan) = outcome {
            plan
        } else {
            nil
        }
        return try #require(ready, "expected a ready plan, got \(outcome)")
    }

    private func moves(_ plan: ReorganizationPlan) -> [[String]] {
        plan.components.map { component in
            component.steps.map { step in
                switch step {
                case let .move(from, to):
                    "\(from.rawValue) -> \(to.rawValue)"
                }
            }
        }
    }

    @Test func exactPathIsNoOp() throws {
        let item = media(path: "2026/07/20260710_120000.jpg")
        let plan = try plan(snapshot(media: [item]))
        #expect(plan.members.map(\.finalDestination) == [item.relativePath])
        #expect(plan.mediaDispositions == [item.id: .noOp])
        #expect(plan.components.isEmpty)
    }

    @Test func dateTimePolicyUsesCanonicalAppleExtension() throws {
        let item = media(path: "IMG_1.HIF", contentTypeIdentifier: "public.heif")
        let plan = try plan(snapshot(media: [item]))
        #expect(plan.mediaDispositions == [
            item.id: .relocate(destination: MediaRelativePath(rawValue: "2026/07/20260710_120000.heif")),
        ])
    }

    /// `Photo.JPG` → `Photo.jpg` is one name on a case-insensitive volume, so a direct
    /// rename cannot change the spelling: the file steps aside to a temporary name in its
    /// own folder first. The temporary name is built from the member's path alone, never
    /// a per-process value, so a plan rebuilt in another process names the same file.
    @Test func caseOnlyRelabelStepsAsideThroughAStableTemporaryName() throws {
        var item = media(path: "Photo.JPG", compact: nil)
        item = PlanningFileFacts(
            id: item.id,
            sourceURL: item.sourceURL,
            relativePath: item.relativePath,
            byteSize: item.byteSize,
            contentModifiedAt: item.contentModifiedAt,
            captureWallCompact: nil,
            mediaKind: .image,
            fileExtension: "jpg",
            companions: []
        )
        let snapshot = snapshot(media: [item], folderPolicy: .none, namePolicy: .original)
        let expected = [[
            "Photo.JPG -> .otos-reorg-media_Photo.JPG-Photo.JPG",
            ".otos-reorg-media_Photo.JPG-Photo.JPG -> Photo.jpg",
        ]]
        #expect(try moves(plan(snapshot)) == expected)
        #expect(try moves(plan(snapshot)) == expected)
    }

    @Test func undatableMediaIsBlockedAndStaysOutOfTheMoves() throws {
        let good = media(path: "good.jpg", compact: 20_260_710_120_001)
        let bad = media(path: "bad.jpg", compact: nil, modified: nil)
        let plan = try plan(snapshot(media: [good, bad]))
        #expect(plan.mediaDispositions == [
            good.id: .relocate(destination: MediaRelativePath(rawValue: "2026/07/20260710_120001.jpg")),
            bad.id: .blocked(.noUsableDate),
        ])
        #expect(moves(plan) == [["good.jpg -> 2026/07/20260710_120001.jpg"]])
    }

    /// Two sources compete for the date name a file that stays already holds: neither
    /// lands on it, and they take the import policy's suffixes in naming order.
    @Test func competingSourcesTakeImportSuffixesAroundAStayingFile() throws {
        let stationary = media(path: "2026/07/20260710_120000.jpg")
        let first = media(path: "x.jpg")
        let second = media(path: "y.jpg")
        let plan = try plan(snapshot(media: [stationary, first, second]))
        #expect(plan.mediaDispositions == [
            stationary.id: .noOp,
            first.id: .relocate(destination: MediaRelativePath(rawValue: "2026/07/20260710_120000_001.jpg")),
            second.id: .relocate(destination: MediaRelativePath(rawValue: "2026/07/20260710_120000_002.jpg")),
        ])
    }

    @Test func aFileTheCatalogDoesNotKnowForcesASuffix() throws {
        let item = media(path: "inbox/shot.jpg")
        let plan = try plan(
            snapshot(media: [item]),
            occupants: ["2026/07/20260710_120000.jpg": .regularFile(byteSize: 1, contentModifiedAt: nil)]
        )
        #expect(plan.mediaDispositions == [
            item.id: .relocate(destination: MediaRelativePath(rawValue: "2026/07/20260710_120000_001.jpg")),
        ])
    }

    @Test func aFileHoldingTheFolderNameBlocksTheItem() throws {
        let item = media(path: "inbox/shot.jpg")
        let plan = try plan(snapshot(media: [item]), occupiedFolders: ["2026/07": "2026"])
        #expect(plan.mediaDispositions == [item.id: .blocked(.folderOccupied(occupant: "2026"))])
        #expect(plan.components.isEmpty)
    }

    @Test func anUnreadableFolderBlocksTheItem() throws {
        let item = media(path: "inbox/shot.jpg")
        let plan = try plan(snapshot(media: [item]), unreadableFolders: ["2026/07": "NSCocoaErrorDomain#257"])
        #expect(plan.mediaDispositions == [item.id: .blocked(.folderUnreadable(folder: "2026/07"))])
        #expect(plan.components.isEmpty)
    }

    /// A RAW and its JPEG name together, as import names them: when one name is taken,
    /// both take the same suffix.
    @Test func aRawAndItsJpegShareOneSuffix() throws {
        let raw = media(path: "inbox/IMG_1.CR3")
        let jpeg = media(path: "inbox/IMG_1.JPG")
        let plan = try plan(
            snapshot(media: [raw, jpeg], folderPolicy: .none, namePolicy: .original),
            occupants: ["IMG_1.JPG": .regularFile(byteSize: 1, contentModifiedAt: nil)]
        )
        #expect(plan.mediaDispositions == [
            raw.id: .relocate(destination: MediaRelativePath(rawValue: "IMG_1_001.CR3")),
            jpeg.id: .relocate(destination: MediaRelativePath(rawValue: "IMG_1_001.JPG")),
        ])
    }

    /// A companion moves beside its primary under the primary's new name, with its kind
    /// as the extension — the name import gives a companion it copies.
    @Test func aCompanionFollowsItsPrimary() throws {
        let companion = MediaCompanion(
            relativePath: MediaRelativePath(rawValue: "a.XMP"),
            primaryRelativePath: MediaRelativePath(rawValue: "a.jpg"),
            kind: .xmp,
            byteSize: 10,
            contentModifiedAt: nil
        )
        let item = media(path: "a.jpg", companions: [companion])
        let plan = try plan(snapshot(media: [item]))
        #expect(Set(plan.members.map { "\($0.source.rawValue) -> \($0.finalDestination.rawValue)" }) == [
            "a.jpg -> 2026/07/20260710_120000.jpg",
            "a.XMP -> 2026/07/20260710_120000.xmp",
        ])
        #expect(plan.components.count == 1)
    }

    /// A takes the name B holds and B moves on to a free one: B vacates first.
    @Test func aChainVacatesItsFreeEndFirst() throws {
        let chainA = media(path: "b.jpg", compact: 20_260_710_120_000)
        let chainB = media(path: "2026/07/20260710_120000.jpg", compact: 20_260_710_120_001)
        let plan = try plan(snapshot(media: [chainA, chainB]))
        #expect(moves(plan) == [[
            "2026/07/20260710_120000.jpg -> 2026/07/20260710_120001.jpg",
            "b.jpg -> 2026/07/20260710_120000.jpg",
        ]])
    }

    /// Two files that swap names: one steps aside, the other takes its name, then the
    /// first takes the other's.
    @Test func aSwapStepsAsideOnce() throws {
        let first = media(path: "2026/07/20260710_120001.jpg", compact: 20_260_710_120_000)
        let second = media(path: "2026/07/20260710_120000.jpg", compact: 20_260_710_120_001)
        let plan = try plan(snapshot(media: [first, second]))
        let temporary = "2026/07/.otos-reorg-media_2026_07_20260710_120000.jpg-20260710_120000.jpg"
        #expect(moves(plan) == [[
            "2026/07/20260710_120000.jpg -> \(temporary)",
            "2026/07/20260710_120001.jpg -> 2026/07/20260710_120000.jpg",
            "\(temporary) -> 2026/07/20260710_120001.jpg",
        ]])
    }
}
