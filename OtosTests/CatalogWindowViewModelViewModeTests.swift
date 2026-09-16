import AppKit
import CoreGraphics
import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// Controllable preview loader for ViewModel pane-identity tests. A `Mutex`-guarded
/// class rather than an actor: its Sendability and initializer are then explicit, and
/// nothing is left to isolation inference. Mutators stay `async` so call sites keep
/// their `await`.
final class FakePreviewLoader: PreviewLoading {
    struct Pending {
        let id: MediaAssetID
        let continuation: CheckedContinuation<PreviewImageLoader.Outcome, Never>
    }

    private struct State {
        var requestedIDs: [MediaAssetID] = []
        var requestedLongEdges: [Int] = []
        var outcomes: [MediaAssetID: PreviewImageLoader.Outcome] = [:]
        var hold = false
        var pending: [Pending] = []
        var defaultOutcome: PreviewImageLoader.Outcome?
    }

    private let state = Mutex(State())

    init() {}

    func setOutcome(_ outcome: PreviewImageLoader.Outcome, for id: MediaAssetID) async {
        state.withLock { $0.outcomes[id] = outcome }
    }

    func setDefaultOutcome(_ outcome: PreviewImageLoader.Outcome) async {
        state.withLock { $0.defaultOutcome = outcome }
    }

    func setHold(_ value: Bool) async {
        state.withLock { $0.hold = value }
    }

    func releaseAll(with outcome: PreviewImageLoader.Outcome) async {
        let waiting: [Pending] = state.withLock { current in
            let waiting = current.pending
            current.pending = []
            return waiting
        }
        for item in waiting {
            item.continuation.resume(returning: outcome)
        }
    }

    func release(id: MediaAssetID, with outcome: PreviewImageLoader.Outcome) async {
        let released: [Pending] = state.withLock { current in
            let matching = current.pending.filter { $0.id == id }
            current.pending.removeAll { $0.id == id }
            return matching
        }
        for item in released {
            item.continuation.resume(returning: outcome)
        }
    }

    func requested() async -> [MediaAssetID] {
        state.withLock { $0.requestedIDs }
    }

    func requestedEdges() async -> [Int] {
        state.withLock { $0.requestedLongEdges }
    }

    func pendingCount() async -> Int {
        state.withLock { $0.pending.count }
    }

