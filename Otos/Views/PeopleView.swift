import AppKit
import SwiftUI

// The detail pane for the `.people` scope (ADR 0047, `docs/design/people.md`): a 52 pt bar
// stating how many people there are and how many photos are not yet checked; under it,
// everyone as their feature face, name (or `Add Name…`) and photo count, favourites first,
// then most photos; then, under `Hidden`, the people the user hid, the one place they are
// seen. Passive: strings come from `PeoplePresentation`, and every control calls a
// view-model intent through `PeopleActions`.

/// The words People's surfaces show. Pure, so each one is tested without a window.
nonisolated enum PeoplePresentation {
    /// The gallery bar's L1: the people every surface offers, the visible ones.
    static func peopleLine(_ count: Int) -> String {
        count == 0 ? "No people" : PeopleText.count(count, "person").replacingOccurrences(of: "persons", with: "people")
    }

    /// The tally the bar carries as L3.
    static func uncheckedLine(_ count: Int) -> String {
        count == 0 ? "Every photo has been checked" : "\(PeopleText.count(count, "photo")) not yet checked for faces"
    }

    /// The gallery's sentence when it holds nobody; nil when it holds someone.
    static func emptySentence(_ state: CatalogPeopleState) -> String? {
        guard state.people.isEmpty else { return nil }
        if state.faceCount > 0 {
            return "People appear here once Otos finds the same face on different days."
        }
        if state.uncheckedPhotoCount > 0 {
            return "People appear here as Otos finds faces in your photos."
        }
        return "Otos found no faces in your photos."
    }

    /// A person cell as VoiceOver reads it.
    static func accessibilityLabel(_ person: PersonSummary) -> String {
        var parts = [person.displayName, PeopleText.count(person.photoCount, "photo")]
        if person.isFavorite {
            parts.append("favorite")
        }
        if person.isHidden {
            parts.append("hidden")
        }
        return parts.joined(separator: ", ")
    }
}

struct PeopleView: View {
    let people: CatalogPeopleState
    let session: PeopleSession
    /// The window's shared sentence when libraries are offline or being checked.
    let librariesState: CatalogMediaEmptyState
    let images: FaceTileImages?
    let derivedImageDirectory: URL?
    let actions: PeopleActions

    @FocusState private var listFocused: Bool
    @State private var columns = 1
    @Environment(\.colorScheme) private var colorScheme

    private static let edge: CGFloat = 128
    private static let gutter: CGFloat = 8

    var body: some View {
        VStack(spacing: 0) {
            PeopleBar(people: people)
            Rectangle()
                .fill(DesignPalette.hairline(for: colorScheme))
                .frame(height: 1)
            if let sentence = emptySentence {
                Text(sentence)
                    .font(.subheadline)
                    .foregroundStyle(DesignPalette.l3(for: colorScheme))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                gallery
            }
        }
        .background(DesignPalette.content(for: colorScheme))
    }

    private var emptySentence: String? {
        guard people.people.isEmpty else { return nil }
        switch librariesState {
        case .checkingLibraries, .noAvailableMedia:
            return librariesState.message
        default:
            return PeoplePresentation.emptySentence(people)
        }
    }

    private var gallery: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: Self.edge, maximum: Self.edge), spacing: Self.gutter, alignment: .top)],
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(people.visiblePeople) { person in
                        cell(person)
                    }
                    let hidden = people.hiddenPeople
                    if !hidden.isEmpty {
                        Section {
                            ForEach(hidden) { person in
                                cell(person)
                            }
                        } header: {
                            Text("Hidden")
                                .font(.headline)
                                .foregroundStyle(DesignPalette.label(for: colorScheme))
                                .accessibilityAddTraits(.isHeader)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, people.visiblePeople.isEmpty ? 0 : 12)
                        }
                    }
                }
                .padding(12)
                .background {
                    GeometryReader { geometry in
                        Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in
                            columns = max(1, Int((width - 24 + Self.gutter) / (Self.edge + Self.gutter)))
                        }
                    }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                let step = switch press.key {
                case .leftArrow: -1
                case .rightArrow: 1
                case .upArrow: -columns
                default: columns
                }
                guard let reached = actions.moveCursor(step, press.modifiers.contains(.shift)) else { return .ignored }
                proxy.scrollTo(reached)
                return .handled
            }
            .onKeyPress(.return) {
                guard let cursor = session.cursor else { return .ignored }
                actions.open(cursor)
                return .handled
            }
            .onKeyPress(.escape) {
                actions.select(nil, [])
                return .handled
            }
        }
    }

    private func cell(_ person: PersonSummary) -> some View {
        PersonCell(
            person: person,
            edge: Self.edge,
            isSelected: session.selectedPeople.contains(person.id),
            selectedPeople: session.selectedPeople,
            people: people,
            images: images,
            derivedImageDirectory: derivedImageDirectory,
            actions: actions,
            focusList: { listFocused = true }
        )
        .id(person.id)
    }
}

/// The question every merge asks first (owner decision, 2026-11-10), wherever it was asked:
/// a drop in the gallery, Merge Into ▸, or a name another person has.
struct PeopleMergeAlert: ViewModifier {
    let question: PeopleMergeQuestion?
    let name: (PersonID) -> String
    let answer: (Bool) -> Void

