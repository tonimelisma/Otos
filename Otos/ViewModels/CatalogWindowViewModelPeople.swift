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
// the one write path; its undo writes back the record the store returned, and each undo or
// redo after that writes back what the one before it replaced (`PeopleUndoRecord`).
// Buttons, keys, menus, drags and VoiceOver actions all call the intents below.

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

/// The targets and the pane the targets' face menu was built for.
struct TargetFacesKey: Equatable {
    let photos: [MediaAssetID]
    let showsInfo: Bool
}

/// People window state.
struct PeopleSession: Equatable {
    var selectedPeople: Set<PersonID> = []
    var cursor: PersonID?
    var sheet: PersonSheetRequest?
    var mergeQuestion: PeopleMergeQuestion?
    /// A merge the store refused after the user answered Merge, with its reason (DES-038).
    var mergeRefusal: PeopleMergeRefusal?
}

/// Why a merge the user answered was refused when the store applied it: the question was
/// judged against the state it was asked in, and an act submitted earlier, still in the
/// stream, can change what the store finds.
nonisolated struct PeopleMergeRefusal: Equatable, Sendable {
    let reason: String
}

/// The People writes the window submitted — acts, and the undo and redo of each — that the
/// store has not yet answered, each under the number its submission took (ADR 0032 rule 2: a
/// request is a counter, and the store's answer names the request it is for). A merge, and
/// the redo of one, which is that merge, takes a person away; while it is outstanding that
/// person is the merge's to answer for: the store commits the write and rings the projection
/// before its answer reaches the window, so a People state that no longer lists them can
/// arrive first. Such a state leaves the window showing and filtering them; the store's
/// confirmation takes the window to the person merged into (`didMerge`), and a refusal or a
/// failed redo hands them back to the published state.
nonisolated struct PendingPeopleActs: Equatable, Sendable {
    /// One person a write merges into another.
    nonisolated struct Merge: Equatable, Sendable {
        let from: PersonID
        let into: PersonID
    }

    private(set) var submitted: UInt64 = 0
    /// Each outstanding merge, by its request.
    private var merges: [UInt64: Merge] = [:]

    /// Numbers a write's submission; `merge` is the merge it makes, if it makes one.
    mutating func submit(merging merge: Merge?) -> UInt64 {
        submitted &+= 1
        merges[submitted] = merge
        return submitted
    }

    /// The store answered `request`: the merge it was making, if it was one still outstanding.
    mutating func answer(_ request: UInt64) -> Merge? {
        merges.removeValue(forKey: request)
    }

    /// Whether an outstanding merge is taking `person` away.
    func isMergingAway(_ person: PersonID) -> Bool {
        merges.values.contains { $0.from == person }
    }
}

extension PeopleAct {
    /// The merge this act makes, performed or redone: a redo returns the catalog to the state
    /// the act left, so it takes the same person away into the same person.
    nonisolated var merge: PendingPeopleActs.Merge? {
        guard case let .merge(from, into) = self else { return nil }
        return PendingPeopleActs.Merge(from: from, into: into)
    }
}

/// A People act on its way to the store, or an undo or redo of one; `request` is its
/// `PendingPeopleActs` number.
nonisolated enum PeopleIntent: Sendable {
    /// `title` is the act's name on the undo stack, decided when the act is submitted, from
    /// the state it changes (`undoTitle(for:)`).
    case perform(PeopleAct, title: String, request: UInt64)
    /// Undo or redo: writes `record` back. `act` and `undoing` name it.
    case flip(PeopleUndoRecord, act: PeopleAct, undoing: Bool, request: UInt64)
}

/// What the store did with one `PeopleIntent`, applied on the main actor once the store's
/// await returns (ADR 0032 rule 1).
enum PeopleIntentEvent {
    case performed(PeopleAct, title: String, request: UInt64, outcome: PeopleActOutcome)
    case refused(PeopleAct, request: UInt64, error: any Error)
    /// A flip wrote `record`'s restore back; `redo` is what that write replaced.
    case flipped(PeopleUndoRecord, act: PeopleAct, undoing: Bool, request: UInt64, redo: PeopleRestore)
    case flipFailed(PeopleUndoRecord, act: PeopleAct, undoing: Bool, request: UInt64, error: any Error)
    /// An earlier flip of the act failed, so this one had nothing to write.
    case flipSkipped(act: PeopleAct, undoing: Bool, request: UInt64)
}

/// What one act's undo and redo entries write back: the state the act, or the last undo or
/// redo of it, replaced. Each flip writes it and keeps what that write replaced
/// (`CatalogStore.restore`), so a redo returns the catalog to the state the act left rather
/// than performing the act again — a person the act created comes back under the same ID,
/// and every later act naming them redoes too. Both entries of one act share it; only the
/// People intent consumer reads or writes it, in submission order, so a flip always finds
/// what the flip before it kept. Nil once a flip failed: what it would write is no longer
/// known, so later flips of the act change nothing and say so in the log.
@MainActor
final class PeopleUndoRecord {
    var restore: PeopleRestore?

