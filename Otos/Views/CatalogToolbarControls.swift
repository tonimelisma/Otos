import SwiftUI

// Toolbar control guide
//
// These menus render the ViewModel's session descriptor and Projection's scoped
// filter options. They do not query the catalog or derive membership; every
// command calls a ViewModel intent so toolbar and menu-bar actions share the same
// implementation path.

struct CatalogFilterMenu: View {
    let descriptor: CatalogQueryDescriptor
    let options: CatalogFilterOptions
    let setKind: (MediaKind, Bool) -> Void
    let setFileType: (MediaFileTypeOption, MediaKind, Bool) -> Void
    let clearFilters: () -> Void

    var body: some View {
        Menu {
            CatalogFilterMenuContent(
                descriptor: descriptor,
                options: options,
                setKind: setKind,
                setFileType: setFileType,
                clearFilters: clearFilters
            )
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(descriptor.filter.isActive ? Color.accentColor : Color.primary)
        }
        .help(descriptor.filter.isActive ? "Filter (Active)" : "Filter")
    }
}

struct CatalogFilterMenuContent: View {
    let descriptor: CatalogQueryDescriptor
    let options: CatalogFilterOptions
    let setKind: (MediaKind, Bool) -> Void
    let setFileType: (MediaFileTypeOption, MediaKind, Bool) -> Void
    let clearFilters: () -> Void

    var body: some View {
        Toggle("All Items", isOn: allItemsBinding)
        Divider()
        ForEach(availableKinds, id: \.self) { kind in
            Toggle(kind.label, sources: kindToggleSources(kind), isOn: \.isOn)
        }
        if hasFileTypes {
            Divider()
            Menu("File Types") {
                ForEach(availableKinds, id: \.self) { kind in
                    let fileTypes = options.fileTypes(for: kind)
                    if !fileTypes.isEmpty {
                        Section(kind.label) {
                            ForEach(fileTypes, id: \.self) { fileType in
                                Toggle(
                                    fileType.label,
                                    isOn: fileTypeBinding(fileType, kind: kind)
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private var availableKinds: [MediaKind] {
        options.availableKinds
    }

    private var hasFileTypes: Bool {
        availableKinds.contains { !options.fileTypes(for: $0).isEmpty }
    }

    private var allItemsBinding: Binding<Bool> {
        Binding(
            get: { !descriptor.filter.isActive },
            set: { isAllItems in
                if isAllItems {
                    clearFilters()
                }
            }
        )
    }

    /// A collection-backed Toggle gives macOS its native mixed state. Every
    /// source setter calls the one kind-level owner intent, so clicking a mixed
    /// parent still produces one effective descriptor change; repeated setter
    /// calls from SwiftUI become normalized no-ops.
    private func kindToggleSources(_ kind: MediaKind) -> [MenuToggleSource] {
        let fileTypes = options.fileTypes(for: kind)
        if fileTypes.isEmpty {
            return [MenuToggleSource(isOn: kindBinding(kind))]
        }
        return fileTypes.map { fileType in
            MenuToggleSource(isOn: Binding(
                get: { isFileTypeIncluded(fileType, kind: kind) },
                set: { setKind(kind, $0) }
            ))
        }
    }

    private func kindBinding(_ kind: MediaKind) -> Binding<Bool> {
        Binding(
            get: { descriptor.filter.kinds.contains(kind) },
            set: { setKind(kind, $0) }
        )
    }

    private func fileTypeBinding(_ fileType: MediaFileTypeOption, kind: MediaKind) -> Binding<Bool> {
        Binding(
            get: { isFileTypeIncluded(fileType, kind: kind) },
            set: { setFileType(fileType, kind, $0) }
        )
    }

    private func isFileTypeIncluded(_ fileType: MediaFileTypeOption, kind: MediaKind) -> Bool {
        descriptor.filter.kinds.contains(kind)
            || Set(fileType.formats).isSubset(of: descriptor.filter.formats)
    }
}

private struct MenuToggleSource {
    let isOn: Binding<Bool>
}

struct CatalogSortMenu: View {
    let sort: MediaSortOrder
    let setOrder: (MediaSortOrder) -> Void

    var body: some View {
        Menu {
            CatalogSortMenuContent(sort: sort, setOrder: setOrder)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .help("Sort: \(sort.label)")
    }
}

struct CatalogSortMenuContent: View {
    let sort: MediaSortOrder
    let setOrder: (MediaSortOrder) -> Void

    var body: some View {
        Picker("Sort Order", selection: sortBinding) {
            ForEach(MediaSortOrder.allCases, id: \.self) { order in
                Text(order.label).tag(order)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    private var sortBinding: Binding<MediaSortOrder> {
        Binding(
            get: { sort },
            set: { order in setOrder(order) }
        )
    }
}

/// Photos-style discrete thumbnail sizing. The grid itself makes the effect
/// visible, while tooltips and menu commands expose the semantic zoom names.
struct CatalogZoomControl: View {
    let columnCount: Int
    let makeThumbnailsSmaller: () -> Void
    let makeThumbnailsLarger: () -> Void

    var body: some View {
        ControlGroup {
            Button(action: makeThumbnailsSmaller) {
                Image(systemName: "minus")
            }
            .help("Smaller Thumbnails")
            .disabled(columnCount >= GridColumnCount.maximum)

            Button(action: makeThumbnailsLarger) {
                Image(systemName: "plus")
            }
            .help("Larger Thumbnails")
            .disabled(columnCount <= GridColumnCount.minimum)
        }
        .accessibilityLabel("Thumbnail Size")
    }
}

/// Segmented Grid / Loupe / Compare control. All three call the same ViewModel
/// `setViewMode` intent as the View menu (⌘1 / ⌘2 / ⌘3).
struct ViewModePicker: View {
    let viewMode: BrowserViewMode
    let setViewMode: (BrowserViewMode) -> Void

    var body: some View {
        Picker("View Mode", selection: modeBinding) {
            ForEach(BrowserViewMode.allCases) { mode in
                Image(systemName: mode.systemImage)
                    .tag(mode)
                    .help(mode.help)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help(viewMode.help)
        .accessibilityLabel("View Mode")
    }

    private var modeBinding: Binding<BrowserViewMode> {
        Binding(
            get: { viewMode },
            set: { setViewMode($0) }
        )
    }
}
