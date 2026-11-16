import Foundation
@testable import OtosKit
import Testing

/// A People act shows its result before People is built with it (DES-120, APP-087): the acts
/// are taken off the stream by hand, so each test decides when the store answers and which
/// People state arrives when.
@Suite(.testScope)
@MainActor
struct PeopleShownFirstTests {
    typealias Fixture = PeopleViewModelTests.Fixture

    /// Add to Favorites moves the person to the front of the gallery in the click's step, by
    /// the builder's own order; its undo is on the stack before the store answers; a refusal
    /// withdraws it and says so.
    @Test func aFavouriteShowsAtOnceAndARefusalWithdrawsIt() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory(), consumesIntents: false)
        let ian = try #require(try await fixture.store.perform(.moveToNewPerson([fixture.stranger], name: "Ian")).person)
        try await fixture.show(fixture.people(), scope: .people)
        #expect(fixture.model.galleryOrder.first == fixture.sam, "Sam has the most photos")
        var intents = fixture.model.peopleIntentStream.makeAsyncIterator()

        fixture.model.setFavorite(ian, true)
        #expect(fixture.model.peopleState.person(ian)?.isFavorite == true)
        #expect(fixture.model.galleryOrder.first == ian)
        #expect(fixture.model.undoMenuState.undoTitle == "Undo Add to Favorites")

        guard case let .perform(act, record, request) = try #require(await intents.next()) else {
            Issue.record("the favourite is a perform")
            return
        }
        fixture.model.applyPeopleIntentEvent(.refused(act, record: record, request: request, error: CocoaError(.fileWriteUnknown)))
        #expect(fixture.model.peopleState.person(ian)?.isFavorite == false)
        #expect(fixture.model.galleryOrder.first == fixture.sam)
        #expect(fixture.model.peopleSession.refusal == .failed("Add to Favorites"))
        #expect(fixture.model.peopleSession.refusal?.title == "This change couldn’t be saved.")
        #expect(!fixture.model.undoMenuState.canUndo)
        await fixture.store.shutdown()
    }

    /// A written act stays shown over every People state built before its write, and leaves
    /// once a state covering the request its answer named arrives.
    @Test func aWrittenActStaysShownUntilABuildCoversIt() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory(), consumesIntents: false)
        let people = try await fixture.people()
        fixture.show(people, scope: .people)
        var intents = fixture.model.peopleIntentStream.makeAsyncIterator()

        fixture.model.setHidden(fixture.sam, true)
        #expect(fixture.model.peopleState.hiddenPeople.map(\.id) == [fixture.sam])
        guard case let .perform(act, record, request) = try #require(await intents.next()) else {
            Issue.record("the hide is a perform")
            return
        }
        let outcome = try await fixture.store.perform(act)
        fixture.model.applyPeopleIntentEvent(.performed(act, record: record, request: request, outcome: outcome, covers: 5))
        var stale = people
        stale.covers = 4
        fixture.show(stale, scope: .people)
        #expect(fixture.model.peopleState.hiddenPeople.map(\.id) == [fixture.sam], "a build from before the write")

        var built = try await fixture.people()
        built.covers = 5
        fixture.show(built, scope: .people)
        #expect(fixture.model.peopleState.hiddenPeople.map(\.id) == [fixture.sam])
        #expect(fixture.model.pendingPeopleActs.effect.isEmpty, "the build that covers the write retired it")
        await fixture.store.shutdown()
    }

    /// This Is Not Sam: the face loses her on the photo menus in the step it is chosen;
    /// ⌘Z before the store answers gives it back at once, and the undo is written after the act.
    @Test func aFaceLeavesItsPersonAtOnceAndAnUndoFirstPutsItBack() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory(), consumesIntents: false)
        try await fixture.show(fixture.people(), scope: .allMedia)
        var intents = fixture.model.peopleIntentStream.makeAsyncIterator()

        fixture.model.removeNames([fixture.hers])
        #expect(fixture.model.peopleState.face(fixture.hers)?.person == nil)
        fixture.model.undoLastChange()
        #expect(fixture.model.peopleState.face(fixture.hers)?.person == fixture.sam)

        let act = try #require(await intents.next())
        await fixture.model.applyPeopleIntentEvent(
            CatalogWindowViewModel.runPeopleIntent(act, store: fixture.store, projection: fixture.model.catalogProjection)
        )
        let undo = try #require(await intents.next())
        await fixture.model.applyPeopleIntentEvent(
            CatalogWindowViewModel.runPeopleIntent(undo, store: fixture.store, projection: fixture.model.catalogProjection)
        )
        #expect(try await fixture.assignment(of: fixture.hers) == .user(fixture.sam))
        #expect(fixture.model.undoMenuState.redoTitle == "Redo This Is Not Sam")
        await fixture.store.shutdown()
    }

    /// Two acts on one person before either is answered: the later is shown; the earlier's
    /// refusal leaves it shown.
    @Test func aSecondActOnTheSamePersonWins() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory(), consumesIntents: false)
        try await fixture.show(fixture.people(), scope: .people)
        var intents = fixture.model.peopleIntentStream.makeAsyncIterator()

        fixture.model.setFavorite(fixture.sam, true)
        fixture.model.savePersonSheet(.person(fixture.sam), name: "Sam K", birthday: nil)
        #expect(fixture.model.peopleState.person(fixture.sam)?.name == "Sam K")
        #expect(fixture.model.peopleState.person(fixture.sam)?.isFavorite == true)

        guard case let .perform(act, record, request) = try #require(await intents.next()) else {
            Issue.record("the favourite is a perform")
            return
        }
        fixture.model.applyPeopleIntentEvent(.refused(act, record: record, request: request, error: CocoaError(.fileWriteUnknown)))
        #expect(fixture.model.peopleState.person(fixture.sam)?.isFavorite == false)
        #expect(fixture.model.peopleState.person(fixture.sam)?.name == "Sam K")
        await fixture.store.shutdown()
    }
}
