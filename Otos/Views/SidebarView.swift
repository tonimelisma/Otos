import SwiftUI

/// SidebarView renders projected library rows and reports explicit selection
/// intents. The local Binding exists only to adapt SwiftUI List's control API;
/// selection ownership and asynchronous delivery remain in the ViewModel.
struct SidebarView: View {
    let libraries: [CatalogLibraryState]
    let removableSources: [CatalogLibraryState]
    let sidebarSelection: SidebarSelection
    let selectSidebar: @MainActor @Sendable (SidebarSelection) -> Void
    let ejectSource: @MainActor @Sendable (LibraryRoot) -> Void

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

            let connectedSources = removableSources.filter(\.isAvailable)
            if !connectedSources.isEmpty {
                Section("Removable") {
                    ForEach(connectedSources) { source in
                        HStack(spacing: 10) {
                            Image(systemName: source.kind.sidebarSystemImage)
                                .foregroundStyle(.secondary)
                                .frame(width: 16)

                            Text(source.displayName)
                                .lineLimit(1)

                            Spacer(minLength: 4)

                            if source.isEjectable {
                                Button {
                                    ejectSource(source.root)
                                } label: {
                                    Image(systemName: "eject.fill")
                                }
                                .buttonStyle(.borderless)
                                .help("Eject")
                            }
                        }
                        .tag(SidebarSelection.library(source.path))
                    }
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
        removableSources: [
            CatalogLibraryState(
                root: LibraryRoot(
                    path: LibraryRootPath(rawValue: "/Volumes/CARD"),
                    kind: .removableVolume,
                    deviceIdentity: "volume:card",
                    displayName: "CARD",
                    lastSeenAt: Date()
                ),
                availability: .available,
                activity: .idle,
                isEjectable: true
            ),
        ],
        sidebarSelection: .allMedia,
        selectSidebar: { _ in },
        ejectSource: { _ in }
    )
}
