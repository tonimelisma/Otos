import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// This is the narrow AppKit boundary for the media browser. SwiftUI remains
/// responsible for window composition, while NSCollectionView supplies the
/// reusable, viewport-bounded item lifecycle that the large catalog requires.
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

        record(
            operation: "ui.mediaGrid.layout.replace",
            phase: "finish",
            fields: ["columns": "6"]
        )
    }

    /// Projection already limits incoming state to 10 Hz. This method adds only
    /// AppKit backpressure: one structural apply may run, and any intermediate
    /// pending value is replaced by the newest value rather than queued.
    func receive(_ grid: CatalogMediaGridState) {
        let signpost = OtosSignpost.ui.beginInterval("MediaGridStateReceive")
        defer { OtosSignpost.ui.endInterval("MediaGridStateReceive", signpost) }

        let action = applyGate.receive(grid)
        record(
            operation: "ui.mediaGrid.state.receive",
            phase: "finish",
            fields: [
                "itemCount": "\(grid.orderedAssetIDs.count)",
                "scope": grid.scope.diagnosticDescription,
                "action": action.diagnosticDescription,
            ]
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
            record(
                operation: "ui.mediaGrid.pending",
                phase: replacedExisting ? "replace" : "store"
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
        record(
            operation: "ui.mediaGrid.apply",
            phase: "start",
            fields: [
                "itemCount": "\(grid.orderedAssetIDs.count)",
                "scope": grid.scope.diagnosticDescription,
                "resetScroll": "\(resetScroll)",
            ]
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

            record(
                operation: "ui.mediaGrid.apply",
                phase: "finish",
                fields: [
                    "itemCount": "\(grid.orderedAssetIDs.count)",
                    "scope": grid.scope.diagnosticDescription,
                    "applyMs": "\(DiagnosticsTiming.milliseconds(since: applyStart))",
                ]
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
        record(
            operation: "ui.mediaGrid.visibleReload",
            phase: "finish",
            fields: [
                "visibleItemCount": "\(visibleIndexPaths.count)",
                "reloadMs": "\(DiagnosticsTiming.milliseconds(since: reloadStart))",
            ]
        )
    }

    func scrollToTop() {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func record(operation: String, phase: String, fields: [String: String] = [:]) {
        Task {
            await CatalogDiagnostics.shared.record(
                operation: operation,
                phase: phase,
                fields: fields
            )
        }
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
        Task {
            await CatalogDiagnostics.shared.record(
                operation: "ui.mediaGrid.cell.configureSlow",
                phase: "finish",
                fields: [
                    "assetID": "\(asset.libraryRootPath.rawValue)/\(asset.relativePath.rawValue)",
                    "configureMs": "\(elapsedMs)",
                ]
            )
        }
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
