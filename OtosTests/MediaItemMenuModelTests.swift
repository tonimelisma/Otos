import Foundation
@testable import OtosKit
import Testing

/// The context menu's ordered contents (APP-037) as a pure value: same titles as the
/// menu bar, same order on every surface, enablement per act.
struct MediaItemMenuModelTests {
    @Test func entriesMirrorTheMenuBarInOrder() {
        let preview = OpenWithApplication(
            url: URL(fileURLWithPath: "/System/Applications/Preview.app"),
            displayName: "Preview"
        )
        let openWith = OpenWithMenuModel(
            defaultApplication: preview,
            applications: [preview],
            defaultsByTarget: [URL(fileURLWithPath: "/Pictures/a.jpg"): preview.url],
            targetCount: 1,
            targetsWithoutDefault: 0
        )
        let items = [URL(fileURLWithPath: "/Pictures/a.jpg")]

        let model = MediaItemMenuModel(openWith: openWith, shareItems: items, canReveal: true, canTrash: true)

        #expect(model.entries == [
            .command(.open, title: "Open in Preview", enabled: true),
            .openWith(applications: [preview], enabled: true),
            .command(.copy, title: "Copy", enabled: true),
            .command(.share, title: "Share…", enabled: true),
            .separator,
            .command(.revealInFinder, title: "Reveal in Finder", enabled: true),
            .separator,
            .command(.choice(.liked), title: "Like", enabled: true),
            .command(.choice(.notRated), title: "Mark as Not Rated", enabled: true),
            .command(.choice(.disliked), title: "Dislike", enabled: true),
            .separator,
            .command(.moveToTrash, title: "Move to Trash", enabled: true),
        ])
    }

    /// The targets' faces sit after Reveal in Finder, one entry per person; a lone entry sits
    /// at the top level (DES-113).
    @Test func facesComeAfterRevealOnePerPerson() throws {
        let face = FaceID(asset: MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/P"), relativePath: MediaRelativePath(rawValue: "a.jpg")), index: 0)
        let sam = FaceMenu.Group(
            kind: .named("Sam"), person: PersonID(rawValue: 1), faces: [face], tile: nil, media: nil,
            listTitle: FaceActTitle.changeTo, list: [], corrections: []
        )
        let unidentified = FaceMenu.Group(
            kind: .unidentified, person: nil, faces: [face], tile: nil, media: nil,
            listTitle: FaceActTitle.assignTo, list: [], corrections: []
        )
        var model = MediaItemMenuModel(
            openWith: OpenWithMenuModel.make(targets: [], workspace: NoWorkspace()),
            shareItems: [URL(fileURLWithPath: "/P/a.jpg")],
            canReveal: true,
            canTrash: true
        )
        model.faces = FaceMenu(groups: [sam, unidentified])

        let entries = model.entries
        let reveal = try #require(entries.firstIndex(of: .command(.revealInFinder, title: "Reveal in Finder", enabled: true)))
        #expect(Array(entries[(reveal + 2) ..< (reveal + 5)]) == [
            .faces(sam, flat: false), .faces(unidentified, flat: false), .separator,
        ])

        model.faces = FaceMenu(groups: [sam])
        #expect(Array(model.entries[(reveal + 2) ..< (reveal + 4)]) == [.faces(sam, flat: true), .separator])
    }
}

private struct NoWorkspace: WorkspaceOpening {
    func applicationURLs(toOpen _: URL) -> [URL] {
        []
    }

    func defaultApplicationURL(toOpen _: URL) -> URL? {
        nil
    }

    func displayName(forApplicationAt url: URL) -> String {
        url.lastPathComponent
    }

    func open(_: [URL], withApplicationAt _: URL) async throws {}

    func revealInFinder(_: [URL]) {}
}
