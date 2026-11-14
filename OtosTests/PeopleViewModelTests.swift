import AppKit
import CoreGraphics
import Foundation
import Observation
@testable import OtosKit
import Testing

/// People's view-model side (ADR 0047, `docs/design/people.md`) against a real catalog: a
/// person's photos are the People filter over every library, hidden people leave it, the
/// photo menus group the targets' faces by person, the Person sheet merges on a taken name,
/// and every act is undone and redone through the window's one undo stack.
///
/// The model is not started: People states are settled from the store with
/// `PeopleAssignment.settle` and applied by hand, so each test decides which state arrives
/// when.
@Suite(.testDirectory)
@MainActor
struct PeopleViewModelTests {
    @MainActor
    struct Fixture {
        let library: FaceEnrichmentTests.ScannedLibrary
        let model: CatalogWindowViewModel
        let sam: PersonID
        /// Sam's face in a.jpg, and the faces of b.jpg: one like hers, one like no one.
        let hers: FaceID
        let like: FaceID
        let stranger: FaceID

        var store: CatalogStore {
            library.store
        }

        /// The face `withVideo` adds: in clip.mov, like hers.
        var inVideo: FaceID {
            FaceID(asset: library.id("clip.mov"), index: 0)
        }

        /// `others` are more stills, none read for faces. Without `consumesIntents` the People
        /// intent consumer is not started: the test takes each intent off the stream, runs it
        /// through the store and applies what the store did itself, so it can deliver a People
        /// state at the very suspension between the store's write and its answer.
        static func make(
            in directory: URL, withVideo: Bool = false, others: [String] = [], consumesIntents: Bool = true
        ) async throws -> Fixture {
            let library = try await FaceEnrichmentTests.ScannedLibrary.make(
                in: directory, files: ["a.jpg", "b.jpg"] + (withVideo ? ["clip.mov"] : []) + others
            )
            try await library.readFaces([
                library.result(for: "a.jpg", faces: [PeopleStoreTests.face(x: 0.1)]),
                library.result(for: "b.jpg", faces: [PeopleStoreTests.face(x: 0.1), PeopleStoreTests.face(x: 0.65)]),
            ])
            if withVideo {
                try await library.readVideoFaces("clip.mov", faces: [PeopleStoreTests.face(x: 0.1)])
            }
            let hers = FaceID(asset: library.id("a.jpg"), index: 0)
            let sam = try #require(try await library.store.perform(.moveToNewPerson([hers], name: "Sam")).person)
            let model = CatalogWindowViewModel(
                catalogStore: library.store,
                catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
                startsStallMonitor: false,
                startsEnrichment: false,
                startsSourceMonitoring: false,
                preferencesDomain: PreferencesDomain.suite(UUID().uuidString),
                volumeCapacity: ampleVolumeCapacity,
                trashFiles: .refusing
            )
            if consumesIntents {
                model.startPeopleIntentConsumer()
            }
            return Fixture(
                library: library, model: model, sam: sam, hers: hers,
                like: FaceID(asset: library.id("b.jpg"), index: 0),
                stranger: FaceID(asset: library.id("b.jpg"), index: 1)
            )
        }

        /// People as the store holds it, assigned.
        func people() async throws -> CatalogPeopleState {
            let libraries = try #require(await store.loadedLibraries())
            return try await PeopleAssignment.settle(store: store, libraries: libraries)
        }

        /// The window showing `scope` with `people`, under the model's own descriptor.
        func show(_ people: CatalogPeopleState, scope: SidebarSelection, grid: [MediaAssetID] = []) {
            var descriptor = model.queryDescriptor
            descriptor.scope = scope
            var state = CatalogWindowState(
                title: "All Media",
                libraries: [],
                removableSources: [],
                mediaGrid: CatalogMediaGridState(descriptor: descriptor, orderedAssetIDs: grid),
                filterOptions: .empty,
                resolvedSidebarSelection: scope,
                mediaEmptyState: .noMedia,
                deviceConnectionBanner: nil
            )
            state.people = people
            state.queryGeneration = model.queryGeneration
            model.applyState(state)
        }

        func assignment(of face: FaceID) async throws -> FaceAssignment? {
            try await store.peopleSnapshot().faces.first { $0.id == face }?.assignment
        }
    }

    /// A person's photos are the leaf under People: every library's photos of them, titled
    /// with the name, with Back to People; the filter set before is kept both ways.
    @Test func openingAPersonShowsTheirPhotosUnderPeople() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        let people = try await fixture.people()
        fixture.show(people, scope: .people)
        fixture.model.setMediaFilter(MediaFilter(choices: [.liked]))

        fixture.model.openPerson(fixture.sam)
        #expect(fixture.model.queryDescriptor.scope == .person(fixture.sam))
        #expect(fixture.model.queryDescriptor.filter == MediaFilter(choices: [.liked]))
        #expect(fixture.model.sidebarSelection.sidebarRow == .people)
        fixture.show(people, scope: .person(fixture.sam))
        #expect(fixture.model.showsBackToPeople)
        #expect(!fixture.model.showsMapAreaLeaf)
        #expect(fixture.model.windowTitle == "Sam")
        #expect(fixture.model.shownPerson?.id == fixture.sam)

