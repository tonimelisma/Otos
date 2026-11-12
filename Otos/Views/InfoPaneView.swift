import MapKit
import SwiftUI

/// The inspector's Info pane (APP-041, DES-088): read-only facts about the current target,
/// laid out as the Edit pane is (DES-092) so the column reads the same in both panes — the
/// file name, a quiet line saying when it was taken, then folding sections under a hairline,
/// each a heading of its symbol and title over rows indented beneath it.
///
/// Passive: it renders the `PhotoInfo` it is given. Its rows keep their place for every item
/// of a kind (DES-053); with no single item they read `—`. Which sections are folded is the
/// person's, remembered across launches like the Edit pane's.
struct InfoPaneView: View {
    let info: PhotoInfo?
    let people: InfoPanePeople?

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

/// What the Info pane's People section shows and does (ADR 0047): the faces of the targeted
/// photos, the people each could be, and the face acts.
struct InfoPanePeople {
    let faces: SelectionFaces
    /// The name the user gave a person; nil for a person without one.
    let name: (PersonID) -> String?
    /// The people some faces may be given, most likely first; the person in the second
    /// argument is left out.
    let choices: ([PhotoFace], PersonID?) -> [PersonSummary]
    let images: FaceTileImages?
    let derivedImageDirectory: URL?
    let actions: FaceActions
    /// The pointer over a row outlines its faces on their photos; off every row, none.
    let hover: ([FaceID]) -> Void
}

/// The People section: for one photo, each face as its crop with its person's name, `Add
/// Name…` for a person without one, or `Unidentified`; for several, each person with how
/// many of the photos hold them, and the unidentified faces. An unidentified face offers the
/// three people it most likely is as buttons, and every row's menu holds the photo menus'
/// acts in their words (`FaceActTitle`, `docs/design/people.md`).
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
            } else if people.faces.photos.count == 1 {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(people.faces.faces) { face in
                        row(people, faces: [face], tile: face.tile, person: face.person, name: face.person.flatMap(people.name))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(people.faces.people, id: \.self) { person in
                        let faces = people.faces.faces(of: person)
                        row(people, faces: faces, tile: faces.first?.tile, person: person, name: people.name(person),
                            detail: PeopleText.count(Set(faces.map(\.id.asset)).count, "photo"))
                    }
                    let unidentified = people.faces.unidentified
                    if !unidentified.isEmpty {
                        row(people, faces: unidentified, tile: nil, person: nil, name: nil,
                            detail: PeopleText.count(unidentified.count, "face"))
                    }
                }
            }
        } else {
            Text(PhotoInfo.notApplicable)
                .foregroundStyle(.secondary)
        }
    }

    private func row(
        _ people: InfoPanePeople,
        faces: [PhotoFace],
        tile: FaceTile?,
        person: PersonID?,
        name: String?,
        detail: String? = nil
    ) -> some View {
        let ids = faces.map(\.id)
        var seen: Set<MediaAssetID> = []
        let onePerPhoto = faces.filter { seen.insert($0.id.asset).inserted }
        let choices = people.choices(person == nil ? onePerPhoto : faces, person)
        return HStack(alignment: .top, spacing: 8) {
            if let tile {
                FaceTileView(tile: tile, edge: 40, isSelected: false, images: people.images, derivedImageDirectory: people.derivedImageDirectory)
            } else {
                Image(systemName: "person.crop.square")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 40, height: 40)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let person, name == nil {
                        // A person without a name: the name's place offers naming them, so
                        // it never reads as someone called Unnamed.
                        Button(FaceActTitle.addName) { people.actions.addName(person) }
                            .buttonStyle(.link)
                            .lineLimit(1)
                    } else {
                        Text(name ?? (faces.count == 1 ? "Unidentified" : "Unidentified Faces"))
                            .foregroundStyle(name == nil ? .secondary : .primary)
                            .lineLimit(1)
                    }
                    if let detail {
                        Text(detail)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if person == nil, !choices.isEmpty {
                    // The people it most likely is, one click each.
                    HStack(spacing: 4) {
                        ForEach(choices.prefix(Self.suggestions)) { choice in
                            Button(choice.displayName) {
                                if faces.count == 1 {
                                    people.actions.name(ids, choice.id)
                                } else {
                                    people.actions.nameUnidentified(choice.id)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .lineLimit(1)
                            .help("This is \(choice.displayName)")
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Menu {
                if let person, name == nil {
                    Button(FaceActTitle.addName) { people.actions.addName(person) }
                    Divider()
                }
                Menu(FaceActTitle.thisIs) {
                    ForEach(choices) { choice in
                        Button(choice.displayName) {
                            if person == nil, faces.count > 1 {
                                people.actions.nameUnidentified(choice.id)
                            } else {
                                people.actions.name(ids, choice.id)
                            }
                        }
                    }
                    if !choices.isEmpty {
                        Divider()
                    }
                    Button(FaceActTitle.newPerson) { people.actions.newPerson(onePerPhoto.map(\.id)) }
                }
                if person != nil {
                    Button(FaceActTitle.notPerson(name)) { people.actions.removeNames(ids) }
                }
                Button(FaceActTitle.notAFace) { people.actions.notFaces(ids) }
                if let person, faces.count == 1, let face = faces.first {
                    Divider()
                    Button(FaceActTitle.makeKeyPhoto) { people.actions.makeKeyPhoto(face.id, person) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Face Actions")
            .accessibilityLabel("Actions for \(name ?? (person == nil ? "unidentified face" : "unnamed person"))")
        }
        .contentShape(Rectangle())
        .onHover { inside in
            people.hover(inside ? ids : [])
        }
        .accessibilityElement(children: .contain)
    }
}
