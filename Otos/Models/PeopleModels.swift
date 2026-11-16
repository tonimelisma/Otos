import CoreGraphics
import CryptoKit
import Foundation

// People models (ADR 0047, `docs/design/people.md`)
//
// What the store reads for People in one transaction (`PeopleSnapshot`), what assignment
// writes back (`FaceAssignmentPlan`), what `PeopleAssignment` publishes (`CatalogPeopleState`)
// and answers about selected photos (`SelectionFaces`), and the user's acts on faces and
// people (`PeopleAct`) with the record that undoes one (`PeopleRestore`). Values only: the
// store writes, the owner derives, and the views render these.

/// One face as a tile shows it: where it is in its photo and the stored image it is cut from:
/// a still's preview (ADR 0035), or the frame of a video it was read in (ADR 0047).
nonisolated struct FaceTile: Hashable, Sendable, Identifiable {
    let id: FaceID
    /// Fractions of the upright photo, or of a video's frame, top-left origin.
    let box: CGRect
    /// Nil before a preview is made, and while the one stored shows an edit no longer saved:
    /// its rendering of the new edit is owed, and the tile waits for it rather than cut
    /// through an edit it cannot know. Nil for a video's face kept from an earlier reading,
    /// whose frame the new reading replaced.
    let preview: FacePreview?
    /// The photo's local capture time (`CaptureLocalTime.seconds`); nil when the photo has
    /// no date. Its UTC day is the day the photo was taken, the same day a birthday names.
    let captureSeconds: Double?
    /// The face was read in one frame of a video: its box belongs to that frame, so it is
    /// never outlined on the video, and a video's face is no person's key photo (ADR 0047).
    var isInVideo = false

    var captureLocalTime: CaptureLocalTime? {
        captureSeconds.map(CaptureLocalTime.init(seconds:))
    }
}

/// A stored image a face is cut from and the edit it shows (`.neutral` for the unedited
/// photo and for a video's frame): the face box, a fraction of the upright photo, is carried
/// through that edit onto the image.
nonisolated struct FacePreview: Hashable, Sendable {
    /// The file's name in the derived-image directory: a still's preview, or a video's face
    /// frames.
    let name: String
    let recipe: EditRecipe
    /// Which image of the file: 0 for a preview, the frame for a video's face frames.
    let image: Int

    init(name: String, recipe: EditRecipe, image: Int = 0) {
        self.name = name
        self.recipe = recipe
        self.image = image
    }
}

