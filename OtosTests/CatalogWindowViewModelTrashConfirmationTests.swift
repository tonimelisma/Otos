import Foundation
@testable import OtosKit
import Testing

/// The Move to Trash confirmation (APP-027): every surface asks first, confirm runs the
/// move exactly once, cancel runs nothing, and the title names the scope.
@MainActor
struct CatalogWindowViewModelTrashConfirmationTests {
    @Test func requestAsksAndConfirmRunsOnce() async throws {
        let fixture = try await makeTrashFixture(count: 2)
        defer { fixture.removeRoot() }
        let model = makeTrashModel(store: fixture.store)
        model.applyState(trashWindowState(ids: fixture.ids, root: fixture.rootPath))
        model.selectAll()
        #expect(model.pendingTrashConfirmation == nil)

        model.requestMoveTargetedMediaToTrash()

        let pending = try #require(model.pendingTrashConfirmation)
        #expect(pending.count == 2)
        #expect(pending.title == "Move 2 Items to Trash?")
        #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "trash-0.jpg").path))

        model.confirmMoveToTrash()
        #expect(model.pendingTrashConfirmation == nil)
        try await waitForTrash("files moved") {
            !FileManager.default.fileExists(atPath: fixture.root.appending(path: "trash-0.jpg").path)
                && !FileManager.default.fileExists(atPath: fixture.root.appending(path: "trash-1.jpg").path)
        }
        // A second confirm with nothing pending is a no-op.
        model.confirmMoveToTrash()
        #expect(model.pendingTrashConfirmation == nil)
    }

    @Test func cancelRunsNothing() async throws {
        let fixture = try await makeTrashFixture(count: 1)
        defer { fixture.removeRoot() }
        let model = makeTrashModel(store: fixture.store)
        model.applyState(trashWindowState(ids: fixture.ids, root: fixture.rootPath))
        model.selectAll()

        model.requestMoveTargetedMediaToTrash()
        #expect(model.pendingTrashConfirmation != nil)
        model.cancelMoveToTrash()

        #expect(model.pendingTrashConfirmation == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "trash-0.jpg").path))
        #expect(model.mediaTrashTask == nil)
    }

    @Test func titlesCarryNameOrCount() {
        let one = TrashConfirmation(ids: [
            MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
                relativePath: MediaRelativePath(rawValue: "Trip/IMG_0001.ARW")
            ),
        ])
        #expect(one.title == "Move “IMG_0001.ARW” to Trash?")
        #expect(one.message == "The item moves to the Trash and can be put back from Finder.")

        let many = TrashConfirmation(ids: (0 ..< 12).map {
            MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/Pictures"), relativePath: MediaRelativePath(rawValue: "\($0).jpg"))
        })
        #expect(many.title == "Move 12 Items to Trash?")
        #expect(many.message == "The items move to the Trash and can be put back from Finder.")
        #expect(TrashConfirmation.confirmTitle == "Move to Trash")
    }

    @Test func noTargetAsksNothing() {
        let model = makeTrashModel(store: CatalogStore(location: .inMemory))
        model.requestMoveTargetedMediaToTrash()
        #expect(model.pendingTrashConfirmation == nil)
    }
}

@MainActor
private func makeTrashModel(store: CatalogStore) -> CatalogWindowViewModel {
    CatalogWindowViewModel(
        catalogStore: store,
        startsStallMonitor: false,
        startsEnrichment: false,
        startsSourceMonitoring: false,
        preferencesDomain: .suite(UUID().uuidString)
    )
}

private struct TrashFixture {
    let store: CatalogStore
    let root: URL
    let rootPath: LibraryRootPath
    let ids: [MediaAssetID]

    func removeRoot() {
        try? FileManager.default.removeItem(at: root)
        Task { await store.shutdown() }
    }
}

private func makeTrashFixture(count: Int) async throws -> TrashFixture {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "Otos-trash-confirm-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for index in 0 ..< count {
        try Data([0]).write(to: root.appending(path: "trash-\(index).jpg"))
    }
    let rootPath = try CatalogPath.normalizedExistingDirectoryPath(for: root)
    let libraryRootPath = LibraryRootPath(rawValue: rootPath.rawValue)
    let ids = (0 ..< count).map { index in
        MediaAssetID(libraryRootPath: libraryRootPath, relativePath: MediaRelativePath(rawValue: "trash-\(index).jpg"))
    }
    let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(5))
    try await store.addLibrary(url: root)
    try await waitForTrash("catalog rows") {
        await (try? store.mediaAssets(for: ids).count) == ids.count
    }
    return TrashFixture(store: store, root: root, rootPath: libraryRootPath, ids: ids)
}

@MainActor
private func trashWindowState(ids: [MediaAssetID], root: LibraryRootPath) -> CatalogWindowState {
    CatalogWindowState(
        title: "Trash",
        libraries: [
            CatalogLibraryState(root: LibraryRoot(path: root), availability: .available, activity: .idle),
        ],
        removableSources: [],
        mediaGrid: CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids),
        filterOptions: .empty,
        resolvedSidebarSelection: .allMedia,
        mediaEmptyState: .noMedia,
        deviceConnectionBanner: nil
    )
}

private func waitForTrash(
    _ label: String,
    timeout: Duration = .seconds(5),
    condition: @escaping @MainActor @Sendable () async -> Bool
) async throws {
    try await withTestTimeout(label, timeout: timeout) {
        while await !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
