import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// Media collection bridge guide
///
/// This is the only AppKit boundary in the media browser. SwiftUI owns window
/// composition and supplies one ordered, scoped value. NSCollectionView owns the
/// imperative viewport, reuse, layout, and diffable-data-source lifecycle that a
/// high-cardinality browser requires.
///
/// Descriptor plus identity order is structural; tile detail is read only for the visible window.
/// A structural change performs one diffable apply, animating small/user-visible
/// insert/remove changes while using AppKit's reloadData-class path for large or
/// reorder-only changes (~110–250 ms at current ~23k scale, not multi-second). Unchanged IDs re-read visible
/// details and reconfigure existing reusable items in place. Paint truth lives in
/// `TileContentStore` alone (monotonic detail + cost-bounded decoded image); the
/// controller owns decode dedup via `inFlightDecodes` and pins the current visible set
/// once per reconfigure/merge/dequeue pass before store mutations so a painted thumbnail
/// cannot be budget-dropped. Scroll-driven detail/preheat work is coalesced on a trailing
/// ~16 ms edge so bounds notifications do not restart Store queries every tick.
/// `MediaGridMutationGate` is the single arbiter for both exclusive collection-view
/// mutations — diffable structural applies and animated zoom swaps — so the two never
/// overlap in either direction; it keeps only the newest pending grid and the newest
/// requested column count, and the controller is a pure executor of the ordered action
/// lists the gate returns (`perform(_:)`).
/// Frequent bridge activity uses OSLog (`op=`/`key=value`) for the agent and interval
/// signposts for Instruments; telemetry must not create file-writing tasks or retain
/// grid state on MainActor.
///
/// Mouse selection is model-owned (spec 0046). `MediaGridCollectionView` (the one
/// collection-view subclass) captures the click at `mouseDown` and does **not** call
/// `super.mouseDown`, so AppKit's native mouse-selection tracking loop never runs and
/// there is no commit to race. It forwards `(hit, modifiers)` to
/// `MediaGridSelectionController.swift`, which computes the gesture against a pure
/// `GridSelection` value (selection + anchor + base) — the single source of truth — and
/// writes `selectionIndexPaths` from the model as the last operation of the gesture. The
/// model is never read from `selectionIndexPaths` to *decide* a gesture;
/// `selectionIndexPaths` is an output, read only to compute the minimal write delta and
/// to reconcile after native keyboard selection (⌘A, ⇧-arrows). Keyboard ⇧+arrow / ⌘A
/// stay native. Because enrichment and scans re-apply the structure frequently, each
/// structural apply snapshots the selected identities first and restores the survivors by
/// identity afterward, pruning the model's anchor/base the same way, so a background
/// update never loses or shifts the selection. ⌘C / Edit ▸ Copy reaches this controller
/// through the responder chain and writes the selected assets' original file URLs to the
/// pasteboard (ADR 0012), reading no bytes.
struct MediaGridBridgeView: NSViewControllerRepresentable {
    let grid: CatalogMediaGridState
    var thumbnailDirectory: URL?
    var detailReader: MediaTileDetailReader?
    var stallMonitor: MainRunLoopStallMonitor?
    var onViewportChanged: ([MediaAssetID]) -> Void = { _ in }
    /// User-adjustable grid density (spec 0048); the ViewModel is the source of truth,
    /// this representable only round-trips it into `receiveColumnCount(_:)`.
    var columnCount: Int = GridColumnCount.defaultValue
    /// The pinch gesture never mutates the layout itself — it requests a new count
    /// through this closure, which the caller wires to the same ViewModel intent the
    /// View menu and toolbar −/+ buttons call directly.
    var onColumnCountChangeRequested: (Int) -> Void = { _ in }

    func makeNSViewController(context _: Context) -> MediaGridViewController {
        MediaGridViewController()
    }

