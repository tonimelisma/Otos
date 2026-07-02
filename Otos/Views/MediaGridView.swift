import SwiftUI

/// SwiftUI owns the surrounding composition and empty states. The AppKit
/// collection bridge receives one already-ordered, already-filtered grid value
/// and does not derive catalog state inside the view tree.
struct MediaGridView: View {
    let title: String
    let grid: CatalogMediaGridState
    let emptyState: CatalogMediaEmptyState
    var thumbnailDirectory: URL?
    var detailReader: MediaTileDetailReader?
    var onViewportChanged: ([MediaAssetID]) -> Void = { _ in }
    var clearFilters: () -> Void = {}

    var body: some View {
        Group {
            if grid.orderedAssetIDs.isEmpty {
                emptyContent
            } else {
                MediaAssetCollectionView(
                    grid: grid,
                    thumbnailDirectory: thumbnailDirectory,
                    detailReader: detailReader,
                    onViewportChanged: onViewportChanged
                )
            }
        }
        .navigationTitle(title)
    }

    private var emptyContent: some View {
        VStack(spacing: 12) {
            ContentUnavailableView(
                emptyState.title,
                systemImage: emptyState.systemImage,
                description: Text(emptyState.message)
            )
            if emptyState == .noFilterMatches {
                Button("Clear Filters", action: clearFilters)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        emptyState: .noMedia
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
        }
    }
}
