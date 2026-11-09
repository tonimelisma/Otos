import Foundation
@testable import OtosKit
import Testing

/// Grouping (ADR 0047): suggestions, unsure faces, the hard rules and unnamed groups, on
/// embeddings whose similarities are exact by construction.
struct FacePeoplePolicyTests {
    static let sam = PersonID(rawValue: 1)
    static let ian = PersonID(rawValue: 2)
    static let year: Double = 365.2425 * 86400
    /// The fixtures' time zero, seconds since 1970.
    static let epoch: Double = 1_600_000_000

    @Test func aFaceIsSuggestedForThePersonItMatches() {
        let reference = Self.face("ref.jpg", toward: [0: 1], at: 0, person: Self.sam)
        let open = Self.face("new.jpg", toward: [0: 1, 9: 0.2], at: Self.year / 2)

        let result = FacePeoplePolicy.suggestions(faces: [reference, open], people: Self.people)

        #expect(result.suggestions.map(\.face) == [open.id])
        #expect(result.suggestions.first?.person == Self.sam)
        #expect(result.suggestions.first?.reference == reference.id)
        #expect(result.unsure.isEmpty)
    }

    /// A child's face three years from any confirmed face is not suggested directly; years
    /// between are reached by confirming faces year by year.
    @Test func confirmedFacesMoreThanTwoYearsAwaySuggestNothing() {
        let reference = Self.face("ref.jpg", toward: [0: 1], at: 0, person: Self.sam)
        let open = Self.face("later.jpg", toward: [0: 1], at: 3 * Self.year)

        let result = FacePeoplePolicy.suggestions(faces: [reference, open], people: Self.people)

        #expect(result.suggestions.isEmpty)
    }

    /// Sam and Ian match the face equally: it is unsure, with both as candidates.
    /// An adult's face is compared with their confirmed faces from any year; a child's only
    /// within two years.
    @Test func anAdultIsComparedAcrossAllYearsAndAChildIsNot() {
        let people = [
            PersonFact(id: Self.sam, birthdaySeconds: Self.epoch - 3 * Self.year),
            PersonFact(id: Self.ian, birthdaySeconds: Self.epoch - 30 * Self.year),
        ]
        let child = Self.face("child.jpg", toward: [0: 1], at: 0, person: Self.sam)
        let adult = Self.face("adult.jpg", toward: [1: 1], at: 0, person: Self.ian)
        let childLater = Self.face("child6.jpg", toward: [0: 1], at: 6 * Self.year)
        let adultLater = Self.face("adult6.jpg", toward: [1: 1], at: 6 * Self.year)

        let result = FacePeoplePolicy.suggestions(faces: [child, adult, childLater, adultLater], people: people)

        #expect(result.suggestions.map(\.face) == [adultLater.id])
        #expect(result.suggestions.first?.person == Self.ian)
    }

    @Test func aFaceTwoPeopleMatchEquallyIsUnsure() {
        let sam = Self.face("s.jpg", toward: [0: 1], at: 0, person: Self.sam)
        let ian = Self.face("i.jpg", toward: [1: 1], at: 0, person: Self.ian)
        let open = Self.face("who.jpg", toward: [0: 1, 1: 1], at: 0)

        let result = FacePeoplePolicy.suggestions(faces: [sam, ian, open], people: Self.people)

        #expect(result.suggestions.isEmpty)
        #expect(result.unsure.map(\.face) == [open.id])
        #expect(Set([result.unsure.first?.first, result.unsure.first?.second]) == [Self.sam, Self.ian])
    }

    @Test func aPersonAlreadyInThePhotoIsNotSuggestedAgainInIt() {
        let confirmed = Self.face("group.jpg", index: 0, toward: [0: 1], at: 0, person: Self.sam)
        let other = Self.face("group.jpg", index: 1, toward: [0: 1, 9: 0.1], at: 0)

        let result = FacePeoplePolicy.suggestions(faces: [confirmed, other], people: Self.people)

        #expect(result.suggestions.isEmpty)
    }

