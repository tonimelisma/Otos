import Foundation
@testable import Otos
import Testing

/// Tests `CatalogWindowViewModel`'s grid-zoom intent (spec 0048): clamping, persistence,
/// and the zoom in/out convenience intents. Each test uses an isolated `UserDefaults`
/// suite (never `.standard`) so tests cannot leak a real column-count preference into
/// the developer's actual defaults domain or into each other.
@MainActor
struct CatalogWindowViewModelGridZoomTests {
    @Test func defaultsToSixColumnsWithNoStoredPreference() {
        let temp = TemporaryDefaults()
        defer { temp.cleanUp() }
        let model = makeViewModel(defaults: temp.defaults)
        #expect(model.gridColumnCount == 6)
    }

    @Test func loadsAndValidatesAStoredPreference() {
        let temp = TemporaryDefaults()
        defer { temp.cleanUp() }
        temp.defaults.set(4, forKey: "mediaGridColumnCount")
        let model = makeViewModel(defaults: temp.defaults)
        #expect(model.gridColumnCount == 4)
    }

    @Test func garbageStoredPreferenceFallsBackToDefault() {
        let temp = TemporaryDefaults()
        defer { temp.cleanUp() }
        temp.defaults.set(999, forKey: "mediaGridColumnCount")
        let model = makeViewModel(defaults: temp.defaults)
        #expect(model.gridColumnCount == 6)
    }

    @Test func setGridColumnCountClampsPersistsAndPublishes() {
        let temp = TemporaryDefaults()
        defer { temp.cleanUp() }
        let model = makeViewModel(defaults: temp.defaults)

        model.setGridColumnCount(2) // one below minimum
        #expect(model.gridColumnCount == 3)
        #expect(temp.defaults.integer(forKey: "mediaGridColumnCount") == 3)

        model.setGridColumnCount(10) // one above maximum
        #expect(model.gridColumnCount == 9)
        #expect(temp.defaults.integer(forKey: "mediaGridColumnCount") == 9)
    }

    @Test func setGridColumnCountRoundTripsThroughANewViewModelInstance() {
        let temp = TemporaryDefaults()
        defer { temp.cleanUp() }
        let first = makeViewModel(defaults: temp.defaults)
        first.setGridColumnCount(9)

        let second = makeViewModel(defaults: temp.defaults)
        #expect(second.gridColumnCount == 9)
    }

    @Test func zoomInDecreasesAndZoomOutIncreasesColumnCount() {
        let temp = TemporaryDefaults()
        defer { temp.cleanUp() }
        let model = makeViewModel(defaults: temp.defaults)
        #expect(model.gridColumnCount == 6)

        model.zoomInGrid()
        #expect(model.gridColumnCount == 5)

        model.zoomOutGrid()
        #expect(model.gridColumnCount == 6)
    }

    @Test func zoomInStopsAtMinimumAndZoomOutStopsAtMaximum() {
        let temp = TemporaryDefaults()
        defer { temp.cleanUp() }
        let model = makeViewModel(defaults: temp.defaults)

        for _ in 0 ..< 10 {
            model.zoomInGrid()
        }
        #expect(model.gridColumnCount == GridColumnCount.minimum)

        for _ in 0 ..< 20 {
            model.zoomOutGrid()
        }
        #expect(model.gridColumnCount == GridColumnCount.maximum)
    }

    @Test func defaultsToSeventyTwoStripTileEdge() {
        let temp = TemporaryDefaults()
        defer { temp.cleanUp() }
        let model = makeViewModel(defaults: temp.defaults)
        #expect(model.stripTileEdge == MediaGridPresentation.defaultStripTileEdge)
    }

    @Test func setStripTileEdgeClampsPersistsAndPublishes() {
        let temp = TemporaryDefaults()
        defer { temp.cleanUp() }
        let model = makeViewModel(defaults: temp.defaults)

        model.setStripTileEdge(20)
        #expect(model.stripTileEdge == MediaGridPresentation.minStripTileEdge)
        #expect(
            temp.defaults.double(forKey: CatalogWindowViewModel.stripTileEdgeDefaultsKey)
                == Double(MediaGridPresentation.minStripTileEdge)
        )

        model.setStripTileEdge(400)
        #expect(model.stripTileEdge == MediaGridPresentation.maxStripTileEdge)
        #expect(
            temp.defaults.double(forKey: CatalogWindowViewModel.stripTileEdgeDefaultsKey)
                == Double(MediaGridPresentation.maxStripTileEdge)
        )
    }

    @Test func setStripTileEdgeRoundTripsThroughANewViewModelInstance() {
        let temp = TemporaryDefaults()
        defer { temp.cleanUp() }
        let first = makeViewModel(defaults: temp.defaults)
        first.setStripTileEdge(120)

        let second = makeViewModel(defaults: temp.defaults)
        #expect(second.stripTileEdge == 120)
    }
}

@MainActor
private func makeViewModel(defaults: UserDefaults) -> CatalogWindowViewModel {
    CatalogWindowViewModel(
        catalogStore: CatalogStore(location: .inMemory),
        startsStallMonitor: false,
        startsEnrichment: false,
        startsSourceMonitoring: false,
        preferences: defaults
    )
}
