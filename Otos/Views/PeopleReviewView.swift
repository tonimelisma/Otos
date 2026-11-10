import AppKit
import SwiftUI

// The detail pane for the `.peopleReview` scope (ADR 0047, `docs/design/people.md`): the
// shown list — Suggestions or Unsure — grouped by year, newest first; in each year one row
// per person (their suggested faces beside the confirmed face they rest on), per unnamed
// group, or per pair of people a face could be. Under it a fixed-height bar: the list
// picker, what is left, the last act's receipt or the legend, and Confirm, which Return
// fires. Passive: every string comes from `PeoplePresentation`, every act is an intent
// through `PeopleReviewActions`, and the selection is the view model's.

/// The view model's review intents, handed to the passive views.
struct PeopleReviewActions {
    let select: @MainActor (FaceID?, NSEvent.ModifierFlags) -> Void
    let selectRow: @MainActor (PeopleReviewRow) -> Void
    let selectAll: @MainActor () -> Void
    let move: @MainActor (PeopleReviewLayout.Direction, Bool) -> Void
    let setList: @MainActor (PeopleReviewList) -> Void
    let confirmSelection: @MainActor () -> Void
    let confirmRow: @MainActor (PeopleReviewRow) -> Void
    let confirmCandidate: @MainActor (Int) -> Void
    let reject: @MainActor () -> Void
    let notAFace: @MainActor ([FaceID]) -> Void
    let ignoreRow: @MainActor (PeopleReviewRow) -> Void
    let thisIsChoices: @MainActor ([FaceID]) -> [PersonSummary]
    let moveTo: @MainActor ([FaceID], PersonID) -> Void
    /// Faces dropped onto a row in a year; false when the drop is refused.
    let dropFaces: @MainActor ([FaceID], PeopleReviewRow, Int?) -> Bool
    let split: @MainActor ([FaceID]) -> Void
    let beginNaming: @MainActor ([FaceID]) -> Void
    let cancelNaming: @MainActor () -> Void
    let nameCompletions: @MainActor (String) -> [String]
    let namingRefusal: @MainActor (String) -> String?
    let commitNaming: @MainActor (String) -> Void
    let openPhoto: @MainActor (FaceID) -> Void
    let undo: @MainActor () -> Void
}

/// What the review bar shows.
struct PeopleReviewBarState: Equatable {
    let list: PeopleReviewList
    let suggestionCount: Int
    let unsureCount: Int
    let shownCount: Int
    let uncheckedCount: Int
    let receipt: PeopleReceipt?
    let canUndoReceipt: Bool
    let selectedCount: Int
    let canConfirm: Bool
    let confirmRefusal: String?
}

struct PeopleReviewView: View {
    let people: CatalogPeopleState
    let layout: PeopleReviewLayout
    let session: PeopleSession
    let bar: PeopleReviewBarState
    let names: (PersonID) -> String
    let images: FaceTileImages?
    let derivedImageDirectory: URL?
    let actions: PeopleReviewActions

    @FocusState private var listFocused: Bool
    /// The person row a drag of faces is over, by its year, while that drop would be taken.
    @State private var dropRow: DropRow?
    @Environment(\.colorScheme) private var colorScheme

    private struct DropRow: Equatable {
        let row: PeopleReviewRow.ID
        let year: Int?
    }

