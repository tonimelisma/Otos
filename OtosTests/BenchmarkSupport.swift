import Darwin
import Foundation
@testable import OtosKit
import Testing

/// Benchmark support (ADR 0043)
///
/// A benchmark runs one case several times and records two numbers per iteration: the
/// instructions the test process retired, and the wall time. Instructions are the number
/// to compare across commits: they hardly move under machine load, where wall time on a
/// machine running parallel checks swings several-fold. Wall time is kept because it is
/// what a user waits for.
///
/// Benchmarks run only when `script/bench.sh` asks (`OTOS_BENCHMARK=1`), never in
/// `script/check.sh`, and assert no budget: a regression is read from the per-commit
/// history `bench.sh` keeps, not failed by a threshold chosen in advance.
enum Benchmark {
    /// Set by `script/bench.sh`. Xcode's scheme always defines the key, as an empty string
    /// unless the build-setting override is passed, so the value is what is checked.
    static let isEnabled = ProcessInfo.processInfo.environment["OTOS_BENCHMARK"] == "1"

    /// Where results go: `build/benchmarks/results.ndjson` in the checkout these tests were
    /// built from, which `bench.sh` reads after the run.
    static let resultsFile = SourceTree.root.appending(path: "build/benchmarks/results.ndjson")

    struct Result: Encodable {
        let name: String
        let iterations: Int
        /// Median instructions retired per iteration.
        let instructions: UInt64
        /// Largest minus smallest, as a share of the median: how steady the count was.
        let instructionSpread: Double
        let medianMilliseconds: Double
        let minimumMilliseconds: Double
    }

    /// Runs `body` once to warm up, then `iterations` times measured, and records the case.
    @discardableResult
    static func measure(
        _ name: String,
        iterations: Int = 5,
        _ body: () async throws -> Void
    ) async throws -> Result {
        try await body()
        var instructions: [UInt64] = []
        var milliseconds: [Double] = []
        let clock = ContinuousClock()
        for _ in 0 ..< iterations {
            let startInstructions = try retiredInstructions()
            let start = clock.now
            try await body()
            let elapsed = start.duration(to: clock.now)
            try instructions.append(retiredInstructions() - startInstructions)
            milliseconds.append(
                Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            )
        }
        instructions.sort()
        milliseconds.sort()
        let median = instructions[instructions.count / 2]
        let range = instructions[instructions.count - 1] - instructions[0]
        let result = Result(
            name: name,
            iterations: iterations,
            instructions: median,
            instructionSpread: median == 0 ? 0 : Double(range) / Double(median),
            medianMilliseconds: milliseconds[milliseconds.count / 2],
            minimumMilliseconds: milliseconds[0]
        )
        try record(result)
        return result
    }

    /// Instructions this process has retired so far. Process-wide, because a case's work
    /// hops between actors and threads; the suite is serialized so no other test adds to it.
    private static func retiredInstructions() throws -> UInt64 {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        return info.ri_instructions
    }

    private static func record(_ result: Result) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var line = try encoder.encode(result)
        line.append(UInt8(ascii: "\n"))
        try FileManager.default.createDirectory(
            at: resultsFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let handle = try? FileHandle(forWritingTo: resultsFile) else {
            try line.write(to: resultsFile)
            return
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }
}

/// A generated library for benchmarks, shaped like the owner's measured on 2026-11-01
/// (`docs/research/2026-11-01-launch-first-frame-and-duplicates-cost.md`): about 15,000
/// stills, one in nine without capture metadata, a few percent identical copies and a few
/// percent near-identical versions. Every value comes from a fixed seed, so every run and
/// every commit measures the same catalog.
struct BenchmarkLibrary {
    let store: CatalogStore
    let libraries: [CatalogLibraryState]

    static let stillCount = 15000

    private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
    private static let cameraSizes = [
        (4032, 3024), (3024, 4032), (6000, 4000), (4000, 6000), (1920, 1080), (3000, 3000),
    ]
    /// A file without capture metadata is mostly a screenshot or a download, in shapes
    /// cameras do not make; that keeps its comparisons near the owner's.
    private static let strippedSizes = [(1179, 2556), (1170, 2532), (1284, 2778)]

    /// What the fixture writes for the still at one index.
    private struct Still {
        let digest: XXH3Digest128
        let hash: UInt64
        let gray: [UInt8]
        let width: Int
        let height: Int
        let isStripped: Bool
    }

    static func make(in directory: URL) async throws -> BenchmarkLibrary {
        let rootURL = directory.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let store = CatalogStore(
            location: .databaseFile(directory.appending(path: "db/catalog.sqlite")),
            scanner: scanner()
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: rootURL)
        let scanned = try await waitForCatalogStoreState(store) {
            !$0.isScanning && $0.testAssets.count == stillCount
        }
        let assets = scanned.testAssets.sorted { $0.id.relativePath.rawValue < $1.id.relativePath.rawValue }
        let stills = try generatedStills()

        let results = zip(assets, stills).enumerated().map { index, pair in
            let (asset, still) = pair
            let captured = [CaptureTimestampRecord.absolute(instant: baseDate.addingTimeInterval(Double(index / 3)))]
            return EnrichmentResult(
                id: asset.id,
                metadata: AssetMetadata(
                    timestamps: still.isStripped ? [] : captured,
                    cameraModel: still.isStripped ? nil : "ILCE-6700",
                    pixelWidth: still.width,
                    pixelHeight: still.height
                ),
                enrichedKind: .image,
                thumbnailPath: "thumb-\(index).jpg",
                sourceSize: asset.byteSize,
                sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
                contentHash: still.digest
            )
        }
        for start in stride(from: 0, to: results.count, by: 500) {
            _ = await store.applyEnrichmentBatch(Array(results[start ..< min(start + 500, results.count)]))
        }

        let indexByID = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($1.id, $0) })
        let signatures = try await store.renderSignatureCandidates(limit: stillCount).map { candidate in
            let still = try stills[#require(indexByID[candidate.id])]
            return RenderSignatureResult(
                id: candidate.id,
                source: candidate.source,
                signature: RenderSignature(differenceHash: still.hash, gray: still.gray)
            )
        }
        #expect(try await store.applyRenderSignatures(signatures) == stillCount)
        let libraries = try #require(await store.loadedLibraries())
        return BenchmarkLibrary(store: store, libraries: libraries)
    }

