import CoreGraphics
import Foundation
@testable import OtosKit
import Testing

/// What the user decides about faces and people, as the catalog stores it (ADR 0047):
/// confirmations, rejections, "not a face", ignored groups, people, and how each survives a
/// new reading of the photo.
@Suite(.testDirectory)
struct PeopleStoreTests {
    @Test func confirmingRejectingAndFlaggingAreReadBackAsFacts() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg", "b.jpg"])
        try await library.store.applyEnrichmentBatch([
            library.result(for: "a.jpg", faces: [Self.face(x: 0.1), Self.face(x: 0.6)]),
            library.result(for: "b.jpg", faces: [Self.face(x: 0.3)]),
        ])
        let a0 = FaceID(asset: library.id("a.jpg"), index: 0)
        let a1 = FaceID(asset: library.id("a.jpg"), index: 1)
        let b0 = FaceID(asset: library.id("b.jpg"), index: 0)
        let sam = try #require(try await library.store.perform(.name([a0], "Sam")).person)
        let ian = try #require(try await library.store.perform(.name([], "Ian")).person)
        _ = try await library.store.perform(.edit(ian, name: "Ian", birthday: "2022-11-03"))

        _ = try await library.store.perform(.reject([a1], person: ian))
        _ = try await library.store.perform(.notAFace([b0]))

