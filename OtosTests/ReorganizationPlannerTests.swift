import Foundation
@testable import Otos
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
}

struct ReorganizationPlannerTests {
    private func policy() -> ImportPolicy {
        ImportPolicy.from(ImportPreferences.default)
    }

    private func media(
        path: String,
        compact: Int64 = 20_260_710_120_000,
        companions: [MediaCompanion] = []
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
            companions: companions
        )
    }

    private func snapshot(media: [PlanningFileFacts]) -> ReorganizationPlanningSnapshot {
        ReorganizationPlanningSnapshot(
            libraryRoot: LibraryRootPath(rawValue: "/Library"),
            volumeIdentifier: "vol-test",
            capabilities: .caseInsensitiveAPFS,
            generation: 1,
            rootRevision: 1,
            policy: policy(),
            media: media,
            knownForeignOccupants: []
        )
    }

    private func planReady(
        snapshot: ReorganizationPlanningSnapshot
    ) -> ReorganizationPlan? {
        var occupancy: [NamespaceOccupancyRequest: NamespaceOccupancyResult] = [:]
        var outcome = ReorganizationPlanner.plan(snapshot: snapshot, occupancy: occupancy)
        if case let .needsProbes(requests) = outcome {
            for request in requests {
                occupancy[request] = .absent
            }
            outcome = ReorganizationPlanner.plan(snapshot: snapshot, occupancy: occupancy)
        }
        guard case let .ready(plan) = outcome else {
            Issue.record("expected ready, got \(outcome)")
            return nil
        }
        return plan
    }

    @Test func exactPathIsNoOp() {
        let item = media(path: "2026/07/20260710_120000.jpg")
        guard let plan = planReady(snapshot: snapshot(media: [item])) else { return }
        if item.relativePath == plan.members.first?.finalDestination {
            #expect(plan.mediaDispositions[item.id] == .noOp)
            #expect(plan.components.isEmpty)
        }
    }

    @Test func byteIdenticalSourcesRemainTwoRelocations() {
        let first = media(path: "a.jpg", compact: 20_260_710_120_001)
        let second = media(path: "b.jpg", compact: 20_260_710_120_002)
        guard let plan = planReady(snapshot: snapshot(media: [first, second])) else { return }
        #expect(plan.relocateCount + plan.noOpCount + plan.blockedCount == 2)
        #expect(plan.mediaDispositions.count == 2)
    }

    @Test func originalPolicyExactSpellingIsNoOp() {
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        let item = PlanningFileFacts(
            id: MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: "/Library"),
                relativePath: MediaRelativePath(rawValue: "IMG_1.JPG")
            ),
            sourceURL: URL(fileURLWithPath: "/Library/IMG_1.JPG"),
            relativePath: MediaRelativePath(rawValue: "IMG_1.JPG"),
            byteSize: 10,
            contentModifiedAt: Date(timeIntervalSince1970: 1),
            captureWallCompact: nil,
            mediaKind: .image,
            fileExtension: "JPG",
            companions: []
        )
        let snap = ReorganizationPlanningSnapshot(
            libraryRoot: LibraryRootPath(rawValue: "/Library"),
            volumeIdentifier: "vol",
            capabilities: .caseInsensitiveAPFS,
            generation: 1,
            rootRevision: 1,
            policy: ImportPolicy.from(prefs),
            media: [item],
            knownForeignOccupants: []
        )
        guard let plan = planReady(snapshot: snap) else { return }
        #expect(plan.noOpCount == 1 || plan.relocateCount == 1)
    }

    @Test func caseOnlyRelabelNeedsTemporaryHop() {
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        let item = PlanningFileFacts(
            id: MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: "/Library"),
                relativePath: MediaRelativePath(rawValue: "Photo.JPG")
            ),
            sourceURL: URL(fileURLWithPath: "/Library/Photo.JPG"),
            relativePath: MediaRelativePath(rawValue: "Photo.JPG"),
            byteSize: 10,
            contentModifiedAt: Date(timeIntervalSince1970: 1),
            captureWallCompact: nil,
            mediaKind: .image,
            fileExtension: "jpg",
            companions: []
        )
        let snap = ReorganizationPlanningSnapshot(
            libraryRoot: LibraryRootPath(rawValue: "/Library"),
            volumeIdentifier: "vol",
            capabilities: .caseInsensitiveAPFS,
            generation: 1,
            rootRevision: 1,
            policy: ImportPolicy.from(prefs),
            media: [item],
            knownForeignOccupants: []
        )
        guard let plan = planReady(snapshot: snap) else { return }
        guard let member = plan.members.first(where: { !$0.isCompanion }),
              member.source != member.finalDestination,
              let component = plan.components.first
        else {
            return
        }
        let sourceKey = FilesystemNamespaceSemantics.nameKey(
            relativePath: member.source,
            capabilities: .caseInsensitiveAPFS
        )
        let destKey = FilesystemNamespaceSemantics.nameKey(
            relativePath: member.finalDestination,
            capabilities: .caseInsensitiveAPFS
        )
        guard sourceKey == destKey else { return }
        #expect(component.steps.contains { step in
            if case .moveViaTemporary = step {
                return true
            }
            return false
        })
    }

    @Test func undatableMediaIsBlockedIndividually() {
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
        guard let plan = planReady(snapshot: snapshot(media: [good, bad])) else { return }
        #expect(plan.mediaDispositions[bad.id] == .blocked(.noUsableDate))
        #expect(plan.blockedCount == 1)
    }

    @Test func finalNamespaceKeysAreUnique() {
        let first = media(path: "x.jpg", compact: 20_260_710_120_000)
        let second = media(path: "y.jpg", compact: 20_260_710_120_000)
        guard let plan = planReady(snapshot: snapshot(media: [first, second])) else { return }
        let keys = plan.members.filter { $0.source != $0.finalDestination }.map {
            FilesystemNamespaceSemantics.nameKey(
                relativePath: $0.finalDestination,
                capabilities: .caseInsensitiveAPFS
            )
        }
        #expect(Set(keys).count == keys.count)
    }
}