/// Everything People reads from the catalog, in one transaction: who the faces are and how
/// their tiles show, never their vectors, which `FaceVectors` holds, read apart.
nonisolated struct PeopleSnapshot: Sendable, Equatable {
    nonisolated struct Person: Sendable, Equatable {
        let id: PersonID
        let name: String?
        let birthday: PersonBirthday?
        var isHidden = false
        var isFavorite = false
    }

    /// One stored face as assignment and the gallery read it: where it is, when its photo was
    /// taken, the number of its vector's row (`FaceEmbeddingSQL`), and what the user decided.
    nonisolated struct Face: Sendable, Equatable {
        let id: FaceID
        /// The photo's local capture time (`CaptureLocalTime.seconds`); nil without a date.
        let captureSeconds: Double?
        let vector: Int64
        let assignment: FaceAssignment
        /// People the user said this face is not (Remove Name).
        let rejected: Set<PersonID>

        /// The face as assignment compares it, with its vector; nil when the vector is not
        /// held or holds no embedding.
        func fact(with vectors: FaceVectors) -> FaceFact? {
            vectors.embedding(vector).map {
                FaceFact(id: id, captureSeconds: captureSeconds, embedding: $0, assignment: assignment, rejected: rejected)
            }
        }
    }

    /// Every face of a photo still in the catalog and out of the Trash, in reading order;
    /// none the user marked as not a face.
    private(set) var faces: [Face]
    /// Each face's tile; none in a snapshot kept after its gallery was built (`withoutTiles`).
    private(set) var tiles: [FaceID: FaceTile]
    /// In creation order.
    let people: [Person]
    /// Each face's stored likeness.
    var likeness: [FaceID: Float] = [:]
    /// Each person's key photo, where the user chose one.
    var keyPhotos: [PersonID: FaceID] = [:]
    /// Each file that is one of several of a photo mapped to the file that stands for it
    /// (`photos(stackKeys:copies:)`), so a person's photo count counts the photo once. A file
    /// absent from it stands for itself.
    var photoOf: [MediaAssetID: MediaAssetID] = [:]
    /// The present identical copies (ADR 0054) of each photo one of whose files holds a face,
    /// each group in the order copies are shown in (`ranked`): what a photo's faces are
    /// resolved through, so every copy shows the photo's people (`CatalogPeopleState.faces(of:)`).
    var copies: [[MediaAssetID]] = []

    /// One present identical copy of a photo with a face, with what ranks it among its copies.
    nonisolated struct Copy: Sendable {
        let asset: MediaAssetID
        let rootID: Int64
        let isAccount: Bool
    }

    /// Each group of copies in the order the shown copy is chosen by (ADR 0054): a library's
    /// before an account's, then by root and path.
    static func ranked(_ copies: [[Copy]]) -> [[MediaAssetID]] {
        copies.map { group in
            group.sorted { lhs, rhs in
                if lhs.isAccount != rhs.isAccount {
                    return !lhs.isAccount
                }
                return (lhs.rootID, lhs.asset.relativePath.rawValue) < (rhs.rootID, rhs.asset.relativePath.rawValue)
            }.map(\.asset)
        }
    }

    /// The file each file with faces stands for, where it is not itself:
    /// - identical copies (ADR 0054) — each group of `copies` — are one photo, which the copy
    ///   shown first among them stands for;
    /// - the files of a stack (ADR 0052) — a RAW and its JPEG — are one photo, which the
    ///   stack's key stands for, reached through the copy.
    static func photos(stackKeys: [MediaAssetID: MediaAssetID], copies: [[Copy]]) -> [MediaAssetID: MediaAssetID] {
        var photoOf = stackKeys
        for ranked in ranked(copies) where ranked.count > 1 {
            let shown = ranked[0]
            let photo = stackKeys[shown] ?? shown
            for copy in ranked.dropFirst() {
                photoOf[copy] = photo
            }
        }
        return photoOf
    }

    /// What in the available libraries and Immich accounts is not yet read for faces: stills
    /// whose faces are not read from their current stored preview, or whose preview is still
    /// to come, and a library's videos whose frames are not yet read.
    let unchecked: MediaCount

    /// Whether the user has said nothing about `person`: no name, birthday, favourite,
    /// hidden mark or key photo. A person Otos found and the user never touched is forgotten
    /// with their last face, and their seeds lapse when their group no longer stands.
    func isBare(_ person: Person) -> Bool {
        person.name == nil && person.birthday == nil && !person.isHidden && !person.isFavorite
            && keyPhotos[person.id] == nil
    }

    /// The people as assignment reads them.
    var personFacts: [PersonFact] {
        people.map { PersonFact(id: $0.id, birthdaySeconds: $0.birthday?.seconds, isBare: isBare($0)) }
    }

    /// The faces as assignment reads them, each with its vector; a face whose vector is not
    /// held, or holds no embedding, is left out.
    func facts(with vectors: FaceVectors) -> [FaceFact] {
        faces.compactMap { $0.fact(with: vectors) }
    }

    /// The vector numbers the faces name.
    var vectors: Set<Int64> {
        Set(faces.map(\.vector))
    }

    /// This snapshot with only the faces among `ids`.
    func keeping(_ ids: Set<FaceID>) -> PeopleSnapshot {
        var kept = self
        kept.faces = faces.filter { ids.contains($0.id) }
        return kept
    }

    /// This snapshot without its tiles: what is kept once the gallery is built from it.
    var withoutTiles: PeopleSnapshot {
        var kept = self
        kept.tiles = [:]
        return kept
    }
}