    init(_ restore: PeopleRestore) {
        self.restore = restore
    }
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
            let shared = Dictionary(grouping: faces.map(\.tile), by: \.id.asset).values.filter { $0.count > 1 }
            return "\(photos.count - Set(photos).count + 1) of these faces are in the same \(MediaCount(tiles: shared.flatMap(\.self)).noun)"
        }
        guard let target = summaries[person] else { return "Choose another person" }
        let anchored = Set(target.userFaces.map(\.id.asset))
        let taken = faces.filter { anchored.contains($0.id.asset) && $0.person != person }
        if !taken.isEmpty {
            let media = MediaCount(faces: taken)
            return "\(target.displayName) is already in \(media.total == 1 ? "this" : "these") \(media.noun)"
        }
        if let birthday = target.birthday?.seconds {
            let before = MediaCount(faces: faces.filter { ($0.tile.captureSeconds ?? .infinity) < birthday })
            if before.total > 0 {
                return "\(before.text) \(before.isOrAre) from before \(target.displayName)'s birthday"
            }
        }
        return nil
    }

    /// Why `person` cannot be merged into anyone, whoever it is dropped on or named as, or
    /// nil when someone could take it: a hidden person has no act but Unhide (DES-111,
    /// `docs/design/people.md`), so it is merged neither away nor into.
    func mergeSourceRefusal(_ person: PersonID) -> String? {
        summaries[person].flatMap(hiddenRefusal)
    }

    private func hiddenRefusal(_ person: PersonSummary) -> String? {
        person.isHidden ? "\(person.displayName) is a hidden person" : nil
    }

    /// Why `from` cannot merge into `into`, or nil when it can.
    func mergeRefusal(_ from: PersonID, into: PersonID) -> String? {
        mergeRefusal(from, into: into, sourceBirthday: summaries[from]?.birthday)
    }

    /// The same, with `from` holding `sourceBirthday`: the Person sheet's Save sets the
    /// birthday typed before it asks to merge.
    private func mergeRefusal(_ from: PersonID, into: PersonID, sourceBirthday: PersonBirthday?) -> String? {
        guard from != into, let source = summaries[from], let target = summaries[into] else {
            return "Choose another person"
        }
        if let refusal = mergeSourceRefusal(from) ?? hiddenRefusal(target) {
            return refusal
        }
        let shared = MediaCount(items: source.anchorMedia.filter { target.anchorMedia[$0.key] != nil }.map { ($0.key, $0.value) })
        if shared.total > 0 {
            return PeopleText.bothIn(source.displayName, target.displayName, media: shared)
        }
        if let birthday = (target.birthday ?? sourceBirthday)?.seconds {
            let before = MediaCount(tiles: (source.userFaces + target.userFaces).filter { ($0.captureSeconds ?? .infinity) < birthday })
            if before.total > 0 {
                return PeopleText.beforeTheBirthday(before)
            }
        }
        return nil
    }

    /// The store's refusal of `from` merging into `into`, in the words the disabled act
    /// would have shown (`mergeRefusal`).
    func mergeRefusal(_ violation: PeopleRuleViolation, from: PersonID, into: PersonID) -> String {
        switch violation {
        case let .bothIn(media):
            PeopleText.bothIn(name(from), name(into), media: media)
        case let .confirmedBeforeBirthday(media):
            PeopleText.beforeTheBirthday(media)
        case .twoFacesOfOnePhoto, .personAlreadyInPhoto, .beforeBirthday, .nameTaken, .unknownFace:
            "Choose another person"
        }
    }

    /// Why the Person sheet cannot save, or nil when it can, so Save is never pressed for
    /// nothing (DES-038). `birthday` is the sheet's text, which must be a year or a full date.
    /// A name another visible person has is not itself a refusal: for a person, Save sets the
    /// birthday typed and asks to merge, refused as that merge is; for faces, it gives them
    /// to that person, refused as that move is, and a birthday there would be another
    /// person's, so it must be cleared. A hidden person's name is refused, as no surface but
    /// the gallery offers them.
    func sheetRefusal(_ subject: PersonSheetRequest.Subject, name text: String, birthday: String?) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Enter a name"
        }
        var parsed: PersonBirthday?
        if let birthday {
            guard let value = PersonBirthday(birthday) else { return "Enter a year, or a full date" }
            parsed = value
        }
        switch subject {
        case let .person(person):
            if let seconds = parsed?.seconds {
                let before = MediaCount(tiles: summaries[person]?.userFaces.filter { ($0.captureSeconds ?? .infinity) < seconds } ?? [])
                if before.total > 0 {
                    return "\(before.text) of \(name(person)) \(before.isOrAre) from before this date"
                }
            }
            if isHiddenName(trimmed, excluding: person) {
                return "\(trimmed) is a hidden person"
            }
            if let holder = self.person(named: trimmed, excluding: person) {
                return mergeRefusal(person, into: holder, sourceBirthday: parsed)
            }
        case let .faces(ids):
            let faces = ids.compactMap(face(_:))
            if isHiddenName(trimmed, excluding: nil) {
                return "\(trimmed) is a hidden person"
            }
            if let holder = person(named: trimmed) {
                if let parsed, parsed != summaries[holder]?.birthday {
                    return "Clear the birthday to give these faces to \(trimmed)"
                }
                return moveRefusal(faces, to: holder)
            }
            if let seconds = parsed?.seconds {
                let before = MediaCount(faces: faces.filter { ($0.tile.captureSeconds ?? .infinity) < seconds })
                if before.total > 0 {
                    return "\(before.text) \(before.isOrAre) from before this date"
                }
            }
        }
        return nil
    }

    /// The visible person called `name`, other than `excluding`.
    func person(named name: String, excluding: PersonID? = nil) -> PersonID? {
        state.visiblePeople.first { $0.name == name && $0.id != excluding }?.id
    }

    /// Whether a hidden person other than `excluding` is called `name`: no two people share
    /// a name, so the store refuses it.
    private func isHiddenName(_ name: String, excluding: PersonID?) -> Bool {
        state.hiddenPeople.contains { $0.name == name && $0.id != excluding }
    }

    /// A face of the published People state.
    func face(_ id: FaceID) -> PhotoFace? {
        state.photoFaces[id.asset]?.first { $0.id == id }
    }
}

