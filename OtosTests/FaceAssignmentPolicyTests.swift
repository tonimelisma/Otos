import Foundation
@testable import OtosKit
import Testing

/// Assignment (ADR 0047): every face to its most likely person, chained year by year, close
/// calls guessed but never carried, the hard rules, new people from faces matching nobody,
/// and a run on its own output changing nothing — on embeddings whose similarities are exact
/// by construction.
struct FaceAssignmentPolicyTests {
    static let sam = PersonID(rawValue: 1)
    static let ian = PersonID(rawValue: 2)
    static let year: Double = 365.2425 * 86400
    static let day: Double = 86400
    /// The fixtures' time zero, seconds since 1970.
    static let epoch: Double = 1_600_000_000
    static let people = [PersonFact(id: sam, birthdaySeconds: nil, isBare: false), PersonFact(id: ian, birthdaySeconds: nil, isBare: false)]

    @Test func aFaceGoesToThePersonItMatches() {
        let anchor = Self.face("ref.jpg", toward: [0: 1], at: 0, assignment: .user(Self.sam))
        let open = Self.face("new.jpg", toward: [0: 1, 9: 0.2], at: Self.year / 2)

        let result = FaceAssignmentPolicy.assign(faces: [anchor, open], people: Self.people)

        #expect(result.guesses == [open.id: .existing(Self.sam)])
        #expect(result.newPeople.isEmpty)
    }

    /// A child is followed from year to year through the faces Otos gave them: each face is
    /// within two years of the one before, none of the last within two years of the first.
    @Test func aChildIsFollowedYearByYear() {
        let anchor = Self.face("2010.jpg", toward: [0: 1], at: 0, assignment: .user(Self.sam))
        let later = [1.5, 3, 4.5, 6].map { years in
            Self.face("\(years).jpg", toward: [0: 1, Int(years * 10): 0.3], at: years * Self.year)
        }

        let result = FaceAssignmentPolicy.assign(faces: [anchor] + later, people: Self.people)

        #expect(later.allSatisfy { result.guesses[$0.id] == .existing(Self.sam) })
    }

    /// With nothing between, a child's face three years from every face of theirs is not
    /// reached; an adult's is.
    @Test func anAdultIsComparedAcrossAllYearsAndAChildIsNot() {
        let people = [
            PersonFact(id: Self.sam, birthdaySeconds: Self.epoch - 3 * Self.year, isBare: false),
            PersonFact(id: Self.ian, birthdaySeconds: Self.epoch - 30 * Self.year, isBare: false),
        ]
        let child = Self.face("child.jpg", toward: [0: 1], at: 0, assignment: .user(Self.sam))
        let adult = Self.face("adult.jpg", toward: [1: 1], at: 0, assignment: .user(Self.ian))
        let childLater = Self.face("child6.jpg", toward: [0: 1], at: 6 * Self.year)
        let adultLater = Self.face("adult6.jpg", toward: [1: 1], at: 6 * Self.year)

        let result = FaceAssignmentPolicy.assign(faces: [child, adult, childLater, adultLater], people: people)

        #expect(result.guesses[adultLater.id] == .existing(Self.ian))
        #expect(result.guesses[childLater.id] == nil)
    }

    /// A face as like Ian as Sam goes to the more likely one, but carries neither to the
    /// next face: a face reached only through it stays without a person.
    @Test func aCloseCallIsGuessedButCarriesNobody() {
        let sam = Self.face("s.jpg", toward: [0: 1], at: 0, assignment: .user(Self.sam))
        let ian = Self.face("i.jpg", toward: [1: 1], at: 0, assignment: .user(Self.ian))
        // 0.737 like Sam and 0.676 like Ian: both reach the threshold, within the margin.
        let close = Self.face("close.jpg", toward: [0: 0.6, 1: 0.55], at: Self.day)
        // 0.477 like the close face, under the threshold for either anchor.
        let beyond = Self.face("beyond.jpg", toward: [0: 0.6, 1: 0.55, 2: 1.5], at: 2 * Self.day)

        let result = FaceAssignmentPolicy.assign(faces: [sam, ian, close, beyond], people: Self.people)

        #expect(result.guesses[close.id] == .existing(Self.sam))
        #expect(result.guesses[beyond.id] == nil)
    }

