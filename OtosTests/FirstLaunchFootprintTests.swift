import AVFoundation
import CoreML
import Foundation
@testable import OtosKit
import Testing
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
