import AppKit
import SwiftUI

/// Media context menu renderer guide
///
/// The one place a `MediaItemMenuModel` becomes an `NSMenu`. Grid and filmstrip tiles
/// reach it through `MediaGridCollectionView.menu(for:)`; the loupe and compare panes
/// reach it through `ContextMenuHost`, a transparent AppKit overlay that answers only
/// context clicks. One renderer for four surfaces means one title list, one order,
/// and one enablement rule.
///
/// Every item, Share… included, routes to the ViewModel's `performMediaItemCommand(_:)`
/// through a closure — the renderer knows no intent by name. Share is not AppKit's
/// `standardShareMenuItem` because that anchors its popover to the whole view the menu
/// was shown on; the ViewModel presents it from the toolbar Share button instead.
///
/// Each face item carries the faces it acts on as its `representedObject`; while it is
/// highlighted, `outline` receives them, so the photo shows which face an entry means —
/// two people without a name read alike otherwise (DES-113).
@MainActor
enum MediaItemContextMenu {
    static func make(
        model: MediaItemMenuModel,
        icons: [URL: NSImage] = [:],
        perform: @escaping @MainActor (MediaItemCommand) -> Void,
        outline: @escaping @MainActor ([FaceID]) -> Void = { _ in }
    ) -> NSMenu {
        let outliner = FaceOutliner(outline: outline)
        let menu = FaceOutliningMenu(outliner: outliner)
        menu.delegate = outliner
        menu.autoenablesItems = false
        for entry in model.entries {
            switch entry {
            case let .command(command, title, enabled):
                let item = ClosureMenuItem(title: title) { perform(command) }
                item.isEnabled = enabled
                menu.addItem(item)
            case let .openWith(applications, enabled):
                let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: "Open With")
                submenu.autoenablesItems = false
                for application in applications {
                    let appItem = ClosureMenuItem(title: application.displayName) { perform(.openWith(application)) }
                    appItem.image = icons[application.url].map(menuSized)
                    submenu.addItem(appItem)
                }
                if !applications.isEmpty {
                    submenu.addItem(.separator())
                }
                submenu.addItem(ClosureMenuItem(title: "Other…") { perform(.openWithOther) })
                item.submenu = submenu
                item.isEnabled = enabled
                menu.addItem(item)
            case let .faces(group, flat):
                if flat {
                    // In a person's photos: the list as a submenu, the corrections beside it.
                    let first = menu.numberOfItems
                    let list = NSMenuItem(title: group.listTitle, action: nil, keyEquivalent: "")
                    let submenu = outliner.submenu(title: group.listTitle)
                    submenu.autoenablesItems = false
                    add(group.list, to: submenu, perform: perform)
                    list.submenu = submenu
                    menu.addItem(list)
                    add(group.corrections, to: menu, perform: perform)
                    carry(group.faces, to: menu.items[first...])
                } else {
                    // One level of submenu (HIG): the list sits under a section header inside
                    // the group's submenu rather than in a submenu of its own.
                    let item = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
                    item.representedObject = group.faces
                    let submenu = outliner.submenu(title: group.title)
                    submenu.autoenablesItems = false
                    submenu.addItem(NSMenuItem.sectionHeader(title: group.listTitle))
                    add(group.list, to: submenu, perform: perform)
                    submenu.addItem(.separator())
                    add(group.corrections, to: submenu, perform: perform)
                    carry(group.faces, to: submenu.items[...])
                    item.submenu = submenu
                    menu.addItem(item)
                }
            case .separator:
                menu.addItem(.separator())
            }
        }
        return menu
    }

    /// The group's acts as they are worded; each carries the faces it outlines.
    private static func add(_ actions: [FaceMenu.Action], to menu: NSMenu, perform: @escaping @MainActor (MediaItemCommand) -> Void) {
        for action in actions {
            let command = action.command
            let item = ClosureMenuItem(title: action.title) { perform(command) }
            item.representedObject = action.faces
            menu.addItem(item)
        }
    }

    /// The group's faces on each of its items that carries none of its own, separators
    /// and headers included, so moving through the group keeps its faces outlined.
    private static func carry(_ faces: [FaceID], to items: ArraySlice<NSMenuItem>) {
        for item in items where item.representedObject == nil {
            item.representedObject = faces
        }
    }

    private static func menuSized(_ image: NSImage) -> NSImage {
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

/// Outlines the faces of a context menu's highlighted item (`representedObject`) on their
/// photos. It is the delegate of the menu and of its face submenus; inside a submenu with
/// nothing highlighted, the faces of the item that opened it stay outlined. Closing the
/// menu clears the outline.
final class FaceOutliner: NSObject, NSMenuDelegate {
    private let outline: @MainActor ([FaceID]) -> Void

    init(outline: @escaping @MainActor ([FaceID]) -> Void) {
        self.outline = outline
    }

    /// A submenu whose highlight this outliner reports.
    func submenu(title: String) -> NSMenu {
        let submenu = NSMenu(title: title)
        submenu.delegate = self
        return submenu
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        let faces = item?.representedObject ?? menu.supermenu?.highlightedItem?.representedObject
        outline(faces as? [FaceID] ?? [])
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu.supermenu == nil {
            outline([])
        }
    }
}

/// The context menu, which keeps its `FaceOutliner` alive: `NSMenu.delegate` is weak.
/// `NSMenu` is nonisolated in AppKit, so the class is too; the outliner is main-actor
/// isolated and so Sendable.
final nonisolated class FaceOutliningMenu: NSMenu {
    let outliner: FaceOutliner

    init(outliner: FaceOutliner) {
        self.outliner = outliner
        super.init(title: "")
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("FaceOutliningMenu is never decoded")
    }
}

/// A menu item whose action is a closure, so the renderer needs no `@objc` target of
/// its own per command. `NSMenuItem` is nonisolated in AppKit, so the class is too;
/// the handler is a MainActor closure, which is Sendable by construction, and `fire`
/// assumes the main actor AppKit dispatches every menu action on.
final nonisolated class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("ClosureMenuItem is never decoded")
    }

    @objc private func fire() {
        let handler = handler
        MainActor.assumeIsolated {
            handler()
        }
    }
}

/// Transparent AppKit overlay that gives a SwiftUI pane a context menu built by the
/// same renderer the grid uses. It claims a hit only for a context click (right mouse,
/// or control-left), so hover, drag, single and double clicks reach the SwiftUI views
/// beneath it untouched. `willOpen` runs before the menu is built so a compare pane
/// can become the active pane first and the menu describes the item under the cursor.
struct ContextMenuHost: NSViewRepresentable {
    var willOpen: () -> Void = {}
    var makeMenu: () -> NSMenu?

    func makeNSView(context _: Context) -> ContextMenuHostView {
        ContextMenuHostView()
    }

    func updateNSView(_ view: ContextMenuHostView, context _: Context) {
        view.willOpen = willOpen
        view.makeMenu = makeMenu
    }
}

final class ContextMenuHostView: NSView {
    var willOpen: () -> Void = {}
    var makeMenu: () -> NSMenu? = { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `NSApp` is nil in the unhosted test bundle (ADR 0023); no app means no event
        // and therefore no claim.
        guard let event = NSApp?.currentEvent else { return nil }
        let isContextClick = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        guard isContextClick else { return nil }
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func menu(for _: NSEvent) -> NSMenu? {
        willOpen()
        return makeMenu()
    }
}