    func updateNSViewController(
        _ controller: MediaGridViewController,
        context _: Context
    ) {
        controller.thumbnailDirectory = thumbnailDirectory
        controller.detailReader = detailReader
        controller.stallMonitor = stallMonitor
        controller.onViewportChanged = onViewportChanged
        controller.onColumnCountChangeRequested = onColumnCountChangeRequested
        controller.receiveColumnCount(columnCount)
        controller.receive(grid)
    }
}

@MainActor
final class MediaGridViewController: NSViewController {
    enum Section: Hashable {
        case media
    }

    private static let itemIdentifier = NSUserInterfaceItemIdentifier("MediaGridItem")

    let scrollView = NSScrollView()
    let collectionView = MediaGridCollectionView()
    /// The single arbiter for both exclusive collection-view mutations (structural applies
    /// and zoom swaps) and the sole owner of column-count truth (`installedColumnCount`,
    /// `requestedColumnCount`). The controller holds no separate column-count state.
    let mutationGate = MediaGridMutationGate()
    var dataSource: NSCollectionViewDiffableDataSource<Section, MediaAssetID>!
    /// Sticky, monotonic tile content (detail + best decoded image). Identity order lives
    /// in the diffable data source; this store is the single paint truth so a tile never
    /// blanks a painted same-asset thumbnail (APP-015 by construction).
    let tileContents = TileContentStore()
    private var detailQueryTask: Task<Void, Never>?
    private var detailQueryGeneration = 0
    /// In-flight decode keys `"id|imageKey"` owned by the controller, not the tile.
    private var inFlightDecodes = Set<String>()
    var preheatTask: Task<Void, Never>?
    var preheatIDs = Set<MediaAssetID>()
    var preheatGeneration = 0
    /// Scroll-bounds diagnostic window: tick/query/preheat counters flushed each second.
    private var scrollBoundsWindowStart = Date()
    private var scrollBoundsTickCount = 0
    private var scrollFlushCount = 0
    private var scrollDetailQueryStarted = 0
    private var scrollDetailQueryCancelled = 0
    private var scrollDetailQuerySkippedUnchanged = 0
    private var scrollPreheatStarted = 0
    private var scrollPreheatReused = 0
    private var scrollWorkDirty = false
    private var scrollCoalesceTask: Task<Void, Never>?
    /// Cancels/restarts on each scroll tick; fires after the shared quiet
    /// threshold to release the mutation gate's scroll hold.
    private var scrollHoldQuietTask: Task<Void, Never>?
    private var lastDetailQueryIDs: [MediaAssetID] = []
    /// Last scroll-bounds notification time. Structural applies suppress move
    /// animation while this is recent (`MediaGridAnimation.suppressesApplyAnimation`).
    private(set) var lastScrollTickAt = Date.distantPast
    /// Reconfigure pin-cost counters (reset each reconfigure).
    private var reconfigurePinCallCount = 0
    private var reconfigurePinElapsed: TimeInterval = 0
    private var reconfigureVisibleIDsElapsed: TimeInterval = 0
    private var decodeStartedCount = 0
    private var decodeAppliedCount = 0
    /// Test hook: pin calls during the last `reconfigureVisibleItems` pass.
    private(set) var lastReconfigurePinCallCount = 0
    /// The model-owned mouse-selection truth (see `MediaGridSelectionController.swift`):
    /// the selected set, the ⇧-range anchor, and the base "islands" a ⇧-range unions with.
    /// `collectionView.selectionIndexPaths` is a render output written from
    /// `gridSelection.selection`, never an input to a gesture computation. Ephemeral,
    /// pruned/cleared alongside the selection — the single selection truth.
    var gridSelection = GridSelection.empty
    /// Bridges a pinch-driven zoom request up to the ViewModel intent; the pinch
    /// gesture never mutates column-count truth or the layout itself — see
    /// `MediaGridZoom.swift`. Column-count truth lives in `mutationGate`.
    var onColumnCountChangeRequested: (Int) -> Void = { _ in }
    /// The item under the gesture location at pinch start, held for the gesture's
    /// duration so a chain of pinch steps all anchor to the same tile.
    var pinchAnchorIndexPath: IndexPath?
    var pinchAccumulatedMagnification: CGFloat = 0

