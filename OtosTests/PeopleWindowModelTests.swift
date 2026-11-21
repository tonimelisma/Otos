import AppKit
import Foundation
import GRDB
@testable import OtosKit
import Testing

/// People's acts as the user makes them: through the window's own intents, its merge question
/// and its undo stack (ADR 0047, APP-072), checked against the same reference model as the
/// store's walk (`PeopleReferenceModelTests`). The window decides what reaches the store — an
/// act it refuses on its own is never submitted — numbers each act in one ordered stream,
/// registers its undo before the store answers and withdraws it on a refusal. After each step
/// the catalog must be what the model predicts for the act the window submitted, an undo or
/// redo must restore exactly what it recorded while nothing else wrote meanwhile, and the
/// rules no act owns must hold.
@Suite(.testScope)
@MainActor
struct PeopleWindowModelTests {
    typealias Model = PeopleReferenceModelTests

    /// One window over a catalog in a file of its own, its People intents consumed as the
    /// app's are.
    @MainActor
    struct Window {
        let library: FaceEnrichmentTests.ScannedLibrary
        let model: CatalogWindowViewModel
        let queue: DatabaseQueue

        /// The People state the store holds now, applied to the window under the gallery, so
        /// the menus, the merge question and the overlay judge what the catalog holds.
        func show() async throws {
            let libraries = try #require(await library.store.loadedLibraries())
            var descriptor = model.queryDescriptor
            descriptor.scope = .people
            var state = CatalogWindowState(
                title: "People",
                libraries: [],
                removableSources: [],
                mediaGrid: CatalogMediaGridState(descriptor: descriptor, orderedAssetIDs: []),
                filterOptions: .empty,
                resolvedSidebarSelection: .people,
                mediaEmptyState: .noMedia,
                deviceConnectionBanner: nil
            )
            state.people = try await library.store.gallery(libraries: libraries)
            state.queryGeneration = model.queryGeneration
            model.applyState(state)
        }

        /// Waits until the store has answered every write the window submitted.
        func untilAnswered() async throws {
            try await waitUntil { model.pendingPeopleActs.answered == model.pendingPeopleActs.submitted }
        }
    }

    /// An act the window submitted: its undo restores `before`, its redo `after`.
    struct Done {
        let act: PeopleAct
        let before: Model.State
        let after: Model.State
        var overtaken = false
    }

