import Foundation
@testable import OtosKit
import Testing

/// The hops a People act travels before People is built with it (ADR 0004 DES-120 paragraph,
/// ADR 0047, `docs/research/2026-11-20-people-act-chain.md`): the window's submission, the
/// store's write, the People state the write's change rings, and the store's answer. At each
/// hop where another event can arrive — a People state read before the write, a state that
/// covers an older request, a second act, an undo, another merge — the test delivers it at
/// exactly that point and asserts what the window shows: the act is never taken back, never
/// applied to another person, and the window never lands on a person who is gone.
///
/// The model is not started and its People intents are taken off the stream by hand
/// (`consumesIntents: false`), so each test decides when the store writes, when it answers
/// and which People state arrives when; an answer's `covers` is set by the test, as the
/// gallery's request numbering would.
@Suite(.testScope)
@MainActor
struct PeopleActChainTests {
    typealias Fixture = PeopleViewModelTests.Fixture

    /// A name saved in the Person sheet survives a People state read before its write that
    /// arrives between the submission and the write, the write itself, and a state covering
    /// an older request that arrives after the answer; the state that covers the answer's
    /// request retires it with the name in place.
    @Test func aStateReadBeforeTheWriteNeverTakesTheNameBack() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory(), consumesIntents: false)
        var before = try await fixture.people()
        before.covers = 3
        fixture.show(before, scope: .people)
        var intents = fixture.model.peopleIntentStream.makeAsyncIterator()

        fixture.model.savePersonSheet(.person(fixture.sam), name: "Sam K", birthday: nil)
        #expect(fixture.model.peopleState.person(fixture.sam)?.name == "Sam K")
        let act = try #require(await intents.next())

        // Between the submission and the write: a state from before it, covering a newer
        // request than any shown so far.
        before.covers = 4
        fixture.show(before, scope: .people)
        #expect(fixture.model.peopleState.person(fixture.sam)?.name == "Sam K", "a state read before the write")

        let answer = await answering(act, fixture: fixture, covers: 5)
        // Between the write and its answer: the state the write's change rang, read before it.
        fixture.show(before, scope: .people)
        #expect(fixture.model.peopleState.person(fixture.sam)?.name == "Sam K", "the write landed, not yet answered")

        fixture.model.applyPeopleIntentEvent(answer)
        #expect(fixture.model.peopleState.person(fixture.sam)?.name == "Sam K", "the answer")

        // After the answer: the state read before the write again, covering an older request
        // than the answer named.
        fixture.show(before, scope: .people)
        #expect(fixture.model.peopleState.person(fixture.sam)?.name == "Sam K", "a state covering an older request")

        var covering = try await fixture.people()
        covering.covers = 5
        fixture.show(covering, scope: .people)
        #expect(fixture.model.peopleState.person(fixture.sam)?.name == "Sam K", "the state covering the answer")
        #expect(fixture.model.pendingPeopleActs.effect.isEmpty, "the covering state retired the act")
        await fixture.store.shutdown()
    }

    /// A hide whose covering People state reaches the window before the store's answer (the
    /// gallery's read of the request can finish before the answer's main-actor turn): the
    /// person is hidden through the state, the answer and every state after.
    @Test func aCoveringStateBeforeTheAnswerKeepsTheHide() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory(), consumesIntents: false)
        try await fixture.show(fixture.people(), scope: .people)
        var intents = fixture.model.peopleIntentStream.makeAsyncIterator()

        fixture.model.setHidden(fixture.sam, true)
        #expect(fixture.model.peopleState.hiddenPeople.map(\.id) == [fixture.sam])
        let act = try #require(await intents.next())
        let answer = await answering(act, fixture: fixture, covers: 5)

        var covering = try await fixture.people()
        covering.covers = 5
        fixture.show(covering, scope: .people)
        #expect(fixture.model.peopleState.hiddenPeople.map(\.id) == [fixture.sam], "the covering state, before the answer")

        fixture.model.applyPeopleIntentEvent(answer)
        #expect(fixture.model.peopleState.hiddenPeople.map(\.id) == [fixture.sam], "the answer")

        var later = try await fixture.people()
        later.covers = 6
        fixture.show(later, scope: .people)
        #expect(fixture.model.peopleState.hiddenPeople.map(\.id) == [fixture.sam], "a later state")
        #expect(fixture.model.pendingPeopleActs.effect.isEmpty)
        await fixture.store.shutdown()
    }

    /// ⌘Z after a rename was answered but before People was built with it: a state covering
    /// the rename's request — the new name — arrives while the undo is on its way, and then
    /// again after the undo's answer. Neither puts the new name back: the window shows the
    /// old name until a state covering the undo's request arrives, and keeps it then.
    @Test func aStateCoveringTheActNeverTakesItsUndoBack() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory(), consumesIntents: false)
        try await fixture.show(fixture.people(), scope: .people)
        var intents = fixture.model.peopleIntentStream.makeAsyncIterator()

        fixture.model.savePersonSheet(.person(fixture.sam), name: "Sam K", birthday: nil)
        let act = try #require(await intents.next())
        await fixture.model.applyPeopleIntentEvent(answering(act, fixture: fixture, covers: 5))
        var renamed = try await fixture.people()
        renamed.covers = 5
        #expect(renamed.person(fixture.sam)?.name == "Sam K")

        fixture.model.undoLastChange()
        #expect(fixture.model.peopleState.person(fixture.sam)?.name == "Sam", "the undo shows at once")
        let undo = try #require(await intents.next())

        fixture.show(renamed, scope: .people)
        #expect(fixture.model.peopleState.person(fixture.sam)?.name == "Sam", "the act's build, before the undo is written")

        await fixture.model.applyPeopleIntentEvent(answering(undo, fixture: fixture, covers: 6))
        renamed.covers = 5
        fixture.show(renamed, scope: .people)
        #expect(fixture.model.peopleState.person(fixture.sam)?.name == "Sam", "the act's build, after the undo's answer")

        var restored = try await fixture.people()
        #expect(restored.person(fixture.sam)?.name == "Sam")
        restored.covers = 6
        fixture.show(restored, scope: .people)
        #expect(fixture.model.peopleState.person(fixture.sam)?.name == "Sam")
        #expect(fixture.model.pendingPeopleActs.effect.isEmpty)
        #expect(fixture.model.undoMenuState.redoTitle == "Redo Edit Person")
        await fixture.store.shutdown()
    }

    /// Two merges in flight, the second merging away the person the first merges into, with
    /// the window on the first person's photos and filtering by them. The state both writes
    /// publish arrives before either answer; then each answer in turn. The window never
    /// leaves for the gallery and ends on the person both merged into.
    @Test func twoMergesInFlightLandOnTheLastPersonMergedInto() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory(), consumesIntents: false)
        let other = try #require(try await fixture.store.perform(.moveToNewPerson([fixture.stranger], name: nil)).person)
        let ian = try #require(try await fixture.store.perform(.moveToNewPerson([], name: "Ian")).person)
        let people = try await fixture.people()
        fixture.show(people, scope: .people)
        fixture.model.openPerson(other)
        fixture.show(people, scope: .person(other))
        fixture.model.setPeopleFilter(other, included: true)
        var intents = fixture.model.peopleIntentStream.makeAsyncIterator()

        fixture.model.peopleSession.mergeQuestion = PeopleMergeQuestion(from: other, into: ian)
        fixture.model.answerMerge(true)
        fixture.model.peopleSession.mergeQuestion = PeopleMergeQuestion(from: ian, into: fixture.sam)
        fixture.model.answerMerge(true)
        let first = try #require(await intents.next())
        let second = try #require(await intents.next())
        let firstAnswer = await CatalogWindowViewModel.runPeopleIntent(
            first, store: fixture.store, projection: fixture.model.catalogProjection
        )
        let secondAnswer = await CatalogWindowViewModel.runPeopleIntent(
            second, store: fixture.store, projection: fixture.model.catalogProjection
        )
        let merged = try await fixture.people()
        #expect(merged.person(other) == nil)
        #expect(merged.person(ian) == nil)

        fixture.show(merged, scope: .person(other))
        #expect(fixture.model.queryDescriptor.scope == .person(other), "both writes published, neither answered")
        #expect(fixture.model.queryDescriptor.filter.people == [other])

        fixture.model.applyPeopleIntentEvent(firstAnswer)
        #expect(fixture.model.queryDescriptor.scope == .person(ian), "the first answer, the second outstanding")
        #expect(fixture.model.queryDescriptor.filter.people == [ian])
        fixture.show(merged, scope: .person(ian))
        #expect(fixture.model.queryDescriptor.scope == .person(ian), "a state without them, the second outstanding")

        fixture.model.applyPeopleIntentEvent(secondAnswer)
        #expect(fixture.model.queryDescriptor.scope == .person(fixture.sam))
        #expect(fixture.model.queryDescriptor.filter.people == [fixture.sam])
        #expect(fixture.model.peopleSession.selectedPeople == [fixture.sam])
        fixture.show(merged, scope: .person(fixture.sam))
        #expect(fixture.model.queryDescriptor.scope == .person(fixture.sam))
        await fixture.store.shutdown()
    }

    /// ⌘Z on a merge before the store answers it, with the window on the person merged away:
    /// the merge's own state arrives first, then its answer, then the undo's write and the
    /// state with the person back. The window ends where an undo after the answer leaves it —
    /// on the person merged into, who exists — and the person merged away is back in People.
    @Test func aMergeUndoneBeforeItsAnswerEndsOnAPersonWhoExists() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory(), consumesIntents: false)
        let other = try #require(try await fixture.store.perform(.moveToNewPerson([fixture.stranger], name: nil)).person)
        let people = try await fixture.people()
        fixture.show(people, scope: .people)
        fixture.model.openPerson(other)
        fixture.show(people, scope: .person(other))
        fixture.model.setPeopleFilter(other, included: true)
        var intents = fixture.model.peopleIntentStream.makeAsyncIterator()

        fixture.model.peopleSession.mergeQuestion = PeopleMergeQuestion(from: other, into: fixture.sam)
        fixture.model.answerMerge(true)
        fixture.model.undoLastChange()
        let merge = try #require(await intents.next())
        let undo = try #require(await intents.next())

        let mergeAnswer = await CatalogWindowViewModel.runPeopleIntent(
            merge, store: fixture.store, projection: fixture.model.catalogProjection
        )
        let merged = try await fixture.people()
        fixture.show(merged, scope: .person(other))
        #expect(fixture.model.queryDescriptor.scope == .person(other), "the merge published, not answered")
        fixture.model.applyPeopleIntentEvent(mergeAnswer)
        #expect(fixture.model.queryDescriptor.scope == .person(fixture.sam))

        await fixture.model.applyPeopleIntentEvent(CatalogWindowViewModel.runPeopleIntent(
            undo, store: fixture.store, projection: fixture.model.catalogProjection
        ))
        let unmerged = try await fixture.people()
        #expect(unmerged.person(other) != nil, "the undo put the person back")
        fixture.show(unmerged, scope: .person(fixture.sam))
        #expect(fixture.model.queryDescriptor.scope == .person(fixture.sam))
        #expect(fixture.model.peopleState.person(other) != nil)
        #expect(fixture.model.queryDescriptor.filter.people == [fixture.sam])
        #expect(fixture.model.undoMenuState.redoTitle == "Redo Merge")
        await fixture.store.shutdown()
    }

    /// Change to ▸ Sam on the stranger's face: the People state covering the act and the read
    /// of the photo's faces it rings, asked before the answer, both arrive before the answer;
    /// then the answer. The
    /// face is Sam's on every surface at every step, and never another person's.
    @Test func aFaceActSurvivesReadsThatArriveBeforeItsAnswer() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory(), consumesIntents: false)
        try await fixture.show(fixture.people(), scope: .allMedia)
        try await fixture.select([fixture.stranger.asset])
        var intents = fixture.model.peopleIntentStream.makeAsyncIterator()

        fixture.model.nameFaces([fixture.stranger], as: fixture.sam)
        #expect(fixture.model.shownTargetFaces.face(fixture.stranger)?.person == fixture.sam)
        let act = try #require(await intents.next())
        let answer = await answering(act, fixture: fixture, covers: 5)

        var covering = try await fixture.people()
        covering.covers = 5
        fixture.show(covering, scope: .allMedia, grid: fixture.model.state.mediaGrid.orderedAssetIDs)
        try await fixture.waitForFaces()
        #expect(fixture.model.targetPhotoFaces.landedThrough == 0, "asked before the answer")
        #expect(fixture.model.shownTargetFaces.face(fixture.stranger)?.person == fixture.sam, "the reads, before the answer")

        fixture.model.applyPeopleIntentEvent(answer)
        #expect(fixture.model.shownTargetFaces.face(fixture.stranger)?.person == fixture.sam, "the answer")
        #expect(try await fixture.assignment(of: fixture.stranger) == .user(fixture.sam))
        await fixture.store.shutdown()
    }

    /// The store's answer to `intent`, run through the store, with the People request a
    /// build must cover to have it set to `covers` (the fixture's projection has no gallery,
    /// so its own request is 0, which every state covers).
    private func answering(_ intent: PeopleIntent, fixture: Fixture, covers: UInt64) async -> PeopleIntentEvent {
        let event = await CatalogWindowViewModel.runPeopleIntent(intent, store: fixture.store, projection: fixture.model.catalogProjection)
        switch event {
        case let .performed(act, record, request, outcome, _):
            return .performed(act, record: record, request: request, outcome: outcome, covers: covers)
        case let .flipped(record, act, undoing, request, redo, _):
            return .flipped(record, act: act, undoing: undoing, request: request, redo: redo, covers: covers)
        case .refused, .flipFailed, .flipSkipped:
            Issue.record("the store wrote the intent")
            return event
        }
    }

    /// The People state that covers an act's request can reach the window before the store's
    /// answer does: `PeopleGallery.request()` rings its loop, whose read can publish before the
    /// intent consumer's main-actor turn applies the answer. That state has the act in it, so
    /// the answer retires the act against it (`PendingPeopleActs.builtThrough`).
    @Test func aCoveringStateBeforeTheAnswerRetiresTheAct() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory(), consumesIntents: false)
        try await fixture.show(fixture.people(), scope: .people)
        var intents = fixture.model.peopleIntentStream.makeAsyncIterator()

        fixture.model.setHidden(fixture.sam, true)
        guard case let .perform(act, record, request) = try #require(await intents.next()) else {
            Issue.record("the hide is a perform")
            return
        }
        let outcome = try await fixture.store.perform(act)
        var covering = try await fixture.people()
        covering.covers = 5
        fixture.show(covering, scope: .people)
        fixture.model.applyPeopleIntentEvent(.performed(act, record: record, request: request, outcome: outcome, covers: 5))

        #expect(fixture.model.peopleState.hiddenPeople.map(\.id) == [fixture.sam])
        #expect(fixture.model.pendingPeopleActs.effect.isEmpty, "the state that covers the answer's request has arrived")
        await fixture.store.shutdown()
    }

    /// The same for an act on a face: the read of the photo's faces the covering state rang was
    /// asked before the answer, so the answer asks for one after it, and that read retires the
    /// face's override.
    @Test func aCoveringStateBeforeTheAnswerRetiresTheFaceAct() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory(), consumesIntents: false)
        try await fixture.show(fixture.people(), scope: .allMedia)
        try await fixture.select([fixture.stranger.asset])
        var intents = fixture.model.peopleIntentStream.makeAsyncIterator()

        fixture.model.nameFaces([fixture.stranger], as: fixture.sam)
        guard case let .perform(act, record, request) = try #require(await intents.next()) else {
            Issue.record("the move is a perform")
            return
        }
        let outcome = try await fixture.store.perform(act)
        var covering = try await fixture.people()
        covering.covers = 5
        fixture.show(covering, scope: .allMedia, grid: fixture.model.state.mediaGrid.orderedAssetIDs)
        try await fixture.waitForFaces()
        fixture.model.applyPeopleIntentEvent(.performed(act, record: record, request: request, outcome: outcome, covers: 5))
        try await fixture.waitForFaces()

        #expect(fixture.model.shownTargetFaces.face(fixture.stranger)?.person == fixture.sam)
        #expect(
            fixture.model.targetPhotoFaces.landedThrough == fixture.model.pendingPeopleActs.answered,
            "a read of the photo's faces asked after the answer"
        )
        #expect(fixture.model.pendingPeopleActs.effect.isEmpty)
        await fixture.store.shutdown()
    }
}
