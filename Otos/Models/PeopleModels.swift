import CoreGraphics
import Foundation

// People models (ADR 0047, `docs/design/people.md`)
//
// What the store reads for People in one transaction (`PeopleSnapshot`), what assignment
// writes back (`FaceAssignmentPlan`), what `PeopleAssignment` publishes (`CatalogPeopleState`)
// and answers about selected photos (`SelectionFaces`), and the user's acts on faces and
// people (`PeopleAct`) with the record that undoes one (`PeopleRestore`). Values only: the
// store writes, the owner derives, and the views render these.

/// One face as a tile shows it: where it is in its photo and the stored preview it is cut
/// from (ADR 0035).
nonisolated struct FaceTile: Hashable, Sendable, Identifiable {
    let id: FaceID
    /// Fractions of the upright photo, top-left origin.
    let box: CGRect
    /// The stored preview's name in the derived-image directory; nil before one is made.
    let previewName: String?
    /// The photo's local capture time (`CaptureLocalTime.seconds`); nil when the photo has
    /// no date. Its UTC day is the day the photo was taken, the same day a birthday names.
    let captureSeconds: Double?

    var captureLocalTime: CaptureLocalTime? {
        captureSeconds.map(CaptureLocalTime.init(seconds:))
    }
}

/// Everything People reads from the catalog, in one transaction.
nonisolated struct PeopleSnapshot: Sendable, Equatable {
    nonisolated struct Person: Sendable, Equatable {
        let id: PersonID
        let name: String?
        /// `YYYY` or `YYYY-MM-DD`, as the user gave it.
        let birthday: String?
        var isHidden = false
        var isFavorite = false

        var birthdaySeconds: Double? {
            birthday.flatMap(PersonBirthday.seconds)
        }

        var fact: PersonFact {
            PersonFact(id: id, birthdaySeconds: birthdaySeconds)
        }

        /// Nothing the user said about the person: no name, birthday, favourite or hidden. A
        /// person Otos found is forgotten once nothing of theirs is left.
        var isBare: Bool {
            name == nil && birthday == nil && !isHidden && !isFavorite
        }
    }

    /// Every face of a photo still in the catalog and out of the Trash, in reading order.
    let faces: [FaceFact]
    let tiles: [FaceID: FaceTile]
    /// In creation order.
    let people: [Person]
    /// Each face's stored likeness.
    var likeness: [FaceID: Float] = [:]
    /// Each person's key photo, where the user chose one.
    var keyPhotos: [PersonID: FaceID] = [:]
    /// Stills in the available fixed libraries whose faces are not yet read for their current
    /// bytes (for an Immich account, its current preview).
    let uncheckedPhotoCount: Int
    /// The store's People revision the snapshot was read under: it includes every act whose
    /// `PeopleActOutcome.revision` is at most this.
    let revision: UInt64
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

    var isEmpty: Bool {
        guesses.isEmpty && newPeople.isEmpty && likeness.isEmpty && emptied.isEmpty
    }

    /// The changes that take the snapshot to `result`.
    static func changes(from snapshot: PeopleSnapshot, to result: FaceAssignmentResult) -> FaceAssignmentPlan {
        var plan = FaceAssignmentPlan()
        plan.newPeople = result.newPeople
        let seeded = Set(result.newPeople.joined())
        var keeps: Set<PersonID> = []
        for face in snapshot.faces where !face.isNotFace {
            let computed = result.likeness[face.id]
            if snapshot.likeness[face.id] != computed {
                plan.likeness[face.id] = .some(computed)
            }
            guard !seeded.contains(face.id) else { continue }
            let target = result.guesses[face.id]
            let kept: FaceAssignmentResult.Person?
            if face.assignment.isGuessable {
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
        let held = Set(snapshot.faces.filter { !$0.isNotFace }.compactMap(\.assignment.person))
        plan.emptied = snapshot.people.filter { $0.isBare && held.contains($0.id) && !keeps.contains($0.id) }.map(\.id)
        return plan
    }
}

/// A person in the People gallery.
nonisolated struct PersonSummary: Hashable, Sendable, Identifiable {
    let id: PersonID
    let name: String?
    let birthday: String?
    let isHidden: Bool
    let isFavorite: Bool
    /// Photos holding a face of this person.
    let photoCount: Int
    /// The key photo the user chose, else the newest face.
    let cover: FaceTile?
    /// The faces the user gave this person, newest first: the facts the hard rules hold
    /// them to.
    let userFaces: [FaceTile]
    /// The photos of the faces that define this person (the user's and the seeds), which two
    /// people merged may not share.
    var anchorPhotos: Set<MediaAssetID> = []

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
/// (DES-113, `docs/design/people.md`).
nonisolated enum FaceActTitle {
    static let thisIs = "This Is"
    static let newPerson = "New Person…"
    static let addName = "Add Name…"
    static let wrongPerson = "Wrong Person"
    static let notAFace = "This Is Not a Face"
    static let makeKeyPhoto = "Make Key Photo"

    /// `This Is Not Sam`. A person without a name is known only by the other photos Otos
    /// put the face with, so for them the act says the grouping is wrong: `Wrong Person`.
    static func notPerson(_ name: String?) -> String {
        name.map { "This Is Not \($0)" } ?? wrongPerson
    }
}

/// What `PeopleAssignment` publishes: the People gallery and the tally of photos not yet
/// checked.
nonisolated struct CatalogPeopleState: Equatable, Sendable {
    /// The gallery's order: favourites first, then most photos, then the name in the locale's
    /// order; the hidden people after everyone else, in the same order.
    let people: [PersonSummary]
    /// Each photo's faces of visible people and unidentified faces, in reading order: what
    /// the photo menus and the Info pane show, at once.
    var photoFaces: [MediaAssetID: [PhotoFace]] = [:]
    let uncheckedPhotoCount: Int
    /// Faces found that are still faces (not marked `This Is Not a Face`).
    let faceCount: Int
    /// The People revision the state was built from (`PeopleSnapshot.revision`).
    var revision: UInt64 = 0

    static let empty = CatalogPeopleState(people: [], uncheckedPhotoCount: 0, faceCount: 0)

    /// The faces of `photos`, in their order.
    func selectionFaces(for photos: [MediaAssetID]) -> SelectionFaces {
        SelectionFaces(photos: photos, faces: photos.flatMap { photoFaces[$0] ?? [] })
    }

    /// Everyone not hidden, in gallery order: the people every surface but the gallery offers.
    var visiblePeople: [PersonSummary] {
        people.filter { !$0.isHidden }
    }

    var hiddenPeople: [PersonSummary] {
        people.filter(\.isHidden)
    }

    func person(_ id: PersonID) -> PersonSummary? {
        people.first { $0.id == id }
    }

    /// A visible person's name; nil for a hidden or unknown one, which no surface but the
    /// gallery names.
    func visibleName(_ id: PersonID) -> String? {
        person(id).flatMap { $0.isHidden ? nil : $0.displayName }
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

    /// Per photo, the unidentified face most like `person`: the face `This Is ▸` gives them
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
    /// The faces become this person's, on the user's word (This Is ▸).
    case move([FaceID], to: PersonID)
    /// The faces become one new person's, with this name (New Person…).
    case moveToNewPerson([FaceID], name: String?)
    /// The faces lose their person and are never given one by Otos again (Not Sam).
    case removeName([FaceID])
    /// The detections are not faces (This Is Not a Face).
    case notAFace([FaceID])
    /// Rename…, Add Name… and Set Birthday….
    case edit(PersonID, name: String?, birthday: String?)
    /// The first person's faces become the second's; the second keeps its name and birthday.
    case merge(PersonID, into: PersonID)
    case setHidden(PersonID, Bool)
    case setFavorite(PersonID, Bool)
    /// The face is its person's key photo.
    case makeKeyPhoto(FaceID, of: PersonID)

    /// The name the undo stack shows, as `Undo <name>`.
    var undoName: String {
        switch self {
        case .move: FaceActTitle.thisIs
        case .moveToNewPerson: "New Person"
        case .removeName: FaceActTitle.wrongPerson
        case .notAFace: FaceActTitle.notAFace
        case .edit: "Edit Person"
        case .merge: "Merge"
        case let .setHidden(_, hidden): hidden ? "Hide" : "Unhide"
        case let .setFavorite(_, favorite): favorite ? "Add to Favorites" : "Remove from Favorites"
        case .makeKeyPhoto: FaceActTitle.makeKeyPhoto
        }
    }

    var faceCount: Int {
        switch self {
        case let .move(faces, _), let .moveToNewPerson(faces, _), let .removeName(faces), let .notAFace(faces):
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
/// (for New Person, the person the act created).
nonisolated struct PeopleActOutcome: Equatable, Sendable {
    let restore: PeopleRestore
    let person: PersonID?
    /// The People revision this act committed as; a People state whose `revision` is at
    /// least this shows it.
    let revision: UInt64
}