/// What assignment reads of a People snapshot, hashed (ADR 0047): equal inputs give an equal
/// assignment, so a catalog whose stored guesses are assignment's output on these inputs owes
/// none. The catalog keeps the hash it settled on (`CatalogStore.recordSettledPeopleAssignment`),
/// so a launch with nothing changed assigns nothing.
///
/// It hashes every fact `FaceAssignmentPolicy.assign` reads, and only those: each face's
/// identity, vector number (a new reading is a new number, so a changed embedding is a
/// changed input), capture time, rejections and anchor (the user's word, a seed, held, or
/// Otos's to decide: a guess's person is assignment's output, never its input); each person's
/// id, birthday and whether the user said anything about them; which file stands for which
/// photo; and the policy's constants with `FaceAssignmentPolicy.revision`, so a build that
/// assigns differently assigns again. Names, covers, tiles and stored likenesses are not
/// inputs.
nonisolated struct AssignmentInputs: Equatable, Sendable {
    let digest: Data

    init(digest: Data) {
        self.digest = digest
    }

    init(_ read: PeopleSnapshot) {
        var hasher = SHA256()
        func add(_ value: some FixedWidthInteger) {
            withUnsafeBytes(of: Int64(value).littleEndian) { hasher.update(bufferPointer: $0) }
        }
        func add(_ value: Double?) {
            withUnsafeBytes(of: (value?.bitPattern ?? UInt64.max).littleEndian) { hasher.update(bufferPointer: $0) }
        }
        func add(_ text: String) {
            let bytes = Data(text.utf8)
            add(bytes.count)
            hasher.update(data: bytes)
        }
        func add(_ asset: MediaAssetID) {
            add(asset.libraryRootPath.rawValue)
            add(asset.relativePath.rawValue)
        }
        add(FaceAssignmentPolicy.revision)
        for constant in FaceAssignmentPolicy.constants {
            add(constant)
        }
        add(read.faces.count)
        for face in read.faces {
            add(face.id.asset)
            add(face.id.index)
            add(face.vector)
            add(face.captureSeconds)
            switch face.assignment {
            case .open, .model: add(0)
            case let .seed(person): add(1)
                add(person.rawValue)
            case let .user(person): add(2)
                add(person.rawValue)
            case .held: add(3)
            }
            add(face.rejected.count)
            for person in face.rejected.sorted() {
                add(person.rawValue)
            }
        }
        let people = read.personFacts
        add(people.count)
        for person in people {
            add(person.id.rawValue)
            add(person.birthdaySeconds)
            add(person.isBare ? 1 : 0)
        }
        let photoOf = read.photoOf.sorted {
            ($0.key.relativePath.rawValue, $0.key.libraryRootPath.rawValue) < ($1.key.relativePath.rawValue, $1.key.libraryRootPath.rawValue)
        }
        add(photoOf.count)
        for (file, photo) in photoOf {
            add(file)
            add(photo)
        }
        digest = Data(hasher.finalize())
    }
}