        let facts = try await library.store.peopleSnapshot()
        let byID = Dictionary(uniqueKeysWithValues: facts.faces.map { ($0.id, $0) })
        #expect(byID[a0]?.person == sam)
        #expect(byID[a1]?.rejected == [ian])
        #expect(byID[b0]?.isNotFace == true)
        #expect(facts.people.map(\.id) == [sam, ian])
        #expect(facts.people.map(\.name) == ["Sam", "Ian"])
        #expect(facts.people.last?.birthdaySeconds == PersonBirthday.seconds("2022-11-03"))
        #expect(facts.tiles[a1]?.box == Self.face(x: 0.6).box)
        await library.store.shutdown()
    }

    /// Naming faces with a name a person already holds gives them to that person, which is
    /// how an unnamed group joins a person.
    @Test func aNameAPersonHoldsIsThatPerson() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg", "b.jpg"])
        try await library.store.applyEnrichmentBatch([
            library.result(for: "a.jpg", faces: [Self.face(x: 0.1)]),
            library.result(for: "b.jpg", faces: [Self.face(x: 0.3)]),
        ])
        let sam = try await library.store.perform(.name([FaceID(asset: library.id("a.jpg"), index: 0)], "Sam")).person
        let again = try await library.store.perform(.name([FaceID(asset: library.id("b.jpg"), index: 0)], "Sam")).person
        #expect(again == sam)
        #expect(try await library.store.peopleSnapshot().people.count == 1)
        await library.store.shutdown()
    }

    /// A birthday may be a full date or only a year, which counts from 1 January; anything
    /// else is refused rather than stored and ignored.
    @Test func aBirthdayIsADateOrAYear() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg"])
        let tyler = try #require(try await library.store.perform(.name([], "Tyler")).person)
        _ = try await library.store.perform(.edit(tyler, name: "Tyler", birthday: "2025"))
        #expect(try await library.store.peopleSnapshot().people.first { $0.id == tyler }?.birthdaySeconds
            == PersonBirthday.seconds("2025-01-01"))
        await #expect(throws: PeopleRuleViolation.invalidBirthday) {
            _ = try await library.store.perform(.edit(tyler, name: "Tyler", birthday: "25"))
        }
        await #expect(throws: PeopleRuleViolation.invalidBirthday) {
            _ = try await library.store.perform(.edit(tyler, name: "Tyler", birthday: "2025-13-01"))
        }
        await library.store.shutdown()
    }

    /// The hard rules hold at the store, whoever asks: one photo holds a person once.
    @Test func aPersonIsConfirmedInAPhotoOnce() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg"])
        try await library.store.applyEnrichmentBatch([
            library.result(for: "a.jpg", faces: [Self.face(x: 0.1), Self.face(x: 0.6)]),
        ])
        let faces = [0, 1].map { FaceID(asset: library.id("a.jpg"), index: $0) }
        let sam = try #require(try await library.store.perform(.name([], "Sam")).person)

        await #expect(throws: PeopleRuleViolation.twoFacesOfOnePhoto) {
            _ = try await library.store.perform(.confirm(faces, as: sam))
        }
        _ = try await library.store.perform(.confirm([faces[0]], as: sam))
        await #expect(throws: PeopleRuleViolation.personAlreadyInPhoto) {
            _ = try await library.store.perform(.confirm([faces[1]], as: sam))
        }
        await library.store.shutdown()
    }

    /// Reading a photo again keeps what the user decided: the confirmed person and the
    /// rejections move to the new face that overlaps the old one; "not a face" does not.
    @Test func aNewReadingKeepsTheUsersDecisions() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg"])
        try await library.store.applyEnrichmentBatch([
            library.result(for: "a.jpg", faces: [Self.face(x: 0.1), Self.face(x: 0.6)]),
        ])
        let old = [0, 1].map { FaceID(asset: library.id("a.jpg"), index: $0) }
        let sam = try #require(try await library.store.perform(.name([old[0]], "Sam")).person)
        let ian = try #require(try await library.store.perform(.name([], "Ian")).person)
        _ = try await library.store.perform(.reject([old[0]], person: ian))
        _ = try await library.store.perform(.notAFace([old[1]]))

        // The new reading finds the faces in the other order, shifted a little.
        try await library.store.applyEnrichmentBatch([
            library.result(for: "a.jpg", faces: [Self.face(x: 0.61), Self.face(x: 0.11)]),
        ])

        let facts = try await library.store.peopleSnapshot()
        let samsFace = try #require(facts.faces.first { $0.id.index == 1 })
        let other = try #require(facts.faces.first { $0.id.index == 0 })
        #expect(samsFace.person == sam)
        #expect(samsFace.rejected == [ian])
        #expect(other.person == nil && !other.isNotFace)
        await library.store.shutdown()
    }

    /// Removing a person returns their faces to unnamed; merging moves them, and is refused
    /// when the two people share a photo.
    @Test func removingAndMergingPeople() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg", "b.jpg"])
        try await library.store.applyEnrichmentBatch([
            library.result(for: "a.jpg", faces: [Self.face(x: 0.1), Self.face(x: 0.6)]),
            library.result(for: "b.jpg", faces: [Self.face(x: 0.3)]),
        ])
        let a0 = FaceID(asset: library.id("a.jpg"), index: 0)
        let a1 = FaceID(asset: library.id("a.jpg"), index: 1)
        let b0 = FaceID(asset: library.id("b.jpg"), index: 0)
        let sam = try #require(try await library.store.perform(.name([a0], "Sam")).person)
        let twin = try #require(try await library.store.perform(.split([a1])).person)

        await #expect(throws: PeopleRuleViolation.bothInPhotos(count: 1)) {
            _ = try await library.store.perform(.merge(twin, into: sam))
        }
        _ = try await library.store.perform(.confirm([b0], as: twin))
        _ = try await library.store.perform(.reject([a1], person: twin))
        _ = try await library.store.perform(.merge(twin, into: sam))
        var facts = try await library.store.peopleSnapshot()
        #expect(facts.people.map(\.id) == [sam])
        #expect(facts.faces.first { $0.id == b0 }?.person == sam)
        #expect(facts.faces.first { $0.id == a1 }?.rejected == [sam])

        _ = try await library.store.perform(.remove(sam))
        facts = try await library.store.peopleSnapshot()
        #expect(facts.people.isEmpty)
        #expect(facts.faces.allSatisfy { $0.person == nil && $0.rejected.isEmpty })
        await library.store.shutdown()
    }

    /// Every act is undone exactly by the record it returns, and the undo's own record redoes
    /// it: people come back with their names, birthdays and faces, and people an act made
    /// go away again.
    @Test(arguments: UndoCase.allCases)
    func everyActIsUndoneExactly(_ undoCase: UndoCase) async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg", "b.jpg", "c.jpg"])
        try await library.store.applyEnrichmentBatch([
            library.result(for: "a.jpg", faces: [Self.face(x: 0.1), Self.face(x: 0.6)]),
            library.result(for: "b.jpg", faces: [Self.face(x: 0.3)]),
            library.result(for: "c.jpg", faces: [Self.face(x: 0.4)]),
        ])
        let a0 = FaceID(asset: library.id("a.jpg"), index: 0)
        let a1 = FaceID(asset: library.id("a.jpg"), index: 1)
        let b0 = FaceID(asset: library.id("b.jpg"), index: 0)
        let c0 = FaceID(asset: library.id("c.jpg"), index: 0)
        let sam = try #require(try await library.store.perform(.name([a0, b0], "Sam")).person)
        _ = try await library.store.perform(.edit(sam, name: "Sam", birthday: "2020-04-24"))
        let ian = try #require(try await library.store.perform(.name([a1], "Ian")).person)
        _ = try await library.store.perform(.reject([c0], person: sam))

        let act: PeopleAct = switch undoCase {
        case .confirm: .confirm([c0], as: ian)
        case .reject: .reject([b0], person: sam)
        case .notAFace: .notAFace([c0])
        case .ignore: .ignore([c0])
        case .name: .name([c0], "Tyler")
        case .split: .split([b0])
        case .edit: .edit(sam, name: "Sofi", birthday: nil)
        case .merge: .merge(ian, into: sam)
        case .remove: .remove(sam)
        }
        if case .merge = undoCase {
            // Sam and Ian share a.jpg; take Ian out of it first so the merge is allowed.
            _ = try await library.store.perform(.confirm([c0], as: ian))
            _ = try await library.store.perform(.reject([a1], person: ian))
        }
        let before = try await library.store.peopleSnapshot()
        let outcome = try await library.store.perform(act)
        let after = try await library.store.peopleSnapshot()
        #expect(after != before)

        let redo = try await library.store.restore(outcome.restore)
        #expect(try await library.store.peopleSnapshot() == before)
        try await library.store.restore(redo)
        #expect(try await library.store.peopleSnapshot() == after)
        await library.store.shutdown()
    }

    enum UndoCase: CaseIterable {
        case confirm, reject, notAFace, ignore, name, split, edit, merge, remove
    }

    /// People acts reach the window: each one is a catalog change.
    @Test func anActIsACatalogChange() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg"])
        var changes = await library.store.changeNotifications().makeAsyncIterator()
        _ = try await library.store.perform(.name([], "Sam"))
        #expect(await changes.next() == .catalogChanged)
        await library.store.shutdown()
    }

    /// A face 0.2 wide at (x, 0.3).
    static func face(x: Double) -> DetectedFace {
        DetectedFace(
            box: CGRect(x: x, y: 0.3, width: 0.2, height: 0.25),
            landmarks: (0 ..< 5).map { CGPoint(x: x + Double($0) / 64, y: 0.375) },
            quality: 0.5,
            embedding: FaceEnrichmentTests.face(seed: Int(x * 100)).embedding
        )
    }
}
