import AppKit
import Foundation
import OSLog

// People intents (ADR 0047, `docs/design/people.md`)
//
// Projection publishes People on `CatalogWindowState.people` in every scope; this file owns
// what is specific to working with it: the people and faces the user selected, which review
// list shows, the faces on their way out after an act, the last act's receipt, and every
// act. An act is one `PeopleAct`, delivered in order on `peopleIntentStream` to
// `CatalogStore.perform(_:)`, the one write path; its undo writes back the record the store
// returned, and its redo performs the act again. Buttons, keys, menus, drags and VoiceOver
// actions all call the intents below.

/// The two review lists (owner decision, 2026-11-10).
nonisolated enum PeopleReviewList: Hashable, Sendable {
    case suggestions
    case unsure
}

/// What the last act did, as the review's bar states it.
nonisolated struct PeopleReceipt: Equatable, Sendable {
    let text: String
    /// The undo stack's name for the act, so Undo is offered only while it is the window's
    /// last change.
    let undoName: String
}

/// Rename… or Set Birthday…, open on one person.
nonisolated struct PersonSheetRequest: Equatable, Sendable, Identifiable {
    let person: PersonID
    var id: PersonID {
        person
    }
}

/// The question a drag of one person onto another asks first (owner decision, 2026-11-10).
nonisolated struct PeopleMergeQuestion: Equatable, Sendable {
    let from: PersonID
    let into: PersonID
}

/// People window state.
struct PeopleSession: Equatable {
    /// The People list's selection: people and unnamed groups are one selection.
    var selectedItems: Set<PeopleListItem> = []
    var listCursor: PeopleListItem?
    var list: PeopleReviewList = .suggestions
    var selectedFaces: Set<FaceID> = []
    var faceCursor: FaceID?
    /// Faces an act took out of the review, hidden until a People state shows the act — its
    /// `revision` is at least the act's — or the act fails.
    var leaving: [FaceID: PeopleLeavingMark] = [:]
    /// Numbers the acts this window submits, so a store answer finds the faces it hid.
    var lastSubmittedAct: UInt64 = 0
    var receipt: PeopleReceipt?
    var sheet: PersonSheetRequest?
    /// The faces the name popover names, while it is open.
    var naming: [FaceID]?
    var mergeQuestion: PeopleMergeQuestion?
    /// Review rows showing all their faces (`Show All N Faces`), while the review is open.
    var expandedRows: Set<PeopleReviewRowKey> = []
    /// The shown review list with `leaving` taken out; rebuilt by `refreshPeopleLayout`.
    var layout = PeopleReviewLayout(years: [], leaving: [], expanded: [])

    /// The people selected on the People list.
    var selectedPeople: Set<PersonID> {
        Set(selectedItems.compactMap { item in
            if case let .person(person) = item {
                person
            } else {
                nil
            }
        })
    }

    /// The unnamed groups selected on the People list.
    var selectedUnnamedGroups: Set<FaceID> {
        Set(selectedItems.compactMap { item in
            if case let .unnamed(group) = item {
                group
            } else {
                nil
            }
        })
    }

    /// Records the store's answer for `act`: its faces stay hidden until a People state at
    /// `revision` or later arrives.
    mutating func actCommitted(_ act: UInt64, revision: UInt64) {
        for (face, mark) in leaving where mark.act == act {
            leaving[face] = PeopleLeavingMark(act: act, revision: revision)
        }
    }

    /// The store refused `act`: its faces come back.
    mutating func actFailed(_ act: UInt64) {
        leaving = leaving.filter { $0.value.act != act }
    }

    /// A People state at `revision` shows every act committed at or before it: those faces
    /// are the state's to show or not.
    mutating func shown(upTo revision: UInt64) {
        leaving = leaving.filter { mark in mark.value.revision.map { $0 > revision } ?? true }
    }
}

/// Why a face is hidden from the review: the window's act that took it out, and the People
/// revision that act committed as, once the store has answered.
nonisolated struct PeopleLeavingMark: Equatable, Sendable {
    let act: UInt64
    let revision: UInt64?
}

/// A People act on its way to the store, or the undo of one. `act` numbers the act, whose
/// faces the window may have hid (`PeopleSession.leaving`); a redo is the act again.
nonisolated enum PeopleIntent: Sendable {
    case perform(PeopleAct, receipt: PeopleReceipt?, act: UInt64)
    case restore(PeopleRestore, act: PeopleAct)
}

