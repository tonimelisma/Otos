import Foundation
@testable import OtosKit
import Testing

struct MediaOperationModelsTests {
    private static let source = LibraryRootPath(rawValue: "/tmp/card")
    private static let destination = LibraryRootPath(rawValue: "/tmp/library")

    private static func facts(name: String) -> PlanningFileFacts {
        let relative = MediaRelativePath(rawValue: name)
        return PlanningFileFacts(
            id: MediaAssetID(libraryRootPath: source, relativePath: relative),
            sourceURL: source.url.appending(path: name),
            relativePath: relative,
            byteSize: 10,
            contentModifiedAt: Date(timeIntervalSince1970: 100),
            captureWallCompact: nil,
            mediaKind: .image,
            fileExtension: "jpg",
            companions: []
        )
    }

    private static func entry(name: String, disposition: MediaOperationDisposition) -> MediaOperationPlanEntry {
        let relative = MediaRelativePath(rawValue: name)
        return MediaOperationPlanEntry(
            source: facts(name: name),
            idealDestination: relative,
            finalDestination: relative,
            companionDestinations: [:],
            disposition: disposition
        )
    }

    private static func plan(entries: [MediaOperationPlanEntry]) -> MediaOperationPlan {
        MediaOperationPlan(
            generation: 1,
            mode: .import(source: source, destination: destination, batch: ImportBatchID()),
            sourceNamespaceRevision: 1,
            sourceNamingRevision: 0,
            destinationNamespaceRevision: 1,
            policy: ImportPolicy(
                destinationFolderPolicy: .none,
                destinationNamePolicy: .original,
                importSidecarFiles: false,
                deleteSourceAfterImport: false,
                autoEjectAfterImport: false
            ),
            entries: entries,
            totals: MediaOperationPlanTotals(copyCount: 0, skipCount: 0, blockedCount: 0, companionCopyCount: 0, copyBytes: 0)
        )
    }

    // MARK: - attentionItems (import-bar.md state D: "Show them" needs identity, not just a count)

    @Test func attentionItemsSurfacesOnlyBlockedEntriesWithIdentityAndReason() {
        let noDate = Self.entry(name: "no-date.jpg", disposition: .blocked(.noUsableDate))
        let observation = Self.entry(
            name: "unreadable.jpg",
            disposition: .blocked(.filesystemObservationUnavailable(
                destination: MediaRelativePath(rawValue: "unreadable.jpg"),
                detail: "enumerate failed"
            ))
        )
        let copied = Self.entry(name: "fine.jpg", disposition: .copy(destination: MediaRelativePath(rawValue: "fine.jpg")))
        let skipped = Self.entry(name: "dup.jpg", disposition: .skipPreexisting(destination: MediaRelativePath(rawValue: "dup.jpg")))

        let items = Self.plan(entries: [noDate, copied, observation, skipped]).attentionItems

        #expect(items.map(\.id) == [noDate.source.id, observation.source.id])
        #expect(items[0].reason == .noUsableDate)
        guard case .filesystemObservationUnavailable = items[1].reason else {
            Issue.record("Expected filesystemObservationUnavailable, got \(items[1].reason)")
            return
        }
    }

    @Test func attentionItemsIsEmptyWhenNothingIsBlocked() {
        let copied = Self.entry(name: "fine.jpg", disposition: .copy(destination: MediaRelativePath(rawValue: "fine.jpg")))
        #expect(Self.plan(entries: [copied]).attentionItems.isEmpty)
    }

    // MARK: - MediaOperationFailureReason.forMissingSnapshot (trap #3's two new producers)

    @Test func missingSnapshotClassifiesSourceRemovedWhenSourceIsGone() {
        let reason = MediaOperationFailureReason.forMissingSnapshot(
            source: Self.source,
            destination: Self.destination,
            availableRoots: [Self.destination]
        )
        #expect(reason == .sourceRemoved)
    }

    @Test func missingSnapshotClassifiesDestinationUnavailableWhenOnlyDestinationIsGone() {
        let reason = MediaOperationFailureReason.forMissingSnapshot(
            source: Self.source,
            destination: Self.destination,
            availableRoots: [Self.source]
        )
        #expect(reason == .destinationUnavailable)
    }

    @Test func missingSnapshotFallsBackToUnexpectedWhenBothRootsAreAvailable() {
        let reason = MediaOperationFailureReason.forMissingSnapshot(
            source: Self.source,
            destination: Self.destination,
            availableRoots: [Self.source, Self.destination]
        )
        #expect(reason == .unexpected(detail: "snapshotUnavailable"))
    }

    @Test func missingSnapshotPrefersSourceRemovedWhenBothRootsAreGone() {
        // Naming one cause is the DES-034 discipline `import-bar.md` state D
        // spells out for attention items; the same rule applies here — pick
        // one honest cause rather than a mixed clause.
        let reason = MediaOperationFailureReason.forMissingSnapshot(
            source: Self.source,
            destination: Self.destination,
            availableRoots: []
        )
        #expect(reason == .sourceRemoved)
    }
}
