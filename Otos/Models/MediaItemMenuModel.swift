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
    /// The faces are this person's, on the user's word (`Change to ▸` or `Assign to ▸` a
    /// person; ADR 0047).
    case giveTo([FaceID], PersonID)
    /// The Person sheet for the faces: a name gives them to the person who has it, or to a
    /// new person (`Someone Else…`).
    case someoneElse([FaceID])
    /// The unnamed person is the named one, every photo of them: a merge, asked first
    /// (`Name This Person ▸` a person).
    case nameAs(PersonID, PersonID)
    /// The Person sheet names the person (`New Name…`, `Add Name…`).
    case addName(PersonID)
    /// The faces are not their person (`This Is Not Sam`, `Not the Same Person`).
    case notPerson([FaceID])
    /// The detections are not faces (`This Is Not a Face`).
    case notAFace([FaceID])
    case makeKeyPhoto(FaceID, PersonID)
}

/// The faces of the targeted photos, as the photo menus and the Info pane offer them
/// (DES-113, `docs/design/people.md`): one group per visible person, and the unidentified
/// faces, each with the acts it offers already worded. The view model builds it once; the
/// AppKit menu and the Info pane's SwiftUI menu render the same items, so their words and
/// order cannot drift.
nonisolated struct FaceMenu: Equatable, Sendable {
    /// One menu item: its words, what it does, and the faces it outlines while highlighted.
    nonisolated struct Action: Equatable, Sendable {
        let title: String
        let command: MediaItemCommand
        let faces: [FaceID]
    }

    nonisolated enum Kind: Equatable, Sendable {
        case named(String)
        case unnamed
        case unidentified
    }

    nonisolated struct Group: Equatable, Sendable {
        let kind: Kind
        /// Nil for unidentified faces.
        let person: PersonID?
        let faces: [FaceID]
        /// The first face's tile, which the Info pane's row shows.
        let tile: FaceTile?
        /// The photos and videos the group's acts change, where that is worth saying: every one
        /// of an unnamed person, and the targeted ones holding the faces when there are several.
        let media: MediaCount?
        /// `Change to`, `Assign to` or `Name This Person`: the words the list completes.
        let listTitle: String
        /// The five people the faces most likely are, then `Someone Else…` or `New Name…`.
        let list: [Action]
        /// `This Is Not Sam` or `Not the Same Person`, `This Is Not a Face`, `Make Key
        /// Photo for Sam`.
        let corrections: [Action]

        /// The group's entry: `Sam`, `Sam · 3 Photos`, `Unnamed Person · 14 Photos & Videos`,
        /// `Unidentified Face`, `Unidentified Faces · 3 Photos`.
        var title: String {
            let base = switch kind {
            case let .named(name): name
            case .unnamed: PersonSummary.displayName(nil)
            case .unidentified: faces.count == 1 ? "Unidentified Face" : "Unidentified Faces"
            }
            return media.map { "\(base) · \($0.title)" } ?? base
        }
    }

    let groups: [Group]

    /// One group: its acts sit at the menu's top level under a heading with its title, since
    /// no other face's acts can be mistaken for them. With several, each is a submenu.
    var isFlat: Bool {
        groups.count == 1
    }
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
        /// One person's faces, or the unidentified ones: a submenu, or at the top level under a
        /// heading when `flat`.
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
            for group in faces.groups {
                entries.append(.faces(group, flat: faces.isFlat))
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
