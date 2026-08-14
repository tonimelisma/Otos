import SwiftUI
import UniformTypeIdentifiers

/// Settings renders a narrow library-management surface from projected library
/// rows. It can show availability without owning catalog orchestration.
struct SettingsView: View {
    let libraries: [CatalogLibraryState]
    let removableSources: [CatalogLibraryState]
    let removableDestinations: [LibraryRootPath: LibraryRootPath]
    let addLibrary: (URL) -> Void
    let removeLibrary: (LibraryRoot) -> Void
    let forgetRemovableSource: (LibraryRoot) -> Void
    let importPreferences: ImportPreferences
    let setImportPreferences: (ImportPreferences) -> Void
    let advanceAfterMediaChoice: Bool
    let setAdvanceAfterMediaChoice: (Bool) -> Void

    var body: some View {
        TabView {
            Form {
                Toggle(
                    "Advance after choosing Liked, Not Rated, or Disliked",
                    isOn: Binding(
                        get: { advanceAfterMediaChoice },
                        set: { value in setAdvanceAfterMediaChoice(value) }
                    )
                )
            }
            .formStyle(.grouped)
            .tabItem {
                Label("General", systemImage: "gearshape")
            }

            LibrariesSettingsView(
                libraries: libraries,
                addLibrary: addLibrary,
                removeLibrary: removeLibrary
            )
            .tabItem {
                Label("Libraries", systemImage: "folder")
            }

            RemovableMediaSettingsView(
                sources: removableSources,
                destinations: removableDestinations,
                forgetSource: forgetRemovableSource
            )
            .tabItem {
                Label("Removable Media", systemImage: "sdcard")
            }

            ImportSettingsView(
                preferences: importPreferences,
                setPreferences: setImportPreferences
            )
            .tabItem {
                Label("Import", systemImage: "square.and.arrow.down")
            }
        }
        .frame(width: 660, height: 380)
        .scenePadding()
    }
}

private struct ImportSettingsView: View {
    let preferences: ImportPreferences
    let setPreferences: (ImportPreferences) -> Void

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Import sidecar files (.xmp / .srt)",
                    isOn: binding(\.importSidecarFiles)
                )
                Toggle(
                    "Delete source files after successful import",
                    isOn: binding(\.deleteSourceAfterImport)
                )
                Toggle(
                    "Eject source after successful import",
                    isOn: binding(\.autoEjectAfterImport)
                )
            }

            Section("Destination folders") {
                Picker("Folder policy", selection: binding(\.destinationFolderPolicy)) {
                    Text("None").tag(DestinationFolderPolicy.none)
                    Text("Year / Month").tag(DestinationFolderPolicy.yearMonth)
                }
                Picker("Filename policy", selection: binding(\.destinationNamePolicy)) {
                    Text("Keep original name").tag(DestinationNamePolicy.original)
                    Text("Capture date and time").tag(DestinationNamePolicy.captureDateTime)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<ImportPreferences, Value>
    ) -> Binding<Value> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { newValue in
                var next = preferences
                next[keyPath: keyPath] = newValue
                setPreferences(next)
            }
        )
    }
}

private struct RemovableMediaSettingsView: View {
    let sources: [CatalogLibraryState]
    let destinations: [LibraryRootPath: LibraryRootPath]
    let forgetSource: (LibraryRoot) -> Void

    @State private var selectedPath: LibraryRootPath?
    @State private var forgetCandidate: LibraryRoot?

    private var sortedSources: [CatalogLibraryState] {
        sources.sorted { left, right in
            (left.lastSeenAt ?? .distantPast) > (right.lastSeenAt ?? .distantPast)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Removable Media")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button(role: .destructive) {
                    forgetCandidate = selectedRoot
                } label: {
                    Label("Forget", systemImage: "trash")
                }
                .disabled(selectedRoot == nil)
            }

            Table(sortedSources, selection: $selectedPath) {
                TableColumn("Name") { source in
                    Label(source.displayName, systemImage: source.kind.sidebarSystemImage)
                        .lineLimit(1)
                }
                .width(min: 160, ideal: 200)

                TableColumn("Kind") { source in
                    Text(source.kind.settingsLabel)
                        .foregroundStyle(.secondary)
                }
                .width(min: 100, ideal: 120)

                TableColumn("Destination") { source in
                    if let dest = destinations[source.path] {
                        Text(dest.displayName)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("—")
                            .foregroundStyle(.secondary)
                    }
                }
                .width(min: 140, ideal: 180)

                TableColumn("Last Seen") { source in
                    if let lastSeenAt = source.lastSeenAt {
                        Text(RelativeDateText.string(for: lastSeenAt, now: Date()))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Unknown")
                            .foregroundStyle(.secondary)
                    }
                }
                .width(min: 110, ideal: 130)
            }
        }
        .alert("Forget Removable Media?", isPresented: forgetAlertBinding, presenting: forgetCandidate) { root in
            Button("Forget", role: .destructive) {
                forgetSource(root)
                forgetCandidate = nil
                selectedPath = nil
            }
            Button("Cancel", role: .cancel) {
                forgetCandidate = nil
            }
        } message: { _ in
            Text(
                """
                Otos will delete catalog rows, thumbnails, and device staging for this source. \
                Original files on removable volumes stay where they are.
                """
            )
        }
    }

    private var selectedRoot: LibraryRoot? {
        guard let selectedPath else {
            return nil
        }
        return sources.first { $0.path == selectedPath }?.root
    }

    private var forgetAlertBinding: Binding<Bool> {
        Binding {
            forgetCandidate != nil
        } set: { isPresented in
            if !isPresented {
                forgetCandidate = nil
            }
        }
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
                        .foregroundStyle(
                            library.availability == .unavailable ? Color.orange : Color.secondary
                        )
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
        removableSources: [],
        removableDestinations: [:],
        addLibrary: { _ in },
        removeLibrary: { _ in },
        forgetRemovableSource: { _ in },
        importPreferences: .default,
        setImportPreferences: { _ in },
        advanceAfterMediaChoice: false,
        setAdvanceAfterMediaChoice: { _ in }
    )
}

private extension LibraryAvailability {
    var label: String {
        switch self {
        case .unknown:
            "Checking"
        case .available:
            "Available"
        case .unavailable:
            "Unavailable"
        }
    }
}

private extension LibraryRootKind {
    var settingsLabel: String {
        switch self {
        case .library:
            "Library"
        case .removableVolume:
            "Volume"
        case .deviceMTP:
            "Camera"
        }
    }
}