    var body: some View {
        VStack(spacing: 0) {
            if layout.years.isEmpty {
                Text(PeoplePresentation.emptyReviewSentence(people, list: session.list))
                    .font(.subheadline)
                    .foregroundStyle(DesignPalette.l3(for: colorScheme))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusable()
                    .focusEffectDisabled()
                    .focused($listFocused)
                    .modifier(ListKeys(session: session, actions: actions))
            } else {
                list
            }
            Rectangle()
                .fill(DesignPalette.hairline(for: colorScheme))
                .frame(height: 1)
            PeopleReviewBar(state: bar, actions: actions)
        }
        .background(DesignPalette.content(for: colorScheme))
        .onAppear { listFocused = true }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(layout.years.enumerated()), id: \.element.id) { index, year in
                        yearSection(year, isFirst: index == 0)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .modifier(ListKeys(session: session, actions: actions))
            .onChange(of: session.faceCursor) { _, cursor in
                if let cursor {
                    proxy.scrollTo(cursor)
                }
            }
        }
    }

    private func yearSection(_ year: PeopleReviewYear, isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !isFirst {
                Rectangle()
                    .fill(DesignPalette.hairline(for: colorScheme))
                    .frame(height: 1)
                    .padding(.bottom, 8)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(year.year.map(String.init) ?? "No Date")
                    .font(.headline)
                    .foregroundStyle(DesignPalette.label(for: colorScheme))
                    .accessibilityAddTraits(.isHeader)
                Text(PeoplePresentation.yearCount(year.faceCount, list: session.list))
                    .font(.subheadline)
                    .foregroundStyle(DesignPalette.l3(for: colorScheme))
                    .monospacedDigit()
            }
            ForEach(Array(year.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(DesignPalette.hairline(for: colorScheme))
                        .frame(height: 1)
                }
                rowView(row, year: year.year)
            }
        }
        .padding(.bottom, 16)
    }

    private func rowView(_ row: PeopleReviewRow, year: Int?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(PeoplePresentation.rowTitle(row, names: names))
                        .font(.body)
                        .foregroundStyle(DesignPalette.label(for: colorScheme))
                    Text(PeoplePresentation.rowDetail(row, names: names))
                        .font(.subheadline)
                        .foregroundStyle(DesignPalette.l3(for: colorScheme))
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    listFocused = true
                    actions.selectRow(row)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                rowLinks(row)
            }
            HStack(alignment: .top, spacing: 16) {
                if !row.references.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(row.references) { reference in
                            referenceTile(reference, row: row)
                        }
                    }
                }
                faces(row, year: year)
            }
        }
        .padding(.vertical, 8)
        .background {
            if dropRow == DropRow(row: row.id, year: year) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.12))
                    .padding(.horizontal, -6)
            }
        }
        // Faces dragged from another row of this year onto a person's row: This Is ▸ them.
        .dropDestination(for: String.self) { items, _ in
            dropRow = nil
            guard let faces = items.first.flatMap(PeopleDrag.faces(from:)) else { return false }
            return actions.dropFaces(faces, row, year)
        } isTargeted: { targeted in
            if !targeted {
                if dropRow == DropRow(row: row.id, year: year) {
                    dropRow = nil
                }
            } else if case .person = row.kind {
                dropRow = DropRow(row: row.id, year: year)
            }
        }
    }

    @ViewBuilder
    private func rowLinks(_ row: PeopleReviewRow) -> some View {
        switch row.kind {
        case .person:
            Button("Confirm All") { actions.confirmRow(row) }
                .buttonStyle(.link)
                .font(.subheadline)
        case .unnamed:
            HStack(spacing: 12) {
                Button("Add Name…") { actions.beginNaming(row.faces.map(\.id)) }
                    .buttonStyle(.link)
                    .font(.subheadline)
                    .popover(isPresented: namingBinding(for: row.faces.map(\.id)), arrowEdge: .bottom) {
                        NamePopover(actions: actions)
                    }
                Button("Ignore") { actions.ignoreRow(row) }
                    .buttonStyle(.link)
                    .font(.subheadline)
            }
        case .unsure:
            EmptyView()
        }
    }

    /// The confirmed face a row rests on: evidence, not a choice, so neither selectable nor
    /// a Tab stop.
    private func referenceTile(_ tile: FaceTile, row: PeopleReviewRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            FaceTileView(tile: tile, edge: Self.edge, isSelected: false, images: images, derivedImageDirectory: derivedImageDirectory)
                .overlay {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(DesignPalette.label(for: colorScheme).opacity(0.3), lineWidth: 1)
                }
            if case .unsure = row.kind, let person = referencePerson(tile) {
                Text(names(person))
                    .font(.subheadline)
                    .foregroundStyle(DesignPalette.l3(for: colorScheme))
                    .lineLimit(1)
            }
            Text(PeoplePresentation.faceDate(tile, rowYear: nil))
                .font(.subheadline)
                .foregroundStyle(DesignPalette.l3(for: colorScheme))
                .lineLimit(1)
        }
        .frame(width: Self.edge, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Confirmed face from \(tile.captureLocalTime?.formatted(Date.FormatStyle(date: .long, time: .omitted)) ?? "no date")")
    }

    private func referencePerson(_ tile: FaceTile) -> PersonID? {
        people.people.first { person in person.faces.contains { $0.id == tile.id } }?.id
    }

    private static let edge: CGFloat = 96
    private static let gutter: CGFloat = 8

    private func faces(_ row: PeopleReviewRow, year: Int?) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Self.edge, maximum: Self.edge), spacing: Self.gutter, alignment: .top)],
            alignment: .leading,
            spacing: Self.gutter
        ) {
            ForEach(row.faces) { tile in
                ReviewFace(
                    tile: tile,
                    row: row,
                    rowYear: year,
                    edge: Self.edge,
                    isSelected: session.selectedFaces.contains(tile.id),
                    selection: session.selectedFaces,
                    names: names,
                    images: images,
                    derivedImageDirectory: derivedImageDirectory,
                    naming: namingBinding(for: Array(session.selectedFaces), anchor: tile.id),
                    actions: actions,
                    focusList: { listFocused = true }
                )
                .id(tile.id)
            }
        }
    }

    /// The name popover, open on the tile it is anchored to: the first selected face in
    /// reading order, or the row link that asked.
    private func namingBinding(for faces: [FaceID], anchor: FaceID? = nil) -> Binding<Bool> {
        Binding(
            get: {
                guard let naming = session.naming else { return false }
                if let anchor {
                    return Set(naming) == Set(faces) && layout.order.first(where: Set(naming).contains) == anchor
                }
                return naming == faces
            },
            set: {
                if !$0 {
                    actions.cancelNaming()
                }
            }
        )
    }
}

