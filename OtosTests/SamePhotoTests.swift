import CoreGraphics
import Foundation
import MediaMetadata
@testable import OtosKit
import Testing

/// ADR 0042: versions of the same photo group, separate captures never do — whatever the
/// pixels say — and nothing reads an original.
@Suite(.testScope)
struct SamePhotoTests {
    private static let root = LibraryRootPath(rawValue: "/Users/me/Photos")

    private static func gray(_ value: UInt8, noise: [Int: UInt8] = [:]) -> [UInt8] {
        var pixels = [UInt8](repeating: value, count: RenderSignature.grayEdge * RenderSignature.grayEdge)
        for (index, bump) in noise {
            pixels[index] = bump
        }
        return pixels
    }

    /// A still as the rule sees it: its column facts, and the details read for a proposed
    /// pair — the copy, the render and the sub-seconds.
    private struct Still {
        let candidate: SamePhotoCandidate
        let copy: DuplicateCopy
        let subsecond: String?
    }

    private static func still(
        _ path: String,
        raw: Bool = false,
        drawnBy: EnrichedRendering.Origin = .otos,
        instant: Double? = 1000,
        subsecond: String? = nil,
        model: String? = "ILCE-6700",
        hash: UInt64 = 0xF0F0,
        width: Int = 4000,
        in library: LibraryRootPath = root
    ) -> Still {
        let id = MediaAssetID(libraryRootPath: library, relativePath: MediaRelativePath(rawValue: path))
        return Still(
            candidate: SamePhotoCandidate(
                id: id,
                isRaw: raw,
                drawnBy: drawnBy,
                captureInstant: instant,
                cameraModel: instant == nil ? nil : model,
                serialNumber: nil,
                aspectRatio: 4.0 / 3.0,
                differenceHash: hash,
                evidenceStamp: SamePhotoEvidenceStamp(
                    signatureSource: path, recordSize: nil, recordMTime: nil, recordRevision: nil
                )
            ),
            copy: DuplicateCopy(
                id: id,
                libraryDisplayName: "Photos", libraryKind: .library,
                kind: .image,
                captureLocalTime: instant.map(CaptureLocalTime.init(seconds:)),
                byteSize: 1000,
                createdAt: nil,
                pixelWidth: width,
                pixelHeight: width * 3 / 4,
                mediaChoice: .notRated,
                isEdited: false,
                hasCompanions: false
            ),
            subsecond: subsecond
        )
    }

    private static func groups(
        _ stills: [Still],
        signatures: [String: [UInt8]]
    ) -> [Set<String>] {
        builtGroups(stills, signatures: signatures).map { Set($0.copies.map(\.id.relativePath.rawValue)) }
    }

    private static func builtGroups(
        _ stills: [Still],
        signatures: [String: [UInt8]]
    ) -> [DuplicateGroup] {
        let evidence = Dictionary(uniqueKeysWithValues: stills.compactMap { still in
            signatures[still.candidate.id.relativePath.rawValue].flatMap { gray in
                RenderSignature(differenceHash: still.candidate.differenceHash, gray: gray).map { signature in
                    (still.candidate.id, SamePhotoEvidence(signature: signature, fractionalSecondDigits: still.subsecond))
                }
            }
        })
        let pairs = SamePhotoPolicy.candidatePairs(stills.map(\.candidate), excluding: [], reach: .acrossLibraries)
        let members = SamePhotoPolicy.members(pairs: pairs, evidence: evidence)
        let copies = Dictionary(uniqueKeysWithValues: stills.map { ($0.candidate.id, $0.copy) })
        return SamePhotoPolicy.groups(members, copies: copies)
    }

