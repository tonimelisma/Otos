import Foundation
@testable import OtosKit
import Testing

/// Tests `CatalogWindowViewModel`'s grid-zoom intent (APP-006): clamping, persistence,
/// and the zoom in/out convenience intents. Each test uses its own in-memory `.suite`
/// domain (never `.standard`) so tests cannot leak a real column-count preference into
/// the developer's actual defaults domain or into each other.
@Suite(.testScope)
@MainActor
struct CatalogWindowViewModelGridZoomTests {
    @Test func garbageStoredPreferenceFallsBackToDefault() {
        let temp = PreferencesDomain.suite(UUID().uuidString)
        temp.makeDefaults().set(999, forKey: "mediaGridColumnCount")
        let model = makeViewModel(domain: temp)
        #expect(model.gridColumnCount == 6)
    }

    @Test func setGridColumnCountClampsPersistsAndPublishes() {
        let temp = PreferencesDomain.suite(UUID().uuidString)
        let model = makeViewModel(domain: temp)

        model.setGridColumnCount(2) // one below minimum
        #expect(model.gridColumnCount == 3)
        #expect(temp.makeDefaults().integer(forKey: "mediaGridColumnCount") == 3)

        model.setGridColumnCount(10) // one above maximum
        #expect(model.gridColumnCount == 9)
        #expect(temp.makeDefaults().integer(forKey: "mediaGridColumnCount") == 9)
    }

    @Test func setGridColumnCountRoundTripsThroughANewViewModelInstance() {
        let temp = PreferencesDomain.suite(UUID().uuidString)
        let first = makeViewModel(domain: temp)
        first.setGridColumnCount(9)

        let second = makeViewModel(domain: temp)
        #expect(second.gridColumnCount == 9)
    }

    @Test func zoomInStopsAtMinimumAndZoomOutStopsAtMaximum() {
        let temp = PreferencesDomain.suite(UUID().uuidString)
        let model = makeViewModel(domain: temp)

        for _ in 0 ..< 10 {
            model.zoomInGrid()
        }
        #expect(model.gridColumnCount == GridColumnCount.minimum)
        // The menu items and the toolbar's −/+ share this one enablement.
        #expect(!model.canZoomIn)
        #expect(model.canZoomOut)

        for _ in 0 ..< 20 {
            model.zoomOutGrid()
        }
        #expect(model.gridColumnCount == GridColumnCount.maximum)
        #expect(model.canZoomIn)
        #expect(!model.canZoomOut)
    }

    @Test func setStripTileEdgeClampsPersistsAndPublishes() {
        let temp = PreferencesDomain.suite(UUID().uuidString)
        let model = makeViewModel(domain: temp)

        model.setStripTileEdge(20)
        #expect(model.stripTileEdge == MediaGridPresentation.minStripTileEdge)
        #expect(
            temp.makeDefaults().object(forKey: CatalogWindowViewModel.stripTileEdgeDefaultsKey) as? Double
                == Double(MediaGridPresentation.minStripTileEdge)
        )

        model.setStripTileEdge(400)
        #expect(model.stripTileEdge == MediaGridPresentation.maxStripTileEdge)
        #expect(
            temp.makeDefaults().object(forKey: CatalogWindowViewModel.stripTileEdgeDefaultsKey) as? Double
                == Double(MediaGridPresentation.maxStripTileEdge)
        )
    }
}

@MainActor
private func makeViewModel(domain: PreferencesDomain) -> CatalogWindowViewModel {
    CatalogWindowViewModel(
        catalogStore: makeTestStore(location: .inMemory),
        startsStallMonitor: false,
        startsEnrichment: false,
        startsSourceMonitoring: false,
        preferencesDomain: domain,
        volumeCapacity: ampleVolumeCapacity,
        trashFiles: .refusing
    )
}