    @Test func aFaceFromBeforeTheBirthdayIsNeverThePersons() {
        let people = [
            PersonFact(id: Self.sam, birthdaySeconds: Self.epoch + Self.year),
            PersonFact(id: Self.ian, birthdaySeconds: nil),
        ]
        let reference = Self.face("ref.jpg", toward: [0: 1], at: 1.5 * Self.year, person: Self.sam)
        let before = Self.face("before.jpg", toward: [0: 1], at: 0.5 * Self.year)

        let result = FacePeoplePolicy.suggestions(faces: [reference, before], people: people)

        #expect(result.suggestions.isEmpty)
    }

    @Test func aRejectedPersonIsNotSuggestedAgain() {
        let reference = Self.face("ref.jpg", toward: [0: 1], at: 0, person: Self.sam)
        let open = Self.face("new.jpg", toward: [0: 1], at: 0, rejected: [Self.sam])

        let result = FacePeoplePolicy.suggestions(faces: [reference, open], people: Self.people)

        #expect(result.suggestions.isEmpty)
    }

    /// Faces the user said are not faces, or ignored as a stranger's, are neither suggested
    /// nor grouped.
    @Test func ignoredFacesAndNonFacesAreLeftAlone() {
        let reference = Self.face("ref.jpg", toward: [0: 1], at: 0, person: Self.sam)
        let notAFace = Self.face("poster.jpg", toward: [0: 1], at: 0, notAFace: true)
        let ignored = [
            Self.face("a.jpg", toward: [5: 1], at: 0, ignored: true),
            Self.face("b.jpg", toward: [5: 1], at: 86400 * 3, ignored: true),
        ]

        let result = FacePeoplePolicy.suggestions(faces: [reference, notAFace] + ignored, people: Self.people)

        #expect(result.suggestions.isEmpty)
        #expect(result.unnamedGroups.isEmpty)
    }

    /// A stranger seen on two days forms a group; seen on one day only, or across one photo
    /// only, they do not.
    @Test func unnamedGroupsNeedTwoDaysAndNeverJoinOnePhoto() {
        let twoDays = [
            Self.face("d1.jpg", toward: [5: 1], at: 0),
            Self.face("d2.jpg", toward: [5: 1, 9: 0.1], at: 86400 * 2),
        ]
        let oneDay = [
            Self.face("e1.jpg", toward: [6: 1], at: 0),
            Self.face("e2.jpg", toward: [6: 1], at: 3600),
        ]
        let onePhoto = [
            Self.face("twins.jpg", index: 0, toward: [7: 1], at: 0),
            Self.face("twins.jpg", index: 1, toward: [7: 1], at: 0),
        ]
        let unlike = Self.face("far.jpg", toward: [8: 1], at: 86400 * 9)

        let result = FacePeoplePolicy.suggestions(faces: twoDays + oneDay + onePhoto + [unlike], people: Self.people)

        #expect(result.unnamedGroups == [twoDays.map(\.id)])
    }

