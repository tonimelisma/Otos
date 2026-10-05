import AppKit
import Foundation
@testable import OtosKit
import Testing

/// Intent-level coverage for File ▸ Open / Open With (APP-035): targets resolve through
/// the current-item resolver, opening hands URLs to the injected workspace and nothing
/// else, and the menu model is rebuilt newest-wins.
@MainActor
struct CatalogWindowViewModelOpenWithTests {
    @Test func noTargetsLeavesMenuEmptyAndOpensNothing() async throws {
        let workspace = RecordingWorkspace(defaults: ["jpg": .preview], applications: ["jpg": [.preview]])
        let model = makeOpenWithModel(workspace: workspace)
        model.applyState(openWithWindowState(ids: makeIDs(count: 2)))

        model.openTargetsInDefaultApplication()
        try await Task.sleep(for: .milliseconds(30))

        #expect(model.openWithMenu == .empty)
        #expect(await workspace.opens.isEmpty)
    }

    @Test func selectionRebuildsMenuOffMainAndTitlesDefault() async throws {
        let workspace = RecordingWorkspace(defaults: ["jpg": .preview], applications: ["jpg": [.preview, .photos]])
        let model = makeOpenWithModel(workspace: workspace)
        let ids = makeIDs(count: 3)
        model.applyState(openWithWindowState(ids: ids))

        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)
        _ = model.applyGridClick(hit: ids[2], modifiers: [.shift], orderedIDs: ids)
        try await waitUntil { model.openWithMenu.targetCount == 3 }

        #expect(model.openWithMenu.openTitle == "Open in Preview")
        #expect(model.openWithMenu.applications.map(\.displayName) == ["Preview", "Photos"])
        #expect(model.openWithMenu.canOpen)
    }

    @Test func openInDefaultOpensEachGroupOnce() async throws {
        let workspace = RecordingWorkspace(
            defaults: ["jpg": .preview, "mov": .quickTime],
            applications: ["jpg": [.preview], "mov": [.quickTime]]
        )
        let model = makeOpenWithModel(workspace: workspace)
        let jpgs = makeIDs(count: 2)
        let mov = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
            relativePath: MediaRelativePath(rawValue: "clip.mov")
        )
        let ids = [jpgs[0], mov, jpgs[1]]
        model.applyState(openWithWindowState(ids: ids))
        model.selectAll()
        try await waitUntil { model.openWithMenu.targetCount == 3 }
        #expect(model.openWithMenu.openTitle == "Open")

        model.openTargetsInDefaultApplication()
        try await waitUntil { await workspace.opens.count == 2 }

        let opens = await workspace.opens
        #expect(opens[0].application == .preview)
        #expect(opens[0].targets == [jpgs[0].fileURL, jpgs[1].fileURL])
        #expect(opens[1].application == .quickTime)
        #expect(opens[1].targets == [mov.fileURL])
    }

    @Test func openWithSendsWholeSelectionToChosenApp() async throws {
        let workspace = RecordingWorkspace(defaults: ["jpg": .preview], applications: ["jpg": [.preview, .photos]])
        let model = makeOpenWithModel(workspace: workspace)
        let ids = makeIDs(count: 3)
        model.applyState(openWithWindowState(ids: ids))
        model.selectAll()
        try await waitUntil { model.openWithMenu.targetCount == 3 }

        let photos = try #require(model.openWithMenu.applications.last)
        model.openTargets(with: photos)
        try await waitUntil { await workspace.opens.count == 1 }

        let open = try #require(await workspace.opens.first)
        #expect(open.application == .photos)
        #expect(open.targets == ids.map(\.fileURL))
    }

    @Test func loupeTargetsTheFocusedAssetOnly() async throws {
        let workspace = RecordingWorkspace(defaults: ["jpg": .preview], applications: ["jpg": [.preview]])
        let model = makeOpenWithModel(workspace: workspace)
        let ids = makeIDs(count: 3)
        model.applyState(openWithWindowState(ids: ids))
        model.openLoupe(id: ids[1])
        try await waitUntil { model.openWithMenu.targetCount == 1 }

        model.openTargetsInDefaultApplication()
        try await waitUntil { await workspace.opens.count == 1 }

        #expect(await workspace.opens.first?.targets == [ids[1].fileURL])
    }

    @Test func staleMenuBuildIsDiscarded() async throws {
        let workspace = RecordingWorkspace(
            defaults: ["jpg": .preview, "mov": .quickTime],
            applications: ["jpg": [.preview], "mov": [.quickTime]],
            queryDelay: 0.08
        )
        let model = makeOpenWithModel(workspace: workspace)
        let jpg = makeIDs(count: 1)[0]
        let mov = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
            relativePath: MediaRelativePath(rawValue: "clip.mov")
        )
        let ids = [jpg, mov]
        model.applyState(openWithWindowState(ids: ids))

        // First build (JPEG) is slow; before it lands the target moves to the MOV.
        _ = model.applyGridClick(hit: jpg, modifiers: [], orderedIDs: ids)
        try await Task.sleep(for: .milliseconds(10))
        _ = model.applyGridClick(hit: mov, modifiers: [], orderedIDs: ids)
        try await waitUntil {
            model.openWithMenu.targetCount == 1 && model.openWithMenu.defaultApplication != nil
        }
        try await Task.sleep(for: .milliseconds(120))

        #expect(model.openWithMenu.openTitle == "Open in QuickTime Player")
        #expect(model.openWithMenu.defaultsByTarget[mov.fileURL] == .quickTime)
        #expect(model.openWithMenu.defaultsByTarget[jpg.fileURL] == nil)
    }

    @Test func openingRequestsNoMaterializationAndReadsNoBytes() async throws {
        // The workspace is the only collaborator; a target under a path that does not
        // exist opens exactly as a real one would, which is only possible because no
        // byte or stat read happens in Otos.
        let workspace = RecordingWorkspace(defaults: ["jpg": .preview], applications: ["jpg": [.preview]])
        let model = makeOpenWithModel(workspace: workspace)
        let ids = makeIDs(count: 1)
        model.applyState(openWithWindowState(ids: ids))
        model.selectAll()
        try await waitUntil { model.openWithMenu.targetCount == 1 }

        model.openTargetsInDefaultApplication()
        try await waitUntil { await workspace.opens.count == 1 }

        #expect(await workspace.opens.first?.targets == [URL(fileURLWithPath: "/Pictures/asset-0.jpg")])
    }
}

