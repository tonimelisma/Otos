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
@Suite(.testScope)
@MainActor
struct CatalogWindowViewModelDetailReadFailureTests {
    @Test func aFailedReadPublishesNoPanePreviewAndTheNextReconcileDoes() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = library.makeEditModel()
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
            let small = try #require(gradientImage(width: 400, height: 300).flatMap(DisplayImage.shown))
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

            model.reportLoupeZoom(LoupeZoomReport(asset: id, magnification: 1, fit: 0.05))
            await model.paneRequestTasks[.loupe]?.value
            #expect(await loader.requestedEdges().count == 1)
            #expect(model.panePreviews[.loupe]?.image === small)
            #expect(!model.downloadingSlots.contains(.loupe))

            try await hidden.restore()
            model.reportLoupeZoom(LoupeZoomReport(asset: id, magnification: 1, fit: 0.05))
            await model.paneRequestTasks[.loupe]?.value
            let edges = await loader.requestedEdges()
            #expect(edges.count == 2)
            #expect(edges.last == PreviewImageLoader.fullResolution)
        }
    }

    @Test func aFailedReadLeavesTheFocusedKindUnknownAndTheNextFocusReadsIt() async throws {
        try await withEditableLibrary(fileCount: 1) { library in
            let id = library.ids[0]
            let model = library.makeEditModel()
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
            let model = library.makeEditModel()
            model.toggleInspector(.edit)
            model.openLoupe(id: library.ids[0])
            try await waitUntil { model.editSession.editTarget?.id == library.ids[0] }
            let hidden = try await HiddenCatalogTable("asset_metadata", in: library.databaseURL)

            // The panel lets go of the photo it showed rather than edit it while the
            // loupe shows the next one.
            model.focusNext()
            await model.editSession.editTargetTask?.value
            #expect(model.editSession.editTarget == nil)

            try await hidden.restore()
            model.editSession.refreshEditTarget()
            try await waitUntil { model.editSession.editTarget?.id == library.ids[1] }
        }
    }

    @Test func aFailedReadShowsNoSharedChoiceAndTheNextTargetChangeDoes() async throws {
        try await withEditableLibrary(fileCount: 2) { library in
            let model = library.makeEditModel()
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
            let model = library.makeEditModel()
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
            #expect(model.photoInfo?.value("Size") != PhotoInfo.unknown)
        }
    }

    /// The place name is looked up for the item the pane shows; an answer for an item the
    /// pane has left is dropped, never shown under the next one (APP-041, ADR 0050).
    @Test func thePlaceNameIsLookedUpForTheItemShownAndAStaleAnswerIsDropped() async throws {
        try await withEditableLibrary(fileCount: 2) { library in
            for (index, id) in library.ids.enumerated() {
                let asset = try #require(try await library.store.windowReads.mediaAssets(for: [id])[id])
                let located = AssetMetadata(locations: [
                    GeoRecord(source: "exifGPS", latitude: Double(index + 1), longitude: 0, altitudeMeters: nil),
                ])
                try await library.store.applyEnrichmentBatch([EnrichmentResult(
                    id: id,
                    metadata: EnrichedMetadata(metadata: located, kind: .image, format: nil),
                    rendering: nil,
                    sourceSize: asset.byteSize,
                    sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
                    contentHash: nil
                )])
                try #require(try await library.store.windowReads.metadata(for: id)?.locations.count == 1)
            }
            let model = library.makeEditModel()
            let places = PlaceGate()
            model.placeNameLookup = PlaceNameLookup { await places.name(for: $0) }

            model.openLoupe(id: library.ids[0])
            model.toggleInspector(.info)
            await places.waitForRequest(latitude: 1)
            model.focusNext()
            await places.waitForRequest(latitude: 2)

            await places.answer(latitude: 1, with: "First")
            await places.answer(latitude: 2, with: "Second")
            try await waitUntil { model.photoInfo?.value("Place") == "Second" }
            #expect(model.photoInfo?.id == library.ids[1])
        }
    }
}

/// Holds each place-name lookup until the test answers it.
private actor PlaceGate {
    private var pending: [Double: CheckedContinuation<String?, Never>] = [:]
    private var requested: [Double: [CheckedContinuation<Void, Never>]] = [:]

    func name(for coordinate: PlaceCoordinate) async -> String? {
        await withCheckedContinuation { continuation in
            pending[coordinate.latitude] = continuation
            requested.removeValue(forKey: coordinate.latitude)?.forEach { $0.resume() }
        }
    }

    func waitForRequest(latitude: Double) async {
        guard pending[latitude] == nil else { return }
        await withCheckedContinuation { requested[latitude, default: []].append($0) }
    }

    func answer(latitude: Double, with name: String) {
        pending.removeValue(forKey: latitude)?.resume(returning: name)
    }
}
