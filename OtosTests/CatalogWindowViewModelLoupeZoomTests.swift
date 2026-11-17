import CoreGraphics
import Foundation
@testable import OtosKit
import Testing

/// Loupe zoom intents (APP-040) and the info overlay (APP-041) at the ViewModel: menu
/// items dispatch by mode, Escape unwinds zoom before the mode, a report past the held
/// decode requests full resolution once, and focus changes reset everything.
@Suite(.testScope)
@MainActor
struct CatalogWindowViewModelLoupeZoomTests {
    @Test func zoomInChangesColumnsInGridAndMagnificationInLoupe() {
        let fake = FakePreviewLoader()
        let model = makeZoomModel(loader: fake)
        let ids = makeIDs(count: 2)
        model.applyState(zoomWindowState(ids: ids))
        let columns = model.gridColumnCount

        model.zoomIn()
        #expect(model.gridColumnCount == columns - 1)
        #expect(model.loupeZoomCommand == nil)

        model.openLoupe(id: ids[0])
        #expect(!model.canZoomIn && !model.canZoomOut)
        model.zoomIn()
        #expect(model.loupeZoomCommand == nil)

        model.reportLoupeZoom(LoupeZoomReport(asset: ids[0], magnification: 0.5, fit: 0.5))
        #expect(model.canZoomIn)
        #expect(!model.canZoomOut)
        model.zoomIn()
        #expect(model.loupeZoomCommand?.target == .magnification(0.625))
        #expect(model.gridColumnCount == columns - 1)

        model.reportLoupeZoom(LoupeZoomReport(asset: ids[0], magnification: 0.9, fit: 0.5))
        model.zoomIn()
        #expect(model.loupeZoomCommand?.target == .magnification(1))
        model.reportLoupeZoom(LoupeZoomReport(asset: ids[0], magnification: 0.55, fit: 0.5))
        model.zoomOut()
        #expect(model.loupeZoomCommand?.target == .fit)
    }

    @Test func toggleGoesToActualSizeAboutTheClickAndBack() {
        let model = makeZoomModel(loader: FakePreviewLoader())
        let ids = makeIDs(count: 1)
        model.applyState(zoomWindowState(ids: ids))
        model.openLoupe(id: ids[0])
        model.reportLoupeZoom(LoupeZoomReport(asset: ids[0], magnification: 0.5, fit: 0.5))

        model.toggleLoupeZoom(at: CGPoint(x: 10, y: 20))
        #expect(model.loupeZoomCommand?.target == .magnification(1))
        #expect(model.loupeZoomCommand?.anchor == CGPoint(x: 10, y: 20))
        let first = model.loupeZoomCommand?.generation

        model.reportLoupeZoom(LoupeZoomReport(asset: ids[0], magnification: 1, fit: 0.5))
        model.toggleLoupeZoom()
        #expect(model.loupeZoomCommand?.target == .fit)
        #expect(model.loupeZoomCommand?.generation != first)
    }

    @Test func escapeReturnsToFitThenExits() {
        let model = makeZoomModel(loader: FakePreviewLoader())
        let ids = makeIDs(count: 1)
        model.applyState(zoomWindowState(ids: ids))
        model.openLoupe(id: ids[0])
        model.reportLoupeZoom(LoupeZoomReport(asset: ids[0], magnification: 1, fit: 0.5))

        model.loupeEscape()
        #expect(model.viewMode == .loupe)
        #expect(model.loupeZoomCommand?.target == .fit)

        model.reportLoupeZoom(LoupeZoomReport(asset: ids[0], magnification: 0.5, fit: 0.5))
        model.loupeEscape()
        #expect(model.viewMode == .grid)
        #expect(model.loupeZoomReport == nil)
    }

    @Test func zoomingPastTheDecodeRequestsFullResolutionOnce() async {
        let fake = FakePreviewLoader()
        let small = makeZoomImage(width: 400, height: 300)
        await fake.setDefaultOutcome(.image(small, nativePixelSize: CGSize(width: 6000, height: 4500)))
        let model = makeZoomModel(loader: fake)
        let ids = makeIDs(count: 1)
        model.applyState(zoomWindowState(ids: ids))
        model.openLoupe(id: ids[0])
        await model.paneRequestTasks[.loupe]?.value
        #expect(model.panePreviews[.loupe]?.nativePixelSize == CGSize(width: 6000, height: 4500))

        // At fit the 400-px decode covers a 0.05 magnification; nothing more is asked.
        model.reportLoupeZoom(LoupeZoomReport(asset: ids[0], magnification: 0.05, fit: 0.05))
        #expect(await fake.requestedEdges().count == 1)

        model.reportLoupeZoom(LoupeZoomReport(asset: ids[0], magnification: 1, fit: 0.05))
        await model.paneRequestTasks[.loupe]?.value
        let edges = await fake.requestedEdges()
        #expect(edges.count == 2)
        #expect(edges.last == PreviewImageLoader.fullResolution)

        // A second report at the same magnification does not ask again.
        model.reportLoupeZoom(LoupeZoomReport(asset: ids[0], magnification: 1, fit: 0.05))
        #expect(await fake.requestedEdges().count == 2)
        // The fit-size decode was never blanked while the sharper one was pending.
        #expect(model.panePreviews[.loupe]?.id == ids[0])
    }

