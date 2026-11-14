import AppKit
import SwiftUI

// Toolbar control guide
//
// These menus render the ViewModel's session descriptor and Projection's scoped
// filter options. They do not query the catalog or derive membership; every
// command calls a ViewModel intent so toolbar and menu-bar actions share the same
// implementation path.

/// The People filter's rows and intents (ADR 0047): the visible people with a name,
/// favourites first, and `Unidentified Faces`; a photo needs every row checked.
struct PeopleFilterControls {
    let people: [PersonSummary]
    let setPerson: (PersonID, Bool) -> Void
    let setUnidentified: (Bool) -> Void
}

/// The head of a long filter list (`docs/design/people.md`, `docs/design/places.md`): the
/// first five rows in the list's own order, plus any checked row past them, so the filter
/// never holds a row the user cannot see; the whole list once expanded.
nonisolated enum FilterListHead {
    static let length = 5
    /// The whole list gains a search field past this many rows.
    static let searchAfter = 8

    /// The rows shown, and whether the list is longer than its head (so it offers Show All /
    /// Show Less).
    static func rows<Row>(_ rows: [Row], isChecked: (Row) -> Bool, isExpanded: Bool) -> (shown: [Row], isLong: Bool) {
        let shown = isExpanded ? rows : rows.enumerated().filter { $0.offset < length || isChecked($0.element) }.map(\.element)
        return (shown, rows.count > length)
    }
}

/// The Places filter's intent (ADR 0040): a country or one town in it, checked or not.
struct PlaceFilterControls {
    let setPlace: (PlaceFilterKey, Bool) -> Void
}

struct CatalogFilterControl: View {
    let descriptor: CatalogQueryDescriptor
    let options: CatalogFilterOptions
    @Binding var isPresented: Bool
    let setKind: (MediaKind, Bool) -> Void
    let setFileType: (MediaFormatToken, MediaKind, Bool) -> Void
    let setChoice: (MediaChoice, Bool) -> Void
    let people: PeopleFilterControls
    let places: PlaceFilterControls
    let clearFilters: () -> Void

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            // Active, the glyph changes shape as well as color (DES-029).
            Image(systemName: descriptor.filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                .foregroundStyle(descriptor.filter.isActive ? Color.accentColor : Color.primary)
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            CatalogFilterPopoverContent(
                descriptor: descriptor,
                options: options,
                setKind: setKind,
                setFileType: setFileType,
                setChoice: setChoice,
                people: people,
                places: places,
                clearFilters: clearFilters
            )
            .frame(width: 260)
            .padding(16)
        }
        .help(descriptor.filter.isActive ? "Filter (Active)" : "Filter")
    }
}

struct CatalogFilterPopoverContent: View {
    let descriptor: CatalogQueryDescriptor
    let options: CatalogFilterOptions
    let setKind: (MediaKind, Bool) -> Void
    let setFileType: (MediaFormatToken, MediaKind, Bool) -> Void
    let setChoice: (MediaChoice, Bool) -> Void
    let people: PeopleFilterControls
    let places: PlaceFilterControls
    let clearFilters: () -> Void

    /// People and countries show their head until Show All; the whole list gains a search
    /// field once it is longer than fits at a glance.
    @State private var showsAllPeople = false
    @State private var peopleQuery = ""
    @State private var showsAllCountries = false
    @State private var placesQuery = ""
    /// The countries whose every town shows.
    @State private var countriesShowingAllTowns: Set<String> = []

