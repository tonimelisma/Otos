import MapKit
import SwiftUI

/// The inspector's Info pane (APP-041, DES-088): read-only facts about the current target,
/// laid out as the Edit pane is (DES-092) so the column reads the same in both panes — the
/// file name, a quiet line saying when it was taken, then folding sections under a hairline,
/// each a heading of its symbol and title over rows indented beneath it.
///
/// Passive: it renders the `PhotoInfo` it is given. Its rows keep their place for every item
/// of a kind (DES-053); with no single item they read `—`. Which sections are folded is the
/// person's, remembered across launches like the Edit pane's. A scene label in In This Photo
/// is a button that searches for its label, and the toolbar field shows its name (`search`).
struct InfoPaneView: View, Equatable {
    let info: PhotoInfo?
    let people: InfoPanePeople?
    let search: (String) -> Void

    /// What the pane shows. The window rebuilds its inspector for every state it applies,
    /// and closures never compare equal, so without this every publication — a one-tile hide,
    /// a background republish — re-resolved and re-laid out every text the pane holds, and the
    /// window measured it again for its minimum size: on an optimised build about half of each
    /// 45–60 ms main-thread update while acts ran in a row
    /// (`docs/research/2026-11-16-window-state-turns.md`). An equal pane is not rendered again
    /// (`.equatable()` where `ContentView` hosts it); its intents are not part of what it shows.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.info == rhs.info && InfoPanePeople.showSame(lhs.people, rhs.people)
    }

    /// Section IDs the person folded, comma-separated.
    @AppStorage("infoPane.foldedSections") private var foldedSections = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: PhotoInfo {
        info ?? .none(itemCount: 0)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(shown.title)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityAddTraits(.isHeader)
                    Text(shown.captured)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Captured \(shown.captured)")
                }
                ForEach(shown.sections) { section in
                    // The Edit pane's hairline above each section (DES-092).
                    Divider()
                    sectionView(section)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func isOpen(_ section: PhotoInfo.SectionID) -> Bool {
        !foldedSections.split(separator: ",").contains(Substring(section.rawValue))
    }

    private func toggleFold(_ section: PhotoInfo.SectionID) {
        var folded = Set(foldedSections.split(separator: ",").map(String.init))
        if folded.contains(section.rawValue) {
            folded.remove(section.rawValue)
        } else {
            folded.insert(section.rawValue)
        }
        // DES-070 for content appearing; DES-075 under Reduce Motion. The content fades in
        // place either way, so nothing translates.
        withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.25)) {
            foldedSections = folded.sorted().joined(separator: ",")
        }
    }

    private func sectionView(_ section: PhotoInfo.Section) -> some View {
        let open = isOpen(section.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                toggleFold(section.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: EditPanelView.disclosureWidth)
                    Image(systemName: section.id.symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(section.id.title)
                        .font(.title3)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(section.id.title)
            .accessibilityValue(open ? "expanded" : "collapsed")
            .accessibilityAddTraits(.isHeader)
            .help(open ? "Hide \(section.id.title)" : "Show \(section.id.title)")
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    if section.id == .location, let coordinate = shown.coordinate {
                        map(coordinate)
                    }
                    if section.id == .description {
                        InfoPaneDescriptionSection(description: shown.photoDescription, hasItem: shown.id != nil)
                    } else if section.id == .people {
                        InfoPanePeopleSection(people: people)
                    } else if section.id == .recognized {
                        InfoPaneRecognizedSection(recognized: shown.recognized, search: search)
                    } else {
                        rows(section.rows)
                    }
                }
                // Indented under the heading, as the Edit pane's controls are, so the
                // headings form one edge the eye runs down.
                .padding(.leading, EditPanelView.contentIndent)
                .transition(.opacity)
            }
        }
    }

    /// Label and value, the label secondary (DES-088). Labels share one leading edge, the
    /// edge the Edit pane's control names use, and a long value wraps beside its label.
    private func rows(_ rows: [PhotoInfo.Row]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                    Text(row.value)
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Where it was taken: a still map with one pin, read-only like the rest of the pane.
    private func map(_ coordinate: PlaceCoordinate) -> some View {
        let center = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return Map(
            initialPosition: .camera(MapCamera(centerCoordinate: center, distance: 4000)),
            interactionModes: []
        ) {
            Marker("", coordinate: center)
        }
        // A new item recenters the map rather than keeping the last one's camera.
        .id(coordinate)
        .frame(height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Map of \(shown.placeName ?? "where it was taken")")
    }
}

/// The Description section (ADR 0053): what Apple's on-device model wrote about the still,
/// selectable, over the line that says who wrote it (the HIG asks that generated content be
/// identified). `No Description` when the model declined; while one is owed, `Not Written
/// Yet`, or why none can be written on this Mac; with no single item, `—`.
private struct InfoPaneDescriptionSection: View {
    let description: PhotoInfo.Description?
    let hasItem: Bool

    var body: some View {
        switch description {
        case let .written(text):
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(InfoPaneDescriptionSection.attribution)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .declined:
            secondary("No Description")
        case let .owed(availability):
            secondary(Self.owedText(availability))
        case nil:
            secondary(hasItem ? PhotoInfo.unknown : PhotoInfo.notApplicable)
        }
    }

    static let attribution = "Written by Apple Intelligence"

    static func owedText(_ availability: PhotoDescriptionAvailability) -> String {
        switch availability {
        case .available: "Not Written Yet"
        case .appleIntelligenceOff: "Turn on Apple Intelligence in System Settings to describe photos."
        case .notEligible: "This Mac can’t describe photos."
        case .notReady: "Not Written Yet — Apple Intelligence isn’t ready."
        }
    }

    private func secondary(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The In This Photo section: Vision's confident scene labels as buttons that search for
/// them, then the text it is certain of, selectable. `Not Checked Yet` while the thumbnail's
/// reading is owed; `Nothing Recognized` only when both readings are made and found nothing (a
/// movie has no text reading); `Text` reads `Not Checked Yet` while the preview's reading is
/// owed; with no single item, `—`.
private struct InfoPaneRecognizedSection: View {
    let recognized: PhotoInfo.Recognized?
    /// Searches for a label, by its Vision identifier.
    let search: (String) -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        if let recognized {
            if recognized.foundNothing {
                Text("Nothing Recognized")
                    .foregroundStyle(.secondary)
            } else if recognized.labels == nil, !Self.hasLines(recognized.text) {
                Text("Not Checked Yet")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let labels = recognized.labels, !labels.isEmpty {
                        ChipFlowLayout(spacing: 4) {
                            ForEach(labels, id: \.identifier) { label in
                                Button(PhotoInfo.Recognized.chipTitle(label.name, locale: locale)) { search(label.identifier) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .lineLimit(1)
                                    .help("Search for “\(label.name)”")
                            }
                        }
                    }
                    switch recognized.text {
                    case let .read(lines) where !lines.isEmpty:
                        Text("Text")
                            .foregroundStyle(.secondary)
                        Text(lines.joined(separator: "\n"))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .owed:
                        Text("Text")
                            .foregroundStyle(.secondary)
                        Text("Not Checked Yet")
                            .foregroundStyle(.secondary)
                    case .read, .none:
                        EmptyView()
                    }
                }
            }
        } else {
            Text(PhotoInfo.notApplicable)
                .foregroundStyle(.secondary)
        }
    }

    private static func hasLines(_ text: PhotoInfo.Recognized.Text) -> Bool {
        if case let .read(lines) = text {
            return !lines.isEmpty
        }
        return false
    }
}

/// Lays chips out in rows, left to right, wrapping when the next one would not fit. A chip
/// wider than the pane is offered the pane's width, so its one line truncates rather than
/// running past the edge.
private struct ChipFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = Self.size(of: subviews[index], within: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    /// A chip's own size, but no wider than `width`.
    private static func size(of subview: LayoutSubview, within width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard ideal.width > width else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = Self.size(of: subviews[index], within: width)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}

/// What the Info pane's People section shows and does (ADR 0047): the targets' face groups
/// as the photo menus offer them, worded once by the view model (`FaceMenu`), so the two
/// surfaces say the same thing.
struct InfoPanePeople {
    /// The photo menus' groups; nil while the targets hold no face People shows.
    let menu: FaceMenu?
    /// What stands in the groups' place when there are none: `No Faces`, `Not Checked Yet` or
    /// `—`, as the view model knows it (`PhotoFacesRead.line`).
    let line: String
    let images: FaceTileImages?
    let derivedImageDirectory: URL?
    /// Every face act, as the photo menus perform it.
    let perform: (MediaItemCommand) -> Void
    /// The pointer over a row outlines its faces on their photos; off every row, none.
    let hover: ([FaceID]) -> Void

    /// Whether the two show the same groups and line from the same images; the intents are
    /// not compared.
    static func showSame(_ lhs: Self?, _ rhs: Self?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs?, rhs?):
            lhs.menu == rhs.menu && lhs.line == rhs.line && lhs.images === rhs.images
                && lhs.derivedImageDirectory == rhs.derivedImageDirectory
        default:
            false
        }
    }
}

/// The People section: one row per group of the photo menus — for one photo, each face as
/// its crop with its person's name, `Add Name…` and every photo of them for a person without
/// one, or `Unidentified`; for several, each person with how many of the photos hold them,
/// and the unidentified faces where the menus offer them. An unidentified face offers the
/// three people the ranking says it most likely is as buttons, in a row whose place is kept
/// while the ranking is owed, and every row's menu holds its group's acts in the same words
/// and sections (DES-113, `docs/design/people.md`). Leaving the section, by folding it or
/// hiding the pane, lets go of the outline a row held.
private struct InfoPanePeopleSection: View {
    let people: InfoPanePeople?

    var body: some View {
        Group {
            if let people, let groups = people.menu?.groups, !groups.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(groups) { group in
                        row(people, group)
                    }
                }
            } else {
                Text(people?.line ?? PhotoInfo.notApplicable)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear {
            people?.hover([])
        }
    }

    private func row(_ people: InfoPanePeople, _ group: FaceMenu.Group) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let tile = group.tile, group.faces.count == 1 || group.person != nil {
                FaceTileView(tile: tile, edge: 40, isSelected: false, images: people.images, derivedImageDirectory: people.derivedImageDirectory)
            } else {
                Image(systemName: "person.crop.square")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 40, height: 40)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    switch group.kind {
                    case let .named(name):
                        Text(name)
                            .lineLimit(1)
                    case .unnamed:
                        // A person without a name: the name's place offers naming them, so
                        // it never reads as someone called Unnamed.
                        if let person = group.person {
                            Button(FaceActTitle.addName) { people.perform(.addName(person)) }
                                .buttonStyle(.link)
                                .lineLimit(1)
                        }
                    case .unidentified:
                        Text(group.faces.count == 1 ? "Unidentified" : "Unidentified Faces")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let media = group.media {
                        Text(media.text)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if group.kind == .unidentified {
                    // The people it most likely is, one click each. The row keeps a button's
                    // height while the ranking is owed or names no one (DES-053), so nothing
                    // moves under the pointer when it lands.
                    ZStack(alignment: .leading) {
                        Button(" ") {}
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .hidden()
                            .accessibilityHidden(true)
                        HStack(spacing: 4) {
                            ForEach(group.suggestions ?? [], id: \.title) { action in
                                Button(action.title) { people.perform(action.command) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .lineLimit(1)
                                    .help("\(FaceActTitle.assignTo) \(action.title)")
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Menu {
                Section(group.listTitle) {
                    actions(group.list, people)
                }
                Divider()
                actions(group.corrections, people)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Face Actions")
            .accessibilityLabel("Actions for \(accessibilityName(group))")
        }
        .contentShape(Rectangle())
        .onHover { inside in
            people.hover(inside ? group.faces : [])
        }
        .accessibilityElement(children: .contain)
    }

    private func actions(_ actions: [FaceMenu.Action], _ people: InfoPanePeople) -> some View {
        ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
            Button(action.title) { people.perform(action.command) }
        }
    }

    private func accessibilityName(_ group: FaceMenu.Group) -> String {
        switch group.kind {
        case let .named(name): name
        case .unnamed: "unnamed person"
        case .unidentified: group.faces.count == 1 ? "unidentified face" : "unidentified faces"
        }
    }
}