/// Lookups over one People state: who is confirmed where, and which acts the hard rules
/// allow (ADR 0047). Pure, rebuilt when the state changes.
nonisolated struct PeopleIndex {
    let state: CatalogPeopleState
    let summaries: [PersonID: PersonSummary]
    /// For each photo, the face confirmed as each person in it.
    let confirmedInPhoto: [MediaAssetID: [PersonID: FaceID]]
    /// Every face the review shows, by id.
    let reviewTiles: [FaceID: FaceTile]
    /// Every face People shows, reviewed or confirmed, with its photo's capture instant.
    let captures: [FaceID: Double?]

    init(_ state: CatalogPeopleState) {
        self.state = state
        summaries = Dictionary(uniqueKeysWithValues: state.people.map { ($0.id, $0) })
        var confirmed: [MediaAssetID: [PersonID: FaceID]] = [:]
        for person in state.people {
            for face in person.faces {
                confirmed[face.id.asset, default: [:]][person.id] = face.id
            }
        }
        confirmedInPhoto = confirmed
        var tiles: [FaceID: FaceTile] = [:]
        for year in state.suggestions + state.unsure {
            for row in year.rows {
                for face in row.faces {
                    tiles[face.id] = face
                }
            }
        }
        reviewTiles = tiles
        var captures = tiles.mapValues(\.captureSeconds)
        for person in state.people {
            for face in person.faces {
                captures[face.id] = face.captureSeconds
            }
        }
        self.captures = captures
    }

    func name(_ person: PersonID) -> String {
        summaries[person]?.displayName ?? "Unnamed"
    }

    /// Why `faces` cannot all become `person`'s, or nil when they can.
    func confirmRefusal(_ faces: [FaceID], as person: PersonID) -> String? {
        let photos = faces.map(\.asset)
        if Set(photos).count < photos.count {
            let shared = photos.count - Set(photos).count + 1
            return "\(shared) of these faces are in the same photo"
        }
        for face in faces {
            if let held = confirmedInPhoto[face.asset]?[person], held != face {
                return "\(name(person)) is already in this photo"
            }
        }
        if let birthday = summaries[person]?.birthday.flatMap(PersonBirthday.seconds) {
            let before = faces.count { face in (captures[face] ?? nil).map { $0 < birthday } ?? false }
            if before > 0 {
                return "\(PeopleText.count(before, "face")) \(before == 1 ? "is" : "are") from before \(name(person))'s birthday"
            }
        }
        return nil
    }

    /// The people `faces` may be moved to, in the People list's order: not already
    /// confirmed in one of their photos, and born on or before each of their dates. A face
    /// with no date is offered to everyone.
    func eligiblePeople(for faces: [FaceID], excluding: Set<PersonID>) -> [PersonSummary] {
        state.people.filter { person in
            !excluding.contains(person.id) && confirmRefusal(faces, as: person.id) == nil
        }
    }

    /// Why `from` cannot merge into `into`, or nil when it can.
    func mergeRefusal(_ from: PersonID, into: PersonID) -> String? {
        guard from != into, let source = summaries[from], let target = summaries[into] else {
            return "Choose another person"
        }
        let shared = Set(source.faces.map(\.id.asset)).intersection(target.faces.map(\.id.asset)).count
        if shared > 0 {
            return "\(source.displayName) and \(target.displayName) are both in \(PeopleText.count(shared, "photo"))"
        }
        if let birthday = target.birthday.flatMap(PersonBirthday.seconds) {
            let before = Set(source.faces.filter { ($0.captureSeconds ?? .infinity) < birthday }.map(\.id.asset)).count
            if before > 0 {
                return "\(PeopleText.count(before, "photo")) of \(source.displayName) \(before == 1 ? "is" : "are") from before \(target.displayName)'s birthday"
            }
        }
        return nil
    }

    /// Why the Person sheet cannot save, or nil when it can.
    func sheetRefusal(person: PersonID, name text: String, birthday: String?) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Enter a name"
        }
        if state.people.contains(where: { $0.id != person && $0.name == trimmed }) {
            return "Another person is named \(trimmed). Merge them instead."
        }
        if let birthday {
            guard let seconds = PersonBirthday.seconds(birthday) else {
                return "Enter a year, or a full date"
            }
            let before = Set(summaries[person]?.faces.filter { ($0.captureSeconds ?? .infinity) < seconds }.map(\.id.asset) ?? []).count
            if before > 0 {
                return "\(PeopleText.count(before, "confirmed photo")) of \(name(person)) \(before == 1 ? "is" : "are") from before this date"
            }
        }
        return nil
    }
}

/// One review row in one year: what `Show All N Faces` expands.
nonisolated struct PeopleReviewRowKey: Hashable, Sendable {
    let row: PeopleReviewRow.ID
    let year: Int?
}

/// The review as it is on screen: the shown list's years with the leaving faces taken out,
/// each row showing its first `collapsedFaces` faces unless expanded, and the shown faces in
/// reading order, which the arrow keys walk.
nonisolated struct PeopleReviewLayout: Equatable {
    /// The faces a row shows until `Show All N Faces` (owner decision, 2026-11-11).
    static let collapsedFaces = 12

    let years: [PeopleReviewYear]
    let expanded: Set<PeopleReviewRowKey>
    /// The shown faces in reading order.
    let order: [FaceID]
    /// Each shown face's row and place in it.
    let position: [FaceID: (row: Int, index: Int)]
    let rows: [PeopleReviewRow]
    /// How many faces each of `rows` shows.
    let shownCounts: [Int]
    /// Every face of every row, shown or not.
    let faceCount: Int

    static func == (lhs: PeopleReviewLayout, rhs: PeopleReviewLayout) -> Bool {
        lhs.years == rhs.years && lhs.expanded == rhs.expanded
    }

    init(years source: [PeopleReviewYear], leaving: Set<FaceID>, expanded: Set<PeopleReviewRowKey>) {
        var years: [PeopleReviewYear] = []
        for year in source {
            let rows = year.rows.compactMap { row -> PeopleReviewRow? in
                let faces = row.faces.filter { !leaving.contains($0.id) }
                return faces.isEmpty ? nil : PeopleReviewRow(kind: row.kind, references: row.references, faces: faces)
            }
            if !rows.isEmpty {
                years.append(PeopleReviewYear(year: year.year, rows: rows))
            }
        }
        self.years = years
        self.expanded = expanded
        var rows: [PeopleReviewRow] = []
        var shownCounts: [Int] = []
        for year in years {
            for row in year.rows {
                rows.append(row)
                shownCounts.append(Self.shownCount(row, year: year.year, expanded: expanded))
            }
        }
        self.rows = rows
        self.shownCounts = shownCounts
        faceCount = rows.reduce(0) { $0 + $1.faces.count }
        var order: [FaceID] = []
        var position: [FaceID: (row: Int, index: Int)] = [:]
        for (rowIndex, row) in rows.enumerated() {
            for (index, face) in row.faces.prefix(shownCounts[rowIndex]).enumerated() {
                order.append(face.id)
                position[face.id] = (rowIndex, index)
            }
        }
        self.order = order
        self.position = position
    }

    private static func shownCount(_ row: PeopleReviewRow, year: Int?, expanded: Set<PeopleReviewRowKey>) -> Int {
        expanded.contains(PeopleReviewRowKey(row: row.id, year: year)) ? row.faces.count : min(row.faces.count, collapsedFaces)
    }

    /// The faces `row` of `year` shows.
    func shownFaces(_ row: PeopleReviewRow, year: Int?) -> ArraySlice<FaceTile> {
        row.faces.prefix(Self.shownCount(row, year: year, expanded: expanded))
    }

    func row(of face: FaceID) -> PeopleReviewRow? {
        position[face].map { rows[$0.row] }
    }

    enum Direction {
        case previous, next, up, down
    }

    /// The face an arrow key reaches from `face`: ← / → in reading order across rows and
    /// years, ↑ / ↓ the same place in the row above or below (its last face when shorter).
    func target(from face: FaceID?, _ direction: Direction) -> FaceID? {
        guard let face, let at = position[face] else {
            return order.first
        }
        switch direction {
        case .previous:
            return order.firstIndex(of: face).flatMap { $0 > 0 ? order[$0 - 1] : nil }
        case .next:
            return order.firstIndex(of: face).flatMap { $0 + 1 < order.count ? order[$0 + 1] : nil }
        case .up, .down:
            let row = at.row + (direction == .up ? -1 : 1)
            guard rows.indices.contains(row) else { return nil }
            return rows[row].faces[min(at.index, shownCounts[row] - 1)].id
        }
    }

    /// The face after the last of `acted` in reading order that is not one of them; else the
    /// one before the first. Where the selection goes after an act.
    func successor(of acted: Set<FaceID>) -> FaceID? {
        guard let last = order.lastIndex(where: acted.contains) else { return nil }
        if let after = order[(last + 1)...].first(where: { !acted.contains($0) }) {
            return after
        }
        return order[..<last].last { !acted.contains($0) }
    }
}

