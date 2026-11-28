import AppKit
import SwiftUI

// The detail pane for the `.people` scope (ADR 0047, `docs/design/people.md`): a 52 pt bar
// stating how many people there are and how many photos are not yet checked; under it,
// everyone as their key photo, name (or `Add Name…`) and photo count, favourites first,
// then the named people, then the unnamed, each by most photos; then, under `Hidden`, the people the user hid, the one place they are
// seen. Passive: strings come from `PeoplePresentation`, and every control calls a
// view-model intent through `PeopleActions`.

/// The words People's surfaces show. Pure, so each one is tested without a window.
nonisolated enum PeoplePresentation {
    /// The gallery bar's L1: the people every surface offers, the visible ones.
    static func peopleLine(_ count: Int) -> String {
        count == 0 ? "No people" : PeopleText.count(count, "person").replacingOccurrences(of: "persons", with: "people")
    }

    /// The tally the bar carries as L3.
    static func uncheckedLine(_ unchecked: MediaCount) -> String {
        unchecked.total == 0 ? "Every photo has been checked" : "\(unchecked.text) not yet checked for faces"
    }

    /// The gallery's sentence when it holds nobody; nil when it holds someone.
    static func emptySentence(_ state: CatalogPeopleState) -> String? {
        guard state.people.isEmpty else { return nil }
        if state.hasFaces {
            return "People appear here once Otos finds the same face on different days."
        }
        if state.unchecked.total > 0 {
            return "People appear here as Otos finds faces in your photos."
        }
        return "Otos found no faces in your photos."
    }

    /// A person cell as VoiceOver reads it.
    static func accessibilityLabel(_ person: PersonSummary) -> String {
        var parts = [person.displayName, person.media.text]
        if person.isFavorite {
            parts.append("favorite")
        }
        if person.isHidden {
            parts.append("hidden")
        }
        return parts.joined(separator: ", ")
    }
}

struct PeopleView: View, Equatable {
    let people: CatalogPeopleState
    let session: PeopleSession
    /// The window's shared sentence when libraries are offline or being checked.
    let librariesState: CatalogMediaEmptyState?
    let images: FaceTileImages?
    let derivedImageDirectory: URL?
    /// The gallery's intents: not part of what it shows.
    let actions: PeopleActions

    /// What the gallery shows. The window re-renders its detail pane for every state it
    /// applies, People or not; an equal gallery is not rendered again (`.equatable()` where
    /// `ContentView` hosts it), and comparing the People state of an unchanged publication
    /// is a storage-identity check.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.people == rhs.people && lhs.session == rhs.session && lhs.librariesState == rhs.librariesState
            && lhs.images === rhs.images && lhs.derivedImageDirectory == rhs.derivedImageDirectory
    }

    @FocusState private var listFocused: Bool
    @State private var columns = 1
    /// How far the gallery is scrolled, kept here as it scrolls and handed to the window only
    /// as the gallery leaves the screen (`PeopleActions.rememberOffset`), so scrolling never
    /// writes window state.
    @State private var offset: CGFloat
    /// Starts where the gallery was when it last left the screen (Back to People, or another
    /// sidebar row and back): a new gallery's scroll view takes it as it first lays out.
    @State private var position: ScrollPosition

    init(
        people: CatalogPeopleState,
        session: PeopleSession,
        librariesState: CatalogMediaEmptyState?,
        images: FaceTileImages?,
        derivedImageDirectory: URL?,
        actions: PeopleActions
    ) {
        self.people = people
        self.session = session
        self.librariesState = librariesState
        self.images = images
        self.derivedImageDirectory = derivedImageDirectory
        self.actions = actions
        _offset = State(initialValue: session.galleryOffset)
        _position = State(initialValue: ScrollPosition(y: session.galleryOffset))
    }

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
        case .checkingLibraries?, .noAvailableMedia?:
            return librariesState?.message
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
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, scrolled in
                offset = scrolled
            }
            .onDisappear {
                actions.rememberOffset(offset)
            }
            .focusable()
            // A collection shows the keyboard by its selection, never a ring around the whole
            // gallery (HIG, Focus and selection; DES-081): the arrows move the selection.
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                let step: PeopleGalleryStep = switch press.key {
                case .leftArrow: .left
                case .rightArrow: .right
                case .upArrow: .up
                default: .down
                }
                guard let reached = actions.moveCursor(step, columns, press.modifiers.contains(.shift)) else { return .ignored }
                proxy.scrollTo(reached)
                return .handled
            }
            // A merge's person, once People shows them where they now sort.
            .onChange(of: session.reveal) { _, reveal in
                guard let reveal else { return }
                proxy.scrollTo(reveal.person)
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

    /// A cell is equal to the one it replaces while its person, selection and images are, so
    /// a People update re-renders only the cells whose person changed (`PersonCell.==`).
    private func cell(_ person: PersonSummary) -> some View {
        PersonCell(
            person: person,
            edge: Self.edge,
            isSelected: session.selectedPeople.contains(person.id),
            images: images,
            derivedImageDirectory: derivedImageDirectory,
            actions: actions,
            focusList: { listFocused = true }
        )
        .equatable()
        .id(person.id)
    }
}