    /// A held request that never arrives must fail the test, not fall through: a
    /// release issued before the request is pending leaves that request held forever
    /// and the test awaiting it hangs the whole suite. The deadline is generous because
    /// the parallel suite can make the store's first read slow.
    func waitUntilPending(atLeast count: Int) async {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if state.withLock({ $0.pending.count >= count }) {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("FakePreviewLoader: fewer than \(count) requests became pending within 15 s")
    }

    func waitUntilPending(id: MediaAssetID) async {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if state.withLock({ $0.pending.contains { $0.id == id } }) {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("FakePreviewLoader: \(id.relativePath.rawValue) never became pending within 15 s")
    }

    func preview(for request: PreviewImageLoader.Request) async -> PreviewImageLoader.Outcome {
        let held: Bool = state.withLock { current in
            current.requestedIDs.append(request.id)
            current.requestedLongEdges.append(request.targetLongEdge)
            return current.hold
        }
        if held {
            return await withCheckedContinuation { continuation in
                state.withLock { $0.pending.append(Pending(id: request.id, continuation: continuation)) }
            }
        }
        return state.withLock { $0.outcomes[request.id] ?? $0.defaultOutcome ?? .unavailable }
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
        await fake.release(id: ids[0], with: .image(imageX, nativePixelSize: nil))

        let loupeTask = model.paneRequestTasks[.loupe]
        let imageY = makeViewModeCGImage(seed: 2)
        await fake.release(id: ids[1], with: .image(imageY, nativePixelSize: nil))
        await loupeTask?.value

        #expect(model.panePreviews[.loupe]?.id == ids[1])
        #expect(model.panePreviews[.loupe]?.id != ids[0])
    }

    @Test func loupeStripClickMovesFocusSelectionAndPreview() async {
        let fake = FakePreviewLoader()
        let image = makeViewModeCGImage(seed: 3)
        await fake.setDefaultOutcome(.image(image, nativePixelSize: nil))
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
        await fake.setDefaultOutcome(.image(image, nativePixelSize: nil))
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

    /// One pane resolving must not disturb the other, and a pane whose request resolves
    /// without an image must stop spinning rather than spin forever.
    ///
    /// This replaces a test named `downloadingRetryDoesNotDisturbSiblingPane`, which
    /// asserted that a non-image outcome *set* the spinner — the old model, where the pane
    /// re-requested every 500 ms and the spinner meant "an attempt failed, another is
    /// coming". The spinner now means "a request is outstanding" (APP-023), so the same
    /// outcome must clear it.
    @Test func oneResolvedPaneDoesNotDisturbItsSibling() async {
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
        await fake.release(id: ids[1], with: .image(rightImage, nativePixelSize: nil))
        await rightTask?.value
        #expect(model.panePreviews[.compareRight]?.id == ids[1])

        // While left is still held, its spinner is up and right's image is untouched.
        #expect(model.downloadingSlots.contains(.compareLeft))
        #expect(!model.downloadingSlots.contains(.compareRight))

        let leftTask = model.paneRequestTasks[.compareLeft]
        await fake.release(id: ids[0], with: .unavailable)
        await leftTask?.value
        #expect(
            !model.downloadingSlots.contains(.compareLeft),
            "a resolved request must stop the spinner; there is no retry behind it any more"
        )
        #expect(model.panePreviews[.compareLeft] == nil)
        #expect(model.panePreviews[.compareRight]?.id == ids[1])
    }

    @Test func returnOpensLoupeOnTheArrowNavigatedItem() {
        // Click a tile, then arrow away: native AppKit keyboard nav rewrites
        // selectionIndexPaths and reconciles upward as a single-item live selection.
        // Return (openLoupe(id: nil)) must focus where the arrows landed, not the
        // clicked tile — the double-click path already passes the id explicitly.
        let fake = FakePreviewLoader()
        let model = makeViewModeModel(loader: fake)
        let ids = makeViewModeIDs(count: 4)
        model.applyState(makeViewModeState(orderedIDs: ids))
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)

        _ = model.reconcileNativeSelection([ids[2]])
        model.openLoupe(id: nil)

        #expect(model.focusedAssetID == ids[2])
        #expect(model.gridSelection.selection == [ids[2]])
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
        await fake.setDefaultOutcome(.image(image, nativePixelSize: nil))
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

    @Test func swappingCompareKeepsActivePanePosition() {
        let model = makeViewModeModel(loader: FakePreviewLoader())
        let ids = makeViewModeIDs(count: 3)
        model.applyState(makeViewModeState(orderedIDs: ids))
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)
        _ = model.applyGridClick(hit: ids[1], modifiers: [.command], orderedIDs: ids)
        model.enterCompare()
        model.activateComparePane(.left)

        model.swapComparedPhotos()

        #expect(model.comparePair.left == ids[1])
        #expect(model.comparePair.right == ids[0])
        #expect(model.activeComparePane == .left)
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
        await fake.releaseAll(with: .image(image, nativePixelSize: nil))
        await finalTask?.value
        #expect(!publishedWrong)
        #expect(model.panePreviews[.loupe]?.id == finalFocus)
    }
}

@MainActor
private func makeViewModeModel(loader: FakePreviewLoader) -> CatalogWindowViewModel {
    let temp = PreferencesDomain.suite(UUID().uuidString)
    return CatalogWindowViewModel(
        catalogStore: CatalogStore(location: .inMemory),
        enrichmentCoordinator: nil,
        startsStallMonitor: false,
        startsEnrichment: false,
        startsSourceMonitoring: false,
        preferencesDomain: temp,
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