/// What one assignment changes in the catalog: only what differs from the snapshot it was
/// computed from. The store writes each guess only where the face is still Otos's to decide,
/// so an act the user made meanwhile always wins.
nonisolated struct FaceAssignmentPlan: Sendable, Equatable {
    nonisolated struct Guess: Sendable, Equatable {
        let face: FaceID
        /// Nil takes the face's guess away.
        let person: FaceAssignmentResult.Person?
    }

    var guesses: [Guess] = []
    /// New people, each with its seed faces.
    var newPeople: [[FaceID]] = []
    /// Faces whose stored likeness changes; nil clears it.
    var likeness: [FaceID: Float?] = [:]
    /// People Otos found who had a face and now have none; each is deleted if, when written,
    /// it still has none and the user has said nothing about them.
    var emptied: [PersonID] = []
    /// Seeds whose group no longer stands, with the person each was a seed of: each loses its
    /// person if, when written, it is still that person's seed. Written before the guesses
    /// and new people, which may give it out again.
    var lapsedSeeds: [FaceID: PersonID] = [:]

    var isEmpty: Bool {
        guesses.isEmpty && newPeople.isEmpty && likeness.isEmpty && emptied.isEmpty && lapsedSeeds.isEmpty
    }

    /// How far a likeness must move to be a change. Accelerate's matrix product rounds
    /// differently from process to process: on the owner's 89,474 faces, likenesses read by
    /// the same code in two processes differed by up to 4.8e-7. Writing such a wobble would
    /// make every assignment change the catalog, and the change starts the next assignment,
    /// so People would never settle. Likeness only orders a person's photos.
    static let likenessPrecision: Float = 1e-5

    /// Whether a face's likeness changed: it appeared, went, or moved past
    /// `likenessPrecision`.
    static func likenessMoved(from stored: Float?, to computed: Float?) -> Bool {
        switch (stored, computed) {
        case let (stored?, computed?): abs(stored - computed) > likenessPrecision
        case (nil, nil): false
        default: true
        }
    }

    /// What one assignment of `snapshot`'s faces — `facts`, the same faces with their vectors —
    /// changes: the policy's result, as changes to the snapshot. The one path from a snapshot
    /// to what `CatalogStore.applyAssignment` writes, which People and the accuracy harness
    /// both take.
    /// A face of the snapshot missing from `facts` (its vector not yet read) is left as it is
    /// stored: assignment did not see it, so the plan neither guesses nor clears it.
    static func assignment(of snapshot: PeopleSnapshot, facts: [FaceFact]) -> FaceAssignmentPlan {
        let seen = facts.count == snapshot.faces.count ? snapshot : snapshot.keeping(Set(facts.map(\.id)))
        return changes(from: seen, to: FaceAssignmentPolicy.assign(faces: facts, people: snapshot.personFacts, photoOf: snapshot.photoOf))
    }

    /// The changes that take the snapshot to `result`.
    static func changes(from snapshot: PeopleSnapshot, to result: FaceAssignmentResult) -> FaceAssignmentPlan {
        var plan = FaceAssignmentPlan()
        plan.newPeople = result.newPeople
        let seeded = Set(result.newPeople.joined())
        var keeps: Set<PersonID> = []
        for face in snapshot.faces {
            let computed = result.likeness[face.id]
            if Self.likenessMoved(from: snapshot.likeness[face.id], to: computed) {
                plan.likeness[face.id] = .some(computed)
            }
            let lapsed = result.lapsedSeeds.contains(face.id)
            if lapsed, let person = face.assignment.person {
                plan.lapsedSeeds[face.id] = person
            }
            guard !seeded.contains(face.id) else { continue }
            let target = result.guesses[face.id]
            let kept: FaceAssignmentResult.Person?
            if lapsed {
                kept = target
                if target != nil {
                    plan.guesses.append(Guess(face: face.id, person: target))
                }
            } else if face.assignment.isGuessable {
                kept = target
                if face.assignment.person.map(FaceAssignmentResult.Person.existing) != target {
                    plan.guesses.append(Guess(face: face.id, person: target))
                }
            } else {
                kept = face.assignment.person.map(FaceAssignmentResult.Person.existing)
            }
            if case let .existing(person) = kept {
                keeps.insert(person)
            }
        }
        let held = Set(snapshot.faces.compactMap(\.assignment.person))
        plan.emptied = snapshot.people.filter { snapshot.isBare($0) && held.contains($0.id) && !keeps.contains($0.id) }.map(\.id)
        return plan
    }
}

/// A person in the People gallery.
nonisolated struct PersonSummary: Hashable, Sendable, Identifiable {
    let id: PersonID
    let name: String?
    let birthday: PersonBirthday?
    let isHidden: Bool
    let isFavorite: Bool
    /// The photos and videos holding a face of this person; a stack counts once.
    let media: MediaCount
    /// The key photo the user chose, else the newest face.
    let cover: FaceTile?
    /// The faces the user gave this person, newest first: the facts the hard rules hold
    /// them to.
    let userFaces: [FaceTile]
    /// The photos and videos of the faces that define this person (the user's and the
    /// seeds), each with whether it is a video, which two people merged may not share.
    var anchorMedia: [MediaAssetID: Bool] = [:]
    /// Up to `newestFaceCount` of the person's faces, whoever gave them, newest first and one
    /// per photo (a photo's copies and a stack's files are one photo): the row the Person
    /// sheet shows.
    var newestFaces: [FaceTile] = []

    static let newestFaceCount = 8

    /// The capture time of the oldest face the user gave this person; nil when none has a
    /// date. `userFaces` is newest first with the undated last, so it is the last dated one.
    var oldestUserCapture: Double? {
        userFaces.last { $0.captureSeconds != nil }?.captureSeconds
    }

    /// What the person is called where only text fits; a person without a name is
    /// `Unnamed Person`, which no one is called. Where a control fits, a person without a
    /// name shows `Add Name…` instead (`FaceActTitle.addName`).
    var displayName: String {
        Self.displayName(name)
    }

    static func displayName(_ name: String?) -> String {
        name ?? "Unnamed Person"
    }
}

