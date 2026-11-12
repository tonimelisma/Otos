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
@MainActor
enum MediaItemContextMenu {
    static func make(
        model: MediaItemMenuModel,
        icons: [URL: NSImage] = [:],
        perform: @escaping @MainActor (MediaItemCommand) -> Void
    ) -> NSMenu {
        let menu = NSMenu()
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
                    addName(group, to: menu, perform: perform)
                    let thisIs = NSMenuItem(title: FaceActTitle.thisIs, action: nil, keyEquivalent: "")
                    let submenu = NSMenu(title: FaceActTitle.thisIs)
                    submenu.autoenablesItems = false
                    addChoices(group, to: submenu, perform: perform)
                    thisIs.submenu = submenu
                    menu.addItem(thisIs)
                    addCorrections(group, to: menu, perform: perform)
                } else {
                    // One level of submenu (HIG): the group's This Is choices sit under a
                    // section header inside it rather than in a submenu of their own.
                    let item = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
                    let submenu = NSMenu(title: group.title)
                    submenu.autoenablesItems = false
                    if addName(group, to: submenu, perform: perform) {
                        submenu.addItem(.separator())
                    }
                    submenu.addItem(NSMenuItem.sectionHeader(title: FaceActTitle.thisIs))
                    addChoices(group, to: submenu, perform: perform)
                    submenu.addItem(.separator())
                    addCorrections(group, to: submenu, perform: perform)
                    item.submenu = submenu
                    menu.addItem(item)
                }
            case .separator:
                menu.addItem(.separator())
            }
        }
        return menu
    }

    /// Add Name… first for a person without a name: naming them is what the user most
    /// likely came for. Returns whether it was added.
    @discardableResult
    private static func addName(_ group: FaceMenu.Group, to menu: NSMenu, perform: @escaping @MainActor (MediaItemCommand) -> Void) -> Bool {
        guard let person = group.person, group.name == nil else { return false }
        menu.addItem(ClosureMenuItem(title: FaceActTitle.addName) { perform(.addName(person)) })
        return true
    }

    /// The people the group's faces may be, most likely first, then New Person….
    private static func addChoices(_ group: FaceMenu.Group, to menu: NSMenu, perform: @escaping @MainActor (MediaItemCommand) -> Void) {
        for choice in group.choices {
            menu.addItem(ClosureMenuItem(title: choice.title) { perform(.thisIs(choice.faces, choice.person)) })
        }
        if !group.choices.isEmpty {
            menu.addItem(.separator())
        }
        let faces = group.newPersonFaces
        menu.addItem(ClosureMenuItem(title: FaceActTitle.newPerson) { perform(.newPerson(faces)) })
    }

    /// This Is Not Sam (Wrong Person for a person without a name), This Is Not a Face,
    /// and Make Key Photo with one photo targeted.
    private static func addCorrections(_ group: FaceMenu.Group, to menu: NSMenu, perform: @escaping @MainActor (MediaItemCommand) -> Void) {
        let faces = group.faces
        if group.person != nil {
            menu.addItem(ClosureMenuItem(title: FaceActTitle.notPerson(group.name)) { perform(.notPerson(faces)) })
        }
        menu.addItem(ClosureMenuItem(title: FaceActTitle.notAFace) { perform(.notAFace(faces)) })
        if let face = group.keyPhoto, let person = group.person {
            menu.addItem(ClosureMenuItem(title: FaceActTitle.makeKeyPhoto) { perform(.makeKeyPhoto(face, person)) })
        }
    }

    private static func menuSized(_ image: NSImage) -> NSImage {
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: 16, height: 16)
        return copy
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
