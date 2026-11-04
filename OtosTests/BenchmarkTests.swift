import Foundation
@testable import OtosKit
import Testing

/// The benchmark cases (ADR 0043). Run with `script/bench.sh run`; skipped otherwise.
///
/// Each case is a path a user waits for, or one that runs in the background at a size where
/// its cost shows. Every case also checks that it did its work, so a broken fixture fails
/// rather than measuring nothing.
@Suite(.serialized, .testDirectory, .enabled(if: Benchmark.isEnabled))
struct BenchmarkTests {
    @Test func catalogCases() async throws {
        let library = try await BenchmarkLibrary.make(in: makeTestDirectory())
        let store = library.store
        let libraries = library.libraries

        // The window's publication of All Media: the order query and the window state.
        let projection = CatalogProjection()
        let request = CatalogQueryRequest(descriptor: .default, generation: 0)
        try await Benchmark.measure("projection.windowState.allMedia") {
            let (state, _) = try await projection.buildWindowState(
                store: store,
                libraries: libraries,
                request: request,
                reuse: .none
            )
            #expect(state.mediaGrid.orderedAssetIDs.count == BenchmarkLibrary.stillCount)
        }

        // A whole duplicates build, as `DuplicatesProjection` runs it after a catalog change.
        try await Benchmark.measure("duplicates.build") {
            let built = try await DuplicatesProjection.build(store: store, libraries: libraries)
            #expect(built.groups.contains { $0.id.isSamePhoto })
            #expect(built.groups.contains { !$0.id.isSamePhoto })
        }

        // Its pure pairing step alone: every still without capture metadata tested against
        // its aspect bucket.
        let paths = CatalogWindowPolicy.availablePaths(from: libraries)
        let candidates = try await store.samePhotoCandidates(availableLibraryPaths: paths)
        try await Benchmark.measure("duplicates.samePhotoPairs") {
            #expect(!SamePhotoPolicy.candidatePairs(candidates, excluding: []).isEmpty)
        }
        await store.shutdown()
    }

    /// The Swift around Auto straighten's and Auto crop's models, which runs per photo opened in
    /// Edit, at the sizes a 4:3 photo reads at.
    @Test func editAnalysisCases() async throws {
        // GeoCalib's solve on a 416 × 320 photo's fields.
        let fields = PerspectiveFieldSolver.Fields.camera(
            width: 416, height: 320, roll: 5 * .pi / 180, pitch: 12 * .pi / 180, focal: 380
        )
        try await Benchmark.measure("edit.perspectiveSolve") {
            #expect(PerspectiveFieldSolver.solve(fields) != nil)
        }

        // FocalNet's retention of every candidate crop over a 64 × 64 importance map.
        let grid = AutoCropModel.mapSize, width = 4032, height = 3024
        let values = (0 ..< grid * grid).map { Double(($0 * 37) % 101) / 100 }
        let boxes = AutoCropModel.candidates(width: width, height: height)
        try await Benchmark.measure("edit.cropRetention") {
            let map = ImportanceMap(values)
            let retention = boxes.map {
                map.retention(of: AutoCropModel.pixelBox($0, width: width, height: height), width: width, height: height)
            }
            #expect(retention.contains { $0 > 0.99 })
        }
    }
}
