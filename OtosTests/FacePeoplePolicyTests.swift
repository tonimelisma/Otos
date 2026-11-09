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
        ignored: Bool = false
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
            captureSeconds: epoch + seconds,
            embedding: vector.map { $0 / length },
            person: person,
            isNotFace: notAFace,
            isIgnored: ignored,
            rejected: rejected
        )
    }
}
