import CoreGraphics
import CoreServices
import Foundation
import GRDB
@testable import OtosKit
import Synchronization
import Testing

/// Who each face is, as the catalog stores it (ADR 0047): the user's acts and the hard rules
/// they are held to, what undoing each writes back, what a new reading of a photo keeps,
/// how assignment's guesses are written without ever overwriting the user's word, and the
/// People filter and likeness order the browser reads.
@Suite(.testScope)
struct PeopleStoreTests {
    @Test func theUsersActsAreReadBackAsFacts() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg", "b.jpg"])
        try await library.readFaces([
            library.result(for: "a.jpg", faces: [Self.face(x: 0.1), Self.face(x: 0.6)]),
            library.result(for: "b.jpg", faces: [Self.face(x: 0.3)]),
        ])
        let a0 = FaceID(asset: library.id("a.jpg"), index: 0)
        let a1 = FaceID(asset: library.id("a.jpg"), index: 1)
        let b0 = FaceID(asset: library.id("b.jpg"), index: 0)
        let sam = try #require(try await library.store.perform(.moveToNewPerson([a0], name: "Sam")).person)
        let ian = try #require(try await library.store.perform(.moveToNewPerson([a1], name: "Ian")).person)
        _ = try await library.store.perform(.edit(ian, name: "Ian", birthday: PersonBirthday("2022-11-03")))
        _ = try await library.store.perform(.removeName([a1]))
        _ = try await library.store.perform(.notAFace([b0]))
        _ = try await library.store.perform(.setFavorite(sam, true))
        _ = try await library.store.perform(.setHidden(ian, true))

