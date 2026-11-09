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
    let searchLanguages: [String]
    let searchLanguageChoices: [SearchLanguageChoice]
    let setSearchLanguages: ([String]) -> Void
    let immichAccounts: ImmichAccountControls

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
                SearchLanguagesPicker(
                    selected: searchLanguages,
                    choices: searchLanguageChoices,
                    setSelected: setSearchLanguages
                )
            }
            .formStyle(.grouped)
            .frame(width: 520, height: 210)
            .tabItem {
                Label("General", systemImage: "gearshape")
            }

            LibrariesSettingsView(
                libraries: libraries,
                addLibrary: addLibrary,
                removeLibrary: removeLibrary,
                moveLibrary: moveLibrary,
                immichAccounts: immichAccounts
            )
            .frame(width: 640, height: 360)
            .tabItem {
                Label("Libraries", systemImage: "folder")
            }

            RemovableMediaSettingsView(
                sources: removableSources,
                destinations: removableDestinations,
                forgetSource: forgetRemovableSource
            )
            .frame(width: 680, height: 360)
            .tabItem {
                Label("Removable Media", systemImage: "sdcard")
            }

            ImportSettingsView(
                preferences: importPreferences,
                setPreferences: setImportPreferences
            )
            .frame(width: 520, height: 330)
            .tabItem {
                Label("Import", systemImage: "square.and.arrow.down")
            }
        }
        // Each tab sizes the window to itself (Settings: resize per pane), so a short
        // pane is not left mostly empty.
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
        VStack(alignment: .leading, spacing: 8) {
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
            HStack {
                Spacer()
                Button("Forget…", role: .destructive) {
                    forgetCandidate = selectedRoot
                }
                .disabled(selectedRoot == nil)
            }
        }
        .padding(20)
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
    let immichAccounts: ImmichAccountControls

    @State private var showingImporter = false
    @State private var selectedPath: LibraryRootPath?
    @State private var removalCandidate: LibraryRoot?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The same headed table as Removable Media. Dragging a row, its Move Up / Move
            // Down menu items and ⌘↑ / ⌘↓ all call `moveLibrary`.
            Table(of: CatalogLibraryState.self, selection: $selectedPath) {
                TableColumn("Name") { library in
                    Text(library.displayName)
                        .lineLimit(1)
                }
                .width(min: 120, ideal: 160)
                TableColumn("Location") { library in
                    Text(library.root.locationDescription)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                TableColumn("Status") { library in
                    if let status = immichAccounts.statuses[library.path] {
                        Text(status.label)
                            .foregroundStyle(status == .signedOut ? Color.orange : Color.secondary)
                    } else {
                        Text(library.availability.label)
                            .foregroundStyle(library.availability == .unavailable ? Color.orange : Color.secondary)
                    }
                }
                .width(min: 90, ideal: 100)
            } rows: {
                ForEach(libraries) { library in
                    TableRow(library)
                        .draggable(library.path.rawValue)
                }
                .dropDestination(for: String.self) { index, paths in
                    // `index` is the row the drop landed above, in the table as drawn: the
                    // move names that library (or the end), not a position.
                    guard let dropped = paths.first else { return }
                    let anchor = libraries.indices.contains(index) ? libraries[index].path : nil
                    moveLibrary(LibraryRootPath(rawValue: dropped), .before(anchor))
                }
            }
            .contextMenu(forSelectionType: LibraryRootPath.self) { paths in
                if let path = paths.first, let index = libraries.firstIndex(where: { $0.path == path }) {
                    Button("Move Up") { moveLibrary(path, .up) }
                        .disabled(index == 0)
                    Button("Move Down") { moveLibrary(path, .down) }
                        .disabled(index == libraries.count - 1)
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
            HStack {
                Spacer()
                Button("Remove…", role: .destructive) {
                    removalCandidate = selectedRoot
                }
                .disabled(selectedRoot == nil)
                if immichAccounts.isAvailable {
                    // A signed-out account signs in again through the same sheet, with
                    // its server filled in.
                    Button("Sign In…") {
                        immichAccounts.begin(selectedRoot?.remoteBaseURL)
                    }
                    .disabled(selectedRoot.map { immichAccounts.statuses[$0.path] != .signedOut } ?? true)
                    Button("Add Immich Account…") {
                        immichAccounts.begin(nil)
                    }
                }
                Button("Add Library…") {
                    showingImporter = true
                }
            }
        }
        .padding(20)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                addLibrary(url)
            }
        }
        .sheet(isPresented: Binding(
            get: { immichAccounts.sheet != nil },
            set: { presented in
                if !presented {
                    immichAccounts.cancel()
                }
            }
        )) {
            if let sheet = immichAccounts.sheet {
                ImmichAccountSheetView(state: sheet, add: immichAccounts.add, cancel: immichAccounts.cancel)
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
        } message: { root in
            Text(root.kind.removalMessage)
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
        setAsksBeforeLargeTrashDownload: { _ in },
        searchLanguages: ["fi", "en"],
        searchLanguageChoices: [
            SearchLanguageChoice(code: "en", name: "English"),
            SearchLanguageChoice(code: "fi", name: "Finnish"),
        ],
        setSearchLanguages: { _ in },
        immichAccounts: ImmichAccountControls(
            isAvailable: true, statuses: [:], sheet: nil, begin: { _ in }, add: { _, _, _ in }, cancel: {}
        )
    )
}

