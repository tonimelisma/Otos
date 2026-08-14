import Foundation
@testable import Otos
import Testing

@MainActor
struct CatalogWindowViewModelCurationTests {
    @Test func rapidChoicesRemainLosslessAndOrdered() async throws {
        let fixture = try await makeCurationFixture(count: 1)
        defer { fixture.removeRoot() }
        let (model, preferences) = makeCurationModel()
        defer { preferences.cleanUp() }
        model.applyState(curationWindowState(ids: fixture.ids))
        _ = model.applyGridClick(hit: fixture.ids[0], modifiers: [], orderedIDs: fixture.ids)
        model.startMediaChoiceForwarding(store: fixture.store)

        model.submitMediaChoice(.liked, origin: .keyboard)
        model.submitMediaChoice(.notRated, origin: .keyboard)
        model.submitMediaChoice(.disliked, origin: .keyboard)

        try await waitForCurationCondition {
            try await fixture.store.mediaAssets(for: fixture.ids)[fixture.ids[0]]?.mediaChoice == .disliked
        }
        #expect(model.gridSelection.selection == [fixture.ids[0]])
        model.mediaChoiceForwardingTask?.cancel()
    }

    @Test func acceptedSameValueChoiceAdvancesOnlyWhenEnabled() async throws {
        let fixture = try await makeCurationFixture(count: 2)
        defer { fixture.removeRoot() }
        let (model, preferences) = makeCurationModel()
        defer { preferences.cleanUp() }
        model.applyState(curationWindowState(ids: fixture.ids))
        _ = model.applyGridClick(hit: fixture.ids[0], modifiers: [], orderedIDs: fixture.ids)
        model.setAdvanceAfterMediaChoice(true)
        model.startMediaChoiceForwarding(store: fixture.store)

        model.submitMediaChoice(.notRated, origin: .keyboard)

        try await waitForCurationCondition {
            model.gridSelection.selection == [fixture.ids[1]]
        }
        #expect(try await fixture.store.mediaAssets(for: fixture.ids)[fixture.ids[0]]?.mediaChoice == .notRated)
        model.mediaChoiceForwardingTask?.cancel()
    }

    @Test func acceptedChoiceAtEndDoesNotWrap() async throws {
        let fixture = try await makeCurationFixture(count: 2)
        defer { fixture.removeRoot() }
        let (model, preferences) = makeCurationModel()
        defer { preferences.cleanUp() }
        model.applyState(curationWindowState(ids: fixture.ids))
        _ = model.applyGridClick(hit: fixture.ids[1], modifiers: [], orderedIDs: fixture.ids)
        model.setAdvanceAfterMediaChoice(true)
        model.startMediaChoiceForwarding(store: fixture.store)

        model.submitMediaChoice(.liked, origin: .keyboard)

        try await waitForCurationCondition {
            try await fixture.store.mediaAssets(for: fixture.ids)[fixture.ids[1]]?.mediaChoice == .liked
        }
        #expect(model.gridSelection.selection == [fixture.ids[1]])
        model.mediaChoiceForwardingTask?.cancel()
    }

    @Test func rejectedStoreMutationNeverAdvances() async throws {
        let (model, preferences) = makeCurationModel()
        defer { preferences.cleanUp() }
        let ids = curationIDs(root: "/missing", count: 2)
        model.applyState(curationWindowState(ids: ids))
        _ = model.applyGridClick(hit: ids[0], modifiers: [], orderedIDs: ids)
        model.setAdvanceAfterMediaChoice(true)
        model.startMediaChoiceForwarding(store: model.catalogStore)

        model.submitMediaChoice(.liked, origin: .keyboard)
        try await Task.sleep(for: .milliseconds(50))

        #expect(model.gridSelection.selection == [ids[0]])
        model.mediaChoiceForwardingTask?.cancel()
    }
}

@MainActor
private func makeCurationModel() -> (CatalogWindowViewModel, TemporaryDefaults) {
    let preferences = TemporaryDefaults()
    let model = CatalogWindowViewModel(
        catalogStore: CatalogStore(location: .inMemory),
        startsStallMonitor: false,
        startsEnrichment: false,
        startsSourceMonitoring: false,
        preferencesDomain: preferences.domain
    )
    return (model, preferences)
}

private struct CurationFixture {
    let store: CatalogStore
    let root: URL
    let ids: [MediaAssetID]

    func removeRoot() {
        try? FileManager.default.removeItem(at: root)
        Task { await store.shutdown() }
    }
}

private func makeCurationFixture(count: Int) async throws -> CurationFixture {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "Otos-curation-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for index in 0 ..< count {
        try Data([0]).write(to: root.appending(path: "choice-\(index).jpg"))
    }
    let rootPath = try CatalogPath.normalizedExistingDirectoryPath(for: root)
    let ids = curationIDs(root: rootPath.rawValue, count: count)
    let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(5))
    try await store.addLibrary(url: root)
    try await waitForCurationCondition {
        try await store.mediaAssets(for: ids).count == ids.count
    }
    return CurationFixture(store: store, root: root, ids: ids)
}

private func curationWindowState(ids: [MediaAssetID]) -> CatalogWindowState {
    CatalogWindowState(
        title: "Curation",
        libraries: [],
        removableSources: [],
        mediaGrid: CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids),
        filterOptions: .empty,
        resolvedSidebarSelection: .allMedia,
        mediaEmptyState: .noMedia,
        deviceConnectionBanner: nil
    )
}

private func curationIDs(root: String, count: Int) -> [MediaAssetID] {
    (0 ..< count).map { index in
        MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: root),
            relativePath: MediaRelativePath(rawValue: "choice-\(index).jpg")
        )
    }
}

@MainActor
private func waitForCurationCondition(
    _ condition: @escaping @MainActor () async throws -> Bool
) async throws {
    for _ in 0 ..< 200 {
        if try await condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for curation state")
}