/// People's counted strings.
nonisolated enum PeopleText {
    static func count(_ value: Int, _ noun: String) -> String {
        "\(value.formatted()) \(value == 1 ? noun : noun + "s")"
    }
}

extension CatalogWindowViewModel {
    // MARK: - Surfaces

    /// Whether the detail pane is the People list. Read from the published scope, for the
    /// reason `showsPlacesMap` gives.
    var showsPeopleList: Bool {
        state.resolvedSidebarSelection == .people
    }

    var showsPeopleReview: Bool {
        state.resolvedSidebarSelection == .peopleReview
    }

    /// The row exists whenever one fixed library does, like Places.
    var showsPeopleRow: Bool {
        showsPlacesRow
    }

    /// The person whose photos the browser shows, if it shows one person's.
    var shownPerson: PersonSummary? {
        if case let .person(person) = sidebarSelection {
            return peopleIndex.summaries[person]
        }
        return nil
    }

    var showsPersonLeaf: Bool {
        if case .person = sidebarSelection {
            return true
        }
        return false
    }

    var showsReviewPhotosLeaf: Bool {
        if case .reviewPhotos = sidebarSelection {
            return true
        }
        return false
    }

    /// The window's title: a person's name in their scope, else the published title.
    var windowTitle: String {
        shownPerson?.displayName ?? state.title
    }

    /// The published empty state, with the person named where it is a person's.
    var mediaEmptyState: CatalogMediaEmptyState {
        if case .noPersonPhotos = state.mediaEmptyState {
            return .noPersonPhotos(shownPerson?.displayName)
        }
        return state.mediaEmptyState
    }

    /// The review as it is on screen now.
    var peopleReviewLayout: PeopleReviewLayout {
        peopleSession.layout
    }

    /// Rebuilds the layout after the People state, the shown list or the leaving faces change.
    func refreshPeopleLayout() {
        let people = state.people ?? .empty
        let layout = PeopleReviewLayout(
            years: peopleSession.list == .suggestions ? people.suggestions : people.unsure,
            leaving: Set(peopleSession.leaving.keys),
            expanded: peopleSession.expandedRows
        )
        if layout != peopleSession.layout {
            peopleSession.layout = layout
        }
    }

    // MARK: - State

    /// A new People state takes in every act it shows: the faces those acts hid are its to
    /// show now, and selections of people or faces that are gone are forgotten.
    func applyPeopleState(previous: CatalogWindowState, next: CatalogWindowState) {
        guard let people = next.people, people != previous.people else {
            if next.resolvedSidebarSelection.sidebarRow != .people, peopleSession.receipt != nil {
                peopleSession.receipt = nil
            }
            return
        }
        peopleIndex = PeopleIndex(people)
        // A state read before an act committed does not show it, whenever it arrives: the
        // faces that act hid stay hidden until a state at its revision or later.
        peopleSession.shown(upTo: people.revision)
        peopleSession.selectedItems = peopleSession.selectedItems.filter { item in
            switch item {
            case let .person(person): peopleIndex.summaries[person] != nil
            case let .unnamed(group): people.unnamedGroup(group) != nil
            }
        }
        peopleSession.selectedFaces = peopleSession.selectedFaces.filter { peopleIndex.reviewTiles[$0] != nil }
        if let sheet = peopleSession.sheet, peopleIndex.summaries[sheet.person] == nil {
            peopleSession.sheet = nil
        }
        refreshPeopleLayout()
        OtosLog.ui.noticeOperation("people.state", phase: "applied", fields: [
            "people": "\(people.people.count)",
            "suggestions": "\(people.suggestionCount)",
            "unsure": "\(people.unsureCount)",
            "unchecked": "\(people.uncheckedPhotoCount)",
        ])
    }

    // MARK: - Navigation

    /// Opens a person's photos in the ordinary browser.
    func openPerson(_ person: PersonID) {
        guard peopleIndex.summaries[person] != nil else { return }
        OtosLog.ui.noticeOperation("people.person", phase: "open", fields: ["person": "\(person.rawValue)"])
        setViewMode(.grid)
        selectSidebar(.person(person))
    }

    /// Return or a double-click on the People list: a person's photos, or the review with an
    /// unnamed group's faces selected.
    func openPeopleListItem(_ item: PeopleListItem) {
        switch item {
        case let .person(person): openPerson(person)
        case let .unnamed(group): openUnnamedGroup(group)
        }
    }

    /// The review, on Suggestions, with every face of `group` selected and the first shown.
    func openUnnamedGroup(_ group: FaceID) {
        guard state.people?.unnamedGroup(group) != nil else { return }
        openReview()
        setReviewList(.suggestions)
        let rows = peopleReviewLayout.rows.filter { $0.id == .unnamed(group) }
        peopleSession.selectedFaces = Set(rows.flatMap { $0.faces.map(\.id) })
        peopleSession.faceCursor = rows.first?.faces.first?.id
    }

    /// Back to People from a person or the review. Rows expanded in the review close.
    func returnToPeople() {
        peopleSession.expandedRows = []
        refreshPeopleLayout()
        setViewMode(.grid)
        selectSidebar(.people)
    }

    func openReview() {
        OtosLog.ui.noticeOperation("people.review", phase: "open", fields: [
            "suggestions": "\(state.people?.suggestionCount ?? 0)", "unsure": "\(state.people?.unsureCount ?? 0)",
        ])
        setViewMode(.grid)
        selectSidebar(.peopleReview)
    }