    /// Set by the representable each SwiftUI update. Tiles resolve `thumbnailPath`
    /// against this directory; the scroll observer reports visible identities here.
    var thumbnailDirectory: URL?
    var detailReader: MediaTileDetailReader?
    var stallMonitor: MainRunLoopStallMonitor? {
        didSet {
            stallMonitor?.additionalStallFields = { [weak self] in
                self?.mutationGate.stallDiagnosticFields ?? [:]
            }
        }
    }

    var onViewportChanged: ([MediaAssetID]) -> Void = { _ in }

    override func loadView() {
        let operation = stallMonitor?.beginOperation("MediaGridViewController.layoutInstall")
        defer {
            if let operation {
                stallMonitor?.endOperation(operation)
            }
        }
        let installedColumnCount = mutationGate.installedColumnCount
        let layoutSignpost = OtosSignpost.ui.beginInterval("MediaGridLayoutReplace")
        collectionView.collectionViewLayout = Self.makeLayout(columnCount: installedColumnCount)
        OtosSignpost.ui.endInterval("MediaGridLayoutReplace", layoutSignpost)

        configureCollectionView()
        configureScrollView()
        installScrollObserver()
        configurePinchZoomGesture()
        OtosLog.ui.info("Media grid layout installed columns=\(installedColumnCount, privacy: .public)")
    }

    deinit {
        detailQueryTask?.cancel()
        preheatTask?.cancel()
        scrollCoalesceTask?.cancel()
        scrollHoldQuietTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func scrollBoundsChanged() {
        lastScrollTickAt = Date()
        scrollBoundsTickCount += 1
        scrollWorkDirty = true
        mutationGate.beginScrollHold()
        scheduleScrollHoldQuietRelease()
        scrollCoalesceTask?.cancel()
        scrollCoalesceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else {
                return
            }
            guard scrollWorkDirty else {
                return
            }
            scrollWorkDirty = false
            flushScrollDrivenWork()
        }
        flushScrollBoundsDiagnosticsIfNeeded()
    }

