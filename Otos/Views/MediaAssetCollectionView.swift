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
/// insert/remove changes while using AppKit's reloadData-class diffable fallback
/// for measured-large or reorder-only changes. Unchanged IDs re-read visible
/// details and reconfigure existing reusable items in place. Decoded thumbnails
/// are supplied by the ViewModel-owned `MediaTileImageCache` so recycled items can
/// repaint synchronously.
/// `MediaGridMutationGate` is the single arbiter for both exclusive collection-view
/// mutations — diffable structural applies and animated zoom swaps — so the two never
/// overlap in either direction; it keeps only the newest pending grid and the newest
/// requested column count, and the controller is a pure executor of the ordered action
/// lists the gate returns (`perform(_:)`).
/// Frequent bridge activity uses Logger/signposts rather than JSONL so telemetry
/// cannot create file-writing tasks or retain grid state on MainActor.
///
/// Selection is native: `isSelectable` + `allowsMultipleSelection` give click,
/// ⌘-click, and ⌘A for free, and `NSCollectionView.selectionIndexPaths` is
/// the live selection truth (no separate mirror to drift). ⇧-click is the one
/// exception AppKit does not give for free — it natively toggles only the clicked
/// item, the same as ⌘-click. `MediaGridCollectionView` (the one collection-view
/// subclass) captures the click at `mouseDown` and, after the native tracking loop
/// settles selection, hands the clicked item and modifiers to
/// `MediaAssetCollectionSelection.swift`, which keeps a small anchor/base correction
/// state and applies the full contiguous range as a same-turn delta (spec 0046).
/// Because enrichment and scans re-apply the structure frequently, each structural apply
/// snapshots the selected identities first and restores the survivors by identity
/// afterward, pruning a dangling anchor and its base the same way, so a background update
/// never loses or shifts the selection. ⌘C / Edit ▸ Copy reaches this controller through
/// the responder chain and writes the selected assets' original file URLs to the
/// pasteboard (ADR 0012), reading no bytes.
struct MediaAssetCollectionView: NSViewControllerRepresentable {
    let grid: CatalogMediaGridState
    var thumbnailDirectory: URL?
    var detailReader: MediaTileDetailReader?
    var imageCache: MediaTileImageCache?
    var stallMonitor: MainRunLoopStallMonitor?
    var diagnostics: CatalogDiagnostics?
    var onViewportChanged: ([MediaAssetID]) -> Void = { _ in }
    /// User-adjustable grid density (spec 0048); the ViewModel is the source of truth,
    /// this representable only round-trips it into `receiveColumnCount(_:)`.
    var columnCount: Int = GridColumnCount.defaultValue
    /// The pinch gesture never mutates the layout itself — it requests a new count
    /// through this closure, which the caller wires to the same ViewModel intent the
    /// View menu and toolbar slider call directly.
    var onColumnCountChangeRequested: (Int) -> Void = { _ in }

    func makeNSViewController(context _: Context) -> MediaAssetCollectionViewController {
        MediaAssetCollectionViewController()
    }

    func updateNSViewController(
        _ controller: MediaAssetCollectionViewController,
        context _: Context
    ) {
        controller.thumbnailDirectory = thumbnailDirectory
        controller.detailReader = detailReader
        controller.imageCache = imageCache
        controller.stallMonitor = stallMonitor
        controller.diagnostics = diagnostics
        controller.onViewportChanged = onViewportChanged
        controller.onColumnCountChangeRequested = onColumnCountChangeRequested
        controller.receiveColumnCount(columnCount)
        controller.receive(grid)
    }
}

@MainActor
final class MediaAssetCollectionViewController: NSViewController {
    enum Section: Hashable {
        case media
    }

    private static let itemIdentifier = NSUserInterfaceItemIdentifier("MediaAssetCollectionItem")

