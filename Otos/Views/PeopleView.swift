import AppKit
import SwiftUI

// The detail pane for the `.people` scope (ADR 0047, `docs/design/people.md`): a 52 pt bar
// stating how many people are named and how many photos are not yet checked, with Review
// Suggestions; under it, every person as their newest confirmed face, name and photo count,
// most photos first. Passive: strings come from `PeoplePresentation`, and every control
// calls a view-model intent through `PeopleActions`.

/// The words People's surfaces show. Pure, so each one is tested without a window.
nonisolated enum PeoplePresentation {
    /// The list bar's L1.
    static func peopleLine(_ count: Int) -> String {
        count == 0 ? "No people" : PeopleText.count(count, "person").replacingOccurrences(of: "persons", with: "people")
    }

    /// The tally both bars carry as L3.
    static func uncheckedLine(_ count: Int) -> String {
        count == 0 ? "Every photo has been checked" : "\(PeopleText.count(count, "photo")) not yet checked for faces"
    }

    /// The list's sentence when it holds nobody; nil when it holds someone or the window's
    /// shared sentence speaks instead.
    static func emptyListSentence(_ state: CatalogPeopleState) -> String? {
        guard state.people.isEmpty else { return nil }
        if state.faceCount > 0 {
            return "Name the faces Otos found in Review Suggestions."
        }
        if state.uncheckedPhotoCount > 0 {
            return "People appear here as Otos finds faces in your photos."
        }
        return "Otos found no faces in your photos."
    }

    /// The review bar's L1 for the list shown.
    static func reviewLine(_ count: Int, list: PeopleReviewList) -> String {
        switch list {
        case .suggestions: count == 0 ? "Nothing to review" : "\(PeopleText.count(count, "face")) to review"
        case .unsure: count == 0 ? "Nothing to decide" : "\(PeopleText.count(count, "face")) to decide"
        }
    }

    /// A year header's L3.
    static func yearCount(_ count: Int, list: PeopleReviewList) -> String {
        "\(PeopleText.count(count, "face")) to \(list == .suggestions ? "review" : "decide")"
    }

    /// The review's sentence when the shown list is empty.
    static func emptyReviewSentence(_ state: CatalogPeopleState, list: PeopleReviewList) -> String {
        if state.faceCount == 0 {
            return "Suggestions appear here as Otos finds faces."
        }
        if state.uncheckedPhotoCount > 0 {
            return "More suggestions may appear as photos are checked."
        }
        return list == .suggestions
            ? "Every face Otos is sure about has been reviewed."
            : "No face is left that could be either of two people."
    }

    /// The legend in the review bar's middle zone.
    static func legend(_ list: PeopleReviewList) -> String {
        switch list {
        case .suggestions: "Select faces and press Return to confirm, or Delete if it isn't them."
        case .unsure: "Select faces and press ⌘[ or ⌘] to choose who it is, or Delete if it's neither."
        }
    }

    /// The bar's act.
    static func confirmTitle(_ count: Int, enabled: Bool) -> String {
        enabled ? "Confirm \(PeopleText.count(count, "Face"))" : "Confirm Faces"
    }

    /// A person row header's L3: `12 faces · like Sam in 2024`.
    static func rowDetail(_ row: PeopleReviewRow, names: (PersonID) -> String) -> String {
        let faces = PeopleText.count(row.faces.count, "face")
        switch row.kind {
        case let .person(person, referenceYear):
            if let referenceYear {
                return "\(faces) · like \(names(person)) in \(referenceYear)"
            }
            return "\(faces) · like \(names(person))"
        case .unnamed, .unsure:
            return faces
        }
    }

    /// A row header's L2.
    static func rowTitle(_ row: PeopleReviewRow, names: (PersonID) -> String) -> String {
        switch row.kind {
        case let .person(person, _): names(person)
        case .unnamed: "Unnamed"
        case let .unsure(first, second): "\(names(first)) or \(names(second))?"
        }
    }

    /// A face's date under it: `Mar 4`, with the year when it differs from its row's year.
    static func faceDate(_ tile: FaceTile, rowYear: Int?, calendar: Calendar = .current) -> String {
        guard let date = tile.captureDate else { return "No date" }
        if let rowYear, calendar.component(.year, from: date) == rowYear {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// VoiceOver's reading of a review face.
    static func faceAccessibility(_ tile: FaceTile, row: PeopleReviewRow, names: (PersonID) -> String) -> String {
        let date = tile.captureDate?.formatted(date: .long, time: .omitted) ?? "No date"
        switch row.kind {
        case let .person(person, _): return "\(date), suggested as \(names(person))"
        case .unnamed: return "\(date), in an unnamed group"
        case let .unsure(first, second): return "\(date), \(names(first)) or \(names(second))"
        }
    }
}

/// The view model's People intents, handed to the passive views.
struct PeopleActions {
    let selectPerson: @MainActor (PersonID?, NSEvent.ModifierFlags) -> Void
    let openPerson: @MainActor (PersonID) -> Void
    let openReview: @MainActor () -> Void
    let edit: @MainActor (PersonID) -> Void
    let askMerge: @MainActor (PersonID, PersonID) -> Void
    let mergeRefusal: @MainActor (PersonID, PersonID) -> String?
    let answerMerge: @MainActor (Bool) -> Void
    let remove: @MainActor (PersonID) -> Void
}

struct PeopleView: View {
    let people: CatalogPeopleState
    let session: PeopleSession
    /// The window's shared sentence when libraries are offline or being checked.
    let librariesState: CatalogMediaEmptyState
    let images: FaceTileImages?
    let derivedImageDirectory: URL?
    let canReview: Bool
    let actions: PeopleActions

    @FocusState private var listFocused: Bool
    @State private var columns = 1
    @Environment(\.colorScheme) private var colorScheme

    private static let edge: CGFloat = 128
    private static let gutter: CGFloat = 8

    var body: some View {
        VStack(spacing: 0) {
            PeopleListBar(people: people, canReview: canReview, openReview: actions.openReview)
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
                list
            }
        }
        .background(DesignPalette.content(for: colorScheme))
        .alert(
            "Are these the same person?",
            isPresented: Binding(
                get: { session.mergeQuestion != nil },
                set: {
                    if !$0 {
                        actions.answerMerge(false)
                    }
                }
            ),
            presenting: session.mergeQuestion
        ) { _ in
            Button("Merge") { actions.answerMerge(true) }
            Button("Cancel", role: .cancel) { actions.answerMerge(false) }
        } message: { question in
            Text("\(name(question.from)) will be merged into \(name(question.into)), keeping \(name(question.into))'s name and birthday.")
        }
    }

    private func name(_ person: PersonID) -> String {
        people.person(person)?.displayName ?? "Unnamed"
    }

    private var emptySentence: String? {
        guard people.people.isEmpty else { return nil }
        switch librariesState {
        case .checkingLibraries, .noAvailableMedia:
            return librariesState.message
        default:
            return PeoplePresentation.emptyListSentence(people)
        }
    }

    private var order: [PersonID] {
        people.people.map(\.id)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: Self.edge, maximum: Self.edge), spacing: Self.gutter, alignment: .top)],
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(people.people) { person in
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
                let from = session.personCursor.flatMap(order.firstIndex(of:))
                let target = from.map { $0 + step } ?? 0
                guard order.indices.contains(target) else { return .ignored }
                actions.selectPerson(order[target], press.modifiers.contains(.shift) ? .shift : [])
                proxy.scrollTo(order[target])
                return .handled
            }
            .onKeyPress(.return) {
                guard let cursor = session.personCursor else { return .ignored }
                actions.openPerson(cursor)
                return .handled
            }
            .onKeyPress(.escape) {
                actions.selectPerson(nil, [])
                return .handled
            }
        }
    }
}

