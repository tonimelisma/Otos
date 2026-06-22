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
/// and reload only visible reusable items. `MediaAssetCollectionApplyGate`
/// prevents overlapping AppKit applies and keeps only the newest pending value.
/// Frequent bridge activity uses Logger/signposts rather than JSONL so telemetry
/// cannot create file-writing tasks or retain grid state on MainActor.
struct MediaAssetCollectionView: NSViewControllerRepresentable {
    let grid: CatalogMediaGridState

    func makeNSViewController(context _: Context) -> MediaAssetCollectionViewController {
        MediaAssetCollectionViewController()
    }

    func updateNSViewController(
        _ controller: MediaAssetCollectionViewController,
        context _: Context
    ) {
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
            item.configure(asset: asset)
            return item
        }

        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        view = scrollView

        OtosLog.ui.info("Media grid layout installed columns=6")
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
            reloadVisibleItems()
            if resetScroll {
                scrollToTop()
            }
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
            reloadVisibleItems()

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

    func reloadVisibleItems() {
        // AppKit may recreate these few visible reusable items. Offscreen items
        // are intentionally untouched and will read the latest map on demand.
        let visibleIndexPaths = collectionView.indexPathsForVisibleItems()
        guard !visibleIndexPaths.isEmpty else {
            return
        }
        let reloadStart = Date()
        let signpost = OtosSignpost.ui.beginInterval("MediaGridVisibleReload")
        collectionView.reloadItems(at: visibleIndexPaths)
        OtosSignpost.ui.endInterval("MediaGridVisibleReload", signpost)
        let reloadMs = DiagnosticsTiming.milliseconds(since: reloadStart)
        OtosLog.ui.debug(
            """
            Media grid visible items reloaded count=\(visibleIndexPaths.count, privacy: .public) \
            reloadMs=\(reloadMs, privacy: .public)
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

private final class MediaAssetCollectionItem: NSCollectionViewItem {
    private var tileView: MediaAssetTileView? {
        view as? MediaAssetTileView
    }

    override func loadView() {
        view = MediaAssetTileView()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        tileView?.prepareForReuse()
    }

    func configure(asset: MediaAsset) {
        guard let tileView else {
            return
        }
        let start = Date()
        tileView.configure(asset: asset)
        let elapsedMs = DiagnosticsTiming.milliseconds(since: start)
        guard elapsedMs >= 5 else {
            return
        }
        OtosSignpost.ui.emitEvent("MediaGridSlowCellConfiguration")
        OtosLog.ui.error(
            """
            Media grid slow cell assetID=\(asset.libraryRootPath.rawValue, privacy: .public)/\
            \(asset.relativePath.rawValue, privacy: .public) configureMs=\(elapsedMs, privacy: .public)
            """
        )
    }
}

private final class MediaAssetTileView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let videoIconView = NSImageView()

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true

        titleField.font = .systemFont(ofSize: 12, weight: .medium)
        titleField.textColor = .labelColor
        titleField.usesSingleLineMode = true
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.cell?.truncatesLastVisibleLine = true
        addSubview(titleField)

        videoIconView.image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: "Video")
        videoIconView.imageScaling = .scaleProportionallyDown
        videoIconView.contentTintColor = .secondaryLabelColor
        addSubview(videoIconView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(asset: MediaAsset) {
        let isVideo = MediaAssetTilePresentation.isVideo(asset)
        titleField.stringValue = MediaAssetTilePresentation.title(asset)
        videoIconView.isHidden = !isVideo
        layer?.backgroundColor = isVideo
            ? NSColor.systemBlue.withAlphaComponent(0.20).cgColor
            : NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor
        setAccessibilityLabel(titleField.stringValue)
        needsLayout = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        titleField.stringValue = ""
        videoIconView.isHidden = true
        setAccessibilityLabel(nil)
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 8
        let iconSize: CGFloat = 13
        let iconVisible = !videoIconView.isHidden
        videoIconView.frame = NSRect(
            x: max(bounds.width - inset - iconSize, inset),
            y: inset,
            width: iconSize,
            height: iconSize
        )
        let iconAllowance = iconVisible ? iconSize + 6 : 0
        titleField.frame = NSRect(
            x: inset,
            y: inset - 1,
            width: max(bounds.width - inset * 2 - iconAllowance, 0),
            height: 17
        )
    }
}

/// Keeps content-type and fallback-title policy independent from reusable AppKit
/// view state so the exact tile classification can be tested directly.
enum MediaAssetTilePresentation {
    static func isVideo(_ asset: MediaAsset) -> Bool {
        guard let identifier = asset.contentTypeIdentifier,
              let contentType = UTType(identifier)
        else {
            return false
        }
        return contentType.conforms(to: .movie)
    }

    static func title(_ asset: MediaAsset) -> String {
        if let name = asset.name {
            return name
        }
        return URL(fileURLWithPath: asset.relativePath.rawValue).lastPathComponent
    }
}