    /// The vectorised policy gives the same suggestions and unsure faces as the rules read
    /// one comparison at a time, on random faces with every complication: undated faces,
    /// birthdays, rejections, shared photos, ignored faces and non-faces.
    @Test func theVectorisedPolicyMatchesABruteForceReading() {
        var generator = SplitMix64(seed: 11)
        let people = (1 ... 5).map { index in
            let birthday: Double? = switch index {
            case 3: Self.epoch + 4 * Self.year
            case 4: Self.epoch - 20 * Self.year
            default: nil
            }
            return PersonFact(id: PersonID(rawValue: Int64(index)), birthdaySeconds: birthday)
        }
        let faces = (0 ..< 400).map { index -> FaceFact in
            let owner = Int(generator.next() % 6)
            var weights: [Int: Float] = [owner: 1]
            weights[6 + Int(generator.next() % 40)] = Float(generator.next() % 100) / 100
            // Some faces look equally like two people: the unsure case.
            if generator.next() % 6 == 0 {
                weights[(owner + 1) % 5] = 1
            }
            let dated = generator.next() % 10 != 0
            let confirmed = generator.next() % 4 == 0 && owner < 5
            return Self.face(
                "\(index / 2).jpg",
                index: index % 2,
                toward: weights,
                at: Double(generator.next() % 3000) * 86400,
                person: confirmed ? PersonID(rawValue: Int64(owner + 1)) : nil,
                rejected: generator.next() % 8 == 0 ? [PersonID(rawValue: Int64(generator.next() % 5 + 1))] : [],
                notAFace: generator.next() % 30 == 0,
                ignored: generator.next() % 30 == 0,
                dated: dated
            )
        }

        let fast = FacePeoplePolicy.suggestions(faces: faces, people: people)
        let slow = Self.bruteForce(faces: faces, people: people)

        #expect(fast.suggestions.map(\.face) == slow.suggestions.map(\.face))
        #expect(fast.suggestions.map(\.person) == slow.suggestions.map(\.person))
        #expect(zip(fast.suggestions, slow.suggestions).allSatisfy { abs($0.similarity - $1.similarity) < 1e-5 })
        #expect(fast.unsure.map(\.face) == slow.unsure.map(\.face))
        #expect(!slow.suggestions.isEmpty && !slow.unsure.isEmpty)
    }

    /// The rules, one comparison at a time.
    static func bruteForce(faces: [FaceFact], people: [PersonFact]) -> PeopleSuggestions {
        let usable = faces.filter { !$0.isNotFace }
        let confirmed = usable.filter { $0.person != nil }
        let birthdays = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.birthdaySeconds) })
        var suggestions: [PeopleSuggestions.Suggestion] = [], unsure: [PeopleSuggestions.Unsure] = []
        for face in usable where face.person == nil && !face.isIgnored {
            var best: [PersonID: (Float, FaceID)] = [:]
            for candidate in confirmed {
                guard let person = candidate.person, birthdays.keys.contains(person), !face.rejected.contains(person),
                      !confirmed.contains(where: { $0.person == person && $0.id.asset == face.id.asset }),
                      face.captureSeconds.map({ FacePeoplePolicy.isAdult(at: $0, birthday: birthdays[person] ?? nil) }) ?? false
                      || FacePeoplePolicy.within(face.captureSeconds, candidate.captureSeconds),
                      FacePeoplePolicy.notBeforeBirthday(face.captureSeconds, birthdays[person] ?? nil)
                else { continue }
                let similarity = zip(face.embedding, candidate.embedding).map(*).reduce(0, +)
                if similarity > best[person]?.0 ?? -2 {
                    best[person] = (similarity, candidate.id)
                }
            }
            let ranked = best.sorted { ($0.value.0, $1.key) > ($1.value.0, $0.key) }
            guard let top = ranked.first, top.value.0 >= FacePeoplePolicy.threshold else { continue }
            if ranked.count > 1, top.value.0 - ranked[1].value.0 < FacePeoplePolicy.margin {
                unsure.append(.init(face: face.id, first: top.key, second: ranked[1].key))
            } else {
                suggestions.append(.init(face: face.id, person: top.key, reference: top.value.1, similarity: top.value.0))
            }
        }
        return PeopleSuggestions(suggestions: suggestions, unsure: unsure, unnamedGroups: [])
    }

    // MARK: - Fixtures

    static let people = [PersonFact(id: sam, birthdaySeconds: nil), PersonFact(id: ian, birthdaySeconds: nil)]

    /// A face whose embedding points along the given axes (weights), normalised, so two
    /// faces' similarity is exact.
    static func face(
        _ path: String,
        index: Int = 0,
        toward weights: [Int: Float],
        at seconds: Double,
        person: PersonID? = nil,
        rejected: Set<PersonID> = [],
        notAFace: Bool = false,
        ignored: Bool = false,
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
            person: person,
            isNotFace: notAFace,
            isIgnored: ignored,
            rejected: rejected
        )
    }
}