    @Test func aPersonIsGuessedInAPhotoOnce() {
        let anchor = Self.face("ref.jpg", toward: [0: 1], at: 0, assignment: .user(Self.sam))
        let likelier = Self.face("group.jpg", index: 0, toward: [0: 1, 9: 0.1], at: Self.day)
        let other = Self.face("group.jpg", index: 1, toward: [0: 1, 9: 0.5], at: Self.day)

        let result = FaceAssignmentPolicy.assign(faces: [anchor, likelier, other], people: Self.people)

        #expect(result.guesses[likelier.id] == .existing(Self.sam))
        #expect(result.guesses[other.id] == nil)
    }

    @Test func theUsersWordHoldsEveryGuess() {
        let people = [
            PersonFact(id: Self.sam, birthdaySeconds: Self.epoch + Self.year, isBare: false),
            PersonFact(id: Self.ian, birthdaySeconds: nil, isBare: false),
        ]
        let sam = Self.face("s.jpg", toward: [0: 1], at: 2 * Self.year, assignment: .user(Self.sam))
        let beforeBirthday = Self.face("baby.jpg", toward: [0: 1], at: 0)
        let rejected = Self.face("not.jpg", toward: [0: 1], at: 2 * Self.year, rejected: [Self.sam])
        let held = Self.face("held.jpg", toward: [0: 1], at: 2 * Self.year, assignment: .held)
        let notAFace = Self.face("poster.jpg", toward: [0: 1], at: 2 * Self.year, notAFace: true)

        let result = FaceAssignmentPolicy.assign(faces: [sam, beforeBirthday, rejected, held, notAFace], people: people)

        // The two faces Sam may not have look alike on two days: a new person, not Sam.
        #expect(!result.guesses.values.contains(.existing(Self.sam)))
        #expect(result.newPeople == [[beforeBirthday.id, rejected.id]])
        #expect(result.guesses[held.id] == nil && result.guesses[notAFace.id] == nil)
    }

    /// Faces matching nobody that look alike on two or more days are a new person; faces of
    /// one day, or of one photo, are not. A face like the new person, below the group link,
    /// is then given to them.
    @Test func facesMatchingNobodyAreANewPersonOnlyAcrossDays() {
        let twoDays = [
            Self.face("d1.jpg", toward: [5: 1], at: 0),
            Self.face("d2.jpg", toward: [5: 1, 9: 0.1], at: 2 * Self.day),
        ]
        let oneDay = [
            Self.face("e1.jpg", toward: [6: 1], at: 0),
            Self.face("e2.jpg", toward: [6: 1], at: 3600),
        ]
        let onePhoto = [
            Self.face("twins.jpg", index: 0, toward: [7: 1], at: 0),
            Self.face("twins.jpg", index: 1, toward: [7: 1], at: 0),
        ]
        // 0.55 like the group: a guess, not a link.
        let reached = Self.face("later.jpg", toward: [5: 0.55, 10: 0.835], at: 5 * Self.day)

        let result = FaceAssignmentPolicy.assign(faces: twoDays + oneDay + onePhoto + [reached], people: [])

        #expect(result.newPeople == [twoDays.map(\.id)])
        #expect(result.guesses == [reached.id: .new(0)])
    }

    /// Assignment rebuilds every guess from the anchors, so run on its own output — the new
    /// people's seeds now anchors, the guesses stored — it gives the same guesses and finds
    /// nobody new.
    @Test func assigningItsOwnOutputChangesNothing() {
        var generator = SplitMix64(seed: 5)
        let faces = Self.randomFaces(count: 300, people: 4, generator: &generator)
        let people = (1 ... 4).map { PersonFact(id: PersonID(rawValue: Int64($0)), birthdaySeconds: nil, isBare: false) }

        let first = FaceAssignmentPolicy.assign(faces: faces, people: people)
        var created: [Int: PersonID] = [:]
        for index in first.newPeople.indices {
            created[index] = PersonID(rawValue: Int64(100 + index))
        }
        func id(_ person: FaceAssignmentResult.Person) -> PersonID {
            switch person {
            case let .existing(id): id
            case let .new(index): created[index]!
            }
        }
        let seeds = Dictionary(uniqueKeysWithValues: first.newPeople.enumerated().flatMap { index, faces in
            faces.map { ($0, created[index]!) }
        })
        let written = faces.map { face -> FaceFact in
            let assignment: FaceAssignment = if let seed = seeds[face.id] {
                .seed(seed)
            } else if face.assignment.isGuessable {
                first.guesses[face.id].map { .model(id($0)) } ?? .open
            } else {
                face.assignment
            }
            return FaceFact(
                id: face.id, captureSeconds: face.captureSeconds, embedding: face.embedding,
                assignment: assignment, isNotFace: face.isNotFace, rejected: face.rejected
            )
        }
        let everyone = people + created.values.map { PersonFact(id: $0, birthdaySeconds: nil, isBare: true) }

        let second = FaceAssignmentPolicy.assign(faces: written, people: everyone)

        #expect(!first.newPeople.isEmpty)
        #expect(second.newPeople.isEmpty)
        #expect(second.guesses == first.guesses.filter { seeds[$0.key] == nil }.mapValues { .existing(id($0)) })
        #expect(second.likeness == first.likeness)
    }