    /// Back to Review from a row's photos.
    func returnToReview() {
        setViewMode(.grid)
        selectSidebar(.peopleReview)
    }

    var canReviewSuggestions: Bool {
        guard let people = state.people else { return false }
        return people.suggestionCount + people.unsureCount > 0
    }

    func setReviewList(_ list: PeopleReviewList) {
        guard peopleSession.list != list else { return }
        peopleSession.list = list
        peopleSession.expandedRows = []
        peopleSession.selectedFaces = []
        peopleSession.faceCursor = nil
        refreshPeopleLayout()
    }

    /// Space or a double-click on a face: its photo in Loupe, the row's photos as the
    /// filmstrip.
    func openReviewPhoto(_ face: FaceID) {
        guard let row = peopleReviewLayout.row(of: face) else { return }
        var seen: Set<MediaAssetID> = []
        let photos = row.faces.map(\.id.asset).filter { seen.insert($0).inserted }
        OtosLog.ui.noticeOperation("people.review", phase: "openPhoto", fields: ["photos": "\(photos.count)"])
        openScope(.reviewPhotos(photos), selecting: [face.asset])
        setViewMode(.loupe)
    }

    // MARK: - Selection

    /// The unnamed groups the People list shows: those with a face not on its way out.
    var shownUnnamedGroups: [UnnamedGroupSummary] {
        let leaving = peopleSession.leaving
        return (state.people?.unnamed ?? []).filter { group in group.faces.contains { leaving[$0.id] == nil } }
    }

    /// The People list's cells in order, as shown.
    var peopleListOrder: [PeopleListItem] {
        (state.people?.people ?? []).map { .person($0.id) } + shownUnnamedGroups.map { .unnamed($0.id) }
    }

    func selectPeople(_ hit: PeopleListItem?, modifiers: NSEvent.ModifierFlags) {
        guard let hit else {
            peopleSession.selectedItems = []
            peopleSession.listCursor = nil
            return
        }
        peopleSession.selectedItems = Self.extend(
            peopleSession.selectedItems, cursor: peopleSession.listCursor, hit: hit, modifiers: modifiers, order: peopleListOrder
        )
        peopleSession.listCursor = hit
    }

    /// ← → ↑ ↓ on the People list: `step` cells along its order.
    func moveListCursor(by step: Int, extending: Bool) -> PeopleListItem? {
        let order = peopleListOrder
        let from = peopleSession.listCursor.flatMap(order.firstIndex(of:))
        let target = from.map { $0 + step } ?? 0
        guard order.indices.contains(target) else { return nil }
        selectPeople(order[target], modifiers: extending ? .shift : [])
        return order[target]
    }

    func selectReviewFaces(_ hit: FaceID?, modifiers: NSEvent.ModifierFlags) {
        guard let hit else {
            peopleSession.selectedFaces = []
            peopleSession.faceCursor = nil
            return
        }
        peopleSession.selectedFaces = Self.extend(
            peopleSession.selectedFaces, cursor: peopleSession.faceCursor, hit: hit, modifiers: modifiers,
            order: peopleReviewLayout.order
        )
        peopleSession.faceCursor = hit
    }

    /// `Show All N Faces` and `Show Fewer` on a row of a year.
    func setReviewRowExpanded(_ key: PeopleReviewRowKey, _ expanded: Bool) {
        if expanded {
            peopleSession.expandedRows.insert(key)
        } else {
            peopleSession.expandedRows.remove(key)
        }
        refreshPeopleLayout()
        // A cursor on a face the row no longer shows is forgotten; the selection is kept.
        if !expanded, let cursor = peopleSession.faceCursor, !peopleReviewLayout.order.contains(cursor) {
            peopleSession.faceCursor = nil
        }
    }

    /// A click on a row's header selects its faces.
    func selectReviewRow(_ row: PeopleReviewRow) {
        peopleSession.selectedFaces = Set(row.faces.map(\.id))
        peopleSession.faceCursor = row.faces.first?.id
    }

    func selectAllReviewFaces() {
        peopleSession.selectedFaces = Set(peopleReviewLayout.order)
    }

    func moveReviewCursor(_ direction: PeopleReviewLayout.Direction, extending: Bool) {
        guard let target = peopleReviewLayout.target(from: peopleSession.faceCursor, direction) else { return }
        selectReviewFaces(target, modifiers: extending ? .shift : [])
    }

    /// Click, ⌘-click and ⇧-click, as the grid selects (APP-011).
    private static func extend<ID: Hashable>(
        _ selection: Set<ID>, cursor: ID?, hit: ID, modifiers: NSEvent.ModifierFlags, order: [ID]
    ) -> Set<ID> {
        if modifiers.contains(.command) {
            var next = selection
            if next.remove(hit) == nil {
                next.insert(hit)
            }
            return next
        }
        if modifiers.contains(.shift), let cursor, let from = order.firstIndex(of: cursor), let to = order.firstIndex(of: hit) {
            return selection.union(order[min(from, to) ... max(from, to)])
        }
        return [hit]
    }

    /// The selected faces in reading order.
    var selectedReviewFaces: [FaceID] {
        peopleReviewLayout.order.filter(peopleSession.selectedFaces.contains)
    }

    // MARK: - Review acts

    /// The person the selection would be confirmed as: every selected face in Suggestions
    /// suggested as one person.
    var confirmTarget: PersonID? {
        let faces = selectedReviewFaces
        guard peopleSession.list == .suggestions, !faces.isEmpty else { return nil }
        let people = Set(faces.compactMap { face -> PersonID? in
            if case let .person(person, _) = peopleReviewLayout.row(of: face)?.kind {
                return person
            }
            return nil
        })
        guard people.count == 1, faces.allSatisfy({ face in
            if case .person = peopleReviewLayout.row(of: face)?.kind {
                return true
            }
            return false
        }) else { return nil }
        return people.first
    }

    /// Why Confirm is disabled, when a hard rule disables it.
    var confirmRefusal: String? {
        guard let person = confirmTarget else { return nil }
        return peopleIndex.confirmRefusal(selectedReviewFaces, as: person)
    }

    var canConfirmReviewFaces: Bool {
        confirmTarget != nil && confirmRefusal == nil
    }