        fixture.model.returnToPeople()
        #expect(fixture.model.queryDescriptor.scope == .people)
        #expect(fixture.model.queryDescriptor.filter == MediaFilter(choices: [.liked]))
        await fixture.store.shutdown()
    }

    /// Choosing another sidebar row leaves the person and starts that row unfiltered, so no
    /// back item and no filter follow the user there.
    @Test func anotherRowLeavesThePersonUnfiltered() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        let people = try await fixture.people()
        fixture.show(people, scope: .people)
        fixture.model.openPerson(fixture.sam)
        fixture.model.setPeopleFilter(fixture.sam, included: true)
        fixture.show(people, scope: .person(fixture.sam))

        fixture.model.selectSidebar(.places)

        #expect(fixture.model.queryDescriptor.scope == .places)
        #expect(!fixture.model.queryDescriptor.filter.isActive)
        #expect(!fixture.model.showsBackToPeople)
        #expect(fixture.model.windowTitle != "Sam")
        await fixture.store.shutdown()
    }

    /// The filter offers the people with a name; an unnamed one only while it is checked.
    @Test func theFilterOffersUnnamedPeopleOnlyWhileChecked() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        let unnamed = try #require(try await fixture.store.perform(.moveToNewPerson([fixture.stranger], name: nil)).person)
        let people = try await fixture.people()
        fixture.show(people, scope: .allMedia)
        #expect(fixture.model.peopleFilterControls.people.map(\.id) == [fixture.sam])

        fixture.model.setPeopleFilter(unnamed, included: true)
        #expect(Set(fixture.model.peopleFilterControls.people.map(\.id)) == [fixture.sam, unnamed])
        await fixture.store.shutdown()
    }

    /// A hidden person is seen only in the gallery: their photos close back to it, they do
    /// not open, and the filter lets go of them.
    @Test func aHiddenPersonLeavesTheirPhotosAndTheFilter() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        try await fixture.show(fixture.people(), scope: .people)
        fixture.model.openPerson(fixture.sam)
        fixture.model.setPeopleFilter(fixture.sam, included: true)
        _ = try await fixture.store.perform(.setHidden(fixture.sam, true))

        try await fixture.show(fixture.people(), scope: .person(fixture.sam))

        #expect(fixture.model.queryDescriptor.scope == .people)
        #expect(!fixture.model.queryDescriptor.filter.people.contains(fixture.sam))
        fixture.model.openPerson(fixture.sam)
        #expect(fixture.model.queryDescriptor.scope == .people)
        await fixture.store.shutdown()
    }

    /// The photo menu groups the targets' faces by person (DES-113): Sam's face (guessed in
    /// b.jpg) under `Change to` with everyone else to move it to, then the unidentified face
    /// under `Assign to`, with Sam among the people it may be. Two faces are two submenus,
    /// wherever the photo shows; a photo with one face has its acts at the top level.
    @Test func thePhotoMenuGroupsTheTargetsFacesByPerson() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        let ian = try #require(try await fixture.store.perform(.moveToNewPerson([], name: "Ian")).person)
        let people = try await fixture.people()
        #expect(try await fixture.assignment(of: fixture.like) == .model(fixture.sam))
        let photo = fixture.like.asset
        fixture.show(people, scope: .allMedia, grid: [photo])
        fixture.model.selectAssets([photo])

        let menu = try #require(fixture.model.targetFaceMenu)
        #expect(menu.groups.map(\.title) == ["Sam", "Unidentified Face"])
        #expect(menu.groups[0].faces == [fixture.like])
        #expect(menu.groups[0].listTitle == "Change to")
        #expect(menu.groups[0].list.map(\.title) == ["Ian", "Someone Else…"])
        #expect(menu.groups[0].list.map(\.command) == [.giveTo([fixture.like], ian), .someoneElse([fixture.like])])
        #expect(menu.groups[0].corrections.map(\.title) == ["This Is Not Sam", "This Is Not a Face", "Make Key Photo for Sam"])
        #expect(menu.groups[0].corrections.last?.command == .makeKeyPhoto(fixture.like, fixture.sam))
        #expect(menu.groups[1].listTitle == "Assign to")
        #expect(Set(menu.groups[1].list.map(\.title)) == ["Sam", "Ian", "Someone Else…"])
        #expect(menu.groups[1].list.last?.title == "Someone Else…")
        #expect(menu.groups[1].corrections.map(\.title) == ["This Is Not a Face"])
        #expect(!menu.isFlat)

        // In Sam's photos two faces are still two submenus, in the photo's order.
        fixture.model.openPerson(fixture.sam)
        fixture.show(people, scope: .person(fixture.sam), grid: [photo, fixture.hers.asset])
        fixture.model.selectAssets([photo])
        #expect(fixture.model.targetFaceMenu?.isFlat == false)
        #expect(fixture.model.targetFaceMenu?.groups.map(\.title) == ["Sam", "Unidentified Face"])
        // a.jpg holds only her face: its acts sit at the top level.
        fixture.model.selectAssets([fixture.hers.asset])
        #expect(fixture.model.targetFaceMenu?.isFlat == true)
        await fixture.store.shutdown()
    }

    /// A person without a name is named as a whole (DES-113): their entry counts every photo
    /// of them, `Name This Person` offers the named people to merge them into and `New Name…`,
    /// and nothing asks to correct a grouping the user cannot see — except in their own
    /// photos, which offer `Not the Same Person`. They get no key photo.
    @Test func anUnnamedPersonIsNamedAsAWhole() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        let unnamed = try #require(try await fixture.store.perform(.moveToNewPerson([fixture.stranger], name: nil)).person)
        let photo = fixture.stranger.asset
        let people = try await fixture.people()
        fixture.show(people, scope: .allMedia, grid: [photo])
        fixture.model.selectAssets([photo])

        let group = try #require(fixture.model.targetFaceMenu?.groups.first { $0.person == unnamed })
        #expect(group.title == "Unnamed Person · 1 Photo")
        #expect(group.kind == .unnamed)
        #expect(group.listTitle == "Name This Person")
        #expect(group.list.map(\.command) == [.nameAs(unnamed, fixture.sam), .addName(unnamed)])
        #expect(group.list.map(\.title) == ["Sam", "New Name…"])
        #expect(group.corrections.map(\.title) == ["This Is Not a Face"])

        fixture.model.performMediaItemCommand(.nameAs(unnamed, fixture.sam))
        #expect(fixture.model.peopleSession.mergeQuestion == PeopleMergeQuestion(from: unnamed, into: fixture.sam))
        fixture.model.answerMerge(false)
        fixture.model.performMediaItemCommand(.addName(unnamed))
        #expect(fixture.model.peopleSession.sheet?.subject == .person(unnamed))
        fixture.model.cancelPersonSheet()

        fixture.model.openPerson(unnamed)
        fixture.show(people, scope: .person(unnamed), grid: [photo])
        fixture.model.selectAssets([photo])
        let own = try #require(fixture.model.targetFaceMenu)
        let theirs = try #require(own.groups.first { $0.person == unnamed })
        #expect(theirs.corrections.map(\.title) == ["Not the Same Person", "This Is Not a Face"])
        await fixture.store.shutdown()
    }

    /// With several photos, an entry counts the photos it changes, and Make Key Photo is
    /// gone. Unidentified faces are offered only while no photo holds more than one, so no
    /// act has to pick a face; with one photo, each unidentified face is its own entry.
    @Test func severalPhotosCountAndOfferOnlyUnambiguousFaces() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        let first = fixture.hers.asset
        let second = fixture.like.asset
        try await fixture.show(fixture.people(), scope: .allMedia, grid: [first, second])
        fixture.model.selectAssets([first, second])

        let menu = try #require(fixture.model.targetFaceMenu)
        #expect(menu.groups.map(\.title) == ["Sam · 2 Photos", "Unidentified Face · 1 Photo"])
        #expect(!menu.groups[0].corrections.contains { $0.title.hasPrefix("Make Key Photo") })

        // b.jpg's faces are each not Sam: assignment gives her the other face once one is
        // held, so both are held, and b.jpg holds two unidentified faces.
        _ = try await fixture.store.perform(.removeName([fixture.like]))
        _ = try await fixture.people()
        _ = try await fixture.store.perform(.removeName([fixture.stranger]))
        try await fixture.show(fixture.people(), scope: .allMedia, grid: [first, second])
        #expect(try await fixture.assignment(of: fixture.like) == .held)
        #expect(try await fixture.assignment(of: fixture.stranger) == .held)
        fixture.model.selectAssets([first, second])
        #expect(fixture.model.targetFaceMenu?.groups.map(\.title) == ["Sam · 1 Photo"])
        fixture.model.selectAssets([second])
        let one = try #require(fixture.model.targetFaceMenu)
        #expect(one.groups.map(\.title) == ["Unidentified Face", "Unidentified Face"])
        #expect(one.groups.map(\.faces) == [[fixture.like], [fixture.stranger]])
        await fixture.store.shutdown()
    }

    /// The Person sheet says who it names and how many photos Save changes, and suggests the
    /// people who already have a name.
    @Test func thePersonSheetSaysWhoAndHowMany() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        let unnamed = try #require(try await fixture.store.perform(.moveToNewPerson([fixture.stranger], name: nil)).person)
        try await fixture.show(fixture.people(), scope: .allMedia)

        let person = fixture.model.personSheetContext(PersonSheetRequest(subject: .person(unnamed)))
        #expect(person.title == "Name This Person")
        #expect(person.media == MediaCount(photos: 1))
        #expect(person.faces.map(\.id) == [fixture.stranger])
        #expect(person.names == ["Sam"])

        let faces = fixture.model.personSheetContext(PersonSheetRequest(subject: .faces([fixture.like])))
        #expect(faces.title == "Name This Face")
        #expect(faces.media == MediaCount(photos: 1))
        #expect(faces.faces.map(\.id) == [fixture.like])

        let sam = fixture.model.personSheetContext(PersonSheetRequest(subject: .person(fixture.sam)))
        #expect(sam.title == "Sam")
        #expect(sam.names.isEmpty)
        await fixture.store.shutdown()
    }

    /// The outlined faces are the view model's: by photo, each face's box, so every surface
    /// showing the photo draws them; empty clears (DES-113).
    @Test func outlinedFacesAreGroupedByPhoto() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        let people = try await fixture.people()
        let photo = fixture.like.asset
        fixture.show(people, scope: .allMedia, grid: [photo])
        let box = try #require(people.photoFaces[photo]?.first { $0.id == fixture.like }?.tile.box)

        fixture.model.outlineFaces([fixture.like])
        #expect(fixture.model.outlinedFaceBoxes == [photo: [box]])
        fixture.model.outlineFaces([])
        #expect(fixture.model.outlinedFaceBoxes.isEmpty)
        await fixture.store.shutdown()
    }

    /// Saving the Person sheet with a name another person has asks whether they are the same
    /// person; Merge merges them. Someone Else… with a taken name gives the faces to that
    /// person.
    @Test func aTakenNameAsksToMerge() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        let other = try #require(try await fixture.store.perform(.moveToNewPerson([fixture.stranger], name: nil)).person)
        try await fixture.show(fixture.people(), scope: .people)

        fixture.model.beginEditingPerson(other)
        fixture.model.savePersonSheet(.person(other), name: "Sam", birthday: nil)
        #expect(fixture.model.peopleSession.mergeQuestion == PeopleMergeQuestion(from: other, into: fixture.sam))
        fixture.model.answerMerge(true)
        try await Self.waitForStore(fixture.store) { try await fixture.assignment(of: fixture.stranger) == .user(fixture.sam) }

        try await fixture.show(fixture.people(), scope: .people)
        fixture.model.performMediaItemCommand(.someoneElse([fixture.like]))
        #expect(fixture.model.peopleSession.sheet?.subject == .faces([fixture.like]))
        // b.jpg already holds Sam's face: Save is disabled with the reason (DES-038), and
        // pressing it anyway changes nothing and keeps the sheet.
        #expect(fixture.model.personSheetRefusal(.faces([fixture.like]), name: "Sam", birthday: nil) == "Sam is already in this photo")
        fixture.model.savePersonSheet(.faces([fixture.like]), name: "Sam", birthday: nil)
        #expect(fixture.model.peopleSession.sheet?.subject == .faces([fixture.like]))
        #expect(try await fixture.assignment(of: fixture.like) != .user(fixture.sam))
        await fixture.store.shutdown()
    }

    /// A hidden person has no act but Unhide (DES-111): it is merged neither away nor into,
    /// however the merge is asked for — a drag, Merge Into or a taken name — and its cell is
    /// not draggable. Unhidden, it merges again.
    @Test func aHiddenPersonIsNeitherMergedAwayNorInto() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        let ian = try #require(try await fixture.store.perform(.moveToNewPerson([fixture.stranger], name: "Ian")).person)
        _ = try await fixture.store.perform(.setHidden(ian, true))
        try await fixture.show(fixture.people(), scope: .people)

        let actions = fixture.model.peopleActions
        #expect(!actions.canMergeAway(ian))
        #expect(actions.canMergeAway(fixture.sam))
        #expect(actions.mergeRefusal(ian, fixture.sam) == "Ian is a hidden person")
        #expect(actions.mergeRefusal(fixture.sam, ian) == "Ian is a hidden person")
        actions.askMerge(ian, fixture.sam)
        #expect(fixture.model.peopleSession.mergeQuestion == nil)
        actions.askMerge(fixture.sam, ian)
        #expect(fixture.model.peopleSession.mergeQuestion == nil)

        _ = try await fixture.store.perform(.setHidden(ian, false))
        try await fixture.show(fixture.people(), scope: .people)
        #expect(fixture.model.peopleActions.canMergeAway(ian))
        fixture.model.peopleActions.askMerge(ian, fixture.sam)
        #expect(fixture.model.peopleSession.mergeQuestion == PeopleMergeQuestion(from: ian, into: fixture.sam))
        await fixture.store.shutdown()
    }

    /// A taken name whose merge the hard rules refuse disables Save with the merge's reason,
    /// rather than closing the sheet with nothing done; a hidden person's name is refused,
    /// since no surface but the gallery offers them; a name with another birthday for
    /// `Someone Else…` asks for the birthday to be cleared.
    @Test func aSheetSaveThatCannotHappenIsDisabledWithItsReason() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        _ = try await fixture.store.perform(.move([fixture.like], to: fixture.sam))
        let other = try #require(try await fixture.store.perform(.moveToNewPerson([fixture.stranger], name: nil)).person)
        let ian = try #require(try await fixture.store.perform(.moveToNewPerson([], name: "Ian")).person)
        _ = try await fixture.store.perform(.setHidden(ian, true))
        try await fixture.show(fixture.people(), scope: .people)

        let refusal = try #require(fixture.model.mergeRefusal(other, into: fixture.sam))
        #expect(fixture.model.personSheetRefusal(.person(other), name: "Sam", birthday: nil) == refusal)
        fixture.model.beginEditingPerson(other)
        fixture.model.savePersonSheet(.person(other), name: "Sam", birthday: nil)
        #expect(fixture.model.peopleSession.mergeQuestion == nil)
        #expect(fixture.model.peopleSession.sheet?.subject == .person(other))

        #expect(fixture.model.personSheetRefusal(.person(other), name: "Ian", birthday: nil) == "Ian is a hidden person")
        #expect(fixture.model.personSheetRefusal(.faces([fixture.hers]), name: "Ian", birthday: nil) == "Ian is a hidden person")
        #expect(fixture.model.personSheetRefusal(.faces([fixture.hers]), name: "Sam", birthday: "1990") == "Clear the birthday to give these faces to Sam")
        #expect(fixture.model.personSheetRefusal(.faces([fixture.hers]), name: "Kai", birthday: "1990") == nil)
        await fixture.store.shutdown()
    }

    /// `Someone Else…` with a new name and a birthday makes one person with both, in one act:
    /// one undo takes the person away and gives the face back.
    @Test func someoneElseKeepsTheBirthdayTyped() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        try await fixture.show(fixture.people(), scope: .allMedia)

        fixture.model.beginNamingFaces([fixture.stranger])
        fixture.model.savePersonSheet(.faces([fixture.stranger]), name: "Kai", birthday: "1990")
        try await Self.waitForStore(fixture.store) {
            try await fixture.store.peopleSnapshot().people.contains { $0.name == "Kai" }
        }
        let kai = try #require(try await fixture.store.peopleSnapshot().people.first { $0.name == "Kai" })
        #expect(kai.birthday == PersonBirthday("1990"))
        #expect(try await fixture.assignment(of: fixture.stranger) == .user(kai.id))
        try await Self.waitForUndo(fixture.model, title: "Undo Name 1 Photo")

        fixture.model.undoLastChange()
        try await Self.waitForStore(fixture.store) {
            try await !fixture.store.peopleSnapshot().people.contains { $0.name == "Kai" }
        }
        #expect(try await fixture.assignment(of: fixture.stranger)?.isGuessable == true)
        await fixture.store.shutdown()
    }

    /// Assign to ▸ Ian on the unidentified face: the undo item names the act and the photos
    /// it changed; undo writes the face back as it was, redo gives it to him again.
    @Test func undoAndRedoAnAct() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        let ian = try #require(try await fixture.store.perform(.moveToNewPerson([], name: "Ian")).person)
        try await fixture.show(fixture.people(), scope: .allMedia)

        fixture.model.nameFaces([fixture.stranger], as: ian)
        try await Self.waitForStore(fixture.store) { try await fixture.assignment(of: fixture.stranger) == .user(ian) }
        try await Self.waitForUndo(fixture.model, title: "Undo Name 1 Photo")

        fixture.model.undoLastChange()
        try await Self.waitForStore(fixture.store) { try await fixture.assignment(of: fixture.stranger)?.isGuessable == true }
        fixture.model.redoLastChange()
        try await Self.waitForStore(fixture.store) { try await fixture.assignment(of: fixture.stranger) == .user(ian) }
        await fixture.store.shutdown()
    }

    /// Merge answered while an act ahead of it in the People stream is unpublished: the
    /// question was judged when asked, so the answer submits the merge and the store, applying
    /// it after that act, judges it — here This Is Not Sam frees the photo both shared, and
    /// the merge lands though the published state still refuses it. What the window does with
    /// the merged people waits for the store's confirmation.
    @Test func aMergeAnsweredBeforeTheActAheadOfItPublishesIsJudgedByTheStore() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        let other = try #require(try await fixture.store.perform(.moveToNewPerson([fixture.stranger], name: nil)).person)
        _ = try await fixture.store.perform(.move([fixture.like], to: fixture.sam))
        try await fixture.show(fixture.people(), scope: .people)
        #expect(fixture.model.mergeRefusal(other, into: fixture.sam) != nil)
        fixture.model.setPeopleFilter(other, included: true)

        fixture.model.removeNames([fixture.like])
        // The question as asked against the state the act ahead of it changes; no People
        // state publishes before the answer.
        fixture.model.peopleSession.mergeQuestion = PeopleMergeQuestion(from: other, into: fixture.sam)
        fixture.model.answerMerge(true)
        #expect(fixture.model.queryDescriptor.filter.people == [other])

        try await Self.waitForStore(fixture.store) { try await fixture.assignment(of: fixture.stranger) == .user(fixture.sam) }
        try await Self.waitForUndo(fixture.model, title: "Undo Merge")
        #expect(fixture.model.queryDescriptor.filter.people == [fixture.sam])
        #expect(fixture.model.peopleSession.selectedPeople == [fixture.sam])
        #expect(fixture.model.peopleSession.mergeRefusal == nil)
        await fixture.store.shutdown()
    }

    /// A merge the store refuses when it applies it says why, in the words the disabled act
    /// uses (DES-038), and the window keeps showing and filtering the person it would have
    /// merged away.
    @Test func aMergeTheStoreRefusesSaysWhyAndMovesNothing() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        let other = try #require(try await fixture.store.perform(.moveToNewPerson([fixture.stranger], name: nil)).person)
        _ = try await fixture.store.perform(.move([fixture.like], to: fixture.sam))
        let people = try await fixture.people()
        fixture.show(people, scope: .people)
        fixture.model.openPerson(other)
        fixture.show(people, scope: .person(other))
        fixture.model.setPeopleFilter(other, included: true)

        fixture.model.peopleSession.mergeQuestion = PeopleMergeQuestion(from: other, into: fixture.sam)
        fixture.model.answerMerge(true)
        try await Self.waitForMergeRefusal(fixture.model)

        #expect(fixture.model.peopleSession.mergeRefusal?.reason == "Unnamed Person and Sam are both in 1 photo")
        #expect(fixture.model.queryDescriptor.scope == .person(other))
        #expect(fixture.model.queryDescriptor.filter.people == [other])
        #expect(try await fixture.assignment(of: fixture.stranger) == .user(other))
        fixture.model.dismissMergeRefusal()
        #expect(fixture.model.peopleSession.mergeRefusal == nil)
        await fixture.store.shutdown()
    }

    /// The People state a merge publishes can reach the window while the store's answer is
    /// still on its way: the store commits the merge and rings the projection before its
    /// await returns. Delivered at exactly that suspension, a state that no longer lists the
    /// person merged away leaves the window showing and filtering them; the store's
    /// confirmation then takes the window to the person it names, merged into.
    @Test func aPeopleStateBeforeTheMergesConfirmationLeavesTheWindowToIt() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory(), consumesIntents: false)
        let other = try #require(try await fixture.store.perform(.moveToNewPerson([fixture.stranger], name: nil)).person)
        let people = try await fixture.people()
        fixture.show(people, scope: .people)
        fixture.model.openPerson(other)
        fixture.show(people, scope: .person(other))
        fixture.model.setPeopleFilter(other, included: true)
        var intents = fixture.model.peopleIntentStream.makeAsyncIterator()

        fixture.model.askMerge(other, into: fixture.sam)
        try #require(fixture.model.peopleSession.mergeQuestion != nil)
        fixture.model.answerMerge(true)
        let merge = try #require(await intents.next())
        let answer = await CatalogWindowViewModel.runPeopleIntent(merge, store: fixture.store)
        let merged = try await fixture.people()
        #expect(merged.person(other) == nil)
        fixture.show(merged, scope: .person(other))
        #expect(fixture.model.queryDescriptor.scope == .person(other))
        #expect(fixture.model.queryDescriptor.filter.people == [other])

        fixture.model.applyPeopleIntentEvent(answer)
        #expect(fixture.model.queryDescriptor.scope == .person(fixture.sam))
        #expect(fixture.model.queryDescriptor.filter.people == [fixture.sam])
        #expect(fixture.model.peopleSession.selectedPeople == [fixture.sam])
        fixture.show(merged, scope: .person(fixture.sam))
        #expect(fixture.model.queryDescriptor.scope == .person(fixture.sam))
        #expect(fixture.model.windowTitle == "Sam")
        await fixture.store.shutdown()
    }

    /// A redo of a merge is that merge: with the window on the person it merges away, a People
    /// state that no longer lists them, arriving before the redo's answer, leaves the window
    /// to it, and the answer takes the window to the person merged into, as the merge's own
    /// confirmation does.
    @Test func aRedoneMergeTakesTheWindowToThePersonMergedInto() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory(), consumesIntents: false)
        let other = try #require(try await fixture.store.perform(.moveToNewPerson([fixture.stranger], name: nil)).person)
        try await fixture.show(fixture.people(), scope: .people)
        var intents = fixture.model.peopleIntentStream.makeAsyncIterator()
        fixture.model.askMerge(other, into: fixture.sam)
        fixture.model.answerMerge(true)
        let merge = try #require(await intents.next())
        await fixture.model.applyPeopleIntentEvent(CatalogWindowViewModel.runPeopleIntent(merge, store: fixture.store))
        try await Self.waitForUndo(fixture.model, title: "Undo Merge")

        fixture.model.undoLastChange()
        let undo = try #require(await intents.next())
        await fixture.model.applyPeopleIntentEvent(CatalogWindowViewModel.runPeopleIntent(undo, store: fixture.store))
        let unmerged = try await fixture.people()
        #expect(unmerged.person(other) != nil)
        fixture.show(unmerged, scope: .people)
        fixture.model.openPerson(other)
        fixture.show(unmerged, scope: .person(other))
        fixture.model.setPeopleFilter(other, included: true)

        fixture.model.redoLastChange()
        let redo = try #require(await intents.next())
        let answer = await CatalogWindowViewModel.runPeopleIntent(redo, store: fixture.store)
        let merged = try await fixture.people()
        #expect(merged.person(other) == nil)
        fixture.show(merged, scope: .person(other))
        #expect(fixture.model.queryDescriptor.scope == .person(other))
        #expect(fixture.model.queryDescriptor.filter.people == [other])

        fixture.model.applyPeopleIntentEvent(answer)
        #expect(fixture.model.queryDescriptor.scope == .person(fixture.sam))
        #expect(fixture.model.queryDescriptor.filter.people == [fixture.sam])
        #expect(fixture.model.peopleSession.selectedPeople == [fixture.sam])
        #expect(fixture.model.undoMenuState.undoTitle == "Undo Merge")
        await fixture.store.shutdown()
    }

    /// A merge the store refuses hands the person it would have merged away back to the
    /// published state: here they were hidden while the merge was on its way, so its refusal
    /// returns the window to the gallery and the filter lets go of them.
    @Test func aRefusedMergeHandsThePersonBackToThePublishedState() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory(), consumesIntents: false)
        let other = try #require(try await fixture.store.perform(.moveToNewPerson([fixture.stranger], name: nil)).person)
        _ = try await fixture.store.perform(.move([fixture.like], to: fixture.sam))
        let people = try await fixture.people()
        fixture.show(people, scope: .people)
        fixture.model.openPerson(other)
        fixture.show(people, scope: .person(other))
        fixture.model.setPeopleFilter(other, included: true)
        var intents = fixture.model.peopleIntentStream.makeAsyncIterator()

        fixture.model.peopleSession.mergeQuestion = PeopleMergeQuestion(from: other, into: fixture.sam)
        fixture.model.answerMerge(true)
        let merge = try #require(await intents.next())
        let answer = await CatalogWindowViewModel.runPeopleIntent(merge, store: fixture.store)
        _ = try await fixture.store.perform(.setHidden(other, true))
        try await fixture.show(fixture.people(), scope: .person(other))
        #expect(fixture.model.queryDescriptor.scope == .person(other))

        fixture.model.applyPeopleIntentEvent(answer)
        #expect(fixture.model.peopleSession.mergeRefusal?.reason == "Unnamed Person and Sam are both in 1 photo")
        #expect(fixture.model.queryDescriptor.scope == .people)
        #expect(fixture.model.queryDescriptor.filter.people.isEmpty)
        await fixture.store.shutdown()
    }

    /// Two acts undone in turn redo in turn: redoing the first keeps the second on the redo
    /// stack (APP-039), so both come back.
    @Test func redoingOneOfTwoUndoneActsKeepsTheOther() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        let ian = try #require(try await fixture.store.perform(.moveToNewPerson([], name: "Ian")).person)
        try await fixture.show(fixture.people(), scope: .allMedia)

        fixture.model.nameFaces([fixture.stranger], as: ian)
        try await Self.waitForUndo(fixture.model, title: "Undo Name 1 Photo")
        fixture.model.setFavorite(fixture.sam, true)
        try await Self.waitForUndo(fixture.model, title: "Undo Add to Favorites")

        fixture.model.undoLastChange()
        fixture.model.undoLastChange()
        try await Self.waitForStore(fixture.store) {
            let sam = try await fixture.store.peopleSnapshot().people.first { $0.id == fixture.sam }
            let assignment = try await fixture.assignment(of: fixture.stranger)
            return sam?.isFavorite == false && assignment?.isGuessable == true
        }
        // Redo the first and let it land, its undo filed, before asking for the second.
        fixture.model.redoLastChange()
        try await Self.waitForStore(fixture.store) { try await fixture.assignment(of: fixture.stranger) == .user(ian) }
        try await Self.waitForUndo(fixture.model, title: "Undo Name 1 Photo")
        #expect(fixture.model.undoMenuState.redoTitle == "Redo Add to Favorites")
        fixture.model.redoLastChange()
        try await Self.waitForStore(fixture.store) {
            let sam = try await fixture.store.peopleSnapshot().people.first { $0.id == fixture.sam }
            let assignment = try await fixture.assignment(of: fixture.stranger)
            return sam?.isFavorite == true && assignment == .user(ian)
        }
        await fixture.store.shutdown()
    }

    /// Redo returns the catalog to the state an act left: a person `Someone Else…` created,
    /// undone away, comes back under the same ID, so a later act that named them redoes too.
    @Test func aRedonePersonKeepsTheirLaterActs() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        try await fixture.show(fixture.people(), scope: .allMedia)

        fixture.model.savePersonSheet(.faces([fixture.stranger]), name: "Kai", birthday: nil)
        try await Self.waitForStore(fixture.store) {
            try await fixture.store.peopleSnapshot().people.contains { $0.name == "Kai" }
        }
        let kai = try #require(try await fixture.store.peopleSnapshot().people.first { $0.name == "Kai" }?.id)
        try await Self.waitForUndo(fixture.model, title: "Undo Name 1 Photo")
        try await fixture.show(fixture.people(), scope: .allMedia)
        fixture.model.setFavorite(kai, true)
        try await Self.waitForUndo(fixture.model, title: "Undo Add to Favorites")

        fixture.model.undoLastChange()
        fixture.model.undoLastChange()
        try await Self.waitForStore(fixture.store) {
            try await !fixture.store.peopleSnapshot().people.contains { $0.id == kai }
        }
        fixture.model.redoLastChange()
        try await Self.waitForStore(fixture.store) { try await fixture.assignment(of: fixture.stranger) == .user(kai) }
        try await Self.waitForUndo(fixture.model, title: "Undo Name 1 Photo")
        fixture.model.redoLastChange()
        try await Self.waitForStore(fixture.store) {
            try await fixture.store.peopleSnapshot().people.first { $0.id == kai }?.isFavorite == true
        }
        #expect(try await fixture.store.peopleSnapshot().people.first { $0.id == kai }?.name == "Kai")
        await fixture.store.shutdown()
    }

    /// The Info pane's People section says `No Faces` only for a photo the catalog read and
    /// holds none of, `Not Checked Yet` for one not read, and `—` for what it cannot know:
    /// several photos with none listed. A photo read while it is shown says so without being
    /// reselected, once the People state its read publishes arrives.
    @Test func theInfoPanesFacesLineIsTheCatalogsFact() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory(), others: ["c.jpg", "d.jpg"])
        try await fixture.library.readFaces([fixture.library.result(for: "c.jpg", faces: [])])
        let read = fixture.library.id("c.jpg")
        let unread = fixture.library.id("d.jpg")
        try await fixture.show(fixture.people(), scope: .allMedia, grid: [fixture.hers.asset, read, unread])
        fixture.model.startFacesReadRefresh()
        fixture.model.toggleInspector(.info)

        fixture.model.selectAssets([read])
        try await Self.waitForFacesLine(fixture.model, "No Faces")
        fixture.model.selectAssets([unread])
        try await Self.waitForFacesLine(fixture.model, "Not Checked Yet")
        fixture.model.selectAssets([read, unread])
        #expect(fixture.model.targetFacesLine == PhotoInfo.notApplicable)

        fixture.model.selectAssets([unread])
        try await Self.waitForFacesLine(fixture.model, "Not Checked Yet")
        try await fixture.library.readFaces([fixture.library.result(for: "d.jpg", faces: [])])
        try await fixture.show(fixture.people(), scope: .allMedia, grid: [fixture.hers.asset, read, unread])
        try await Self.waitForFacesLine(fixture.model, "No Faces")
        await fixture.store.shutdown()
    }

    /// An Info row's outline belongs to the targets and the pane: another photo, or the pane
    /// hidden, lets go of it, though the pointer that set it reported no exit.
    @Test func anInfoRowsOutlineEndsWithItsTarget() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        try await fixture.show(fixture.people(), scope: .allMedia, grid: [fixture.hers.asset, fixture.like.asset])
        fixture.model.toggleInspector(.info)
        fixture.model.selectAssets([fixture.like.asset])

        fixture.model.outlineFaces([fixture.like])
        fixture.model.selectAssets([fixture.hers.asset])
        #expect(fixture.model.outlinedFaces.isEmpty)

        fixture.model.outlineFaces([fixture.hers])
        fixture.model.toggleInspector(.info)
        #expect(fixture.model.outlinedFaces.isEmpty)
        await fixture.store.shutdown()
    }

    /// An unidentified face offers its likely people as Info buttons only once ranked, so no
    /// button names a person only gallery order put there.
    @Test func suggestionsWaitForTheRanking() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        let ian = try #require(try await fixture.store.perform(.moveToNewPerson([], name: "Ian")).person)
        let photo = fixture.stranger.asset
        try await fixture.show(fixture.people(), scope: .allMedia, grid: [photo])
        fixture.model.selectAssets([photo])

        let unranked = try #require(fixture.model.targetFaceMenu?.groups.first { $0.kind == .unidentified })
        #expect(unranked.suggestions == nil)
        #expect(unranked.list.map(\.title).contains("Ian"))

        fixture.model.faceCandidates = FaceCandidates(photos: [photo], candidates: [
            fixture.like: [FaceCandidate(person: ian, similarity: 0.5)],
            fixture.stranger: [FaceCandidate(person: ian, similarity: 0.9)],
        ])
        let ranked = try #require(fixture.model.targetFaceMenu?.groups.first { $0.kind == .unidentified })
        #expect(ranked.suggestions?.map(\.title) == ["Ian"])
        #expect(ranked.suggestions?.map(\.command) == [.giveTo([fixture.stranger], ian)])
        await fixture.store.shutdown()
    }

    /// Up and Down keep the column inside each section's own rows, crossing the Hidden header
    /// into the next section's first row or the previous one's last.
    @Test func theArrowKeysKeepTheColumnAcrossTheHiddenHeader() {
        let people = (1 ... 7).map { PersonID(rawValue: Int64($0)) }
        // Three columns: visible 1 2 3 / 4 5; hidden 6 7.
        let sections = [Array(people[0 ..< 5]), Array(people[5 ..< 7])]
        func step(_ from: Int64?, _ key: PeopleGalleryStep) -> Int64? {
            key.target(from: from.map { PersonID(rawValue: $0) }, columns: 3, sections: sections)?.rawValue
        }
        #expect(step(nil, .down) == 1)
        #expect(step(2, .down) == 5)
        #expect(step(3, .down) == 5)
        #expect(step(5, .down) == 7)
        #expect(step(4, .down) == 6)
        #expect(step(7, .down) == 7)
        #expect(step(6, .up) == 4)
        #expect(step(7, .up) == 5)
        #expect(step(5, .up) == 2)
        #expect(step(1, .up) == 1)
        #expect(step(5, .right) == 6)
        #expect(step(6, .left) == 5)
        #expect(PeopleGalleryStep.down.target(from: nil, columns: 3, sections: []) == nil)
    }

    /// The gallery's context menu, the menu bar's person items and VoiceOver's actions are one
    /// value: the selected person's settings, Merge Into the other selected people, Hide and
    /// Show Photos; a hidden person's is Unhide alone. The toolbar's Merge Into offers only
    /// named people.
    @Test func everySurfaceOffersAPersonsActsFromOneMenu() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        let unnamed = try #require(try await fixture.store.perform(.moveToNewPerson([fixture.stranger], name: nil)).person)
        let ian = try #require(try await fixture.store.perform(.moveToNewPerson([], name: "Ian")).person)
        _ = try await fixture.store.perform(.setHidden(ian, true))
        try await fixture.show(fixture.people(), scope: .people)

        #expect(fixture.model.galleryActingPersonMenu == .unavailable)
        fixture.model.selectPeople(fixture.sam, modifiers: [])
        fixture.model.selectPeople(unnamed, modifiers: .command)
        let menu = fixture.model.galleryActingPersonMenu
        #expect(menu.settings.map(\.title) == ["Add Name…", "Set Birthday…", "Add to Favorites"])
        #expect(menu.mergeInto?.map(\.act) == [.mergeInto(fixture.sam)])
        #expect(menu.visibility.title == "Hide")
        #expect(menu.open?.title == "Show Photos")
        #expect(menu.accessibilityItems.map(\.title).contains("Merge Into Sam"))

        fixture.model.performGalleryPersonAct(.mergeInto(fixture.sam))
        #expect(fixture.model.peopleSession.mergeQuestion == PeopleMergeQuestion(from: unnamed, into: fixture.sam))
        fixture.model.answerMerge(false)

        let hidden = try #require(fixture.model.galleryPersonMenu(ian))
        #expect(hidden.settings.isEmpty)
        #expect(hidden.mergeInto == nil)
        #expect(hidden.visibility.act == .setHidden(false))
        #expect(hidden.accessibilityItems.map(\.title) == ["Unhide"])

        fixture.model.openPerson(unnamed)
        try await fixture.show(fixture.people(), scope: .person(unnamed))
        #expect(fixture.model.shownPersonMenu?.mergeInto?.map(\.act) == [.mergeInto(fixture.sam)])
        #expect(fixture.model.shownPersonMenu?.open == nil)
        await fixture.store.shutdown()
    }

    /// This Is Not Sam: the face loses her and Otos never gives it to her again; the undo
    /// item says so in the menu's words.
    @Test func notThisPersonHoldsTheFace() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        try await fixture.show(fixture.people(), scope: .allMedia)
        #expect(try await fixture.assignment(of: fixture.like) == .model(fixture.sam))

        fixture.model.performMediaItemCommand(.notPerson([fixture.like]))
        try await Self.waitForStore(fixture.store) { try await fixture.assignment(of: fixture.like) == .held }
        try await Self.waitForUndo(fixture.model, title: "Undo This Is Not Sam")
        _ = try await fixture.people()
        #expect(try await fixture.assignment(of: fixture.like) == .held)
        await fixture.store.shutdown()
    }

    /// A video's face is counted as a video's (APP-072): her person holds two photos and a
    /// video, a menu over a photo and the video says `Photos & Videos`, the video's face offers
    /// no Make Key Photo, and it is never outlined, its box being one frame's.
    @Test func aVideosFaceCountsAsAVideoAndIsNoKeyPhoto() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory(), withVideo: true)
        let people = try await fixture.people()
        #expect(try await fixture.assignment(of: fixture.inVideo) == .model(fixture.sam))
        #expect(people.person(fixture.sam)?.media == MediaCount(photos: 2, videos: 1))
        let video = fixture.inVideo.asset
        fixture.show(people, scope: .allMedia, grid: [fixture.hers.asset, video])

        fixture.model.selectAssets([video])
        let menu = try #require(fixture.model.targetFaceMenu)
        #expect(menu.groups.map(\.title) == ["Sam"])
        #expect(menu.groups[0].corrections.map(\.title) == ["This Is Not Sam", "This Is Not a Face"])

        fixture.model.selectAssets([fixture.hers.asset, video])
        #expect(fixture.model.targetFaceMenu?.groups.first?.title == "Sam · 2 Photos & Videos")

        fixture.model.outlineFaces([fixture.hers, fixture.inVideo])
        #expect(fixture.model.outlinedFaceBoxes.keys.sorted { $0.relativePath.rawValue < $1.relativePath.rawValue } == [fixture.hers.asset])
        await fixture.store.shutdown()
    }

    /// Waits for the catalog to satisfy `condition`; no deadline (a value that never comes
    /// is a hang `check.sh` names).
    static func waitForStore(_ store: CatalogStore, _ condition: () async throws -> Bool) async throws {
        var changes = await store.changeNotifications().makeAsyncIterator()
        while try await !condition() {
            guard await changes.next() != nil else { return }
        }
    }

    /// Waits for the Info pane's People line to read `line`.
    static func waitForFacesLine(_ model: CatalogWindowViewModel, _ line: String) async throws {
        let lines = Observations { @MainActor [weak model] in
            model?.targetFacesLine
        }
        for await value in lines where value == line {
            return
        }
    }

    /// Waits for a refused merge to be reported.
    static func waitForMergeRefusal(_ model: CatalogWindowViewModel) async throws {
        let refusals = Observations { @MainActor [weak model] in
            model?.peopleSession.mergeRefusal
        }
        for await refusal in refusals where refusal != nil {
            return
        }
    }

    /// Waits for the window's Undo item to read `title`.
    static func waitForUndo(_ model: CatalogWindowViewModel, title: String) async throws {
        let states = Observations { @MainActor [weak model] in
            model?.undoMenuState
        }
        for await state in states {
            if state?.undoTitle == title {
                return
            }
        }
    }
}