/// The review's keys (DES-113): arrows, ⌘A, Return, Delete, ⇧O, Space, ⌘[ / ⌘], ⌘1 / ⌘2
/// and Escape.
private struct ListKeys: ViewModifier {
    let session: PeopleSession
    let actions: PeopleReviewActions

    func body(content: Content) -> some View {
        content
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                let direction: PeopleReviewLayout.Direction = switch press.key {
                case .leftArrow: .previous
                case .rightArrow: .next
                case .upArrow: .up
                default: .down
                }
                actions.move(direction, press.modifiers.contains(.shift))
                return .handled
            }
            .onKeyPress(.return) {
                if session.list == .suggestions {
                    actions.confirmSelection()
                }
                return .handled
            }
            .onKeyPress(keys: [.delete, .deleteForward]) { press in
                // ⌘⌫ never moves a photo to the Trash from here: Delete means "not them".
                guard !press.modifiers.contains(.command) else { return .handled }
                actions.reject()
                return .handled
            }
            .onKeyPress(.space) {
                guard let cursor = session.faceCursor else { return .ignored }
                actions.openPhoto(cursor)
                return .handled
            }
            .onKeyPress(.escape) {
                actions.select(nil, [])
                return .handled
            }
            .onKeyPress(characters: CharacterSet(charactersIn: "oOaA[]12")) { press in
                switch (press.characters.lowercased(), press.modifiers) {
                case ("o", .shift):
                    actions.beginNaming(Array(session.selectedFaces))
                case ("a", .command):
                    actions.selectAll()
                case ("[", .command):
                    actions.confirmCandidate(0)
                case ("]", .command):
                    actions.confirmCandidate(1)
                case ("1", .command):
                    actions.setList(.suggestions)
                case ("2", .command):
                    actions.setList(.unsure)
                default:
                    return .ignored
                }
                return .handled
            }
    }
}

/// One suggested face: its tile and its date, selectable, with the review's acts on its
/// context menu and as VoiceOver actions.
private struct ReviewFace: View {
    let tile: FaceTile
    let row: PeopleReviewRow
    let rowYear: Int?
    let edge: CGFloat
    let isSelected: Bool
    let selection: Set<FaceID>
    let names: (PersonID) -> String
    let images: FaceTileImages?
    let derivedImageDirectory: URL?
    let naming: Binding<Bool>
    let actions: PeopleReviewActions
    let focusList: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// The faces an act from this tile's menu applies to: the selection when the tile is in
    /// it, else this face.
    private var targets: [FaceID] {
        isSelected ? Array(selection) : [tile.id]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            FaceTileView(tile: tile, edge: edge, isSelected: isSelected, images: images, derivedImageDirectory: derivedImageDirectory)
            Text(PeoplePresentation.faceDate(tile, rowYear: rowYear))
                .font(.subheadline)
                .foregroundStyle(DesignPalette.l3(for: colorScheme))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(width: edge, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            actions.openPhoto(tile.id)
        }
        .simultaneousGesture(TapGesture().modifiers(.command).onEnded {
            focusList()
            actions.select(tile.id, .command)
        })
        .simultaneousGesture(TapGesture().modifiers(.shift).onEnded {
            focusList()
            actions.select(tile.id, .shift)
        })
        .onTapGesture {
            focusList()
            actions.select(tile.id, [])
        }
        .popover(isPresented: naming, arrowEdge: .bottom) {
            NamePopover(actions: actions)
        }
        .draggable(PeopleDrag.payload(faces: targets))
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PeoplePresentation.faceAccessibility(tile, row: row, names: names))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Confirm") {
            if !isSelected {
                actions.select(tile.id, [])
            }
            actions.confirmSelection()
        }
        .accessibilityActions {
            if let rejectName {
                Button(rejectName) {
                    if !isSelected {
                        actions.select(tile.id, [])
                    }
                    actions.reject()
                }
            }
        }
        .accessibilityAction(named: "Open Photo") { actions.openPhoto(tile.id) }
        .accessibilityAction(named: "Name…") { actions.beginNaming(targets) }
    }

    /// Delete's name on this face's row, as the context menu and VoiceOver say it.
    /// Nil on an unnamed row: there is no person to reject.
    private var rejectName: String? {
        switch row.kind {
        case let .person(person, _): "Not \(names(person))"
        case let .unsure(first, second): "Not \(names(first)) or \(names(second))"
        case .unnamed: nil
        }
    }

    @ViewBuilder
    private var menu: some View {
        switch row.kind {
        case let .person(person, _):
            Button("Confirm") {
                if !isSelected {
                    actions.select(tile.id, [])
                }
                actions.confirmSelection()
            }
            Button("Not \(names(person))") {
                if !isSelected {
                    actions.select(tile.id, [])
                }
                actions.reject()
            }
        case let .unsure(first, second):
            Button(names(first)) {
                if !isSelected {
                    actions.select(tile.id, [])
                }
                actions.confirmCandidate(0)
            }
            Button(names(second)) {
                if !isSelected {
                    actions.select(tile.id, [])
                }
                actions.confirmCandidate(1)
            }
            Button("Not \(names(first)) or \(names(second))") {
                if !isSelected {
                    actions.select(tile.id, [])
                }
                actions.reject()
            }
        case .unnamed:
            EmptyView()
        }
        Menu("This Is") {
            ForEach(actions.thisIsChoices(targets)) { person in
                Button(person.displayName) { actions.moveTo(targets, person.id) }
            }
            Divider()
            Button("New Person") { actions.split(targets) }
        }
        Button("Name…") { actions.beginNaming(targets) }
        Divider()
        Button("Not a Face") { actions.notAFace(targets) }
        Divider()
        Button("Open Photo") { actions.openPhoto(tile.id) }
    }
}

