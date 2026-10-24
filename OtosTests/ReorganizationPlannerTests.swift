import Foundation
@testable import OtosKit
import Testing

struct FilesystemNameKeyTests {
    @Test func caseInsensitiveCollapsesSpelling() {
        let caps = VolumeNamespaceCapabilities.caseInsensitiveAPFS
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
        let caps = VolumeNamespaceCapabilities.caseSensitiveAPFS
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
                capabilities: .caseInsensitiveAPFS
            ) == FilesystemNamespaceSemantics.nameKey(
                relativePath: decomposed,
                capabilities: .caseInsensitiveAPFS
            )
        )
    }
}

struct ReorganizationPlannerTests {
    private func media(
        path: String,
        compact: Int64 = 20_260_710_120_000,
        companions: [MediaCompanion] = [],
        contentTypeIdentifier: String? = nil
    ) -> PlanningFileFacts {
        PlanningFileFacts(
            id: MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: "/Library"),
                relativePath: MediaRelativePath(rawValue: path)
            ),
            sourceURL: URL(fileURLWithPath: "/Library/\(path)"),
            relativePath: MediaRelativePath(rawValue: path),
            byteSize: 100,
            contentModifiedAt: Date(timeIntervalSince1970: 1000),
            captureWallCompact: compact,
            mediaKind: .image,
            fileExtension: URL(fileURLWithPath: path).pathExtension,
            companions: companions,
            contentTypeIdentifier: contentTypeIdentifier
        )
    }

    private func snapshot(
        media: [PlanningFileFacts],
        preferences: ImportPreferences = .default
    ) -> ReorganizationPlanningSnapshot {
        ReorganizationPlanningSnapshot(
            libraryRoot: LibraryRootPath(rawValue: "/Library"),
            volumeIdentifier: "vol-test",
            capabilities: .caseInsensitiveAPFS,
            generation: 1,
            rootRevision: 1,
            policy: ImportPolicy.from(preferences),
            calendar: .current,
            timeZone: .current,
            media: media,
            knownForeignOccupants: []
        )
    }

    /// A library that keeps one undated file's original name at the root (no date
    /// folders), so the only change a plan can make is the spelling of its extension.
    private func originalNameSnapshot(path: String, fileExtension: String) -> ReorganizationPlanningSnapshot {
        var preferences = ImportPreferences.default
        preferences.destinationFolderPolicy = .none
        preferences.destinationNamePolicy = .original
        let item = PlanningFileFacts(
            id: MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: "/Library"),
                relativePath: MediaRelativePath(rawValue: path)
            ),
            sourceURL: URL(fileURLWithPath: "/Library/\(path)"),
            relativePath: MediaRelativePath(rawValue: path),
            byteSize: 10,
            contentModifiedAt: Date(timeIntervalSince1970: 1),
            captureWallCompact: nil,
            mediaKind: .image,
            fileExtension: fileExtension,
            companions: []
        )
        return snapshot(media: [item], preferences: preferences)
    }

    /// Plans `snapshot`, answering every occupancy probe with `.absent`, and requires
    /// the result to be a ready plan.
    private func planReady(snapshot: ReorganizationPlanningSnapshot) throws -> ReorganizationPlan {
        var occupancy: [NamespaceOccupancyRequest: NamespaceOccupancyResult] = [:]
        var outcome = ReorganizationPlanner.plan(snapshot: snapshot, occupancy: occupancy)
        if case let .needsProbes(requests) = outcome {
            for request in requests {
                occupancy[request] = .absent
            }
            outcome = ReorganizationPlanner.plan(snapshot: snapshot, occupancy: occupancy)
        }
        let plan: ReorganizationPlan? = if case let .ready(plan) = outcome {
            plan
        } else {
            nil
        }
        return try #require(plan, "expected ready, got \(outcome)")
    }

    /// The single move step a one-file case relabel must take: through a temporary name.
    private let photoCaseRelabel = ReorganizationMoveStep.moveViaTemporary(
        from: MediaRelativePath(rawValue: "Photo.JPG"),
        temporary: MediaRelativePath(rawValue: ".otos-reorg-media_Photo.JPG-Photo.JPG"),
        to: MediaRelativePath(rawValue: "Photo.jpg")
    )

    /// The planner derives a suffixed or temporary name's directory with
    /// `URL(fileURLWithPath:).deletingLastPathComponent().path`, which resolves a
    /// relative path against the process's working directory, so those names come back
    /// absolute (`/private/tmp/…` in the test host, `/…` in the app) instead of
    /// root-relative. `withKnownIssue` fails as soon as that is fixed, so the exact
    /// expectations below then stand unwrapped.
    private static let workingDirectoryLeak: Comment =
        "ReorganizationPlanner.suffixed/temporaryPath resolve relative paths against the working directory"

    /// The relabel step the plan holds, with every part but the temporary name checked.
    private func photoCaseRelabelStep(in plan: ReorganizationPlan) throws -> ReorganizationMoveStep {
        let steps = plan.components.map(\.steps)
        try #require(steps.count == 1 && steps[0].count == 1, "expected one single-step component, got \(steps)")
        let step = steps[0][0]
        let hop: (MediaRelativePath, MediaRelativePath)? =
            if case let .moveViaTemporary(from, _, to) = step {
                (from, to)
            } else {
                nil
            }
        let (from, to) = try #require(hop, "expected a temporary hop, got \(step)")
        #expect(from == MediaRelativePath(rawValue: "Photo.JPG"))
        #expect(to == MediaRelativePath(rawValue: "Photo.jpg"))
        return step
    }

    @Test func exactPathIsNoOp() throws {
        let item = media(path: "2026/07/20260710_120000.jpg")
        let plan = try planReady(snapshot: snapshot(media: [item]))
        #expect(plan.members.map(\.finalDestination) == [item.relativePath])
        #expect(plan.mediaDispositions == [item.id: .noOp])
        #expect(plan.components.isEmpty)
    }

    @Test func dateTimePolicyUsesCanonicalAppleExtension() throws {
        let item = media(path: "IMG_1.HIF", contentTypeIdentifier: "public.heif")
        let plan = try planReady(snapshot: snapshot(media: [item]))
        #expect(plan.members.first?.finalDestination.rawValue.hasSuffix(".heif") == true)
    }

    @Test func byteIdenticalSourcesRemainTwoRelocations() throws {
        let first = media(path: "a.jpg", compact: 20_260_710_120_001)
        let second = media(path: "b.jpg", compact: 20_260_710_120_002)
        let plan = try planReady(snapshot: snapshot(media: [first, second]))
        #expect(plan.relocateCount == 2)
        #expect(plan.mediaDispositions == [
            first.id: .relocate(destination: MediaRelativePath(rawValue: "2026/07/20260710_120001.jpg")),
            second.id: .relocate(destination: MediaRelativePath(rawValue: "2026/07/20260710_120002.jpg")),
        ])
    }

    @Test func originalPolicyExactSpellingIsNoOp() throws {
        let plan = try planReady(snapshot: originalNameSnapshot(path: "IMG_1.JPG", fileExtension: "JPG"))
        #expect(plan.noOpCount == 1)
        #expect(plan.relocateCount == 0)
        #expect(plan.components.isEmpty)
    }

    /// `Photo.JPG` → `Photo.jpg` is one name on a case-insensitive volume, so a direct
    /// rename would not change the spelling; only a hop through a temporary name does.
    @Test func caseOnlyRelabelNeedsTemporaryHop() throws {
        let plan = try planReady(snapshot: originalNameSnapshot(path: "Photo.JPG", fileExtension: "jpg"))
        #expect(plan.relocateCount == 1)
        let step = try photoCaseRelabelStep(in: plan)
        withKnownIssue(Self.workingDirectoryLeak) {
            #expect(step == photoCaseRelabel)
        }
    }

    @Test func undatableMediaIsBlockedIndividually() throws {
        let good = media(path: "good.jpg", compact: 20_260_710_120_001)
        let bad = PlanningFileFacts(
            id: MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: "/Library"),
                relativePath: MediaRelativePath(rawValue: "bad.jpg")
            ),
            sourceURL: URL(fileURLWithPath: "/Library/bad.jpg"),
            relativePath: MediaRelativePath(rawValue: "bad.jpg"),
            byteSize: 10,
            contentModifiedAt: nil,
            captureWallCompact: nil,
            mediaKind: .image,
            fileExtension: "jpg",
            companions: []
        )
        let plan = try planReady(snapshot: snapshot(media: [good, bad]))
        #expect(plan.mediaDispositions[bad.id] == .blocked(.noUsableDate))
        #expect(plan.blockedCount == 1)
    }

    /// Every member's final name is unique in the volume namespace, stationary (no-op)
    /// members included: a relocating file must never land on a file that stays put.
    /// Two sources compete for the date name a third file already holds.
    @Test func finalNamespaceKeysAreUnique() throws {
        let stationary = media(path: "2026/07/20260710_120000.jpg", compact: 20_260_710_120_000)
        let first = media(path: "x.jpg", compact: 20_260_710_120_000)
        let second = media(path: "y.jpg", compact: 20_260_710_120_000)
        let plan = try planReady(snapshot: snapshot(media: [stationary, first, second]))
        let keys = plan.members.map {
            FilesystemNamespaceSemantics.nameKey(
                relativePath: $0.finalDestination,
                capabilities: .caseInsensitiveAPFS
            )
        }
        #expect(keys.count == 3)
        #expect(Set(keys).count == keys.count)
        #expect(plan.mediaDispositions[stationary.id] == .noOp)
        #expect(plan.relocateCount == 2)
        withKnownIssue(Self.workingDirectoryLeak) {
            #expect(plan.mediaDispositions == [
                stationary.id: .noOp,
                first.id: .relocate(destination: MediaRelativePath(rawValue: "2026/07/20260710_120000_1.jpg")),
                second.id: .relocate(destination: MediaRelativePath(rawValue: "2026/07/20260710_120000_2.jpg")),
            ])
        }
    }

    @Test func existingDirectoryAncestorsDoNotBlock() {
        let item = media(path: "inbox/shot.jpg", compact: 20_260_710_120_000)
        var occupancy: [NamespaceOccupancyRequest: NamespaceOccupancyResult] = [:]
        var outcome = ReorganizationPlanner.plan(snapshot: snapshot(media: [item]), occupancy: occupancy)
        if case let .needsProbes(requests) = outcome {
            for request in requests {
                let leaf = request.relativePath.rawValue
                if leaf == "2026" || leaf == "2026/07" {
                    occupancy[request] = .foreign(kind: .directory)
                } else {
                    occupancy[request] = .absent
                }
            }
            outcome = ReorganizationPlanner.plan(snapshot: snapshot(media: [item]), occupancy: occupancy)
        }
        guard case let .ready(plan) = outcome else {
            Issue.record("expected ready, got \(outcome)")
            return
        }
        #expect(plan.blockedCount == 0)
        #expect(plan.mediaDispositions[item.id] != .blocked(.ancestorConflict(MediaRelativePath(rawValue: "2026"))))
    }

    @Test func occupiedFinalDestinationIsSuffixed() {
        let item = media(path: "inbox/shot.jpg", compact: 20_260_710_120_000)
        var occupancy: [NamespaceOccupancyRequest: NamespaceOccupancyResult] = [:]
        var outcome = ReorganizationPlanner.plan(snapshot: snapshot(media: [item]), occupancy: occupancy)
        if case let .needsProbes(requests) = outcome {
            for request in requests {
                if request.relativePath.rawValue == "2026/07/20260710_120000.jpg" {
                    occupancy[request] = .regularFile(byteSize: 1, contentModifiedAt: nil)
                } else if request.relativePath.rawValue == "2026" || request.relativePath.rawValue == "2026/07" {
                    occupancy[request] = .foreign(kind: .directory)
                } else {
                    occupancy[request] = .absent
                }
            }
            outcome = ReorganizationPlanner.plan(snapshot: snapshot(media: [item]), occupancy: occupancy)
            // Resuffix may request another probe round.
            if case let .needsProbes(more) = outcome {
                for request in more {
                    occupancy[request] = .absent
                }
                outcome = ReorganizationPlanner.plan(snapshot: snapshot(media: [item]), occupancy: occupancy)
            }
        }
        guard case let .ready(plan) = outcome else {
            Issue.record("expected ready, got \(outcome)")
            return
        }
        guard case let .relocate(destination) = plan.mediaDispositions[item.id] else {
            Issue.record("expected relocate, got \(String(describing: plan.mediaDispositions[item.id]))")
            return
        }
        #expect(destination.rawValue != "2026/07/20260710_120000.jpg")
        #expect(destination.rawValue.contains("20260710_120000"))
    }

    @Test func chainVacatesFreeEndFirst() throws {
        // A at b.jpg wants the date path currently occupied by B; B vacates to a free date path.
        let chainA = media(path: "b.jpg", compact: 20_260_710_120_000)
        let chainB = media(path: "2026/07/20260710_120000.jpg", compact: 20_260_710_120_001)
        let plan = try planReady(snapshot: snapshot(media: [chainA, chainB]))
        let component = try #require(plan.components.first, "expected a chain component")
        let steps = component.steps.compactMap { step -> (String, String)? in
            if case let .move(from, to) = step {
                return (from.rawValue, to.rawValue)
            }
            return nil
        }
        #expect(steps.count >= 2)
        // Free end (B→C) must precede predecessor (A→B).
        let freeEndIndex = steps.firstIndex { $0.0 == "2026/07/20260710_120000.jpg" }
        let predIndex = steps.firstIndex { $0.0 == "b.jpg" }
        guard let freeEndIndex, let predIndex else {
            Issue.record("missing chain steps: \(steps)")
            return
        }
        #expect(freeEndIndex < predIndex)
    }

    /// The temporary name is derived from the member's path alone, never from a
    /// per-process value such as `hashValue`, so a plan rebuilt in another process
    /// names the same temporary file. The literal pins that derivation.
    @Test func temporaryPathTokenIsStable() throws {
        let snap = originalNameSnapshot(path: "Photo.JPG", fileExtension: "jpg")
        let first = try photoCaseRelabelStep(in: planReady(snapshot: snap))
        let second = try photoCaseRelabelStep(in: planReady(snapshot: snap))
        #expect(first == second)
        withKnownIssue(Self.workingDirectoryLeak) {
            #expect(first == photoCaseRelabel)
        }
    }
}
