import AppKit
import CoreGraphics
import Foundation
@testable import Otos
import Synchronization
import Testing

/// Controllable preview loader for ViewModel pane-identity tests.
actor FakePreviewLoader: PreviewLoading {
    struct Pending {
        let id: MediaAssetID
        let continuation: CheckedContinuation<PreviewImageLoader.Outcome, Never>
    }

    private(set) var requestedIDs: [MediaAssetID] = []
    private var outcomes: [MediaAssetID: PreviewImageLoader.Outcome] = [:]
    private var hold = false
    private var pending: [Pending] = []
    private var defaultOutcome: PreviewImageLoader.Outcome?

    func setOutcome(_ outcome: PreviewImageLoader.Outcome, for id: MediaAssetID) {
        outcomes[id] = outcome
    }

    func setDefaultOutcome(_ outcome: PreviewImageLoader.Outcome) {
        defaultOutcome = outcome
    }

    func setHold(_ value: Bool) {
        hold = value
    }

    func releaseAll(with outcome: PreviewImageLoader.Outcome) {
        let waiting = pending
        pending = []
        for item in waiting {
            item.continuation.resume(returning: outcome)
        }
    }

    func release(id: MediaAssetID, with outcome: PreviewImageLoader.Outcome) {
        var remaining: [Pending] = []
        for item in pending {
            if item.id == id {
                item.continuation.resume(returning: outcome)
            } else {
                remaining.append(item)
            }
        }
        pending = remaining
    }

    func requested() -> [MediaAssetID] {
        requestedIDs
    }

    func pendingCount() -> Int {
        pending.count
    }

    func waitUntilPending(atLeast count: Int) async {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if pending.count >= count {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func waitUntilPending(id: MediaAssetID) async {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if pending.contains(where: { $0.id == id }) {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func preview(for request: PreviewImageLoader.Request) async -> PreviewImageLoader.Outcome {
        requestedIDs.append(request.id)
        if hold {
            return await withCheckedContinuation { continuation in
                pending.append(Pending(id: request.id, continuation: continuation))
            }
        }
        if let outcome = outcomes[request.id] {
            return outcome
        }
        if let defaultOutcome {
            return defaultOutcome
        }
        return .unavailable
    }
}

@MainActor
struct CatalogWindowViewModelViewModeTests {
    @Test func staleDecodeDiscardedByIdentity() async {
        let fake = FakePreviewLoader()
        await fake.setHold(true)
        let model = makeViewModeModel(loader: fake)
        let ids = makeViewModeIDs(count: 3)
        model.applyState(makeViewModeState(orderedIDs: ids))
        model.openLoupe(id: ids[0])
        #expect(model.focusedAssetID == ids[0])
        await fake.waitUntilPending(atLeast: 1)

        // Move focus before the first decode completes; owned slot task cancels.
        model.focusNext()
        #expect(model.focusedAssetID == ids[1])
        await fake.waitUntilPending(atLeast: 2)

        let imageX = makeViewModeCGImage(seed: 1)
        await fake.release(id: ids[0], with: .image(imageX))

        let loupeTask = model.paneRequestTasks[.loupe]
        let imageY = makeViewModeCGImage(seed: 2)
        await fake.release(id: ids[1], with: .image(imageY))
        await loupeTask?.value

        #expect(model.panePreviews[.loupe]?.id == ids[1])
        #expect(model.panePreviews[.loupe]?.id != ids[0])
    }

    @Test func loupeStripClickMovesFocusSelectionAndPreview() async {
        let fake = FakePreviewLoader()
        let image = makeViewModeCGImage(seed: 3)
        await fake.setDefaultOutcome(.image(image))
        let model = makeViewModeModel(loader: fake)
        let ids = makeViewModeIDs(count: 4)
        model.applyState(makeViewModeState(orderedIDs: ids))
        model.openLoupe(id: ids[0])
        await model.paneRequestTasks[.loupe]?.value
        #expect(model.panePreviews[.loupe]?.id == ids[0])

        _ = model.applyGridClick(hit: ids[2], modifiers: [], orderedIDs: ids)

        #expect(model.focusedAssetID == ids[2])
        #expect(model.gridSelection.selection == [ids[2]])
        await model.paneRequestTasks[.loupe]?.value
        #expect(model.panePreviews[.loupe]?.id == ids[2])
        let requested = await fake.requested()
        #expect(requested.contains(ids[2]))
    }

    @Test func pairChangeClearsOnlyChangedSlots() async {
        let fake = FakePreviewLoader()
        let image = makeViewModeCGImage(seed: 4)
        await fake.setDefaultOutcome(.image(image))
        let model = makeViewModeModel(loader: fake)
        let ids = makeViewModeIDs(count: 4)
        model.applyState(makeViewModeState(orderedIDs: ids))
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)
        _ = model.applyGridClick(hit: ids[1], modifiers: [.command], orderedIDs: ids)
        model.enterCompare()
        await model.paneRequestTasks[.compareLeft]?.value
        await model.paneRequestTasks[.compareRight]?.value
        #expect(model.panePreviews[.compareLeft]?.id == ids[0])
        #expect(model.panePreviews[.compareRight]?.id == ids[1])
        _ = model.applyGridClick(hit: ids[2], modifiers: [], orderedIDs: ids)
        // Positional: plain click replaces right. (A,B) + C → (A,C). Left keeps A.
        #expect(model.comparePair.left == ids[0])
        #expect(model.comparePair.right == ids[2])
        await model.paneRequestTasks[.compareRight]?.value
        #expect(model.panePreviews[.compareLeft]?.id == ids[0])
        #expect(model.panePreviews[.compareLeft] != nil)
    }

    @Test func downloadingRetryDoesNotDisturbSiblingPane() async {
        let fake = FakePreviewLoader()
        await fake.setHold(true)
        let model = makeViewModeModel(loader: fake)
        let ids = makeViewModeIDs(count: 3)
        model.applyState(makeViewModeState(orderedIDs: ids))
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)
        _ = model.applyGridClick(hit: ids[1], modifiers: [.command], orderedIDs: ids)
        model.enterCompare()
        await fake.waitUntilPending(atLeast: 2)

        let rightTask = model.paneRequestTasks[.compareRight]
        let rightImage = makeViewModeCGImage(seed: 5)
        await fake.release(id: ids[1], with: .image(rightImage))
        await rightTask?.value
        #expect(model.panePreviews[.compareRight]?.id == ids[1])

        let leftTask = model.paneRequestTasks[.compareLeft]
        await fake.release(id: ids[0], with: .downloading)
        await leftTask?.value
        #expect(model.downloadingSlots.contains(.compareLeft))
        #expect(model.panePreviews[.compareRight]?.id == ids[1])
    }

    @Test func compareDoesNotRetargetLoupeFocus() {
        let fake = FakePreviewLoader()
        let model = makeViewModeModel(loader: fake)
        let ids = makeViewModeIDs(count: 4)
        model.applyState(makeViewModeState(orderedIDs: ids))
        model.openLoupe(id: ids[2])
        #expect(model.focusedAssetID == ids[2])

        // Build a two-item selection with modified clicks so loupe focus stays X.
        _ = model.applyGridClick(hit: ids[0], modifiers: [.command], orderedIDs: ids)
        _ = model.applyGridClick(hit: ids[1], modifiers: [.command], orderedIDs: ids)
        model.enterCompare()
        #expect(model.comparePair.members.count == 2)
        // applyComparePair must not stomp loupe focus to panes.left.
        #expect(model.focusedAssetID == ids[2])

        model.exitToGrid()
        #expect(model.focusedAssetID == ids[2])
        model.openLoupe(id: nil)
        let expected = BrowserModePolicy.loupeEntryFocus(
            preferredID: nil,
            selection: model.gridSelection,
            orderedIDs: ids
        )
        #expect(model.focusedAssetID == expected)
    }

    @Test func positionalClickReplacesNamedPane() async {
        let fake = FakePreviewLoader()
        let image = makeViewModeCGImage(seed: 6)
        await fake.setDefaultOutcome(.image(image))
        let model = makeViewModeModel(loader: fake)
        let ids = makeViewModeIDs(count: 5)
        model.applyState(makeViewModeState(orderedIDs: ids))
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)
        _ = model.applyGridClick(hit: ids[1], modifiers: [.command], orderedIDs: ids)
        model.enterCompare()
        #expect(model.comparePair.left == ids[0])
        #expect(model.comparePair.right == ids[1])
        #expect(model.lastReplacedComparePane == .right)

        _ = model.applyGridClick(hit: ids[2], modifiers: [], orderedIDs: ids)
        #expect(model.comparePair.left == ids[0])
        #expect(model.comparePair.right == ids[2])
        #expect(model.lastReplacedComparePane == .right)

        _ = model.applyGridClick(hit: ids[3], modifiers: [.command], orderedIDs: ids)
        #expect(model.comparePair.left == ids[3])
        #expect(model.comparePair.right == ids[2])
        #expect(model.lastReplacedComparePane == .left)
    }

    @Test func rapidArrowStormKeepsFinalFocusIdentity() async throws {
        let fake = FakePreviewLoader()
        await fake.setHold(true)
        let model = makeViewModeModel(loader: fake)
        let ids = makeViewModeIDs(count: 8)
        model.applyState(makeViewModeState(orderedIDs: ids))
        model.openLoupe(id: ids[0])
        await fake.waitUntilPending(atLeast: 1)

        var publishedWrong = false
        for _ in 0 ..< 20 {
            model.focusNext()
            if let preview = model.panePreviews[.loupe],
               preview.id != model.focusedAssetID
            {
                publishedWrong = true
            }
        }
        let finalFocus = try #require(model.focusedAssetID)
        #expect(finalFocus == ids[7] || finalFocus == ids.last)
        await fake.waitUntilPending(id: finalFocus)

        let finalTask = model.paneRequestTasks[.loupe]
        let image = makeViewModeCGImage(seed: 9)
        await fake.releaseAll(with: .image(image))
        await finalTask?.value
        #expect(!publishedWrong)
        #expect(model.panePreviews[.loupe]?.id == finalFocus)
    }
}

@MainActor
private func makeViewModeModel(loader: FakePreviewLoader) -> CatalogWindowViewModel {
    let temp = TemporaryDefaults()
    defer { temp.cleanUp() }
    return CatalogWindowViewModel(
        catalogStore: CatalogStore(location: .inMemory),
        enrichmentCoordinator: nil,
        startsStallMonitor: false,
        startsEnrichment: false,
        startsSourceMonitoring: false,
        preferencesDomain: temp.domain,
        previewLoader: loader
    )
}

private func makeViewModeIDs(count: Int) -> [MediaAssetID] {
    (0 ..< count).map { index in
        MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
            relativePath: MediaRelativePath(rawValue: "vm-\(index).jpg")
        )
    }
}

private func makeViewModeState(orderedIDs: [MediaAssetID]) -> CatalogWindowState {
    CatalogWindowState(
        title: "Test",
        libraries: [],
        removableSources: [],
        mediaGrid: CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: orderedIDs),
        filterOptions: .empty,
        resolvedSidebarSelection: .allMedia,
        mediaEmptyState: .noMedia,
        deviceConnectionBanner: nil,
        queryGeneration: 0
    )
}

private func makeViewModeCGImage(seed: Int) -> CGImage {
    let context = CGContext(
        data: nil,
        width: 16 + seed,
        height: 16,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: CGFloat(seed % 5) / 5, green: 0.3, blue: 0.7, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 16 + seed, height: 16))
    return context.makeImage()!
}
