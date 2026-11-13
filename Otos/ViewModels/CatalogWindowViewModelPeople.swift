import AppKit
import Foundation
import OSLog

// People intents (ADR 0047, `docs/design/people.md`)
//
// `PeopleAssignment` publishes People on `CatalogWindowState.people` in every scope; this
// file owns what is specific to working with it: the people the user selected in the
// gallery, the sheet and the merge question, a person's photos (the `.person` leaf), the
// faces of the targeted photos with the people each could be, and every act. An act is one
// `PeopleAct`, delivered in order on `peopleIntentStream` to `CatalogStore.perform(_:)`,
// the one write path; its undo writes back the record the store returned, and its redo
// performs the act again. Buttons, keys, menus, drags and VoiceOver actions all call the
// intents below.

/// Add Name…, New Name…, Rename… or Set Birthday… on one person, or Someone Else… for faces.
nonisolated struct PersonSheetRequest: Equatable, Sendable, Identifiable {
    nonisolated enum Subject: Equatable, Sendable {
        case person(PersonID)
        /// `Someone Else…`: the faces go to the person the sheet names, a new one when no
        /// one has the name.
        case faces([FaceID])
    }

    let subject: Subject

    var id: String {
        switch subject {
        case let .person(person): "person:\(person.rawValue)"
        case let .faces(faces): "faces:\(faces.count):\(faces.first.map { "\($0.asset.relativePath.rawValue)#\($0.index)" } ?? "")"
        }
    }

    var person: PersonID? {
        if case let .person(person) = subject {
            return person
        }
        return nil
    }
}

/// What the Person sheet shows: the person's name and birthday as they are (nil when naming
/// faces), its title, the photos Save changes, up to eight of the faces being named, newest
/// first, and the visible people's names it suggests as the user types.
nonisolated struct PersonSheetContext: Equatable, Sendable {
    static let faceCount = 8

    let person: PersonSummary?
    let title: String
    let media: MediaCount
    let faces: [FaceTile]
    let names: [String]
}

/// The question a merge asks first (owner decision, 2026-11-10): a drop of one person on
/// another, Merge Into ▸, or a name another person already has.
nonisolated struct PeopleMergeQuestion: Equatable, Sendable {
    let from: PersonID
    let into: PersonID
}

/// The people the faces of some photos could be, as last ranked for exactly those photos.
nonisolated struct FaceCandidates: Equatable, Sendable {
    let photos: [MediaAssetID]
    let candidates: [FaceID: [FaceCandidate]]

    static let none = FaceCandidates(photos: [], candidates: [:])
}

/// People window state.
struct PeopleSession: Equatable {
    var selectedPeople: Set<PersonID> = []
    var cursor: PersonID?
    var sheet: PersonSheetRequest?
    var mergeQuestion: PeopleMergeQuestion?
}

/// A People act on its way to the store, or the undo of one; a redo is the act again.
nonisolated enum PeopleIntent: Sendable {
    /// `title` is the act's name on the undo stack, decided when the act is submitted, from
    /// the state it changes (`undoTitle(for:)`).
    case perform(PeopleAct, title: String)
    case restore(PeopleRestore, act: PeopleAct)
}

