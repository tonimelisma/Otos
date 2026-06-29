import SwiftUI

/// SidebarView renders projected library rows and reports explicit selection
/// intents. The local Binding exists only to adapt SwiftUI List's control API;
/// selection ownership and asynchronous delivery remain in the ViewModel.
struct SidebarView: View {
    let libraries: [CatalogLibraryState]
    let sidebarSelection: SidebarSelection
    let selectSidebar: @MainActor @Sendable (SidebarSelection) -> Void

    var body: some View {
        List(selection: selectionBinding) {
            Label("All Media", systemImage: "square.grid.2x2")
                .tag(SidebarSelection.allMedia)

            Section("Libraries") {
                ForEach(libraries) { library in
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)

                        Text(library.displayName)
                            .lineLimit(1)
                    }
                    .tag(SidebarSelection.library(library.path))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
    }

    private var selectionBinding: Binding<SidebarSelection> {
        Binding(
            get: { sidebarSelection },
            set: selectSidebar
        )
    }
}

#Preview {
    SidebarView(
        libraries: [
            CatalogLibraryState(
                root: LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures")),
                availability: .available,
                activity: .scanning
            ),
            CatalogLibraryState(
                root: LibraryRoot(path: LibraryRootPath(rawValue: "/Volumes/Archive")),
                availability: .unavailable,
                activity: .idle
            ),
        ],
        sidebarSelection: .allMedia,
        selectSidebar: { _ in }
    )
}