    let scrollView = NSScrollView()
    let collectionView = MediaGridCollectionView()
    /// The single arbiter for both exclusive collection-view mutations (structural applies
    /// and zoom swaps) and the sole owner of column-count truth (`installedColumnCount`,
    /// `requestedColumnCount`). The controller holds no separate column-count state.
    let mutationGate = MediaGridMutationGate()
    var dataSource: NSCollectionViewDiffableDataSource<Section, MediaAssetID>!
    /// Sticky, bounded tile details. Identity order lives in the diffable data source;
    /// this cache preserves best-known rows across scroll, reloadData-class recycling,
    /// and transient query failures so a tile does not downgrade to placeholder merely
    /// because the current visible query returned no row.
    private var tileDetails = MediaTileDetailCache()
    private var detailQueryTask: Task<Void, Never>?
    private var detailQueryGeneration = 0
    var preheatTask: Task<Void, Never>?
    var preheatIDs = Set<MediaAssetID>()
    var preheatGeneration = 0
    /// Shift-click range anchor (see `MediaAssetCollectionSelection.swift`). Ephemeral,
    /// pruned/cleared alongside the selection it corrects — never a second selection
    /// truth.
    var selectionAnchorID: MediaAssetID?
    var anchorBaseSelection = Set<MediaAssetID>()
    /// Bridges a pinch-driven zoom request up to the ViewModel intent; the pinch
    /// gesture never mutates column-count truth or the layout itself — see
    /// `MediaAssetCollectionZoom.swift`. Column-count truth lives in `mutationGate`.
    var onColumnCountChangeRequested: (Int) -> Void = { _ in }
    /// The item under the gesture location at pinch start, held for the gesture's
    /// duration so a chain of pinch steps all anchor to the same tile.
    var pinchAnchorIndexPath: IndexPath?
    var pinchAccumulatedMagnification: CGFloat = 0

    /// Set by the representable each SwiftUI update. Tiles resolve `thumbnailPath`
    /// against this directory; the scroll observer reports visible identities here.
    var thumbnailDirectory: URL?
    var detailReader: MediaTileDetailReader?
    var imageCache: MediaTileImageCache?
    var stallMonitor: MainRunLoopStallMonitor?
    var diagnostics: CatalogDiagnostics?
    var onViewportChanged: ([MediaAssetID]) -> Void = { _ in }