    /// A person Otos found keeps its seeds only while they span two or more days. When seeds
    /// of the other days are gone, the ones left lapse: they lose their person and, like no
    /// one and from one day, stay without one.
    @Test func seedsOfOneDayLeftOfABarePersonLapse() {
        let found = PersonID(rawValue: 7)
        let seeds = [
            Self.face("halloween-1.jpg", toward: [5: 1], at: 0, assignment: .seed(found)),
            Self.face("halloween-2.jpg", toward: [5: 1, 6: 0.3], at: 60, assignment: .seed(found)),
        ]
        let sam = Self.face("sam.jpg", toward: [0: 1], at: 0, assignment: .user(Self.sam))
        let people = Self.people + [PersonFact(id: found, birthdaySeconds: nil, isBare: true)]

        let result = FaceAssignmentPolicy.assign(faces: seeds + [sam], people: people)

        #expect(result.lapsedSeeds == Set(seeds.map(\.id)))
        #expect(result.guesses.isEmpty)
        #expect(result.newPeople.isEmpty)
    }

    /// Seeds lapse only for a person the user said nothing about and gave no face, and only
    /// when they span fewer than two days.
    @Test func seedsStandWhileTheUserSaidSomethingOrTheyStillSpanTwoDays() {
        let found = PersonID(rawValue: 7)
        let oneDay = [
            Self.face("a.jpg", toward: [5: 1], at: 0, assignment: .seed(found)),
            Self.face("b.jpg", toward: [5: 1, 6: 0.3], at: 60, assignment: .seed(found)),
        ]
        let named = Self.people + [PersonFact(id: found, birthdaySeconds: nil, isBare: false)]
        let bare = Self.people + [PersonFact(id: found, birthdaySeconds: nil, isBare: true)]
        let usersFace = Self.face("c.jpg", toward: [5: 1, 8: 0.3], at: 120, assignment: .user(found))
        let otherDay = Self.face("d.jpg", toward: [5: 1, 9: 0.3], at: Self.day * 3, assignment: .seed(found))

        #expect(FaceAssignmentPolicy.assign(faces: oneDay, people: named).lapsedSeeds.isEmpty)
        #expect(FaceAssignmentPolicy.assign(faces: oneDay + [usersFace], people: bare).lapsedSeeds.isEmpty)
        #expect(FaceAssignmentPolicy.assign(faces: oneDay + [otherDay], people: bare).lapsedSeeds.isEmpty)
        #expect(FaceAssignmentPolicy.assign(faces: oneDay, people: bare).lapsedSeeds == Set(oneDay.map(\.id)))
    }

    @Test func likenessIsTheBestSimilarityToTheOtherFacesOfThePerson() {
        let anchor = Self.face("a.jpg", toward: [0: 1], at: 0, assignment: .user(Self.sam))
        let guess = Self.face("b.jpg", toward: [0: 1, 1: 1], at: Self.day)
        let alone = Self.face("c.jpg", toward: [1: 1], at: 0, assignment: .user(Self.ian))

        let result = FaceAssignmentPolicy.assign(faces: [anchor, guess, alone], people: Self.people)

        #expect(abs((result.likeness[guess.id] ?? 0) - 0.7071) < 0.001)
        #expect(abs((result.likeness[anchor.id] ?? 0) - 0.7071) < 0.001)
        #expect(result.likeness[alone.id] == nil)
    }

