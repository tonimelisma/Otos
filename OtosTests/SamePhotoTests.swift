import CoreGraphics
import Foundation
import MediaMetadata
@testable import OtosKit
import Testing

/// ADR 0042: versions of the same photo group, separate captures never do — whatever the
/// pixels say — and nothing reads an original.
@Suite(.testDirectory)
struct SamePhotoTests {
    private static let root = LibraryRootPath(rawValue: "/Users/me/Photos")

    private static func gray(_ value: UInt8, noise: [Int: UInt8] = [:]) -> [UInt8] {
        var pixels = [UInt8](repeating: value, count: RenderSignature.grayEdge * RenderSignature.grayEdge)
        for (index, bump) in noise {
            pixels[index] = bump
        }
        return pixels
    }

    private static func candidate(
        _ path: String,
        raw: Bool = false,
        instant: Double? = 1000,
        subsecond: String? = nil,
        model: String? = "ILCE-6700",
        burst: String? = nil,
        hash: UInt64 = 0xF0F0
    ) -> SamePhotoCandidate {
        SamePhotoCandidate(
            copy: DuplicateCopy(
                id: MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: path)),
                libraryDisplayName: "Photos",
                byteSize: 1000,
                createdAt: nil,
                pixelWidth: 4000,
                pixelHeight: 3000,
                mediaChoice: .notRated,
                isEdited: false,
                hasCompanions: false
            ),
            isRaw: raw,
            captureInstant: instant,
            fractionalSecondDigits: subsecond,
            cameraModel: instant == nil ? nil : model,
            serialNumber: nil,
            burstIdentifier: burst,
            aspectRatio: 4.0 / 3.0,
            differenceHash: hash
        )
    }

    private static func groups(
        _ candidates: [SamePhotoCandidate],
        signatures: [String: [UInt8]]
    ) -> [Set<String>] {
        let byID = Dictionary(uniqueKeysWithValues: candidates.compactMap { candidate in
            signatures[candidate.copy.id.relativePath.rawValue].flatMap { gray in
                RenderSignature(differenceHash: candidate.differenceHash, gray: gray).map { (candidate.copy.id, $0) }
            }
        })
        return SamePhotoPolicy.groups(candidates: candidates, signatures: byID, excluding: [])
            .map { Set($0.copies.map(\.id.relativePath.rawValue)) }
    }

    @Test func burstFramesNeverGroupEvenWithIdenticalPixels() {
        let frames = [
            Self.candidate("DSC_1.ARW", raw: true, subsecond: "123"),
            Self.candidate("DSC_2.ARW", raw: true, subsecond: "707"),
        ]
        #expect(Self.groups(frames, signatures: ["DSC_1.ARW": Self.gray(90), "DSC_2.ARW": Self.gray(90)]).isEmpty)

        let iPhoneBurst = [
            Self.candidate("IMG_1.HEIC", burst: "A"),
            Self.candidate("IMG_2.HEIC", burst: "B"),
        ]
        #expect(Self.groups(iPhoneBurst, signatures: ["IMG_1.HEIC": Self.gray(90), "IMG_2.HEIC": Self.gray(90)]).isEmpty)
    }

    @Test func aResizedStrippedCopyGroupsWithItsSource() {
        let candidates = [
            Self.candidate("IMG_1.HEIC", subsecond: "387"),
            Self.candidate("WhatsApp/IMG-1.jpg", instant: nil),
        ]
        let found = Self.groups(candidates, signatures: [
            "IMG_1.HEIC": Self.gray(90),
            "WhatsApp/IMG-1.jpg": Self.gray(90, noise: [0: 92, 5: 88]),
        ])
        #expect(found == [["IMG_1.HEIC", "WhatsApp/IMG-1.jpg"]])
    }

    @Test func aStrippedCopyEquallyCloseToTwoFramesJoinsNeither() {
        let candidates = [
            Self.candidate("DSC_1.JPG", subsecond: "123"),
            Self.candidate("DSC_2.JPG", subsecond: "707"),
            Self.candidate("Downloads/photo.jpg", instant: nil),
        ]
        let found = Self.groups(candidates, signatures: [
            "DSC_1.JPG": Self.gray(90),
            "DSC_2.JPG": Self.gray(90, noise: [3: 91]),
            "Downloads/photo.jpg": Self.gray(90, noise: [7: 91]),
        ])
        #expect(found.isEmpty)
    }

    @Test func aRawAndAProcessedFileNeverGroup() {
        let candidates = [
            Self.candidate("DSC_1.ARW", raw: true, subsecond: "123"),
            Self.candidate("DSC_1.JPG", subsecond: "123"),
        ]
        #expect(Self.groups(candidates, signatures: ["DSC_1.ARW": Self.gray(90), "DSC_1.JPG": Self.gray(90)]).isEmpty)
    }

    @Test func farHashesAreNotEvenCompared() {
        let candidates = [
            Self.candidate("a.jpg", subsecond: "1", hash: 0),
            Self.candidate("b.jpg", subsecond: "1", hash: UInt64.max),
        ]
        #expect(SamePhotoPolicy.candidatePairs(candidates, excluding: []).isEmpty)
    }

    @Test func aSignatureOfOneImageMatchesItself() throws {
        let context = try #require(CGContext(
            data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        for column in 0 ..< 64 {
            context.setFillColor(gray: CGFloat(column) / 63, alpha: 1)
            context.fill(CGRect(x: column, y: 0, width: 1, height: 48))
        }
        let image = try #require(context.makeImage())
        let signature = try #require(RenderSignature(image: image))
        #expect(signature.gray.count == 1024)
        #expect(signature.meanDifference(to: signature) == 0)
        #expect(signature.hammingDistance(to: signature) == 0)
        // A left-to-right gradient brightens at nearly every step of the 9 × 8 hash.
        #expect(signature.differenceHash.nonzeroBitCount > 48)
    }

    @Test func subsecondDigitsRoundTripThroughTheStoredRecord() {
        let time = CaptureTime(
            year: 2026, month: 9, day: 22, hour: 11, minute: 55, second: 6,
            utcOffsetSeconds: -25200, instant: Date(timeIntervalSince1970: 1_790_000_000),
            precision: .localWithOffset, fractionalSecondDigits: "387"
        )
        let record = CaptureTimestampRecord(role: .original, time: time)
        #expect(record.fractionalSecondDigits == "387")
        #expect(CaptureTime(record: record)?.fractionalSecondDigits == "387")
    }

    @Test func aSignatureIsWrittenOnlyForTheThumbnailItWasReadFrom() async throws {
        let temp = try makeTestDirectory()
        let library = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try writeCatalogStoreFile(library.appending(path: "a.jpg"), contents: "jpeg")
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: library)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let id = try #require(scanned.testAssets.first?.id)
        _ = await store.applyEnrichmentBatch([EnrichmentResult(
            id: id,
            metadata: AssetMetadata(),
            enrichedKind: .image,
            thumbnailPath: "a-thumb.jpg",
            sourceSize: scanned.testAssets.first?.byteSize ?? 0,
            sourceMTimeSeconds: MediaAsset.mtimeSeconds(scanned.testAssets.first?.contentModifiedAt),
            contentHash: nil
        )])

        let candidates = try await store.renderSignatureCandidates(limit: 10)
        let candidate = try #require(candidates.first)
        #expect(candidates.map(\.id) == [id])

        let signature = try #require(RenderSignature(differenceHash: 42, gray: Self.gray(7)))
        // A source from a thumbnail since replaced writes nothing.
        #expect(try await store.applyRenderSignatures([
            RenderSignatureResult(id: id, source: "stale", signature: signature),
        ]) == 0)
        #expect(try await store.applyRenderSignatures([
            RenderSignatureResult(id: id, source: candidate.source, signature: signature),
        ]) == 1)
        #expect(try await store.renderSignatureCandidates(limit: 10).isEmpty)
        #expect(try await store.renderSignatures(for: [id])[id] == signature)
        await store.shutdown()
    }
}