/// Where a face's outline sits on its photo as shown. A face box is a fraction of the upright
/// photo from its top-left corner; the photo is shown through its saved edit's crop and
/// straighten, so the box is carried through them.
nonisolated enum FaceOutline {
    /// Nil when the photo has an edit but its upright size is unknown: the outline is not
    /// drawn rather than drawn in the wrong place.
    static func onEditedPhoto(_ box: CGRect, recipe: EditRecipe?, upright: CGSize?) -> CGRect? {
        guard let recipe else { return box }
        guard let upright, upright.width > 0, upright.height > 0 else { return nil }
        return EditGeometry(recipe: recipe, developedSize: upright).editedRect(ofDevelopedFraction: box)
    }

    /// The outlines, fractions of `frame` from its top-left corner, as one path of rounded
    /// rectangles in a top-left-origin space.
    static func path(_ outlines: [CGRect], in frame: CGRect) -> CGPath {
        let path = CGMutablePath()
        for rect in outlines {
            let box = CGRect(
                x: frame.minX + rect.minX * frame.width, y: frame.minY + rect.minY * frame.height,
                width: rect.width * frame.width, height: rect.height * frame.height
            )
            path.addRoundedRect(in: box, cornerWidth: 4, cornerHeight: 4)
        }
        return path
    }
}

/// The face acts' words, the same on the photo menus, the Info pane and the undo stack
/// (DES-113, `docs/design/people.md`). An act is a verb phrase, and a list of people sits
/// under the words its items complete (HIG Menus: `Sort by ▸ Date`), so `Change to ▸ Sam`
/// reads as the act it is.
nonisolated enum FaceActTitle {
    /// A named person's faces, given to someone else.
    static let changeTo = "Change to"
    /// Unidentified faces, given a person.
    static let assignTo = "Assign to"
    static let someoneElse = "Someone Else…"
    /// An unnamed person, named as a whole.
    static let nameThisPerson = "Name This Person"
    static let newName = "New Name…"
    static let addName = "Add Name…"
    /// An unnamed person's faces, in that person's own photos, are not theirs.
    static let notTheSamePerson = "Not the Same Person"
    static let notAFace = "This Is Not a Face"

    static func notPerson(_ name: String) -> String {
        "This Is Not \(name)"
    }

    static func makeKeyPhoto(_ name: String) -> String {
        "Make Key Photo for \(name)"
    }

    /// The undo stack's name for giving faces a person, or naming one: `Name 3 Photos`,
    /// `Name 4 Photos & Videos`.
    static func name(_ media: MediaCount) -> String {
        "Name \(media.title)"
    }
}

