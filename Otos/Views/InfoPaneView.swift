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
/// is a button that searches for its name, through the toolbar field's own intent (`search`).
struct InfoPaneView: View {
    let info: PhotoInfo?
    let people: InfoPanePeople?
    let search: (String) -> Void

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
                    if section.id == .people {
                        InfoPanePeopleSection(people: people, facesRead: shown.facesRead)
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

/// The In This Photo section: Vision's confident scene labels as buttons that search for
/// them, then the text it is certain of, selectable. A reading still owed reads `Not Checked
/// Yet`; one that found nothing, `Nothing Recognized`; with no single item, `—`.
private struct InfoPaneRecognizedSection: View {
    let recognized: PhotoInfo.Recognized?
    let search: (String) -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        if let recognized {
            if let labels = recognized.labels, !labels.isEmpty || !(recognized.text ?? []).isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if !labels.isEmpty {
                        ChipFlowLayout(spacing: 4) {
                            ForEach(labels, id: \.self) { name in
                                let title = PhotoInfo.Recognized.chipTitle(name, locale: locale)
                                Button(title) { search(name) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .lineLimit(1)
                                    .help("Search for “\(name)”")
                            }
                        }
                    }
                    if let text = recognized.text, !text.isEmpty {
                        Text("Text")
                            .foregroundStyle(.secondary)
                        Text(text.joined(separator: "\n"))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Text(recognized.labels == nil ? "Not Checked Yet" : "Nothing Recognized")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(PhotoInfo.notApplicable)
                .foregroundStyle(.secondary)
        }
    }
}

/// Lays chips out in rows, left to right, wrapping when the next one would not fit.
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
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
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
            let size = subviews[index].sizeThatFits(.unspecified)
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

/// What the Info pane's People section shows and does (ADR 0047): the faces of the targeted
/// photos, and their groups as the photo menus offer them, worded once by the view model
/// (`FaceMenu`), so the two surfaces say the same thing.
struct InfoPanePeople {
    let faces: SelectionFaces
    /// The photo menus' groups; nil while the targets hold no face People shows.
    let menu: FaceMenu?
    let images: FaceTileImages?
    let derivedImageDirectory: URL?
    /// Every face act, as the photo menus perform it.
    let perform: (MediaItemCommand) -> Void
    /// The pointer over a row outlines its faces on their photos; off every row, none.
    let hover: ([FaceID]) -> Void
}

/// The People section: one row per group of the photo menus — for one photo, each face as
/// its crop with its person's name, `Add Name…` and every photo of them for a person without
/// one, or `Unidentified`; for several, each person with how many of the photos hold them,
/// and the unidentified faces where the menus offer them. An unidentified face offers the
/// three people it most likely is as buttons, and every row's menu holds its group's acts
/// in the same words and sections (DES-113, `docs/design/people.md`).
private struct InfoPanePeopleSection: View {
    let people: InfoPanePeople?
    let facesRead: Bool?

    /// The likely people an unidentified face shows as buttons.
    private static let suggestions = 3

    var body: some View {
        if let people, !people.faces.photos.isEmpty {
            if people.faces.faces.isEmpty {
                Text(people.faces.photos.count == 1 && facesRead == false ? "Not Checked Yet" : "No Faces")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array((people.menu?.groups ?? []).enumerated()), id: \.offset) { _, group in
                        row(people, group)
                    }
                }
            }
        } else {
            Text(PhotoInfo.notApplicable)
                .foregroundStyle(.secondary)
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
                    if let count = group.photoCount {
                        Text(PeopleText.count(count, "photo"))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if group.kind == .unidentified {
                    // The people it most likely is, one click each.
                    let likely = group.list.filter {
                        if case .giveTo = $0.command {
                            true
                        } else {
                            false
                        }
                    }
                    if !likely.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(Array(likely.prefix(Self.suggestions).enumerated()), id: \.offset) { _, action in
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
