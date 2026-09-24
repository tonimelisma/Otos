import AppKit
import Foundation
@testable import OtosKit
import Testing

/// The one `NSMenu` renderer for media context menus (APP-037): every model entry
/// becomes an item with the model's title and enablement, and firing an item routes
/// the command back through the single `perform` closure.
@MainActor
struct MediaItemContextMenuTests {
    @Test func menuRendersEveryEntryWithEnablement() {
        let preview = OpenWithApplication(
            url: URL(fileURLWithPath: "/System/Applications/Preview.app"),
            displayName: "Preview"
        )
        let photos = OpenWithApplication(
            url: URL(fileURLWithPath: "/System/Applications/Photos.app"),
            displayName: "Photos"
        )
        let model = MediaItemMenuModel(
            openTitle: "Open in Preview",
            canOpen: true,
            openWithApplications: [preview, photos],
            canOpenWith: true,
            shareItems: [URL(fileURLWithPath: "/Pictures/a.jpg")],
            canReveal: true,
            canChoose: true,
            canTrash: false
        )

        let menu = MediaItemContextMenu.make(model: model) { _ in }

        let titles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        #expect(titles == [
            "Open in Preview", "Open With", "Copy", "Share…", "—",
            "Reveal in Finder", "—",
            "Like", "Mark as Not Rated", "Dislike", "—",
            "Move to Trash",
        ])
        let keyEquivalents = menu.items.map(\.keyEquivalent)
        #expect(keyEquivalents == Array(repeating: "", count: keyEquivalents.count))
        let trash = menu.items.last
        #expect(trash?.isEnabled == false)
        let openWith = menu.items[1]
        #expect(openWith.submenu?.items.map(\.title) == ["Preview", "Photos", "", "Other…"])
        #expect(menu.items[3].isEnabled)
    }

    @Test func emptyTargetsRenderDisabledItemsIncludingShare() {
        let menu = MediaItemContextMenu.make(model: .empty) { _ in }

        #expect(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { !$0.isEnabled })
        #expect(menu.items[3].title == "Share…")
    }

    @Test func menuItemsRouteToPerform() throws {
        let photos = OpenWithApplication(
            url: URL(fileURLWithPath: "/System/Applications/Photos.app"),
            displayName: "Photos"
        )
        let model = MediaItemMenuModel(
            openTitle: "Open",
            canOpen: true,
            openWithApplications: [photos],
            canOpenWith: true,
            shareItems: [URL(fileURLWithPath: "/Pictures/a.jpg")],
            canReveal: true,
            canChoose: true,
            canTrash: true
        )
        let recorder = CommandRecorder()
        let menu = MediaItemContextMenu.make(model: model) { recorder.commands.append($0) }

        func fire(_ item: NSMenuItem) {
            _ = item.target?.perform(item.action, with: item)
        }
        fire(menu.items[0])
        try fire(#require(menu.items[1].submenu?.items[0]))
        try fire(#require(menu.items[1].submenu?.items[2]))
        fire(menu.items[2])
        fire(menu.items[3])
        fire(menu.items[5])
        fire(menu.items[7])
        fire(menu.items[8])
        fire(menu.items[9])
        fire(menu.items[11])

        #expect(recorder.commands == [
            .open, .openWith(photos), .openWithOther, .copy, .share, .revealInFinder,
            .choice(.liked), .choice(.notRated), .choice(.disliked), .moveToTrash,
        ])
    }

    @Test func hostClaimsOnlyContextClicks() throws {
        let host = ContextMenuHostView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        var opened = 0
        host.willOpen = { opened += 1 }
        host.makeMenu = { NSMenu() }

        // No current event at all: never claim the hit, so SwiftUI keeps the click.
        #expect(host.hitTest(NSPoint(x: 10, y: 10)) == nil)
        // The menu path itself runs willOpen exactly once per open.
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        #expect(host.menu(for: event) != nil)
        #expect(opened == 1)
    }
}

@MainActor
private final class CommandRecorder {
    var commands: [MediaItemCommand] = []
}
