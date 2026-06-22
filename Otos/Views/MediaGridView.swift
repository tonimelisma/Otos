import SwiftUI

/// SwiftUI owns the surrounding composition and empty states. The AppKit
/// collection bridge receives one already-ordered, already-filtered grid value
/// and does not derive catalog state inside the view tree.
struct MediaGridView: View {
    let title: String
    let grid: CatalogMediaGridState
    let emptyState: CatalogMediaEmptyState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if grid.orderedAssetIDs.isEmpty {
                ContentUnavailableView(
                    emptyState.title,
                    systemImage: emptyState.systemImage,
                    description: Text(emptyState.message)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MediaAssetCollectionView(grid: grid)
            }
        }
        .navigationTitle(title)
    }

    private var header: some View {
        HStack {
            Text(title)
                .font(.title2.weight(.semibold))
            Spacer()
            Text("\(grid.orderedAssetIDs.count) files")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
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
            orderedAssetIDs: [asset.id],
            assetsByID: [asset.id: asset]
        ),
        emptyState: .noMedia
    )
}

private extension CatalogMediaEmptyState {
    var title: String {
        switch self {
        case .noMedia:
            "No Media"
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
        case .checkingLibraries, .libraryChecking:
            "externaldrive.badge.timemachine"
        case .noAvailableMedia, .libraryUnavailable:
            "externaldrive.badge.questionmark"
        }
    }
}
