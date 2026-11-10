import Foundation
@testable import OtosKit
import Testing

/// A failed catalog read against a real catalog (ADR 0032, rule 4). Each read is made to
/// fail inside the store by hiding a table it reads (`asset_metadata` for tile details,
/// `media_asset` for the loupe overlay's asset); every caller publishes nothing for it,
/// keeps no value that belongs to another asset, and asking again once the table is back
/// publishes the real value.
///
/// Each step waits on the task that made the read, so "nothing was published" is checked
/// after the failure, never after a delay.
@Suite(.testDirectory)
@MainActor
struct CatalogWindowViewModelDetailReadFailureTests {
    @Test func aFailedReadPublishesNoPanePreviewAndTheNextReconcileDoes() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            let hidden = try await HiddenCatalogTable("asset_metadata", in: library.databaseURL)

            model.openLoupe(id: id)
            await model.paneRequestTasks[.loupe]?.value
            #expect(model.panePreviews[.loupe] == nil)
            #expect(!model.downloadingSlots.contains(.loupe))

            try await hidden.restore()
            model.refreshPanePreviews()
            try await waitUntil { model.panePreviews[.loupe]?.id == id }
        }
    }

    /// The screen-sized decode stays in the slot, so only the zoom report can ask again
    /// for full resolution: a failed read must not count as having asked.
    @Test func aFailedFullResolutionReadDecodesNothingAndTheNextZoomAsksAgain() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let loader = FakePreviewLoader()
            let small = try #require(gradientImage(width: 400, height: 300))
            await loader.setDefaultOutcome(.image(small, nativePixelSize: CGSize(width: 6000, height: 4500)))
            let model = CatalogWindowViewModel(
                catalogStore: library.store,
                startsStallMonitor: false,
                startsEnrichment: false,
                startsSourceMonitoring: false,
                preferencesDomain: .suite(UUID().uuidString),
                previewLoader: loader,
                volumeCapacity: ampleVolumeCapacity,
                trashFiles: .refusing
            )
            model.applyState(CatalogWindowState(
                title: "Zoom",
                libraries: [],
                removableSources: [],
                mediaGrid: CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: library.ids),
                filterOptions: .empty,
                resolvedSidebarSelection: .allMedia,
                mediaEmptyState: .noMedia,
                deviceConnectionBanner: nil
            ))
            model.openLoupe(id: id)
            await model.paneRequestTasks[.loupe]?.value
            try #require(model.panePreviews[.loupe]?.id == id)
            let hidden = try await HiddenCatalogTable("asset_metadata", in: library.databaseURL)

            model.reportLoupeZoom(LoupeZoomReport(magnification: 1, fit: 0.05))
            await model.paneRequestTasks[.loupe]?.value
            #expect(await loader.requestedEdges().count == 1)
            #expect(model.panePreviews[.loupe]?.image === small)
            #expect(!model.downloadingSlots.contains(.loupe))

            try await hidden.restore()
            model.reportLoupeZoom(LoupeZoomReport(magnification: 1, fit: 0.05))
            await model.paneRequestTasks[.loupe]?.value
            let edges = await loader.requestedEdges()
            #expect(edges.count == 2)
            #expect(edges.last == PreviewImageLoader.fullResolution)
        }
    }

    @Test func aFailedReadLeavesTheFocusedKindUnknownAndTheNextFocusReadsIt() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            let hidden = try await HiddenCatalogTable("asset_metadata", in: library.databaseURL)

            model.openLoupe(id: id)
            await model.focusedKindTask?.value
            #expect(model.focusedAssetKind == nil)

            try await hidden.restore()
            model.setFocus(id)
            try await waitUntil { model.focusedAssetKind == .image }
        }
    }

    @Test func aFailedReadOpensNoEditTargetAndTheNextRefreshDoes() async throws {
        try await withEditableLibrary(fileCount: 2) { library in
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            model.toggleInspector(.edit)
            model.openLoupe(id: library.ids[0])
            try await waitUntil { model.editTarget?.id == library.ids[0] }
            let hidden = try await HiddenCatalogTable("asset_metadata", in: library.databaseURL)

            // The panel lets go of the photo it showed rather than edit it while the
            // loupe shows the next one.
            model.focusNext()
            await model.editTargetTask?.value
            #expect(model.editTarget == nil)

            try await hidden.restore()
            model.refreshEditTarget()
            try await waitUntil { model.editTarget?.id == library.ids[1] }
        }
    }

    @Test func aFailedReadShowsNoSharedChoiceAndTheNextTargetChangeDoes() async throws {
        try await withEditableLibrary(fileCount: 2) { library in
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            _ = try await library.store.setMediaChoices([library.ids[0]: .liked, library.ids[1]: .liked])
            model.openLoupe(id: library.ids[0])
            try await waitUntil { model.currentTargetChoice == .liked }
            let hidden = try await HiddenCatalogTable("asset_metadata", in: library.databaseURL)

            // The first photo's choice is not shown as the second one's.
            model.focusNext()
            await model.currentTargetChoiceTask?.value
            #expect(model.currentTargetChoice == nil)

            try await hidden.restore()
            model.focusPrevious()
            try await waitUntil { model.currentTargetChoice == .liked }
        }
    }

    @Test func aFailedAssetReadShowsNoOtherAssetsInfoAndNoInventedFacts() async throws {
        try await withEditableLibrary(fileCount: 2) { library in
            let model = makeEditModel(store: library.store, ids: library.ids)
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }
            model.openLoupe(id: library.ids[0])
            model.toggleInspector(.info)
            try await waitUntil { model.photoInfo?.id == library.ids[0] }
            let hidden = try await HiddenCatalogTable("media_asset", in: library.databaseURL)

            model.focusNext()
            await model.focusedKindTask?.value
            await model.photoInfoTask?.value
            #expect(model.photoInfo == nil)

            try await hidden.restore()
            model.refreshPhotoInfo()
            try await waitUntil { model.photoInfo?.id == library.ids[1] }
            #expect(model.photoInfo?.fileSize != PhotoInfo.unknown)
        }
    }
}
