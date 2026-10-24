import SwiftUI

/// SwiftUI owns the surrounding composition and empty states. The AppKit
/// collection bridge receives one already-ordered, already-filtered grid value
/// and does not derive catalog state inside the view tree.
struct MediaGridView: View {
    let title: String
    let grid: CatalogMediaGridState
    var tileContentStore: TileContentStore?
    let emptyState: CatalogMediaEmptyState
    let deviceConnectionBanner: CatalogDeviceConnectionBanner?
    var thumbnailDirectory: URL?
    var detailReader: MediaTileDetailReader?
    var stallMonitor: MainRunLoopStallMonitor?
    var onViewportChanged: ([MediaAssetID]) -> Void = { _ in }
    var clearFilters: () -> Void = {}
    var gridColumnCount: Int = GridColumnCount.defaultValue
    var onGridColumnCountChangeRequested: (Int) -> Void = { _ in }
    var selectionHandlers: MediaGridSelectionHandlers = .init()
    var onItemDoubleClick: (MediaAssetID) -> Void = { _ in }
    var onReturnKey: () -> Void = {}
    var onMediaChoiceKey: (MediaChoice) -> Void = { _ in }
    var onMediaChoice: (MediaAssetID, MediaChoice) -> Void = { _, _ in }
    var contextMenu: () -> NSMenu? = { nil }
    /// Centers the grid on this asset after loupe/compare exit (fresh controller).
    var focusTargetID: MediaAssetID?
    var dismissedCameraBannerIdentities: Set<DeviceIdentity> = []
    var onDismissCameraBanner: (CatalogDeviceConnectionBanner) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            if let deviceConnectionBanner, !isDismissed(deviceConnectionBanner) {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.horizontal.circle")
                        .foregroundStyle(.secondary)
                    Text(deviceConnectionBanner.message)
                        .font(.callout)
                        .foregroundStyle(DesignPalette.label(for: colorScheme))
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button {
                        dismiss(deviceConnectionBanner)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(DesignPalette.bar(for: colorScheme))
            }

            Group {
                if grid.orderedAssetIDs.isEmpty {
                    emptyContent
                } else {
                    MediaGridBridgeView(
                        grid: grid,
                        tileContentStore: tileContentStore,
                        thumbnailDirectory: thumbnailDirectory,
                        detailReader: detailReader,
                        stallMonitor: stallMonitor,
                        onViewportChanged: onViewportChanged,
                        columnCount: gridColumnCount,
                        onColumnCountChangeRequested: onGridColumnCountChangeRequested,
                        selectionHandlers: selectionHandlers,
                        presentation: .grid(columnCount: gridColumnCount),
                        onItemDoubleClick: onItemDoubleClick,
                        onReturnKey: onReturnKey,
                        onMediaChoiceKey: onMediaChoiceKey,
                        onMediaChoice: onMediaChoice,
                        contextMenu: contextMenu,
                        focusTargetID: focusTargetID
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // DES-022's content surface. Without it the grid shows the raw window
            // background, and the surface order has no base: `bar` and `sidebar` were
            // painted while `content` had no caller at all, so nothing chrome sat on
            // was ever the value the order is measured against, and the day bar read
            // as an unexplained band rather than as a step above the content beneath
            // it. Loupe and Compare own their own darker surface deliberately, so
            // this is the grid's alone.
            .background(DesignPalette.content(for: colorScheme))
        }
        .navigationTitle(title)
    }

    @ViewBuilder
    private var emptyContent: some View {
        // Before the first catalog load nothing is known, so nothing is said (APP-044).
        if emptyState == .loadingCatalog {
            Color.clear
        } else {
            knownEmptyContent
        }
    }

    private var knownEmptyContent: some View {
        VStack(spacing: 12) {
            if emptyState.isProgressing {
                ProgressView()
                    .controlSize(.large)
            }
            ContentUnavailableView {
                Label(emptyState.title, systemImage: emptyState.systemImage)
            } description: {
                Text(emptyState.message)
            }
            if emptyState == .noFilterMatches {
                Button("Clear Filters", action: clearFilters)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func isDismissed(_ banner: CatalogDeviceConnectionBanner) -> Bool {
        dismissedCameraBannerIdentities.contains(banner.identity)
    }

    private func dismiss(_ banner: CatalogDeviceConnectionBanner) {
        onDismissCameraBanner(banner)
    }
}

#Preview {
    let asset = MediaAsset(
        libraryRootPath: LibraryRootPath(rawValue: "/Users/example/Pictures"),
        relativePath: MediaRelativePath(rawValue: "sample.jpg"),
        name: "sample.jpg",
        contentTypeIdentifier: "public.jpeg",
        byteSize: 42000,
        createdAt: Date(),
        contentModifiedAt: Date()
    )
    MediaGridView(
        title: "All Media",
        grid: CatalogMediaGridState(
            scope: .allMedia,
            orderedAssetIDs: [asset.id]
        ),
        emptyState: .noMedia,
        deviceConnectionBanner: nil
    )
}