    /// The popover is as tall as its rows, never taller than the screen can show under the
    /// toolbar: the title and Clear Filters stay put and the sections between them scroll as
    /// one, so no row is ever out of reach (DES-115).
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Filter")
                .font(.headline)
            ScrollView {
                sections
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Self.sectionsMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            Button("Clear Filters", action: clearFilters)
                .disabled(!descriptor.filter.isActive)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The screen's visible height less what stands above and around the sections: the
    /// toolbar, the popover's arrow and margins, the title and Clear Filters.
    private static var sectionsMaxHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 800
        return max(240, visible - 220)
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Curation")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(MediaChoice.allCases, id: \.self) { choice in
                Toggle(isOn: Binding(
                    get: { descriptor.filter.choices.contains(choice) },
                    set: { setChoice(choice, $0) }
                )) {
                    Label(choice.label, systemImage: choice.systemImage)
                }
                .toggleStyle(.checkbox)
            }
            Divider()
            Text("Media")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            // Every kind, always: the popover's rows never depend on what the shown scope
            // holds, so an empty scope still shows (and can clear) the filter it is under.
            ForEach(MediaKind.displayOrder, id: \.self) { kind in
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(kind.label, sources: kindToggleSources(kind), isOn: \.isOn)
                        .fontWeight(.semibold)
                        .accessibilityLabel(kind.label)
                    ForEach(options.formats(for: kind, holding: descriptor.filter), id: \.self) { fileType in
                        Toggle(fileType.rawValue, isOn: fileTypeBinding(fileType, kind: kind))
                            .padding(.leading, 20)
                            .accessibilityLabel(fileType.rawValue)
                    }
                }
                .toggleStyle(.checkbox)
            }
            Divider()
            peopleSection
            Divider()
            placesSection
        }
    }

    private var peopleSection: some View {
        let filter = descriptor.filter
        let query = peopleQuery.trimmingCharacters(in: .whitespaces)
        let head = FilterListHead.rows(
            people.people, isChecked: { filter.people.contains($0.id) }, isExpanded: showsAllPeople
        )
        let shown = head.shown.filter { person in
            query.isEmpty || filter.people.contains(person.id) || person.displayName.localizedStandardContains(query)
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text("People")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if showsAllPeople, people.people.count > FilterListHead.searchAfter {
                TextField("Search People", text: $peopleQuery)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(shown) { person in
                    Toggle(person.displayName, isOn: Binding(
                        get: { filter.people.contains(person.id) },
                        set: { people.setPerson(person.id, $0) }
                    ))
                }
                Toggle("Unidentified Faces", isOn: Binding(
                    get: { filter.unassignedFaces },
                    set: { people.setUnidentified($0) }
                ))
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, alignment: .leading)
            if head.isLong {
                showAllButton(
                    showsAll: showsAllPeople, total: people.people.count, noun: "People",
                    toggle: { showsAllPeople.toggle()
                        peopleQuery = ""
                    }
                )
            }
        }
    }

    /// `Show All 23 People` under a list cut to its head, or `Show Less` under the whole.
    private func showAllButton(showsAll: Bool, total: Int, noun: String, toggle: @escaping () -> Void) -> some View {
        Button(showsAll ? "Show Less" : "Show All \(total.formatted()) \(noun)", action: toggle)
            .buttonStyle(.link)
    }

    /// Every country Maps named for the located items, most items first, each opening onto its
    /// towns; a country with some towns checked is mixed. Countries, and each country's towns,
    /// show their head until Show All; a checked place always shows.
    private var placesSection: some View {
        let filter = descriptor.filter
        let query = placesQuery.trimmingCharacters(in: .whitespaces)
        let countries = options.countries(holding: filter)
        let head = FilterListHead.rows(
            countries, isChecked: { country in filter.heldPlaces.contains { $0.country == country.name } },
            isExpanded: showsAllCountries
        )
        let shown = head.shown.compactMap { country -> PlaceFilterCountry? in
            if query.isEmpty || filter.heldPlaces.contains(where: { $0.country == country.name })
                || country.name.localizedStandardContains(query)
            {
                return country
            }
            let towns = country.towns.filter { $0.localizedStandardContains(query) }
            return towns.isEmpty ? nil : PlaceFilterCountry(name: country.name, towns: towns)
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Places")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if showsAllCountries, countries.count > FilterListHead.searchAfter {
                TextField("Search Places", text: $placesQuery)
                    .textFieldStyle(.roundedBorder)
            }
            if shown.isEmpty {
                Text(countries.isEmpty ? "No places named yet" : "No matching places")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(shown) { country in
                    DisclosureGroup {
                        townRows(country, searching: !query.isEmpty)
                    } label: {
                        Toggle(country.name, sources: countrySources(country), isOn: \.isOn)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, alignment: .leading)
            if head.isLong {
                showAllButton(
                    showsAll: showsAllCountries, total: countries.count, noun: "Countries",
                    toggle: { showsAllCountries.toggle()
                        placesQuery = ""
                    }
                )
            }
        }
    }

    /// One country's towns, their head until its own Show All; every match while searching.
    private func townRows(_ country: PlaceFilterCountry, searching: Bool) -> some View {
        let showsAll = searching || countriesShowingAllTowns.contains(country.name)
        let head = FilterListHead.rows(
            country.towns, isChecked: { isPlaceIncludedExplicitly($0, in: country.name) }, isExpanded: showsAll
        )
        // Leading-aligned: a disclosure group centers rows of unequal width.
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(head.shown, id: \.self) { town in
                Toggle(town, isOn: townBinding(town, in: country))
            }
            if head.isLong, !searching {
                showAllButton(
                    showsAll: showsAll, total: country.towns.count, noun: "Towns",
                    toggle: {
                        if showsAll {
                            countriesShowingAllTowns.remove(country.name)
                        } else {
                            countriesShowingAllTowns.insert(country.name)
                        }
                    }
                )
            }
        }
        .padding(.leading, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func countrySources(_ country: PlaceFilterCountry) -> [MenuToggleSource] {
        let whole = PlaceFilterKey(country: country.name, town: nil)
        guard !country.towns.isEmpty else {
            return [MenuToggleSource(isOn: Binding(
                get: { descriptor.filter.heldPlaces.contains(whole) },
                set: { places.setPlace(whole, $0) }
            ))]
        }
        return country.towns.map { town in
            MenuToggleSource(isOn: Binding(
                get: { isPlaceIncluded(town, in: country.name) },
                set: { places.setPlace(whole, $0) }
            ))
        }
    }

    private func townBinding(_ town: String, in country: PlaceFilterCountry) -> Binding<Bool> {
        Binding(
            get: { isPlaceIncluded(town, in: country.name) },
            set: { places.setPlace(PlaceFilterKey(country: country.name, town: town), $0) }
        )
    }

    /// A town checked on its own, not through its whole country: the row a head must keep.
    private func isPlaceIncludedExplicitly(_ town: String, in country: String) -> Bool {
        descriptor.filter.heldPlaces.contains(PlaceFilterKey(country: country, town: town))
    }

    private func isPlaceIncluded(_ town: String, in country: String) -> Bool {
        descriptor.filter.heldPlaces.contains(PlaceFilterKey(country: country, town: nil))
            || descriptor.filter.heldPlaces.contains(PlaceFilterKey(country: country, town: town))
    }

    /// A collection-backed Toggle gives macOS its native mixed state. Every
    /// source setter calls the one kind-level owner intent, so clicking a mixed
    /// parent still produces one effective descriptor change; repeated setter
    /// calls from SwiftUI become normalized no-ops.
    private func kindToggleSources(_ kind: MediaKind) -> [MenuToggleSource] {
        let fileTypes = options.formats(for: kind, holding: descriptor.filter)
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

    private func fileTypeBinding(_ fileType: MediaFormatToken, kind: MediaKind) -> Binding<Bool> {
        Binding(
            get: { isFileTypeIncluded(fileType, kind: kind) },
            set: { setFileType(fileType, kind, $0) }
        )
    }

    private func isFileTypeIncluded(_ fileType: MediaFormatToken, kind: MediaKind) -> Bool {
        descriptor.filter.kinds.contains(kind)
            || descriptor.filter.fileTypes.contains(FilterFileType(kind: kind, format: fileType))
    }
}

private struct MenuToggleSource {
    let isOn: Binding<Bool>
}

struct CatalogSortMenu: View {
    let sort: MediaSortOrder
    let search: CatalogSearch?
    /// The one person the filter shows, whom the likeness orders name.
    let person: String?
    let setOrder: (MediaSortOrder) -> Void
    let orderByRelevance: () -> Void

    var body: some View {
        Menu {
            CatalogSortMenuContent(sort: sort, search: search, person: person, setOrder: setOrder, orderByRelevance: orderByRelevance)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .help("Sort: \(search?.order == .relevance ? "Relevance" : sort.label(person: person))")
    }
}

/// The sort choices. While a search is shown, `Relevance` — best match first, Lightroom's
/// default for search results — sits above the scope's own orders (ADR 0048). The likeness
/// orders name the person the filter shows, and are disabled, never hidden, without one
/// (DES-053).
struct CatalogSortMenuContent: View {
    let sort: MediaSortOrder
    let search: CatalogSearch?
    let person: String?
    let setOrder: (MediaSortOrder) -> Void
    let orderByRelevance: () -> Void

    private enum Choice: Hashable {
        case relevance
        case order(MediaSortOrder)
    }

    var body: some View {
        Picker("Sort Order", selection: choiceBinding) {
            if search != nil {
                Text("Relevance").tag(Choice.relevance)
                Divider()
            }
            ForEach(MediaSortOrder.allCases, id: \.self) { order in
                Text(order.label(person: person))
                    .tag(Choice.order(order))
                    .selectionDisabled(order.field == .likeness && person == nil)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    private var choiceBinding: Binding<Choice> {
        Binding(
            get: { search?.order == .relevance ? .relevance : .order(sort) },
            set: { choice in
                switch choice {
                case .relevance:
                    orderByRelevance()
                case let .order(order):
                    setOrder(order)
                }
            }
        )
    }
}

/// The toolbar's −/+: the same View ▸ Zoom Out / Zoom In intents in every mode — grid
/// density in the grid, the image in the loupe (APP-040) — enabled exactly when the menu
/// items are.
struct CatalogZoomControl: View {
    let canZoomOut: Bool
    let canZoomIn: Bool
    let zoomOut: () -> Void
    let zoomIn: () -> Void

    var body: some View {
        ToolbarSegmentedControl(
            segments: [
                ToolbarSegment(systemImage: "minus", title: "Zoom Out", isEnabled: canZoomOut),
                ToolbarSegment(systemImage: "plus", title: "Zoom In", isEnabled: canZoomIn),
            ],
            selected: nil,
            choose: { $0 == 0 ? zoomOut() : zoomIn() }
        )
        .frame(width: 64, height: 24)
        .accessibilityLabel("Zoom")
        .help("Zoom")
    }
}

/// One segment of a toolbar segmented control: its symbol, the act it names (tooltip and
/// accessibility description), and whether it acts now.
struct ToolbarSegment: Equatable {
    let systemImage: String
    let title: String
    let isEnabled: Bool
}

/// A fused group of toolbar buttons drawn as one AppKit `NSSegmentedControl` — the one
/// idiom for every joined group in the toolbar (`hig-validation.md` F-26): SwiftUI's
/// `ControlGroup` lays a modern macOS toolbar's buttons out apart. With `selected` it
/// shows a state (the targets' curation choice, none when they differ); without, its
/// segments are momentary buttons.
struct ToolbarSegmentedControl: NSViewRepresentable {
    let segments: [ToolbarSegment]
    let selected: Int?
    let choose: (Int) -> Void

    final class Coordinator: NSObject {
        var choose: (Int) -> Void

        init(choose: @escaping (Int) -> Void) {
            self.choose = choose
        }

        @objc func segmentClicked(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            guard index >= 0 else { return }
            choose(index)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(choose: choose)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            images: segments.map { Self.image($0) },
            trackingMode: selected == nil ? .momentary : .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.segmentClicked(_:))
        )
        control.segmentStyle = .automatic
        apply(to: control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.choose = choose
        apply(to: control)
    }

    private func apply(to control: NSSegmentedControl) {
        for (index, segment) in segments.enumerated() {
            control.setImage(Self.image(segment), forSegment: index)
            control.setToolTip(segment.title, forSegment: index)
            control.setEnabled(segment.isEnabled, forSegment: index)
        }
        if control.trackingMode == .selectOne {
            // The state the model reports, never the click itself: a click whose choice
            // does not land leaves the segment showing what is true.
            control.selectedSegment = selected ?? -1
        }
    }

    private static func image(_ segment: ToolbarSegment) -> NSImage {
        NSImage(systemSymbolName: segment.systemImage, accessibilityDescription: segment.title) ?? NSImage()
    }
}

/// Segmented Grid / Loupe / Compare control. All three call the same ViewModel
/// `setViewMode` intent as the View menu (⌘1 / ⌘2 / ⌘3). `viewMode` is nil while the
/// Places map shows: the map is not one of the modes, so no segment is selected, and
/// choosing one opens the area the map shows in it.
struct ViewModePicker: View {
    let viewMode: BrowserViewMode?
    let setViewMode: (BrowserViewMode) -> Void

    var body: some View {
        Picker("View Mode", selection: modeBinding) {
            ForEach(BrowserViewMode.allCases) { mode in
                Image(systemName: mode.systemImage)
                    .tag(BrowserViewMode?.some(mode))
                    .help(mode.help)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help(viewMode?.help ?? "View Mode")
        .accessibilityLabel("View Mode")
    }

    private var modeBinding: Binding<BrowserViewMode?> {
        Binding(
            get: { viewMode },
            set: { mode in
                if let mode {
                    setViewMode(mode)
                }
            }
        )
    }
}

/// Toolbar Share and Info buttons (APP-036, APP-041). The Share button is the anchor
/// every Share path presents from — File ▸ Share… and the context menus included —
/// which is what Preview and Photos do: the popover drops from the toolbar button, not
/// from wherever the command happened to be invoked. The button's AppKit host view is
/// handed to the ViewModel through `onAnchor` so the presenter can point at it; the
/// view is passive and calls one intent.
struct CatalogShareToolbarButton: View {
    let isEnabled: Bool
    let onAnchor: (NSView?) -> Void
    let share: () -> Void

    var body: some View {
        Button(action: share) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .help("Share")
        .disabled(!isEnabled)
        .background(ToolbarAnchorReader(onAnchor: onAnchor))
    }
}

/// A toolbar button that shows and hides a surface. It is a toggle, so the toolbar draws
/// it pressed while the surface is shown — one idiom for Info and Edit, and the state
/// is never carried by the glyph alone (DES-029). Its tooltip names the act a click does.
struct CatalogSurfaceToolbarToggle: View {
    let title: String
    let systemImage: String
    let isShowing: Bool
    var isEnabled = true
    let toggle: () -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isShowing }, set: { _ in toggle() })) {
            Label(title, systemImage: systemImage)
        }
        .toggleStyle(.button)
        .help(isShowing ? "Hide \(title)" : "Show \(title)")
        .disabled(!isEnabled)
    }
}

/// Invisible AppKit view placed behind a SwiftUI toolbar button so the button's
/// on-screen frame is known to AppKit code that must present a popover from it.
struct ToolbarAnchorReader: NSViewRepresentable {
    let onAnchor: (NSView?) -> Void

    func makeNSView(context _: Context) -> ToolbarAnchorView {
        let view = ToolbarAnchorView()
        view.onAnchor = onAnchor
        return view
    }

    func updateNSView(_ view: ToolbarAnchorView, context _: Context) {
        view.onAnchor = onAnchor
        if view.window != nil {
            onAnchor(view)
        }
    }
}

final class ToolbarAnchorView: NSView {
    var onAnchor: (NSView?) -> Void = { _ in }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onAnchor(window == nil ? nil : self)
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}

/// Reports the toolbar search field emptied, which `.searchable` misses, so the field and the
/// search cannot disagree (DES-108). `.searchable` reports what the field's editor changes,
/// but the field's clear button pressed while the field is not being edited — a click after
/// the keyboard left the field, or VoiceOver's press — empties the field without calling its
/// text binding (macOS 27, measured with a bare `.searchable` too; `SearchFieldWindowTests`).
/// The field sends its action on that clear, and SwiftUI leaves the action unset. The action
/// also fires on every end of editing, carrying the field's text before SwiftUI has drawn the
/// binding's: Escape sets the binding empty, then the action still carries the typed text. So
/// only an empty field is reported — the one fact the binding can miss — and every other text
/// is the binding's to report. The relay draws nothing, takes no click, and sets the action on
/// the window's search toolbar item when the item is added.
struct ToolbarSearchFieldClearRelay: NSViewRepresentable {
    let onClear: () -> Void

    func makeNSView(context _: Context) -> RelayView {
        let view = RelayView()
        view.onClear = onClear
        return view
    }

    func updateNSView(_ view: RelayView, context _: Context) {
        view.onClear = onClear
    }

    final class RelayView: NSView {
        var onClear: () -> Void = {}
        /// The window's toolbar, whose added items are watched.
        private weak var toolbar: NSToolbar?
        /// The window's `toolbar`, which SwiftUI may set after this view joins the window.
        private var toolbarObservation: NSKeyValueObservation?

        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            toolbarObservation = window?.observe(\.toolbar, options: [.initial, .new]) { [weak self] window, _ in
                MainActor.assumeIsolated {
                    self?.watch(window.toolbar)
                }
            }
            if window == nil {
                watch(nil)
            }
        }

        private func watch(_ next: NSToolbar?) {
            guard next !== toolbar else { return }
            if let toolbar {
                NotificationCenter.default.removeObserver(self, name: NSToolbar.willAddItemNotification, object: toolbar)
            }
            toolbar = next
            guard let next else { return }
            NotificationCenter.default.addObserver(
                self, selector: #selector(toolbarWillAddItem(_:)), name: NSToolbar.willAddItemNotification, object: next
            )
            next.items.forEach(relay(_:))
        }

        @objc private func toolbarWillAddItem(_ notification: Notification) {
            guard let item = notification.userInfo?["item"] as? NSToolbarItem else { return }
            relay(item)
        }

        private func relay(_ item: NSToolbarItem) {
            guard let field = (item as? NSSearchToolbarItem)?.searchField else { return }
            field.target = self
            field.action = #selector(fieldAction(_:))
        }

        /// The text the field shows is its editor's while it is being edited.
        @objc private func fieldAction(_ field: NSSearchField) {
            guard (field.currentEditor()?.string ?? field.stringValue).isEmpty else { return }
            onClear()
        }
    }
}

/// Toolbar curation control (APP-024): Like / Not Rated / Dislike for the current
/// targets — the same intent P, U, X, the Photo menu, the hover group and the context
/// menu call. Photos' toolbar heart, in Otos's vocabulary. `currentChoice` is the one
/// choice every target holds, or nil when they differ or nothing is targeted; the
/// matching segment is drawn selected so the current item's state is visible at a glance.
struct CatalogCurationToolbarControl: View {
    let currentChoice: MediaChoice?
    let isEnabled: Bool
    let choose: (MediaChoice) -> Void

    var body: some View {
        ToolbarSegmentedControl(
            segments: MediaChoice.allCases.map { choice in
                ToolbarSegment(systemImage: choice.systemImage, title: choice.actionLabel, isEnabled: isEnabled)
            },
            selected: currentChoice.flatMap { MediaChoice.allCases.firstIndex(of: $0) },
            choose: { choose(MediaChoice.allCases[$0]) }
        )
        .frame(width: 96, height: 24)
        .accessibilityLabel("Curation")
        .accessibilityValue(currentChoice?.accessibilityValue ?? "mixed")
    }
}

/// Finder-style Action menu: the long tail of per-item acts — Open, Open With ▸,
/// Reveal in Finder, Move to Trash — with a toolbar home but not a button each. Every
/// entry calls the intent its File / Photo menu twin calls.
struct CatalogActionToolbarMenu: View {
    let openWith: OpenWithMenuModel
    let icons: [URL: NSImage]
    let canReveal: Bool
    let canTrash: Bool
    let open: () -> Void
    let openWithApplication: (OpenWithApplication) -> Void
    let openWithOther: () -> Void
    let reveal: () -> Void
    let moveToTrash: () -> Void

    var body: some View {
        Menu {
            Button(openWith.openTitle, action: open)
                .disabled(!openWith.canOpen)
            Menu("Open With") {
                ForEach(openWith.applications) { application in
                    Button {
                        openWithApplication(application)
                    } label: {
                        Label {
                            Text(application.displayName)
                        } icon: {
                            if let icon = icons[application.url] {
                                Image(nsImage: icon)
                            }
                        }
                    }
                }
                if !openWith.applications.isEmpty {
                    Divider()
                }
                Button("Other…", action: openWithOther)
            }
            .disabled(!openWith.canOpenWith)
            Button("Reveal in Finder", action: reveal)
                .disabled(!canReveal)
            Divider()
            Button("Move to Trash", role: .destructive, action: moveToTrash)
                .disabled(!canTrash)
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .help("More")
    }
}