    /// One in forty stills is an identical copy of the one before it; one in eleven is a
    /// version of it — the same shape, a hash a few bits away and a render a few levels
    /// away; one in nine has no capture metadata. The rest are unrelated pictures.
    private static func generatedStills() throws -> [Still] {
        var random = SplitMix64(seed: 0x0705)
        var stills: [Still] = []
        for index in 0 ..< stillCount {
            let previous = stills.last
            let isStripped = index % 9 == 0
            let digest = if index % 40 == 1, let previous {
                previous.digest
            } else {
                try #require(XXH3Digest128(data: Data((0 ..< 16).map { _ in
                    UInt8.random(in: 0 ... 255, using: &random)
                })))
            }
            if index % 11 == 1, let previous {
                stills.append(Still(
                    digest: digest,
                    hash: previous.hash ^ (1 << UInt64(index % 64)) ^ (1 << UInt64((index * 7) % 64)),
                    gray: previous.gray.map { $0 &+ UInt8.random(in: 0 ... 3, using: &random) },
                    width: previous.width,
                    height: previous.height,
                    isStripped: isStripped
                ))
            } else {
                let (width, height) = isStripped
                    ? strippedSizes[index % strippedSizes.count]
                    : cameraSizes[index % cameraSizes.count]
                stills.append(Still(
                    digest: digest,
                    hash: random.next(),
                    gray: (0 ..< RenderSignature.grayEdge * RenderSignature.grayEdge).map { _ in
                        UInt8.random(in: 0 ... 255, using: &random)
                    },
                    width: width,
                    height: height,
                    isStripped: isStripped
                ))
            }
        }
        return stills
    }

    /// Files with distinct paths and dates; their bytes are never read.
    private static func scanner() -> CatalogScanner {
        CatalogScanner { _, _, batchHandler in
            let files = (0 ..< stillCount).map { index in
                ScannedMediaFile(
                    relativePath: MediaRelativePath(rawValue: String(format: "IMG_%06d.jpg", index)),
                    name: String(format: "IMG_%06d.jpg", index),
                    contentTypeIdentifier: "public.jpeg",
                    byteSize: 4,
                    createdAt: baseDate.addingTimeInterval(Double(index)),
                    contentModifiedAt: baseDate.addingTimeInterval(Double(index))
                )
            }
            try await batchHandler(files)
            return .mediaOnly(Set(files.map(\.relativePath)))
        }
    }
}

/// A seeded generator, so a benchmark's catalog is the same on every run.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// A generated library of RAW+JPEG pairs (ADR 0052), shaped like the owner's catalog on
/// 2026-11-13: a few files in each of thousands of folders, a RAW in every folder. Each of
/// 3,000 folders holds two pairs and one JPEG alone, so the window shows 9,000 tiles for
/// 15,000 files.
struct BenchmarkPairLibrary {
    let store: CatalogStore
    let libraries: [CatalogLibraryState]

    static let folderCount = 3000
    static let fileCount = folderCount * 5
    static let tileCount = folderCount * 3

    static func make(in directory: URL) async throws -> BenchmarkPairLibrary {
        let rootURL = directory.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let store = CatalogStore(
            location: .databaseFile(directory.appending(path: "db/catalog.sqlite")),
            scanner: scanner()
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: rootURL)
        _ = try await waitForCatalogStoreState(store) {
            !$0.isScanning && $0.testAssets.count == fileCount
        }
        let libraries = try #require(await store.loadedLibraries())
        return BenchmarkPairLibrary(store: store, libraries: libraries)
    }

    /// Files with distinct paths and dates; their bytes are never read.
    private static func scanner() -> CatalogScanner {
        CatalogScanner { _, _, batchHandler in
            let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
            var files: [ScannedMediaFile] = []
            files.reserveCapacity(fileCount)
            for folder in 0 ..< folderCount {
                let names = ["DSC0.ARW", "DSC0.JPG", "DSC1.ARW", "DSC1.JPG", "DSC2.JPG"]
                for (offset, name) in names.enumerated() {
                    let isRaw = name.hasSuffix(".ARW")
                    let date = baseDate.addingTimeInterval(Double(folder * 10 + offset / 2))
                    files.append(ScannedMediaFile(
                        relativePath: MediaRelativePath(rawValue: String(format: "%04d/", folder) + name),
                        name: name,
                        contentTypeIdentifier: isRaw ? "com.sony.arw-raw-image" : "public.jpeg",
                        byteSize: 4,
                        createdAt: date,
                        contentModifiedAt: date,
                        kind: isRaw ? .raw : .image
                    ))
                }
            }
            try await batchHandler(files)
            return .mediaOnly(Set(files.map(\.relativePath)))
        }
    }
}
