import AppKit
import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// Intent-level coverage for File ▸ Open / Open With (APP-035): targets resolve through
/// the current-item resolver, opening hands URLs to the injected workspace and nothing
/// else, and the menu model is rebuilt newest-wins.
@Suite(.testScope)
@MainActor
struct CatalogWindowViewModelOpenWithTests {
    @Test func openInDefaultOpensEachGroupOnce() async throws {
        let workspace = RecordingWorkspace(
            defaults: ["jpg": .preview, "mov": .quickTime],
            applications: ["jpg": [.preview], "mov": [.quickTime]]
        )
        let model = makeOpenWithModel(workspace: workspace)
        let jpgs = try makeIDs(count: 2)
        let mov = try makeLocalMediaIDs(["clip.mov"])[0]
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
        let ids = try makeIDs(count: 3)
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
        let ids = try makeIDs(count: 3)
        model.applyState(openWithWindowState(ids: ids))
        model.openLoupe(id: ids[1])
        try await waitUntil { model.openWithMenu.targetCount == 1 }

        model.openTargetsInDefaultApplication()
        try await waitUntil { await workspace.opens.count == 1 }

        #expect(await workspace.opens.first?.targets == [ids[1].fileURL])
    }

    @Test func staleMenuBuildIsDiscarded() async throws {
        // The JPEG build is held inside its LaunchServices query until the target has
        // moved to the MOV and the MOV's menu has landed, so the stale build is
        // provably in flight across the change and provably finishes after it.
        let gate = QueryGate(pathExtension: "jpg")
        let workspace = RecordingWorkspace(
            defaults: ["jpg": .preview, "mov": .quickTime],
            applications: ["jpg": [.preview], "mov": [.quickTime]],
            gate: gate
        )
        let model = makeOpenWithModel(workspace: workspace)
        let jpg = try makeIDs(count: 1)[0]
        let mov = try makeLocalMediaIDs(["clip.mov"])[0]
        let ids = [jpg, mov]
        model.applyState(openWithWindowState(ids: ids))

        _ = model.applyGridClick(hit: jpg, modifiers: [], orderedIDs: ids)
        try await waitUntil { gate.hasEntered }
        let staleBuild = try #require(model.openWithMenuTask)
        _ = model.applyGridClick(hit: mov, modifiers: [], orderedIDs: ids)
        try await waitUntil { model.openWithMenu.defaultsByTarget[mov.fileURL] == .quickTime }

        gate.release()
        // The stale build has returned and either applied or discarded its menu.
        await staleBuild.value

        #expect(model.openWithMenu.openTitle == "Open in QuickTime Player")
        #expect(model.openWithMenu.defaultsByTarget[mov.fileURL] == .quickTime)
        #expect(model.openWithMenu.defaultsByTarget[jpg.fileURL] == nil)
    }

    /// An original that is not where the catalog last saw it opens nothing: the hand-off
    /// hands over only files on this Mac, and says which photo it could not find (ADR 0012).
    @Test func aMissingOriginalOpensNothingAndSaysSo() async throws {
        let workspace = RecordingWorkspace(defaults: ["jpg": .preview], applications: ["jpg": [.preview]])
        let model = makeOpenWithModel(workspace: workspace)
        let missing = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
            relativePath: MediaRelativePath(rawValue: "gone.jpg")
        )
        model.applyState(openWithWindowState(ids: [missing]))
        model.selectAll()
        try await waitUntil { model.openWithMenu.targetCount == 1 }

        model.openTargetsInDefaultApplication()
        try await waitUntil { model.hasSettledHandOffs }

        #expect(await workspace.opens.isEmpty)
        #expect(model.handOffAlertMessage
            == "One photo’s original isn’t where Otos last saw it. Nothing was handed over.")
    }
}

@MainActor
private func makeOpenWithModel(workspace: RecordingWorkspace) -> CatalogWindowViewModel {
    // Open, Open With, Share and Copy are hand-offs, consumed by the hand-off lane.
    let model = CatalogWindowViewModel(
        catalogStore: makeTestStore(location: .inMemory),
        startsStallMonitor: false,
        startsEnrichment: false,
        startsSourceMonitoring: false,
        preferencesDomain: .suite(UUID().uuidString),
        workspace: workspace,
        volumeCapacity: ampleVolumeCapacity,
        trashFiles: .refusing
    )
    model.startHandOff(store: model.catalogStore)
    return model
}

private func makeIDs(count: Int) throws -> [MediaAssetID] {
    try makeLocalMediaIDs((0 ..< count).map { "asset-\($0).jpg" })
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

/// Holds one extension's application query on its (non-main) calling thread until the
/// test releases it, and reports when the query was entered and when it returned.
private final class QueryGate: Sendable {
    let pathExtension: String
    private let entered = Mutex(false)
    private let returned = Mutex(false)
    private let released = DispatchSemaphore(value: 0)

    init(pathExtension: String) {
        self.pathExtension = pathExtension
    }

    var hasEntered: Bool {
        entered.withLock { $0 }
    }

    var hasReturned: Bool {
        returned.withLock { $0 }
    }

    func release() {
        released.signal()
    }

    func pass() {
        entered.withLock { $0 = true }
        released.wait()
        returned.withLock { $0 = true }
    }
}

private struct RecordingWorkspace: WorkspaceOpening {
    let defaults: [String: URL]
    let applications: [String: [URL]]
    let gate: QueryGate?
    private let log = OpenLog()

    init(defaults: [String: URL], applications: [String: [URL]], gate: QueryGate? = nil) {
        self.defaults = defaults
        self.applications = applications
        self.gate = gate
    }

    var opens: [(application: URL, targets: [URL])] {
        get async { await log.opens }
    }

    func applicationURLs(toOpen url: URL) -> [URL] {
        if let gate, gate.pathExtension == url.pathExtension.lowercased() {
            // LaunchServices is synchronous; a slow answer is modelled by blocking the
            // calling (non-main) thread, exactly as a cold LaunchServices query would.
            gate.pass()
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

    func revealInFinder(_: [URL]) {}
}
