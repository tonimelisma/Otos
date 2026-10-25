import SwiftUI

// Toolbar control guide
//
// These menus render the ViewModel's session descriptor and Projection's scoped
// filter options. They do not query the catalog or derive membership; every
// command calls a ViewModel intent so toolbar and menu-bar actions share the same
// implementation path.

struct CatalogFilterControl: View {
    let descriptor: CatalogQueryDescriptor
    let options: CatalogFilterOptions
    @Binding var isPresented: Bool
    let setKind: (MediaKind, Bool) -> Void
    let setFileType: (MediaFileTypeOption, MediaKind, Bool) -> Void
    let setChoice: (MediaChoice, Bool) -> Void
    let clearFilters: () -> Void

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(descriptor.filter.isActive ? Color.accentColor : Color.primary)
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            CatalogFilterPopoverContent(
                descriptor: descriptor,
                options: options,
                setKind: setKind,
                setFileType: setFileType,
                setChoice: setChoice,
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
    let setFileType: (MediaFileTypeOption, MediaKind, Bool) -> Void
    let setChoice: (MediaChoice, Bool) -> Void
    let clearFilters: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Filter")
                .font(.headline)
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
            ForEach(availableKinds, id: \.self) { kind in
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(kind.label, sources: kindToggleSources(kind), isOn: \.isOn)
                        .fontWeight(.semibold)
                        .accessibilityLabel(kind.label)
                    ForEach(options.fileTypes(for: kind), id: \.self) { fileType in
                        Toggle(fileType.label, isOn: fileTypeBinding(fileType, kind: kind))
                            .padding(.leading, 20)
                            .accessibilityLabel(fileType.label)
                    }
                }
                .toggleStyle(.checkbox)
            }
            Divider()
            Button("Clear Filters", action: clearFilters)
                .disabled(!descriptor.filter.isActive)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var availableKinds: [MediaKind] {
        options.availableKinds
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

/// Photos-style discrete thumbnail sizing. Uses AppKit `NSSegmentedControl` with
/// momentary tracking so the −/+ pair renders as one fused control (SwiftUI
/// `ControlGroup` only applies logical spacing on modern macOS toolbars).
struct CatalogZoomControl: View {
    let columnCount: Int
    let makeThumbnailsSmaller: () -> Void
    let makeThumbnailsLarger: () -> Void

    var body: some View {
        ZoomSegmentedControl(
            columnCount: columnCount,
            makeThumbnailsSmaller: makeThumbnailsSmaller,
            makeThumbnailsLarger: makeThumbnailsLarger
        )
        .frame(width: 64, height: 24)
        .accessibilityLabel("Thumbnail Size")
        .help("Thumbnail Size")
    }
}

/// Native fused momentary −/+ segment for the toolbar.
struct ZoomSegmentedControl: NSViewRepresentable {
    let columnCount: Int
    let makeThumbnailsSmaller: () -> Void
    let makeThumbnailsLarger: () -> Void

    final class Coordinator: NSObject {
        var makeThumbnailsSmaller: () -> Void
        var makeThumbnailsLarger: () -> Void

        init(
            makeThumbnailsSmaller: @escaping () -> Void,
            makeThumbnailsLarger: @escaping () -> Void
        ) {
            self.makeThumbnailsSmaller = makeThumbnailsSmaller
            self.makeThumbnailsLarger = makeThumbnailsLarger
        }

        @objc func segmentClicked(_ sender: NSSegmentedControl) {
            switch sender.selectedSegment {
            case 0:
                makeThumbnailsSmaller()
            case 1:
                makeThumbnailsLarger()
            default:
                break
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            makeThumbnailsSmaller: makeThumbnailsSmaller,
            makeThumbnailsLarger: makeThumbnailsLarger
        )
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let minus = NSImage(systemSymbolName: "minus", accessibilityDescription: "Smaller Thumbnails")
            ?? NSImage()
        let plus = NSImage(systemSymbolName: "plus", accessibilityDescription: "Larger Thumbnails")
            ?? NSImage()
        let control = NSSegmentedControl(
            images: [minus, plus],
            trackingMode: .momentary,
            target: context.coordinator,
            action: #selector(Coordinator.segmentClicked(_:))
        )
        control.segmentStyle = .automatic
        control.setToolTip("Smaller Thumbnails", forSegment: 0)
        control.setToolTip("Larger Thumbnails", forSegment: 1)
        applyEnablement(control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.makeThumbnailsSmaller = makeThumbnailsSmaller
        context.coordinator.makeThumbnailsLarger = makeThumbnailsLarger
        applyEnablement(control)
    }

    private func applyEnablement(_ control: NSSegmentedControl) {
        control.setEnabled(columnCount < GridColumnCount.maximum, forSegment: 0)
        control.setEnabled(columnCount > GridColumnCount.minimum, forSegment: 1)
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

struct CatalogInfoToolbarButton: View {
    let isEnabled: Bool
    let isShowing: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Label("Info", systemImage: isShowing ? "info.circle.fill" : "info.circle")
        }
        .help(isShowing ? "Hide Info" : "Show Info")
        .disabled(!isEnabled)
    }
}

/// Shows and hides the trailing edit panel; View ▸ Show Edit (E) is its menu-bar
/// equivalent.
struct CatalogEditToolbarButton: View {
    let isShowing: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Label("Edit", systemImage: "slider.horizontal.3")
        }
        .help(isShowing ? "Hide Edit" : "Show Edit")
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

/// Toolbar curation control (APP-024): Like / Not Rated / Dislike for the current
/// targets — the same intent P, U, X, the Photo menu, the hover group and the context
/// menu call. Photos' toolbar heart, in Otos's vocabulary. `currentChoice` is the one
/// choice every target holds, or nil when they differ or nothing is targeted; the
/// matching segment is filled so the current item's state is visible at a glance.
struct CatalogCurationToolbarControl: View {
    let currentChoice: MediaChoice?
    let isEnabled: Bool
    let choose: (MediaChoice) -> Void

    var body: some View {
        ControlGroup {
            ForEach(MediaChoice.allCases, id: \.self) { choice in
                Button {
                    choose(choice)
                } label: {
                    Label(choice.actionLabel, systemImage: choice.systemImage)
                        .symbolVariant(currentChoice == choice ? .fill : .none)
                }
                .help(choice.actionLabel)
            }
        }
        .disabled(!isEnabled)
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
