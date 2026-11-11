import CoreGraphics
import Foundation
@testable import OtosKit
import Testing

/// What People shows (ADR 0047, `docs/design/people.md`): the list, the review's
/// Suggestions and Unsure lists grouped by year, the hard rules the review enforces, and
/// the way the review is walked from the keyboard. On embeddings whose similarities are
/// exact by construction (`FacePeoplePolicyTests.face`).
struct PeopleStateTests {
    typealias Fixture = FacePeoplePolicyTests
    static let sam = Fixture.sam
    static let ian = Fixture.ian
    static let year = Fixture.year

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    static func snapshot(_ faces: [FaceFact], people: [PeopleSnapshot.Person]? = nil, unchecked: Int = 0) -> PeopleSnapshot {
        PeopleSnapshot(
            faces: faces,
            tiles: Dictionary(uniqueKeysWithValues: faces.map {
                ($0.id, FaceTile(id: $0.id, box: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.2), previewName: "p", captureSeconds: $0.captureSeconds))
            }),
            people: people ?? [
                .init(id: sam, name: "Sam", birthday: nil),
                .init(id: ian, name: "Ian", birthday: nil),
            ],
            uncheckedPhotoCount: unchecked,
            revision: 0
        )
    }

    static func yearOf(_ face: FaceFact) -> Int? {
        face.captureSeconds.map { utc.component(.year, from: Date(timeIntervalSince1970: $0)) }
    }

    /// The list is most photos first; a person's faces are newest first, the newest the
    /// cover; a suggestion sits in its photo's year beside the face it rests on.
    @Test func theListAndSuggestionsByYear() {
        // The older face is less like the suggestion, so the newer one is what it rests on.
        let samOld = Fixture.face("s1.jpg", toward: [0: 1, 3: 0.3], at: 0, person: Self.sam)
        let samNew = Fixture.face("s2.jpg", toward: [0: 1], at: Self.year, person: Self.sam)
        let ianFace = Fixture.face("i1.jpg", toward: [1: 1], at: 0, person: Self.ian)
        let suggested = Fixture.face("new.jpg", toward: [0: 1, 9: 0.2], at: 1.2 * Self.year)

        let state = PeopleStateBuilder.state(
            from: Self.snapshot([samOld, samNew, ianFace, suggested], unchecked: 3),
            calendar: Self.utc
        )

        #expect(state.people.map(\.id) == [Self.sam, Self.ian])
        #expect(state.people.first?.photoCount == 2)
        #expect(state.people.first?.cover?.id == samNew.id)
        #expect(state.uncheckedPhotoCount == 3)
        #expect(state.faceCount == 4)
        let row = try? #require(state.suggestions.first?.rows.first)
        #expect(state.suggestions.map(\.year) == [Self.yearOf(suggested)])
        #expect(row?.kind == .person(Self.sam, referenceYear: Self.yearOf(samNew)))
        #expect(row?.faces.map(\.id) == [suggested.id])
        #expect(row?.references.map(\.id) == [samNew.id])
        #expect(state.unsure.isEmpty)
    }

    /// A face as like Sam as Ian is in Unsure, never in Suggestions, with each
    /// candidate's confirmed face beside it, the pair in the People list's order (one photo
    /// each, so by name).
    @Test func aFaceThatCouldBeEitherIsUnsure() {
        let samFace = Fixture.face("s.jpg", toward: [0: 1], at: 0, person: Self.sam)
        let ianFace = Fixture.face("i.jpg", toward: [1: 1], at: 0, person: Self.ian)
        let either = Fixture.face("e.jpg", toward: [0: 1, 1: 1], at: Self.year / 4)

        let state = PeopleStateBuilder.state(from: Self.snapshot([samFace, ianFace, either]), calendar: Self.utc)

        #expect(state.suggestions.isEmpty)
        #expect(state.unsureCount == 1)
        let row = state.unsure.first?.rows.first
        #expect(row?.kind == .unsure(Self.ian, Self.sam))
        #expect(row?.references.map(\.id) == [ianFace.id, samFace.id])
    }

    /// Faces matching nobody that look alike on two days are one unnamed row per year;
    /// years are newest first and undated photos last.
    @Test func unnamedGroupsByYearNewestFirst() {
        let a = Fixture.face("a.jpg", toward: [5: 1], at: 0)
        let b = Fixture.face("b.jpg", toward: [5: 1], at: 2 * Self.year)
        let c = Fixture.face("c.jpg", toward: [5: 1], at: 0, dated: false)

        let state = PeopleStateBuilder.state(from: Self.snapshot([a, b, c], people: []), calendar: Self.utc)

        #expect(state.suggestions.map(\.year) == [Self.yearOf(b), Self.yearOf(a), nil])
        #expect(state.suggestions.allSatisfy { year in
            year.rows.allSatisfy {
                if case .unnamed = $0.kind {
                    true
                } else {
                    false
                }
            }
        })
        #expect(state.suggestionCount == 3)
    }

    /// The People list holds every unnamed group, across years, as its newest face: most
    /// photos first, named by its first face in path order, which also names its review rows.
    @Test func theListHoldsUnnamedGroups() {
        let small = [
            Fixture.face("x1.jpg", toward: [6: 1], at: 0),
            Fixture.face("x2.jpg", toward: [6: 1], at: 2 * Self.year),
        ]
        let large = [
            Fixture.face("y1.jpg", toward: [5: 1], at: 0),
            Fixture.face("y2.jpg", toward: [5: 1], at: Self.year),
            Fixture.face("y3.jpg", toward: [5: 1], at: 3 * Self.year),
        ]

        let state = PeopleStateBuilder.state(from: Self.snapshot(small + large, people: []), calendar: Self.utc)

        #expect(state.people.isEmpty)
        #expect(state.unnamed.map(\.id) == [large[0].id, small[0].id])
        #expect(state.unnamed.first?.cover?.id == large[2].id)
        #expect(state.unnamed.first?.photoCount == 3)
        #expect(state.listItems == [.unnamed(large[0].id), .unnamed(small[0].id)])
        let rowIDs = Set(state.suggestions.flatMap(\.rows).map(\.id))
        #expect(rowIDs == [.unnamed(large[0].id), .unnamed(small[0].id)])
        #expect(PeoplePresentation.emptyListSentence(state) == nil)
        #expect(PeoplePresentation.unnamedCount(state.unnamed) == "5 faces")
    }

    /// A person row shows the face least like the person first.
    @Test func aPersonRowShowsItsLeastSureFaceFirst() {
        let samFace = Fixture.face("s.jpg", toward: [0: 1], at: 0, person: Self.sam)
        let sure = Fixture.face("sure.jpg", toward: [0: 1, 9: 0.1], at: Self.year / 4)
        let lessSure = Fixture.face("less.jpg", toward: [0: 1, 9: 0.8], at: Self.year / 4 + 86400)

        let state = PeopleStateBuilder.state(from: Self.snapshot([samFace, sure, lessSure]), calendar: Self.utc)

        #expect(state.suggestions.count == 1)
        #expect(state.suggestions.first?.rows.first?.faces.map(\.id) == [lessSure.id, sure.id])
    }

    /// Not a Face takes a detection out of People altogether.
    @Test func notAFaceIsNotCounted() {
        let face = Fixture.face("x.jpg", toward: [0: 1], at: 0, notAFace: true)
        let state = PeopleStateBuilder.state(from: Self.snapshot([face], people: []), calendar: Self.utc)
        #expect(state.faceCount == 0)
        #expect(state.suggestions.isEmpty)
    }

    // MARK: - The review's rules and keys

    static func tile(_ path: String, at seconds: Double?) -> FaceTile {
        FaceTile(
            id: FaceID(asset: MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/Lib"), relativePath: MediaRelativePath(rawValue: path)), index: 0),
            box: .zero, previewName: nil, captureSeconds: seconds
        )
    }

    /// The hard rules disable the act, with the reason the tooltip shows (DES-038).
    @Test func theHardRulesNameTheirReason() {
        let shared = Self.tile("a.jpg", at: Fixture.epoch)
        let sharedOther = FaceID(asset: shared.id.asset, index: 1)
        let early = Self.tile("early.jpg", at: Fixture.epoch - Self.year)
        let state = CatalogPeopleState(
            people: [
                PersonSummary(id: Self.sam, name: "Sam", birthday: "2020", photoCount: 1, faces: [shared]),
                PersonSummary(id: Self.ian, name: "Ian", birthday: nil, photoCount: 0, faces: []),
            ],
            suggestions: [PeopleReviewYear(year: 2020, rows: [
                PeopleReviewRow(kind: .person(Self.ian, referenceYear: nil), references: [], faces: [early]),
            ])],
            unsure: [], uncheckedPhotoCount: 0, faceCount: 3
        )
        let index = PeopleIndex(state)

        #expect(index.confirmRefusal([sharedOther], as: Self.sam) == "Sam is already in this photo")
        #expect(index.confirmRefusal([sharedOther, shared.id], as: Self.ian) == "2 of these faces are in the same photo")
        #expect(index.confirmRefusal([early.id], as: Self.sam) == "1 face is from before Sam's birthday")
        #expect(index.confirmRefusal([early.id], as: Self.ian) == nil)
        #expect(index.eligiblePeople(for: [early.id], excluding: []).map(\.id) == [Self.ian])
        #expect(index.sheetRefusal(person: Self.ian, name: "Sam", birthday: nil) == "Another person is named Sam. Merge them instead.")
        #expect(index.sheetRefusal(person: Self.ian, name: " ", birthday: nil) == "Enter a name")
        #expect(index.sheetRefusal(person: Self.sam, name: "Sam", birthday: "2021") == "1 confirmed photo of Sam is from before this date")
        #expect(index.sheetRefusal(person: Self.sam, name: "Sam", birthday: "20x") == "Enter a year, or a full date")
        #expect(index.mergeRefusal(Self.ian, into: Self.sam) == nil)
    }

    @Test func mergingIsRefusedWhenBothAreInAPhoto() {
        let shared = Self.tile("a.jpg", at: Fixture.epoch)
        let other = FaceTile(id: FaceID(asset: shared.id.asset, index: 1), box: .zero, previewName: nil, captureSeconds: Fixture.epoch)
        let state = CatalogPeopleState(
            people: [
                PersonSummary(id: Self.sam, name: "Sam", birthday: nil, photoCount: 1, faces: [shared]),
                PersonSummary(id: Self.ian, name: "Ian", birthday: nil, photoCount: 1, faces: [other]),
            ],
            suggestions: [], unsure: [], uncheckedPhotoCount: 0, faceCount: 2
        )
        #expect(PeopleIndex(state).mergeRefusal(Self.ian, into: Self.sam) == "Ian and Sam are both in 1 photo")
    }

    /// ← / → walk faces across rows; ↑ / ↓ keep the place in the row; after an act the
    /// selection goes to the face after the last one acted on; leaving faces are not shown.
    @Test func theReviewIsWalkedFromTheKeyboard() {
        let first = (0 ..< 3).map { Self.tile("a\($0).jpg", at: Fixture.epoch - Double($0)) }
        let second = (0 ..< 2).map { Self.tile("b\($0).jpg", at: Fixture.epoch - Double($0)) }
        let years = [PeopleReviewYear(year: 2020, rows: [
            PeopleReviewRow(kind: .person(Self.sam, referenceYear: 2020), references: [], faces: first),
            PeopleReviewRow(kind: .person(Self.ian, referenceYear: 2020), references: [], faces: second),
        ])]
        let layout = PeopleReviewLayout(years: years, leaving: [], expanded: [])

        #expect(layout.target(from: nil, .next) == first[0].id)
        #expect(layout.target(from: first[2].id, .next) == second[0].id)
        #expect(layout.target(from: second[0].id, .previous) == first[2].id)
        #expect(layout.target(from: first[2].id, .down) == second[1].id)
        #expect(layout.target(from: second[1].id, .up) == first[1].id)
        #expect(layout.successor(of: [first[0].id, first[1].id]) == first[2].id)
        #expect(layout.successor(of: Set((first + second).map(\.id))) == nil)

        let without = PeopleReviewLayout(years: years, leaving: Set(first.map(\.id)), expanded: [])
        #expect(without.rows.count == 1)
        #expect(without.order == second.map(\.id))
    }

    /// A row shows its first 12 faces until it is expanded; the hidden ones still count, and
    /// the keys walk only the shown ones.
    @Test func aLongRowShowsTwelveFacesUntilExpanded() {
        let many = (0 ..< 15).map { Self.tile("m\($0).jpg", at: Fixture.epoch - Double($0)) }
        let next = [Self.tile("n.jpg", at: Fixture.epoch)]
        let row = PeopleReviewRow(kind: .person(Self.sam, referenceYear: 2020), references: [], faces: many)
        let years = [PeopleReviewYear(year: 2020, rows: [
            row,
            PeopleReviewRow(kind: .person(Self.ian, referenceYear: 2020), references: [], faces: next),
        ])]

        let collapsed = PeopleReviewLayout(years: years, leaving: [], expanded: [])
        #expect(collapsed.faceCount == 16)
        #expect(collapsed.order == many.prefix(12).map(\.id) + next.map(\.id))
        #expect(collapsed.shownFaces(row, year: 2020).count == 12)
        #expect(collapsed.target(from: many[11].id, .next) == next[0].id)
        #expect(collapsed.target(from: next[0].id, .up) == many[0].id)
        #expect(PeoplePresentation.showAllTitle(15) == "Show All 15 Faces")

        let expanded = PeopleReviewLayout(years: years, leaving: [], expanded: [PeopleReviewRowKey(row: row.id, year: 2020)])
        #expect(expanded.order.count == 16)
        #expect(expanded.shownFaces(row, year: 2020).count == 15)
        #expect(expanded != collapsed)
    }

    // MARK: - Words

    @Test func countsReadAsTheSpecWritesThem() {
        #expect(PeoplePresentation.peopleLine(0) == "No people")
        #expect(PeoplePresentation.peopleLine(1) == "1 person")
        #expect(PeoplePresentation.peopleLine(14) == "14 people")
        #expect(PeoplePresentation.uncheckedLine(0) == "Every photo has been checked")
        #expect(PeoplePresentation.uncheckedLine(1) == "1 photo not yet checked for faces")
        #expect(PeoplePresentation.reviewLine(236, list: .suggestions) == "236 faces to review")
        #expect(PeoplePresentation.reviewLine(0, list: .unsure) == "Nothing to decide")
        #expect(PeoplePresentation.confirmTitle(12, enabled: true) == "Confirm 12 Faces")
        #expect(PeoplePresentation.confirmTitle(0, enabled: false) == "Confirm Faces")
        let row = PeopleReviewRow(kind: .person(Self.sam, referenceYear: 2024), references: [], faces: [Self.tile("a.jpg", at: nil)])
        #expect(PeoplePresentation.rowDetail(row) { _ in "Sam" } == "1 face · like Sam in 2024")
        let unsure = PeopleReviewRow(kind: .unsure(Self.sam, Self.ian), references: [], faces: [])
        #expect(PeoplePresentation.rowTitle(unsure) { $0 == Self.sam ? "Sam" : "Ian" } == "Sam or Ian?")
    }

    @Test func aDraggedPersonRoundTrips() {
        #expect(PeopleDrag.person(from: PeopleDrag.payload(Self.ian)) == Self.ian)
        #expect(PeopleDrag.person(from: "something else") == nil)
    }

    /// The crop is the face box enlarged by 1.6, kept inside the image.
    @Test func aFaceTileIsTheEnlargedBoxInsideThePhoto() throws {
        let context = try #require(CGContext(
            data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let centered = try #require(FaceCrop.crop(image, box: CGRect(x: 0.45, y: 0.4, width: 0.1, height: 0.2)))
        #expect(centered.width == 64 && centered.height == 64)
        let corner = try #require(FaceCrop.crop(image, box: CGRect(x: 0, y: 0, width: 0.6, height: 0.9)))
        #expect(corner.width == 200 && corner.height == 200)
    }
}
