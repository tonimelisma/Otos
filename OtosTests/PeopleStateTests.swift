import CoreGraphics
import Foundation
import ImageIO
@testable import OtosKit
import Testing

/// What People shows (ADR 0047, `docs/design/people.md`): the gallery, the faces of a photo,
/// what one assignment writes, the people a selection's faces most likely are, the hard rules
/// the acts are held to, and the words the surfaces use. On embeddings whose similarities are
/// exact by construction (`FaceAssignmentPolicyTests.face`).
@Suite(.testScope)
struct PeopleStateTests {
    typealias Fixture = FaceAssignmentPolicyTests
    static let sam = Fixture.sam
    static let ian = Fixture.ian
    static let year = Fixture.year
    static let day = Fixture.day

    static func snapshot(
        _ faces: [FaceFact],
        people: [PeopleSnapshot.Person]? = nil,
        keyPhotos: [PersonID: FaceID] = [:],
        likeness: [FaceID: Float] = [:]
    ) -> PeopleSnapshot {
        PeopleSnapshot(
            facts: faces,
            people: people ?? [
                .init(id: sam, name: "Sam", birthday: nil),
                .init(id: ian, name: "Ian", birthday: nil),
            ],
            likeness: likeness,
            keyPhotos: keyPhotos
        )
    }