    /// The ranker offers everyone the hard rules allow, most likely first, never the face's
    /// own person, a person already in its photo, one it was said not to be, or one born
    /// after it.
    @Test func theRankerOffersWhoTheFaceCouldBe() {
        let tyler = PersonID(rawValue: 3)
        let owen = PersonID(rawValue: 4)
        let people = Self.people + [
            PersonFact(id: tyler, birthdaySeconds: nil, isBare: false),
            PersonFact(id: owen, birthdaySeconds: Self.epoch + Self.year, isBare: false),
        ]
        let faces = [
            Self.face("s.jpg", toward: [0: 1], at: 0, assignment: .user(Self.sam)),
            Self.face("i.jpg", toward: [1: 1], at: 0, assignment: .user(Self.ian)),
            Self.face("t.jpg", toward: [2: 1], at: 0, assignment: .user(tyler)),
            Self.face("o.jpg", toward: [0: 1], at: 2 * Self.year, assignment: .user(owen)),
        ]
        let ranker = FaceRanker(faces: faces, people: people, offered: [Self.sam, Self.ian, tyler, owen])
        let asked = Self.face("q.jpg", toward: [0: 1, 1: 0.5, 2: 0.2], at: Self.day, rejected: [tyler])
        let inPhoto = Self.face("q.jpg", index: 1, toward: [1: 1], at: Self.day, assignment: .model(Self.ian))

        let ranked = ranker.candidates(for: [asked, inPhoto], photoPeople: [asked.id.asset: [Self.ian]])

        #expect(ranked[asked.id]?.map(\.person) == [Self.sam])
        #expect(ranked[inPhoto.id]?.map(\.person) == [Self.sam, tyler])
    }

