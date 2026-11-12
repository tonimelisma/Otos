import CoreGraphics
import Foundation
@testable import OtosKit
import Testing

/// What People shows (ADR 0047, `docs/design/people.md`): the gallery, the faces of a photo,
/// what one assignment writes, the people a selection's faces most likely are, the hard rules
/// the acts are held to, and the words the surfaces use. On embeddings whose similarities are
/// exact by construction (`FaceAssignmentPolicyTests.face`).
struct PeopleStateTests {
    typealias Fixture = FaceAssignmentPolicyTests
    static let sam = Fixture.sam
    static let ian = Fixture.ian
    static let year = Fixture.year
    static let day = Fixture.day

    static func snapshot(
        _ faces: [FaceFact],
        people: [PeopleSnapshot.Person]? = nil,
        features: [PersonID: FaceID] = [:],
        likeness: [FaceID: Float] = [:],
        unchecked: Int = 0
    ) -> PeopleSnapshot {
        PeopleSnapshot(
            faces: faces,
            tiles: Dictionary(uniqueKeysWithValues: faces.map {
                ($0.id, FaceTile(id: $0.id, box: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.2), previewName: "p", captureSeconds: $0.captureSeconds))
            }),
            people: people ?? [
                .init(id: sam, name: "Sam", birthday: nil),
                .init(id: ian, name: "Ian", birthday: nil),
            ],
            likeness: likeness,
            features: features,
            uncheckedPhotoCount: unchecked,
            revision: 0
        )
    }

    /// The gallery: favourites first, then most photos, a named person before an unnamed one
    /// of the same count; hidden people last. The cover is the feature face, else the newest.
    @Test func theGalleryOrdersFavoritesThenPhotosAndHiddenLast() {
        let tyler = PersonID(rawValue: 3)
        let owen = PersonID(rawValue: 4)
        let faces = [
            Fixture.face("s1.jpg", toward: [0: 1], at: 0, assignment: .user(Self.sam)),
            Fixture.face("s2.jpg", toward: [0: 1], at: Self.day, assignment: .model(Self.sam)),
            Fixture.face("s3.jpg", toward: [0: 1], at: 2 * Self.day, assignment: .model(Self.sam)),
            Fixture.face("i1.jpg", toward: [1: 1], at: 0, assignment: .seed(Self.ian)),
            Fixture.face("t1.jpg", toward: [2: 1], at: 0, assignment: .seed(tyler)),
            Fixture.face("u1.jpg", toward: [3: 1], at: 0, assignment: .seed(owen)),
        ]
        let people: [PeopleSnapshot.Person] = [
            .init(id: Self.sam, name: "Sam", birthday: nil),
            .init(id: Self.ian, name: "Ian", birthday: nil, isHidden: true),
            .init(id: tyler, name: nil, birthday: nil),
            .init(id: owen, name: "Owen", birthday: nil, isFavorite: true),
        ]

        let state = PeopleStateBuilder.state(from: Self.snapshot(faces, people: people, features: [Self.sam: faces[0].id]))

        #expect(state.people.map(\.id) == [owen, Self.sam, tyler, Self.ian])
        #expect(state.visiblePeople.map(\.id) == [owen, Self.sam, tyler])
        #expect(state.person(Self.sam)?.photoCount == 3)
        #expect(state.person(Self.sam)?.cover?.id == faces[0].id)
        #expect(state.person(tyler)?.cover?.id == faces[4].id)
        #expect(state.person(Self.sam)?.userFaces.map(\.id) == [faces[0].id])
        #expect(state.person(Self.ian)?.anchorPhotos == [faces[3].id.asset])
    }

    /// A photo's faces as the menus and Info show them: a hidden person's face is left out;
    /// an unidentified face and a "not a face" detection are not.
    @Test func aPhotosFacesLeaveOutHiddenPeopleAndNonFaces() {
        let faces = [
            Fixture.face("g.jpg", index: 0, toward: [0: 1], at: 0, assignment: .model(Self.sam)),
            Fixture.face("g.jpg", index: 1, toward: [1: 1], at: 0, assignment: .user(Self.ian)),
            Fixture.face("g.jpg", index: 2, toward: [2: 1], at: 0),
            Fixture.face("g.jpg", index: 3, toward: [3: 1], at: 0, notAFace: true),
        ]
        let people: [PeopleSnapshot.Person] = [
            .init(id: Self.sam, name: "Sam", birthday: nil),
            .init(id: Self.ian, name: "Ian", birthday: nil, isHidden: true),
        ]

        let state = PeopleStateBuilder.state(from: Self.snapshot(faces, people: people))
        let selection = state.selectionFaces(for: [faces[0].id.asset])

        #expect(selection.faces.map(\.id) == [faces[0].id, faces[2].id])
        #expect(selection.people == [Self.sam])
        #expect(selection.unidentified.map(\.id) == [faces[2].id])
        #expect(state.faceCount == 3)
    }

    /// What one assignment writes is only what changed: a new guess, a guess taken away, a
    /// new person with seeds, a changed likeness, and a person Otos found whose last face is
    /// gone. The user's faces are never written.
    @Test func aPlanHoldsOnlyWhatChanged() {
        let tyler = PersonID(rawValue: 3)
        let faces = [
            Fixture.face("a.jpg", toward: [0: 1], at: 0, assignment: .user(Self.sam)),
            Fixture.face("b.jpg", toward: [0: 1], at: 0, assignment: .model(Self.sam)),
            Fixture.face("c.jpg", toward: [0: 1], at: 0, assignment: .model(Self.ian)),
            Fixture.face("d.jpg", toward: [0: 1], at: 0),
            Fixture.face("e.jpg", toward: [5: 1], at: 0),
            Fixture.face("f.jpg", toward: [5: 1], at: 0),
            Fixture.face("g.jpg", toward: [6: 1], at: 0, assignment: .model(tyler)),
        ]
        let people: [PeopleSnapshot.Person] = [
            .init(id: Self.sam, name: "Sam", birthday: nil),
            .init(id: Self.ian, name: "Ian", birthday: nil),
            .init(id: tyler, name: nil, birthday: nil),
        ]
        var result = FaceAssignmentResult()
        result.guesses = [faces[1].id: .existing(Self.sam), faces[2].id: .existing(Self.sam)]
        result.newPeople = [[faces[4].id, faces[5].id]]
        result.likeness = [faces[0].id: 0.9]

        let plan = FaceAssignmentPlan.changes(from: Self.snapshot(faces, people: people, likeness: [faces[1].id: 0.8]), to: result)

        #expect(Set(plan.guesses.map(\.face)) == [faces[2].id, faces[6].id])
        #expect(plan.guesses.first { $0.face == faces[6].id }?.person == nil)
        #expect(plan.newPeople == [[faces[4].id, faces[5].id]])
        let likeness: [FaceID: Float?] = [faces[0].id: 0.9, faces[1].id: nil]
        #expect(plan.likeness == likeness)
        #expect(plan.emptied == [tyler])
    }

    /// Across a selection, the people its unidentified faces most likely are; This Is gives
    /// a person the face most like them in each photo.
    @Test func theSelectionsLikelyPeopleAndTheFacesTheyAreGiven() {
        let one = Fixture.face("one.jpg", index: 0, toward: [0: 1], at: 0)
        let two = Fixture.face("two.jpg", index: 0, toward: [0: 1], at: 0)
        let twoOther = Fixture.face("two.jpg", index: 1, toward: [1: 1], at: 0)
        let state = PeopleStateBuilder.state(from: Self.snapshot([one, two, twoOther]))
        var selection = state.selectionFaces(for: [one.id.asset, two.id.asset])
        selection.candidates = [
            one.id: [.init(person: Self.ian, similarity: 0.7), .init(person: Self.sam, similarity: 0.5)],
            two.id: [.init(person: Self.ian, similarity: 0.6), .init(person: Self.sam, similarity: 0.4)],
            twoOther.id: [.init(person: Self.sam, similarity: 0.9), .init(person: Self.ian, similarity: 0.2)],
        ]

        #expect(selection.likelyPeople(for: selection.unidentified) == [Self.sam, Self.ian])
        #expect(selection.unidentifiedFacesToName(as: Self.ian) == [one.id, two.id])
        #expect(selection.unidentifiedFacesToName(as: Self.sam) == [one.id, twoOther.id])
    }

    /// The acts' hard rules disable them, with the reason the tooltip shows (DES-038).
    @Test func theHardRulesNameTheirReason() throws {
        let birthday = try #require(PersonBirthday.seconds("2021-01-01"))
        let samsFace = Fixture.face("a.jpg", index: 0, toward: [0: 1], at: 0, assignment: .user(Self.sam))
        let iansFace = Fixture.face("b.jpg", index: 0, toward: [1: 1], at: 0, assignment: .user(Self.ian))
        let people: [PeopleSnapshot.Person] = [
            .init(id: Self.sam, name: "Sam", birthday: nil),
            .init(id: Self.ian, name: "Ian", birthday: "2021-01-01"),
        ]
        let index = PeopleIndex(PeopleStateBuilder.state(from: Self.snapshot([samsFace, iansFace], people: people)))
        let other = PhotoFace(tile: Self.tile("a.jpg", index: 1, at: Fixture.epoch), person: nil)
        let early = PhotoFace(tile: Self.tile("c.jpg", at: birthday - Self.day), person: nil)
        let pair = [Self.tile("d.jpg", at: Fixture.epoch), Self.tile("d.jpg", index: 1, at: Fixture.epoch)].map {
            PhotoFace(tile: $0, person: nil)
        }

        #expect(index.moveRefusal([other], to: Self.sam) == "Sam is already in this photo")
        #expect(index.moveRefusal([early], to: Self.ian) == "1 photo is from before Ian's birthday")
        #expect(index.moveRefusal(pair, to: Self.sam) == "2 of these faces are in the same photo")
        #expect(index.moveRefusal([early], to: Self.sam) == nil)
        #expect(index.sheetRefusal(.person(Self.sam), name: "  ", birthday: nil) == "Enter a name")
        #expect(index.sheetRefusal(.person(Self.sam), name: "Sam", birthday: "20") == "Enter a year, or a full date")
        #expect(index.sheetRefusal(.person(Self.ian), name: "Ian", birthday: "2030") == "1 photo of Ian is from before this date")
        // A name another person has is not a refusal: saving it asks to merge.
        #expect(index.sheetRefusal(.person(Self.sam), name: "Ian", birthday: nil) == nil)
        #expect(index.person(named: "Ian", excluding: Self.sam) == Self.ian)
    }

    @Test func mergingIsRefusedWhenTheUserGaveBothAFaceOfOnePhoto() {
        let faces = [
            Fixture.face("g.jpg", index: 0, toward: [0: 1], at: 0, assignment: .user(Self.sam)),
            Fixture.face("g.jpg", index: 1, toward: [1: 1], at: 0, assignment: .seed(Self.ian)),
        ]
        let index = PeopleIndex(PeopleStateBuilder.state(from: Self.snapshot(faces)))

        #expect(index.mergeRefusal(Self.sam, into: Self.ian) == "Sam and Ian are both in 1 photo")
        #expect(index.mergeRefusal(Self.sam, into: Self.sam) == "Choose another person")
    }

    @Test func theWordsTheSurfacesUse() {
        #expect(PeoplePresentation.peopleLine(0) == "No people")
        #expect(PeoplePresentation.peopleLine(1) == "1 person")
        #expect(PeoplePresentation.peopleLine(14) == "14 people")
        #expect(PeoplePresentation.uncheckedLine(0) == "Every photo has been checked")
        #expect(PeoplePresentation.uncheckedLine(1820) == "1,820 photos not yet checked for faces")
        #expect(PeopleText.names(["Sam"]) == "Sam")
        #expect(PeopleText.names(["Sam", "Ian"]) == "Sam and Ian")
        #expect(PeopleText.names(["Sam", "Ian", "Tyler", "Owen"]) == "Sam, Ian and 2 Others")
        #expect(MediaSortOrder.likenessLeast.label(person: "Sam") == "Likeness — Least Like Sam First")
        #expect(MediaSortOrder.likenessMost.label(person: "Sam") == "Likeness — Most Like Sam First")
        #expect(MediaSortOrder.likenessLeast.label(person: nil) == "Likeness — Least Alike First")
        #expect(MediaSortOrder.dateNewest.label(person: "Sam") == "Date — Newest First")
    }

    /// Likeness orders photos only with one person filtered; otherwise the reads use the
    /// default order, and the user's choice is kept for when one person is filtered again.
    @Test func likenessNeedsOnePersonFiltered() {
        var descriptor = CatalogQueryDescriptor(scope: .allMedia, sort: .likenessLeast)
        #expect(descriptor.effectiveSort == .defaultOrder)
        descriptor.filter.people = [Self.sam]
        #expect(descriptor.effectiveSort == .likenessLeast)
        descriptor.filter.unassignedFaces = true
        #expect(descriptor.effectiveSort == .defaultOrder)
        #expect(descriptor.sort == .likenessLeast)
    }

    @Test func thePeopleFilterIsPartOfTheFilter() {
        var filter = MediaFilter.all.settingPerson(Self.sam, included: true)
        #expect(filter.isActive && filter.singlePerson == Self.sam)
        filter = filter.settingPerson(Self.ian, included: true)
        #expect(filter.singlePerson == nil && filter.filtersPeople)
        filter.peopleMatch = .all
        filter.choices = [.liked]
        #expect(filter.withoutPeople == MediaFilter(choices: [.liked]))
    }

    @Test func aDraggedPersonRoundTrips() {
        #expect(PeopleDrag.person(from: PeopleDrag.payload(Self.sam)) == Self.sam)
        #expect(PeopleDrag.person(from: "net.melisma.otos.other:1") == nil)
    }

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

    /// A face's outline on the edited photo: the box itself without an edit, mapped through
    /// a quarter turn and a crop, and nothing when the crop leaves it out.
    @Test func aFacesOutlineFollowsTheEdit() throws {
        let box = CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.1)
        let size = CGSize(width: 400, height: 200)
        var turned = EditRecipe()
        turned.quarterTurns = 1
        let quarter = try #require(EditGeometry(recipe: turned, developedSize: size).editedRect(ofDevelopedFraction: box))
        // A quarter turn clockwise: the left edge becomes the top.
        #expect(abs(quarter.minX - 0.7) < 1e-9 && abs(quarter.minY - 0.1) < 1e-9)
        #expect(abs(quarter.width - 0.1) < 1e-9 && abs(quarter.height - 0.2) < 1e-9)

        var cropped = EditRecipe()
        cropped.crop = EditCrop(left: 0.5, top: 0, width: 0.5, height: 1)
        #expect(EditGeometry(recipe: cropped, developedSize: size).editedRect(ofDevelopedFraction: box) == nil)
        cropped.crop = EditCrop(left: 0, top: 0, width: 0.5, height: 1)
        let half = try #require(EditGeometry(recipe: cropped, developedSize: size).editedRect(ofDevelopedFraction: box))
        #expect(abs(half.minX - 0.2) < 1e-9 && abs(half.width - 0.4) < 1e-9 && abs(half.minY - 0.2) < 1e-9)
    }

    static func tile(_ path: String, index: Int = 0, at seconds: Double?) -> FaceTile {
        FaceTile(
            id: FaceID(asset: MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/Lib"), relativePath: MediaRelativePath(rawValue: path)), index: index),
            box: .zero, previewName: nil, captureSeconds: seconds
        )
    }
}
