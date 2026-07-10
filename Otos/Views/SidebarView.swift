import SwiftUI

/// SidebarView renders projected library rows and reports explicit selection
/// intents. The local Binding exists only to adapt SwiftUI List's control API;
/// selection ownership and asynchronous delivery remain in the ViewModel.
struct SidebarView: View {
    let showsAllMedia: Bool
    let libraries: [CatalogLibraryState]
    let importBatches: [ImportBatchSummary]
    let removableSources: [CatalogLibraryState]
    let sidebarSelection: SidebarSelection
    let ejectingSourceIdentities: Set<String>
    let selectSidebar: @MainActor @Sendable (SidebarSelection) -> Void
    let ejectSource: @MainActor @Sendable (LibraryRoot) -> Void

    var body: some View {
        List(selection: selectionBinding) {
            if showsAllMedia {
                SidebarRow(systemImage: "square.grid.2x2", title: "All Media") {
                    EmptyView()
                }
                .tag(SidebarSelection.allMedia)
            }

            Section("Libraries") {
                ForEach(libraries) { library in
                    SidebarRow(systemImage: "folder", title: library.displayName) {
                        EmptyView()
                    }
                    .tag(SidebarSelection.library(library.path))
                }
            }

            if !importBatches.isEmpty {
                Section("Imports") {
                    ForEach(importBatches, id: \.batchID) { batch in
                        SidebarRow(
                            systemImage: "square.and.arrow.down.on.square",
                            title: ImportBatchFormatting.sidebarTitle(
                                for: batch.batchID,
                                among: importBatches
                            )
                        ) {
                            Text("\(batch.assetCount)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .tag(SidebarSelection.importBatch(batch.batchID))
                    }
                }
            }

            let connectedSources = SidebarSelectionPolicy.sidebarVisibleRemovableSources(removableSources)
            if !connectedSources.isEmpty {
                Section("Removable") {
                    ForEach(connectedSources) { source in
                        SidebarRow(
                            systemImage: source.kind.sidebarSystemImage,
                            title: source.displayName
                        ) {
                            removableTrailingAccessory(for: source)
                        }
                        .tag(SidebarSelection.library(source.path))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
    }

    @ViewBuilder
    private func removableTrailingAccessory(for source: CatalogLibraryState) -> some View {
        if let identity = source.deviceIdentity, ejectingSourceIdentities.contains(identity) {
            ProgressView()
                .controlSize(.small)
        } else if source.isEjectable {
            Button {
                ejectSource(source.root)
            } label: {
                Image(systemName: "eject.fill")
            }
            .buttonStyle(.borderless)
            .help("Eject")
        }
    }

    private var selectionBinding: Binding<SidebarSelection> {
        Binding(
            get: { sidebarSelection },
            set: selectSidebar
        )
    }
}

private struct SidebarRow<Trailing: View>: View {
    let systemImage: String
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 4)
            trailing()
        }
    }
}

#Preview {
    SidebarView(
        showsAllMedia: true,
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
        importBatches: [
            ImportBatchSummary(
                batchID: ImportBatchID(unixMilliseconds: 1_704_067_200_000),
                assetCount: 12
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
        ejectingSourceIdentities: [],
        selectSidebar: { _ in },
        ejectSource: { _ in }
    )
}