/// What `PeopleAssignment` publishes: the People gallery and the tally of photos and videos
/// not yet checked. What the gallery, the Person sheet and every menu read from the people
/// is derived once, where the state is built (`PeopleStateBuilder`, off the main actor):
/// everyone visible and the hidden people in gallery order, the names the sheet suggests,
/// and each person's place by ID, so no surface walks the people to find one.
nonisolated struct CatalogPeopleState: Equatable, Sendable {
    /// The gallery's order: favourites first, then most photos, then the name in the locale's
    /// order; the hidden people after everyone else, in the same order.
    let people: [PersonSummary]
    /// Everyone not hidden, in gallery order: the people every surface but the gallery offers.
    let visiblePeople: [PersonSummary]
    /// The hidden people, in gallery order: the gallery's `Hidden` section.
    let hiddenPeople: [PersonSummary]
    /// The visible people's names, in gallery order: what the Person sheet suggests.
    let visibleNames: [String]
    /// Each person's index in `people`.
    private let positions: [PersonID: Int]
    /// Each file's own faces of visible people and unidentified faces, in reading order, as
    /// built: what the photo menus and the Info pane show, at once, read through
    /// `faces(of:)` so the acts the window holds (`faceOverrides`) are laid over them.
    private let photoFaces: [MediaAssetID: [PhotoFace]]
    /// Each file that is one of a photo's present identical copies (ADR 0054), mapped to its
    /// other copies in the order copies are shown in: a named face on any of them is the
    /// photo's (`faces(of:)`).
    private let copies: [MediaAssetID: [MediaAssetID]]
    /// What the window's held People acts do to single faces until People is built with them
    /// (`overlaying`): small, so a held act never copies `photoFaces`.
    private let faceOverrides: [FaceID: PhotoFaceOverride]
    /// Read with every pass, and alone when rows were only added (`PeopleAssignment`).
    var unchecked: MediaCount
    /// Faces found that are still faces (not marked `This Is Not a Face`).
    let faceCount: Int
    /// The `PeopleAssignment` request the build covers: a People act the window holds is
    /// shown by every build that covers the request its write asked for (ADR 0032 rule 2).
    var covers: UInt64

    init(
        people: [PersonSummary],
        photoFaces: [MediaAssetID: [PhotoFace]] = [:],
        copies: [MediaAssetID: [MediaAssetID]] = [:],
        unchecked: MediaCount,
        faceCount: Int,
        covers: UInt64 = 0
    ) {
        self.init(
            people: people, photoFaces: photoFaces, copies: copies, faceOverrides: [:],
            unchecked: unchecked, faceCount: faceCount, covers: covers
        )
    }

    private init(
        people: [PersonSummary],
        photoFaces: [MediaAssetID: [PhotoFace]],
        copies: [MediaAssetID: [MediaAssetID]],
        faceOverrides: [FaceID: PhotoFaceOverride],
        unchecked: MediaCount,
        faceCount: Int,
        covers: UInt64
    ) {
        self.people = people
        visiblePeople = people.filter { !$0.isHidden }
        hiddenPeople = people.filter(\.isHidden)
        visibleNames = visiblePeople.compactMap(\.name)
        positions = Dictionary(uniqueKeysWithValues: people.enumerated().map { ($1.id, $0) })
        self.photoFaces = photoFaces
        self.copies = copies
        self.faceOverrides = faceOverrides
        self.unchecked = unchecked
        self.faceCount = faceCount
        self.covers = covers
    }

    /// The derived lists are functions of `people`, so they are not compared again.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.faceCount == rhs.faceCount && lhs.unchecked == rhs.unchecked && lhs.people == rhs.people
            && lhs.covers == rhs.covers && lhs.faceOverrides == rhs.faceOverrides && lhs.photoFaces == rhs.photoFaces
            && lhs.copies == rhs.copies
    }

    static let empty = CatalogPeopleState(people: [], unchecked: MediaCount(), faceCount: 0)

    /// The faces `photo` shows, with what held acts do to them: its own, in reading order,
    /// then — a named face on any copy being the photo's (ADR 0054; owner, 2026-11-15) — the
    /// face of each person a present copy holds and this file does not, from the first copy
    /// in shown order that holds one. A face stays on the copy it was read from: its box is
    /// of that copy's pixels, so it is outlined only where that copy shows, and an act on it
    /// acts on that copy's face. Another copy's unidentified faces are not shown: they are
    /// this file's own detections, read from another preview.
    func faces(of photo: MediaAssetID) -> [PhotoFace] {
        let own = ownFaces(of: photo)
        guard let others = copies[photo] else {
            return own
        }
        var named = Set(own.compactMap(\.person))
        var borrowed: [PhotoFace] = []
        for copy in others {
            for face in ownFaces(of: copy) {
                guard let person = face.person, named.insert(person).inserted else { continue }
                borrowed.append(face)
            }
        }
        return own + borrowed
    }

    /// The faces read from `file` itself, in reading order, with what held acts do to them.
    func ownFaces(of file: MediaAssetID) -> [PhotoFace] {
        let built = photoFaces[file] ?? []
        guard !faceOverrides.isEmpty else {
            return built
        }
        return built.compactMap { face in
            switch faceOverrides[face.id] {
            case nil: face
            case .removed: nil
            case let .person(person): PhotoFace(tile: face.tile, person: person)
            }
        }
    }

    /// The other present copies of `file`, in the order copies are shown in; none for a file
    /// that is no copy of a photo with a face.
    func copies(of file: MediaAssetID) -> [MediaAssetID] {
        copies[file] ?? []
    }

    /// The faces of `photos`, in their order, each once: two copies of one photo among them
    /// show the same named face of the copy that holds it.
    func selectionFaces(for photos: [MediaAssetID]) -> SelectionFaces {
        var seen: Set<FaceID> = []
        return SelectionFaces(photos: photos, faces: photos.flatMap(faces(of:)).filter { seen.insert($0.id).inserted })
    }

    /// This state with `effect` laid over it: the window's People acts the store has answered
    /// or will answer, shown before a build has them (`PendingPeopleActs`). The people it edits
    /// are re-sorted by the builder's own gallery order (`PeopleStateBuilder.galleryOrder`);
    /// a person's photo count, which a face leaving them may change, keeps its build's value
    /// until the next build. Costs the people and the faces it changes, never the photos.
    func overlaying(_ effect: PeopleOverlayEffect) -> CatalogPeopleState {
        guard !effect.isEmpty else {
            return self
        }
        var faceOverrides = faceOverrides
        faceOverrides.merge(effect.faces) { _, new in new }
        var people = people
        if !effect.people.isEmpty {
            people = people.map { summary in effect.people[summary.id].map { summary.editing($0, faces: self) } ?? summary }
                .sorted(by: PeopleStateBuilder.galleryOrder)
        }
        return CatalogPeopleState(
            people: people, photoFaces: photoFaces, copies: copies, faceOverrides: faceOverrides,
            unchecked: unchecked, faceCount: faceCount, covers: covers
        )
    }

    func person(_ id: PersonID) -> PersonSummary? {
        positions[id].map { people[$0] }
    }

    /// The people among `ids`, in gallery order.
    func inGalleryOrder(_ ids: some Sequence<PersonID>) -> [PersonSummary] {
        ids.compactMap { positions[$0] }.sorted().map { people[$0] }
    }

    /// A visible person's name; nil for a hidden or unknown one, which no surface but the
    /// gallery names.
    func visibleName(_ id: PersonID) -> String? {
        person(id).flatMap { $0.isHidden ? nil : $0.displayName }
    }
}