@MainActor
private func makeOpenWithModel(workspace: RecordingWorkspace) -> CatalogWindowViewModel {
    CatalogWindowViewModel(
        catalogStore: CatalogStore(location: .inMemory),
        startsStallMonitor: false,
        startsEnrichment: false,
        startsSourceMonitoring: false,
        preferencesDomain: .suite(UUID().uuidString),
        workspace: workspace
    )
}

private func makeIDs(count: Int) -> [MediaAssetID] {
    (0 ..< count).map { index in
        MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
            relativePath: MediaRelativePath(rawValue: "asset-\(index).jpg")
        )
    }
}

private func openWithWindowState(ids: [MediaAssetID]) -> CatalogWindowState {
    CatalogWindowState(
        title: "Open",
        libraries: [],
        removableSources: [],
        mediaGrid: CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids),
        filterOptions: .empty,
        resolvedSidebarSelection: .allMedia,
        mediaEmptyState: .noMedia,
        deviceConnectionBanner: nil
    )
}

private extension URL {
    static let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
    static let photos = URL(fileURLWithPath: "/System/Applications/Photos.app")
    static let quickTime = URL(fileURLWithPath: "/System/Applications/QuickTime Player.app")
}

/// LaunchServices stand-in that records every open. An actor, so the recording is
/// Sendable without an unchecked escape; the synchronous query methods read only
/// immutable tables.
private actor OpenLog {
    var opens: [(application: URL, targets: [URL])] = []

    func record(application: URL, targets: [URL]) {
        opens.append((application, targets))
    }
}

private struct RecordingWorkspace: WorkspaceOpening {
    let defaults: [String: URL]
    let applications: [String: [URL]]
    let queryDelay: TimeInterval?
    private let log = OpenLog()

    init(defaults: [String: URL], applications: [String: [URL]], queryDelay: TimeInterval? = nil) {
        self.defaults = defaults
        self.applications = applications
        self.queryDelay = queryDelay
    }

    var opens: [(application: URL, targets: [URL])] {
        get async { await log.opens }
    }

    func applicationURLs(toOpen url: URL) -> [URL] {
        if let queryDelay {
            // LaunchServices is synchronous; a slow answer is modelled by blocking the
            // calling (non-main) thread, exactly as a cold LaunchServices query would.
            Thread.sleep(forTimeInterval: queryDelay)
        }
        return applications[url.pathExtension.lowercased()] ?? []
    }

    func defaultApplicationURL(toOpen url: URL) -> URL? {
        defaults[url.pathExtension.lowercased()]
    }

    func displayName(forApplicationAt url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    func open(_ urls: [URL], withApplicationAt applicationURL: URL) async throws {
        await log.record(application: applicationURL, targets: urls)
    }
}
