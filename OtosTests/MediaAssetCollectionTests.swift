@testable import Otos
import Testing

@MainActor
struct MediaAssetCollectionTests {
    @Test func applyGateKeepsOnlyNewestPendingGrid() {
        let gate = MediaAssetCollectionApplyGate()
        let first = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        let intermediate = makeGrid(scope: .allMedia, paths: ["a.jpg", "b.jpg"])
        let newest = makeGrid(scope: .allMedia, paths: ["c.jpg"])

        guard case let .apply(started, resetScroll, resetSelection) = gate.receive(first) else {
            Issue.record("The first structural state should start an apply")
            return
        }
        #expect(started == first)
        #expect(resetScroll == false)
        #expect(resetSelection == false)

        guard case let .pending(replacedFirstPending) = gate.receive(intermediate) else {
            Issue.record("An update during an apply should become pending")
            return
        }
        #expect(replacedFirstPending == false)

        guard case let .pending(replacedExisting) = gate.receive(newest) else {
            Issue.record("A newer update should replace the pending state")
            return
        }
        #expect(replacedExisting)

        guard case let .apply(next, nextResetScroll, nextResetSelection) = gate.complete(applied: first) else {
            Issue.record("Completing the first apply should start the newest pending state")
            return
        }
        #expect(next == newest)
        #expect(nextResetScroll == false)
        #expect(nextResetSelection == false)
    }

    @Test func identicalIDsRefreshVisibleWithoutStructuralApply() {
        let gate = MediaAssetCollectionApplyGate()
        let first = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        guard case .apply = gate.receive(first) else {
            Issue.record("Expected initial structural apply")
            return
        }
        #expect(isNone(gate.complete(applied: first)))

        guard case let .refreshVisible(refreshed, resetScroll, resetSelection) = gate.receive(first) else {
            Issue.record("Unchanged identities should refresh visible item details")
            return
        }
        #expect(refreshed == first)
        #expect(resetScroll == false)
        #expect(resetSelection == false)
    }

    @Test func descriptorChangeResetsScrollAndSelectionAndSameDescriptorStructurePreservesThem() {
        let gate = MediaAssetCollectionApplyGate()
        let allMedia = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        guard case .apply = gate.receive(allMedia) else {
            Issue.record("Expected initial structural apply")
            return
        }
        _ = gate.complete(applied: allMedia)

        let sameDescriptor = makeGrid(scope: .allMedia, paths: ["a.jpg", "b.jpg"])
        let sameDescriptorAction = gate.receive(sameDescriptor)
        guard case let .apply(_, sameResetScroll, sameResetSelection) = sameDescriptorAction else {
            Issue.record("Expected same-descriptor structural apply")
            return
        }
        #expect(sameResetScroll == false)
        #expect(sameResetSelection == false)
        _ = gate.complete(applied: sameDescriptor)

        let libraryPath = LibraryRootPath(rawValue: "/Pictures")
        let differentScope = makeGrid(scope: .library(libraryPath), paths: ["a.jpg"])
        let differentScopeAction = gate.receive(differentScope)
        guard case let .apply(_, scopeResetScroll, scopeResetSelection) = differentScopeAction else {
            Issue.record("Expected scope-changing structural apply")
            return
        }
        #expect(scopeResetScroll)
        #expect(scopeResetSelection)
    }

    @Test func descriptorChangeWithSameIDsRefreshClearsSelection() {
        let gate = MediaAssetCollectionApplyGate()
        let allMedia = makeGrid(scope: .allMedia, paths: ["a.jpg"])
        guard case .apply = gate.receive(allMedia) else {
            Issue.record("Expected initial structural apply")
            return
        }
        _ = gate.complete(applied: allMedia)

        let sameIDsInLibraryScope = makeGrid(
            scope: .library(LibraryRootPath(rawValue: "/Pictures")),
            paths: ["a.jpg"]
        )
        let scopeRefreshAction = gate.receive(sameIDsInLibraryScope)
        guard case let .refreshVisible(refreshed, resetScroll, resetSelection) = scopeRefreshAction else {
            Issue.record("Expected descriptor-changing refresh when IDs are unchanged")
            return
        }
        #expect(refreshed == sameIDsInLibraryScope)
        #expect(resetScroll)
        #expect(resetSelection)
    }

    @Test func structuralApplyPolicyUsesReloadDataFallbackOnlyForLargeOrReorderApplies() {
        let previous = makeGrid(scope: .allMedia, paths: ["a.jpg", "b.jpg", "c.jpg"]).orderedAssetIDs
        let smallInsert = makeGrid(scope: .allMedia, paths: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]).orderedAssetIDs
        let smallInsertPolicy = MediaGridStructuralApplyPolicy.summarize(
            previousOrderedIDs: previous,
            nextOrderedIDs: smallInsert
        )
        #expect(smallInsertPolicy.animatingDifferences)
        #expect(!smallInsertPolicy.usesReloadDataFallback)

        let reordered = [previous[2], previous[1], previous[0]]
        let reorderPolicy = MediaGridStructuralApplyPolicy.summarize(
            previousOrderedIDs: previous,
            nextOrderedIDs: reordered
        )
        #expect(reorderPolicy.reorderOnly)
        #expect(!reorderPolicy.animatingDifferences)
        #expect(reorderPolicy.usesReloadDataFallback)

        let largeApply = makeGrid(
            scope: .allMedia,
            paths: (0 ..< MediaGridStructuralApplyPolicy.reloadDataFallbackItemCountThreshold).map { "asset-\($0).jpg" }
        ).orderedAssetIDs
        let largePolicy = MediaGridStructuralApplyPolicy.summarize(
            previousOrderedIDs: [],
            nextOrderedIDs: largeApply
        )
        #expect(largePolicy.largeApply)
        #expect(!largePolicy.animatingDifferences)
        #expect(largePolicy.usesReloadDataFallback)
    }

    @Test func tileDetailCacheMergesAndEvictsLeastRecentlyUsedAssets() {
        let firstDetail = makeDetail(path: "a.jpg")
        let secondDetail = makeDetail(path: "b.jpg")
        let thirdDetail = makeDetail(path: "c.jpg")
        var cache = MediaTileDetailCache(limit: 2)

        cache.merge([firstDetail.id: firstDetail, secondDetail.id: secondDetail])
        #expect(cache.count == 2)
        #expect(cache.detail(for: firstDetail.id) == firstDetail)

        cache.merge([thirdDetail.id: thirdDetail])
        #expect(cache.count == 2)
        #expect(cache.detail(for: firstDetail.id) == firstDetail)
        #expect(cache.detail(for: secondDetail.id) == nil)
        #expect(cache.detail(for: thirdDetail.id) == thirdDetail)
    }
}

@MainActor
private func makeGrid(scope: SidebarSelection, paths: [String]) -> CatalogMediaGridState {
    let assets = paths.map { makeAssetID(path: $0) }
    return CatalogMediaGridState(
        scope: scope,
        orderedAssetIDs: assets
    )
}

@MainActor
private func makeAssetID(path: String) -> MediaAssetID {
    MediaAssetID(
        libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
        relativePath: MediaRelativePath(rawValue: path)
    )
}

@MainActor
private func makeDetail(path: String) -> MediaTileDetail {
    MediaTileDetail(
        libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
        relativePath: MediaRelativePath(rawValue: path)
    )
}

@MainActor
private func isNone(_ action: MediaAssetCollectionApplyGate.Action) -> Bool {
    if case .none = action {
        return true
    }
    return false
}