    /// The vectorised chaining gives the same guesses as the rules applied one comparison at
    /// a time, on random faces with every complication: undated faces, birthdays, adults,
    /// rejections, shared photos, held faces and non-faces.
    @Test func theVectorisedChainingMatchesABruteForceReading() {
        var generator = SplitMix64(seed: 11)
        let people = (1 ... 5).map { index in
            let birthday: Double? = switch index {
            case 3: Self.epoch + 4 * Self.year
            case 4: Self.epoch - 20 * Self.year
            default: nil
            }
            return PersonFact(id: PersonID(rawValue: Int64(index)), birthdaySeconds: birthday, isBare: false)
        }
        let faces = Self.randomFaces(count: 400, people: 5, generator: &generator).filter { !$0.isNotFace }
        let birthdays = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.birthdaySeconds) })
        let anchors = Dictionary(uniqueKeysWithValues: faces.filter(\.assignment.isAnchor).map {
            ($0.id, $0.assignment.person!)
        })
        let anchorRows = Dictionary(uniqueKeysWithValues: faces.enumerated().compactMap { index, face in
            anchors[face.id].map { (index, FaceAssignmentResult.Person.existing($0)) }
        })

        let fill = Fill.run(faces: faces, anchors: anchorRows, birthdays: birthdays)
        let fast = Dictionary(uniqueKeysWithValues: fill.assigned.compactMap { index, person -> (FaceID, PersonID)? in
            guard anchorRows[index] == nil, case let .existing(id) = person else { return nil }
            return (faces[index].id, id)
        })
        let slow = Self.bruteForceFill(faces: faces, anchors: anchors, birthdays: birthdays)

        #expect(fast == slow)
        #expect(slow.count > 50)
    }

    // MARK: - Fixtures

    /// Faces of `people` people, each toward its own axis with noise; a quarter are the
    /// user's, some equally like two people, some undated, rejected, held or not faces.
    static func randomFaces(count: Int, people: Int, generator: inout SplitMix64) -> [FaceFact] {
        (0 ..< count).map { index -> FaceFact in
            let owner = Int(generator.next() % UInt64(people + 1))
            var weights: [Int: Float] = [owner: 1]
            weights[people + 1 + Int(generator.next() % 40)] = Float(generator.next() % 100) / 100
            if generator.next() % 6 == 0 {
                weights[(owner + 1) % people] = 1
            }
            let dated = generator.next() % 10 != 0
            let assignment: FaceAssignment = if generator.next() % 4 == 0, owner < people {
                .user(PersonID(rawValue: Int64(owner + 1)))
            } else if generator.next() % 30 == 0 {
                .held
            } else {
                .open
            }
            return face(
                "\(index / 2).jpg",
                index: index % 2,
                toward: weights,
                at: Double(generator.next() % 3000) * day,
                assignment: assignment,
                rejected: generator.next() % 8 == 0 ? [PersonID(rawValue: Int64(generator.next() % UInt64(people) + 1))] : [],
                notAFace: generator.next() % 30 == 0,
                dated: dated
            )
        }
    }

    /// Chaining, one comparison at a time: rounds of confident faces strongest first, each
    /// round's faces evidence for the next, then the close calls strongest first.
    static func bruteForceFill(
        faces: [FaceFact],
        anchors: [FaceID: PersonID],
        birthdays: [PersonID: Double?]
    ) -> [FaceID: PersonID] {
        func dot(_ a: [Float], _ b: [Float]) -> Float {
            zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        }
        let byID = Dictionary(uniqueKeysWithValues: faces.map { ($0.id, $0) })
        var assigned = anchors
        var evidence: [PersonID: [FaceFact]] = [:]
        for (face, person) in anchors {
            evidence[person, default: []].append(byID[face]!)
        }
        let people = Array(Set(anchors.values)).sorted()
        var open = faces.filter { $0.assignment.isGuessable && anchors[$0.id] == nil }.map(\.id)
        func ranked(_ face: FaceFact, excludingPhoto: Bool) -> [(PersonID, Float)] {
            let inPhoto = Set(assigned.filter { $0.key.asset == face.id.asset }.map(\.value))
            return people.compactMap { person -> (PersonID, Float)? in
                guard !face.rejected.contains(person), !(excludingPhoto && inPhoto.contains(person)),
                      FaceAssignmentPolicy.notBeforeBirthday(face.captureSeconds, birthdays[person] ?? nil)
                else { return nil }
                let best = (evidence[person] ?? [])
                    .filter { FaceAssignmentPolicy.reaches(face.captureSeconds, $0.captureSeconds, birthday: birthdays[person] ?? nil) }
                    .map { dot(face.embedding, $0.embedding) }
                    .max()
                return best.map { (person, $0) }
            }.sorted { ($0.1, $1.0) > ($1.1, $0.0) }
        }
        while true {
            var round: [(FaceID, PersonID, Float)] = []
            for id in open {
                let list = ranked(byID[id]!, excludingPhoto: true)
                guard let top = list.first, top.1 >= FaceAssignmentPolicy.threshold,
                      top.1 - (list.dropFirst().first?.1 ?? -2) >= FaceAssignmentPolicy.margin
                else { continue }
                round.append((id, top.0, top.1))
            }
            guard !round.isEmpty else { break }
            var added = false
            let rows = Dictionary(uniqueKeysWithValues: open.enumerated().map { ($1, $0) })
            for (id, person, _) in round.sorted(by: { ($0.2, rows[$1.0]!) > ($1.2, rows[$0.0]!) }) {
                guard !assigned.contains(where: { $0.key.asset == id.asset && $0.value == person }) else { continue }
                assigned[id] = person
                evidence[person, default: []].append(byID[id]!)
                added = true
            }
            open.removeAll { assigned[$0] != nil }
            if !added {
                break
            }
        }
        let rows = Dictionary(uniqueKeysWithValues: open.enumerated().map { ($1, $0) })
        let close = open.compactMap { id -> (FaceID, Float)? in
            ranked(byID[id]!, excludingPhoto: false).first.flatMap { $0.1 >= FaceAssignmentPolicy.threshold ? (id, $0.1) : nil }
        }
        for (id, _) in close.sorted(by: { ($0.1, rows[$1.0]!) > ($1.1, rows[$0.0]!) }) {
            guard let top = ranked(byID[id]!, excludingPhoto: true).first, top.1 >= FaceAssignmentPolicy.threshold else { continue }
            assigned[id] = top.0
        }
        return assigned.filter { anchors[$0.key] == nil }
    }

    static func face(
        _ path: String,
        index: Int = 0,
        toward weights: [Int: Float],
        at seconds: Double,
        assignment: FaceAssignment = .open,
        rejected: Set<PersonID> = [],
        notAFace: Bool = false,
        dated: Bool = true
    ) -> FaceFact {
        var vector = [Float](repeating: 0, count: FaceEmbeddingModel.dimensions)
        for (axis, weight) in weights {
            vector[axis] = weight
        }
        let length = vector.map { $0 * $0 }.reduce(0, +).squareRoot()
        return FaceFact(
            id: FaceID(
                asset: MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/Lib"), relativePath: MediaRelativePath(rawValue: path)),
                index: index
            ),
            captureSeconds: dated ? epoch + seconds : nil,
            embedding: vector.map { $0 / length },
            assignment: assignment,
            isNotFace: notAFace,
            rejected: rejected
        )
    }
}
