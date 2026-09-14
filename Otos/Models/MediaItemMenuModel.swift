import Foundation

/// One act a media context menu can perform. The ViewModel maps each case onto the
/// same intent the menu bar calls, so a context-menu act and its File/Photo menu twin
/// are one implementation path with two renderers.
nonisolated enum MediaItemCommand: Equatable, Sendable {
    case open
    case openWith(OpenWithApplication)
    case openWithOther
    case revealInFinder
    case choice(MediaChoice)
    case moveToTrash
}

/// Media context menu model guide
///
/// The ordered contents of the context menu shown on a grid tile, a filmstrip tile,
/// the loupe pane and each compare pane. It is a pure value built by the ViewModel at
/// the moment the menu opens, from the current targets, and rendered by one AppKit
/// builder (`MediaItemContextMenu`). Order mirrors the menu bar and shows no shortcuts
/// (HIG: shortcuts belong in the main menus): Open, Open With ▸, Share…, then Reveal in
/// Finder, then the three curation choices, then Move to Trash. Titles are the same
/// strings the menu bar uses, so the two never drift.
nonisolated struct MediaItemMenuModel: Equatable, Sendable {
    enum Entry: Equatable, Sendable {
        case command(MediaItemCommand, title: String, enabled: Bool)
        case openWith(applications: [OpenWithApplication], enabled: Bool)
        case share(items: [URL])
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
        [
            .command(.open, title: openTitle, enabled: canOpen),
            .openWith(applications: openWithApplications, enabled: canOpenWith),
            .share(items: shareItems),
            .separator,
            .command(.revealInFinder, title: "Reveal in Finder", enabled: canReveal),
            .separator,
            .command(.choice(.liked), title: MediaChoice.liked.actionLabel, enabled: canChoose),
            .command(.choice(.notRated), title: MediaChoice.notRated.actionLabel, enabled: canChoose),
            .command(.choice(.disliked), title: MediaChoice.disliked.actionLabel, enabled: canChoose),
            .separator,
            .command(.moveToTrash, title: "Move to Trash", enabled: canTrash),
        ]
    }
}
