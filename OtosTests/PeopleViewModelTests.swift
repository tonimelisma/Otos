import CoreGraphics
import Foundation
import Observation
@testable import OtosKit
import Testing

/// People's view-model side (ADR 0047, `docs/design/people.md`) against a real catalog: an
/// act hides its faces at once and moves the selection on; the faces stay hidden until a
/// People state built after the act arrives, whatever arrives before it; a refused act
/// brings them back; undo and redo restore the catalog; and a person's scope corrects the
/// selected photos' faces.
///
/// The model is not started: People states are built from the store with
/// `PeopleProjection.build` and applied by hand, so each test decides which state arrives
/// when — a state read before the act is applied after it on purpose.
@Suite(.testDirectory)
@MainActor
struct PeopleViewModelTests {
    @MainActor
    struct Fixture {
        let library: FaceEnrichmentTests.ScannedLibrary
        let model: CatalogWindowViewModel
        let sam: PersonID
        let confirmed: FaceID
        let suggested: FaceID

        var store: CatalogStore {
            library.store
        }

        /// Sam confirmed in a.jpg; the same face in b.jpg is suggested as her.
        static func make(in directory: URL, extraFaceInB: Bool = false) async throws -> Fixture {
            let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: directory, files: ["a.jpg", "b.jpg"])
            let face = PeopleStoreTests.face(x: 0.1)
            try await library.store.applyEnrichmentBatch([
                library.result(for: "a.jpg", faces: [face]),
                library.result(for: "b.jpg", faces: extraFaceInB ? [face, PeopleStoreTests.face(x: 0.6)] : [face]),
            ])
            let confirmed = FaceID(asset: library.id("a.jpg"), index: 0)
            let sam = try #require(try await library.store.perform(.name([confirmed], "Sam")).person)
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
                library: library, model: model, sam: sam, confirmed: confirmed,
                suggested: FaceID(asset: library.id("b.jpg"), index: 0)
            )
        }

        /// People as the store holds it now.
        func people() async throws -> CatalogPeopleState {
            let libraries = try #require(await store.loadedLibraries())
            return try await PeopleProjection.build(store: store, libraries: libraries)
        }

        /// The window showing `scope` with `people`.
        func show(_ people: CatalogPeopleState, scope: SidebarSelection, grid: [MediaAssetID] = []) {
            var state = CatalogWindowState(
                title: "People",
                libraries: [],
                removableSources: [],
                mediaGrid: CatalogMediaGridState(descriptor: CatalogQueryDescriptor(scope: scope), orderedAssetIDs: grid),
                filterOptions: .empty,
                resolvedSidebarSelection: scope,
                mediaEmptyState: .noMedia,
                deviceConnectionBanner: nil
            )
            state.people = people
            state.queryGeneration = model.queryGeneration
            model.applyState(state)
        }

        func person(of face: FaceID) async throws -> PersonID? {
            try await store.peopleSnapshot().faces.first { $0.id == face }?.person
        }
    }

    /// Waits for the model's People session to satisfy `predicate`; no deadline (a value
    /// that never comes is a hang `check.sh` names).
    func waitForSession(
        _ model: CatalogWindowViewModel,
        _ predicate: @escaping @MainActor (PeopleSession) -> Bool
    ) async {
        let sessions = Observations { @MainActor [weak model] in
            model?.peopleSession
        }
        for await session in sessions {
            guard let session else { return }
            if predicate(session) {
                return
            }
        }
    }

    /// The race this guards: a People state read before an act committed arrives after the
    /// act. It must not bring the acted face back; the state built after the act shows it
    /// confirmed, and the hidden face is released.
    @Test func aStateFromBeforeTheActDoesNotBringItsFaceBack() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        let before = try await fixture.people()
        #expect(before.suggestionCount == 1)
        fixture.show(before, scope: .peopleReview)

        fixture.model.selectReviewFaces(fixture.suggested, modifiers: [])
        #expect(fixture.model.canConfirmReviewFaces)
        fixture.model.confirmSelectedReviewFaces()
        #expect(fixture.model.peopleReviewLayout.order.isEmpty)
        #expect(fixture.model.peopleSession.selectedFaces.isEmpty)

        await waitForSession(fixture.model) { $0.leaving[fixture.suggested]?.revision != nil }
        let committed = try #require(fixture.model.peopleSession.leaving[fixture.suggested]?.revision)
        #expect(committed > before.revision)
        #expect(try await fixture.person(of: fixture.suggested) == fixture.sam)

        // The stale state arrives late: same rows, read under the old revision.
        let stale = CatalogPeopleState(
            people: before.people, suggestions: before.suggestions, unsure: before.unsure,
            uncheckedPhotoCount: before.uncheckedPhotoCount + 1, faceCount: before.faceCount, revision: before.revision
        )
        fixture.show(stale, scope: .peopleReview)
        #expect(fixture.model.peopleReviewLayout.order.isEmpty)

        let after = try await fixture.people()
        #expect(after.revision >= committed)
        fixture.show(after, scope: .peopleReview)
        #expect(fixture.model.peopleSession.leaving.isEmpty)
        #expect(after.suggestionCount == 0)
        #expect(after.person(fixture.sam)?.photoCount == 2)
        await fixture.store.shutdown()
    }

    /// Return confirms and the selection moves to the next face; Undo puts the face back in
    /// the review, selected; Redo confirms it again.
    @Test func undoAndRedoAConfirmation() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        try await fixture.show(fixture.people(), scope: .peopleReview)
        fixture.model.selectReviewFaces(fixture.suggested, modifiers: [])
        fixture.model.confirmSelectedReviewFaces()
        await waitForSession(fixture.model) { $0.receipt != nil }
        #expect(fixture.model.peopleSession.receipt?.text == "Confirmed 1 face as Sam")
        #expect(fixture.model.canUndoPeopleReceipt)
        try await fixture.show(fixture.people(), scope: .peopleReview)

        fixture.model.undoLastChange()
        #expect(fixture.model.peopleSession.selectedFaces == [fixture.suggested])
        // The restore is ordered after the act on the one consumer; wait for it to land.
        try await Self.waitForStore(fixture.store) { try await fixture.person(of: fixture.suggested) == nil }
        let restored = try await fixture.people()
        #expect(restored.suggestionCount == 1)
        fixture.show(restored, scope: .peopleReview)
        #expect(fixture.model.peopleReviewLayout.order == [fixture.suggested])

        fixture.model.redoLastChange()
        try await Self.waitForStore(fixture.store) { try await fixture.person(of: fixture.suggested) == fixture.sam }
        await fixture.store.shutdown()
    }

    /// A confirmation the store refuses — Sam was confirmed in that photo after the review
    /// was built — brings the hidden face back, and nothing is written.
    @Test func aRefusedActBringsItsFaceBack() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory(), extraFaceInB: true)
        let before = try await fixture.people()
        fixture.show(before, scope: .peopleReview)
        #expect(fixture.model.peopleReviewLayout.order.contains(fixture.suggested))

        // Elsewhere, the other face of b.jpg becomes Sam's.
        _ = try await fixture.store.perform(.confirm([FaceID(asset: fixture.suggested.asset, index: 1)], as: fixture.sam))

        fixture.model.selectReviewFaces(fixture.suggested, modifiers: [])
        fixture.model.confirmSelectedReviewFaces()
        #expect(!fixture.model.peopleReviewLayout.order.contains(fixture.suggested))
        await waitForSession(fixture.model) { $0.leaving.isEmpty }
        #expect(fixture.model.peopleReviewLayout.order.contains(fixture.suggested))
        #expect(try await fixture.person(of: fixture.suggested) == nil)
        await fixture.store.shutdown()
    }

    /// In Sam's photos, Not Sam on a selected photo takes her face out and remembers
    /// it is not her.
    @Test func notThisPersonInTheirPhotos() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        try await fixture.show(fixture.people(), scope: .person(fixture.sam), grid: [fixture.confirmed.asset])
        #expect(fixture.model.windowTitle == "Sam")
        fixture.model.selectAssets([fixture.confirmed.asset])
        #expect(fixture.model.shownPersonSelectedFaces == [fixture.confirmed])
        #expect(fixture.model.personCorrectionsMenu()?.enabled == true)

        fixture.model.rejectShownPersonFaces()
        try await Self.waitForStore(fixture.store) { try await fixture.person(of: fixture.confirmed) == nil }
        let facts = try await fixture.store.peopleSnapshot()
        #expect(facts.faces.first { $0.id == fixture.confirmed }?.rejected == [fixture.sam])
        await fixture.store.shutdown()
    }

    /// Undo shows what it changed: undoing Not Sam after leaving her photos opens them
    /// again with the photo selected, and the face is hers again.
    @Test func undoingNotThisPersonOpensTheirPhotos() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        try await fixture.show(fixture.people(), scope: .person(fixture.sam), grid: [fixture.confirmed.asset])
        fixture.model.selectAssets([fixture.confirmed.asset])
        fixture.model.rejectShownPersonFaces()
        await waitForSession(fixture.model) { $0.receipt != nil }
        try await fixture.show(fixture.people(), scope: .peopleReview)
        #expect(fixture.model.showsPeopleReview)

        fixture.model.undoLastChange()
        #expect(fixture.model.sidebarSelection == .person(fixture.sam))
        #expect(fixture.model.peopleSession.selectedFaces.isEmpty)
        try await Self.waitForStore(fixture.store) { try await fixture.person(of: fixture.confirmed) == fixture.sam }
        // Her scope's first state, holding the photo again, keeps it selected.
        try await fixture.show(fixture.people(), scope: .person(fixture.sam), grid: [fixture.confirmed.asset])
        #expect(fixture.model.orderedSelectedAssetIDs == [fixture.confirmed.asset])
        await fixture.store.shutdown()
    }

    /// Opening a face's photo from the review shows that photo, not the row's first: its
    /// selection survives the review-photos scope's first state.
    @Test func openingAFacesPhotoShowsThatPhoto() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(
            in: makeTestDirectory(), files: ["a.jpg", "b.jpg", "c.jpg"]
        )
        let store = library.store
        var results: [EnrichmentResult] = []
        for name in ["a.jpg", "b.jpg", "c.jpg"] {
            try await results.append(library.result(for: name, faces: [PeopleStoreTests.face(x: 0.1)]))
        }
        _ = await store.applyEnrichmentBatch(results)
        _ = try await store.perform(.name([FaceID(asset: library.id("a.jpg"), index: 0)], "Sam"))
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: PreferencesDomain.suite(UUID().uuidString),
            volumeCapacity: ampleVolumeCapacity,
            trashFiles: .refusing
        )
        let fixture = Fixture(
            library: library, model: model, sam: PersonID(rawValue: 0),
            confirmed: FaceID(asset: library.id("a.jpg"), index: 0), suggested: FaceID(asset: library.id("c.jpg"), index: 0)
        )
        try await fixture.show(fixture.people(), scope: .peopleReview)
        let row = try #require(model.peopleReviewLayout.rows.first)
        let photos = row.faces.map(\.id.asset)
        #expect(Set(photos) == [library.id("b.jpg"), library.id("c.jpg")])
        let opened = try #require(row.faces.last).id

        model.openReviewPhoto(opened)
        #expect(model.sidebarSelection == .reviewPhotos(photos))
        try await fixture.show(fixture.people(), scope: .reviewPhotos(photos), grid: photos)
        #expect(model.orderedSelectedAssetIDs == [opened.asset])
        #expect(model.focusedAssetID == opened.asset)
        await store.shutdown()
    }

    /// The sibling fix by drag: Ian's suggested face dropped onto Sam's row in the same
    /// year becomes Sam's. A drop onto its own row, or onto a year it is not in, is refused.
    @Test func faceDroppedOntoAnotherPersonsRowIsTheirs() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(
            in: makeTestDirectory(), files: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]
        )
        let store = library.store
        try await store.applyEnrichmentBatch([
            library.result(for: "a.jpg", faces: [PeopleStoreTests.face(x: 0.1)]),
            library.result(for: "b.jpg", faces: [PeopleStoreTests.face(x: 0.1)]),
            library.result(for: "c.jpg", faces: [PeopleStoreTests.face(x: 0.6)]),
            library.result(for: "d.jpg", faces: [PeopleStoreTests.face(x: 0.6)]),
        ])
        let sam = try #require(try await store.perform(.name([FaceID(asset: library.id("a.jpg"), index: 0)], "Sam")).person)
        let ian = try #require(try await store.perform(.name([FaceID(asset: library.id("c.jpg"), index: 0)], "Ian")).person)
        let dropped = FaceID(asset: library.id("d.jpg"), index: 0)
        let model = CatalogWindowViewModel(
            catalogStore: store,
            catalogProjection: CatalogProjection(cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: PreferencesDomain.suite(UUID().uuidString),
            volumeCapacity: ampleVolumeCapacity,
            trashFiles: .refusing
        )
        model.startPeopleIntentConsumer()
        let fixture = Fixture(library: library, model: model, sam: sam, confirmed: dropped, suggested: dropped)
        try await fixture.show(fixture.people(), scope: .peopleReview)

        func row(of person: PersonID) -> PeopleReviewRow? {
            model.peopleReviewLayout.rows.first {
                if case .person(person, _) = $0.kind {
                    true
                } else {
                    false
                }
            }
        }
        let year = try #require(model.peopleReviewLayout.years.first).year
        let samRow = try #require(row(of: sam))
        let ianRow = try #require(row(of: ian))
        #expect(ianRow.faces.map(\.id) == [dropped])
        let payload = try #require(PeopleDrag.faces(from: PeopleDrag.payload(faces: [dropped])))
        #expect(payload == [dropped])
        #expect(model.reviewDropTarget(payload, onto: ianRow, year: year) == nil)
        #expect(model.reviewDropTarget(payload, onto: samRow, year: (year ?? 2000) - 1) == nil)

        #expect(model.dropReviewFaces(payload, onto: samRow, year: year))
        await waitForSession(model) { $0.receipt != nil }
        #expect(model.peopleSession.receipt?.text == "Moved 1 face to Sam")
        try await Self.waitForStore(store) { try await fixture.person(of: dropped) == sam }
        await store.shutdown()
    }

    /// `PeopleProjection`'s own loop: a request after an act publishes a state whose
    /// revision covers it and which shows it.
    @Test func theProjectionPublishesAStateThatShowsTheAct() async throws {
        let fixture = try await Fixture.make(in: makeTestDirectory())
        let projection = PeopleProjection(store: fixture.store, builder: nil)
        await projection.start()
        var builds = projection.builds.makeAsyncIterator()
        await projection.request()
        let first = try #require(await builds.next())
        #expect(first.suggestionCount == 1)

        let outcome = try await fixture.store.perform(.confirm([fixture.suggested], as: fixture.sam))
        await projection.request()
        let second = try #require(await builds.next())
        #expect(second.revision >= outcome.revision)
        #expect(second.suggestionCount == 0)
        #expect(second.person(fixture.sam)?.photoCount == 2)
        projection.stop()
        await fixture.store.shutdown()
    }

    /// The hiding rule on its own: a face stays hidden while its act is on its way and
    /// until a state at the act's revision; a refused act's faces come back at once.
    @Test func hiddenFacesFollowTheirActsRevision() {
        let a = FaceID(asset: MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/L"), relativePath: MediaRelativePath(rawValue: "a")), index: 0)
        let b = FaceID(asset: a.asset, index: 1)
        var session = PeopleSession()
        session.leaving = [a: PeopleLeavingMark(act: 1, revision: nil), b: PeopleLeavingMark(act: 2, revision: nil)]

        session.shown(upTo: 100)
        #expect(session.leaving.count == 2)
        session.actCommitted(1, revision: 7)
        session.shown(upTo: 6)
        #expect(session.leaving[a] != nil)
        session.shown(upTo: 7)
        #expect(session.leaving[a] == nil)
        session.actFailed(2)
        #expect(session.leaving.isEmpty)
    }

    /// Waits until `condition` holds, re-checking after each store change. Subscribed before
    /// the first check, so a change between a check and the wait is never missed. No
    /// deadline.
    static func waitForStore(_ store: CatalogStore, _ condition: () async throws -> Bool) async throws {
        var changes = await store.changeNotifications().makeAsyncIterator()
        while try await !condition() {
            guard await changes.next() != nil else { return }
        }
    }
}