    /// Return and the bar's Confirm.
    func confirmSelectedReviewFaces() {
        guard let person = confirmTarget, confirmRefusal == nil else { return }
        confirm(selectedReviewFaces, as: person, verb: .confirm)
    }

    /// A row's Confirm All.
    func confirmReviewRow(_ row: PeopleReviewRow) {
        guard case let .person(person, _) = row.kind else { return }
        let faces = row.faces.map(\.id)
        guard peopleIndex.confirmRefusal(faces, as: person) == nil else { return }
        confirm(faces, as: person, verb: .confirm)
    }

    /// Unsure's ⌘[ and ⌘]: the selected faces as their row's first or second candidate.
    func confirmUnsureCandidate(_ which: Int) {
        let faces = selectedReviewFaces
        guard peopleSession.list == .unsure, let first = faces.first,
              case let .unsure(a, b) = peopleReviewLayout.row(of: first)?.kind,
              faces.allSatisfy({ peopleReviewLayout.row(of: $0)?.kind == .unsure(a, b) })
        else { return }
        let person = which == 0 ? a : b
        guard peopleIndex.confirmRefusal(faces, as: person) == nil else { return }
        confirm(faces, as: person, verb: .confirm)
    }

    enum ConfirmVerb {
        case confirm, move
    }

    /// This Is ▸ a person, from the review or a person's scope.
    func moveFaces(_ faces: [FaceID], to person: PersonID) {
        confirm(faces, as: person, verb: .move)
    }

    /// The person dropping `faces` onto a person's row in `year` moves them to, or nil when
    /// that drop is refused (`docs/design/people.md`, sibling fix): the faces are on other
    /// rows of the same year, and This Is ▸ offers that person for all of them.
    func reviewDropTarget(_ faces: [FaceID], onto row: PeopleReviewRow, year: Int?) -> PersonID? {
        guard case let .person(person, _) = row.kind, !faces.isEmpty,
              let shownYear = peopleReviewLayout.years.first(where: { $0.year == year })
        else { return nil }
        let inYear = Set(shownYear.rows.flatMap { $0.faces.map(\.id) })
        let onRow = Set(row.faces.map(\.id))
        guard faces.allSatisfy({ inYear.contains($0) && !onRow.contains($0) }),
              thisIsChoices(for: faces, excluding: []).contains(where: { $0.id == person })
        else { return nil }
        return person
    }

    /// Faces dropped onto a person's row: This Is ▸ that person.
    func dropReviewFaces(_ faces: [FaceID], onto row: PeopleReviewRow, year: Int?) -> Bool {
        guard let person = reviewDropTarget(faces, onto: row, year: year) else { return false }
        moveFaces(faces, to: person)
        return true
    }

    private func confirm(_ faces: [FaceID], as person: PersonID, verb: ConfirmVerb) {
        let text = switch verb {
        case .confirm: "Confirmed \(PeopleText.count(faces.count, "face")) as \(peopleIndex.name(person))"
        case .move: "Moved \(PeopleText.count(faces.count, "face")) to \(peopleIndex.name(person))"
        }
        let act = PeopleAct.confirm(faces, as: person)
        submitPeopleAct(act, receipt: PeopleReceipt(text: text, undoName: verb == .move ? "Move to \(peopleIndex.name(person))" : act.undoName))
    }

    /// The person Delete rejects on the selection, when one person names every selected face's
    /// row (Suggestions), or the pair on an unsure row.
    var rejectTarget: [PersonID]? {
        let faces = selectedReviewFaces
        guard let first = faces.first, let kind = peopleReviewLayout.row(of: first)?.kind,
              faces.allSatisfy({ peopleReviewLayout.row(of: $0)?.kind == kind })
        else { return nil }
        switch kind {
        case let .person(person, _): return [person]
        case let .unsure(a, b): return [a, b]
        case .unnamed: return nil
        }
    }

    /// Delete: `Not Sam`, or `Not Sam or Ian` on an unsure row.
    func rejectSelectedReviewFaces() {
        guard let people = rejectTarget else { return }
        let faces = selectedReviewFaces
        let names = people.map(peopleIndex.name).joined(separator: " or ")
        let text = "\(PeopleText.count(faces.count, "face")) \(faces.count == 1 ? "is" : "are") not \(names)"
        let act: PeopleAct = people.count == 1 ? .reject(faces, person: people[0]) : .rejectAll(faces, people: people)
        submitPeopleAct(act, receipt: PeopleReceipt(text: text, undoName: "Not \(names)"))
    }

    /// Not a Face, on the review's selection.
    func markSelectedReviewFacesNotFaces() {
        markNotFaces(selectedReviewFaces)
    }

    func markNotFaces(_ faces: [FaceID]) {
        guard !faces.isEmpty else { return }
        let text = "Marked \(PeopleText.count(faces.count, "detection")) as not a face"
        submitPeopleAct(.notAFace(faces), receipt: PeopleReceipt(text: text, undoName: PeopleAct.notAFace([]).undoName))
    }

    /// An unnamed row's Ignore.
    func ignoreReviewRow(_ row: PeopleReviewRow) {
        ignoreFaces(row.faces.map(\.id))
    }

    /// Ignore on the People list: the unnamed group, or every selected one when it is selected.
    func ignoreUnnamedGroups(from group: FaceID) {
        ignoreFaces(unnamedTargets(from: group).flatMap { $0.faces.map(\.id) })
    }

    /// Add Name… on an unnamed cell: its group's faces, or every selected group's when it is
    /// selected.
    func beginNamingUnnamedGroups(from group: FaceID) {
        beginNaming(unnamedTargets(from: group).flatMap { $0.faces.map(\.id) })
    }

    /// ⇧O on the People list: the selected unnamed groups.
    func beginNamingSelectedUnnamedGroups() {
        let groups = shownUnnamedGroups.filter { peopleSession.selectedUnnamedGroups.contains($0.id) }
        beginNaming(groups.flatMap { $0.faces.map(\.id) })
    }

    /// The groups an act from `group`'s cell applies to: the selected ones when it is
    /// selected, else `group`.
    private func unnamedTargets(from group: FaceID) -> [UnnamedGroupSummary] {
        let selected = peopleSession.selectedUnnamedGroups
        let ids = selected.contains(group) ? selected : [group]
        return shownUnnamedGroups.filter { ids.contains($0.id) }
    }