/// The question every merge asks first, wherever it was asked:
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
            Text("\(name(question.from)) will be merged into \(name(question.into)), keeping \(name(question.into))’s name and birthday.")
        }
    }
}

/// An act the window showed that the store refused or could not write: a merge the user
/// answered that an act submitted before it made impossible, said in the words the disabled
/// act uses (DES-038), or any act whose write failed, named as back as it was (DES-120).
struct PeopleRefusalAlert: ViewModifier {
    let refusal: PeopleActRefusal?
    let dismiss: () -> Void

    func body(content: Content) -> some View {
        content.alert(
            refusal?.title ?? "",
            isPresented: Binding(
                get: { refusal != nil },
                set: {
                    if !$0 {
                        dismiss()
                    }
                }
            ),
            presenting: refusal
        ) { _ in
            Button("OK", action: dismiss)
        } message: { refusal in
            Text(refusal.reason)
        }
    }
}

/// The gallery's bar (DES-109): L1 over the tally. `nil` before People is first built: both
/// lines hold their height and say nothing (APP-044, DES-118).
struct PeopleBar: View {
    let people: CatalogPeopleState?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(people.map { PeoplePresentation.peopleLine($0.visiblePeople.count) } ?? " ")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(DesignPalette.label(for: colorScheme))
                    .monospacedDigit()
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text(people.map { PeoplePresentation.uncheckedLine($0.unchecked) } ?? " ")
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

/// One person: their key photo, their name (or `Add Name…`) and their photo count; a
/// heart before the name for a favourite. A hidden person is dimmed and offers Unhide and, among people selected with it, Merge Into.
/// Dragging one person onto another asks whether they are the same person.
///
/// Its body reads only its own values: nothing in it scales with the number of people. Its
/// context menu and VoiceOver actions are child views whose bodies ask the view model for the
/// person's menu, which SwiftUI evaluates only as the menu or VoiceOver opens them.
private struct PersonCell: View, Equatable {
    let person: PersonSummary
    let edge: CGFloat
    let isSelected: Bool
    let images: FaceTileImages?
    let derivedImageDirectory: URL?
    /// Intents, the same for every cell of the gallery: not part of what the cell shows.
    let actions: PeopleActions
    let focusList: () -> Void

    @State private var isTargeted = false
    @Environment(\.colorScheme) private var colorScheme

    /// What the cell shows: its person, selection, edge and images. The closures are the
    /// gallery's intents, rebuilt with every window update and the same in effect.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.person == rhs.person && lhs.isSelected == rhs.isSelected && lhs.edge == rhs.edge
            && lhs.images === rhs.images && lhs.derivedImageDirectory == rhs.derivedImageDirectory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            face
            nameLine
            Text(person.media.text)
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
            guard let from = items.first.flatMap(PeopleDrag.person(from:)), from != person.id,
                  actions.mergeRefusal(from, person.id) == nil
            else { return false }
            actions.askMerge(from, person.id)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .contextMenu {
            PersonContextMenu(person: person.id, actions: actions)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PeoplePresentation.accessibilityLabel(person))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { actions.open(person.id) }
        // The context menu's acts, in its words, so VoiceOver reaches every one (DES-080).
        .accessibilityActions {
            PersonAccessibilityActions(person: person.id, actions: actions)
        }
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
}

/// A cell's context menu: the person's `PersonMenu`, asked for when the menu opens, so the
/// selection it offers to merge into is the one at that moment.
private struct PersonContextMenu: View {
    let person: PersonID
    let actions: PeopleActions

    var body: some View {
        if let menu = actions.menu(person) {
            PersonMenuContent(menu: menu) { actions.perform($0, person) }
        }
    }
}

/// A cell's VoiceOver actions: the context menu's enabled acts, asked for when VoiceOver
/// reads them.
private struct PersonAccessibilityActions: View {
    let person: PersonID
    let actions: PeopleActions

    var body: some View {
        ForEach(actions.menu(person)?.accessibilityItems ?? [], id: \.title) { item in
            Button(item.title) { actions.perform(item.act, person) }
        }
    }
}

/// A person's settings as one menu renders them: the gallery's context menu, the menu bar,
/// and the toolbar menu of a person's photos (`PersonMenu`). A disabled item says why in its
/// tooltip (DES-038).
struct PersonMenuContent: View {
    let menu: PersonMenu
    let perform: (PersonMenu.Act) -> Void

    var body: some View {
        ForEach(menu.settings, id: \.title) { item in
            button(item)
        }
        if let targets = menu.mergeInto {
            Menu("Merge Into") {
                ForEach(targets, id: \.title) { item in
                    button(item)
                }
            }
            .disabled(targets.isEmpty)
        }
        if !menu.settings.isEmpty {
            Divider()
        }
        button(menu.visibility)
        if let open = menu.open {
            Divider()
            button(open)
        }
    }

    private func button(_ item: PersonMenu.Item) -> some View {
        Button(item.title) { perform(item.act) }
            .disabled(item.refusal != nil)
            .help(item.refusal ?? "")
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
