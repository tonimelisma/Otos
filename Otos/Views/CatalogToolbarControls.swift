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
    let toggleKind: (MediaKind, [MediaFormatToken]) -> Void
    let toggleFormat: (MediaFormatToken, MediaKind) -> Void
    let clearFilters: () -> Void

    var body: some View {
        Menu {
            CatalogFilterMenuContent(
                descriptor: descriptor,
                options: options,
                toggleKind: toggleKind,
                toggleFormat: toggleFormat,
                clearFilters: clearFilters
            )
        } label: {
            Image(systemName: descriptor.filter.isActive
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease")
        }
        .help("Filter")
    }
}

struct CatalogFilterMenuContent: View {
    let descriptor: CatalogQueryDescriptor
    let options: CatalogFilterOptions
    let toggleKind: (MediaKind, [MediaFormatToken]) -> Void
    let toggleFormat: (MediaFormatToken, MediaKind) -> Void
    let clearFilters: () -> Void

    var body: some View {
        if descriptor.filter.isActive {
            Button("Show Everything", action: clearFilters)
            Divider()
        }
        ForEach(availableKinds, id: \.self) { kind in
            let formats = options.formats(for: kind)
            Button {
                toggleKind(kind, formats)
            } label: {
                Label(kind.label, systemImage: kindSymbol(kind, formats: formats))
            }
            ForEach(formats, id: \.self) { format in
                Button {
                    toggleFormat(format, kind)
                } label: {
                    Label(format.rawValue, systemImage: formatSymbol(format))
                }
            }
            if kind != availableKinds.last {
                Divider()
            }
        }
    }

    private var availableKinds: [MediaKind] {
        options.availableKinds
    }

    private func kindSymbol(_ kind: MediaKind, formats: [MediaFormatToken]) -> String {
        if descriptor.filter.kinds.contains(kind) {
            return "checkmark"
        }
        if formats.contains(where: { descriptor.filter.formats.contains($0) }) {
            return "minus"
        }
        return "circle"
    }

    private func formatSymbol(_ format: MediaFormatToken) -> String {
        descriptor.filter.formats.contains(format) ? "checkmark" : "circle"
    }
}

struct CatalogSortMenu: View {
    let sort: MediaSortOrder
    let setField: (MediaSortField) -> Void
    let setDirection: (MediaSortDirection) -> Void

    var body: some View {
        Menu {
            Section("Sort By") {
                ForEach(MediaSortField.allCases, id: \.self) { field in
                    Button {
                        setField(field)
                    } label: {
                        Label(field.label, systemImage: field == sort.field ? "checkmark" : "circle")
                    }
                }
            }
            Section("Direction") {
                ForEach(MediaSortDirection.allCases, id: \.self) { direction in
                    Button {
                        setDirection(direction)
                    } label: {
                        Label(direction.label, systemImage: direction == sort.direction ? "checkmark" : "circle")
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .help("Sort")
    }
}

/// Grid zoom slider (spec 0048). Right = zoom in (Photos convention): the slider's own
/// `0...6` value is only a display detail, converted at the boundary so this view's
/// public contract is the same `columnCount` every other zoom surface uses.
struct CatalogZoomSlider: View {
    let columnCount: Int
    let requestColumnCount: (Int) -> Void

    private var sliderValue: Binding<Double> {
        Binding(
            get: { Double(GridColumnCount.sliderValue(forColumnCount: columnCount)) },
            set: { requestColumnCount(GridColumnCount.columnCount(forSliderValue: Int($0.rounded()))) }
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Slider(
                value: sliderValue,
                in: 0 ... Double(GridColumnCount.maximum - GridColumnCount.minimum),
                step: 1
            )
            .frame(width: 100)
            Image(systemName: "photo")
                .imageScale(.large)
                .foregroundStyle(.secondary)
        }
        .help("Grid Zoom")
    }
}