    private func ignoreFaces(_ faces: [FaceID]) {
        guard !faces.isEmpty else { return }
        let text = "Ignored \(PeopleText.count(faces.count, "face"))"
        submitPeopleAct(.ignore(faces), receipt: PeopleReceipt(text: text, undoName: PeopleAct.ignore([]).undoName))
    }

    /// The people This Is ▸ offers for `faces`: the row's candidates first (the runner-up
    /// for a suggestion, both for an unsure row), then everyone else eligible.
    func thisIsChoices(for faces: [FaceID], excluding: Set<PersonID>) -> [PersonSummary] {
        var preferred: [PersonID] = []
        if let first = faces.first, case let .unsure(a, b) = peopleReviewLayout.row(of: first)?.kind {
            preferred = [a, b]
        }
        let eligible = peopleIndex.eligiblePeople(for: faces, excluding: excluding)
        let first = preferred.compactMap { id in eligible.first { $0.id == id } }
        return first + eligible.filter { !preferred.contains($0.id) }
    }

    /// This Is ▸ New Person: the faces become one new person, whose sheet opens for a name.
    func splitFaces(_ faces: [FaceID]) {
        guard !faces.isEmpty, Set(faces.map(\.asset)).count == faces.count else { return }
        let text = "Moved \(PeopleText.count(faces.count, "face")) to a new person"
        submitPeopleAct(.split(faces), receipt: PeopleReceipt(text: text, undoName: PeopleAct.split([]).undoName))
    }

    /// ⇧O, Name… and an unnamed row's Add Name…: opens the popover for `faces`.
    func beginNaming(_ faces: [FaceID]) {
        guard !faces.isEmpty else { return }
        peopleSession.naming = faces
    }

    func beginNamingSelectedReviewFaces() {
        beginNaming(selectedReviewFaces)
    }

    func cancelNaming() {
        peopleSession.naming = nil
    }

    /// The names the popover completes `text` with: eligible people whose name starts with it.
    func nameCompletions(_ text: String) -> [String] {
        guard let faces = peopleSession.naming else { return [] }
        let prefix = text.trimmingCharacters(in: .whitespaces)
        return thisIsChoices(for: faces, excluding: []).compactMap(\.name).filter {
            prefix.isEmpty || $0.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
        }
    }