    // swiftlint:disable:next cyclomatic_complexity
    func walk(seed: UInt64, steps: Int) async throws -> Model.Walk {
        let names = (0 ..< 8).map { "w\($0).jpg" }
        let directory = try makeTestDirectory()
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(
            in: directory, files: names, database: directory.appending(path: "db/catalog.sqlite")
        )
        var random = SplitMix64(seed: seed)
        func roll(_ count: Int) -> Int {
            Int(random.next() % UInt64(count))
        }
        func pick<T>(_ values: [T]) -> T? {
            values.isEmpty ? nil : values[roll(values.count)]
        }
        for (index, name) in names.enumerated() {
            let identities = Array(Set((0 ..< 1 + roll(3)).map { _ in roll(4) })).sorted()
            let faces = identities.enumerated().map { place, identity in
                PeopleStoreTests.face(x: 0.05 + 0.3 * Double(place), toward: [identity * 8: 1, 200 + roll(200): 0.15])
            }
            let day = Date(timeIntervalSince1970: 1_580_000_000 + Double(index * 5 % 12) * 100 * 86400)
            try await library.readFaces([library.result(for: name, faces: faces, captured: day)])
        }
        let owner = PeopleAssignment(store: library.store, vectorSpace: .ample)
        try await owner.settle()
        let model = CatalogWindowViewModel(
            catalogStore: library.store,
            catalogProjection: CatalogProjection(volumeCapacity: ampleVolumeCapacity, cadence: .milliseconds(10)),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: PreferencesDomain.suite(UUID().uuidString),
            volumeCapacity: ampleVolumeCapacity,
            trashFiles: .refusing
        )
        model.startPeopleIntentConsumer()
        let window = try Window(
            library: library, model: model,
            queue: makeTestDatabaseQueue(path: #require(library.databaseURL).path(percentEncoded: false))
        )
        func faceID(_ key: Model.FaceKey) -> FaceID {
            FaceID(asset: library.id(key.path), index: key.index)
        }
        func key(_ id: FaceID) -> Model.FaceKey {
            Model.FaceKey(path: id.asset.relativePath.rawValue, index: id.index)
        }

        var done: [Done] = []
        var undone: [Done] = []
        var failures: [String] = []
        var performed = 0
        var mostPeople = 0
        func record(_ step: Int, _ what: String, _ problems: [String]) {
            failures += problems.map { "seed \(seed) step \(step) \(what): \($0)" }
        }
        func overtakeAll() {
            for index in done.indices {
                done[index].overtaken = true
            }
            for index in undone.indices {
                undone[index].overtaken = true
            }
        }

        for step in 0 ..< steps {
            try await window.show()
            let before = try Model.read(window.queue)
            mostPeople = max(mostPeople, before.people.count)
            let visible = before.faces.filter { !$0.value.isNotFace }.map(\.key).sorted()
            let people = before.people.keys.sorted().map(PersonID.init(rawValue:))
            let submitted = model.pendingPeopleActs.submitted
            let choice = roll(12)
            var act: PeopleAct?
            switch choice {
            case 0, 1:
                if let face = pick(visible), let person = pick(people) {
                    act = .move([faceID(face)], to: person)
                    model.nameFaces([faceID(face)], as: person)
                }
            case 2:
                if let face = pick(visible.filter { before.faces[$0]?.person != nil }) {
                    act = .removeName([faceID(face)])
                    model.removeNames([faceID(face)])
                }
            case 3:
                if let face = pick(visible) {
                    act = .notAFace([faceID(face)])
                    model.markNotFaces([faceID(face)])
                }
            case 4:
                if let person = pick(people) {
                    let hidden = roll(2) == 0
                    act = .setHidden(person, hidden)
                    model.setHidden(person, hidden)
                }
            case 5:
                if let (face, person) = pick(visible.compactMap { face in before.faces[face]?.person.map { (face, $0) } }) {
                    act = .makeKeyPhoto(faceID(face), of: PersonID(rawValue: person))
                    model.makeKeyPhoto(faceID(face), of: PersonID(rawValue: person))
                }
            case 6, 7:
                // The question, then Merge: the window asks only where its rules allow it.
                if let from = pick(people), let into = pick(people.filter { $0 != from }) {
                    model.askMerge(from, into: into)
                    if model.peopleSession.mergeQuestion != nil {
                        act = .merge(from, into: into)
                        model.answerMerge(true)
                    }
                }
            case 8, 9:
                if let last = done.popLast() {
                    model.undoLastChange()
                    try await window.untilAnswered()
                    let now = try Model.read(window.queue)
                    if !last.overtaken, now != last.before {
                        record(step, "undo \(last.act.logName)", Model.differences(expected: last.before, actual: now, act: last.act))
                    }
                    record(step, "after undo \(last.act.logName)", Model.violations(of: now))
                    overtakeAll()
                    undone.append(Done(act: last.act, before: last.before, after: last.after, overtaken: last.overtaken))
                }
                continue
            case 10:
                if let last = undone.popLast() {
                    model.redoLastChange()
                    try await window.untilAnswered()
                    let now = try Model.read(window.queue)
                    if !last.overtaken, now != last.after {
                        record(step, "redo \(last.act.logName)", Model.differences(expected: last.after, actual: now, act: last.act))
                    }
                    record(step, "after redo \(last.act.logName)", Model.violations(of: now))
                    overtakeAll()
                    done.append(Done(act: last.act, before: last.before, after: last.after, overtaken: last.overtaken))
                }
                continue
            default:
                await owner.request()
                try await owner.settle()
                let after = try Model.read(window.queue)
                record(step, "pass", Model.violations(of: after) + Model.passViolations(before: before, after: after))
                if after != before {
                    overtakeAll()
                }
                continue
            }
            guard let act else { continue }
            try await window.untilAnswered()
            let after = try Model.read(window.queue)
            guard model.pendingPeopleActs.submitted != submitted else {
                // The window kept the act to itself: nothing reached the store.
                if after != before {
                    record(step, "unsubmitted \(act.logName)", ["the catalog changed"])
                }
                continue
            }
            do {
                switch try Model.predict(act, from: before, key: key, created: nil, after: after) {
                case .refused:
                    if after != before {
                        record(step, act.logName, ["the model refuses \(act), the catalog performed it"])
                    }
                case let .state(expected):
                    if expected != after {
                        record(step, act.logName, Model.differences(expected: expected, actual: after, act: act))
                    }
                    // The store wrote it, so its undo is on the window's stack.
                    performed += 1
                    overtakeAll()
                    done.append(Done(act: act, before: before, after: after))
                    undone = []
                }
            } catch {
                record(step, act.logName, ["\(error)"])
            }
            record(step, "after \(act.logName)", Model.violations(of: after))
        }
        await library.store.shutdown()
        return Model.Walk(performed: performed, mostPeople: mostPeople, failures: failures)
    }

    @Test(arguments: [11, 12, 13, 14] as [UInt64])
    func theWindowsActsFollowTheModel(seed: UInt64) async throws {
        let walk = try await walk(seed: seed, steps: 50)
        // The walk compared the window's acts on people, not an empty catalog.
        #expect(walk.performed >= 10, "seed \(seed): only \(walk.performed) acts performed")
        #expect(walk.mostPeople > 0, "seed \(seed): no one to act on")
        #expect(walk.failures.isEmpty, "\(walk.failures.count) failures:\n\(walk.failures.prefix(40).joined(separator: "\n"))")
    }
}