nonisolated extension MediaCount {
    /// The photos and videos `faces` are in, each counted once.
    init(faces: some Sequence<PhotoFace>) {
        self.init(tiles: faces.map(\.tile))
    }

    /// The photos and videos `tiles` are in, each counted once.
    init(tiles: some Sequence<FaceTile>) {
        self.init(items: tiles.map { ($0.id.asset, $0.isInVideo) })
    }
}

/// One face of a photo, as the Info pane and the photo menus show it: a face of a visible
/// person or of no person.
nonisolated struct PhotoFace: Hashable, Sendable, Identifiable {
    let tile: FaceTile
    /// Its person; nil for an unidentified face.
    let person: PersonID?

    var id: FaceID {
        tile.id
    }
}

/// One person a face could be, with how like them it is.
nonisolated struct FaceCandidate: Hashable, Sendable {
    let person: PersonID
    let similarity: Float
}

/// The faces of the selected photos (ADR 0047), with the people each could be once
/// `PeopleAssignment` has ranked them: everyone visible the hard rules allow, most likely
/// first, the face's own person left out.
nonisolated struct SelectionFaces: Equatable, Sendable {
    let photos: [MediaAssetID]
    let faces: [PhotoFace]
    /// Missing for a face not ranked yet (or beyond `PeopleAssignment.rankedFaceLimit`).
    var candidates: [FaceID: [FaceCandidate]] = [:]

    static let empty = SelectionFaces(photos: [], faces: [])

    var unidentified: [PhotoFace] {
        faces.filter { $0.person == nil }
    }

    /// The visible people with a face in the selection, in the order their faces come.
    var people: [PersonID] {
        var seen: Set<PersonID> = []
        return faces.compactMap(\.person).filter { seen.insert($0).inserted }
    }

    /// The faces of `person` in the selection.
    func faces(of person: PersonID?) -> [PhotoFace] {
        faces.filter { $0.person == person }
    }

    /// The people most likely to be `faces`, most likely first: each person scored by their
    /// mean best similarity over the photos holding one of the faces.
    func likelyPeople(for faces: [PhotoFace]) -> [PersonID] {
        let byPhoto = Dictionary(grouping: faces, by: \.id.asset)
        var total: [PersonID: Float] = [:]
        for photoFaces in byPhoto.values {
            var best: [PersonID: Float] = [:]
            for face in photoFaces {
                for candidate in candidates[face.id] ?? [] {
                    best[candidate.person] = max(best[candidate.person] ?? -2, candidate.similarity)
                }
            }
            for (person, value) in best {
                total[person, default: 0] += value
            }
        }
        let count = Float(max(byPhoto.count, 1))
        return total.map { (person: $0.key, score: $0.value / count) }
            .sorted { ($0.score, $1.person) > ($1.score, $0.person) }
            .map(\.person)
    }

    /// Per photo, the unidentified face most like `person`: the face `Assign to ▸` gives them
    /// in each photo that holds one. A photo whose unidentified faces are not ranked gives its
    /// first one.
    func unidentifiedFacesToName(as person: PersonID) -> [FaceID] {
        Dictionary(grouping: unidentified, by: \.id.asset).values.compactMap { faces in
            let ranked = faces.compactMap { face in
                candidates[face.id]?.first { $0.person == person }.map { (face: face.id, similarity: $0.similarity) }
            }
            if let best = ranked.max(by: { ($0.similarity, $1.face.index) < ($1.similarity, $0.face.index) }) {
                return best.face
            }
            return faces.first { candidates[$0.id] == nil }?.id
        }.sorted(by: FaceAssignmentPolicy.pathOrder)
    }
}

