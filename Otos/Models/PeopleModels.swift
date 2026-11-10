import CoreGraphics
import Foundation

// People models (ADR 0047, `docs/design/people.md`)
//
// What the store reads for People in one transaction (`PeopleSnapshot`), what
// `PeopleProjection` publishes from it (`CatalogPeopleState`), and the user's acts on faces
// and people (`PeopleAct`) with the record that undoes one (`PeopleRestore`). Values only:
// the store writes, the projection derives, and the views render these.

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

        var birthdaySeconds: Double? {
            birthday.flatMap(PersonBirthday.seconds)
        }

        var fact: PersonFact {
            PersonFact(id: id, birthdaySeconds: birthdaySeconds)
        }
    }

    /// Every face of a photo still in the catalog and out of the Trash, in reading order.
    let faces: [FaceFact]
    let tiles: [FaceID: FaceTile]
    /// In creation order.
    let people: [Person]
    /// Stills in the available fixed libraries whose faces are not yet read for their current
    /// bytes (for an Immich account, its current preview).
    let uncheckedPhotoCount: Int
}

/// A person in the People list: their confirmed faces, newest first, the first being the
/// cover (owner decision, 2026-11-09).
nonisolated struct PersonSummary: Hashable, Sendable, Identifiable {
    let id: PersonID
    let name: String?
    let birthday: String?
    /// Photos holding a confirmed face of this person.
    let photoCount: Int
    let faces: [FaceTile]

    var cover: FaceTile? {
        faces.first
    }

    /// What the person is called on every surface; an unnamed person (a split) is `Unnamed`.
    var displayName: String {
        name ?? "Unnamed"
    }
}

/// One row of the review: one person's suggestions in a year, one unnamed group's faces in a
/// year, or the faces of a year that could be either of two people.
nonisolated struct PeopleReviewRow: Hashable, Sendable, Identifiable {
    nonisolated enum Kind: Hashable, Sendable {
        /// Suggested as this person; `referenceYear` is the year of the confirmed face the
        /// row's suggestions rest on.
        case person(PersonID, referenceYear: Int?)
        /// Faces that look alike and match no person. `group` is the group's first face,
        /// which names it across years.
        case unnamed(group: FaceID)
        /// Faces whose best two people are too close to call.
        case unsure(PersonID, PersonID)
    }

    nonisolated enum ID: Hashable, Sendable {
        case person(PersonID)
        case unnamed(FaceID)
        case unsure(PersonID, PersonID)
    }

    let kind: Kind
    /// The confirmed faces shown as evidence: one for a person row, one per candidate for an
    /// unsure row, none for an unnamed group.
    let references: [FaceTile]
    /// Newest first.
    let faces: [FaceTile]

    var id: ID {
        switch kind {
        case let .person(person, _): .person(person)
        case let .unnamed(group): .unnamed(group)
        case let .unsure(first, second): .unsure(first, second)
        }
    }
}

/// The review's rows of one year, newest year first; `year` is nil for photos with no date.
nonisolated struct PeopleReviewYear: Hashable, Sendable, Identifiable {
    let year: Int?
    let rows: [PeopleReviewRow]

    var id: Int {
        year ?? Int.min
    }

    var faceCount: Int {
        rows.reduce(0) { $0 + $1.faces.count }
    }
}

/// What `PeopleProjection` publishes: the People list, the review's two lists, and the tally
/// of photos not yet checked.
nonisolated struct CatalogPeopleState: Equatable, Sendable {
    /// Most photos first, ties by name in the locale's order (owner decision, 2026-11-09).
    let people: [PersonSummary]
    /// One person clearly wins, or the faces form an unnamed group.
    let suggestions: [PeopleReviewYear]
    /// The best two people are too close to call.
    let unsure: [PeopleReviewYear]
    let uncheckedPhotoCount: Int
    /// Faces found that are still faces (not marked `Not a Face`).
    let faceCount: Int

    static let empty = CatalogPeopleState(people: [], suggestions: [], unsure: [], uncheckedPhotoCount: 0, faceCount: 0)

    var suggestionCount: Int {
        suggestions.reduce(0) { $0 + $1.faceCount }
    }

    var unsureCount: Int {
        unsure.reduce(0) { $0 + $1.faceCount }
    }

    func person(_ id: PersonID) -> PersonSummary? {
        people.first { $0.id == id }
    }
}

/// One act of the user's on faces or people. Each is one store transaction, undone by the
/// `PeopleRestore` the store returns for it.
nonisolated enum PeopleAct: Equatable, Sendable {
    /// The faces become this person's (Confirm, This Is ▸).
    case confirm([FaceID], as: PersonID)
    /// The faces are not this person, and never suggested as them again (Not Sam).
    case reject([FaceID], person: PersonID)
    /// The faces are none of these people (Not Sam or Ian, on an unsure row).
    case rejectAll([FaceID], people: [PersonID])
    /// The detections are not faces (Not a Face).
    case notAFace([FaceID])
    /// A stranger's group: never grouped or suggested again (Ignore).
    case ignore([FaceID])
    /// The faces become the person of that name, a new one if nobody has it (Name…).
    case name([FaceID], String)
    /// The faces become one new, unnamed person (This Is ▸ New Person).
    case split([FaceID])
    /// Rename… and Set Birthday….
    case edit(PersonID, name: String?, birthday: String?)
    /// The first person's faces become the second's; the second keeps its name and birthday.
    case merge(PersonID, into: PersonID)
    /// The person is gone; their faces are unnamed and their rejections forgotten.
    case remove(PersonID)

    /// The name the undo stack shows, as `Undo <name>`.
    var undoName: String {
        switch self {
        case .confirm: "Confirm"
        case .reject, .rejectAll: "Not This Person"
        case .notAFace: "Not a Face"
        case .ignore: "Ignore"
        case .name: "Name"
        case .split: "Split"
        case .edit: "Edit Person"
        case .merge: "Merge"
        case .remove: "Remove Person"
        }
    }

    var faceCount: Int {
        switch self {
        case let .confirm(faces, _), let .reject(faces, _), let .rejectAll(faces, _), let .notAFace(faces),
             let .ignore(faces), let .name(faces, _), let .split(faces):
            faces.count
        case .edit, .merge, .remove:
            0
        }
    }
}

/// The state an act changed, as it was before: the people it touched and every face row and
/// rejection it could have changed. Writing it back undoes the act exactly.
nonisolated struct PeopleRestore: Equatable, Sendable {
    nonisolated struct FaceRow: Equatable, Sendable {
        let face: FaceID
        let person: PersonID?
        let isNotFace: Bool
        let isIgnored: Bool
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
/// (for Name… and a split, possibly a person the act created).
nonisolated struct PeopleActOutcome: Equatable, Sendable {
    let restore: PeopleRestore
    let person: PersonID?
}