/// Lookups over one People state, and which acts the hard rules allow (ADR 0047). Pure,
/// rebuilt when the state changes. A refusal is the reason the act is disabled (DES-038);
/// the store holds the same rules and refuses what slips past.
nonisolated struct PeopleIndex {
    let state: CatalogPeopleState
    let summaries: [PersonID: PersonSummary]

    init(_ state: CatalogPeopleState) {
        self.state = state
        summaries = Dictionary(uniqueKeysWithValues: state.people.map { ($0.id, $0) })
    }

    func name(_ person: PersonID) -> String {
        PersonSummary.displayName(givenName(person))
    }

    /// The name the user gave the person; nil for a person without one.
    func givenName(_ person: PersonID) -> String? {
        summaries[person]?.name
    }

    /// Why `faces` cannot all be `person`'s, or nil when they can.
    func moveRefusal(_ faces: [PhotoFace], to person: PersonID) -> String? {
        let photos = faces.map(\.id.asset)
        if Set(photos).count < photos.count {
            return "\(photos.count - Set(photos).count + 1) of these faces are in the same photo"
        }
        guard let target = summaries[person] else { return "Choose another person" }
        let anchored = Set(target.userFaces.map(\.id.asset))
        if faces.contains(where: { anchored.contains($0.id.asset) && $0.person != person }) {
            return "\(target.displayName) is already in this photo"
        }
        if let birthday = target.birthday.flatMap(PersonBirthday.seconds) {
            let before = faces.count { ($0.tile.captureSeconds ?? .infinity) < birthday }
            if before > 0 {
                return "\(PeopleText.count(before, "photo")) \(before == 1 ? "is" : "are") from before \(target.displayName)'s birthday"
            }
        }
        return nil
    }

    /// Why `from` cannot merge into `into`, or nil when it can.
    func mergeRefusal(_ from: PersonID, into: PersonID) -> String? {
        guard from != into, let source = summaries[from], let target = summaries[into] else {
            return "Choose another person"
        }
        let shared = Set(source.anchorPhotos).intersection(target.anchorPhotos).count
        if shared > 0 {
            return "\(source.displayName) and \(target.displayName) are both in \(PeopleText.count(shared, "photo"))"
        }
        if let birthday = (target.birthday ?? source.birthday).flatMap(PersonBirthday.seconds) {
            let before = Set((source.userFaces + target.userFaces).filter { ($0.captureSeconds ?? .infinity) < birthday }.map(\.id.asset)).count
            if before > 0 {
                return "\(PeopleText.count(before, "photo")) \(before == 1 ? "is" : "are") from before the birthday"
            }
        }
        return nil
    }

    /// Why the Person sheet cannot save, or nil when it can. A name another person has is
    /// not a refusal: saving it asks to merge them.
    func sheetRefusal(_ subject: PersonSheetRequest.Subject, name text: String, birthday: String?) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Enter a name"
        }
        guard let birthday else { return nil }
        guard let seconds = PersonBirthday.seconds(birthday) else {
            return "Enter a year, or a full date"
        }
        if case let .person(person) = subject {
            let before = Set(summaries[person]?.userFaces.filter { ($0.captureSeconds ?? .infinity) < seconds }.map(\.id.asset) ?? []).count
            if before > 0 {
                return "\(PeopleText.count(before, "photo")) of \(name(person)) \(before == 1 ? "is" : "are") from before this date"
            }
        }
        return nil
    }

    /// The visible person called `name`, other than `excluding`.
    func person(named name: String, excluding: PersonID? = nil) -> PersonID? {
        state.people.first { $0.name == name && $0.id != excluding }?.id
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

    /// Whether the detail pane is the People gallery. Read from the published scope, for the
    /// reason `showsPlacesMap` gives.
    var showsPeopleList: Bool {
        state.resolvedSidebarSelection == .people
    }

    /// The row exists whenever one fixed library does, like Places.
    var showsPeopleRow: Bool {
        showsPlacesRow
    }

    /// The person whose photos the browser shows (the leaf under People), while visible.
    var shownPerson: PersonSummary? {
        queryDescriptor.scope.person.flatMap { person in
            peopleIndex.summaries[person].flatMap { $0.isHidden ? nil : $0 }
        }
    }

    /// `Back to People`, while the browser shows one person's photos. Read from the intent,
    /// like Back to Map, so it exists only in that leaf.
    var showsBackToPeople: Bool {
        queryDescriptor.scope.person != nil
    }

    /// The window's title: the person a person's photos show, else the published title.
    var windowTitle: String {
        shownPerson?.displayName ?? state.title
    }

    /// The published empty state.
    var mediaEmptyState: CatalogMediaEmptyState {
        state.mediaEmptyState
    }

    // MARK: - State

    /// A new People state: selections, the sheet and the filter forget people who are gone
    /// or hidden, and the targets' faces are ranked again.
    func applyPeopleState(previous: CatalogWindowState, next: CatalogWindowState) {
        guard let people = next.people, people != previous.people else { return }
        peopleIndex = PeopleIndex(people)
        peopleSession.selectedPeople = peopleSession.selectedPeople.filter { peopleIndex.summaries[$0] != nil }
        if let person = peopleSession.cursor, peopleIndex.summaries[person] == nil {
            peopleSession.cursor = nil
        }
        if let person = peopleSession.sheet?.person, peopleIndex.summaries[person] == nil {
            peopleSession.sheet = nil
        }
        // A person hidden or merged away takes their photos with them: the window returns to
        // the gallery, where a hidden person is still seen.
        let visible = Set(people.visiblePeople.map(\.id))
        if let person = queryDescriptor.scope.person, !visible.contains(person) {
            returnToPeople()
        }
        // The filter offers only visible people: a hidden or merged one leaves it.
        let filter = queryDescriptor.filter
        if !filter.people.isSubset(of: visible) {
            var kept = filter
            kept.people = filter.people.intersection(visible)
            setMediaFilter(kept)
        }
        refreshFaceCandidates()
        OtosLog.ui.noticeOperation("people.state", phase: "applied", fields: [
            "people": "\(people.people.count)",
            "hidden": "\(people.hiddenPeople.count)",
            "faces": "\(people.faceCount)",
            "unchecked": "\(people.unchecked.total)",
        ])
    }

    // MARK: - Navigation

    /// A person's photos: the leaf under People, every fixed library's photos of them, with
    /// the filter kept, as an area under the map keeps it. A hidden person is seen only in the
    /// gallery, so their photos do not open until they are unhidden.
    func openPerson(_ person: PersonID) {
        guard let summary = peopleIndex.summaries[person], !summary.isHidden else { return }
        OtosLog.ui.noticeOperation("people.person", phase: "open", fields: ["person": "\(person.rawValue)"])
        setViewMode(.grid)
        setQueryDescriptor(CatalogQueryDescriptor(
            scope: .person(person),
            filter: queryDescriptor.filter,
            sort: queryDescriptor.sort,
            search: queryDescriptor.search
        ))
    }

    /// Back to People: the gallery, with the filter kept.
    func returnToPeople() {
        guard showsBackToPeople else { return }
        setViewMode(.grid)
        setQueryDescriptor(CatalogQueryDescriptor(
            scope: .people,
            filter: queryDescriptor.filter,
            sort: queryDescriptor.sort,
            search: queryDescriptor.search
        ))
    }

    // MARK: - Gallery selection

    var galleryOrder: [PersonID] {
        (state.people?.people ?? []).map(\.id)
    }

    func selectPeople(_ hit: PersonID?, modifiers: NSEvent.ModifierFlags) {
        guard let hit else {
            peopleSession.selectedPeople = []
            peopleSession.cursor = nil
            return
        }
        peopleSession.selectedPeople = Self.extend(
            peopleSession.selectedPeople, hit: hit, cursor: peopleSession.cursor, order: galleryOrder, modifiers: modifiers
        )
        peopleSession.cursor = hit
    }

    /// The arrow keys on the gallery: the person `step` places away in its order.
    func moveGalleryCursor(by step: Int, extending: Bool) -> PersonID? {
        let order = galleryOrder
        guard !order.isEmpty else { return nil }
        let index = peopleSession.cursor.flatMap { order.firstIndex(of: $0) }.map { $0 + step } ?? 0
        let target = order[min(max(index, 0), order.count - 1)]
        selectPeople(target, modifiers: extending ? .shift : [])
        return target
    }

    private static func extend(
        _ selection: Set<PersonID>,
        hit: PersonID,
        cursor: PersonID?,
        order: [PersonID],
        modifiers: NSEvent.ModifierFlags
    ) -> Set<PersonID> {
        if modifiers.contains(.command) {
            return selection.symmetricDifference([hit])
        }
        if modifiers.contains(.shift), let cursor, let from = order.firstIndex(of: cursor), let to = order.firstIndex(of: hit) {
            return selection.union(order[min(from, to) ... max(from, to)])
        }
        return [hit]
    }

    // MARK: - Gallery acts

    /// Add Name…, Rename… and Set Birthday….
    func beginEditingPerson(_ person: PersonID) {
        guard peopleIndex.summaries[person] != nil else { return }
        peopleSession.sheet = PersonSheetRequest(subject: .person(person))
    }

    /// What the Person sheet shows for `request`: who is being named and how many photos
    /// Save changes, a row of their faces, and the names it suggests (DES-113).
    func personSheetContext(_ request: PersonSheetRequest) -> PersonSheetContext {
        let names = (state.people?.visiblePeople ?? []).compactMap(\.name)
        switch request.subject {
        case let .person(person):
            let summary = peopleIndex.summaries[person]
            let faces = (state.people?.photoFaces.values.flatMap(\.self) ?? [])
                .filter { $0.person == person }
                .map(\.tile)
                .sorted { ($0.captureSeconds ?? -.infinity) > ($1.captureSeconds ?? -.infinity) }
            return PersonSheetContext(
                person: summary,
                title: summary?.name ?? FaceActTitle.nameThisPerson,
                media: summary?.media ?? MediaCount(tiles: faces),
                faces: Array(faces.prefix(PersonSheetContext.faceCount)),
                names: names.filter { $0 != summary?.name }
            )
        case let .faces(ids):
            let tiles = ids.compactMap(tile(of:))
            return PersonSheetContext(
                person: nil,
                title: ids.count == 1 ? "Name This Face" : "Name These Faces",
                media: MediaCount(tiles: tiles),
                faces: Array(tiles.prefix(PersonSheetContext.faceCount)),
                names: names
            )
        }
    }

    func cancelPersonSheet() {
        peopleSession.sheet = nil
    }

    func personSheetRefusal(_ subject: PersonSheetRequest.Subject, name: String, birthday: String?) -> String? {
        peopleIndex.sheetRefusal(subject, name: name, birthday: birthday)
    }

    /// The sheet's Save. A name another person has asks whether they are the same person;
    /// for `Someone Else…` it gives the faces to that person.
    func savePersonSheet(_ subject: PersonSheetRequest.Subject, name: String, birthday: String?) {
        guard personSheetRefusal(subject, name: name, birthday: birthday) == nil else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        peopleSession.sheet = nil
        switch subject {
        case let .person(person):
            guard let summary = peopleIndex.summaries[person] else { return }
            if let holder = peopleIndex.person(named: trimmed, excluding: person) {
                askMerge(person, into: holder)
                return
            }
            guard trimmed != summary.name || birthday != summary.birthday else { return }
            submitPeopleAct(.edit(person, name: trimmed, birthday: birthday))
        case let .faces(faces):
            if let holder = peopleIndex.person(named: trimmed) {
                submitPeopleAct(.move(faces, to: holder))
            } else {
                submitPeopleAct(.moveToNewPerson(faces, name: trimmed))
            }
        }
    }

    /// A drop of one person on another, Merge Into ▸, or a taken name: asks first.
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
        peopleSession.selectedPeople = [question.into]
        peopleSession.cursor = question.into
        // The person merged away was being shown or filtered: the one they became takes their
        // place, rather than the window leaving them.
        if queryDescriptor.scope.person == question.from {
            setQueryDescriptor(CatalogQueryDescriptor(
                scope: .person(question.into),
                filter: queryDescriptor.filter,
                sort: queryDescriptor.sort,
                search: queryDescriptor.search
            ))
        }
        if queryDescriptor.filter.people.contains(question.from) {
            var filter = queryDescriptor.filter
            filter.people.remove(question.from)
            filter.people.insert(question.into)
            setMediaFilter(filter)
        }
        submitPeopleAct(.merge(question.from, into: question.into))
    }

    func setFavorite(_ person: PersonID, _ favorite: Bool) {
        guard let summary = peopleIndex.summaries[person], summary.isFavorite != favorite else { return }
        submitPeopleAct(.setFavorite(person, favorite))
    }

    /// Hide and Unhide: a hidden person is seen only in the gallery.
    func setHidden(_ person: PersonID, _ hidden: Bool) {
        guard let summary = peopleIndex.summaries[person], summary.isHidden != hidden else { return }
        if hidden, queryDescriptor.filter.people.contains(person) {
            var filter = queryDescriptor.filter
            filter.people.remove(person)
            setMediaFilter(filter)
        }
        submitPeopleAct(.setHidden(person, hidden))
    }

    // MARK: - Faces of the targeted photos

    /// The faces of the targeted photos, with the people each could be once ranked.
    var targetFaces: SelectionFaces {
        let photos = targetIDs(.current)
        var faces = (state.people ?? .empty).selectionFaces(for: photos)
        if faceCandidates.photos == photos {
            faces.candidates = faceCandidates.candidates
        }
        return faces
    }

    /// Asks `PeopleAssignment` which people the targeted photos' faces could be. Called by
    /// every writer of the target (through `refreshPhotoInfo`) and when People changes; a
    /// ranking for photos no longer targeted is dropped.
    func refreshFaceCandidates() {
        faceCandidatesTask?.cancel()
        let photos = targetIDs(.current)
        guard !photos.isEmpty, !(state.people ?? .empty).selectionFaces(for: photos).faces.isEmpty else {
            faceCandidates = .none
            faceCandidatesTask = nil
            return
        }
        let projection = catalogProjection
        faceCandidatesTask = Task { [weak self] in
            let ranked = await projection.faceCandidates(for: photos)
            guard !Task.isCancelled, let self, targetIDs(.current) == photos else { return }
            faceCandidates = FaceCandidates(photos: photos, candidates: ranked)
            faceCandidatesTask = nil
        }
    }

    /// How many people a face list offers before `Someone Else…` or `New Name…` (HIG: about
    /// five items in a submenu).
    static let faceListLength = 5

    /// The people a face list offers for `faces`: the five they most likely are, most likely
    /// first, filled in gallery order. Only visible people with a name, since several unnamed
    /// ones would read alike, and only those `allowed` keeps: the hard rules of the act.
    func likelyPeople(for faces: [PhotoFace], in selection: SelectionFaces, allowed: (PersonID) -> Bool) -> [PersonSummary] {
        let rank = Dictionary(uniqueKeysWithValues: selection.likelyPeople(for: faces).enumerated().map { ($1, $0) })
        return (state.people?.visiblePeople ?? [])
            .filter { $0.name != nil && allowed($0.id) }
            .enumerated()
            .sorted { lhs, rhs in
                (rank[lhs.element.id] ?? Int.max, lhs.offset) < (rank[rhs.element.id] ?? Int.max, rhs.offset)
            }
            .prefix(Self.faceListLength)
            .map(\.element)
    }

    /// `Change to ▸` or `Assign to ▸` a person: on the user's word, the faces are theirs.
    func nameFaces(_ faces: [FaceID], as person: PersonID) {
        guard !faces.isEmpty else { return }
        submitPeopleAct(.move(faces, to: person))
    }

    /// `Someone Else…`: the sheet names the faces, then they are that person's.
    func beginNamingFaces(_ faces: [FaceID]) {
        guard !faces.isEmpty else { return }
        peopleSession.sheet = PersonSheetRequest(subject: .faces(faces))
    }

    /// `This Is Not Sam`, `Not the Same Person`: the faces lose their person, and Otos never
    /// gives them one again.
    func removeNames(_ faces: [FaceID]) {
        guard !faces.isEmpty else { return }
        submitPeopleAct(.removeName(faces))
    }

    func markNotFaces(_ faces: [FaceID]) {
        guard !faces.isEmpty else { return }
        submitPeopleAct(.notAFace(faces))
    }

    func makeKeyPhoto(_ face: FaceID, of person: PersonID) {
        submitPeopleAct(.makeKeyPhoto(face, of: person))
    }

    // MARK: - Delivery

    /// Hands an act to the one consumer.
    private func submitPeopleAct(_ act: PeopleAct, title: String? = nil) {
        let title = title ?? undoTitle(for: act)
        OtosLog.ui.noticeOperation("people.act", phase: "submit", fields: [
            "act": act.logName, "faces": "\(act.faceCount)",
        ])
        submitPeopleIntent(.perform(act, title: title))
    }

    /// The act's name on the undo stack, in the words of the item that made it and the
    /// photos it changes (`docs/design/people.md` Undo). Read before the act, from the state
    /// it changes: the person a face is losing, the photos of a person being named.
    func undoTitle(for act: PeopleAct) -> String {
        switch act {
        case let .move(faces, _), let .moveToNewPerson(faces, _):
            return FaceActTitle.name(MediaCount(tiles: faces.compactMap(tile(of:))))
        case let .removeName(faces):
            let person = faces.first.flatMap { face in
                state.people?.photoFaces[face.asset]?.first { $0.id == face }?.person
            }
            return person.flatMap(peopleIndex.givenName).map(FaceActTitle.notPerson) ?? FaceActTitle.notTheSamePerson
        case .notAFace:
            return FaceActTitle.notAFace
        case let .edit(person, name, _):
            if let summary = peopleIndex.summaries[person], summary.name == nil, name != nil {
                return FaceActTitle.name(summary.media)
            }
            return "Edit Person"
        case .merge:
            return "Merge"
        case let .setHidden(_, hidden):
            return hidden ? "Hide" : "Unhide"
        case let .setFavorite(_, favorite):
            return favorite ? "Add to Favorites" : "Remove from Favorites"
        case let .makeKeyPhoto(_, person):
            return FaceActTitle.makeKeyPhoto(peopleIndex.name(person))
        }
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
                case let .perform(act, title):
                    do {
                        let outcome = try await store.perform(act)
                        self?.didPerformPeopleAct(act, title: title, outcome: outcome)
                    } catch {
                        OtosLog.ui.errorOperation("people.act", phase: "refused", fields: [
                            "act": act.logName, "faces": "\(act.faceCount)", "error": String(describing: error),
                        ])
                    }
                case let .restore(record, act):
                    do {
                        try await store.restore(record)
                        OtosLog.ui.noticeOperation("people.act", phase: "undone", fields: ["act": act.logName])
                    } catch {
                        OtosLog.ui.errorOperation("people.act", phase: "undoFailed", fields: [
                            "act": act.logName, "error": String(describing: error),
                        ])
                    }
                }
                if self == nil {
                    return
                }
            }
        }
    }

    /// Registers the act's undo.
    private func didPerformPeopleAct(_ act: PeopleAct, title: String, outcome: PeopleActOutcome) {
        windowUndoManager.beginUndoGrouping()
        windowUndoManager.registerUndo(withTarget: self) { model in
            model.undoPeopleAct(act, title: title, restore: outcome.restore)
        }
        windowUndoManager.setActionName(title)
        windowUndoManager.endUndoGrouping()
        publishUndoState()
    }

    /// Runs inside `UndoManager.undo()`: files the redo synchronously — the act again — then
    /// writes back what the act changed.
    private func undoPeopleAct(_ act: PeopleAct, title: String, restore: PeopleRestore) {
        windowUndoManager.registerUndo(withTarget: self) { model in
            model.submitPeopleAct(act, title: title)
        }
        windowUndoManager.setActionName(title)
        submitPeopleIntent(.restore(restore, act: act))
    }

    // MARK: - Face outlines

    /// Outlines these faces wherever their photos show, and no others: the Info pane's
    /// pointer over a face, or the highlighted item of a photo's face menu, which is how two
    /// people the menu names alike are told apart (DES-113). Empty clears.
    func outlineFaces(_ faces: [FaceID]) {
        guard outlinedFaces != faces else { return }
        outlinedFaces = faces
        OtosLog.ui.debugOperation("people.faceOutline", phase: faces.isEmpty ? "cleared" : "shown", fields: [
            "faces": "\(faces.count)",
            "photos": "\(Set(faces.map(\.asset)).count)",
            "mode": viewMode.rawValue,
        ])
    }

    /// The outlined faces' boxes, by photo, as fractions of the upright photo from its
    /// top-left corner. Each surface places them on the picture it shows: a grid tile on
    /// its edited thumbnail, the loupe and compare panes through their decode's edit. A
    /// video's faces are never outlined.
    var outlinedFaceBoxes: [MediaAssetID: [CGRect]] {
        var boxes: [MediaAssetID: [CGRect]] = [:]
        for face in outlinedFaces {
            // A video's face box belongs to the frame it was read in, not to what is shown.
            if let tile = tile(of: face), !tile.isInVideo {
                boxes[face.asset, default: []].append(tile.box)
            }
        }
        return boxes
    }

    /// A face's tile, while its photo's faces are published.
    func tile(of face: FaceID) -> FaceTile? {
        state.people?.photoFaces[face.asset]?.first { $0.id == face }?.tile
    }

    // MARK: - The People filter

    /// The filter popover's People rows: the visible people with a name, favourites first. An
    /// unnamed person is one more `Unnamed Person` row no one can tell from the others, so it is
    /// offered only while checked (named when checked, its name since removed), which keeps
    /// every checked row seen.
    var peopleFilterControls: PeopleFilterControls {
        let checked = queryDescriptor.filter.people
        return PeopleFilterControls(
            people: (state.people?.visiblePeople ?? []).filter { $0.name != nil || checked.contains($0.id) },
            setPerson: { [weak self] person, included in self?.setPeopleFilter(person, included: included) },
            setUnidentified: { [weak self] included in self?.setUnidentifiedFilter(included) }
        )
    }

    func setPeopleFilter(_ person: PersonID, included: Bool) {
        setMediaFilter(queryDescriptor.filter.settingPerson(person, included: included))
    }

    func setUnidentifiedFilter(_ included: Bool) {
        var filter = queryDescriptor.filter
        filter.unassignedFaces = included
        setMediaFilter(filter)
    }

    // MARK: - What the views get

    var peopleActions: PeopleActions {
        PeopleActions(
            select: { [weak self] person, modifiers in self?.selectPeople(person, modifiers: modifiers) },
            moveCursor: { [weak self] step, extending in self?.moveGalleryCursor(by: step, extending: extending) },
            open: { [weak self] person in self?.openPerson(person) },
            edit: { [weak self] person in self?.beginEditingPerson(person) },
            askMerge: { [weak self] from, into in self?.askMerge(from, into: into) },
            mergeRefusal: { [weak self] from, into in self?.mergeRefusal(from, into: into) },
            answerMerge: { [weak self] merge in self?.answerMerge(merge) },
            setFavorite: { [weak self] person, favorite in self?.setFavorite(person, favorite) },
            setHidden: { [weak self] person, hidden in self?.setHidden(person, hidden) }
        )
    }
}

/// The People gallery's intents, as values the passive views call.
struct PeopleActions {
    let select: (PersonID?, NSEvent.ModifierFlags) -> Void
    let moveCursor: (Int, Bool) -> PersonID?
    let open: (PersonID) -> Void
    let edit: (PersonID) -> Void
    let askMerge: (PersonID, PersonID) -> Void
    let mergeRefusal: (PersonID, PersonID) -> String?
    let answerMerge: (Bool) -> Void
    let setFavorite: (PersonID, Bool) -> Void
    let setHidden: (PersonID, Bool) -> Void
}