/// What Settings shows and does for Immich accounts: their statuses, the Add Immich
/// Account sheet, and the intents that open, submit and cancel it.
struct ImmichAccountControls {
    /// False for a window that runs no accounts; the buttons are then not offered.
    let isAvailable: Bool
    let statuses: [LibraryRootPath: ImmichAccountStatus]
    let sheet: ImmichAccountSheetState?
    let begin: @MainActor (URL?) -> Void
    let add: @MainActor (String, String, String) -> Void
    let cancel: @MainActor () -> Void
}

private extension ImmichAccountStatus {
    var label: String {
        switch self {
        case .connecting: "Connecting"
        case .online: "Online"
        case .offline: "Offline"
        case .signedOut: "Signed Out"
        }
    }
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
    /// What removing a library keeps and what it deletes, in the terms of where its
    /// originals live.
    var removalMessage: String {
        switch self {
        case .immichAccount:
            """
            The photos stay on the Immich server. Otos will delete this account's catalog information, \
            thumbnails and previews, and adding it again will download them again.
            """
        case .library, .removableVolume, .deviceMTP:
            """
            Original media files will stay on disk. Otos will delete this library's catalog information, \
            and adding it again will require a new scan.
            """
        }
    }

    var settingsLabel: String {
        switch self {
        case .library:
            "Library"
        case .removableVolume:
            "Card"
        case .deviceMTP:
            "Camera"
        case .immichAccount:
            "Immich"
        }
    }
}

/// Settings ▸ General ▸ Search Languages (DES-108): the languages the user searches in, as a
/// pop-up of checkable languages whose title lists the chosen ones. At least one stays chosen.
struct SearchLanguagesPicker: View {
    let selected: [String]
    let choices: [SearchLanguageChoice]
    let setSelected: ([String]) -> Void

    var body: some View {
        LabeledContent("Search Languages") {
            Menu(title) {
                ForEach(choices) { choice in
                    Toggle(choice.name, isOn: Binding(
                        get: { selected.contains(choice.code) },
                        set: { isOn in
                            let next = isOn ? selected + [choice.code] : selected.filter { $0 != choice.code }
                            if !next.isEmpty {
                                setSelected(next)
                            }
                        }
                    ))
                }
            }
            .fixedSize()
            .disabled(choices.isEmpty)
            .help("Searches in these languages are understood best")
        }
    }

    private var title: String {
        let names = selected.map { code in choices.first { $0.code == code }?.name ?? Locale.current.localizedString(forIdentifier: code) ?? code }
        return ListFormatter.localizedString(byJoining: names)
    }
}
