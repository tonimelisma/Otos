import Foundation

/// One act a media context menu can perform. The ViewModel maps each case onto the
/// same intent the menu bar calls, so a context-menu act and its File/Photo menu twin
/// are one implementation path with two renderers.
nonisolated enum MediaItemCommand: Equatable, Sendable {
    case open
    case openWith(OpenWithApplication)
    case openWithOther
    case copy
    case share
    case revealInFinder
    case choice(MediaChoice)
    case moveToTrash
    /// The faces are this person's (This Is ▸ a person; ADR 0047).
    case thisIs([FaceID], PersonID)
    /// The faces are one new person's (This Is ▸ New Person…).
    case newPerson([FaceID])
    /// The person without a name gets one (Add Name…, the Person sheet).
    case addName(PersonID)
    /// The faces are not their person (This Is Not Sam, or Wrong Person).
    case notPerson([FaceID])
    /// The detections are not faces (This Is Not a Face).
    case notAFace([FaceID])
    case makeKeyPhoto(FaceID, PersonID)
}

/// The faces of the targeted photos, grouped by person, as the context menu offers them
/// (`docs/design/people.md`). Each group's acts act on its faces.
nonisolated struct FaceMenu: Equatable, Sendable {
    nonisolated struct Choice: Equatable, Sendable {
        let person: PersonID
        let title: String
        /// The faces This Is gives this person: the group's, or for unidentified faces the
        /// one in each photo most like them.
        let faces: [FaceID]
    }

    nonisolated struct Group: Equatable, Sendable {
        /// The person's name, `Unnamed Person`, or `Unidentified Face(s)`.
        let title: String
        /// Nil for unidentified faces.
        let person: PersonID?
        /// The person's name; nil for a person without one, who is offered Add Name…, and
        /// for unidentified faces.
        let name: String?
        let faces: [FaceID]
        /// Most likely first, then everyone else the hard rules allow.
        let choices: [Choice]
        /// The faces New Person… gives a new person: at most one per photo.
        let newPersonFaces: [FaceID]
        /// Make Key Photo, with one photo targeted.
        let keyPhoto: FaceID?
    }

    let groups: [Group]
    /// The filter shows one person: their group's acts sit at the menu's top level.
    let flattensFirst: Bool
}

/// Media context menu model guide
///
/// The ordered contents of the context menu shown on a grid tile, a filmstrip tile,
/// the loupe pane and each compare pane. It is a pure value built by the ViewModel at
/// the moment the menu opens, from the current targets, and rendered by one AppKit
/// builder (`MediaItemContextMenu`). Order mirrors the menu bar and shows no shortcuts
/// (HIG: shortcuts belong in the main menus): Open, Open With ▸, Copy, Share…, then
/// Reveal in Finder, then the three curation choices, then Move to Trash — Copy before
/// Share as Finder and Photos order them. Titles are the same
/// strings the menu bar uses, so the two never drift.
nonisolated struct MediaItemMenuModel: Equatable, Sendable {
    enum Entry: Equatable, Sendable {
        case command(MediaItemCommand, title: String, enabled: Bool)
        case openWith(applications: [OpenWithApplication], enabled: Bool)
        /// One person's faces, or the unidentified ones: a submenu, or at the top level when
        /// `flat`.
        case faces(FaceMenu.Group, flat: Bool)
        case separator
    }

    var openTitle: String
    var canOpen: Bool
    var openWithApplications: [OpenWithApplication]
    var canOpenWith: Bool
    var shareItems: [URL]
    var canReveal: Bool
    var canChoose: Bool
    var canTrash: Bool
    /// The targets' faces; nil when they hold none People shows.
    var faces: FaceMenu?

    static let empty = MediaItemMenuModel(
        openTitle: "Open",
        canOpen: false,
        openWithApplications: [],
        canOpenWith: false,
        shareItems: [],
        canReveal: false,
        canChoose: false,
        canTrash: false
    )

    init(
        openTitle: String,
        canOpen: Bool,
        openWithApplications: [OpenWithApplication],
        canOpenWith: Bool,
        shareItems: [URL],
        canReveal: Bool,
        canChoose: Bool,
        canTrash: Bool
    ) {
        self.openTitle = openTitle
        self.canOpen = canOpen
        self.openWithApplications = openWithApplications
        self.canOpenWith = canOpenWith
        self.shareItems = shareItems
        self.canReveal = canReveal
        self.canChoose = canChoose
        self.canTrash = canTrash
    }

    init(openWith: OpenWithMenuModel, shareItems: [URL], canReveal: Bool, canTrash: Bool) {
        self.init(
            openTitle: openWith.openTitle,
            canOpen: openWith.canOpen,
            openWithApplications: openWith.applications,
            canOpenWith: openWith.canOpenWith,
            shareItems: shareItems,
            canReveal: canReveal,
            canChoose: !shareItems.isEmpty,
            canTrash: canTrash
        )
    }

    var entries: [Entry] {
        var entries: [Entry] = [
            .command(.open, title: openTitle, enabled: canOpen),
            .openWith(applications: openWithApplications, enabled: canOpenWith),
            .command(.copy, title: "Copy", enabled: !shareItems.isEmpty),
            .command(.share, title: "Share…", enabled: !shareItems.isEmpty),
            .separator,
            .command(.revealInFinder, title: "Reveal in Finder", enabled: canReveal),
            .separator,
        ]
        if let faces, !faces.groups.isEmpty {
            for (index, group) in faces.groups.enumerated() {
                entries.append(.faces(group, flat: faces.flattensFirst && index == 0))
            }
            entries.append(.separator)
        }
        entries += [
            .command(.choice(.liked), title: MediaChoice.liked.actionLabel, enabled: canChoose),
            .command(.choice(.notRated), title: MediaChoice.notRated.actionLabel, enabled: canChoose),
            .command(.choice(.disliked), title: MediaChoice.disliked.actionLabel, enabled: canChoose),
            .separator,
            .command(.moveToTrash, title: "Move to Trash", enabled: canTrash),
        ]
        return entries
    }
}
