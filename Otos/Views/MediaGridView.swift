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
    /// Centers the grid on this asset after loupe/compare exit (fresh controller).
    var focusTargetID: MediaAssetID?
    var identityRemapEpoch: UInt64 = 0
    var identityRemapBatch: CatalogIdentityRemapBatch?
    var dismissedCameraBannerIdentities: Set<String> = []
    var onDismissCameraBanner: (CatalogDeviceConnectionBanner) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            if let deviceConnectionBanner, !isDismissed(deviceConnectionBanner) {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.horizontal.circle")
                        .foregroundStyle(.secondary)
                    Text(deviceConnectionBanner.message)
                        .font(.callout)
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
                .background(.bar)
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
                        focusTargetID: focusTargetID,
                        identityRemapEpoch: identityRemapEpoch,
                        identityRemapBatch: identityRemapBatch
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(title)
    }

    private var emptyContent: some View {
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

private extension CatalogMediaEmptyState {
    var title: String {
        switch self {
        case .noMedia:
            "No Media"
        case .noFilterMatches:
            "No Matching Media"
        case .checkingLibraries:
            "Checking Libraries"
        case .noAvailableMedia:
            "No Available Media"
        case .libraryChecking:
            "Checking Library"
        case .libraryUnavailable:
            "Library Unavailable"
        case .deviceEnumerating:
            "Reading Items"
        case .catalogIncompatible:
            "Catalog Incompatible"
        }
    }

    var message: String {
        switch self {
        case .noMedia:
            "Add a library with media files to begin."
        case .noFilterMatches:
            "No media in this scope matches the active filters."
        case .checkingLibraries:
            "Otos is checking whether saved library folders are reachable."
        case .noAvailableMedia:
            "Cataloged media exists, but its libraries are not currently reachable."
        case .libraryChecking:
            "Otos is checking whether the selected library folder is reachable."
        case .libraryUnavailable:
            "The selected library folder is not currently reachable."
        case let .deviceEnumerating(name):
            """
            Reading items from \(name). This can take several minutes on this connection. \
            For faster browsing and import, insert the memory card directly or use the camera's Mass Storage USB mode.
            """
        case let .catalogIncompatible(detail):
            detail
        }
    }

    var systemImage: String {
        switch self {
        case .noMedia:
            "photo.on.rectangle"
        case .noFilterMatches:
            "line.3.horizontal.decrease.circle"
        case .checkingLibraries, .libraryChecking:
            "externaldrive.badge.timemachine"
        case .noAvailableMedia, .libraryUnavailable:
            "externaldrive.badge.questionmark"
        case .deviceEnumerating:
            "camera.metering.matrix"
        case .catalogIncompatible:
            "exclamationmark.triangle"
        }
    }

    var isProgressing: Bool {
        if case .deviceEnumerating = self {
            return true
        }
        return false
    }
}