/// One act of the user's on faces or people. Each is one store transaction, undone by the
/// `PeopleRestore` the store returns for it.
nonisolated enum PeopleAct: Equatable, Sendable {
    /// The faces become this person's, on the user's word (`Change to ▸`, `Assign to ▸`).
    case move([FaceID], to: PersonID)
    /// The faces become one new person's, with this name and birthday (`Someone Else…`).
    case moveToNewPerson([FaceID], name: String?, birthday: PersonBirthday? = nil)
    /// The faces lose their person and are never given one by Otos again (`This Is Not Sam`,
    /// `Not the Same Person`).
    case removeName([FaceID])
    /// The detections are not faces (This Is Not a Face).
    case notAFace([FaceID])
    /// Rename…, Add Name… and Set Birthday….
    case edit(PersonID, name: String?, birthday: PersonBirthday?)
    /// The first person's faces become the second's; the second keeps its name and birthday.
    case merge(PersonID, into: PersonID)
    case setHidden(PersonID, Bool)
    case setFavorite(PersonID, Bool)
    /// The face is its person's key photo, and theirs on the user's word: choosing a cover is
    /// saying who it shows (ADR 0047).
    case makeKeyPhoto(FaceID, of: PersonID)

    /// The act's name in the log. The undo stack names it in the user's words, decided by
    /// the view model when the act is submitted (`FaceActTitle`).
    var logName: String {
        switch self {
        case .move: "move"
        case .moveToNewPerson: "moveToNewPerson"
        case .removeName: "removeName"
        case .notAFace: "notAFace"
        case .edit: "edit"
        case .merge: "merge"
        case .setHidden: "setHidden"
        case .setFavorite: "setFavorite"
        case .makeKeyPhoto: "makeKeyPhoto"
        }
    }

    var faceCount: Int {
        switch self {
        case let .move(faces, _), let .moveToNewPerson(faces, _, _), let .removeName(faces), let .notAFace(faces):
            faces.count
        case .makeKeyPhoto:
            1
        case .edit, .merge, .setHidden, .setFavorite:
            0
        }
    }
}

/// The state an act changed, as it was before: the people it touched and every face row and
/// rejection it could have changed. Writing it back undoes the act exactly; the guesses that
/// follow from it are rebuilt by assignment.
nonisolated struct PeopleRestore: Equatable, Sendable {
    nonisolated struct FaceRow: Equatable, Sendable {
        let face: FaceID
        let assignment: FaceAssignment
        let isNotFace: Bool
        let isKeyPhoto: Bool
    }

    nonisolated struct Rejection: Hashable, Sendable {
        let face: FaceID
        let person: PersonID
    }

    /// People as they were; nil for a person the act created.
    let people: [PersonID: PeopleSnapshot.Person?]
    let faces: [FaceRow]
    /// Every rejection naming one of `faces` or one of `people`, as it was.
    let rejections: Set<Rejection>
}

/// What `CatalogStore.perform(_:)` did: what undoes it, and the person the faces went to
/// (for New Person, the person the act created; for a merge, the person merged into).
nonisolated struct PeopleActOutcome: Equatable, Sendable {
    let restore: PeopleRestore
    let person: PersonID?
}

/// What the catalog says about one photo's faces (`CatalogStore.facesRead(for:)`): whether
/// they have been read, and how many of the faces stored for it are still faces, of visible
/// and hidden people alike.
nonisolated struct PhotoFacesRead: Equatable, Sendable {
    let photo: MediaAssetID
    let isRead: Bool
    let faceCount: Int

    /// What the Info pane's People section says for `photos` when it lists no face: `Not
    /// Checked Yet` and `No Faces` only for the one photo this read is of, as the catalog
    /// holds them; `—` for several photos, before the read lands, and for a photo with faces
    /// People does not list (not yet published, or a hidden person's), since `No Faces`
    /// there would be a fact no one read.
    static func line(for photos: [MediaAssetID], read: PhotoFacesRead?) -> String {
        guard photos.count == 1, let read, read.photo == photos.first else {
            return PhotoInfo.notApplicable
        }
        if !read.isRead {
            return "Not Checked Yet"
        }
        return read.faceCount == 0 ? "No Faces" : PhotoInfo.notApplicable
    }
}
