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
/// insert/remove changes while suppressing visible motion for reorder-only background
/// applies. Unchanged IDs re-read visible details and reconfigure existing reusable
/// items in place. Decoded thumbnails are supplied by the ViewModel-owned
/// `MediaTileImageCache` so recycled items can repaint synchronously.
/// `MediaAssetCollectionApplyGate` prevents overlapping AppKit applies and keeps
/// only the newest pending value.
/// Frequent bridge activity uses Logger/signposts rather than JSONL so telemetry
/// cannot create file-writing tasks or retain grid state on MainActor.
///
/// Selection is native: `isSelectable` + `allowsMultipleSelection` give click,
/// ⌘-click, ⇧-click, and ⌘A for free, and `NSCollectionView.selectionIndexPaths` is
/// the live selection truth (no separate mirror to drift). Because enrichment and
/// scans re-apply the structure frequently, each structural apply snapshots the
/// selected identities first and restores the survivors by identity afterward, so a
/// background update never loses or shifts the selection. ⌘C / Edit ▸ Copy reaches
/// this controller through the responder chain and writes the selected assets'
/// original file URLs to the pasteboard (ADR 0012), reading no bytes.
struct MediaAssetCollectionView: NSViewControllerRepresentable {
    let grid: CatalogMediaGridState
    var thumbnailDirectory: URL?
    var detailReader: MediaTileDetailReader?
    var imageCache: MediaTileImageCache?
    var stallMonitor: MainRunLoopStallMonitor?
    var diagnostics: CatalogDiagnostics?
    var onViewportChanged: ([MediaAssetID]) -> Void = { _ in }

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
    let collectionView = NSCollectionView()
    let applyGate = MediaAssetCollectionApplyGate()
    var dataSource: NSCollectionViewDiffableDataSource<Section, MediaAssetID>!
    /// Sticky, bounded tile details. Identity order lives in the diffable data source;
    /// this cache preserves best-known rows across scroll, reloadData-class recycling,
    /// and transient query failures so a tile does not downgrade to placeholder merely
    /// because the current visible query returned no row.
    private var tileDetails = MediaTileDetailCache()
    private var detailQueryTask: Task<Void, Never>?
    private var detailQueryGeneration = 0
    var preheatTasks: [MediaAssetID: Task<Void, Never>] = [:]
    struct StructuralApplyCompletionContext {
        let grid: CatalogMediaGridState
        let preservedSelection: Set<MediaAssetID>
        let resetScroll: Bool
        let applyStart: Date
        let insertedCount: Int
        let removedCount: Int
        let reorderOnly: Bool
        let largeApply: Bool
        let animatingDifferences: Bool
        let usesZeroDurationAnimation: Bool
        let signpost: OSSignpostIntervalState
    }

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
        let layoutSignpost = OtosSignpost.ui.beginInterval("MediaGridLayoutReplace")
        collectionView.collectionViewLayout = Self.makeLayout()
        OtosSignpost.ui.endInterval("MediaGridLayoutReplace", layoutSignpost)

