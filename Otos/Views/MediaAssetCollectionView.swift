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
/// Identity order is structural; the asset map is detail. A structural change
/// performs one nonanimated diffable apply, while unchanged IDs replace the map
/// and reconfigure existing visible reusable items in place. `MediaAssetCollectionApplyGate`
/// prevents overlapping AppKit applies and keeps only the newest pending value.
/// Frequent bridge activity uses Logger/signposts rather than JSONL so telemetry
/// cannot create file-writing tasks or retain grid state on MainActor.
struct MediaAssetCollectionView: NSViewControllerRepresentable {
    let grid: CatalogMediaGridState
    var thumbnailDirectory: URL?
    var onViewportChanged: ([MediaAssetID]) -> Void = { _ in }

    func makeNSViewController(context _: Context) -> MediaAssetCollectionViewController {
        MediaAssetCollectionViewController()
    }

    func updateNSViewController(
        _ controller: MediaAssetCollectionViewController,
        context _: Context
    ) {
        controller.thumbnailDirectory = thumbnailDirectory
        controller.onViewportChanged = onViewportChanged
        controller.receive(grid)
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
    /// This map is the latest detail payload for the identities owned by the
    /// diffable data source. Replacing it does not itself change collection
    /// structure, which is why detail updates can stay viewport-bounded.
    private var assetsByID: [MediaAssetID: MediaAsset] = [:]

    /// Set by the representable each SwiftUI update. Tiles resolve `thumbnailPath`
    /// against this directory; the scroll observer reports visible identities here.
    var thumbnailDirectory: URL?
    var onViewportChanged: ([MediaAssetID]) -> Void = { _ in }

    override func loadView() {
        let layoutSignpost = OtosSignpost.ui.beginInterval("MediaGridLayoutReplace")
        collectionView.collectionViewLayout = Self.makeLayout()
        OtosSignpost.ui.endInterval("MediaGridLayoutReplace", layoutSignpost)

        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = false
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
                  let asset = assetsByID[assetID],
                  let item = collectionView.makeItem(
                      withIdentifier: Self.itemIdentifier,
                      for: indexPath
                  ) as? MediaAssetCollectionItem
            else {
                return nil
            }
            item.configure(asset: asset, thumbnailDirectory: thumbnailDirectory)
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
        case let .refreshVisible(grid, resetScroll):
            assetsByID = grid.assetsByID
            if resetScroll {
                scrollToTop()
            }
            reconfigureVisibleItems(reason: "detailRefresh")
            reportViewport()
        case let .apply(grid, resetScroll):
            applyStructure(grid, resetScroll: resetScroll)
        }
    }

    func applyStructure(_ grid: CatalogMediaGridState, resetScroll: Bool) {
        let applyStart = Date()
        let preservedOrigin = resetScroll ? nil : scrollView.contentView.bounds.origin
        assetsByID = grid.assetsByID

        // Identity order is the complete structural contract. Details remain in
        // assetsByID, so a filename or content-type change never requires this
        // O(n) diffable snapshot path.
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
            reconfigureVisibleItems(reason: "structuralApply")
            reportViewport()

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
            guard let assetID = dataSource.itemIdentifier(for: indexPath),
                  let asset = assetsByID[assetID]
            else {
                missingAssetCount += 1
                continue
            }
            guard let item = collectionView.item(at: indexPath) as? MediaAssetCollectionItem else {
                missingItemCount += 1
                continue
            }
            item.configure(asset: asset, thumbnailDirectory: thumbnailDirectory)
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
}

/// A small, testable state machine keeps imperative AppKit update lifecycle out
/// of SwiftUI. It never queues history: while one apply is active, only the
/// newest requested grid survives.
@MainActor
final class MediaAssetCollectionApplyGate {
    enum Action {
        case none
        case pending(replacedExisting: Bool)
        case refreshVisible(CatalogMediaGridState, resetScroll: Bool)
        case apply(CatalogMediaGridState, resetScroll: Bool)

        var diagnosticDescription: String {
            switch self {
            case .none:
                "none"
            case .pending:
                "pending"
            case .refreshVisible:
                "refreshVisible"
            case .apply:
                "apply"
            }
        }
    }

    private(set) var displayedOrderedIDs: [MediaAssetID] = []
    private(set) var displayedScope: SidebarSelection = .allMedia
    private(set) var isApplyInFlight = false
    private var pendingGrid: CatalogMediaGridState?

    func receive(_ grid: CatalogMediaGridState) -> Action {
        if isApplyInFlight {
            let replacedExisting = pendingGrid != nil
            pendingGrid = grid
            return .pending(replacedExisting: replacedExisting)
        }

        let resetScroll = grid.scope != displayedScope
        if grid.orderedAssetIDs == displayedOrderedIDs {
            displayedScope = grid.scope
            return .refreshVisible(grid, resetScroll: resetScroll)
        }

        isApplyInFlight = true
        return .apply(grid, resetScroll: resetScroll)
    }

    func complete(applied grid: CatalogMediaGridState) -> Action {
        displayedOrderedIDs = grid.orderedAssetIDs
        displayedScope = grid.scope
        isApplyInFlight = false

        guard let pendingGrid else {
            return .none
        }
        self.pendingGrid = nil
        return receive(pendingGrid)
    }
}
