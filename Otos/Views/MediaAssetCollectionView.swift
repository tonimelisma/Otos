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
/// Identity order is structural; tile detail is read only for the visible window.
/// A structural change performs one nonanimated diffable apply, while unchanged
/// IDs re-read visible details and reconfigure existing reusable items in place.
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
        controller.onViewportChanged = onViewportChanged
        controller.receive(grid)
    }
}

struct MediaTileDetailReader {
    private let store: CatalogStore

    init(store: CatalogStore) {
        self.store = store
    }

    func assets(for ids: [MediaAssetID]) async -> [MediaAssetID: MediaAsset] {
        do {
            return try await store.mediaAssets(for: ids)
        } catch {
            OtosLog.catalog.error("Media tile detail query failed")
            return [:]
        }
    }
}

@MainActor
final class MediaAssetCollectionViewController: NSViewController {
    private enum Section: Hashable {
        case media
    }

    private static let itemIdentifier = NSUserInterfaceItemIdentifier("MediaAssetCollectionItem")

    private let scrollView = NSScrollView()
    private let collectionView = NSCollectionView()
    private let applyGate = MediaAssetCollectionApplyGate()
    private var dataSource: NSCollectionViewDiffableDataSource<Section, MediaAssetID>!
    /// Details for the current visible window only. Identity order lives in the
    /// diffable data source; values are faulted after AppKit tells us what is visible.
    private var tileDetailsByID: [MediaAssetID: MediaAsset] = [:]
    private var detailQueryTask: Task<Void, Never>?
    private var detailQueryGeneration = 0

    /// Set by the representable each SwiftUI update. Tiles resolve `thumbnailPath`
    /// against this directory; the scroll observer reports visible identities here.
    var thumbnailDirectory: URL?
    var detailReader: MediaTileDetailReader?
    var onViewportChanged: ([MediaAssetID]) -> Void = { _ in }

    override func loadView() {
        let layoutSignpost = OtosSignpost.ui.beginInterval("MediaGridLayoutReplace")
        collectionView.collectionViewLayout = Self.makeLayout()
        OtosSignpost.ui.endInterval("MediaGridLayoutReplace", layoutSignpost)

        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.delegate = self
        collectionView.register(
            MediaAssetCollectionItem.self,
            forItemWithIdentifier: Self.itemIdentifier
        )

        // AppKit asks for items only as they enter its managed viewport. The
        // provider configures a reused AppKit item directly, avoiding one
        // SwiftUI hosting tree per catalog asset.
        dataSource = NSCollectionViewDiffableDataSource<Section, MediaAssetID>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, assetID in
            guard let self,
                  let item = collectionView.makeItem(
                      withIdentifier: Self.itemIdentifier,
                      for: indexPath
                  ) as? MediaAssetCollectionItem
            else {
                return nil
            }
            item.configure(asset: assetForTile(assetID), thumbnailDirectory: thumbnailDirectory)
            return item
        }

        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        view = scrollView

        // The clip view posts bounds changes as the user scrolls; each is a chance to
        // re-report the visible identities as the enrichment priority hint. The newest
        // -value stream upstream coalesces the bursts, so reporting per tick is cheap.
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )

        OtosLog.ui.info("Media grid layout installed columns=6")
    }

    @objc private func scrollBoundsChanged() {
        reportViewport()
        requestVisibleDetails(reason: "scroll")
    }

    /// Maps the currently visible items to their ordered identities and forwards them as
    /// the enrichment priority hint. Visible-only (no look-ahead): the coordinator already
    /// eagerly enriches the rest of the library, so the viewport just reprioritizes.
    private func reportViewport() {
        let visible = collectionView.indexPathsForVisibleItems().sorted()
        guard !visible.isEmpty else {
            return
        }
        let ids = visible.compactMap { dataSource.itemIdentifier(for: $0) }
        onViewportChanged(ids)
    }

    /// Projection already limits incoming state to 10 Hz. This method adds only
    /// AppKit backpressure: one structural apply may run, and any intermediate
    /// pending value is replaced by the newest value rather than queued.
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
        perform(action)
    }
}