    override func loadView() {
        let operation = stallMonitor?.beginOperation("MediaAssetCollectionViewController.layoutInstall")
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
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func scrollBoundsChanged() {
        reportViewport()
        _ = requestVisibleDetails(reason: "scroll")
        preheatLookahead(reason: "scroll")
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
    /// backpressure: while any exclusive mutation (structural apply or zoom swap) is in
    /// flight the newest grid is parked rather than queued; otherwise the gate decides
    /// whether to refresh visible details in place or run one structural apply.
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

extension MediaAssetCollectionViewController {
    private func configureCollectionView() {
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.onMouseSelectionFinished = { [weak self] hit, modifiers in
            self?.mouseSelectionFinished(hit: hit, modifiers: modifiers)
        }
        collectionView.register(
            MediaAssetCollectionItem.self,
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
    ) -> MediaAssetCollectionItem? {
        guard let item = collectionView.makeItem(
            withIdentifier: Self.itemIdentifier,
            for: indexPath
        ) as? MediaAssetCollectionItem else {
            return nil
        }
        _ = item.configure(
            detail: detailForTile(assetID),
            thumbnailDirectory: thumbnailDirectory,
            imageCache: imageCache
        )
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
                OtosSignpost.ui.emitEvent("MediaGridPendingState")
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
            case let .apply(grid, resetScroll, resetSelection):
                applyStructure(grid, resetScroll: resetScroll, resetSelection: resetSelection)
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

        guard let detailReader else {
            reconfigureVisibleItems(reason: reason)
            return visibleIDs.count
        }

        let queryStart = Date()
        let signpost = OtosSignpost.ui.beginInterval("MediaGridVisibleDetailQuery")
        OtosLog.ui.debug(
            """
            Media grid visible detail query started count=\(visibleIDs.count, privacy: .public) \
            reason=\(reason, privacy: .public)
            """
        )
        detailQueryTask = Task { [weak self, detailReader, visibleIDs] in
            let details = await detailReader.details(for: visibleIDs)
            if Task.isCancelled {
                OtosSignpost.ui.endInterval("MediaGridVisibleDetailQuery", signpost)
                return
            }
            guard let self, detailQueryGeneration == generation else {
                OtosSignpost.ui.endInterval("MediaGridVisibleDetailQuery", signpost)
                OtosSignpost.ui.emitEvent("MediaGridVisibleDetailQueryDropped")
                return
            }
            mergeTileDetails(details, reason: reason)
            OtosSignpost.ui.endInterval("MediaGridVisibleDetailQuery", signpost)
            let queryMs = DiagnosticsTiming.milliseconds(since: queryStart)
            OtosLog.ui.debug(
                """
                Media grid visible detail query finished requested=\(visibleIDs.count, privacy: .public) \
                returned=\(details.count, privacy: .public) reason=\(reason, privacy: .public) \
                queryMs=\(queryMs, privacy: .public)
                """
            )
            reconfigureVisibleItems(reason: "detailQuery")
        }
        return visibleIDs.count
    }

    func reconfigureVisibleItems(reason: String) {
        let operation = stallMonitor?.beginOperation("MediaAssetCollectionViewController.reconfigureVisibleItems")
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
        let signpost = OtosSignpost.ui.beginInterval("MediaGridVisibleReconfigure")
        var configuredCount = 0
        var thumbnailLoadsStarted = 0
        var missingAssetCount = 0
        var missingItemCount = 0

        for indexPath in visibleIndexPaths {
            guard let assetID = dataSource.itemIdentifier(for: indexPath) else {
                missingAssetCount += 1
                continue
            }
            guard let item = collectionView.item(at: indexPath) as? MediaAssetCollectionItem else {
                missingItemCount += 1
                continue
            }
            if item.configure(
                detail: detailForTile(assetID),
                thumbnailDirectory: thumbnailDirectory,
                imageCache: imageCache
            ) {
                thumbnailLoadsStarted += 1
            }
            configuredCount += 1
        }

        OtosSignpost.ui.endInterval("MediaGridVisibleReconfigure", signpost)
        let reconfigureMs = DiagnosticsTiming.milliseconds(since: reconfigureStart)
        OtosLog.ui.debug(
            """
            Media grid visible items reconfigured count=\(configuredCount, privacy: .public) \
            requested=\(visibleIndexPaths.count, privacy: .public) \
            missingAssets=\(missingAssetCount, privacy: .public) \
            missingItems=\(missingItemCount, privacy: .public) \
            thumbnailLoadsStarted=\(thumbnailLoadsStarted, privacy: .public) \
            reason=\(reason, privacy: .public) \
            reconfigureMs=\(reconfigureMs, privacy: .public)
            """
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

    func detailForTile(_ id: MediaAssetID) -> MediaTileDetail {
        tileDetails.detail(for: id) ?? MediaTileDetail(
            libraryRootPath: id.libraryRootPath,
            relativePath: id.relativePath
        )
    }

    func mergeTileDetails(_ details: [MediaAssetID: MediaTileDetail], reason: String) {
        guard !details.isEmpty else {
            OtosSignpost.ui.emitEvent("MediaGridTileDetailsMergeEmpty")
            return
        }
        tileDetails.merge(details)
        let storedCount = tileDetails.count
        OtosSignpost.ui.emitEvent("MediaGridTileDetailsMerged")
        OtosLog.ui.debug(
            """
            Media grid tile details merged incoming=\(details.count, privacy: .public) \
            stored=\(storedCount, privacy: .public) reason=\(reason, privacy: .public)
            """
        )
    }
}