/// One field that completes eligible names. Return commits, Escape cancels.
private struct NamePopover: View {
    let actions: PeopleReviewActions

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let refusal = actions.namingRefusal(text)
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused($focused)
                .onSubmit {
                    actions.commitNaming(text)
                }
                .onExitCommand {
                    actions.cancelNaming()
                }
            let completions = actions.nameCompletions(text).prefix(6)
            if !completions.isEmpty, !completions.contains(text) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(completions), id: \.self) { name in
                        Button(name) { text = name }
                            .buttonStyle(.link)
                    }
                }
            }
            if let refusal, !text.isEmpty {
                Text(refusal)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .onAppear { focused = true }
    }
}

/// The review's bar (DES-018, DES-109): the list picker, what is left over the tally, the
/// receipt or the legend behind a hairline, and Confirm, the one prominent act.
private struct PeopleReviewBar: View {
    let state: PeopleReviewBarState
    let actions: PeopleReviewActions

    @Environment(\.colorScheme) private var colorScheme

    private static let contentHeight: CGFloat = 40

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            Picker("List", selection: Binding(get: { state.list }, set: actions.setList)) {
                Text("Suggestions \(state.suggestionCount.formatted())").tag(PeopleReviewList.suggestions)
                Text("Unsure \(state.unsureCount.formatted())").tag(PeopleReviewList.unsure)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            VStack(alignment: .leading, spacing: 2) {
                Text(PeoplePresentation.reviewLine(state.shownCount, list: state.list))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(DesignPalette.label(for: colorScheme))
                    .monospacedDigit()
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text(PeoplePresentation.uncheckedLine(state.uncheckedCount))
                    .font(.subheadline)
                    .foregroundStyle(DesignPalette.l3(for: colorScheme))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            HStack(spacing: 20) {
                Rectangle()
                    .fill(DesignPalette.hairline(for: colorScheme))
                    .frame(width: 1, height: Self.contentHeight)
                middle
            }
            Spacer(minLength: 0)
            Button(PeoplePresentation.confirmTitle(state.selectedCount, enabled: state.canConfirm), action: actions.confirmSelection)
                .buttonStyle(.borderedProminent)
                .disabled(!state.canConfirm)
                .help(state.confirmRefusal ?? (state.list == .unsure
                        ? "Choose who each face is with ⌘[ or ⌘]."
                        : "Confirms the selected faces as the person suggested."))
        }
        .frame(minHeight: Self.contentHeight, maxHeight: Self.contentHeight)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(DesignPalette.bar(for: colorScheme))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var middle: some View {
        if let receipt = state.receipt {
            HStack(spacing: 7) {
                Text(receipt.text)
                    .font(.subheadline)
                    .foregroundStyle(DesignPalette.label(for: colorScheme))
                    .monospacedDigit()
                    .lineLimit(1)
                if state.canUndoReceipt {
                    Button("Undo", action: actions.undo)
                        .buttonStyle(.link)
                        .font(.subheadline)
                }
            }
        } else {
            Text(PeoplePresentation.legend(state.list))
                .font(.subheadline)
                .foregroundStyle(DesignPalette.l3(for: colorScheme))
                .lineLimit(2)
        }
    }
}
