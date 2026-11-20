import Foundation

// File guide: what the window's People acts show before People is built with them (ADR 0047,
// DES-120). `PendingPeopleActs` holds each act's effect; folded in submission order they are
// one `PeopleOverlayEffect`: its people edits are laid over the People state
// (`CatalogPeopleState.overlaying`) and its face changes over the targets' faces
// (`PhotoFaces.overlaying`). Values only.

/// What a held People act does to one face until People is built with it.
nonisolated enum PhotoFaceOverride: Hashable, Sendable {
    /// `This Is Not a Face`: the face leaves every photo menu and the Info pane.
    case removed
    /// The face is this person's, or no one's.
    case person(PersonID?)
}

/// What a held People act does to one person until People is built with it: each field the
/// act sets, nil where it leaves the person's own.
nonisolated struct PersonEdit: Hashable, Sendable {
    /// A name set or cleared (`.some(nil)`), or kept (nil).
    var name: String??
    var birthday: PersonBirthday??
    var isFavorite: Bool?
    var isHidden: Bool?
    /// The key photo chosen: the face whose tile becomes the cover.
    var keyFace: FaceTile?

    /// `later` applied after this edit: each field it sets wins.
    func then(_ later: PersonEdit) -> PersonEdit {
        PersonEdit(
            name: later.name ?? name,
            birthday: later.birthday ?? birthday,
            isFavorite: later.isFavorite ?? isFavorite,
            isHidden: later.isHidden ?? isHidden,
            keyFace: later.keyFace ?? keyFace
        )
    }
}

/// What the window's held People acts show, folded in the order they were made: the people
/// they edit and the faces they change (`CatalogPeopleState.overlaying`).
nonisolated struct PeopleOverlayEffect: Hashable, Sendable {
    var people: [PersonID: PersonEdit] = [:]
    var faces: [FaceID: PhotoFaceOverride] = [:]

    static let none = PeopleOverlayEffect()

    var isEmpty: Bool {
        people.isEmpty && faces.isEmpty
    }

    /// `later` laid after this effect.
    func then(_ later: PeopleOverlayEffect) -> PeopleOverlayEffect {
        var folded = self
        for (person, edit) in later.people {
            folded.people[person] = folded.people[person]?.then(edit) ?? edit
        }
        folded.faces.merge(later.faces) { _, new in new }
        return folded
    }
}

nonisolated extension PersonSummary {
    /// This person with `edit` applied.
    func editing(_ edit: PersonEdit) -> PersonSummary {
        PersonSummary(
            id: id,
            name: edit.name ?? name,
            birthday: edit.birthday ?? birthday,
            isHidden: edit.isHidden ?? isHidden,
            isFavorite: edit.isFavorite ?? isFavorite,
            media: media,
            cover: edit.keyFace ?? cover,
            userFaces: userFaces
        )
    }
}
