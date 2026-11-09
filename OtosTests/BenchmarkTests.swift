import AppKit
import CoreImage
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

    /// The pure half of a grid structural apply, which the user waits for on every switch of
    /// view: a library of 15,000 photos taken ten a day over 1,500 days, the shape of several
    /// years, where AppKit's snapshot build grows with days × items.
    @Test func gridCases() async throws {
        let dayCount = 1500, perDay = 10
        let ids = (0 ..< dayCount * perDay).map { index in
            MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
                relativePath: MediaRelativePath(rawValue: "DCIM/IMG_\(index).HEIC")
            )
        }
        let days = (0 ..< dayCount * perDay).map { index in
            Optional(Date(timeIntervalSince1970: Double(dayCount - index / perDay) * 86400))
        }
        let grid = CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids, dayBuckets: days)
        try await Benchmark.measure("grid.structureBuild.days1500") {
            let built = await MediaGridViewController.buildStructure(
                for: grid,
                descriptorChanged: true,
                previousOrderedIDs: [],
                previousOrderedIDSet: []
            )
            #expect(built.daySections.count == dayCount)
            #expect(built.snapshot.numberOfItems == ids.count)
        }
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

    /// The work enrichment does for each face it reads (ADR 0047): aligning five points, cutting
    /// the opaque 112 px crop out of a 12-megapixel photo, and the embedding model's prediction.
    /// Alignment and cropping are batched (1,000 and 16) so each case retires enough
    /// instructions to be steady; one alignment alone is lost in the measurement's own cost.
    @Test func faceCases() async throws {
        let moved = CGAffineTransform(rotationAngle: 0.2).scaledBy(x: 5.5, y: 5.5).translatedBy(x: 380, y: 250)
        let points = FaceAlignment.template.map { $0.applying(moved) }
        try await Benchmark.measure("face.align.x1000") {
            var aligned = 0
            for _ in 0 ..< 1000 where FaceAlignment.similarity(from: points, to: FaceAlignment.template) != nil {
                aligned += 1
            }
            #expect(aligned == 1000)
        }

        let photo = try CIImage(cgImage: FaceAnalyzerTests.patternImage(seed: 4, size: 4000))
        let transform = try #require(FaceAlignment.similarity(from: points, to: FaceAlignment.template))
        let context = CIContext()
        try await Benchmark.measure("face.crop.x16") {
            var crops = 0
            for _ in 0 ..< 16 where FaceAnalyzer.alignedCrop(of: photo, transform: transform, context: context) != nil {
                crops += 1
            }
            #expect(crops == 16)
        }

        // Grouping over a library the size of the bake-off's: 3,000 faces, 300 of them
        // confirmed across 10 people, the rest open (ADR 0047).
        let (faces, people) = Self.groupingLibrary(faces: 3000, people: 10, confirmedEach: 30)
        try await Benchmark.measure("people.suggestions") {
            let result = FacePeoplePolicy.suggestions(faces: faces, people: people)
            #expect(!result.suggestions.isEmpty)
        }

        // A family archive's scale: 10,000 faces, 1,000 confirmed across 20 people.
        let (large, largePeople) = Self.groupingLibrary(faces: 10000, people: 20, confirmedEach: 50)
        try await Benchmark.measure("people.suggestions.10k", iterations: 3) {
            let result = FacePeoplePolicy.suggestions(faces: large, people: largePeople)
            #expect(!result.suggestions.isEmpty)
        }
        // Its unnamed grouping alone, on the faces nobody is confirmed near.
        let unconfirmed = large.filter { $0.person == nil }
        try await Benchmark.measure("people.unnamedGroups.9k", iterations: 3) {
            #expect(!FacePeoplePolicy.unnamedGroups(unconfirmed).isEmpty)
        }

        let model = try FaceEmbeddingModel(bundle: Bundle(for: CatalogWindowViewModel.self))
        let crop = try FaceAnalyzerTests.patternImage(seed: 5)
        try await Benchmark.measure("face.embed") {
            let embedding = try model.embedding(of: crop)
            #expect(embedding.count == FaceEmbeddingModel.dimensions)
        }
    }

    /// Faces of `people` people, each a direction in embedding space with small per-face
    /// variation, spread over ten years; the first `confirmedEach` of each person confirmed.
    static func groupingLibrary(faces count: Int, people: Int, confirmedEach: Int) -> ([FaceFact], [PersonFact]) {
        var generator = SplitMix64(seed: 7)
        let root = LibraryRootPath(rawValue: "/Bench")
        var faces: [FaceFact] = []
        for index in 0 ..< count {
            let person = index % people
            var vector = [Float](repeating: 0, count: FaceEmbeddingModel.dimensions)
            vector[person] = 1
            for _ in 0 ..< 8 {
                vector[people + Int(generator.next() % UInt64(FaceEmbeddingModel.dimensions - people))] += 0.15
            }
            let length = vector.map { $0 * $0 }.reduce(0, +).squareRoot()
            faces.append(FaceFact(
                id: FaceID(asset: MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "\(index).jpg")), index: 0),
                captureSeconds: 1_300_000_000 + Double(index) * 105_000,
                embedding: vector.map { $0 / length },
                person: index / people < confirmedEach ? PersonID(rawValue: Int64(person + 1)) : nil,
                isNotFace: false,
                isIgnored: false,
                rejected: []
            ))
        }
        return (faces, (1 ... people).map { PersonFact(id: PersonID(rawValue: Int64($0)), birthdaySeconds: nil) })
    }
}