/// The list's bar (DES-109): what (L1 over the tally) and the act.
private struct PeopleListBar: View {
    let people: CatalogPeopleState
    let canReview: Bool
    let openReview: @MainActor () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(PeoplePresentation.peopleLine(people.people.count))
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
            Button("Review Suggestions", action: openReview)
                .disabled(!canReview)
                .help(canReview ? "Confirm the faces Otos found." : "Nothing to review")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(DesignPalette.bar(for: colorScheme))
    }
}

/// One person: their newest confirmed face, their name and their photo count. Dragging one
/// onto another asks whether they are the same person.
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
            Group {
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
            Text(person.displayName)
                .font(.body)
                .foregroundStyle(DesignPalette.label(for: colorScheme))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(PeopleText.count(person.photoCount, "photo"))
                .font(.subheadline)
                .foregroundStyle(DesignPalette.l3(for: colorScheme))
                .monospacedDigit()
        }
        .frame(width: edge, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            actions.openPerson(person.id)
        }
        .simultaneousGesture(TapGesture().modifiers(.command).onEnded {
            focusList()
            actions.selectPerson(person.id, .command)
        })
        .simultaneousGesture(TapGesture().modifiers(.shift).onEnded {
            focusList()
            actions.selectPerson(person.id, .shift)
        })
        .onTapGesture {
            focusList()
            actions.selectPerson(person.id, [])
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
            Button("Rename…") { actions.edit(person.id) }
            Button("Set Birthday…") { actions.edit(person.id) }
            if selectedPeople.count >= 2, selectedPeople.contains(person.id) {
                Menu("Merge Into") {
                    ForEach(people.people.filter { selectedPeople.contains($0.id) && $0.id != person.id }) { target in
                        Button(target.displayName) { actions.askMerge(person.id, target.id) }
                            .disabled(actions.mergeRefusal(person.id, target.id) != nil)
                            .help(actions.mergeRefusal(person.id, target.id) ?? "")
                    }
                }
            }
            Divider()
            Button("Remove Person") { actions.remove(person.id) }
            Divider()
            Button("Review Suggestions") { actions.openReview() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(person.displayName), \(PeopleText.count(person.photoCount, "photo"))")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { actions.openPerson(person.id) }
    }
}

/// A person dragged within the list, as text.
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