        configureCollectionView()
        configureScrollView()
        installScrollObserver()
        OtosLog.ui.info("Media grid layout installed columns=6")
    }

    deinit {
        detailQueryTask?.cancel()
        for task in preheatTasks.values {
            task.cancel()
        }
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
    /// backpressure: one structural apply may run, and any intermediate pending
    /// value is replaced by the newest value rather than queued.
    func receive(_ grid: CatalogMediaGridState) {
        let signpost = OtosSignpost.ui.beginInterval("MediaGridStateReceive")
        defer { OtosSignpost.ui.endInterval("MediaGridStateReceive", signpost) }

        let action = applyGate.receive(grid)
        OtosLog.ui.debug(
            """
            Media grid state received items=\(grid.orderedAssetIDs.count, privacy: .public) \
            scope=\(grid.scope.diagnosticDescription, privacy: .public) \
            action=\(action.diagnosticDescription, privacy: .public)
            """
        )
        performApplyGateAction(action)
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
            asset: assetForTile(assetID),
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

    func performApplyGateAction(_ action: MediaAssetCollectionApplyGate.Action) {
        switch action {
        case .none:
            return
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
        }
    }

    func applyStructure(
        _ grid: CatalogMediaGridState,
        resetScroll: Bool,
        resetSelection: Bool
    ) {
        let operation = stallMonitor?.beginOperation("MediaAssetCollectionViewController.applyStructure")
        let applyStart = Date()
        let summary = MediaGridStructuralApplyPolicy.summarize(
            previousOrderedIDs: applyGate.displayedOrderedIDs,
            nextOrderedIDs: grid.orderedAssetIDs
        )
        // Snapshot the selected identities before the diffable apply can drop or shift
        // them. Query-descriptor changes are user context changes, so they intentionally
        // start from an empty selection instead of restoring surviving identities.
        let preservedSelection = resetSelection ? [] : selectedIdentities()

        // Identity order is the complete structural contract. Details are read
        // for visible identities after the structural apply, so a filename or
        // thumbnail change never requires this O(n) diffable snapshot path.
        let snapshot = mediaSnapshot(for: grid.orderedAssetIDs)

        let signpost = OtosSignpost.ui.beginInterval("MediaGridStructuralApply")
        OtosLog.ui.debug(
            """
            Media grid structural apply started items=\(grid.orderedAssetIDs.count, privacy: .public) \
            scope=\(grid.scope.diagnosticDescription, privacy: .public) \
            resetScroll=\(resetScroll, privacy: .public) \
            reorderOnly=\(summary.reorderOnly, privacy: .public) \
            largeApply=\(summary.largeApply, privacy: .public) \
            animating=\(summary.animatingDifferences, privacy: .public) \
            zeroDuration=\(summary.usesZeroDurationAnimation, privacy: .public)
            """
        )
        let stallMonitor = stallMonitor
        let diagnostics = diagnostics
        let context = StructuralApplyCompletionContext(
            grid: grid,
            preservedSelection: preservedSelection,
            resetScroll: resetScroll,
            applyStart: applyStart,
            insertedCount: summary.insertedCount,
            removedCount: summary.removedCount,
            reorderOnly: summary.reorderOnly,
            largeApply: summary.largeApply,
            animatingDifferences: summary.animatingDifferences,
            usesZeroDurationAnimation: summary.usesZeroDurationAnimation,
            signpost: signpost
        )
        let completion = { [weak self, operation, stallMonitor, diagnostics, context] in
            guard let self else {
                if let operation {
                    stallMonitor?.endOperation(operation)
                }
                return
            }
            completeStructuralApply(
                context,
                operation: operation,
                stallMonitor: stallMonitor,
                diagnostics: diagnostics
            )
        }
        applySnapshot(snapshot, summary: summary, completion: completion)
    }

    private func applySnapshot(
        _ snapshot: NSDiffableDataSourceSnapshot<Section, MediaAssetID>,
        summary: MediaGridStructuralApplyPolicy,
        completion: @escaping () -> Void
    ) {
        guard summary.usesZeroDurationAnimation else {
            dataSource.apply(snapshot, animatingDifferences: true, completion: completion)
            return
        }
        NSAnimationContext.runAnimationGroup { animationContext in
            animationContext.duration = 0
            animationContext.allowsImplicitAnimation = false
            dataSource.apply(snapshot, animatingDifferences: true, completion: completion)
        }
    }

    private func mediaSnapshot(
        for orderedIDs: [MediaAssetID]
    ) -> NSDiffableDataSourceSnapshot<Section, MediaAssetID> {
        var snapshot = NSDiffableDataSourceSnapshot<Section, MediaAssetID>()
        snapshot.appendSections([.media])
        snapshot.appendItems(orderedIDs, toSection: .media)
        return snapshot
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
            let assets = await detailReader.assets(for: visibleIDs)
            if Task.isCancelled {
                OtosSignpost.ui.endInterval("MediaGridVisibleDetailQuery", signpost)
                return
            }
            guard let self, detailQueryGeneration == generation else {
                OtosSignpost.ui.endInterval("MediaGridVisibleDetailQuery", signpost)
                OtosSignpost.ui.emitEvent("MediaGridVisibleDetailQueryDropped")
                return
            }
            mergeTileDetails(assets, reason: reason)
            OtosSignpost.ui.endInterval("MediaGridVisibleDetailQuery", signpost)
            let queryMs = DiagnosticsTiming.milliseconds(since: queryStart)
            OtosLog.ui.debug(
                """
                Media grid visible detail query finished requested=\(visibleIDs.count, privacy: .public) \
                returned=\(assets.count, privacy: .public) reason=\(reason, privacy: .public) \
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
                asset: assetForTile(assetID),
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

    func assetForTile(_ id: MediaAssetID) -> MediaAsset {
        tileDetails.asset(for: id) ?? MediaAsset(
            libraryRootPath: id.libraryRootPath,
            relativePath: id.relativePath,
            name: nil,
            contentTypeIdentifier: nil,
            byteSize: nil,
            createdAt: nil,
            contentModifiedAt: nil
        )
    }

    func mergeTileDetails(_ assets: [MediaAssetID: MediaAsset], reason: String) {
        guard !assets.isEmpty else {
            OtosSignpost.ui.emitEvent("MediaGridTileDetailsMergeEmpty")
            return
        }
        tileDetails.merge(assets)
        let storedCount = tileDetails.count
        OtosSignpost.ui.emitEvent("MediaGridTileDetailsMerged")
        OtosLog.ui.debug(
            """
            Media grid tile details merged incoming=\(assets.count, privacy: .public) \
            stored=\(storedCount, privacy: .public) reason=\(reason, privacy: .public)
            """
        )
    }
}
