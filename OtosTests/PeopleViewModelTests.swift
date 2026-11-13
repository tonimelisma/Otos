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

        static func make(in directory: URL, withVideo: Bool = false) async throws -> Fixture {
            let library = try await FaceEnrichmentTests.ScannedLibrary.make(
                in: directory, files: ["a.jpg", "b.jpg"] + (withVideo ? ["clip.mov"] : [])
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
            model.startPeopleIntentConsumer()
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

        let menu = try #require(fixture.model.faceMenu())
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
        #expect(fixture.model.faceMenu()?.isFlat == false)
        #expect(fixture.model.faceMenu()?.groups.map(\.title) == ["Sam", "Unidentified Face"])
        // a.jpg holds only her face: its acts sit at the top level.
        fixture.model.selectAssets([fixture.hers.asset])
        #expect(fixture.model.faceMenu()?.isFlat == true)
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

        let group = try #require(fixture.model.faceMenu()?.groups.first { $0.person == unnamed })
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
        let own = try #require(fixture.model.faceMenu())
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

        let menu = try #require(fixture.model.faceMenu())
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
        #expect(fixture.model.faceMenu()?.groups.map(\.title) == ["Sam · 1 Photo"])
        fixture.model.selectAssets([second])
        let one = try #require(fixture.model.faceMenu())
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
        fixture.model.savePersonSheet(.faces([fixture.like]), name: "Sam", birthday: nil)
        // b.jpg already holds Sam's face: the store refuses, and nothing changes.
        #expect(try await fixture.assignment(of: fixture.like) != .user(fixture.sam))
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
        let menu = try #require(fixture.model.faceMenu())
        #expect(menu.groups.map(\.title) == ["Sam"])
        #expect(menu.groups[0].corrections.map(\.title) == ["This Is Not Sam", "This Is Not a Face"])

        fixture.model.selectAssets([fixture.hers.asset, video])
        #expect(fixture.model.faceMenu()?.groups.first?.title == "Sam · 2 Photos & Videos")

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
