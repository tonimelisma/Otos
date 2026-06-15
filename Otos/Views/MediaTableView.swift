import SwiftUI

struct MediaTableView: View {
    let title: String
    let assets: [MediaAsset]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if assets.isEmpty {
                ContentUnavailableView("No Media", systemImage: "photo.on.rectangle")
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
        ]
    )
}