private extension MediaAssetCollectionViewController {
    static func makeLayout() -> NSCollectionViewCompositionalLayout {
        // A counted fractional group expresses the invariant six columns once;
        // AppKit recomputes the square item size as the viewport width changes.
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .fractionalHeight(1)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        item.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)

        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .fractionalWidth(1.0 / 6.0)
        )
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: groupSize,
            subitem: item,
            count: 6
        )
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        return NSCollectionViewCompositionalLayout(section: section)
    }

    func perform(_ action: MediaAssetCollectionApplyGate.Action) {
        switch action {
        case .none:
            return
        case let .pending(replacedExisting):
            OtosSignpost.ui.emitEvent("MediaGridPendingState")
            OtosLog.ui.debug(
                "Media grid pending state replaced=\(replacedExisting, privacy: .public)"
            )
        case let .refreshVisible(_, resetScroll):
            if resetScroll {
                scrollToTop()
            }
            requestVisibleDetails(reason: "detailRefresh")
            reportViewport()
        case let .apply(grid, resetScroll):
            applyStructure(grid, resetScroll: resetScroll)
        }
    }

    func applyStructure(_ grid: CatalogMediaGridState, resetScroll: Bool) {
        let applyStart = Date()
        let preservedOrigin = resetScroll ? nil : scrollView.contentView.bounds.origin
        tileDetailsByID = tileDetailsByID.filter { grid.orderedAssetIDs.contains($0.key) }

        // Snapshot the selected identities before the diffable apply can drop or shift
        // them; the completion restores the survivors by identity (see restoreSelection).
        let preservedSelection = selectedIdentities()

        // Identity order is the complete structural contract. Details are read
        // for visible identities after the structural apply, so a filename or
        // thumbnail change never requires this O(n) diffable snapshot path.
        var snapshot = NSDiffableDataSourceSnapshot<Section, MediaAssetID>()
        snapshot.appendSections([.media])
        snapshot.appendItems(grid.orderedAssetIDs, toSection: .media)

        let signpost = OtosSignpost.ui.beginInterval("MediaGridStructuralApply")
        OtosLog.ui.debug(
            """
            Media grid structural apply started items=\(grid.orderedAssetIDs.count, privacy: .public) \
            scope=\(grid.scope.diagnosticDescription, privacy: .public) \
            resetScroll=\(resetScroll, privacy: .public)
            """
        )
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            OtosSignpost.ui.endInterval("MediaGridStructuralApply", signpost)
            OtosSignpost.ui.emitEvent("MediaGridStructuralApplyCompleted")

            if resetScroll {
                scrollToTop()
            } else if let preservedOrigin {
                scrollView.contentView.scroll(to: preservedOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            requestVisibleDetails(reason: "structuralApply")
            reportViewport()
            restoreSelection(preservedSelection, in: grid.orderedAssetIDs)

            let applyMs = DiagnosticsTiming.milliseconds(since: applyStart)
            OtosLog.ui.info(
                """
                Media grid structural apply finished items=\(grid.orderedAssetIDs.count, privacy: .public) \
                scope=\(grid.scope.diagnosticDescription, privacy: .public) \
                applyMs=\(applyMs, privacy: .public)
                """
            )
            perform(applyGate.complete(applied: grid))
        }
    }

    func requestVisibleDetails(reason: String) {
        let visibleIDs = visibleAssetIDs()
        guard !visibleIDs.isEmpty else {
            return
        }
        detailQueryGeneration += 1
        let generation = detailQueryGeneration
        detailQueryTask?.cancel()

        guard let detailReader else {
            reconfigureVisibleItems(reason: reason)
            return
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
            await MainActor.run {
                guard let self, self.detailQueryGeneration == generation else {
                    OtosSignpost.ui.endInterval("MediaGridVisibleDetailQuery", signpost)
                    OtosSignpost.ui.emitEvent("MediaGridVisibleDetailQueryDropped")
                    return
                }
                self.tileDetailsByID = assets
                OtosSignpost.ui.endInterval("MediaGridVisibleDetailQuery", signpost)
                let queryMs = DiagnosticsTiming.milliseconds(since: queryStart)
                OtosLog.ui.debug(
                    """
                    Media grid visible detail query finished requested=\(visibleIDs.count, privacy: .public) \
                    returned=\(assets.count, privacy: .public) reason=\(reason, privacy: .public) \
                    queryMs=\(queryMs, privacy: .public)
                    """
                )
                self.reconfigureVisibleItems(reason: "detailQuery")
            }
        }
    }

    func reconfigureVisibleItems(reason: String) {
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
            item.configure(asset: assetForTile(assetID), thumbnailDirectory: thumbnailDirectory)
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
        tileDetailsByID[id] ?? MediaAsset(
            libraryRootPath: id.libraryRootPath,
            relativePath: id.relativePath,
            name: nil,
            contentTypeIdentifier: nil,
            byteSize: nil,
            createdAt: nil,
            contentModifiedAt: nil
        )
    }
}