    /// Restart the quiet timer on every tick; when it fires, release scroll hold
    /// and perform any drained gate actions (newest parked grid / pending zoom).
    private func scheduleScrollHoldQuietRelease() {
        scrollHoldQuietTask?.cancel()
        let quietMs = Int(MediaGridAnimation.applyAnimationScrollQuietThreshold * 1000)
        scrollHoldQuietTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(quietMs))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else {
                return
            }
            perform(mutationGate.endScrollHold())
        }
    }

    private func flushScrollDrivenWork() {
        scrollFlushCount += 1
        reportViewport()
        let visibleIDs = visibleAssetIDs()
        guard !visibleIDs.isEmpty else {
            return
        }
        if visibleIDs == lastDetailQueryIDs {
            scrollDetailQuerySkippedUnchanged += 1
        } else if wouldStartVisibleDetailQuery(for: visibleIDs) {
            let hadActiveDetailQuery = detailQueryTask != nil
            let detailCount = requestVisibleDetails(reason: "scroll")
            if detailCount > 0 {
                if hadActiveDetailQuery {
                    scrollDetailQueryCancelled += 1
                }
                scrollDetailQueryStarted += 1
            }
        }
        switch preheatLookahead(reason: "scroll") {
        case .started:
            scrollPreheatStarted += 1
        case .reused:
            scrollPreheatReused += 1
        case .skipped:
            break
        }
    }

    private func flushScrollBoundsDiagnosticsIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(scrollBoundsWindowStart) >= 1.0 else {
            return
        }
        let windowMs = DiagnosticsTiming.milliseconds(since: scrollBoundsWindowStart, now: now)
        OtosLog.ui.noticeOperation(
            "ui.mediaGrid.scrollBounds",
            phase: "window",
            fields: [
                "boundsTickCount": "\(scrollBoundsTickCount)",
                "flushCount": "\(scrollFlushCount)",
                "detailQueryStarted": "\(scrollDetailQueryStarted)",
                "detailQueryCancelled": "\(scrollDetailQueryCancelled)",
                "detailQuerySkippedUnchanged": "\(scrollDetailQuerySkippedUnchanged)",
                "preheatStarted": "\(scrollPreheatStarted)",
                "preheatReused": "\(scrollPreheatReused)",
                "windowMs": "\(windowMs)",
            ]
        )
        scrollBoundsWindowStart = now
        scrollBoundsTickCount = 0
        scrollFlushCount = 0
        scrollDetailQueryStarted = 0
        scrollDetailQueryCancelled = 0
        scrollDetailQuerySkippedUnchanged = 0
        scrollPreheatStarted = 0
        scrollPreheatReused = 0
    }

    /// Maps the currently visible items to their ordered identities and forwards them as
    /// the enrichment priority hint. Visible-only (no look-ahead): the coordinator already
    /// eagerly enriches the rest of the library, so the viewport just reprioritizes.
    func reportViewport() {
        let visible = collectionView.indexPathsForVisibleItems().sorted()
        guard !visible.isEmpty else {
            return
        }
        let ids = visible.compactMap { dataSource.itemIdentifier(for: $0) }
        onViewportChanged(ids)
    }

    /// Projection coalesces incoming background state. This method adds only AppKit
    /// backpressure: while any exclusive mutation is in flight, or while live scroll
    /// holds same-descriptor adoption, the newest grid is parked; descriptor-changed
    /// grids bypass scroll hold. Otherwise the gate decides refresh vs apply.
    func receive(_ grid: CatalogMediaGridState) {
        let signpost = OtosSignpost.ui.beginInterval("MediaGridStateReceive")
        defer { OtosSignpost.ui.endInterval("MediaGridStateReceive", signpost) }

        let actions = mutationGate.receive(grid)
        OtosLog.ui.debug(
            """
            Media grid state received items=\(grid.orderedAssetIDs.count, privacy: .public) \
            scope=\(grid.scope.diagnosticDescription, privacy: .public) \
            actions=\(actions.map(\.diagnosticDescription).joined(separator: ","), privacy: .public)
            """
        )
        perform(actions)
    }

    /// Requests a new column count from any zoom surface (the ViewModel round-trips its
    /// published value here on every SwiftUI update, and the pinch gesture routes through
    /// the same intent). Input, not command: the gate decides whether a swap runs now,
    /// converges at the next completion, or is a no-op.
    func receiveColumnCount(_ requested: Int) {
        perform(mutationGate.receiveColumnCount(requested))
    }
}

