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

        static func make(in directory: URL) async throws -> Fixture {
            let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: directory, files: ["a.jpg", "b.jpg"])
            try await library.store.applyEnrichmentBatch([
                library.result(for: "a.jpg", faces: [PeopleStoreTests.face(x: 0.1)]),
                library.result(for: "b.jpg", faces: [PeopleStoreTests.face(x: 0.1), PeopleStoreTests.face(x: 0.65)]),
            ])
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

    /// A person's photos are every library with the People filter on them, titled with the
    /// name and with Back to People, which clears the filter it set.
    @Test func openingAPersonFiltersEveryLibraryToThem() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        let people = try await fixture.people()
        fixture.show(people, scope: .people)

        fixture.model.openPerson(fixture.sam)
        #expect(fixture.model.queryDescriptor.scope == .allMedia)
        #expect(fixture.model.queryDescriptor.filter.people == [fixture.sam])
        fixture.show(people, scope: .allMedia)
        #expect(fixture.model.showsBackToPeople)
        #expect(fixture.model.windowTitle == "Sam")
        #expect(fixture.model.shownPerson?.id == fixture.sam)

        fixture.model.returnToPeople()
        #expect(fixture.model.queryDescriptor.scope == .people)
        #expect(!fixture.model.queryDescriptor.filter.filtersPeople)
        await fixture.store.shutdown()
    }

    /// A hidden person is seen only in the gallery: their photos do not open, and the
    /// filter lets go of them.
    @Test func aHiddenPersonLeavesTheFilter() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        try await fixture.show(fixture.people(), scope: .people)
        fixture.model.openPerson(fixture.sam)
        _ = try await fixture.store.perform(.setHidden(fixture.sam, true))

        try await fixture.show(fixture.people(), scope: .allMedia)

        #expect(!fixture.model.queryDescriptor.filter.people.contains(fixture.sam))
        fixture.model.returnToPeople()
        fixture.model.openPerson(fixture.sam)
        #expect(fixture.model.queryDescriptor.scope == .people)
        await fixture.store.shutdown()
    }

    /// The photo menu groups the targets' faces by person: Sam's face (guessed in b.jpg)
    /// with everyone else to move it to, then the unidentified face, with Sam among the
    /// people it may be. With the filter on Sam, her group sits at the top level.
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
        #expect(menu.groups[0].choices.map(\.person) == [ian])
        #expect(menu.groups[0].keyPhoto == fixture.like)
        #expect(menu.groups.map(\.name) == ["Sam", nil])
        #expect(Set(menu.groups[1].choices.map(\.person)) == [fixture.sam, ian])
        #expect(!menu.flattensFirst)

        fixture.model.setPeopleFilter(fixture.sam, included: true)
        fixture.show(people, scope: .allMedia, grid: [photo])
        fixture.model.selectAssets([photo])
        #expect(fixture.model.faceMenu()?.flattensFirst == true)
        await fixture.store.shutdown()
    }

    /// A person without a name is `Unnamed Person` in the photo menu, never offered a name
    /// to deny, and Add Name… opens the Person sheet for them.
    @Test func anUnnamedPersonIsOfferedAName() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        let unnamed = try #require(try await fixture.store.perform(.moveToNewPerson([fixture.stranger], name: nil)).person)
        let photo = fixture.stranger.asset
        try await fixture.show(fixture.people(), scope: .allMedia, grid: [photo])
        fixture.model.selectAssets([photo])

        let group = try #require(fixture.model.faceMenu()?.groups.first { $0.person == unnamed })
        #expect(group.title == "Unnamed Person")
        #expect(group.name == nil)
        fixture.model.performMediaItemCommand(.addName(unnamed))
        #expect(fixture.model.peopleSession.sheet?.subject == .person(unnamed))
        await fixture.store.shutdown()
    }

    /// Saving the Person sheet with a name another person has asks whether they are the same
    /// person; Merge merges them. New Person… with a taken name gives the faces to that
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
        fixture.model.beginNewPerson([fixture.like])
        fixture.model.savePersonSheet(.newPerson([fixture.like]), name: "Sam", birthday: nil)
        // b.jpg already holds Sam's face: the store refuses, and nothing changes.
        #expect(try await fixture.assignment(of: fixture.like) != .user(fixture.sam))
        await fixture.store.shutdown()
    }

    /// This Is ▸ Sam on the unidentified face: undo writes the face back as it was, redo
    /// gives it to her again.
    @Test func undoAndRedoAnAct() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        let ian = try #require(try await fixture.store.perform(.moveToNewPerson([], name: "Ian")).person)
        try await fixture.show(fixture.people(), scope: .allMedia)

        fixture.model.nameFaces([fixture.stranger], as: ian)
        try await Self.waitForStore(fixture.store) { try await fixture.assignment(of: fixture.stranger) == .user(ian) }
        try await Self.waitForUndo(fixture.model, title: "Undo This Is")

        fixture.model.undoLastChange()
        try await Self.waitForStore(fixture.store) { try await fixture.assignment(of: fixture.stranger)?.isGuessable == true }
        fixture.model.redoLastChange()
        try await Self.waitForStore(fixture.store) { try await fixture.assignment(of: fixture.stranger) == .user(ian) }
        await fixture.store.shutdown()
    }

    /// Not Sam: the face loses her and Otos never gives it to her again.
    @Test func notThisPersonHoldsTheFace() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        try await fixture.show(fixture.people(), scope: .allMedia)
        #expect(try await fixture.assignment(of: fixture.like) == .model(fixture.sam))

        fixture.model.removeNames([fixture.like])
        try await Self.waitForStore(fixture.store) { try await fixture.assignment(of: fixture.like) == .held }
        _ = try await fixture.people()
        #expect(try await fixture.assignment(of: fixture.like) == .held)
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