    /// The loupe shows the photo it has until the next one's decode lands, and the zoom view
    /// reports while it swaps documents: a report measured on the photo just left is not the
    /// focused photo's, so it neither becomes the zoom state nor asks for a full decode.
    @Test func aReportMeasuredOnAnotherPhotoIsNotTaken() async {
        let fake = FakePreviewLoader()
        await fake.setDefaultOutcome(.image(makeZoomImage(width: 400, height: 300), nativePixelSize: CGSize(width: 6000, height: 4000)))
        let model = makeZoomModel(loader: fake)
        let ids = makeIDs(count: 2)
        model.applyState(zoomWindowState(ids: ids))
        model.openLoupe(id: ids[0])
        await model.paneRequestTasks[.loupe]?.value
        model.focusNext()
        await model.paneRequestTasks[.loupe]?.value
        #expect(model.panePreviews[.loupe]?.id == ids[1])

        model.reportLoupeZoom(LoupeZoomReport(asset: ids[0], magnification: 1, fit: 1))
        #expect(model.loupeZoomReport == nil)
        #expect(await fake.requestedEdges().allSatisfy { $0 != PreviewImageLoader.fullResolution })
    }

    @Test func focusChangeResetsZoom() {
        let model = makeZoomModel(loader: FakePreviewLoader())
        let ids = makeIDs(count: 2)
        model.applyState(zoomWindowState(ids: ids))
        model.openLoupe(id: ids[0])
        model.reportLoupeZoom(LoupeZoomReport(asset: ids[0], magnification: 1, fit: 0.5))
        model.toggleLoupeZoom()
        #expect(model.loupeZoomCommand != nil)

        model.focusNext()

        #expect(model.focusedAssetID == ids[1])
        #expect(model.loupeZoomReport == nil)
        #expect(model.loupeZoomCommand == nil)
        #expect(!model.canZoomIn && !model.canZoomOut)
    }

    /// The inspector holds one pane (APP-041): I shows Info for the current target in any
    /// mode and follows it, E switches the column to Edit, and the shown pane's key hides it.
    @Test func infoPaneFollowsTheTargetAndToggle() async throws {
        let model = makeZoomModel(loader: FakePreviewLoader())
        let ids = makeIDs(count: 2)
        model.applyState(zoomWindowState(ids: ids))
        model.selectAssets([ids[0]])
        #expect(model.photoInfo == nil)

        model.toggleInspector(.info)
        #expect(model.inspectorPane == .info)
        try await waitUntil { model.photoInfo?.title == "asset-0.jpg" }
        #expect(model.photoInfo?.captured == PhotoInfo.unknown)

        model.openLoupe(id: ids[0])
        model.focusNext()
        try await waitUntil { model.photoInfo?.title == "asset-1.jpg" }

        model.toggleInspector(.edit)
        #expect(model.inspectorPane == .edit)
        #expect(model.isEditPanelPresented)
        #expect(model.photoInfo == nil)

        model.toggleInspector(.edit)
        #expect(model.inspectorPane == nil)
        #expect(!model.showsInfo)
    }
}

@MainActor
private func makeZoomModel(loader: FakePreviewLoader) -> CatalogWindowViewModel {
    CatalogWindowViewModel(
        catalogStore: makeTestStore(location: .inMemory),
        startsStallMonitor: false,
        startsEnrichment: false,
        startsSourceMonitoring: false,
        preferencesDomain: .suite(UUID().uuidString),
        previewLoader: loader,
        volumeCapacity: ampleVolumeCapacity,
        trashFiles: .refusing
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

private func zoomWindowState(ids: [MediaAssetID]) -> CatalogWindowState {
    CatalogWindowState(
        title: "Zoom",
        libraries: [],
        removableSources: [],
        mediaGrid: CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids),
        filterOptions: .empty,
        resolvedSidebarSelection: .allMedia,
        mediaEmptyState: .noMedia,
        deviceConnectionBanner: nil
    )
}

private func makeZoomImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}
