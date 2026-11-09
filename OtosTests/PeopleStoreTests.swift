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
        let sam = try await library.store.addPerson(name: "Sam", birthday: nil)
        let ian = try await library.store.addPerson(name: "Ian", birthday: "2022-11-03")
        let a0 = FaceID(asset: library.id("a.jpg"), index: 0)
        let a1 = FaceID(asset: library.id("a.jpg"), index: 1)
        let b0 = FaceID(asset: library.id("b.jpg"), index: 0)

        try await library.store.setPerson(sam, for: [a0])
        try await library.store.setRejected(true, person: ian, for: [a1])
        try await library.store.setNotAFace(true, for: [b0])

        let facts = try await library.store.peopleFacts()
        let byID = Dictionary(uniqueKeysWithValues: facts.faces.map { ($0.id, $0) })
        #expect(byID[a0]?.person == sam)
        #expect(byID[a1]?.rejected == [ian])
        #expect(byID[b0]?.isNotFace == true)
        #expect(facts.people.map(\.id) == [sam, ian])
        #expect(facts.people.last?.birthdaySeconds == PersonBirthday.seconds("2022-11-03"))
        await library.store.shutdown()
    }

    /// A birthday may be a full date or only a year, which counts from 1 January; anything
    /// else is refused rather than stored and ignored.
    @Test func aBirthdayIsADateOrAYear() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg"])
        let tyler = try await library.store.addPerson(name: "Tyler", birthday: "2025")
        #expect(try await library.store.peopleFacts().people.first { $0.id == tyler }?.birthdaySeconds
            == PersonBirthday.seconds("2025-01-01"))
        await #expect(throws: PeopleRuleViolation.invalidBirthday) {
            _ = try await library.store.addPerson(name: "Typo", birthday: "25")
        }
        await #expect(throws: PeopleRuleViolation.invalidBirthday) {
            try await library.store.updatePerson(tyler, name: "Tyler", birthday: "2025-13-01")
        }
        await library.store.shutdown()
    }

    /// The hard rules hold at the store, whoever asks: one photo holds a person once.
    @Test func aPersonIsConfirmedInAPhotoOnce() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg"])
        try await library.store.applyEnrichmentBatch([
            library.result(for: "a.jpg", faces: [Self.face(x: 0.1), Self.face(x: 0.6)]),
        ])
        let sam = try await library.store.addPerson(name: "Sam", birthday: nil)
        let faces = [0, 1].map { FaceID(asset: library.id("a.jpg"), index: $0) }

        await #expect(throws: PeopleRuleViolation.twoFacesOfOnePhoto) {
            try await library.store.setPerson(sam, for: faces)
        }
        try await library.store.setPerson(sam, for: [faces[0]])
        await #expect(throws: PeopleRuleViolation.personAlreadyInPhoto) {
            try await library.store.setPerson(sam, for: [faces[1]])
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
        let sam = try await library.store.addPerson(name: "Sam", birthday: nil)
        let ian = try await library.store.addPerson(name: "Ian", birthday: nil)
        let old = [0, 1].map { FaceID(asset: library.id("a.jpg"), index: $0) }
        try await library.store.setPerson(sam, for: [old[0]])
        try await library.store.setRejected(true, person: ian, for: [old[0]])
        try await library.store.setNotAFace(true, for: [old[1]])

        // The new reading finds the faces in the other order, shifted a little.
        try await library.store.applyEnrichmentBatch([
            library.result(for: "a.jpg", faces: [Self.face(x: 0.61), Self.face(x: 0.11)]),
        ])

        let facts = try await library.store.peopleFacts()
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
        let sam = try await library.store.addPerson(name: "Sam", birthday: nil)
        let twin = try await library.store.addPerson(name: nil, birthday: nil)
        let a0 = FaceID(asset: library.id("a.jpg"), index: 0)
        let a1 = FaceID(asset: library.id("a.jpg"), index: 1)
        let b0 = FaceID(asset: library.id("b.jpg"), index: 0)
        try await library.store.setPerson(sam, for: [a0])
        try await library.store.setPerson(twin, for: [a1])

        await #expect(throws: PeopleRuleViolation.bothInPhotos(count: 1)) {
            try await library.store.mergePerson(twin, into: sam)
        }
        try await library.store.setPerson(nil, for: [a1])
        try await library.store.setPerson(twin, for: [b0])
        try await library.store.mergePerson(twin, into: sam)
        var facts = try await library.store.peopleFacts()
        #expect(facts.people.map(\.id) == [sam])
        #expect(facts.faces.first { $0.id == b0 }?.person == sam)

        try await library.store.removePerson(sam)
        facts = try await library.store.peopleFacts()
        #expect(facts.people.isEmpty)
        #expect(facts.faces.allSatisfy { $0.person == nil })
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
