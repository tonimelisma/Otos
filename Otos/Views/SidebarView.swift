import SwiftUI

struct SidebarView: View {
    let snapshot: CatalogSnapshot
    @Binding var selection: CatalogSelection

    var body: some View {
        List(selection: $selection) {
            Label("All Media", systemImage: "square.grid.2x2")
                .tag(CatalogSelection.allMedia)

            Section("Libraries") {
                ForEach(snapshot.roots) { root in
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(root.displayName)
                                .lineLimit(1)
                            if snapshot.scanningRootPaths.contains(root.path) {
                                Text("Scanning")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .tag(CatalogSelection.library(root.path))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
    }
}

#Preview {
    @Previewable @State var selection = CatalogSelection.allMedia
    SidebarView(
        snapshot: CatalogSnapshot(
            roots: [LibraryRoot(storageID: 1, path: "/Users/example/Pictures")],
            assets: [],
            scanningRootPaths: []
        ),
        selection: $selection
    )
}
