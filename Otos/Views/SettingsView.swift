import SwiftUI
import UniformTypeIdentifiers

/// Settings renders a narrow library-management surface from projected library
/// rows. It can show availability without owning catalog orchestration.
struct SettingsView: View {
    let libraries: [CatalogLibraryState]
    let addLibrary: (URL) -> Void
    let removeLibrary: (LibraryRoot) -> Void

    var body: some View {
        TabView {
            LibrariesSettingsView(
                libraries: libraries,
                addLibrary: addLibrary,
                removeLibrary: removeLibrary
            )
            .tabItem {
                Label("Libraries", systemImage: "folder")
            }
        }
        .frame(width: 660, height: 380)
        .scenePadding()
    }
}

private struct LibrariesSettingsView: View {
    let libraries: [CatalogLibraryState]
    let addLibrary: (URL) -> Void
    let removeLibrary: (LibraryRoot) -> Void

    @State private var showingImporter = false
    @State private var selectedPath: LibraryRootPath?
    @State private var removalCandidate: LibraryRoot?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Libraries")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    showingImporter = true
                } label: {
                    Label("Add Library", systemImage: "plus")
                }
                Button(role: .destructive) {
                    removalCandidate = selectedRoot
                } label: {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(selectedRoot == nil)
            }

            Table(libraries, selection: $selectedPath) {
                TableColumn("Name") { library in
                    Text(library.displayName)
                        .lineLimit(1)
                }
                .width(min: 140, ideal: 180)

                TableColumn("Path") { library in
                    Text(library.path.rawValue)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }

                TableColumn("Availability") { library in
                    Text(library.availability.label)
                        .foregroundStyle(library.isAvailable ? Color.secondary : Color.orange)
                }
                .width(min: 100, ideal: 120)
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                addLibrary(url)
            }
        }
        .alert("Remove Library?", isPresented: removalAlertBinding, presenting: removalCandidate) { root in
            Button("Remove Library", role: .destructive) {
                removeLibrary(root)
                removalCandidate = nil
                selectedPath = nil
            }
            Button("Cancel", role: .cancel) {
                removalCandidate = nil
            }
        } message: { _ in
            Text(
                """
                Original media files will stay on disk. Otos will delete this library's catalog information, \
                and adding it again will require a new scan.
                """
            )
        }
    }

    private var selectedRoot: LibraryRoot? {
        guard let selectedPath else {
            return nil
        }
        return libraries.first { $0.path == selectedPath }?.root
    }

    private var removalAlertBinding: Binding<Bool> {
        Binding {
            removalCandidate != nil
        } set: { isPresented in
            if !isPresented {
                removalCandidate = nil
            }
        }
    }
}

#Preview {
    SettingsView(
        libraries: [
            CatalogLibraryState(
                root: LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures")),
                availability: .available,
                activity: .idle
            ),
        ],
        addLibrary: { _ in },
        removeLibrary: { _ in }
    )
}

private extension LibraryAvailability {
    var label: String {
        switch self {
        case .available:
            "Available"
        case .unavailable:
            "Unavailable"
        }
    }
}