/// People's counted strings.
nonisolated enum PeopleText {
    static func count(_ value: Int, _ noun: String) -> String {
        "\(value.formatted()) \(value == 1 ? noun : noun + "s")"
    }

    /// A merge refused because the user gave both people a face in the same photos and
    /// videos, named by what they are (`MediaCount`).
    static func bothIn(_ first: String, _ second: String, media: MediaCount) -> String {
        "\(first) and \(second) are both in \(media.text)"
    }

    /// A merge refused because photos and videos the user gave either predate the birthday
    /// kept.
    static func beforeTheBirthday(_ media: MediaCount) -> String {
        "\(media.text) \(media.isOrAre) from before the birthday"
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

    /// The published empty state; nil while the scope holds items.
    var mediaEmptyState: CatalogMediaEmptyState? {
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
        reconcileShownPeople()
        refreshTargetFaces()
        OtosLog.ui.noticeOperation("people.state", phase: "applied", fields: [
            "people": "\(people.people.count)",
            "hidden": "\(people.hiddenPeople.count)",
            "faces": "\(people.faceCount)",
            "unchecked": "\(people.unchecked.total)",
        ])
    }

    /// The one answer to which person the window shows and which people it filters by, given
    /// the published People state and the merges the store has not answered: a person hidden,
    /// merged away or gone takes their photos with them, so the window returns to the gallery,
    /// where a hidden person is still seen, and the filter, which offers only visible people,
    /// lets go of them. A person an outstanding merge is taking away is kept until the store
    /// answers (`PendingPeopleActs`). Called for every new People state and every answer to a
    /// merge.
    private func reconcileShownPeople() {
        guard let people = state.people else { return }
        let visible = Set(people.visiblePeople.map(\.id))
        let pending = pendingPeopleActs
        let stays = { (person: PersonID) in visible.contains(person) || pending.isMergingAway(person) }
        if let person = queryDescriptor.scope.person, !stays(person) {
            returnToPeople()
        }
        let filter = queryDescriptor.filter
        let kept = filter.people.filter(stays)
        if kept != filter.people {
            var next = filter
            next.people = kept
            setMediaFilter(next)
        }
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

    /// The arrow keys on the gallery, `columns` people to a row: the person the key reaches
    /// (`PeopleGalleryStep.target`).
    func moveGalleryCursor(_ step: PeopleGalleryStep, columns: Int, extending: Bool) -> PersonID? {
        let people = state.people ?? .empty
        let sections = [people.visiblePeople.map(\.id), people.hiddenPeople.map(\.id)].filter { !$0.isEmpty }
        guard let target = step.target(from: peopleSession.cursor, columns: columns, sections: sections) else { return nil }
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

    /// The sheet's Save, enabled only while `personSheetRefusal` is nil. A name another
    /// person has asks whether they are the same person; for `Someone Else…` it gives the
    /// faces to that person, and a new name makes a new person with the birthday typed, one
    /// act and one undo.
    func savePersonSheet(_ subject: PersonSheetRequest.Subject, name: String, birthday: String?) {
        guard personSheetRefusal(subject, name: name, birthday: birthday) == nil else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        peopleSession.sheet = nil
        // The refusal above has read the text as a birthday.
        let parsed = birthday.flatMap(PersonBirthday.init)
        switch subject {
        case let .person(person):
            guard let summary = peopleIndex.summaries[person] else { return }
            if let holder = peopleIndex.person(named: trimmed, excluding: person) {
                // The birthday typed is saved, then the name asks whether they are one person;
                // the refusal above judged that merge with this birthday.
                if parsed != summary.birthday {
                    submitPeopleAct(.edit(person, name: summary.name, birthday: parsed))
                }
                peopleSession.mergeQuestion = PeopleMergeQuestion(from: person, into: holder)
                return
            }
            guard trimmed != summary.name || parsed != summary.birthday else { return }
            submitPeopleAct(.edit(person, name: trimmed, birthday: parsed))
        case let .faces(faces):
            if let holder = peopleIndex.person(named: trimmed) {
                submitPeopleAct(.move(faces, to: holder))
            } else {
                submitPeopleAct(.moveToNewPerson(faces, name: trimmed, birthday: parsed))
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

    /// Whether `person` can be merged into anyone: a cell the gallery lets the user drag.
    func canMergeAway(_ person: PersonID) -> Bool {
        peopleIndex.mergeSourceRefusal(person) == nil
    }

    /// The merge question's answer. Merge submits the merge without judging it again: it was
    /// judged when asked, against the state it was asked in (for a taken name, with the
    /// birthday typed), and an act submitted before it — that birthday — is still ahead of it
    /// in the one ordered People stream, so the published state may not show it yet. The store
    /// applies the merge after that act and is its judge: what the window does with the merged
    /// people follows its confirmation (`didMerge`), and its refusal reaches the user with the
    /// reason (`mergeRefusal`). Until it answers, the person merged away stays where the
    /// window shows or filters them (`PendingPeopleActs`).
    func answerMerge(_ merge: Bool) {
        guard let question = peopleSession.mergeQuestion else { return }
        peopleSession.mergeQuestion = nil
        guard merge else { return }
        submitPeopleAct(.merge(question.from, into: question.into))
    }

    /// The store answered `request`, a write the window numbered, having written it (`wrote`)
    /// or not. The one place an answer reaches what the window shows: a merge it wrote — the
    /// act or its redo — takes the window to the person merged into; a merge it did not write
    /// hands the person it would have taken back to the published state.
    private func didAnswerPeopleWrite(_ request: UInt64, wrote: Bool) {
        guard let merge = pendingPeopleActs.answer(request) else { return }
        if wrote {
            didMerge(merge.from, into: merge.into)
        }
        reconcileShownPeople()
    }

    /// The store merged `from` into `into`: the person they became is selected, and takes
    /// their place where the window showed or filtered them, rather than the window leaving
    /// them.
    private func didMerge(_ from: PersonID, into: PersonID) {
        peopleSession.selectedPeople = [into]
        peopleSession.cursor = into
        if queryDescriptor.scope.person == from {
            setQueryDescriptor(CatalogQueryDescriptor(
                scope: .person(into),
                filter: queryDescriptor.filter,
                sort: queryDescriptor.sort,
                search: queryDescriptor.search
            ))
        }
        if queryDescriptor.filter.people.contains(from) {
            var filter = queryDescriptor.filter
            filter.people.remove(from)
            filter.people.insert(into)
            setMediaFilter(filter)
        }
    }

    /// The store refused an act. A merge the user answered says why, and the person it would
    /// have merged away is the published state's again; every other act is offered only while
    /// its rules allow it, so its refusal is a race the log records.
    private func didRefusePeopleAct(_ act: PeopleAct, request: UInt64, error: any Error) {
        OtosLog.ui.errorOperation("people.act", phase: "refused", fields: [
            "act": act.logName, "faces": "\(act.faceCount)", "error": String(describing: error),
        ])
        didAnswerPeopleWrite(request, wrote: false)
        guard case let .merge(from, into) = act, let violation = error as? PeopleRuleViolation else { return }
        peopleSession.mergeRefusal = PeopleMergeRefusal(reason: peopleIndex.mergeRefusal(violation, from: from, into: into))
    }

    func dismissMergeRefusal() {
        peopleSession.mergeRefusal = nil
    }

    // MARK: - A person's settings menu

    /// The gallery's context menu for `person`: their settings, `Merge Into ▸` the other
    /// selected people while they are selected with others, Hide, and Show Photos; a hidden
    /// person's is Unhide alone.
    func galleryPersonMenu(_ person: PersonID) -> PersonMenu? {
        guard let summary = peopleIndex.summaries[person] else { return nil }
        let selected = peopleSession.selectedPeople
        let others = (state.people?.visiblePeople ?? []).filter { selected.contains($0.id) && $0.id != person }
        return personMenu(summary, mergeTargets: selected.contains(person) && !others.isEmpty ? others : nil, opens: true)
    }

    /// The person the menu bar's person items act on while the gallery shows: the one the
    /// keys last reached, if selected, else the one person selected.
    var galleryActingPerson: PersonID? {
        guard showsPeopleList else { return nil }
        let selected = peopleSession.selectedPeople
        if let cursor = peopleSession.cursor, selected.contains(cursor) {
            return cursor
        }
        return selected.count == 1 ? selected.first : nil
    }

    /// The menu bar's person items: the gallery's context menu for the person they act on,
    /// so the keyboard reaches every act the pointer does (DES-080); every item disabled
    /// while there is none.
    var galleryActingPersonMenu: PersonMenu {
        galleryActingPerson.flatMap(galleryPersonMenu) ?? .unavailable
    }

    /// A menu-bar person item: the same intent the gallery's context menu calls.
    func performGalleryPersonAct(_ act: PersonMenu.Act) {
        guard let person = galleryActingPerson else { return }
        performPersonAct(act, on: person)
    }

    /// The toolbar menu of a person's photos: their settings, `Merge Into ▸` every other
    /// visible person with a name (an unnamed one reads `Unnamed Person`, so no row could be
    /// told from another), and Hide.
    var shownPersonMenu: PersonMenu? {
        guard let person = shownPerson else { return nil }
        let others = (state.people?.visiblePeople ?? []).filter { $0.id != person.id && $0.name != nil }
        return personMenu(person, mergeTargets: others, opens: false)
    }

    private func personMenu(_ person: PersonSummary, mergeTargets: [PersonSummary]?, opens: Bool) -> PersonMenu {
        guard !person.isHidden else {
            return PersonMenu(
                settings: [], mergeInto: nil,
                visibility: PersonMenu.Item(title: "Unhide", act: .setHidden(false)), open: nil
            )
        }
        return PersonMenu(
            settings: [
                PersonMenu.Item(title: person.name == nil ? FaceActTitle.addName : "Rename…", act: .edit),
                PersonMenu.Item(title: "Set Birthday…", act: .edit),
                PersonMenu.Item(title: person.isFavorite ? "Remove from Favorites" : "Add to Favorites", act: .setFavorite(!person.isFavorite)),
            ],
            mergeInto: mergeTargets?.map { target in
                PersonMenu.Item(
                    title: target.displayName, act: .mergeInto(target.id),
                    refusal: peopleIndex.mergeRefusal(person.id, into: target.id)
                )
            },
            visibility: PersonMenu.Item(title: "Hide", act: .setHidden(true)),
            open: opens ? PersonMenu.Item(title: "Show Photos", act: .open) : nil
        )
    }

    /// Every item of every `PersonMenu`, wherever it renders.
    func performPersonAct(_ act: PersonMenu.Act, on person: PersonID) {
        switch act {
        case .edit:
            beginEditingPerson(person)
        case let .setFavorite(favorite):
            setFavorite(person, favorite)
        case let .mergeInto(target):
            askMerge(person, into: target)
        case let .setHidden(hidden):
            setHidden(person, hidden)
        case .open:
            openPerson(person)
        }
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
    private var targetFaces: SelectionFaces {
        let photos = targetIDs(.current)
        var faces = (state.people ?? .empty).selectionFaces(for: photos)
        if faceCandidates.photos == photos {
            faces.candidates = faceCandidates.candidates
        }
        return faces
    }

    /// Rebuilds what the photo menus and the Info pane offer for the targets' faces
    /// (`targetFaceMenu`), asks `PeopleAssignment` to rank them again, and rings the Info
    /// pane's read of whether they were checked. Called by every writer of the target
    /// (through `refreshPhotoInfo`, which the pane's showing and hiding also call) and by
    /// every new People state, so the menu value is built once per change of what it is
    /// built from, never in a view's `body`. A ranking for photos no longer targeted is
    /// dropped. An outline the Info pane's rows held belongs to the targets and the pane it
    /// was pointed at in: either changing lets go of it, since the row the pointer rested on
    /// is gone and reports no exit.
    func refreshTargetFaces() {
        let photos = targetIDs(.current)
        let key = TargetFacesKey(photos: photos, showsInfo: showsInfo)
        if key != targetFacesKey {
            targetFacesKey = key
            outlineFaces([])
        }
        rebuildTargetFaceMenu()
        facesReadDoorbell?.yield()
        faceCandidatesTask?.cancel()
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

    /// Builds `targetFaceMenu` from the targets, People and the ranking as they are now; a
    /// new ranking (`faceCandidates`) rebuilds it as it lands.
    func rebuildTargetFaceMenu() {
        let menu = faceMenu(for: targetFaces)
        if targetFaceMenu != menu {
            targetFaceMenu = menu
        }
    }

    /// What the Info pane's People section says when it lists no face (APP-041).
    var targetFacesLine: String {
        PhotoFacesRead.line(for: targetIDs(.current), read: photoFacesRead)
    }

    /// The one photo whose faces the Info pane says were checked, while it shows one.
    private var facesReadTarget: MediaAssetID? {
        guard showsInfo else { return nil }
        let photos = targetIDs(.current)
        return photos.count == 1 ? photos.first : nil
    }

    /// Keeps `photoFacesRead` the catalog's word on the Info pane's photo: each ring reads
    /// whether its faces were read and how many it holds, and applies the read if that photo
    /// is still the one shown. `refreshTargetFaces` rings it for every new target and People
    /// state, so a photo read while it is shown says so without being reselected (the
    /// reader's write is what publishes the next People state). One loop on a newest-wins
    /// doorbell; a ring during a read is kept, so the last change is always followed by a
    /// fresh read. It holds the view model weakly across each wait and ends with it. A failed
    /// read is logged and changes nothing (ADR 0032 rule 4).
    func startFacesReadRefresh() {
        guard facesReadTask == nil else { return }
        let (rings, doorbell) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        facesReadDoorbell = doorbell
        let store = catalogStore
        facesReadTask = Task { [weak self] in
            for await _ in rings {
                guard let target = self?.facesReadTarget else {
                    if self == nil {
                        break
                    }
                    continue
                }
                let read: PhotoFacesRead?
                do {
                    read = try await store.facesRead(for: target)
                } catch {
                    OtosLog.ui.errorOperation("people.facesRead", phase: "readFailed", fields: [
                        "id": target.relativePath.rawValue, "error": String(describing: error),
                    ])
                    continue
                }
                guard !Task.isCancelled, let self else {
                    break
                }
                guard facesReadTarget == target, photoFacesRead != read else {
                    continue
                }
                photoFacesRead = read
                OtosLog.ui.debugOperation("people.facesRead", phase: "applied", fields: [
                    "id": target.relativePath.rawValue,
                    "read": read.map { "\($0.isRead)" } ?? "uncataloged",
                    "faces": read.map { "\($0.faceCount)" } ?? "none",
                ])
            }
        }
    }

    /// How many people a face list offers before `Someone Else…` or `New Name…` (HIG: about
    /// five items in a submenu).
    static let faceListLength = 5

    /// How many likely people an unidentified face in the Info pane offers as buttons.
    static let faceSuggestionLength = 3

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

    /// The people an unidentified face in the Info pane offers as buttons: the three the
    /// ranking says it most likely is, under the list's rules. Nil until every one of
    /// `faces` is ranked, so no button stands for a person only gallery order put there, and
    /// none moves under the pointer when the ranking lands.
    func rankedPeople(for faces: [PhotoFace], in selection: SelectionFaces, allowed: (PersonID) -> Bool) -> [PersonSummary]? {
        guard faces.allSatisfy({ selection.candidates[$0.id] != nil }) else { return nil }
        let named = Dictionary(uniqueKeysWithValues: (state.people?.visiblePeople ?? []).filter { $0.name != nil }.map { ($0.id, $0) })
        return Array(selection.likelyPeople(for: faces).compactMap { named[$0] }.filter { allowed($0.id) }.prefix(Self.faceSuggestionLength))
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

    /// Hands an act to the one consumer, numbered in `pendingPeopleActs`.
    private func submitPeopleAct(_ act: PeopleAct) {
        let title = undoTitle(for: act)
        let request = pendingPeopleActs.submit(merging: act.merge)
        OtosLog.ui.noticeOperation("people.act", phase: "submit", fields: [
            "act": act.logName, "faces": "\(act.faceCount)", "request": "\(request)",
        ])
        submitPeopleIntent(.perform(act, title: title, request: request), request: request)
    }

    /// The act's name on the undo stack, in the words of the item that made it and the
    /// photos it changes (`docs/design/people.md` Undo). Read before the act, from the state
    /// it changes: the person a face is losing, the photos of a person being named.
    func undoTitle(for act: PeopleAct) -> String {
        switch act {
        case let .move(faces, _), let .moveToNewPerson(faces, _, _):
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

    /// Hands `intent`, numbered `request`, to the stream. An intent the stream never takes is
    /// never answered, so its number is answered here.
    private func submitPeopleIntent(_ intent: PeopleIntent, request: UInt64) {
        switch peopleIntentContinuation.yield(intent) {
        case .enqueued:
            return
        case .dropped, .terminated:
            OtosLog.ui.error("op=people.intent phase=dropped")
        @unknown default:
            OtosLog.ui.error("op=people.intent phase=unknownYield")
        }
        _ = pendingPeopleActs.answer(request)
    }

    /// The one consumer of People acts and their undo, in submission order: each intent goes
    /// to the store (`runPeopleIntent`) and what the store did is applied when its await
    /// returns (`applyPeopleIntentEvent`). Holds the view model weakly across each wait and
    /// ends with the stream.
    func startPeopleIntentConsumer() {
        guard peopleIntentTask == nil else { return }
        let intents = peopleIntentStream
        let store = catalogStore
        peopleIntentTask = Task { [weak self, store] in
            for await intent in intents {
                let event = await Self.runPeopleIntent(intent, store: store)
                guard let self else { return }
                applyPeopleIntentEvent(event)
            }
        }
    }

    /// One intent through the store. Touches no window state: it reads the flip's record as
    /// its input before the await and returns what the store did. Every People state the
    /// store's write publishes can reach the window while this is suspended.
    static func runPeopleIntent(_ intent: PeopleIntent, store: CatalogStore) async -> PeopleIntentEvent {
        switch intent {
        case let .perform(act, title, request):
            do {
                return try await .performed(act, title: title, request: request, outcome: store.perform(act))
            } catch {
                return .refused(act, request: request, error: error)
            }
        case let .flip(record, act, undoing, request):
            guard let restore = record.restore else { return .flipSkipped(act: act, undoing: undoing, request: request) }
            do {
                return try await .flipped(record, act: act, undoing: undoing, request: request, redo: store.restore(restore))
            } catch {
                return .flipFailed(record, act: act, undoing: undoing, request: request, error: error)
            }
        }
    }

    /// What the store did with one intent, applied in the order the intents were submitted.
    func applyPeopleIntentEvent(_ event: PeopleIntentEvent) {
        switch event {
        case let .performed(act, title, request, outcome):
            didPerformPeopleAct(act, title: title, request: request, outcome: outcome)
        case let .refused(act, request, error):
            didRefusePeopleAct(act, request: request, error: error)
        case let .flipped(record, act, undoing, request, redo):
            record.restore = redo
            OtosLog.ui.noticeOperation("people.act", phase: undoing ? "undone" : "redone", fields: [
                "act": act.logName, "request": "\(request)",
            ])
            didAnswerPeopleWrite(request, wrote: true)
        case let .flipFailed(record, act, undoing, request, error):
            record.restore = nil
            OtosLog.ui.errorOperation("people.act", phase: "\(undoing ? "undone" : "redone").failed", fields: [
                "act": act.logName, "request": "\(request)", "error": String(describing: error),
            ])
            didAnswerPeopleWrite(request, wrote: false)
        case let .flipSkipped(act, undoing, request):
            OtosLog.ui.errorOperation("people.act", phase: "\(undoing ? "undone" : "redone").skipped", fields: [
                "act": act.logName, "request": "\(request)", "reason": "earlierFlipFailed",
            ])
            didAnswerPeopleWrite(request, wrote: false)
        }
    }

    /// Registers the act's undo. Explicit groups: registration happens on a store
    /// completion, not inside an AppKit event, so the manager's per-event grouping has
    /// nothing to close.
    private func didPerformPeopleAct(_ act: PeopleAct, title: String, request: UInt64, outcome: PeopleActOutcome) {
        didAnswerPeopleWrite(request, wrote: true)
        let record = PeopleUndoRecord(outcome.restore)
        windowUndoManager.beginUndoGrouping()
        windowUndoManager.registerUndo(withTarget: self) { model in
            model.flipPeopleAct(record, act: act, title: title)
        }
        windowUndoManager.setActionName(title)
        windowUndoManager.endUndoGrouping()
        publishUndoState()
    }

    /// Runs inside `UndoManager.undo()` and `redo()`: files the opposite entry synchronously
    /// — the manager is undoing or redoing right now, so it lands on the other stack and the
    /// rest of that stack is kept — then writes the act's record back through the serial
    /// lane. Undo and redo are the same write: each restores what the last one replaced. A
    /// redo is the act, so it is numbered as the act was and a redone merge is answered as the
    /// merge is (`didAnswerPeopleWrite`); an undo puts back the person a merge took and takes
    /// no one away.
    private func flipPeopleAct(_ record: PeopleUndoRecord, act: PeopleAct, title: String) {
        let undoing = windowUndoManager.isUndoing
        windowUndoManager.registerUndo(withTarget: self) { model in
            model.flipPeopleAct(record, act: act, title: title)
        }
        windowUndoManager.setActionName(title)
        let request = pendingPeopleActs.submit(merging: undoing ? nil : act.merge)
        submitPeopleIntent(.flip(record, act: act, undoing: undoing, request: request), request: request)
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

    ///
    /// Each act checks, when it is called, that the gallery is still the user's scope
    /// (`showsSelectedScope`): between a click on another row and its publication the
    /// gallery stays on screen, and nothing on it acts.
    var peopleActions: PeopleActions {
        PeopleActions(
            select: { [weak self] person, modifiers in self?.inGallery { $0.selectPeople(person, modifiers: modifiers) } },
            moveCursor: { [weak self] step, columns, extending in
                self?.inGallery { $0.moveGalleryCursor(step, columns: columns, extending: extending) } ?? nil
            },
            open: { [weak self] person in self?.inGallery { $0.openPerson(person) } },
            edit: { [weak self] person in self?.inGallery { $0.beginEditingPerson(person) } },
            askMerge: { [weak self] from, into in self?.inGallery { $0.askMerge(from, into: into) } },
            mergeRefusal: { [weak self] from, into in self?.mergeRefusal(from, into: into) },
            canMergeAway: { [weak self] person in self?.inGallery { $0.canMergeAway(person) } ?? false },
            answerMerge: { [weak self] merge in self?.answerMerge(merge) },
            menu: { [weak self] person in self?.inGallery { $0.galleryPersonMenu(person) } ?? nil },
            perform: { [weak self] act, person in self?.inGallery { $0.performPersonAct(act, on: person) } }
        )
    }

    /// `act` while the gallery is the scope the user selected; nil otherwise.
    private func inGallery<Result>(_ act: (CatalogWindowViewModel) -> Result) -> Result? {
        showsPeopleList && showsSelectedScope ? act(self) : nil
    }
}

/// The People gallery's intents, as values the passive views call.
struct PeopleActions {
    let select: (PersonID?, NSEvent.ModifierFlags) -> Void
    /// An arrow key, the gallery's columns, and whether Shift extends the selection.
    let moveCursor: (PeopleGalleryStep, Int, Bool) -> PersonID?
    let open: (PersonID) -> Void
    let edit: (PersonID) -> Void
    let askMerge: (PersonID, PersonID) -> Void
    let mergeRefusal: (PersonID, PersonID) -> String?
    /// Whether the person can be merged into anyone, so its cell can be dragged.
    let canMergeAway: (PersonID) -> Bool
    let answerMerge: (Bool) -> Void
    /// The person's context menu and VoiceOver actions.
    let menu: (PersonID) -> PersonMenu?
    let perform: (PersonMenu.Act, PersonID) -> Void
}

/// An arrow key in the People gallery.
nonisolated enum PeopleGalleryStep: Sendable {
    case left, right, up, down

    /// The person the key reaches from `cursor` in a grid of `columns` people to a row,
    /// whose `sections` (everyone visible, then the hidden people under their header) each
    /// start their own rows. Left and Right step through the gallery's order across the
    /// header; Up and Down keep the column, crossing into the next section's first row or
    /// the previous one's last, and stop on the last person or the first. With no cursor,
    /// the first person; with nobody, nil.
    func target(from cursor: PersonID?, columns: Int, sections: [[PersonID]]) -> PersonID? {
        let order = sections.flatMap(\.self)
        guard let first = order.first else { return nil }
        guard let cursor,
              let section = sections.firstIndex(where: { $0.contains(cursor) }),
              let index = sections[section].firstIndex(of: cursor)
        else { return first }
        let columns = max(columns, 1)
        let row = sections[section]
        let column = index % columns
        switch self {
        case .left, .right:
            let flat = order.firstIndex(of: cursor) ?? 0
            return order[min(max(flat + (self == .left ? -1 : 1), 0), order.count - 1)]
        case .up:
            if index >= columns {
                return row[index - columns]
            }
            guard section > 0 else { return row[0] }
            let above = sections[section - 1]
            let lastRowStart = (above.count - 1) / columns * columns
            return above[min(lastRowStart + column, above.count - 1)]
        case .down:
            if index + columns < row.count {
                return row[index + columns]
            }
            // A partial last row below: its last person, as Finder does.
            if index / columns < (row.count - 1) / columns {
                return row[row.count - 1]
            }
            guard section + 1 < sections.count else { return row[row.count - 1] }
            let below = sections[section + 1]
            return below[min(column, below.count - 1)]
        }
    }
}

/// One person's settings as a menu offers them (`docs/design/people.md`): the gallery's
/// context menu, the menu bar's items for the person selected there, the toolbar menu of a
/// person's photos, and a gallery cell's VoiceOver actions render this one value, built by
/// the view model, so their words and rules cannot drift.
nonisolated struct PersonMenu: Equatable, Sendable {
    nonisolated enum Act: Equatable, Sendable {
        /// Add Name…, Rename… and Set Birthday…: the Person sheet.
        case edit
        case setFavorite(Bool)
        /// Asks whether they are the same person first.
        case mergeInto(PersonID)
        case setHidden(Bool)
        /// Show Photos.
        case open
    }

    nonisolated struct Item: Equatable, Sendable {
        let title: String
        let act: Act
        /// Why the act is disabled, as its tooltip (DES-038); nil while it is enabled.
        var refusal: String?
    }

    /// Add Name… or Rename…, Set Birthday…, Add to Favorites or Remove from Favorites; none
    /// for a hidden person.
    let settings: [Item]
    /// `Merge Into ▸`'s people; nil where it is not offered, empty where it is disabled.
    let mergeInto: [Item]?
    /// Hide, or Unhide for a hidden person.
    let visibility: Item
    /// Show Photos, in the gallery.
    let open: Item?

    /// The menu bar's person items while the gallery has no person selected: the visible
    /// person's items, each disabled with the reason.
    static let unavailable: PersonMenu = {
        let reason = "Select a person in People"
        return PersonMenu(
            settings: [
                Item(title: "Rename…", act: .edit, refusal: reason),
                Item(title: "Set Birthday…", act: .edit, refusal: reason),
                Item(title: "Add to Favorites", act: .setFavorite(true), refusal: reason),
            ],
            mergeInto: [],
            visibility: Item(title: "Hide", act: .setHidden(true), refusal: reason),
            open: Item(title: "Show Photos", act: .open, refusal: reason)
        )
    }()

    /// Every enabled act in menu order, as VoiceOver offers them: a merge reads `Merge Into
    /// Sam`.
    var accessibilityItems: [Item] {
        let merges = (mergeInto ?? []).map { Item(title: "Merge Into \($0.title)", act: $0.act, refusal: $0.refusal) }
        return (settings + merges + [visibility] + (open.map { [$0] } ?? [])).filter { $0.refusal == nil }
    }
}