extension MediaGridViewController {
    private func configureCollectionView() {
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.onMouseSelection = { [weak self] hit, modifiers in
            self?.applyMouseSelection(hit: hit, modifiers: modifiers)
        }
        collectionView.register(
            MediaGridItem.self,
            forItemWithIdentifier: Self.itemIdentifier
        )

        dataSource = NSCollectionViewDiffableDataSource<Section, MediaAssetID>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, assetID in
            self?.makeCollectionItem(collectionView: collectionView, indexPath: indexPath, assetID: assetID)
        }
    }

    private func makeCollectionItem(
        collectionView: NSCollectionView,
        indexPath: IndexPath,
        assetID: MediaAssetID
    ) -> MediaGridItem? {
        guard let item = collectionView.makeItem(
            withIdentifier: Self.itemIdentifier,
            for: indexPath
        ) as? MediaGridItem else {
            return nil
        }
        tileContents.pin(assetID)
        let change = ensureContentAndMaybeDecode(for: assetID)
        renderItem(item, assetID: assetID, change: change)
        return item
    }

    private func configureScrollView() {
        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        view = scrollView
    }

    private func installScrollObserver() {
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    /// The one executor for the gate's ordered action lists. Every gate method
    /// (`receive`, `receiveColumnCount`, `completeStructuralApply`, `completeZoomSwap`)
    /// funnels through here, so there is a single place each action kind is realized.
    /// The list is already ordered so that a non-exclusive `.refreshVisible` precedes any
    /// trailing exclusive `.apply`/`.zoomSwap`.
    func perform(_ actions: [MediaGridMutationGate.Action]) {
        for action in actions {
            switch action {
            case let .pending(replacedExisting):
                OtosLog.ui.debug(
                    "Media grid pending state replaced=\(replacedExisting, privacy: .public)"
                )
            case let .refreshVisible(_, resetScroll, resetSelection):
                if resetSelection {
                    clearSelection(reason: "descriptorChange")
                }
                if resetScroll {
                    scrollToTop()
                }
                _ = requestVisibleDetails(reason: "detailRefresh")
                reportViewport()
            case let .apply(grid, descriptorChanged):
                applyStructure(
                    grid,
                    resetScroll: descriptorChanged,
                    resetSelection: descriptorChanged,
                    descriptorChanged: descriptorChanged
                )
            case let .zoomSwap(columnCount):
                performZoomSwap(to: columnCount)
            }
        }
    }

    @discardableResult
    func requestVisibleDetails(reason: String) -> Int {
        let visibleIDs = visibleAssetIDs()
        guard !visibleIDs.isEmpty else {
            return 0
        }
        detailQueryGeneration += 1
        let generation = detailQueryGeneration
        detailQueryTask?.cancel()
        lastDetailQueryIDs = visibleIDs

        guard let detailReader else {
            reconfigureVisibleItems(reason: reason)
            return visibleIDs.count
        }

        let queryStart = Date()
        let verbose = OtosUIVerbose.enabled
        let signpost = verbose
            ? OtosSignpost.ui.beginInterval("MediaGridVisibleDetailQuery")
            : nil
        if verbose {
            OtosLog.ui.debug(
                """
                Media grid visible detail query started count=\(visibleIDs.count, privacy: .public) \
                reason=\(reason, privacy: .public)
                """
            )
        }
        detailQueryTask = Task { [weak self, detailReader, visibleIDs] in
            let details = await detailReader.details(for: visibleIDs)
            if Task.isCancelled {
                if let signpost {
                    OtosSignpost.ui.endInterval("MediaGridVisibleDetailQuery", signpost)
                }
                return
            }
            guard let self, detailQueryGeneration == generation else {
                if let signpost {
                    OtosSignpost.ui.endInterval("MediaGridVisibleDetailQuery", signpost)
                }
                return
            }
            mergeTileDetails(details, reason: reason)
            if let signpost {
                OtosSignpost.ui.endInterval("MediaGridVisibleDetailQuery", signpost)
            }
            if OtosUIVerbose.enabled {
                let queryMs = DiagnosticsTiming.milliseconds(since: queryStart)
                OtosLog.ui.debug(
                    """
                    Media grid visible detail query finished requested=\(visibleIDs.count, privacy: .public) \
                    returned=\(details.count, privacy: .public) reason=\(reason, privacy: .public) \
                    queryMs=\(queryMs, privacy: .public)
                    """
                )
            }
            reconfigureVisibleItems(reason: "detailQuery")
        }
        return visibleIDs.count
    }

    func reconfigureVisibleItems(reason: String) {
        let operation = stallMonitor?.beginOperation("MediaGridViewController.reconfigureVisibleItems")
        defer {
            if let operation {
                stallMonitor?.endOperation(operation)
            }
        }
        // Reconfiguring the existing AppKit items preserves their layer contents when the
        // tile content key is unchanged. Offscreen items are intentionally untouched and
        // will read the latest map when AppKit asks for them.
        let visibleIndexPaths = collectionView.indexPathsForVisibleItems().sorted()
        guard !visibleIndexPaths.isEmpty else {
            return
        }
        let reconfigureStart = Date()
        reconfigurePinCallCount = 0
        reconfigurePinElapsed = 0
        reconfigureVisibleIDsElapsed = 0
        lastReconfigurePinCallCount = 0
        let decodeStartsBefore = decodeStartedCount
        let visibleStart = Date()
        let visibleIDs = visibleIndexPaths.compactMap { dataSource.itemIdentifier(for: $0) }
        reconfigureVisibleIDsElapsed += Date().timeIntervalSince(visibleStart)
        let pinStart = Date()
        tileContents.pinVisible(Set(visibleIDs))
        reconfigurePinElapsed += Date().timeIntervalSince(pinStart)
        reconfigurePinCallCount = 1
        lastReconfigurePinCallCount = 1
        let reconfigureSignpost = OtosUIVerbose.enabled
            ? OtosSignpost.ui.beginInterval("MediaGridVisibleReconfigure")
            : nil
        var configuredCount = 0
        var thumbnailLoadsStarted = 0
        var missingAssetCount = 0
        var missingItemCount = 0
        var ensureElapsed: TimeInterval = 0
        var renderElapsed: TimeInterval = 0

        for indexPath in visibleIndexPaths {
            guard let assetID = dataSource.itemIdentifier(for: indexPath) else {
                missingAssetCount += 1
                continue
            }
            guard let item = collectionView.item(at: indexPath) as? MediaGridItem else {
                missingItemCount += 1
                continue
            }
            let ensureStart = Date()
            let change = ensureContentAndMaybeDecode(for: assetID)
            ensureElapsed += Date().timeIntervalSince(ensureStart)
            if case .awaitingDecode = change {
                thumbnailLoadsStarted += 1
            }
            let renderStart = Date()
            renderItem(item, assetID: assetID, change: change)
            renderElapsed += Date().timeIntervalSince(renderStart)
            configuredCount += 1
        }

        if let reconfigureSignpost {
            OtosSignpost.ui.endInterval("MediaGridVisibleReconfigure", reconfigureSignpost)
        }
        let reconfigureMs = DiagnosticsTiming.milliseconds(since: reconfigureStart)
        let decodeStarts = decodeStartedCount - decodeStartsBefore
        let pinMs = max(0, Int((reconfigurePinElapsed * 1000).rounded()))
        let visibleIDsMs = max(0, Int((reconfigureVisibleIDsElapsed * 1000).rounded()))
        let ensureMs = max(0, Int((ensureElapsed * 1000).rounded()))
        let renderMs = max(0, Int((renderElapsed * 1000).rounded()))
        OtosLog.ui.noticeOperation(
            "ui.mediaGrid.reconfigure",
            phase: "finish",
            fields: [
                "visibleCount": "\(configuredCount)",
                "requested": "\(visibleIndexPaths.count)",
                "missingAssets": "\(missingAssetCount)",
                "missingItems": "\(missingItemCount)",
                "pinCallCount": "\(reconfigurePinCallCount)",
                "pinMs": "\(pinMs)",
                "visibleIDsMs": "\(visibleIDsMs)",
                "ensureMs": "\(ensureMs)",
                "renderMs": "\(renderMs)",
                "decodeStarts": "\(decodeStarts)",
                "decodeInFlight": "\(inFlightDecodes.count)",
                "decodeStartedTotal": "\(decodeStartedCount)",
                "decodeAppliedTotal": "\(decodeAppliedCount)",
                "storeImageBytes": "\(tileContents.imageBytes)",
                "thumbnailLoadsStarted": "\(thumbnailLoadsStarted)",
                "reason": reason,
                "reconfigureMs": "\(reconfigureMs)",
            ]
        )
    }

    func scrollToTop() {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func visibleAssetIDs() -> [MediaAssetID] {
        collectionView.indexPathsForVisibleItems()
            .sorted()
            .compactMap { dataSource.itemIdentifier(for: $0) }
    }

    /// Whether a scroll flush would start a new visible detail query for `visibleIDs`.
    func wouldStartVisibleDetailQuery(for visibleIDs: [MediaAssetID]) -> Bool {
        !visibleIDs.isEmpty && visibleIDs != lastDetailQueryIDs
    }

    func contentForTile(_ id: MediaAssetID) -> TileContent? {
        tileContents.content(for: id)
    }

    func mergeTileDetails(_ details: [MediaAssetID: MediaTileDetail], reason: String) {
        guard !details.isEmpty else {
            return
        }
        pinVisibleIDs()
        let changes = tileContents.mergeDetails(details)
        for (id, change) in changes {
            if case .awaitingDecode = change {
                startDecode(for: id)
            }
        }
        let storedCount = tileContents.count
        OtosLog.ui.debug(
            """
            Media grid tile details merged incoming=\(details.count, privacy: .public) \
            stored=\(storedCount, privacy: .public) reason=\(reason, privacy: .public)
            """
        )
    }

    private func renderItem(_ item: MediaGridItem, assetID: MediaAssetID, change: TileContentChange) {
        let content = ensureStoreEntry(for: assetID)
        item.render(content: content, change: change)
    }

    /// Ensures a store entry exists (empty detail stub if needed), starts decode when a
    /// thumbnail is known without an image, and returns the change classification for fade.
    /// Callers own pinning: pass boundaries use `pinVisibleIDs()` / `pinVisible(_:)`;
    /// dequeue binds use additive `tileContents.pin(_:)` for the single asset being bound.
    @discardableResult
    func ensureContentAndMaybeDecode(for id: MediaAssetID) -> TileContentChange {
        if tileContents.content(for: id) == nil {
            _ = tileContents.mergeDetail(
                MediaTileDetail(libraryRootPath: id.libraryRootPath, relativePath: id.relativePath)
            )
        }
        guard let content = tileContents.content(for: id) else {
            return .unchanged
        }
        guard content.detail.thumbnailPath != nil else {
            return content.image == nil ? .detailOnly : .unchanged
        }
        if content.image != nil {
            let expectedKey = MediaAssetTilePresentation.imageContentKey(content.detail)
            if content.imageKey != expectedKey {
                startDecode(for: id)
                return .awaitingDecode(retainsImage: true)
            }
            return .unchanged
        }
        startDecode(for: id)
        return .awaitingDecode(retainsImage: false)
    }

    @discardableResult
    private func ensureStoreEntry(for id: MediaAssetID) -> TileContent? {
        if let content = tileContents.content(for: id) {
            return content
        }
        _ = tileContents.mergeDetail(
            MediaTileDetail(libraryRootPath: id.libraryRootPath, relativePath: id.relativePath)
        )
        return tileContents.content(for: id)
    }

    private func pinVisibleIDs() {
        tileContents.pinVisible(Set(visibleAssetIDs()))
    }

    private func startDecode(for id: MediaAssetID) {
        guard let content = tileContents.content(for: id),
              content.detail.thumbnailPath != nil
        else {
            return
        }
        let key = content.imageKey
        let flightKey = "\(id.libraryRootPath.rawValue)|\(id.relativePath.rawValue)|\(key)"
        guard inFlightDecodes.insert(flightKey).inserted else {
            return
        }
        decodeStartedCount += 1
        let detail = content.detail
        let directory = thumbnailDirectory
        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = MediaAssetTilePresentation.loadImage(detail: detail, thumbnailDirectory: directory)
            await MainActor.run {
                guard let self else {
                    return
                }
                self.inFlightDecodes.remove(flightKey)
                guard let image = loaded.image else {
                    return
                }
                let change = self.tileContents.applyDecoded(image, key: key, for: id)
                guard change == .firstImage || change == .replacedImage else {
                    return
                }
                self.decodeAppliedCount += 1
                self.renderVisibleItem(id: id, change: change)
            }
        }
    }

    func renderVisibleItem(id: MediaAssetID, change: TileContentChange) {
        guard let indexPath = dataSource.indexPath(for: id),
              let item = collectionView.item(at: indexPath) as? MediaGridItem
        else {
            return
        }
        item.render(content: tileContents.content(for: id), change: change)
    }
}