// MARK: - Selection and copy

extension MediaAssetCollectionViewController: NSCollectionViewDelegate {
    /// User clicks drive native selection; we only observe it for telemetry. The
    /// programmatic restore below uses select/deselectItems, which do not call these
    /// delegate methods, so restore cannot feed back into itself.
    func collectionView(_: NSCollectionView, didSelectItemsAt _: Set<IndexPath>) {
        logSelection(reason: "select")
    }

    func collectionView(_: NSCollectionView, didDeselectItemsAt _: Set<IndexPath>) {
        logSelection(reason: "deselect")
    }
}

extension MediaAssetCollectionViewController: NSUserInterfaceValidations {
    /// Edit ▸ Copy and its ⌘C key equivalent are enabled only when something is
    /// selected. AppKit asks this controller because it is the responder-chain object
    /// that implements `copy(_:)`.
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return !collectionView.selectionIndexPaths.isEmpty
        }
        return true
    }
}

extension MediaAssetCollectionViewController {
    /// ⌘C / Edit ▸ Copy arrives here through the responder chain: the collection view is
    /// first responder but does not implement copy:, so the action travels to this
    /// controller. We write the selected assets' original file URLs to the general
    /// pasteboard in display order (ADR 0012). No image or video bytes are read, so copy
    /// is instant and never materializes a dataless cloud original.
    @objc func copy(_: Any?) {
        let ordered = MediaGridSelection.orderedSelection(
            selectedIdentities(),
            in: applyGate.displayedOrderedIDs
        )
        let signpost = OtosSignpost.ui.beginInterval("MediaGridCopy")
        let count = MediaGridClipboard.write(ordered, to: .general)
        OtosSignpost.ui.endInterval("MediaGridCopy", signpost)
        OtosSignpost.ui.emitEvent("MediaGridCopyInvoked")
        OtosLog.ui.info("Media grid copy wrote fileURLs count=\(count, privacy: .public)")
    }

    /// The live selection as stable identities, read from the collection view's own
    /// selection so there is no second copy of selection state to keep in sync.
    func selectedIdentities() -> Set<MediaAssetID> {
        Set(collectionView.selectionIndexPaths.compactMap { dataSource.itemIdentifier(for: $0) })
    }

    /// Restores selection after a structural apply: survivors are the previously
    /// selected identities that still exist. select/deselectItems update the tiles'
    /// rings without re-entering the delegate.
    func restoreSelection(_ preserved: Set<MediaAssetID>, in ordered: [MediaAssetID]) {
        let current = collectionView.selectionIndexPaths
        if !current.isEmpty {
            collectionView.deselectItems(at: current)
        }
        let survivors = MediaGridSelection.pruned(preserved, to: ordered)
        let paths = Set(survivors.compactMap { dataSource.indexPath(for: $0) })
        if !paths.isEmpty {
            collectionView.selectItems(at: paths, scrollPosition: [])
        }
        logSelection(reason: "restore")
    }

    func logSelection(reason: String) {
        let count = collectionView.selectionIndexPaths.count
        OtosSignpost.ui.emitEvent("MediaGridSelectionChanged")
        OtosLog.ui.debug(
            """
            Media grid selection changed count=\(count, privacy: .public) \
            reason=\(reason, privacy: .public)
            """
        )
    }
}
