import AVFoundation
import CoreGraphics
import CoreML
import Foundation
import ImageIO
@testable import OtosKit
import Testing
import UniformTypeIdentifiers
import VideoToolbox

/// Plan 0116, peak footprint ≤ 700 MB: what the heavy reads of a launch cost the process at
/// their peak, measured in this process (`FootprintPeak`). They run only when asked
/// (`OTOS_SCALE_TEST=1 script/check.sh --only FirstLaunchFootprintTests`), alone, because a
/// peak is the process's: anything else running beside them is in it. Each line goes to
/// `build/measurements/image-memory.log` (`docs/research/2026-11-16-first-launch-footprint.md`).
@Suite(.testScope, .serialized, .enabled(if: ProcessInfo.processInfo.environment["OTOS_SCALE_TEST"] == "1"))
struct FirstLaunchFootprintTests {
    /// A 4K video read for its faces holds one full-resolution frame at a time: two read at
    /// once, as enrichment does (`videoEnrichCap`), stay within the bound.
    /// An iPhone records HDR HEVC (10-bit, HLG); an SDR H.264 is the other kind.
    @Test(arguments: [false, true])
    func twoFourKVideosReadForFacesStayWithinTheBound(hdr: Bool) async throws {
        let directory = try makeTestDirectory()
        let video = directory.appending(path: "uhd.mov")
        try await Self.writeVideo(to: video, width: 3840, height: 2160, hdr: hdr)
        let frames = directory.appending(path: "Thumbnails", directoryHint: .isDirectory)
        // The analysis enrichment runs, its model loaded first so only the reads are measured.
        let analyze = FaceAnalyzer.bundledAnalysis()
        _ = try await analyze(AVAssetImageGenerator(asset: AVURLAsset(url: video)).image(at: .zero).image)
        let peak = try await Self.peakMB {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0 ..< 2 {
                    group.addTask {
                        _ = try await VideoFaceReader.read(
                            AVURLAsset(url: video),
                            analyzeFaces: analyze,
                            framesRelativeName: "uhd-\(index).faces.heic",
                            in: frames
                        )
                    }
                }
                try await group.waitForAll()
            }
        }
        ImageMemoryFixture.record("op=footprint step=twoFourKVideoFaceReads hdr=\(hdr) peakAboveStartMB=\(peak)")
        #expect(peak <= Self.videoFaceReadsBoundMB, "two 4K videos read for faces: \(peak) MB")
    }

    /// The text tower's load when Core ML has no compiled program for it — the first launch
    /// after an install — and again once it has: the compile's own cost, in this process.
    @Test func aModelCompiledInProcessCostsItsPeak() async throws {
        let directory = try makeTestDirectory()
        let bundle = Bundle(for: CatalogWindowViewModel.self)
        let source = try #require(BundledModel.url(named: "SigLIP2Text", in: bundle))
        // A model at a path Core ML has not seen has no compiled program yet.
        let fresh = directory.appending(path: "SigLIP2Text-\(UUID().uuidString).mlmodelc", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: source, to: fresh)
        // The bundle's files are read-only; the copy is made writable so the test directory
        // can be removed.
        for item in try FileManager.default.subpathsOfDirectory(atPath: fresh.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fresh.appending(path: item).path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fresh.path)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = SearchEmbedding.computeUnits
        var cold: MLModel?
        let coldStart = ContinuousClock.now
        let coldPeak = try await Self.peakMB { cold = try MLModel(contentsOf: fresh, configuration: configuration) }
        let coldMs = DiagnosticsTiming.milliseconds(since: coldStart)
        cold = nil
        var warm: MLModel?
        let warmStart = ContinuousClock.now
        let warmPeak = try await Self.peakMB { warm = try MLModel(contentsOf: fresh, configuration: configuration) }
        let warmMs = DiagnosticsTiming.milliseconds(since: warmStart)
        warm = nil
        ImageMemoryFixture.record(
            "op=footprint step=textTowerLoad coldPeakAboveStartMB=\(coldPeak) coldMs=\(coldMs) warmPeakAboveStartMB=\(warmPeak) warmMs=\(warmMs)"
        )
        #expect(warmPeak <= coldPeak)
    }

    /// A new library's first enrichment renders every still's preview on the background lane
    /// at once, as many as the lane admits: 28 photos from a person's cameras (48 MP and 12 MP
    /// HEIC, 24 MP and 12 MP JPEG), every one asked for together, as the enrichment backlog
    /// asks. Their peak stays within the bound.
    @Test func aNewLibrarysStillRendersStayWithinTheBound() async throws {
        let directory = try makeTestDirectory()
        var photos: [URL] = []
        for index in 0 ..< 28 {
            let camera = Self.cameras[index % Self.cameras.count]
            let url = directory.appending(path: "photo-\(index).\(camera.ext)")
            try Self.writePhoto(to: url, width: camera.width, height: camera.height, type: camera.type, seed: index)
            photos.append(url)
        }
        let staging = directory.appending(path: "Thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        // Each still as enrichment makes it: rendered, staged as its HEIC preview and its JPEG
        // thumbnail.
        let peak = try await Self.peakMB {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (index, url) in photos.enumerated() {
                    group.addTask {
                        // Staged on the lane, as `MediaEnricher` stages a still.
                        let staged = try await ImageRenderer.background.render(
                            url, longEdge: ThumbnailStore.previewMaxPixelSize
                        ) { rendered in
                            (try? ThumbnailStore.stagePreview(rendered.image, finalRelativeName: "\(index).heic", in: staging)) != nil
                                && (try? ThumbnailStore.stage(
                                    ThumbnailStore.scaled(rendered.image, toLongEdge: ThumbnailStore.maxPixelSize),
                                    finalRelativeName: "\(index).jpg", in: staging
                                )) != nil
                        }
                        #expect(staged)
                    }
                }
                try await group.waitForAll()
            }
        }
        ImageMemoryFixture.record("op=footprint step=newLibraryStillRenders photos=\(photos.count) peakAboveStartMB=\(peak)")
        #expect(peak <= Self.stillRendersBoundMB, "28 stills rendered on the background lane: \(peak) MB")
    }

    /// One still of each camera rendered alone: what one decode on the lane costs at its peak,
    /// recorded for the research note.
    @Test func eachCamerasStillRenderedAlone() async throws {
        let directory = try makeTestDirectory()
        for (index, camera) in Self.cameras.enumerated() {
            let url = directory.appending(path: "alone-\(index).\(camera.ext)")
            try Self.writePhoto(to: url, width: camera.width, height: camera.height, type: camera.type, seed: index)
            let peak = try await Self.peakMB {
                _ = try await ImageRenderer.background.render(url, longEdge: ThumbnailStore.previewMaxPixelSize)
            }
            ImageMemoryFixture.record(
                "op=footprint step=stillRenderAlone camera=\(camera.width)x\(camera.height).\(camera.ext) peakAboveStartMB=\(peak)"
            )
            #expect(peak <= Self.stillRendersBoundMB)
        }
    }

    /// The cameras a new library's photos come from (as `script/sandbox-library-media.swift`).
    struct Camera {
        let width: Int
        let height: Int
        let type: UTType
        let ext: String
    }

    static let cameras = [
        Camera(width: 8064, height: 6048, type: .heic, ext: "heic"), Camera(width: 4032, height: 3024, type: .heic, ext: "heic"),
        Camera(width: 6000, height: 4000, type: .jpeg, ext: "jpg"), Camera(width: 4032, height: 3024, type: .jpeg, ext: "jpg"),
    ]

    /// A photo of `width` × `height`: shapes on a gradient, drawn from `seed`.
    static func writePhoto(to url: URL, width: Int, height: Int, type: UTType, seed: Int) throws {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        for shape in 0 ..< 24 {
            let value = CGFloat((seed * 31 + shape * 17) % 100) / 100
            context.setFillColor(CGColor(srgbRed: value, green: 1 - value, blue: CGFloat(shape) / 24, alpha: 1))
            context.fillEllipse(in: CGRect(
                x: CGFloat((seed * 397 + shape * 211) % width), y: CGFloat((seed * 211 + shape * 397) % height),
                width: CGFloat(width) / 4, height: CGFloat(height) / 4
            ))
        }
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// What a new library's still renders may add at their peak (measured; see the research note).
    static let stillRendersBoundMB = 300

    /// What two 4K videos read for faces at once may add at their peak (measured; see the
    /// research note).
    static let videoFaceReadsBoundMB = 200

    /// The footprint's peak while `body` runs, above where it started, in MB.
    static func peakMB(_ body: () async throws -> Void) async rethrows -> Int {
        let peak = FootprintPeak()
        let before = ImageMemoryFixture.footprintMB()
        peak.start()
        defer { peak.stop() }
        _ = peak.takeMB()
        try await body()
        return max(0, peak.takeMB() - before)
    }

    /// A video of `width` × `height`, two seconds of a moving gradient: H.264 8-bit, or with
    /// `hdr` HEVC Main 10 in HLG, as an iPhone records.
    static func writeVideo(to url: URL, width: Int, height: Int, hdr: Bool) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [
            AVVideoCodecKey: hdr ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
        ]
        if hdr {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
            ]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let format = hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0 ..< 20 {
            while !input.isReadyForMoreMediaData {
                // time: poll — the writer reports readiness only through this flag here.
                try await Task.sleep(for: .milliseconds(5))
            }
            let pool = try #require(adaptor.pixelBufferPool)
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            let buffer = try #require(made)
            CVPixelBufferLockBaseAddress(buffer, [])
            if hdr {
                // Luma a moving ramp, chroma neutral: 10 bits in the high bits of 16.
                let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt16.self)
                let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
                for y in 0 ..< height {
                    for x in 0 ..< width {
                        luma[y * lumaRow + x] = UInt16(64 + ((x + y + frame * 40) % 876)) << 6
                    }
                }
                let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(to: UInt16.self)
                let chromaCount = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) / 2 * CVPixelBufferGetHeightOfPlane(buffer, 1)
                for index in 0 ..< chromaCount {
                    chroma[index] = 512 << 6
                }
            } else {
                let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
                let row = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0 ..< height {
                    for x in 0 ..< width {
                        let pixel = base + y * row + x * 4
                        pixel[0] = UInt8((x + frame * 40) & 0xFF)
                        pixel[1] = UInt8(y & 0xFF)
                        pixel[2] = UInt8((x + y) & 0xFF)
                        pixel[3] = 0xFF
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error {
            throw error
        }
    }
}
