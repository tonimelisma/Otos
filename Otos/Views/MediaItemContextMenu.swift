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
            case .separator:
                menu.addItem(.separator())
            }
        }
        return menu
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
