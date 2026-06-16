import SwiftUI

struct MediaTableView: View {
    let title: String
    let assets: [MediaAsset]
    let emptyState: CatalogMediaEmptyState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if assets.isEmpty {
                ContentUnavailableView(
                    emptyState.title,
                    systemImage: emptyState.systemImage,
                    description: Text(emptyState.message)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(assets) {
                    TableColumn("Library") { asset in
                        Text(asset.libraryDisplayName)
                            .lineLimit(1)
                    }
                    .width(min: 120, ideal: 160)

                    TableColumn("Name") { asset in
                        Text(asset.name ?? "Unknown")
                            .lineLimit(1)
                    }
                    .width(min: 140, ideal: 180)

                    TableColumn("Relative Path") { asset in
                        Text(asset.relativePath.rawValue)
                            .lineLimit(1)
                    }
                    .width(min: 240, ideal: 420)

                    TableColumn("Content Type") { asset in
                        Text(asset.contentTypeIdentifier ?? "Unknown")
                            .lineLimit(1)
                    }
                    .width(min: 120, ideal: 180)

                    TableColumn("Size") { asset in
                        Text(formatByteSize(asset.byteSize))
                            .monospacedDigit()
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Created") { asset in
                        Text(formatDate(asset.createdAt))
                            .lineLimit(1)
                    }
                    .width(min: 160, ideal: 180)

                    TableColumn("Modified") { asset in
                        Text(formatDate(asset.contentModifiedAt))
                            .lineLimit(1)
                    }
                    .width(min: 160, ideal: 180)
                }
            }
        }
        .navigationTitle(title)
    }

    private var header: some View {
        HStack {
            Text(title)
                .font(.title2.weight(.semibold))
            Spacer()
            Text("\(assets.count) files")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func formatByteSize(_ byteSize: Int64?) -> String {
        guard let byteSize else {
            return "Unknown"
        }
        return ByteCountFormatStyle().format(byteSize)
    }

    private func formatDate(_ date: Date?) -> String {
        guard let date else {
            return "Unknown"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

#Preview {
    MediaTableView(
        title: "All Media",
        assets: [
            MediaAsset(
                libraryRootPath: LibraryRootPath(rawValue: "/Users/example/Pictures"),
                libraryDisplayName: "Pictures",
                relativePath: MediaRelativePath(rawValue: "sample.jpg"),
                name: "sample.jpg",
                contentTypeIdentifier: "public.jpeg",
                byteSize: 42000,
                createdAt: Date(),
                contentModifiedAt: Date()
            ),
        ],
        emptyState: .noMedia
    )
}

private extension CatalogMediaEmptyState {
    var title: String {
        switch self {
        case .noMedia:
            "No Media"
        case .noAvailableMedia:
            "No Available Media"
        case .libraryUnavailable:
            "Library Unavailable"
        }
    }

    var message: String {
        switch self {
        case .noMedia:
            "Add a library with media files to begin."
        case .noAvailableMedia:
            "Cataloged media exists, but its libraries are not currently reachable."
        case .libraryUnavailable:
            "The selected library folder is not currently reachable."
        }
    }

    var systemImage: String {
        switch self {
        case .noMedia:
            "photo.on.rectangle"
        case .noAvailableMedia, .libraryUnavailable:
            "externaldrive.badge.questionmark"
        }
    }
}