    func body(content: Content) -> some View {
        content.alert(
            "Are these the same person?",
            isPresented: Binding(
                get: { question != nil },
                set: {
                    if !$0 {
                        answer(false)
                    }
                }
            ),
            presenting: question
        ) { _ in
            Button("Merge") { answer(true) }
            Button("Cancel", role: .cancel) { answer(false) }
        } message: { question in
            Text("\(name(question.from)) will be merged into \(name(question.into)), keeping \(name(question.into))'s name and birthday.")
        }
    }
}

/// The gallery's bar (DES-109): L1 over the tally.
private struct PeopleBar: View {
    let people: CatalogPeopleState

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(PeoplePresentation.peopleLine(people.visiblePeople.count))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(DesignPalette.label(for: colorScheme))
                    .monospacedDigit()
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text(PeoplePresentation.uncheckedLine(people.uncheckedPhotoCount))
                    .font(.subheadline)
                    .foregroundStyle(DesignPalette.l3(for: colorScheme))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(DesignPalette.bar(for: colorScheme))
    }
}

/// One person: their feature face, their name (or `Add Name…`) and their photo count; a
/// heart before the name for a favourite. A hidden person is dimmed and offers only Unhide.
/// Dragging one person onto another asks whether they are the same person.
private struct PersonCell: View {
    let person: PersonSummary
    let edge: CGFloat
    let isSelected: Bool
    let selectedPeople: Set<PersonID>
    let people: CatalogPeopleState
    let images: FaceTileImages?
    let derivedImageDirectory: URL?
    let actions: PeopleActions
    let focusList: () -> Void

    @State private var isTargeted = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            face
            nameLine
            Text(PeopleText.count(person.photoCount, "photo"))
                .font(.subheadline)
                .foregroundStyle(DesignPalette.l3(for: colorScheme))
                .monospacedDigit()
        }
        .opacity(person.isHidden ? 0.5 : 1)
        .frame(width: edge, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            actions.open(person.id)
        }
        .simultaneousGesture(TapGesture().modifiers(.command).onEnded {
            focusList()
            actions.select(person.id, .command)
        })
        .simultaneousGesture(TapGesture().modifiers(.shift).onEnded {
            focusList()
            actions.select(person.id, .shift)
        })
        .onTapGesture {
            focusList()
            actions.select(person.id, [])
        }
        .draggable(PeopleDrag.payload(person.id))
        .dropDestination(for: String.self) { items, _ in
            guard !person.isHidden, let from = items.first.flatMap(PeopleDrag.person(from:)), from != person.id,
                  actions.mergeRefusal(from, person.id) == nil
            else { return false }
            actions.askMerge(from, person.id)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PeoplePresentation.accessibilityLabel(person))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { actions.open(person.id) }
    }

    @ViewBuilder private var face: some View {
        if let cover = person.cover {
            FaceTileView(
                tile: cover, edge: edge, isSelected: isSelected || isTargeted,
                images: images, derivedImageDirectory: derivedImageDirectory
            )
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(DesignPalette.hairline(for: colorScheme))
                .frame(width: edge, height: edge)
                .overlay {
                    Image(systemName: "person.crop.square")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
                .overlay {
                    if isSelected || isTargeted {
                        RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
        }
    }

    private var nameLine: some View {
        HStack(spacing: 4) {
            if person.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            if person.name == nil, !person.isHidden {
                Button("Add Name…") { actions.edit(person.id) }
                    .buttonStyle(.link)
                    .font(.body)
                    .lineLimit(1)
            } else {
                Text(person.displayName)
                    .font(.body)
                    .foregroundStyle(DesignPalette.label(for: colorScheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    @ViewBuilder private var menu: some View {
        if person.isHidden {
            Button("Unhide") { actions.setHidden(person.id, false) }
        } else {
            Button(person.name == nil ? "Add Name…" : "Rename…") { actions.edit(person.id) }
            Button("Set Birthday…") { actions.edit(person.id) }
            Button(person.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                actions.setFavorite(person.id, !person.isFavorite)
            }
            let targets = people.visiblePeople.filter { selectedPeople.contains($0.id) && $0.id != person.id }
            if selectedPeople.contains(person.id), !targets.isEmpty {
                Menu("Merge Into") {
                    ForEach(targets) { target in
                        Button(target.displayName) { actions.askMerge(person.id, target.id) }
                            .disabled(actions.mergeRefusal(person.id, target.id) != nil)
                            .help(actions.mergeRefusal(person.id, target.id) ?? "")
                    }
                }
            }
            Divider()
            Button("Hide") { actions.setHidden(person.id, true) }
            Divider()
            Button("Show Photos") { actions.open(person.id) }
        }
    }
}

/// A person dragged within the People gallery, as text, under a prefix of its own so a drop
/// never reads another payload.
nonisolated enum PeopleDrag {
    private static let prefix = "net.melisma.otos.person:"

    static func payload(_ person: PersonID) -> String {
        prefix + String(person.rawValue)
    }

    static func person(from payload: String) -> PersonID? {
        guard payload.hasPrefix(prefix), let value = Int64(payload.dropFirst(prefix.count)) else { return nil }
        return PersonID(rawValue: value)
    }
}
