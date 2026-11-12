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

extension MediaItemContextMenuTests {
    /// DES-113: an unnamed person's entry counts every photo of them and opens with `Name
    /// This Person` over the people to merge them into and `New Name…`; highlighting a face
    /// item outlines the faces it acts on, so two people the menu names alike are told
    /// apart. Closing the menu clears the outline.
    @Test func highlightingAFaceItemOutlinesItsFaces() throws {
        let asset = MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/P"), relativePath: MediaRelativePath(rawValue: "a.jpg"))
        let first = FaceID(asset: asset, index: 0)
        let second = FaceID(asset: asset, index: 1)
        let unnamed = Self.unnamedGroup(PersonID(rawValue: 1), face: first, photos: 14)
        let other = Self.unnamedGroup(PersonID(rawValue: 3), face: second, photos: 3)
        var model = MediaItemMenuModel(
            openTitle: "Open", canOpen: true, openWithApplications: [], canOpenWith: false,
            shareItems: [URL(fileURLWithPath: "/P/a.jpg")], canReveal: true, canChoose: true, canTrash: true
        )
        model.faces = FaceMenu(groups: [unnamed, other])
        let recorder = OutlineRecorder()
        let menu = MediaItemContextMenu.make(model: model, perform: { _ in }, outline: { recorder.outlines.append($0) })
        let delegate = try #require(menu.delegate)

        let groups = menu.items.filter { $0.title.hasPrefix("Unnamed Person · ") }
        #expect(groups.map(\.title) == ["Unnamed Person · 14 Photos", "Unnamed Person · 3 Photos"])
        let submenu = try #require(groups[0].submenu)
        #expect(submenu.items.map(\.title) == ["Name This Person", "Sam", "New Name…", "", "This Is Not a Face"])
        #expect(submenu.items.first?.isSectionHeader == true)

        delegate.menu?(menu, willHighlight: groups[0])
        delegate.menu?(menu, willHighlight: groups[1])
        let sam = try #require(submenu.items.first { $0.title == "Sam" })
        submenu.delegate?.menu?(submenu, willHighlight: sam)
        delegate.menu?(menu, willHighlight: menu.items.first { $0.title == "Copy" })
        delegate.menu?(menu, willHighlight: groups[0])
        delegate.menuDidClose?(menu)
        #expect(recorder.outlines == [[first], [second], [first], [], [first], []])
    }

    /// The only face's acts sit at the top level under a heading naming whose they are, the
    /// list a submenu named by the words it completes; each item performs its own command.
    @Test func aFlattenedGroupKeepsItsListInOneSubmenu() throws {
        let asset = MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/P"), relativePath: MediaRelativePath(rawValue: "a.jpg"))
        let face = FaceID(asset: asset, index: 0)
        let sam = PersonID(rawValue: 1)
        let ian = PersonID(rawValue: 2)
        let group = FaceMenu.Group(
            kind: .named("Sam"), person: sam, faces: [face], tile: nil, photoCount: nil,
            listTitle: FaceActTitle.changeTo,
            list: [
                .init(title: "Ian", command: .giveTo([face], ian), faces: [face]),
                .init(title: FaceActTitle.someoneElse, command: .someoneElse([face]), faces: [face]),
            ],
            corrections: [
                .init(title: "This Is Not Sam", command: .notPerson([face]), faces: [face]),
                .init(title: FaceActTitle.notAFace, command: .notAFace([face]), faces: [face]),
                .init(title: "Make Key Photo for Sam", command: .makeKeyPhoto(face, sam), faces: [face]),
            ]
        )
        var model = MediaItemMenuModel(
            openTitle: "Open", canOpen: true, openWithApplications: [], canOpenWith: false,
            shareItems: [URL(fileURLWithPath: "/P/a.jpg")], canReveal: true, canChoose: true, canTrash: true
        )
        model.faces = FaceMenu(groups: [group])
        let recorder = CommandRecorder()
        let menu = MediaItemContextMenu.make(model: model, perform: { recorder.commands.append($0) })

        let heading = try #require(menu.items.first { $0.isSectionHeader })
        #expect(heading.title == "Sam")
        let headingIndex = menu.index(of: heading)
        #expect(menu.items[headingIndex + 1].title == "Change to")
        let changeTo = try #require(menu.items.first { $0.title == "Change to" })
        #expect(changeTo.submenu?.items.map(\.title) == ["Ian", "Someone Else…"])
        #expect(menu.items.contains { $0.title == "This Is Not Sam" })
        #expect(menu.items.contains { $0.title == "Make Key Photo for Sam" })
        let ianItem = try #require(changeTo.submenu?.items.first)
        _ = ianItem.target?.perform(ianItem.action, with: ianItem)
        #expect(recorder.commands == [.giveTo([face], ian)])
    }

    static func unnamedGroup(_ person: PersonID, face: FaceID, photos: Int) -> FaceMenu.Group {
        FaceMenu.Group(
            kind: .unnamed, person: person, faces: [face], tile: nil, photoCount: photos,
            listTitle: FaceActTitle.nameThisPerson,
            list: [
                .init(title: "Sam", command: .nameAs(person, PersonID(rawValue: 2)), faces: [face]),
                .init(title: FaceActTitle.newName, command: .addName(person), faces: [face]),
            ],
            corrections: [.init(title: FaceActTitle.notAFace, command: .notAFace([face]), faces: [face])]
        )
    }
}

@MainActor
private final class OutlineRecorder {
    var outlines: [[FaceID]] = []
}

@MainActor
private final class CommandRecorder {
    var commands: [MediaItemCommand] = []
}