        let facts = try await library.store.peopleSnapshot()
        let byID = Dictionary(uniqueKeysWithValues: facts.faces.map { ($0.id, $0) })
        #expect(byID[a0]?.assignment == .user(sam))
        #expect(byID[a1]?.assignment == .held)
        #expect(byID[a1]?.rejected == [ian])
        // A face the user marked as not a face is no face to assignment or People.
        #expect(byID[b0] == nil)
        #expect(facts.people.map(\.id) == [sam, ian])
        #expect(facts.people.map(\.name) == ["Sam", "Ian"])
        #expect(facts.people.map(\.isFavorite) == [true, false])
        #expect(facts.people.map(\.isHidden) == [false, true])
        #expect(facts.people.last?.birthday?.seconds == PersonBirthday("2022-11-03")?.seconds)
        let photoFaces = try await library.store.photoFaces(of: [library.id("a.jpg")], landedThrough: 0)
        // Ian is hidden: the photo's faces show the faces of people not hidden, and the
        // unidentified one.
        #expect(photoFaces.ownFaces(of: library.id("a.jpg")).map(\.id) == [a0, a1])
        #expect(photoFaces.face(a1)?.tile.box == Self.face(x: 0.6).box)
        #expect(try await library.store.namedPeople().map(\.id) == [sam])
        await library.store.shutdown()
    }

    /// One photo holds a person once. The user's face is the fact: giving them another face
    /// of the photo is refused; Otos's guess in the photo makes way.
    @Test func aPersonIsInAPhotoOnce() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg"])
        try await library.readFaces([
            library.result(for: "a.jpg", faces: [Self.face(x: 0.1), Self.face(x: 0.6)]),
        ])
        let faces = [0, 1].map { FaceID(asset: library.id("a.jpg"), index: $0) }
        let sam = try #require(try await library.store.perform(.moveToNewPerson([], name: "Sam")).person)

        await #expect(throws: PeopleRuleViolation.twoFacesOfOnePhoto) {
            _ = try await library.store.perform(.move(faces, to: sam))
        }
        try await library.store.applyAssignment(FaceAssignmentPlan(guesses: [.init(face: faces[0], person: .existing(sam))]))
        _ = try await library.store.perform(.move([faces[1]], to: sam))
        let snapshot = try await library.store.peopleSnapshot()
        #expect(snapshot.faces.map(\.assignment) == [.open, .user(sam)])
        await #expect(throws: PeopleRuleViolation.personAlreadyInPhoto) {
            _ = try await library.store.perform(.move([faces[0]], to: sam))
        }
        await library.store.shutdown()
    }

    /// A name is one person's: renaming to it or naming a new person with it is refused —
    /// merging is the act.
    @Test func aNameIsOnePersons() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg"])
        _ = try await library.store.perform(.moveToNewPerson([], name: "Sam"))
        let other = try #require(try await library.store.perform(.moveToNewPerson([], name: nil)).person)
        await #expect(throws: PeopleRuleViolation.nameTaken) {
            _ = try await library.store.perform(.edit(other, name: "Sam", birthday: nil))
        }
        await #expect(throws: PeopleRuleViolation.nameTaken) {
            _ = try await library.store.perform(.moveToNewPerson([], name: "Sam"))
        }
        await library.store.shutdown()
    }

    /// A birthday is a full date or only a year, which counts from 1 January. One after a
    /// photo the user gave the person is refused; Otos's guesses from before it lose them.
    @Test func aBirthdayHoldsTheUsersFacesAndDropsEarlierGuesses() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg", "b.jpg"])
        try await library.readFaces([
            library.result(for: "a.jpg", faces: [Self.face(x: 0.1)]),
            library.result(for: "b.jpg", faces: [Self.face(x: 0.3)]),
        ])
        let a = FaceID(asset: library.id("a.jpg"), index: 0)
        let b = FaceID(asset: library.id("b.jpg"), index: 0)
        let tyler = try #require(try await library.store.perform(.moveToNewPerson([a], name: "Tyler")).person)
        try await library.store.applyAssignment(FaceAssignmentPlan(guesses: [.init(face: b, person: .existing(tyler))]))
        // The scanned files carry no capture date, so no face predates any birthday yet.
        _ = try await library.store.perform(.edit(tyler, name: "Tyler", birthday: PersonBirthday("2025")))
        #expect(try await library.store.peopleSnapshot().people.first?.birthday?.seconds == PersonBirthday("2025-01-01")?.seconds)
        await library.store.shutdown()
    }

    /// Reading a photo again keeps the user's word: their face and its rejections, the seed,
    /// the removed name and the key photo move to the new face that overlaps the old;
    /// Otos's guess does not. A key photo the user chose on a face Otos had guessed is the
    /// user's word too: choosing it confirmed the face, so a re-read keeps both.
    @Test func aNewReadingKeepsTheUsersWord() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg", "b.jpg"])
        try await library.readFaces([
            library.result(for: "a.jpg", faces: [Self.face(x: 0.1), Self.face(x: 0.4), Self.face(x: 0.7)]),
            library.result(for: "b.jpg", faces: [Self.face(x: 0.3)]),
        ])
        let old = [0, 1, 2].map { FaceID(asset: library.id("a.jpg"), index: $0) }
        let guessed = FaceID(asset: library.id("b.jpg"), index: 0)
        let sam = try #require(try await library.store.perform(.moveToNewPerson([old[0]], name: "Sam")).person)
        let ian = try #require(try await library.store.perform(.moveToNewPerson([old[1]], name: "Ian")).person)
        _ = try await library.store.perform(.removeName([old[1]]))
        _ = try await library.store.perform(.makeKeyPhoto(old[0], of: sam))
        try await library.store.applyAssignment(FaceAssignmentPlan(guesses: [
            .init(face: old[2], person: .existing(ian)), .init(face: guessed, person: .existing(ian)),
        ]))
        _ = try await library.store.perform(.makeKeyPhoto(guessed, of: ian))
        #expect(try await library.store.peopleSnapshot().faces.first { $0.id == guessed }?.assignment == .user(ian))

        // The new reading finds the faces in another order, shifted a little.
        try await library.readFaces([
            library.result(for: "a.jpg", faces: [Self.face(x: 0.71), Self.face(x: 0.41), Self.face(x: 0.11)]),
            library.result(for: "b.jpg", faces: [Self.face(x: 0.31)]),
        ])

        let snapshot = try await library.store.peopleSnapshot()
        let byIndex = Dictionary(uniqueKeysWithValues: snapshot.faces.filter { $0.id.asset == library.id("a.jpg") }.map { ($0.id.index, $0) })
        #expect(byIndex[2]?.assignment == .user(sam))
        #expect(byIndex[1]?.assignment == .held)
        #expect(byIndex[1]?.rejected == [ian])
        #expect(byIndex[0]?.assignment == .open)
        #expect(snapshot.keyPhotos[sam]?.index == 2)
        #expect(snapshot.faces.first { $0.id == guessed }?.assignment == .user(ian))
        #expect(snapshot.keyPhotos[ian] == guessed)
        await library.store.shutdown()
    }

    /// The faces stamp a migration clears owes a re-read, but says nothing of the source the
    /// faces came from: a re-read of the same source keeps "not a face" and a named face it
    /// does not find, and a re-read after the file changed reads it afresh.
    @Test func aClearedStampStillKnowsTheSourceTheFacesCameFrom() async throws {
        let directory = try makeTestDirectory()
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(
            in: directory, files: ["a.jpg", "b.jpg"], database: directory.appending(path: "db/catalog.sqlite")
        )
        for name in ["a.jpg", "b.jpg"] {
            try await library.readFaces([library.result(for: name, faces: [Self.face(x: 0.1), Self.face(x: 0.6)])])
            _ = try await library.store.perform(.notAFace([FaceID(asset: library.id(name), index: 0)]))
            _ = try await library.store.perform(.moveToNewPerson([FaceID(asset: library.id(name), index: 1)], name: "Sam \(name)"))
        }
        let database = try DatabaseQueue(path: #require(library.databaseURL).path(percentEncoded: false))
        try await database.write { db in
            // A migration owes every re-read; b's file changed before its re-read.
            try db.execute(sql: "UPDATE media_asset SET faces_source_size = NULL, faces_source_mtime = NULL")
            try db.execute(sql: "UPDATE media_asset SET byte_size = byte_size + 1 WHERE relative_path = 'b.jpg'")
        }
        try await library.readFaces([
            library.result(for: "a.jpg", faces: [Self.face(x: 0.1)]),
            library.result(for: "b.jpg", faces: [Self.face(x: 0.1)]),
        ])

        let rows = try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT relative_path, is_not_face, person_id FROM face ORDER BY relative_path, face_index")
                .map { "\($0["relative_path"] as String) notFace=\($0["is_not_face"] as Int) named=\(($0["person_id"] as Int64?) != nil)" }
        }
        #expect(rows == ["a.jpg notFace=1 named=false", "a.jpg notFace=0 named=true", "b.jpg notFace=0 named=false"])
        await library.store.shutdown()
    }

    /// A face row no reading writes fails only its own photo. One with no vector row: the
    /// People read leaves that photo out. One whose vector holds no embedding: People finds it
    /// as it reads the vectors and leaves the face out of assignment. Either way the photo's
    /// faces are owed again, and a new reading replaces the row.
    @Test func aMalformedFaceRowIsLeftOutAndReadAgain() async throws {
        let directory = try makeTestDirectory()
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(
            in: directory, files: ["a.jpg", "b.jpg"], database: directory.appending(path: "db/catalog.sqlite")
        )
        try await library.readFaces([
            library.result(for: "a.jpg", faces: [Self.face(x: 0.1), Self.face(x: 0.6)]),
            library.result(for: "b.jpg", faces: [Self.face(x: 0.3)]),
        ])
        let database = try DatabaseQueue(path: #require(library.databaseURL).path(percentEncoded: false))
        try await database.write { db in
            try db.execute(sql: "DELETE FROM face_embedding WHERE relative_path = 'a.jpg' AND face_index = 1")
        }

        let snapshot = try await library.store.peopleSnapshot()
        #expect(snapshot.faces.map(\.id.asset) == [library.id("b.jpg")])
        #expect(try await library.store.previewFaceCandidates(limit: 10).candidates.map(\.id) == [library.id("a.jpg")])

        try await library.readFaces([library.result(for: "a.jpg", faces: [Self.face(x: 0.1), Self.face(x: 0.6)])])
        #expect(try await library.store.peopleSnapshot().faces.count == 3)

        try await database.write { db in
            try db.execute(sql: "UPDATE face_embedding SET embedding = x'00' WHERE relative_path = 'b.jpg'")
        }
        let state = try await PeopleAssignment.settle(store: library.store, libraries: #require(await library.store.loadedLibraries()))
        #expect(state.hasFaces, "the gallery shows what is stored")
        #expect(try await library.store.previewFaceCandidates(limit: 10).candidates.map(\.id) == [library.id("b.jpg")])
        await library.store.shutdown()
    }

    /// A merged person's birthday holds both people's faces: Otos's guesses and seeds of
    /// either from before it lose their person, as Set Birthday's do, and the user's are
    /// refused.
    @Test func aMergeHoldsBothPeopleToTheMergedBirthday() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg", "b.jpg"])
        try await library.readFaces([
            library.result(for: "a.jpg", faces: [Self.face(x: 0.1)], captured: Date(timeIntervalSince1970: 1_262_304_000)),
            library.result(for: "b.jpg", faces: [Self.face(x: 0.3)], captured: Date(timeIntervalSince1970: 1_577_836_800)),
        ])
        let early = FaceID(asset: library.id("a.jpg"), index: 0)
        let late = FaceID(asset: library.id("b.jpg"), index: 0)
        try await library.store.applyAssignment(FaceAssignmentPlan(newPeople: [[early]]))
        let found = try #require(try await library.store.peopleSnapshot().people.first?.id)
        let sam = try #require(try await library.store.perform(.moveToNewPerson([late], name: "Sam")).person)
        _ = try await library.store.perform(.edit(sam, name: "Sam", birthday: PersonBirthday("2015")))

        _ = try await library.store.perform(.merge(found, into: sam))

        let snapshot = try await library.store.peopleSnapshot()
        #expect(snapshot.faces.first { $0.id == early }?.assignment == .open)
        #expect(snapshot.faces.first { $0.id == late }?.assignment == .user(sam))
        await library.store.shutdown()
    }

    /// Merging gives the first person's faces to the second, which keeps its name and takes
    /// the first's when it has none, and is a favourite if either was. Refused when the user's
    /// faces or seeds put both in one photo; Otos's guess of one in the other's photo is
    /// dropped.
    @Test func mergingPeople() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg", "b.jpg"])
        try await library.readFaces([
            library.result(for: "a.jpg", faces: [Self.face(x: 0.1), Self.face(x: 0.6)]),
            library.result(for: "b.jpg", faces: [Self.face(x: 0.3)]),
        ])
        let a0 = FaceID(asset: library.id("a.jpg"), index: 0)
        let a1 = FaceID(asset: library.id("a.jpg"), index: 1)
        let b0 = FaceID(asset: library.id("b.jpg"), index: 0)
        let named = try #require(try await library.store.perform(.moveToNewPerson([a0], name: "Sam")).person)
        let found = try #require(try await library.store.perform(.moveToNewPerson([b0], name: nil)).person)
        _ = try await library.store.perform(.setFavorite(named, true))
        try await library.store.applyAssignment(FaceAssignmentPlan(guesses: [.init(face: a1, person: .existing(found))]))

        _ = try await library.store.perform(.merge(named, into: found))

        let snapshot = try await library.store.peopleSnapshot()
        #expect(snapshot.people.map(\.id) == [found])
        #expect(snapshot.people.first?.name == "Sam")
        #expect(snapshot.people.first?.isFavorite == true)
        #expect(snapshot.faces.map(\.assignment) == [.user(found), .open, .user(found)])

        // A face the merged person was said not to be is not the merged person either.
        _ = try await library.store.perform(.removeName([b0]))
        #expect(try await library.store.peopleSnapshot().faces.first { $0.id == b0 }?.rejected == [found])

        let other = try #require(try await library.store.perform(.moveToNewPerson([a1], name: "Ian")).person)
        await #expect(throws: PeopleRuleViolation.bothIn(MediaCount(photos: 1))) {
            _ = try await library.store.perform(.merge(other, into: found))
        }
        await library.store.shutdown()
    }

    /// A person has one key photo; a face that leaves them takes it along.
    @Test func aKeyPhotoIsOneFaceOfThePerson() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg", "b.jpg"])
        try await library.readFaces([
            library.result(for: "a.jpg", faces: [Self.face(x: 0.1)]),
            library.result(for: "b.jpg", faces: [Self.face(x: 0.3)]),
        ])
        let a = FaceID(asset: library.id("a.jpg"), index: 0)
        let b = FaceID(asset: library.id("b.jpg"), index: 0)
        let sam = try #require(try await library.store.perform(.moveToNewPerson([a], name: "Sam")).person)
        _ = try await library.store.perform(.move([b], to: sam))
        _ = try await library.store.perform(.makeKeyPhoto(a, of: sam))
        _ = try await library.store.perform(.makeKeyPhoto(b, of: sam))
        #expect(try await library.store.peopleSnapshot().keyPhotos == [sam: b])

        _ = try await library.store.perform(.removeName([b]))
        #expect(try await library.store.peopleSnapshot().keyPhotos.isEmpty)
        await #expect(throws: PeopleRuleViolation.unknownFace) {
            _ = try await library.store.perform(.makeKeyPhoto(b, of: sam))
        }
        await library.store.shutdown()
    }

    /// Undo writes back exactly what each act changed, and redo is the act again.
    @Test func undoRestoresEveryAct() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg", "b.jpg"])
        try await library.readFaces([
            library.result(for: "a.jpg", faces: [Self.face(x: 0.1), Self.face(x: 0.6)]),
            library.result(for: "b.jpg", faces: [Self.face(x: 0.3)]),
        ])
        let a0 = FaceID(asset: library.id("a.jpg"), index: 0)
        let a1 = FaceID(asset: library.id("a.jpg"), index: 1)
        let b0 = FaceID(asset: library.id("b.jpg"), index: 0)
        let sam = try #require(try await library.store.perform(.moveToNewPerson([a0], name: "Sam")).person)
        let ian = try #require(try await library.store.perform(.moveToNewPerson([b0], name: "Ian")).person)
        try await library.store.applyAssignment(FaceAssignmentPlan(guesses: [.init(face: a1, person: .existing(ian))]))
        _ = try await library.store.perform(.makeKeyPhoto(b0, of: ian))

        func state() async throws -> PeopleSnapshot {
            let snapshot = try await library.store.peopleSnapshot()
            return PeopleSnapshot(faces: snapshot.faces, people: snapshot.people, keyPhotos: snapshot.keyPhotos)
        }
        let before = try await state()
        for act: PeopleAct in [
            .move([a1], to: ian), .moveToNewPerson([a1], name: "Tyler"), .removeName([a0]), .notAFace([b0]),
            .edit(sam, name: "Sam M", birthday: PersonBirthday("2020")), .merge(ian, into: sam),
            .setHidden(ian, true), .setFavorite(sam, true), .makeKeyPhoto(a0, of: sam),
        ] {
            let outcome = try await library.store.perform(act)
            let after = try await state()
            #expect(after != before, "\(act.logName) changed nothing")
            let redo = try await library.store.restore(outcome.restore)
            #expect(try await state() == before, "undoing \(act.logName)")
            try await library.store.restore(redo)
            #expect(try await state() == after, "redoing \(act.logName)")
            try await library.store.restore(outcome.restore)
        }
        await library.store.shutdown()
    }

    /// Assignment writes a guess only where the face is still Otos's to decide: a face the
    /// user gave someone while the pass ran keeps their word. A person Otos found is deleted
    /// once they have no face left and the user said nothing about them.
    @Test func assignmentNeverOverwritesTheUsersWord() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg", "b.jpg"])
        try await library.readFaces([
            library.result(for: "a.jpg", faces: [Self.face(x: 0.1)]),
            library.result(for: "b.jpg", faces: [Self.face(x: 0.3)]),
        ])
        let a = FaceID(asset: library.id("a.jpg"), index: 0)
        let b = FaceID(asset: library.id("b.jpg"), index: 0)
        let ian = try #require(try await library.store.perform(.moveToNewPerson([], name: "Ian")).person)
        var plan = FaceAssignmentPlan()
        plan.newPeople = [[a, b]]
        plan.likeness = [a: 0.75]
        // The new person, its two seeds and the likeness.
        #expect(try await library.store.applyAssignment(plan) == 4)
        let found = try #require(try await library.store.peopleSnapshot().people.last?.id)
        _ = try await library.store.perform(.move([a, b], to: ian))

        // Planned before the move: neither guess lands, and Otos's person, with no face left
        // and nothing the user said, is gone.
        #expect(try await library.store.applyAssignment(FaceAssignmentPlan(guesses: [
            .init(face: a, person: .existing(found)), .init(face: b, person: nil),
        ], emptied: [found])) == 1)

        let snapshot = try await library.store.peopleSnapshot()
        #expect(snapshot.faces.map(\.assignment) == [.user(ian), .user(ian)])
        #expect(snapshot.likeness == [a: 0.75])
        #expect(snapshot.people.map(\.id) == [ian])
        #expect(try await library.store.applyAssignment(FaceAssignmentPlan()) == 0)
        await library.store.shutdown()
    }

    /// A lapsed seed loses its person only while it is still that person's seed, and the
    /// person Otos found is gone once no face is theirs; a seed the user moved meanwhile
    /// keeps the user's word.
    @Test func aLapsedSeedIsReleasedOnlyWhileStillASeed() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg", "b.jpg"])
        try await library.readFaces([
            library.result(for: "a.jpg", faces: [Self.face(x: 0.1)]),
            library.result(for: "b.jpg", faces: [Self.face(x: 0.3)]),
        ])
        let a = FaceID(asset: library.id("a.jpg"), index: 0)
        let b = FaceID(asset: library.id("b.jpg"), index: 0)
        var seeding = FaceAssignmentPlan()
        seeding.newPeople = [[a, b]]
        try await library.store.applyAssignment(seeding)
        let found = try #require(try await library.store.peopleSnapshot().people.last?.id)
        let ian = try #require(try await library.store.perform(.moveToNewPerson([b], name: "Ian")).person)

        // Planned before the move: a is released, b keeps the user's word, and the person
        // Otos found has no face left.
        #expect(try await library.store.applyAssignment(FaceAssignmentPlan(
            emptied: [found], lapsedSeeds: [a: found, b: found]
        )) == 2)

        let snapshot = try await library.store.peopleSnapshot()
        #expect(snapshot.faces.map(\.assignment) == [.open, .user(ian)])
        #expect(snapshot.people.map(\.id) == [ian])
        await library.store.shutdown()
    }

    /// A person Otos found is not created when none of its seeds can still be written (the
    /// user named them since the snapshot), and a guess of that person waits for the next
    /// assignment instead of writing anything.
    @Test func aNewPersonWithNoSeedLeftIsNotCreated() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg", "b.jpg", "c.jpg"])
        try await library.readFaces([
            library.result(for: "a.jpg", faces: [Self.face(x: 0.1)]),
            library.result(for: "b.jpg", faces: [Self.face(x: 0.3)]),
            library.result(for: "c.jpg", faces: [Self.face(x: 0.5)]),
        ])
        let a = FaceID(asset: library.id("a.jpg"), index: 0)
        let b = FaceID(asset: library.id("b.jpg"), index: 0)
        let c = FaceID(asset: library.id("c.jpg"), index: 0)
        let sam = try #require(try await library.store.perform(.moveToNewPerson([a, b], name: "Sam")).person)
        var plan = FaceAssignmentPlan()
        plan.newPeople = [[a, b]]
        plan.guesses = [FaceAssignmentPlan.Guess(face: c, person: .new(0))]

        #expect(try await library.store.applyAssignment(plan) == 0)

        let snapshot = try await library.store.peopleSnapshot()
        #expect(snapshot.people.map(\.id) == [sam])
        #expect(snapshot.faces.map(\.assignment) == [.user(sam), .user(sam), .open])
        await library.store.shutdown()
    }

    /// The assignment rules SQL reads come from `FaceAssignment`, and a stored row no
    /// assignment can hold is an error, never an open face.
    @Test func aStoredAssignmentIsReadByTheAssignmentRules() throws {
        #expect(FaceAssignmentColumn.sqlList { $0.isGuessable } == "(0, 1)")
        #expect(FaceAssignmentColumn.sqlList { $0.isAnchor } == "(2, 3)")
        let person = PersonID(rawValue: 7)
        #expect(try FaceAssignmentColumn.assignment(column: FaceAssignmentColumn.seed.rawValue, person: 7) == .seed(person))
        #expect(try FaceAssignmentColumn.assignment(column: FaceAssignmentColumn.user.rawValue, person: nil) == .open)
        #expect(try FaceAssignmentColumn.assignment(column: FaceAssignmentColumn.held.rawValue, person: nil) == .held)
        #expect(throws: FaceAssignmentColumn.Malformed(column: 9, person: nil)) {
            try FaceAssignmentColumn.assignment(column: 9, person: nil)
        }
        #expect(throws: FaceAssignmentColumn.Malformed(column: FaceAssignmentColumn.open.rawValue, person: 7)) {
            try FaceAssignmentColumn.assignment(column: FaceAssignmentColumn.open.rawValue, person: 7)
        }
    }

    /// A person's photos and the People filter: several people are photos of them together,
    /// `Unidentified` a face with no person; in a person's photos the likeness order puts the
    /// face least like them first.
    @Test func thePeopleFilterAndTheLikenessOrder() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
        try await library.readFaces([
            library.result(for: "a.jpg", faces: [Self.face(x: 0.1), Self.face(x: 0.6)]),
            library.result(for: "b.jpg", faces: [Self.face(x: 0.3)]),
            library.result(for: "c.jpg", faces: [Self.face(x: 0.5)]),
            library.result(for: "d.jpg", faces: []),
        ])
        let a0 = FaceID(asset: library.id("a.jpg"), index: 0)
        let a1 = FaceID(asset: library.id("a.jpg"), index: 1)
        let b0 = FaceID(asset: library.id("b.jpg"), index: 0)
        let sam = try #require(try await library.store.perform(.moveToNewPerson([a0], name: "Sam")).person)
        let ian = try #require(try await library.store.perform(.moveToNewPerson([a1], name: "Ian")).person)
        try await library.store.applyAssignment(FaceAssignmentPlan(
            guesses: [.init(face: b0, person: .existing(sam))],
            likeness: [a0: 0.9, b0: 0.5]
        ))
        func photos(
            _ filter: MediaFilter = .all, in scope: SidebarSelection? = nil, sort: MediaSortOrder = .filenameAscending
        ) async throws -> [String] {
            try await library.store.orderedAssetIDs(
                for: CatalogQueryDescriptor(scope: scope ?? .library(library.rootPath), filter: filter, sort: sort),
                availableLibraryPaths: [library.rootPath]
            ).ids.map(\.relativePath.rawValue)
        }
        #expect(try await photos(in: .person(sam)) == ["a.jpg", "b.jpg"])
        #expect(try await photos(in: .person(sam), sort: .likenessLeast) == ["b.jpg", "a.jpg"])
        #expect(try await photos(in: .person(sam), sort: .likenessMost) == ["a.jpg", "b.jpg"])
        #expect(try await photos(MediaFilter(people: [ian]), in: .person(sam)) == ["a.jpg"])
        var filter = MediaFilter(people: [sam])
        #expect(try await photos(filter) == ["a.jpg", "b.jpg"])
        // Several people are photos of them together.
        filter.people.insert(ian)
        #expect(try await photos(filter) == ["a.jpg"])
        #expect(try await photos(MediaFilter(unassignedFaces: true)) == ["c.jpg"])
        await library.store.shutdown()
    }

    /// People acts and assignments that wrote reach the window: each is a catalog change.
    @Test func anActOrAnAssignmentIsACatalogChange() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg"])
        try await library.readFaces([library.result(for: "a.jpg", faces: [Self.face(x: 0.1)])])
        var changes = await library.store.changeNotifications().makeAsyncIterator()
        let sam = try #require(try await library.store.perform(.moveToNewPerson([], name: "Sam")).person)
        #expect(await changes.next() == .changed(.faces))
        try await library.store.applyAssignment(FaceAssignmentPlan(guesses: [
            .init(face: FaceID(asset: library.id("a.jpg"), index: 0), person: .existing(sam)),
        ]))
        #expect(await changes.next() == .changed(.faces))
        await library.store.shutdown()
    }

    /// A People pass writes in pages: on a library whose every face is owed a guess and a
    /// likeness, no transaction of the pass changes more than `backgroundWritePage` rows, so a
    /// write the user is waiting on never queues behind all of it. The guard over every People
    /// write: a pass writing in one transaction again fails it.
    @Test func noPeopleWriteTransactionChangesMoreThanAPage() async throws {
        let count = 3 * CatalogStore.backgroundWritePage
        let (library, databaseURL) = try await Self.lookalikes(count, in: makeTestDirectory())
        await library.store.shutdown()
        // A store opened on the catalog afresh counts only the pass's transactions.
        let store = makeTestStore(location: .databaseFile(databaseURL))
        try await store.start(scansSavedLibraries: false)
        let libraries = try #require(await store.loadedLibraries())
        let state = try await PeopleAssignment.settle(store: store, libraries: libraries)
        #expect(state.people.first?.media.total == count)
        let writes = store.use().connections.holds.filter { $0.role == "main.writer" }
        #expect(writes.contains { $0.operation == "applyAssignment" && $0.count >= 2 }, "\(writes)")
        for write in writes {
            #expect(write.mostRows <= CatalogStore.backgroundWritePage, "\(write.operation): \(write.mostRows) rows")
        }
        await store.shutdown()
    }

    /// People paints from what the catalog stores and assigns only when what assignment reads
    /// moved: a pass on a catalog whose assignment settled — a launch with nothing changed —
    /// publishes the stored guesses and reads no vector; ranking a photo's faces reads the
    /// vectors then; a new face is assigned, and only the vectors above the ones held are read.
    @Test func peoplePaintsWhatIsStoredAndAssignsOnlyWhenItsInputsMove() async throws {
        let (library, databaseURL) = try await Self.lookalikes(4, in: makeTestDirectory(), extraFiles: ["new.jpg"])
        let first = try await PeopleAssignment.settle(store: library.store, libraries: #require(await library.store.loadedLibraries()))
        let sam = try #require(first.people.first?.id)
        #expect(first.person(sam)?.media.total == 4)
        await library.store.shutdown()

        let store = makeTestStore(location: .databaseFile(databaseURL))
        try await store.start(scansSavedLibraries: false)
        let libraries = try #require(await store.loadedLibraries())
        /// A read is counted as its transaction ends, which can be after its caller resumed
        /// (`readFreeingConnection` frees the caller first), so a count is waited for.
        func vectorReads() -> Int {
            store.use().connections.holds.filter { $0.operation == "faceEmbeddings" }.reduce(0) { $0 + $1.count }
        }
        func vectorReads(reaching count: Int) async throws -> Int {
            try await waitUntil { vectorReads() >= count }
            return vectorReads()
        }
        let people = PeopleAssignment(store: store)
        try await people.settle()
        #expect(try await store.gallery(libraries: libraries).person(sam)?.media.total == 4)

        let candidates = await people.candidates(for: [library.id("0.jpg")])
        #expect(candidates?.count == 1)
        // The ranking's one page, and none before it: the settled pass read no vector.
        let afterRanking = try await vectorReads(reaching: 1)
        #expect(afterRanking == 1)

        let reopened = FaceEnrichmentTests.ScannedLibrary(
            store: store, root: library.root, rootPath: library.rootPath, emit: library.emit, databaseURL: databaseURL
        )
        try await reopened.readFaces([reopened.result(for: "new.jpg", faces: [Self.lookalike(4)])])
        try await people.settle()
        #expect(try await store.gallery(libraries: libraries).person(sam)?.media.total == 5)
        #expect(try await vectorReads(reaching: afterRanking + 1) == afterRanking + 1, "one page above the vectors held")
        await store.shutdown()
    }

    /// What People costs at the owner's scale, on a generated catalog of his shape whose faces
    /// carry real unit vectors, one direction per person: the first gallery's read, a first
    /// pass that assigns, a settled pass after it, and the footprint the process reached
    /// while they ran. On demand (`OTOS_SCALE_TEST=1`), since it writes a 2.3 GB file; a
    /// measurement written to `build/people-cost/owner.txt`, not a benchmark.
    @Test(.enabled(if: StallReproductionTests.ownerSize))
    func peopleCostsOnTheOwnersShape() async throws {
        let directory = try makeTestDirectory()
        let catalog = try OwnerShapedCatalog.make(in: directory, scale: 1)
        let queue = try DatabaseQueue(path: catalog.databaseURL.path(percentEncoded: false))
        try await queue.write { db in
            let ids = try Row.fetchAll(db, sql: "SELECT e.id, f.person_id FROM face_embedding e JOIN face f USING (library_root_id, relative_path, face_index)")
            let update = try db.makeStatement(sql: "UPDATE face_embedding SET embedding = ? WHERE id = ?")
            var generator = SplitMix64(seed: 5)
            for row in ids {
                let person = Int((row[1] as Int64?) ?? 0)
                var values = [Float](repeating: 0, count: FaceEmbeddingModel.dimensions)
                values[person % values.count] = 1
                values[(person / values.count + 7 * person) % values.count] += 0.5
                for _ in 0 ..< 6 {
                    values[Int(generator.next() % UInt64(values.count))] += 0.12
                }
                try update.execute(arguments: [FaceStorage.embeddingData(FaceEmbedding(normalizing: values)!), row[0] as Int64])
            }
        }
        try queue.close()
        let store = makeTestStore(location: .databaseFile(catalog.databaseURL))
        try await store.start(scansSavedLibraries: false)
        let libraries = try #require(await store.loadedLibraries())
        let mb = { (bytes: UInt64) in bytes / 1_048_576 }
        let peak = Mutex<UInt64>(0)
        let sampler = Task.detached {
            while !Task.isCancelled {
                let footprint = ProcessResourceSample.current().footprintBytes
                peak.withLock { $0 = max($0, footprint) }
                // time: measurement — samples the footprint while the passes run; nothing waits on it.
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { sampler.cancel() }
        var fields: [String] = []
        /// Runs `body`, recording the footprint before and after it and the highest between.
        func phase<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
            let before = ProcessResourceSample.current().footprintBytes
            peak.withLock { $0 = before }
            let start = ContinuousClock.now
            let value = try await body()
            let after = ProcessResourceSample.current().footprintBytes
            fields.append(
                "\(name)Ms=\(DiagnosticsTiming.milliseconds(since: start)) \(name)BeforeMB=\(mb(before)) "
                    + "\(name)PeakMB=\(mb(peak.withLock { max($0, after) })) \(name)AfterMB=\(mb(after))"
            )
            return value
        }
        let paths = CatalogWindowPolicy.availablePaths(from: libraries)
        // The parts of one pass, each alone, kept alive as a pass keeps them.
        let snapshot = try await phase("snapshot") { try await store.peopleSnapshot() }
        let galleryFacts = await phase("galleryFacts") { snapshot.computedGalleryFacts }
        var vectors = FaceVectors()
        try await phase("vectors") {
            while true {
                let page = try await store.faceEmbeddings(after: vectors.owed, limit: FaceVectors.pageSize)
                vectors.add(page)
                if page.count < FaceVectors.pageSize {
                    break
                }
            }
        }
        let facts = await phase("facts") { snapshot.facts(with: vectors) }
        let plan = await phase("kernel") { FaceAssignmentPlan.assignment(of: snapshot, facts: facts) }
        fields.append("faces=\(snapshot.faces.count) people=\(galleryFacts.count) guesses=\(plan.guesses.count)")
        // The three passes the owner meets, each on a fresh owner.
        _ = try await phase("firstAssignment") { try await PeopleAssignment.settle(store: store, libraries: libraries) }
        _ = try await phase("settledLaunch") { try await PeopleAssignment.settle(store: store, libraries: libraries) }
        // The gallery's own read, as the window makes it on a visit.
        _ = try await phase("galleryRead") { try await store.peopleGallery(availableLibraryPaths: paths) }
        // One face read again: a new vector row for it, as a new reading writes.
        let writer = try DatabaseQueue(path: catalog.databaseURL.path(percentEncoded: false))
        func readAgain() async throws {
            try await writer.write { db in
                let row = try #require(try Row.fetchOne(db, sql: "SELECT * FROM face_embedding ORDER BY id DESC LIMIT 1"))
                try db.execute(sql: "DELETE FROM face_embedding WHERE id = ?", arguments: [row["id"] as Int64])
                try db.execute(sql: FaceEmbeddingSQL.insertSQL, arguments: [
                    row["library_root_id"] as Int64, row["relative_path"] as String, row["face_index"] as Int, row["embedding"] as Data,
                ])
            }
        }
        try await readAgain()
        let owner = PeopleAssignment(store: store)
        try await owner.settle()
        try await readAgain()
        try await phase("oneNewFace") { try await owner.settle() }
        let line = "op=peopleCost " + fields.joined(separator: " ")
        let url = SourceTree.root.appending(path: "build/people-cost/owner.txt")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(line.utf8).write(to: url)
        try writer.close()
        await store.shutdown()
    }

    /// A vector written after a snapshot was read is a newer reading of some face, which the next
    /// snapshot names: forgetting the vectors a snapshot does not name keeps every vector above
    /// what that snapshot could see, so the newer reading is never dropped and never re-read.
    @Test func aVectorWrittenAfterTheSnapshotIsKept() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg", "b.jpg"])
        try await library.readFaces([library.result(for: "a.jpg", faces: [Self.face(x: 0.1)])])
        let snapshot = try await library.store.peopleSnapshot()
        #expect(snapshot.vectorHorizon == snapshot.faces.first?.vector)
        // A reading lands between the snapshot's read and the vectors' read.
        try await library.readFaces([library.result(for: "b.jpg", faces: [Self.face(x: 0.3)])])
        var vectors = FaceVectors()
        try await vectors.add(library.store.faceEmbeddings(after: 0, limit: FaceVectors.pageSize))
        #expect(vectors.count == 2)
        vectors.keep(snapshot.vectors, through: snapshot.vectorHorizon)
        #expect(vectors.count == 2, "the newer reading stays")
        let next = try await library.store.peopleSnapshot()
        #expect(next.faces.allSatisfy { vectors.vector($0.vector) != nil })
        await library.store.shutdown()
    }

    /// A new person is made only with a seed that lands: a plan whose seeds the user has
    /// since taken leaves no person behind, in any page.
    @Test func aNewPersonIsMadeOnlyWithASeed() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg", "b.jpg"])
        try await library.readFaces([
            library.result(for: "a.jpg", faces: [Self.face(x: 0.1)]),
            library.result(for: "b.jpg", faces: [Self.face(x: 0.3)]),
        ])
        let a = FaceID(asset: library.id("a.jpg"), index: 0)
        let b = FaceID(asset: library.id("b.jpg"), index: 0)
        _ = try await library.store.perform(.moveToNewPerson([a], name: "Sam"))
        _ = try await library.store.perform(.moveToNewPerson([b], name: "Ian"))
        var plan = FaceAssignmentPlan()
        plan.newPeople = [[a, b]]
        #expect(try await library.store.applyAssignment(plan) == 0)
        #expect(try await library.store.peopleSnapshot().people.map(\.name) == ["Sam", "Ian"])
        await library.store.shutdown()
    }

    /// What a metadata write wakes: a date or render of a photo that holds no face wakes no
    /// People pass, however many arrive; one of a photo that holds a face wakes one. The guard
    /// over People's wake (`PeopleAssignment.inputs`, `.faceTiles`).
    @Test func onlyAFacedPhotosDateOrImageWakesPeople() async throws {
        let names = (0 ..< 6).map { "\($0).jpg" }
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: names)
        try await library.readFaces([library.result(for: "0.jpg", faces: [Self.face(x: 0.1)])])
        var changes = await library.store.changeNotifications().makeAsyncIterator()
        func date(_ name: String, _ seconds: Double) async throws {
            let asset = try #require(try await library.store.mediaAssets(for: [library.id(name)])[library.id(name)])
            _ = await library.store.applyEnrichmentBatch([EnrichmentResult(
                id: library.id(name),
                metadata: AssetMetadata(timestamps: [.absolute(instant: Date(timeIntervalSince1970: seconds))]),
                thumbnailPath: "thumb-again-\(name).jpg",
                sourceSize: asset.byteSize,
                sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
                contentHash: .empty,
                previewPath: "preview-again-\(name).heic"
            )])
        }
        for (index, name) in names.dropFirst().enumerated() {
            try await date(name, 1_500_000_000 + Double(index) * 86400)
            let change = try #require(await changes.next())
            #expect(change.facts.contains(.captureDate), "\(name): \(change.facts.diagnosticDescription)")
            #expect(!change.touches(PeopleAssignment.inputs), "\(name) holds no face: \(change.facts.diagnosticDescription)")
        }
        try await date("0.jpg", 1_400_000_000)
        let faced = try #require(await changes.next())
        #expect(faced.touches(PeopleAssignment.inputs), "\(faced.facts.diagnosticDescription)")
        await library.store.shutdown()
    }

    /// `count` photos each holding one face like the others, the first on the user's word
    /// Sam's, the rest not yet assigned, in a catalog file.
    /// The People gallery paints from facts the catalog stores (`person_summary`): after any
    /// run of acts, readings, assignments and a deleted photo, once People has run, every
    /// person's stored photo count and newest face are what a computation from scratch over
    /// every stored face gives (`PeopleSnapshot.computedGalleryFacts`), and the gallery's read
    /// shows them with the key photo as the cover where one counts.
    // swiftlint:disable:next cyclomatic_complexity
    @Test func theGallerysStoredFactsEqualAComputationFromScratch() async throws {
        let names = (0 ..< 8).map { "\($0).jpg" }
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: names)
        var random = SplitMix64(seed: 116)
        func pick<T>(_ values: [T]) -> T? {
            values.isEmpty ? nil : values[Int(random.next() % UInt64(values.count))]
        }
        func read(_ name: String) async throws {
            let count = 1 + Int(random.next() % 3)
            let faces = (0 ..< count).map { Self.lookalike(Int(random.next() % 3) * 50 + $0) }.enumerated().map { index, face in
                DetectedFace(
                    box: CGRect(x: 0.05 + 0.3 * Double(index), y: 0.3, width: 0.2, height: 0.25),
                    landmarks: face.landmarks, quality: face.quality, embedding: face.embedding
                )
            }
            let day = Date(timeIntervalSince1970: 1_600_000_000 + Double(random.next() % 40) * 86400)
            try await library.readFaces([library.result(
                for: name, faces: faces, sizeOffset: Int64(random.next() % 1000), captured: day
            )])
        }
        for name in names {
            try await read(name)
        }
        let owner = PeopleAssignment(store: library.store)
        let libraries = try #require(await library.store.loadedLibraries())
        var present = names
        for step in 0 ..< 40 {
            let snapshot = try await library.store.peopleSnapshot()
            let faces = snapshot.faces.map(\.id)
            let people = snapshot.people.map(\.id)
            switch random.next() % 9 {
            case 0: if let face = pick(faces), let person = pick(people) {
                    _ = try? await library.store.perform(.move([face], to: person))
                }
            case 1: if let face = pick(faces) {
                    _ = try? await library.store.perform(.moveToNewPerson([face], name: "P\(step)"))
                }
            case 2: if let face = pick(faces) {
                    _ = try? await library.store.perform(.removeName([face]))
                }
            case 3: if let face = pick(faces) {
                    _ = try? await library.store.perform(.notAFace([face]))
                }
            case 4:
                if let face = pick(snapshot.faces.filter { $0.assignment.person != nil }), let person = face.assignment.person {
                    _ = try? await library.store.perform(.makeKeyPhoto(face.id, of: person))
                }
            case 5: if let person = pick(people) {
                    _ = try? await library.store.perform(.setHidden(person, random.next() % 2 == 0))
                }
            case 6: if let from = pick(people), let into = pick(people) {
                    _ = try? await library.store.perform(.merge(from, into: into))
                }
            case 7: if let name = pick(present) {
                    try await read(name)
                }
            default:
                guard present.count > 4, let name = pick(present) else { break }
                let file = library.root.appending(path: name)
                try FileManager.default.removeItem(at: file)
                library.emit(FilesystemEvent(path: file.path, flags: UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)))
                present.removeAll { $0 == name }
                let left = Set(present)
                _ = try await waitForCatalogStoreState(library.store) { !$0.isScanning && Set($0.testAssets.map(\.relativePath.rawValue)) == left }
            }
            try await owner.settle()
            let truth = try await library.store.peopleSnapshot()
            let gallery = try #require(try await library.store.peopleGallery(availableLibraryPaths: [library.rootPath]))
            let computed = truth.computedGalleryFacts
            #expect(gallery.people.allSatisfy { $0.facts != nil }, "step \(step)")
            #expect(Dictionary(uniqueKeysWithValues: gallery.people.compactMap { person in person.facts.map { (person.id, $0) } }) == computed, "step \(step)")
            #expect(truth.galleryFacts == computed, "step \(step)")
            let state = try await library.store.gallery(libraries: libraries)
            for person in state.people {
                let cover = truth.keyPhotos[person.id] ?? computed[person.id]?.newestFace
                #expect(person.cover?.id == cover, "step \(step): \(person.id)")
            }
        }
        await library.store.shutdown()
    }

    /// The gallery's read seeks every face and photo row it reads by key: the people are the
    /// one table it walks, and the faces that define them come from their partial index, so
    /// its cost is the people's, never the faces' (7.5–7.9 s cold on the owner's catalog when
    /// every face was joined to its photo).
    @Test func theGallerysReadSeeksEveryFaceAndPhotoByKey() async throws {
        let directory = try makeTestDirectory()
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(
            in: directory, files: ["a.jpg"], database: directory.appending(path: "db/catalog.sqlite")
        )
        try await library.readFaces([library.result(for: "a.jpg", faces: [Self.face(x: 0.1)])])
        _ = try await library.store.perform(.moveToNewPerson([FaceID(asset: library.id("a.jpg"), index: 0)], name: "Sam"))
        let database = try DatabaseQueue(path: #require(library.databaseURL).path(percentEncoded: false))
        let plans = try await database.read { db in
            try [PeopleGallerySQL.people, PeopleGallerySQL.anchors].map { sql in
                try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)").map { $0["detail"] as String }
            }
        }
        let (people, anchors) = (plans[0], plans[1])
        #expect(people.contains { $0.hasPrefix("SCAN p") }, "\(people)")
        for alias in ["s", "k", "km", "c", "cm"] {
            #expect(people.contains { $0.hasPrefix("SEARCH \(alias) USING") }, "\(alias): \(people)")
        }
        #expect(people.contains { $0.contains("idx_face_key_photo") }, "\(people)")
        #expect(anchors.first?.contains("COVERING INDEX idx_face_anchor") == true, "\(anchors)")
        #expect(anchors.contains { $0.hasPrefix("SEARCH m USING") }, "\(anchors)")
        for plan in [people, anchors] {
            #expect(!plan.contains { $0.hasPrefix("SCAN") && !$0.hasPrefix("SCAN p") && !$0.contains("idx_face_anchor") && !$0.contains("member") }, "\(plan)")
        }
        try await database.close()
        await library.store.shutdown()
    }

    private static func lookalikes(
        _ count: Int,
        in directory: URL,
        extraFiles: [String] = []
    ) async throws -> (FaceEnrichmentTests.ScannedLibrary, URL) {
        let databaseURL = directory.appending(path: "db/catalog.sqlite")
        let names = (0 ..< count).map { "\($0).jpg" }
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: directory, files: names + extraFiles, database: databaseURL)
        try await library.readFaces(names.enumerated().map { library.result(for: $1, faces: [Self.lookalike($0)]) })
        _ = try await library.store.perform(.moveToNewPerson([FaceID(asset: library.id("0.jpg"), index: 0)], name: "Sam"))
        return (library, databaseURL)
    }

    /// A face like every other `lookalike`: one direction, nudged a little per face.
    private static func lookalike(_ index: Int) -> DetectedFace {
        let base = FaceEnrichmentTests.face(seed: 3)
        var values = Array(base.embedding.values)
        values[index % values.count] += 0.02
        return DetectedFace(
            box: base.box, landmarks: base.landmarks, quality: base.quality, embedding: FaceEmbedding(normalizing: values)!
        )
    }

    static func face(x: Double) -> DetectedFace {
        DetectedFace(
            box: CGRect(x: x, y: 0.3, width: 0.2, height: 0.25),
            landmarks: FaceAlignment.Landmarks(
                leftEye: CGPoint(x: x, y: 0.375), rightEye: CGPoint(x: x + 1 / 64, y: 0.375),
                nose: CGPoint(x: x + 2 / 64, y: 0.375), leftMouth: CGPoint(x: x + 3 / 64, y: 0.375),
                rightMouth: CGPoint(x: x + 4 / 64, y: 0.375)
            ),
            quality: 0.5,
            embedding: FaceEnrichmentTests.face(seed: Int(x * 100)).embedding
        )
    }
}