    /// Each face's tile, as a catalog holding `snapshot`'s faces stores it.
    static func tiles(_ snapshot: PeopleSnapshot) -> [FaceID: FaceTile] {
        Dictionary(uniqueKeysWithValues: snapshot.faces.map {
            ($0.id, FaceTile(
                id: $0.id, box: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.2),
                preview: FacePreview(name: "p", recipe: .neutral), captureSeconds: $0.captureSeconds,
                isInVideo: $0.isInVideo
            ))
        })
    }

    /// What the window reads of a catalog holding `snapshot`'s faces once People has written
    /// its gallery facts.
    static func state(_ snapshot: PeopleSnapshot) -> CatalogPeopleState {
        CatalogPeopleState(snapshot: snapshot, tiles: tiles(snapshot))
    }

    /// The faces of `files` as the photo menus read them from that catalog.
    static func photoFaces(_ snapshot: PeopleSnapshot, files: [MediaAssetID]) -> PhotoFaces {
        PhotoFaces(snapshot: snapshot, tiles: tiles(snapshot), files: files)
    }

    /// The gallery: favourites first, then most photos, a named person before an unnamed one
    /// of the same count; hidden people last. The cover is the key photo, else the newest.
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

        let state = Self.state(Self.snapshot(faces, people: people, keyPhotos: [Self.sam: faces[0].id]))

        #expect(state.people.map(\.id) == [owen, Self.sam, tyler, Self.ian])
        #expect(state.visiblePeople.map(\.id) == [owen, Self.sam, tyler])
        #expect(state.hiddenPeople.map(\.id) == [Self.ian])
        #expect(state.visibleNames == ["Owen", "Sam"])
        #expect(state.inGalleryOrder([Self.ian, tyler, owen, PersonID(rawValue: 99)]).map(\.id) == [owen, tyler, Self.ian])
        #expect(state.person(Self.sam)?.media == MediaCount(photos: 3))
        #expect(state.person(Self.sam)?.cover?.id == faces[0].id)
        #expect(state.person(tyler)?.cover?.id == faces[4].id)
        #expect(state.person(Self.sam)?.userFaces.map(\.photo) == [faces[0].id.asset])
        #expect(state.person(Self.ian)?.anchorMedia.keys.map(\.self) == [faces[3].id.asset])
    }

    /// A likeness is written when it appears, goes, or moves past its precision, never for
    /// the last-bit wobble Accelerate's matrix product brings from one process to the next,
    /// so an assignment run on an unchanged catalog writes nothing and People settles.
    @Test func aLikenessThatOnlyWobblesIsNotWritten() {
        let stored: Float = 0.8001686
        #expect(!FaceAssignmentPlan.likenessMoved(from: stored, to: stored + 4.8e-7))
        #expect(!FaceAssignmentPlan.likenessMoved(from: nil, to: nil))
        #expect(FaceAssignmentPlan.likenessMoved(from: stored, to: stored + 1e-3))
        #expect(FaceAssignmentPlan.likenessMoved(from: nil, to: stored))
        #expect(FaceAssignmentPlan.likenessMoved(from: stored, to: nil))
    }

    /// A photo's faces as the menus and Info show them: a hidden person's face is left out,
    /// an unidentified face is not. (A detection marked not a face never reaches the
    /// snapshot: `PeopleStoreTests`.)
    @Test func aPhotosFacesLeaveOutHiddenPeople() {
        let faces = [
            Fixture.face("g.jpg", index: 0, toward: [0: 1], at: 0, assignment: .model(Self.sam)),
            Fixture.face("g.jpg", index: 1, toward: [1: 1], at: 0, assignment: .user(Self.ian)),
            Fixture.face("g.jpg", index: 2, toward: [2: 1], at: 0),
        ]
        let people: [PeopleSnapshot.Person] = [
            .init(id: Self.sam, name: "Sam", birthday: nil),
            .init(id: Self.ian, name: "Ian", birthday: nil, isHidden: true),
        ]

        let snapshot = Self.snapshot(faces, people: people)
        let selection = Self.photoFaces(snapshot, files: [faces[0].id.asset]).selectionFaces(for: [faces[0].id.asset])

        #expect(selection.faces.map(\.id) == [faces[0].id, faces[2].id])
        #expect(selection.people == [Self.sam])
        #expect(selection.unidentified.map(\.id) == [faces[2].id])
        #expect(Self.state(snapshot).hasFaces)
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

    /// A lapsed seed is released from its person and given out again: the plan names the
    /// person it was a seed of, carries its new guess when it has one, and empties the
    /// person it leaves with no face.
    @Test func aPlanReleasesLapsedSeeds() {
        let found = PersonID(rawValue: 7)
        let faces = [
            Fixture.face("a.jpg", toward: [0: 1], at: 0, assignment: .user(Self.sam)),
            Fixture.face("b.jpg", toward: [5: 1], at: 0, assignment: .seed(found)),
            Fixture.face("c.jpg", toward: [5: 1], at: 0, assignment: .seed(found)),
        ]
        let people: [PeopleSnapshot.Person] = [
            .init(id: Self.sam, name: "Sam", birthday: nil), .init(id: found, name: nil, birthday: nil),
        ]
        var result = FaceAssignmentResult()
        result.lapsedSeeds = [faces[1].id, faces[2].id]
        result.guesses = [faces[2].id: .existing(Self.sam)]

        let plan = FaceAssignmentPlan.changes(from: Self.snapshot(faces, people: people), to: result)

        #expect(plan.lapsedSeeds == [faces[1].id: found, faces[2].id: found])
        #expect(plan.guesses == [.init(face: faces[2].id, person: .existing(Self.sam))])
        #expect(plan.emptied == [found])
    }

    /// Assignment reads a person as Otos's own only when the user said nothing about them;
    /// a key photo the user chose is their word.
    @Test func aKeyPhotoMakesAPersonTheUsers() {
        let found = PersonID(rawValue: 7)
        let face = Fixture.face("a.jpg", toward: [5: 1], at: 0, assignment: .seed(found))
        var snapshot = Self.snapshot([face], people: [.init(id: found, name: nil, birthday: nil)])
        #expect(snapshot.personFacts.map(\.isBare) == [true])
        snapshot.keyPhotos = [found: face.id]
        #expect(snapshot.personFacts.map(\.isBare) == [false])
    }

    /// Across a selection, the people its unidentified faces most likely are; This Is gives
    /// a person the face most like them in each photo.
    @Test func theSelectionsLikelyPeopleAndTheFacesTheyAreGiven() {
        let one = Fixture.face("one.jpg", index: 0, toward: [0: 1], at: 0)
        let two = Fixture.face("two.jpg", index: 0, toward: [0: 1], at: 0)
        let twoOther = Fixture.face("two.jpg", index: 1, toward: [1: 1], at: 0)
        let files = [one.id.asset, two.id.asset]
        var selection = Self.photoFaces(Self.snapshot([one, two, twoOther]), files: files).selectionFaces(for: files)
        selection.candidates = [
            one.id: [.init(person: Self.ian, similarity: 0.7), .init(person: Self.sam, similarity: 0.5)],
            two.id: [.init(person: Self.ian, similarity: 0.6), .init(person: Self.sam, similarity: 0.4)],
            twoOther.id: [.init(person: Self.sam, similarity: 0.9), .init(person: Self.ian, similarity: 0.2)],
        ]

        #expect(selection.likelyPeople(for: selection.unidentified) == [Self.sam, Self.ian])
        #expect(selection.unidentifiedFacesToName(as: Self.ian) == [one.id, two.id])
        #expect(selection.unidentifiedFacesToName(as: Self.sam) == [one.id, twoOther.id])
    }

    /// A birthday is a whole date or only a year, which counts from 1 January, at midnight
    /// UTC; it reads back from its stored text exactly, and anything else is no birthday.
    @Test func aBirthdayIsAYearOrAWholeDate() throws {
        let year = try #require(PersonBirthday("2025"))
        #expect(year.seconds == 1_735_689_600 && !year.isExact && year.text == "2025")
        let day = try #require(PersonBirthday("2022-11-03"))
        #expect(day.seconds == 1_667_433_600 && day.isExact && day.text == "2022-11-03")
        #expect(PersonBirthday("0950")?.text == "0950")
        #expect(PersonBirthday(utcDay: Date(timeIntervalSince1970: 1_667_433_600 + 3600)) == day)
        for text in ["", "25", "abcd", "+020", "2020-1-5", "2020-13-01", "2021-02-30", "2020-01", "２０２０"] {
            #expect(PersonBirthday(text) == nil, "\(text)")
        }
    }

    /// The acts' hard rules disable them, with the reason the tooltip shows (DES-038).
    @Test func theHardRulesNameTheirReason() throws {
        let birthday = try #require(PersonBirthday("2021-01-01")?.seconds)
        let samsFace = Fixture.face("a.jpg", index: 0, toward: [0: 1], at: 0, assignment: .user(Self.sam))
        let iansFace = Fixture.face("b.jpg", index: 0, toward: [1: 1], at: 0, assignment: .user(Self.ian))
        let people: [PeopleSnapshot.Person] = [
            .init(id: Self.sam, name: "Sam", birthday: nil),
            .init(id: Self.ian, name: "Ian", birthday: PersonBirthday("2021-01-01")),
        ]
        let index = Self.state(Self.snapshot([samsFace, iansFace], people: people))
        let other = PhotoFace(tile: Self.tile("a.jpg", index: 1, at: Fixture.epoch), person: nil)
        let early = PhotoFace(tile: Self.tile("c.jpg", at: birthday - Self.day), person: nil)
        let pair = [Self.tile("d.jpg", at: Fixture.epoch), Self.tile("d.jpg", index: 1, at: Fixture.epoch)].map {
            PhotoFace(tile: $0, person: nil)
        }

        #expect(index.moveRefusal([other], to: Self.sam) == "Sam is already in this photo")
        #expect(index.moveRefusal([early], to: Self.ian) == "1 photo is from before Ian’s birthday")
        #expect(index.moveRefusal(pair, to: Self.sam) == "2 of these faces are in the same photo")
        #expect(index.moveRefusal([early], to: Self.sam) == nil)
        #expect(index.sheetRefusal(.person(Self.sam), name: "  ", birthday: nil, faces: .none) == "Enter a name")
        #expect(index.sheetRefusal(.person(Self.sam), name: "Sam", birthday: "20", faces: .none) == "Enter a year, or a full date")
        #expect(index.sheetRefusal(.person(Self.ian), name: "Ian", birthday: "2030", faces: .none) == "1 photo of Ian is from before this date")
        // A name another person has asks to merge, so Save is refused as that merge is.
        #expect(index.sheetRefusal(.person(Self.sam), name: "Ian", birthday: nil, faces: .none) == index.mergeRefusal(Self.sam, into: Self.ian))
        #expect(index.sheetRefusal(.person(Self.sam), name: "Ian", birthday: nil, faces: .none) == "2 photos are from before the birthday")
        // The birthday typed is the one the merge is judged with: cleared, nothing predates it.
        #expect(index.mergeRefusal(Self.ian, into: Self.sam) != nil)
        #expect(index.sheetRefusal(.person(Self.ian), name: "Sam", birthday: nil, faces: .none) == nil)
        #expect(index.person(named: "Ian", excluding: Self.sam) == Self.ian)
    }

    /// Every refusal that counts says what it counts (`MediaCount`, ADR 0047's Counts): photos,
    /// videos, or photos and videos, each counted once however many faces it holds.
    @Test func refusalsCountPhotosAndVideosAsWhatTheyAre() throws {
        let birthday = try #require(PersonBirthday("2021-01-01")?.seconds)
        let before = birthday - Self.day
        let people: [PeopleSnapshot.Person] = [
            .init(id: Self.sam, name: "Sam", birthday: nil),
            .init(id: Self.ian, name: "Ian", birthday: nil),
        ]
        func index(_ paths: [String], ianToo: Bool = false) -> CatalogPeopleState {
            let faces = paths.flatMap { path in
                [Fixture.face(path, index: 0, toward: [0: 1], at: 0, assignment: .user(Self.sam))]
                    + (ianToo ? [Fixture.face(path, index: 1, toward: [1: 1], at: 0, assignment: .user(Self.ian))] : [])
            }
            return Self.state(Self.snapshot(faces, people: people))
        }
        for (paths, said) in [(["a.jpg", "b.jpg"], "2 photos"), (["a.mov", "b.mov"], "2 videos"), (["a.jpg", "b.mov"], "2 photos and videos")] {
            #expect(index(paths).sheetRefusal(.person(Self.sam), name: "Sam", birthday: "2030", faces: .none) == "\(said) of Sam are from before this date")
            #expect(index(paths, ianToo: true).mergeRefusal(Self.sam, into: Self.ian) == "Sam and Ian are both in \(said)")
        }
        // Two faces of one video are in the same video; a video Ian was given holds him.
        let video = Self.state(Self.snapshot(
            [Fixture.face("v.mov", index: 0, toward: [1: 1], at: before, assignment: .user(Self.ian))],
            people: [.init(id: Self.sam, name: "Sam", birthday: nil), .init(id: Self.ian, name: "Ian", birthday: PersonBirthday("2021-01-01"))]
        ))
        let pair = [Self.tile("w.mov", at: Fixture.epoch), Self.tile("w.mov", index: 1, at: Fixture.epoch)].map { PhotoFace(tile: $0, person: nil) }
        #expect(video.moveRefusal(pair, to: Self.ian) == "2 of these faces are in the same video")
        let inVideo = PhotoFace(tile: Self.tile("v.mov", index: 1, at: Fixture.epoch), person: nil)
        #expect(video.moveRefusal([inVideo], to: Self.ian) == "Ian is already in this video")
        let early = [Self.tile("x.mov", at: before), Self.tile("x.mov", index: 1, at: before), Self.tile("y.jpg", at: before)]
            .map { PhotoFace(tile: $0, person: nil) }
        #expect(video.moveRefusal(Array(early.dropFirst()), to: Self.ian) == "2 photos and videos are from before Ian’s birthday")
        #expect(PeopleText.beforeTheBirthday(MediaCount(videos: 1)) == "1 video is from before the birthday")
    }

    @Test func mergingIsRefusedWhenTheUserGaveBothAFaceOfOnePhoto() {
        let faces = [
            Fixture.face("g.jpg", index: 0, toward: [0: 1], at: 0, assignment: .user(Self.sam)),
            Fixture.face("g.jpg", index: 1, toward: [1: 1], at: 0, assignment: .seed(Self.ian)),
        ]
        let index = Self.state(Self.snapshot(faces))

        #expect(index.mergeRefusal(Self.sam, into: Self.ian) == "Sam and Ian are both in 1 photo")
        #expect(index.mergeRefusal(Self.sam, into: Self.sam) == "Choose another person")
    }

    /// Likeness orders one person's photos; elsewhere, a People filter of one person
    /// included, the reads use the default order, and the user's choice is kept for the next
    /// person's photos.
    @Test func likenessNeedsOnePersonsPhotos() {
        var descriptor = CatalogQueryDescriptor(scope: .allMedia, sort: .likenessLeast)
        #expect(descriptor.effectiveSort == .defaultOrder)
        descriptor.filter.people = [Self.sam]
        #expect(descriptor.effectiveSort == .defaultOrder)
        descriptor.scope = .person(Self.sam)
        #expect(descriptor.effectiveSort == .likenessLeast)
        #expect(descriptor.sort == .likenessLeast)
    }

    @Test func thePeopleFilterIsPartOfTheFilter() {
        var filter = MediaFilter.all.settingPerson(Self.sam, included: true)
        #expect(filter.isActive && filter.filtersPeople)
        filter = filter.settingPerson(Self.sam, included: false)
        #expect(!filter.isActive)
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

    /// A face tile of an edited photo shows the face: its box, a fraction of the upright
    /// photo, is carried onto the stored preview through the crop and the quarter turn that
    /// preview shows; a face the crop leaves out has no tile. The upright photo is 400 × 200
    /// with the face at x 240–280, y 80–120.
    @Test func anEditedPhotosFaceTileShowsTheFace() async throws {
        let directory = try makeTestDirectory()
        let box = CGRect(x: 0.6, y: 0.4, width: 0.1, height: 0.2)

        // The right half kept: the face at x 40–80 of a 200 × 200 preview.
        let rightHalf = EditRecipe(crop: EditCrop(left: 0.5, top: 0, width: 0.5, height: 1))
        try Self.writePreview("cropped.png", width: 200, height: 200, face: CGRect(x: 40, y: 80, width: 40, height: 40), in: directory)
        let cropped = try #require(await FaceCrop.decode(box, from: FacePreview(name: "cropped.png", recipe: rightHalf), in: directory, pixelEdge: 64))
        #expect(Self.isFace(Self.centerPixel(of: cropped.cgImage)))

        // A quarter turn clockwise: the face at x 80–120, y 240–280 of a 200 × 400 preview.
        let turned = EditRecipe(quarterTurns: 1)
        try Self.writePreview("turned.png", width: 200, height: 400, face: CGRect(x: 80, y: 240, width: 40, height: 40), in: directory)
        let quarter = try #require(await FaceCrop.decode(box, from: FacePreview(name: "turned.png", recipe: turned), in: directory, pixelEdge: 64))
        #expect(Self.isFace(Self.centerPixel(of: quarter.cgImage)))

        // The left half kept: the face is not on the preview.
        let leftHalf = EditRecipe(crop: EditCrop(left: 0, top: 0, width: 0.5, height: 1))
        #expect(await FaceCrop.decode(box, from: FacePreview(name: "cropped.png", recipe: leftHalf), in: directory, pixelEdge: 64) == nil)
    }

    /// A face tile holds its own pixels and no more: a small face on a 2560 px preview gives a
    /// tile at most the size asked for, whose bytes are its own rows, not the preview's
    /// (`DisplayImage.draw`). A crop sharing the preview's pixels kept the whole decode alive.
    @Test func aFaceTileHoldsOnlyItsOwnPixels() async throws {
        let directory = try makeTestDirectory()
        try Self.writePreview("large.png", width: 2560, height: 1920, face: CGRect(x: 1200, y: 900, width: 100, height: 100), in: directory)
        let box = CGRect(x: 1200.0 / 2560, y: 900.0 / 1920, width: 100.0 / 2560, height: 100.0 / 1920)
        let tile = try #require(await FaceCrop.decode(box, from: FacePreview(name: "large.png", recipe: .neutral), in: directory, pixelEdge: 128))
        #expect(tile.width == 128 && tile.height == 128)
        #expect(tile.cgImage.bytesPerRow == tile.width * 4)
        // Its surface is its rows and the surface's own few bytes of alignment, a page at most:
        // nothing of the 2560 px preview it was cut from.
        #expect(tile.byteCount <= tile.cgImage.bytesPerRow * tile.height + 4096)
        #expect(Self.isFace(Self.centerPixel(of: tile.cgImage)))
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

    /// `FaceOutline` places a box on the photo as shown: as is without an edit, through the
    /// edit with the upright size, nowhere with an edit and no size; and draws each outline
    /// in its frame from the top-left corner.
    @Test func anOutlineIsPlacedThroughTheEdit() throws {
        let box = CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.1)
        var cropped = EditRecipe()
        cropped.crop = EditCrop(left: 0, top: 0, width: 0.5, height: 1)
        #expect(FaceOutline.onEditedPhoto(box, recipe: nil, upright: nil) == box)
        #expect(FaceOutline.onEditedPhoto(box, recipe: cropped, upright: nil) == nil)
        let half = try #require(FaceOutline.onEditedPhoto(box, recipe: cropped, upright: CGSize(width: 400, height: 200)))
        #expect(abs(half.minX - 0.2) < 1e-9 && abs(half.width - 0.4) < 1e-9)
        let frame = CGRect(x: 10, y: 20, width: 200, height: 100)
        #expect(FaceOutline.path([box], in: frame).boundingBox == CGRect(x: 30, y: 40, width: 40, height: 10))
    }

    /// The loupe and compare place outlines through the edit their own decode shows, so they
    /// need nothing the Info pane reads (DES-113): a decode carries the original's upright
    /// size and its edit, and its shown size follows from them.
    @Test func aPaneDecodePlacesOutlinesThroughItsOwnEdit() {
        let box = CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.1)
        var cropped = EditRecipe()
        cropped.crop = EditCrop(left: 0, top: 0, width: 0.5, height: 1)
        let image = DisplayImage.fixture(width: 4, height: 2)
        let id = MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/Lib"), relativePath: MediaRelativePath(rawValue: "a.jpg"))
        let upright = CGSize(width: 400, height: 200)

        let edited = PanePreview(id: id, image: image, uprightPixelSize: upright, editRecipe: cropped)
        #expect(edited.faceOutlines([box]) == [FaceOutline.onEditedPhoto(box, recipe: cropped, upright: upright)].compactMap(\.self))
        #expect(edited.nativePixelSize == cropped.outputSize(ofOriginal: upright))

        let original = PanePreview(id: id, image: image, uprightPixelSize: upright)
        #expect(original.faceOutlines([box]) == [box])
        #expect(original.nativePixelSize == upright)
        #expect(PanePreview(id: id, image: image, editRecipe: cropped).faceOutlines([box]).isEmpty)
    }

    /// A blue preview of `width` × `height` with a red face at `face`, top-left origin.
    static func writePreview(_ name: String, width: Int, height: Int, face: CGRect, in directory: URL) throws {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: face.minX, y: CGFloat(height) - face.maxY, width: face.width, height: face.height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            directory.appending(path: name) as CFURL, "public.png" as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// The image's center pixel as red, green, blue.
    static func centerPixel(of image: CGImage) -> (UInt8, UInt8, UInt8) {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            let center = CGPoint(x: image.width / 2, y: image.height / 2)
            context?.draw(image, in: CGRect(x: -center.x, y: -center.y, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return (pixel[0], pixel[1], pixel[2])
    }

    static func isFace(_ pixel: (UInt8, UInt8, UInt8)) -> Bool {
        pixel.0 > 200 && pixel.2 < 50
    }

    static func tile(_ path: String, index: Int = 0, at seconds: Double?) -> FaceTile {
        FaceTile(
            id: FaceID(asset: MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/Lib"), relativePath: MediaRelativePath(rawValue: path)), index: index),
            box: .zero, preview: nil, captureSeconds: seconds, isInVideo: path.hasSuffix(".mov")
        )
    }
}