    /// Why the popover's name cannot be given to its faces, or nil when it can.
    func namingRefusal(_ text: String) -> String? {
        guard let faces = peopleSession.naming else { return nil }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return "Enter a name"
        }
        if let person = state.people?.people.first(where: { $0.name == name }) {
            return peopleIndex.confirmRefusal(faces, as: person.id)
        }
        if Set(faces.map(\.asset)).count < faces.count {
            return "\(faces.count - Set(faces.map(\.asset)).count + 1) of these faces are in the same photo"
        }
        return nil
    }

    /// Return in the popover: an existing name gives the faces to that person, a new one
    /// creates them.
    func commitNaming(_ text: String) {
        guard let faces = peopleSession.naming, namingRefusal(text) == nil else { return }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        peopleSession.naming = nil
        let text = "Named \(PeopleText.count(faces.count, "face")) \(name)"
        submitPeopleAct(.name(faces, name), receipt: PeopleReceipt(text: text, undoName: PeopleAct.name([], "").undoName))
    }

    // MARK: - People list acts

    func beginEditingPerson(_ person: PersonID) {
        guard peopleIndex.summaries[person] != nil else { return }
        peopleSession.sheet = PersonSheetRequest(person: person)
    }

    func cancelEditingPerson() {
        peopleSession.sheet = nil
    }

    func personSheetRefusal(_ person: PersonID, name: String, birthday: String?) -> String? {
        peopleIndex.sheetRefusal(person: person, name: name, birthday: birthday)
    }

    /// The sheet's Save.
    func savePerson(_ person: PersonID, name: String, birthday: String?) {
        guard let summary = peopleIndex.summaries[person], personSheetRefusal(person, name: name, birthday: birthday) == nil else {
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        peopleSession.sheet = nil
        guard trimmed != summary.name || birthday != summary.birthday else { return }
        let undoName = trimmed == summary.name ? "Set Birthday" : (birthday == summary.birthday ? "Rename" : "Edit Person")
        submitPeopleAct(.edit(person, name: trimmed, birthday: birthday), receipt: PeopleReceipt(text: "", undoName: undoName))
    }

    /// A drop of one person on another, and Merge Into ▸: asks first.
    func askMerge(_ from: PersonID, into: PersonID) {
        guard peopleIndex.mergeRefusal(from, into: into) == nil else { return }
        peopleSession.mergeQuestion = PeopleMergeQuestion(from: from, into: into)
    }

    func mergeRefusal(_ from: PersonID, into: PersonID) -> String? {
        peopleIndex.mergeRefusal(from, into: into)
    }

    func answerMerge(_ merge: Bool) {
        guard let question = peopleSession.mergeQuestion else { return }
        peopleSession.mergeQuestion = nil
        guard merge, peopleIndex.mergeRefusal(question.from, into: question.into) == nil else { return }
        let from = peopleIndex.name(question.from)
        let into = peopleIndex.name(question.into)
        if case .person(question.from) = sidebarSelection {
            returnToPeople()
        }
        peopleSession.selectedItems = [.person(question.into)]
        peopleSession.listCursor = .person(question.into)
        submitPeopleAct(.merge(question.from, into: question.into), receipt: PeopleReceipt(
            text: "Merged \(from) into \(into)", undoName: PeopleAct.merge(question.from, into: question.into).undoName
        ))
    }

    /// Remove Person: undoable; their faces return to the review as unnamed.
    func removePerson(_ person: PersonID) {
        guard peopleIndex.summaries[person] != nil else { return }
        if case .person(person) = sidebarSelection {
            returnToPeople()
        }
        peopleSession.selectedItems.remove(.person(person))
        submitPeopleAct(.remove(person), receipt: PeopleReceipt(
            text: "Removed \(peopleIndex.name(person))", undoName: PeopleAct.remove(person).undoName
        ))
    }

    // MARK: - A person's scope

    /// The faces of the shown person in the selected photos: each photo holds at most one.
    var shownPersonSelectedFaces: [FaceID] {
        guard let person = shownPerson?.id else { return [] }
        return orderedSelectedAssetIDs.compactMap { peopleIndex.confirmedInPhoto[$0]?[person] }
    }

    /// The context menu's corrections in a person's scope; nil elsewhere.
    func personCorrectionsMenu() -> PersonCorrectionsMenu? {
        guard let person = shownPerson else { return nil }
        let faces = shownPersonSelectedFaces
        return PersonCorrectionsMenu(
            name: person.displayName,
            choices: thisIsChoices(for: faces, excluding: [person.id]).map { .init(person: $0.id, title: $0.displayName) },
            enabled: !faces.isEmpty
        )
    }

    /// Not Sam, on the selected photos of Sam: the faces return to the review as
    /// unnamed and are never suggested as her again.
    func rejectShownPersonFaces() {
        guard let person = shownPerson?.id else { return }
        let faces = shownPersonSelectedFaces
        guard !faces.isEmpty else { return }
        let text = "\(PeopleText.count(faces.count, "face")) \(faces.count == 1 ? "is" : "are") not \(peopleIndex.name(person))"
        submitPeopleAct(.reject(faces, person: person), receipt: PeopleReceipt(text: text, undoName: "Not \(peopleIndex.name(person))"))
    }

    // MARK: - Delivery

    /// Hands an act to the one consumer. Its faces leave the review at once and the
    /// selection moves on; the receipt is written once the store has done it.
    private func submitPeopleAct(_ act: PeopleAct, receipt: PeopleReceipt?) {
        let faces: [FaceID] = switch act {
        case let .confirm(faces, _), let .reject(faces, _), let .rejectAll(faces, _), let .notAFace(faces),
             let .ignore(faces), let .name(faces, _), let .split(faces):
            faces
        case .edit, .merge, .remove:
            []
        }
        let acted = Set(faces)
        peopleSession.lastSubmittedAct &+= 1
        let number = peopleSession.lastSubmittedAct
        if showsPeopleReview, !acted.isEmpty {
            let next = peopleReviewLayout.successor(of: acted)
            for face in acted {
                peopleSession.leaving[face] = PeopleLeavingMark(act: number, revision: nil)
            }
            peopleSession.selectedFaces = next.map { [$0] } ?? []
            peopleSession.faceCursor = next
            refreshPeopleLayout()
        } else if showsPeopleList, !acted.isEmpty {
            // An unnamed group named or ignored from the list leaves it at once.
            for face in acted {
                peopleSession.leaving[face] = PeopleLeavingMark(act: number, revision: nil)
            }
            let gone = Set(shownUnnamedGroups.map(\.id))
            peopleSession.selectedItems = peopleSession.selectedItems.filter { item in
                if case let .unnamed(group) = item {
                    gone.contains(group)
                } else {
                    true
                }
            }
            if case let .unnamed(group)? = peopleSession.listCursor, !gone.contains(group) {
                peopleSession.listCursor = nil
            }
            refreshPeopleLayout()
        }
        OtosLog.ui.noticeOperation("people.act", phase: "submit", fields: [
            "act": act.undoName, "faces": "\(act.faceCount)",
        ])
        submitPeopleIntent(.perform(act, receipt: receipt, act: number))
    }

    private func submitPeopleIntent(_ intent: PeopleIntent) {
        switch peopleIntentContinuation.yield(intent) {
        case .enqueued:
            return
        case .dropped, .terminated:
            OtosLog.ui.error("op=people.intent phase=dropped")
        @unknown default:
            OtosLog.ui.error("op=people.intent phase=unknownYield")
        }
    }

    /// The one consumer of People acts and their undo, in submission order. Holds the view
    /// model weakly across each wait and ends with the stream.
    func startPeopleIntentConsumer() {
        guard peopleIntentTask == nil else { return }
        let intents = peopleIntentStream
        let store = catalogStore
        peopleIntentTask = Task { [weak self, store] in
            for await intent in intents {
                switch intent {
                case let .perform(act, receipt, number):
                    do {
                        let outcome = try await store.perform(act)
                        self?.peopleSession.actCommitted(number, revision: outcome.revision)
                        self?.didPerformPeopleAct(act, outcome: outcome, receipt: receipt)
                    } catch {
                        OtosLog.ui.errorOperation("people.act", phase: "failed", fields: [
                            "act": act.undoName, "faces": "\(act.faceCount)", "error": String(describing: error),
                        ])
                        self?.peopleSession.actFailed(number)
                        self?.refreshPeopleLayout()
                    }
                case let .restore(record, act):
                    do {
                        try await store.restore(record)
                        OtosLog.ui.noticeOperation("people.act", phase: "undone", fields: ["act": act.undoName])
                        self?.revealRestoredPerson(of: act, restore: record)
                    } catch {
                        OtosLog.ui.errorOperation("people.act", phase: "undoFailed", fields: [
                            "act": act.undoName, "error": String(describing: error),
                        ])
                    }
                }
                if self == nil {
                    return
                }
            }
        }
    }

    /// Registers the act's undo, writes its receipt, and opens the sheet for a person a split
    /// made, so they are named now or later.
    private func didPerformPeopleAct(_ act: PeopleAct, outcome: PeopleActOutcome, receipt: PeopleReceipt?) {
        let undoName = receipt?.undoName ?? act.undoName
        windowUndoManager.beginUndoGrouping()
        windowUndoManager.registerUndo(withTarget: self) { model in
            model.undoPeopleAct(act, restore: outcome.restore, receipt: receipt)
        }
        windowUndoManager.setActionName(undoName)
        windowUndoManager.endUndoGrouping()
        publishUndoState()
        if let receipt, !receipt.text.isEmpty {
            peopleSession.receipt = receipt
        }
        if case .split = act, let person = outcome.person {
            peopleSession.sheet = PersonSheetRequest(person: person)
        }
    }

    /// Runs inside `UndoManager.undo()`: files the redo synchronously — the act again — then
    /// writes back what the act changed.
    private func undoPeopleAct(_ act: PeopleAct, restore: PeopleRestore, receipt: PeopleReceipt?) {
        windowUndoManager.registerUndo(withTarget: self) { model in
            model.submitPeopleAct(act, receipt: receipt)
        }
        windowUndoManager.setActionName(receipt?.undoName ?? act.undoName)
        peopleSession.receipt = nil
        submitPeopleIntent(.restore(restore, act: act))
        let faces = restore.faces.map(\.face)
        for face in faces {
            peopleSession.leaving[face] = nil
        }
        refreshPeopleLayout()
        showUndoneFaces(of: act, restore: restore)
    }

    /// Shows what an undone act on faces changed in the review (HIG Undo,
    /// `docs/design/people.md` Undo): faces that return unnamed are selected there when it
    /// is shown. Faces that return to a person are shown by `revealRestoredPerson`, once the
    /// restore has committed.
    private func showUndoneFaces(of act: PeopleAct, restore: PeopleRestore) {
        guard act.faceCount > 0, !restore.faces.isEmpty, showsPeopleReview,
              restore.faces.contains(where: { $0.person == nil })
        else { return }
        peopleSession.selectedFaces = Set(restore.faces.map(\.face))
        peopleSession.faceCursor = restore.faces.first?.face
    }

    /// Faces an undone act returned to one person are theirs again: their photos are
    /// selected in the person's scope, which opens when the window shows another. Called
    /// once the restore has committed, so the scope's photos are read with them in it. A
    /// person-level act (Merge, Remove Person, Rename) moves no selection: the People list
    /// shows both people as they were.
    private func revealRestoredPerson(of act: PeopleAct, restore: PeopleRestore) {
        guard act.faceCount > 0, !restore.faces.isEmpty else { return }
        let owners = Set(restore.faces.map(\.person))
        guard owners.count == 1, let person = owners.first ?? nil else { return }
        var seen: Set<MediaAssetID> = []
        let photos = restore.faces.map(\.face.asset).filter { seen.insert($0).inserted }
        OtosLog.ui.noticeOperation("people.undo", phase: "revealPerson", fields: ["photos": "\(photos.count)"])
        openScope(.person(person), selecting: photos)
    }

    /// Whether the review's receipt may offer Undo: its act is the window's last change.
    var canUndoPeopleReceipt: Bool {
        guard let receipt = peopleSession.receipt else { return false }
        return undoMenuState.canUndo && undoMenuState.undoTitle == "Undo \(receipt.undoName)"
    }

    // MARK: - What the views get

    var peopleActions: PeopleActions {
        PeopleActions(
            selectItem: { [weak self] item, modifiers in self?.selectPeople(item, modifiers: modifiers) },
            moveCursor: { [weak self] step, extending in self?.moveListCursor(by: step, extending: extending) },
            open: { [weak self] item in self?.openPeopleListItem(item) },
            openReview: { [weak self] in self?.openReview() },
            edit: { [weak self] person in self?.beginEditingPerson(person) },
            askMerge: { [weak self] from, into in self?.askMerge(from, into: into) },
            mergeRefusal: { [weak self] from, into in self?.mergeRefusal(from, into: into) },
            answerMerge: { [weak self] merge in self?.answerMerge(merge) },
            remove: { [weak self] person in self?.removePerson(person) },
            beginNaming: { [weak self] group in self?.beginNamingUnnamedGroups(from: group) },
            beginNamingSelection: { [weak self] in self?.beginNamingSelectedUnnamedGroups() },
            ignore: { [weak self] group in self?.ignoreUnnamedGroups(from: group) },
            naming: namingActions
        )
    }

    var peopleReviewActions: PeopleReviewActions {
        PeopleReviewActions(
            select: { [weak self] face, modifiers in self?.selectReviewFaces(face, modifiers: modifiers) },
            selectRow: { [weak self] row in self?.selectReviewRow(row) },
            selectAll: { [weak self] in self?.selectAllReviewFaces() },
            move: { [weak self] direction, extending in self?.moveReviewCursor(direction, extending: extending) },
            setList: { [weak self] list in self?.setReviewList(list) },
            confirmSelection: { [weak self] in self?.confirmSelectedReviewFaces() },
            confirmRow: { [weak self] row in self?.confirmReviewRow(row) },
            confirmCandidate: { [weak self] which in self?.confirmUnsureCandidate(which) },
            reject: { [weak self] in self?.rejectSelectedReviewFaces() },
            notAFace: { [weak self] faces in self?.markNotFaces(faces) },
            ignoreRow: { [weak self] row in self?.ignoreReviewRow(row) },
            thisIsChoices: { [weak self] faces in self?.thisIsChoices(for: faces, excluding: []) ?? [] },
            moveTo: { [weak self] faces, person in self?.moveFaces(faces, to: person) },
            dropFaces: { [weak self] faces, row, year in self?.dropReviewFaces(faces, onto: row, year: year) ?? false },
            split: { [weak self] faces in self?.splitFaces(faces) },
            beginNaming: { [weak self] faces in self?.beginNaming(faces) },
            naming: namingActions,
            setExpanded: { [weak self] key, expanded in self?.setReviewRowExpanded(key, expanded) },
            openPhoto: { [weak self] face in self?.openReviewPhoto(face) },
            undo: { [weak self] in self?.undoLastChange() }
        )
    }

    /// The name popover's intents, on the list and in the review.
    var namingActions: PeopleNamingActions {
        PeopleNamingActions(
            cancel: { [weak self] in self?.cancelNaming() },
            completions: { [weak self] text in self?.nameCompletions(text) ?? [] },
            refusal: { [weak self] text in self?.namingRefusal(text) },
            commit: { [weak self] text in self?.commitNaming(text) }
        )
    }

    var peopleReviewBarState: PeopleReviewBarState {
        let people = state.people ?? .empty
        let layout = peopleReviewLayout
        return PeopleReviewBarState(
            list: peopleSession.list,
            suggestionCount: peopleSession.list == .suggestions ? layout.faceCount : people.suggestionCount,
            unsureCount: peopleSession.list == .unsure ? layout.faceCount : people.unsureCount,
            shownCount: layout.faceCount,
            uncheckedCount: people.uncheckedPhotoCount,
            receipt: peopleSession.receipt,
            canUndoReceipt: canUndoPeopleReceipt,
            selectedCount: peopleSession.selectedFaces.count,
            canConfirm: canConfirmReviewFaces,
            confirmRefusal: confirmRefusal
        )
    }
}
