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
    /// In a person's scope (ADR 0047): the selected photos' faces are not this person.
    case notPerson
    /// The selected photos' faces of this person are not faces.
    case notAFace
    /// The selected photos' faces of this person are someone else's.
    case thisIs(PersonID)
    /// They are one new person's.
    case newPerson
}

/// A person's scope's corrections on the selected photos, each acting on the one face of
/// that person in each photo (`docs/design/people.md`).
nonisolated struct PersonCorrectionsMenu: Equatable, Sendable {
    struct Choice: Equatable, Sendable {
        let person: PersonID
        let title: String
    }

    /// The person whose scope it is.
    let name: String
    /// The people the faces may move to.
    let choices: [Choice]
    let enabled: Bool
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
        /// This Is ▸: the people, a separator, New Person.
        case thisIs(choices: [PersonCorrectionsMenu.Choice], enabled: Bool)
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
    /// Present in a person's scope.
    var personCorrections: PersonCorrectionsMenu?

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
        if let people = personCorrections {
            entries += [
                .command(.notPerson, title: "Not \(people.name)", enabled: people.enabled),
                .thisIs(choices: people.choices, enabled: people.enabled),
                .command(.notAFace, title: "Not a Face", enabled: people.enabled),
                .separator,
            ]
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