    /// The camera's own file is kept, even against a stripped copy with more pixels; among
    /// originals, the one with the most pixels.
    @Test func theCameraOriginalWithTheMostPixelsIsKept() throws {
        let stripped = try #require(Self.builtGroups([
            Self.still("IMG_1.HEIC", subsecond: "387", width: 1600),
            Self.still("Upscaled/IMG_1.jpg", instant: nil, width: 4000),
        ], signatures: [
            "IMG_1.HEIC": Self.gray(90),
            "Upscaled/IMG_1.jpg": Self.gray(90, noise: [0: 92]),
        ]).first)
        #expect(stripped.defaultKeep.map { Set($0.map(\.relativePath.rawValue)) } == ["IMG_1.HEIC"])

        let originals = try #require(Self.builtGroups([
            Self.still("Small/IMG_1.HEIC", subsecond: "387", width: 1600),
            Self.still("IMG_1.HEIC", subsecond: "387", width: 4000),
        ], signatures: [
            "Small/IMG_1.HEIC": Self.gray(90, noise: [3: 91]),
            "IMG_1.HEIC": Self.gray(90),
        ]).first)
        #expect(originals.defaultKeep.map { Set($0.map(\.relativePath.rawValue)) } == ["IMG_1.HEIC"])
    }

    @Test func burstFramesNeverGroupEvenWithIdenticalPixels() {
        let frames = [
            Self.still("DSC_1.ARW", raw: true, subsecond: "123"),
            Self.still("DSC_2.ARW", raw: true, subsecond: "707"),
        ]
        #expect(Self.groups(frames, signatures: ["DSC_1.ARW": Self.gray(90), "DSC_2.ARW": Self.gray(90)]).isEmpty)
    }

    /// Six frames of one second whose records carry no sub-seconds — the file has none, or
    /// the record predates the reader reporting them — prove nothing, so they never group.
    @Test func sameSecondFramesWithoutSubsecondsNeverGroup() {
        let names = ["20261004_152305.arw"] + (1 ... 5).map { "20261004_152305_00\($0).arw" }
        let frames = names.map { Self.still($0, raw: true) }
        let signatures = Dictionary(uniqueKeysWithValues: names.map { ($0, Self.gray(90)) })
        #expect(Self.groups(frames, signatures: signatures).isEmpty)

        let oneSideKnown = [
            Self.still("IMG_1.HEIC", subsecond: "387"),
            Self.still("IMG_2.HEIC"),
        ]
        #expect(Self.groups(oneSideKnown, signatures: ["IMG_1.HEIC": Self.gray(90), "IMG_2.HEIC": Self.gray(90)]).isEmpty)
    }

    @Test func aResizedStrippedCopyGroupsWithItsSource() {
        let candidates = [
            Self.still("IMG_1.HEIC", subsecond: "387"),
            Self.still("WhatsApp/IMG-1.jpg", instant: nil),
        ]
        let found = Self.groups(candidates, signatures: [
            "IMG_1.HEIC": Self.gray(90),
            "WhatsApp/IMG-1.jpg": Self.gray(90, noise: [0: 92, 5: 88]),
        ])
        #expect(found == [["IMG_1.HEIC", "WhatsApp/IMG-1.jpg"]])
    }

    @Test func aStrippedCopyEquallyCloseToTwoFramesJoinsNeither() {
        let candidates = [
            Self.still("DSC_1.JPG", subsecond: "123"),
            Self.still("DSC_2.JPG", subsecond: "707"),
            Self.still("Downloads/photo.jpg", instant: nil),
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
            Self.still("DSC_1.ARW", raw: true, subsecond: "123"),
            Self.still("DSC_1.JPG", subsecond: "123"),
        ]
        #expect(Self.groups(candidates, signatures: ["DSC_1.ARW": Self.gray(90), "DSC_1.JPG": Self.gray(90)]).isEmpty)
    }

    /// ADR 0046 §7: an account's thumbnail is Immich's image until Otos renders the
    /// original, and the two pipelines' images of one photo are not compared.
    @Test func aSourceDrawnAndAnOtosRenderedThumbnailNeverPair() {
        let candidates = [
            Self.still("Pictures/IMG_1.JPG", subsecond: "123"),
            Self.still("asset-1/IMG_1.JPG", drawnBy: .source, subsecond: "123"),
        ]
        #expect(SamePhotoPolicy.candidatePairs(candidates.map(\.candidate), excluding: [], reach: .acrossLibraries).isEmpty)
        let sameSource = [
            Self.still("asset-1/IMG_1.JPG", drawnBy: .source, subsecond: "123"),
            Self.still("asset-2/IMG_1.JPG", drawnBy: .source, subsecond: "123"),
        ]
        #expect(SamePhotoPolicy.candidatePairs(sameSource.map(\.candidate), excluding: [], reach: .acrossLibraries).count == 1)
    }

    /// ADR 0042: while Duplicates compares within each library, a version in another
    /// library is never proposed, so no group of versions spans two.
    @Test func versionsInTwoLibrariesPairOnlyWhenDuplicatesComparesAcrossThem() {
        let mirror = LibraryRootPath(rawValue: "/Users/me/Mirror")
        let acrossTwo = [
            Self.still("IMG_1.JPG", subsecond: "123"),
            Self.still("IMG_1.JPG", subsecond: "123", in: mirror),
        ].map(\.candidate)
        #expect(SamePhotoPolicy.candidatePairs(acrossTwo, excluding: [], reach: .withinEachLibrary).isEmpty)
        #expect(SamePhotoPolicy.candidatePairs(acrossTwo, excluding: [], reach: .acrossLibraries).count == 1)
        let inOne = [Self.still("a/IMG_1.JPG", subsecond: "123"), Self.still("b/IMG_1.JPG", subsecond: "123")]
        #expect(SamePhotoPolicy.candidatePairs(inOne.map(\.candidate), excluding: [], reach: .withinEachLibrary).count == 1)
    }

    /// The proposed pairs are exactly the pairs of eligible stills in one bucket — library while
    /// compared within each, kind, pipeline and display aspect — that pass the column checks,
    /// each once: the pass's buckets and instants are a layout of positions, so this holds
    /// against a test of every pair on a random library of two roots, an exclusion included.
    @Test func theProposedPairsAreEveryCandidatePairOfABucket() {
        let mirror = LibraryRootPath(rawValue: "/Users/me/Mirror")
        var random = SplitMix64(seed: 0x5A11)
        let candidates = (0 ..< 400).map { index in
            let raw = random.next() % 5 == 0
            let instant: Double? = random.next() % 4 == 0 ? nil : Double(random.next() % 12)
            let aspect: Double? = random.next() % 20 == 0 ? nil : [4.0 / 3.0, 3.0 / 2.0, 16.0 / 9.0][Int(random.next() % 3)]
            return SamePhotoCandidate(
                id: MediaAssetID(
                    libraryRootPath: index % 3 == 0 ? mirror : Self.root,
                    relativePath: MediaRelativePath(rawValue: "IMG_\(index).JPG")
                ),
                isRaw: raw,
                drawnBy: random.next() % 6 == 0 ? .source : .otos,
                captureInstant: instant,
                cameraModel: instant == nil ? nil : ["A", "B"][Int(random.next() % 2)],
                serialNumber: random.next() % 2 == 0 ? nil : "S",
                aspectRatio: aspect,
                differenceHash: 0xF0F0 ^ (UInt64(1) << (random.next() % 16)) ^ (random.next() % 3 == 0 ? UInt64.max << 40 : 0),
                evidenceStamp: SamePhotoEvidenceStamp(signatureSource: "\(index)", recordSize: nil, recordMTime: nil, recordRevision: nil)
            )
        }
        let excluded: Set<MediaAssetID> = [candidates[7].id, candidates[8].id]
        for reach in [DuplicatesReach.withinEachLibrary, .acrossLibraries] {
            func key(_ pair: SamePhotoPair) -> Set<String> {
                [pair.left.id.relativePath.rawValue, pair.right.id.relativePath.rawValue]
            }
            let proposed = SamePhotoPolicy.candidatePairs(candidates, excluding: excluded, reach: reach).map(key)
            let eligible = candidates.filter { $0.aspectRatio != nil && !excluded.contains($0.id) }
            var expected: [Set<String>] = []
            for (position, left) in eligible.enumerated() {
                for right in eligible[(position + 1)...]
                    where reach.library(of: left.id) == reach.library(of: right.id)
                    && Int(((left.aspectRatio ?? 0) * 100).rounded()) == Int(((right.aspectRatio ?? 0) * 100).rounded())
                    && SamePhotoPolicy.isCandidate(left, right)
                {
                    expected.append(key(SamePhotoPair(left: left, right: right)))
                }
            }
            #expect(proposed.count == Set(proposed).count, "\(reach): a pair proposed twice")
            #expect(Set(proposed) == Set(expected), "\(reach)")
            #expect(!expected.isEmpty)
        }
    }

    @Test func farHashesAreNotEvenCompared() {
        let candidates = [
            Self.still("a.jpg", subsecond: "1", hash: 0),
            Self.still("b.jpg", subsecond: "1", hash: UInt64.max),
        ]
        #expect(SamePhotoPolicy.candidatePairs(candidates.map(\.candidate), excluding: [], reach: .acrossLibraries).isEmpty)
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

    @Test func theMeanDifferenceIsTheExactAverageOfPixelDifferences() throws {
        let black = try #require(RenderSignature(differenceHash: 0, gray: Self.gray(0)))
        let white = try #require(RenderSignature(differenceHash: 0, gray: Self.gray(255)))
        #expect(black.meanDifference(to: white) == 255)
        let base = try #require(RenderSignature(differenceHash: 0, gray: Self.gray(90)))
        let bumped = try #require(RenderSignature(differenceHash: 0, gray: Self.gray(90, noise: [0: 93, 9: 89])))
        #expect(base.meanDifference(to: bumped) == 4.0 / 1024)
        #expect(bumped.meanDifference(to: base) == 4.0 / 1024)
    }

    @Test func aSignatureIsWrittenOnlyForTheThumbnailItWasReadFrom() async throws {
        let temp = try makeTestDirectory()
        let library = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try writeCatalogStoreFile(library.appending(path: "a.jpg"), contents: "jpeg")
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
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

        let candidates = try await store.backgroundReads.renderSignatureCandidates(limit: 10).candidates
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
        #expect(try await store.backgroundReads.renderSignatureCandidates(limit: 10).candidates.isEmpty)

        // The still is offered for pairing by its column facts and the stamp its evidence is
        // read at; its evidence carries the signature, and its copy is the one a group lists.
        let paired = try await store.backgroundReads.samePhotoCandidates(availableLibraryPaths: [id.libraryRootPath])
        #expect(paired.map(\.id) == [id])
        #expect(paired.first?.differenceHash == 42)
        #expect(paired.first?.evidenceStamp.signatureSource == candidate.source)
        let evidence = try #require(try await store.backgroundReads.samePhotoEvidence(for: [id])[id])
        #expect(evidence.signature == signature)
        let copy = try #require(try await store.backgroundReads.samePhotoCopies(for: [id])[id])
        #expect(copy.id == id)
        #expect(copy.libraryDisplayName == "Pictures")
        #expect(copy.byteSize == scanned.testAssets.first?.byteSize)
        await store.shutdown()
    }
}
