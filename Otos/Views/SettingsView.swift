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
    let moveLibrary: (LibraryRootPath, LibraryOrderMove) -> Void
    let forgetRemovableSource: (LibraryRoot) -> Void
    let libraryRemovalNotice: LibraryRemovalNotice?
    let dismissLibraryRemovalNotice: () -> Void
    let importPreferences: ImportPreferences
    let setImportPreferences: (ImportPreferences) -> Void
    let advanceAfterMediaChoice: Bool
    let setAdvanceAfterMediaChoice: (Bool) -> Void
    let asksBeforeLargeTrashDownload: Bool
    let setAsksBeforeLargeTrashDownload: (Bool) -> Void

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
                Toggle(
                    "Ask before downloading more than 100 MB to move items to the Trash",
                    isOn: Binding(
                        get: { asksBeforeLargeTrashDownload },
                        set: { value in setAsksBeforeLargeTrashDownload(value) }
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
                removeLibrary: removeLibrary,
                moveLibrary: moveLibrary
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
        .alert(
            libraryRemovalNotice.map(LibraryRemovalNoticePresentation.title) ?? "",
            isPresented: Binding(
                get: { libraryRemovalNotice != nil },
                set: { isPresented in
                    if !isPresented {
                        dismissLibraryRemovalNotice()
                    }
                }
            ),
            presenting: libraryRemovalNotice
        ) { _ in
            Button("OK") {
                dismissLibraryRemovalNotice()
            }
        } message: { notice in
            Text(LibraryRemovalNoticePresentation.message(for: notice))
        }
    }
}

/// The alert for a removal that waits for the library to be free (DES-091), in the
/// user's vocabulary (DES-035): the work it waits for, never lease or owner.
enum LibraryRemovalNoticePresentation {
    static func title(for notice: LibraryRemovalNotice) -> String {
        "\u{201C}\(notice.displayName)\u{201D} Is Busy"
    }

    static func message(for notice: LibraryRemovalNotice) -> String {
        switch notice.waitingFor {
        case .importPublication, .sourceErase:
            "It will be removed from Otos when its import finishes."
        case .mediaTrash:
            "It will be removed from Otos when its items finish moving to the Trash."
        case .reorganization:
            "It will be removed from Otos when its reorganization finishes."
        case .libraryRemoval:
            "It is already being removed from Otos."
        }
    }
}

private struct ImportSettingsView: View {
    let preferences: ImportPreferences
    let setPreferences: (ImportPreferences) -> Void

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Copy sidecars into the library",
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

            // Named for what lands in the library, never Otos's own vocabulary (DES-035,
            // DES-039): "Subfolders: Year / Month", "File names: Capture date and time".
            Section("Destination") {
                Picker("Subfolders", selection: binding(\.destinationFolderPolicy)) {
                    Text("None").tag(DestinationFolderPolicy.none)
                    Text("Year / Month").tag(DestinationFolderPolicy.yearMonth)
                }
                Picker("File names", selection: binding(\.destinationNamePolicy)) {
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
    /// Drag, `Move Up`/`Move Down`, and ⌘↑/⌘↓ all call this one intent (plan
    /// 0092 increment 4) — one user action, one path. Indices are positions in
    /// `libraries`' current (stored) order.
    let moveLibrary: (LibraryRootPath, LibraryOrderMove) -> Void

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

            // List, because only List supports drag-to-reorder (`.onMove`) in
            // this SDK, and drag/Move Up/Move Down/⌘↑/⌘↓ all need to share
            // one path.
            List(selection: $selectedPath) {
                ForEach(Array(libraries.enumerated()), id: \.element.path) { index, library in
                    libraryRow(library)
                        .tag(library.path)
                        .contextMenu {
                            Button("Move Up") { moveLibrary(library.path, .up) }
                                .disabled(index == 0)
                            Button("Move Down") { moveLibrary(library.path, .down) }
                                .disabled(index == libraries.count - 1)
                        }
                }
                .onMove { indices, destination in
                    // `destination` is the row the drop landed above, in the list as
                    // drawn: the move names that library (or the end), not a position.
                    guard let sourceIndex = indices.first else { return }
                    let anchor = libraries.indices.contains(destination) ? libraries[destination].path : nil
                    moveLibrary(libraries[sourceIndex].path, .before(anchor))
                }
            }
            // Invisible, keyboard-only mirrors of the Move Up/Down menu items —
            // ⌘↑/⌘↓ act on the current selection without requiring the context
            // menu to be open (DES-080: reorder is completable from the
            // keyboard alone).
            .background {
                Button("Move Up") { moveSelected(by: -1) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(!canMoveSelected(by: -1))
                    .opacity(0).allowsHitTesting(false)
                Button("Move Down") { moveSelected(by: 1) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .disabled(!canMoveSelected(by: 1))
                    .opacity(0).allowsHitTesting(false)
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

    private func libraryRow(_ library: CatalogLibraryState) -> some View {
        HStack {
            Text(library.displayName)
                .lineLimit(1)
                .frame(minWidth: 140, idealWidth: 180, alignment: .leading)
            Text(library.path.rawValue)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(library.availability.label)
                .foregroundStyle(library.availability == .unavailable ? Color.orange : Color.secondary)
                .frame(minWidth: 100, idealWidth: 120, alignment: .leading)
        }
    }

    private var selectedIndex: Int? {
        guard let selectedPath else {
            return nil
        }
        return libraries.firstIndex { $0.path == selectedPath }
    }

    private func canMoveSelected(by offset: Int) -> Bool {
        guard let selectedIndex else {
            return false
        }
        let destination = selectedIndex + offset
        return libraries.indices.contains(destination)
    }

    private func moveSelected(by offset: Int) {
        guard let selectedPath, canMoveSelected(by: offset) else {
            return
        }
        moveLibrary(selectedPath, offset < 0 ? .up : .down)
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
        moveLibrary: { _, _ in },
        forgetRemovableSource: { _ in },
        libraryRemovalNotice: nil,
        dismissLibraryRemovalNotice: {},
        importPreferences: .default,
        setImportPreferences: { _ in },
        advanceAfterMediaChoice: false,
        setAdvanceAfterMediaChoice: { _ in },
        asksBeforeLargeTrashDownload: true,
        setAsksBeforeLargeTrashDownload: { _ in }
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
