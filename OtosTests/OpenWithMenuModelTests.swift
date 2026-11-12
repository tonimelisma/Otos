import Foundation
@testable import OtosKit
import Testing

/// Pure-model coverage for the File ▸ Open / Open With menu (APP-035). The workspace
/// is a table-driven stand-in for LaunchServices so the tests assert the model's
/// grouping, title, and intersection rules rather than what this Mac has installed.
struct OpenWithMenuModelTests {
    /// ADR 0046 §4: an account's original not yet staged has no file, and LaunchServices
    /// answers nothing for a path with no file; the workspace asks by its type, so Open and
    /// Open With offer the apps they will use once the hand-off fetches it.
    @Test func aFileNotOnDiskYetIsAskedAboutByItsType() {
        let absent = URL(fileURLWithPath: "/private/var/empty/otos-absent/a1/IMG_1.JPG")
        let workspace = LaunchServicesWorkspace()
        #expect(workspace.defaultApplicationURL(toOpen: absent) != nil)
        #expect(!workspace.applicationURLs(toOpen: absent).isEmpty)
    }

    @Test func sharedDefaultTitlesOpenInThatApp() {
        let workspace = TableWorkspace(
            defaults: ["jpg": .preview, "jpeg": .preview],
            applications: ["jpg": [.preview, .pixelmator], "jpeg": [.preview, .pixelmator]]
        )
        let targets = [url("a.jpg"), url("b.JPEG"), url("c.jpg")]

        let model = OpenWithMenuModel.make(targets: targets, workspace: workspace)

        #expect(model.openTitle == "Open in Preview")
        #expect(model.defaultApplication?.url == .preview)
        #expect(model.canOpen)
        #expect(model.targetCount == 3)
        #expect(model.targetsWithoutDefault == 0)
        let groups = model.targetsByDefaultApplication(order: targets)
        #expect(groups.count == 1)
        #expect(groups.first?.application == .preview)
        #expect(groups.first?.targets == targets)
    }

    @Test func mixedDefaultsTitlePlainOpenAndGroupByApp() {
        let workspace = TableWorkspace(
            defaults: ["jpg": .preview, "mov": .quickTime],
            applications: ["jpg": [.preview, .pixelmator], "mov": [.quickTime, .preview]]
        )
        let targets = [url("a.jpg"), url("b.mov"), url("c.jpg")]

        let model = OpenWithMenuModel.make(targets: targets, workspace: workspace)

        #expect(model.openTitle == "Open")
        #expect(model.defaultApplication == nil)
        #expect(model.canOpen)
        let groups = model.targetsByDefaultApplication(order: targets)
        #expect(groups.map(\.application) == [.preview, .quickTime])
        #expect(groups[0].targets == [url("a.jpg"), url("c.jpg")])
        #expect(groups[1].targets == [url("b.mov")])
    }

    @Test func applicationsAreTheIntersectionInBestFirstOrder() {
        let workspace = TableWorkspace(
            defaults: ["jpg": .preview, "mov": .quickTime],
            applications: ["jpg": [.preview, .pixelmator, .photos], "mov": [.quickTime, .photos, .preview]]
        )

        let model = OpenWithMenuModel.make(targets: [url("a.jpg"), url("b.mov")], workspace: workspace)

        // Order follows the first group's best-first list; QuickTime cannot open a JPEG
        // and Pixelmator cannot open a MOV, so neither is offered.
        #expect(model.applications.map(\.url) == [.preview, .photos])
        #expect(model.applications.map(\.displayName) == ["Preview", "Photos"])
    }

    @Test func targetWithoutDefaultIsCountedNotOpened() {
        let workspace = TableWorkspace(
            defaults: ["jpg": .preview],
            applications: ["jpg": [.preview], "xyz": []]
        )
        let targets = [url("a.jpg"), url("weird.xyz")]

        let model = OpenWithMenuModel.make(targets: targets, workspace: workspace)

        #expect(model.openTitle == "Open")
        #expect(model.targetsWithoutDefault == 1)
        #expect(model.canOpen)
        #expect(model.targetsByDefaultApplication(order: targets).flatMap(\.targets) == [url("a.jpg")])
        #expect(model.applications.isEmpty)
    }
}

private func url(_ name: String) -> URL {
    URL(fileURLWithPath: "/Pictures/\(name)")
}

private extension URL {
    static let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
    static let photos = URL(fileURLWithPath: "/System/Applications/Photos.app")
    static let quickTime = URL(fileURLWithPath: "/System/Applications/QuickTime Player.app")
    static let pixelmator = URL(fileURLWithPath: "/Applications/Pixelmator Pro.app")
}

/// A LaunchServices stand-in keyed by lowercased file extension.
private struct TableWorkspace: WorkspaceOpening {
    let defaults: [String: URL]
    let applications: [String: [URL]]

    init(defaults: [String: URL] = [:], applications: [String: [URL]] = [:]) {
        self.defaults = defaults
        self.applications = applications
    }

    func applicationURLs(toOpen url: URL) -> [URL] {
        applications[url.pathExtension.lowercased()] ?? []
    }

    func defaultApplicationURL(toOpen url: URL) -> URL? {
        defaults[url.pathExtension.lowercased()]
    }

    func displayName(forApplicationAt url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    func open(_: [URL], withApplicationAt _: URL) async throws {}

    func revealInFinder(_: [URL]) {}
}
