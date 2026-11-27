#!/usr/bin/env xcrun swift
// Generates the media of a sandbox library (script/sandbox-library.sh): N distinct photos and
// a few short videos, all made here from code, so a tour or a survey has a library that is no
// one's photos. Some carry rendered words (search's text reading finds them), some are skies
// (the tour's "sky" query), a few have an exact copy or a re-encoded version beside them (the
// Duplicates steps: ADR 0042 groups identical bytes, and versions of one capture whose camera,
// instant and sub-seconds agree and whose pixels match), some carry GPS (Places) and some fall
// on today's day in past years (On This Day). Every name starts with the run's prefix, so the
// script can find each file by name wherever it went.
//
// Two sizes. `camera` photos come from a person's cameras in turn (48 MP and 12 MP HEIC, 24 MP
// and 12 MP JPEG) in one folder, so a first launch decodes what a real library holds. `small`
// is for a library of the owner's size (about 160,000 items): 64 × 64 JPEGs of a few KB, each
// drawn from its own index, in a year / month / ten-day folder tree of a few hundred files a
// folder, written in parallel; the features are a small share (one photo in 500 has words, at
// 640 × 480 so text reading can read them; one in 500 has a copy and one a version; one in 50
// has GPS), so every view has something in it without the library being mostly features.
//
// usage: sandbox-library-media.swift <folder> <prefix> <photos> <videos> [camera|small]
// Prints one generated file name per line.

import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Generator {
    /// SplitMix64: the same index draws the same photo, and no two indices draw alike.
    struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func unit() -> CGFloat {
            CGFloat(next() % 1_000_000) / 1_000_000
        }
    }

    static let words = [
        "LIGHTHOUSE", "WELCOME HOME", "RECEIPT 42.10", "EXIT", "MENU OF THE DAY", "PLATFORM 9",
        "OPEN 24 HOURS", "HARBOUR ROAD", "NO PARKING", "BIRTHDAY", "CAFE", "MUSEUM",
    ]
    /// Taken in turn by the photos that carry GPS. The first two are neighbours (Helsinki,
    /// Paris), so a small library's two GPS photos fit one map at its widest zoom on a small
    /// screen, and the Places capture (script/app-capture.sh) shows both stacks.
    static let places: [(Double, Double)] = [
        (60.1699, 24.9384), (48.8566, 2.3522), (37.7749, -122.4194), (35.6762, 139.6503), (-33.8688, 151.2093),
    ]

    enum Size: String {
        case camera
        case small
    }

    let folder: URL
    let prefix: String
    let size: Size
    /// One photo's frame and encoding.
    struct Camera {
        let width: Int
        let height: Int
        let type: UTType
        let ext: String
    }

    /// The cameras `camera` photos come from, in turn: an iPhone's 48 MP and 12 MP HEIC, a
    /// camera's 24 MP JPEG and a 12 MP JPEG, so a launch decodes what a person's library holds.
    static let cameras = [
        Camera(width: 8064, height: 6048, type: .heic, ext: "heic"),
        Camera(width: 4032, height: 3024, type: .heic, ext: "heic"),
        Camera(width: 6000, height: 4000, type: .jpeg, ext: "jpg"),
        Camera(width: 4032, height: 3024, type: .jpeg, ext: "jpg"),
    ]
    static let smallFrame = Camera(width: 64, height: 64, type: .jpeg, ext: "jpg")
    /// Large enough for text reading to read the words.
    static let wordsFrame = Camera(width: 640, height: 480, type: .jpeg, ext: "jpg")

    /// One in `stride` photos is a sign with words, two are skies; one in `stride` is followed
    /// by an exact copy and one by a re-encoded version.
    var stride: Int {
        size == .camera ? 10 : 500
    }

    var duplicateStride: Int {
        size == .camera ? 50 : 500
    }

    func camera(_ index: Int) -> Camera {
        switch size {
        case .camera: Self.cameras[index % Self.cameras.count]
        case .small: index % stride == 0 ? Self.wordsFrame : Self.smallFrame
        }
    }

    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    /// The folder photo `index` is written to, relative to the library: none for `camera`; a
    /// year / month / ten-day folder of its capture date for `small`, so a folder holds a few
    /// hundred files as a person's does.
    func subfolder(_ index: Int) -> String {
        guard size == .small else { return "" }
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: captureDate(index))
        let day = parts.day ?? 1
        let range = day <= 10 ? "01-10" : day <= 20 ? "11-20" : "21-31"
        return String(format: "%04d/%02d/%@", parts.year ?? 0, parts.month ?? 0, range)
    }

    func name(_ index: Int, _ suffix: String = "", ext: String) -> String {
        String(format: "%@-%05d%@.%@", prefix, index, suffix, ext)
    }

    /// One photo's pixels.
    func draw(_ index: Int) -> CGImage {
        var random = Random(state: UInt64(index) &* 7919 &+ 17)
        let width = camera(index).width, height = camera(index).height
        // Sizes are drawn for a 1600-pixel-wide frame and scaled to the camera's.
        let unit = CGFloat(width) / 1600
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
            CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
        switch index % stride {
        case 0:
            // Words on a sign: what search's text reading reads.
            context.setFillColor(color(0.96, 0.95, 0.9))
            context.fill(bounds)
            let word = Self.words[(index / stride) % Self.words.count]
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 150 * unit, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(0.08, 0.08, 0.1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: word, attributes: attributes))
            let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
            context.textPosition = CGPoint(x: max(40 * unit, (CGFloat(width) - lineWidth) / 2), y: CGFloat(height) / 2 - 50 * unit)
            CTLineDraw(line, context)
        case 1, 2:
            // A sky over land, with the sun somewhere in it.
            let sky = CGGradient(colorsSpace: space, colors: [color(0.25, 0.5, 0.92), color(0.7, 0.85, 1)] as CFArray, locations: [0, 1])!
            context.drawLinearGradient(sky, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: 0, y: CGFloat(height) * 0.3), options: [])
            context.setFillColor(color(0.2 + random.unit() * 0.2, 0.45 + random.unit() * 0.2, 0.2))
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height) * (0.2 + random.unit() * 0.15)))
            context.setFillColor(color(1, 0.97, 0.85))
            let sun = (80 + random.unit() * 80) * unit
            context.fillEllipse(in: CGRect(x: random.unit() * (CGFloat(width) - 200 * unit), y: CGFloat(height) * 0.6, width: sun, height: sun))
        default:
            // Shapes on a gradient, drawn from the index alone.
            let ground = CGGradient(
                colorsSpace: space,
                colors: [color(random.unit(), random.unit(), random.unit()), color(random.unit(), random.unit(), random.unit())] as CFArray,
                locations: [0, 1]
            )!
            context.drawLinearGradient(ground, start: .zero, end: CGPoint(x: CGFloat(width), y: CGFloat(height)), options: [])
            for _ in 0 ..< 12 {
                context.setFillColor(color(random.unit(), random.unit(), random.unit()))
                let rect = CGRect(x: random.unit() * CGFloat(width), y: random.unit() * CGFloat(height),
                                  width: (60 + random.unit() * 400) * unit, height: (60 + random.unit() * 400) * unit)
                if random.next() % 2 == 0 {
                    context.fillEllipse(in: rect)
                } else {
                    context.fill(rect)
                }
            }
        }
        return context.makeImage()!
    }

    /// When the generator started: every photo's date is drawn from it, so a photo's date and
    /// folder agree however long the run takes.
    let now = Date()

    /// Capture date: spread over ten years (fifteen for `small`), and every 37th on today's day
    /// in a past year.
    func captureDate(_ index: Int) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        if index % 37 == 5 {
            return calendar.date(byAdding: .year, value: -(1 + index % 9), to: now)!
        }
        let days = size == .camera ? 3650 : 5475
        return now.addingTimeInterval(-Double(1 + index % days) * 86400 - Double(index % 86400))
    }

    /// The URL of a file named `fileName` for photo `index`, its folder made.
    func url(_ index: Int, _ fileName: String) throws -> URL {
        let directory = subfolder(index).isEmpty ? folder : folder.appending(path: subfolder(index), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: fileName)
    }

    /// Writes photo `index`. A version (`suffix` non-empty, `quality` lower) is the same capture
    /// re-encoded: the same pixels and the same camera, instant and sub-seconds, other bytes.
    func writePhoto(_ index: Int, suffix: String = "", quality: Double = 0.8) throws -> String {
        let fileName = name(index, suffix, ext: camera(index).ext)
        let url = try url(index, fileName)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, camera(index).type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Sandbox", kCGImagePropertyTIFFModel: "Camera \(index % Self.cameras.count)"],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: formatter.string(from: captureDate(index)),
                kCGImagePropertyExifSubsecTimeOriginal: String(format: "%03d", index % 1000),
            ],
        ]
        let gpsStride = size == .camera ? 5 : 50
        if index % gpsStride == 3 {
            let (lat, lon) = Self.places[(index / gpsStride) % Self.places.count]
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(lat), kCGImagePropertyGPSLatitudeRef: lat >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(lon), kCGImagePropertyGPSLongitudeRef: lon >= 0 ? "E" : "W",
            ]
        }
        CGImageDestinationAddImage(destination, draw(index), properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return fileName
    }

    /// A two-second H.264 clip whose colour moves from frame to frame.
    func writeVideo(_ index: Int) async throws -> String {
        let fileName = name(index, "-clip", ext: "mov")
        let url = folder.appending(path: fileName)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let space = space
        // The writer asks for frames when it can take them, and says so on its queue.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var frame = 0
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "sandbox-library-media.video")) {
                while input.isReadyForMoreMediaData, frame < 60 {
                    var buffer: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
                    guard let buffer else { break }
                    CVPixelBufferLockBaseAddress(buffer, [])
                    let context = CGContext(
                        data: CVPixelBufferGetBaseAddress(buffer), width: 640, height: 360, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                    )!
                    let phase = CGFloat(frame) / 60
                    context.setFillColor(CGColor(srgbRed: phase, green: 0.4, blue: 1 - phase, alpha: 1))
                    context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
                    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                    context.fillEllipse(in: CGRect(x: 40 + phase * 480, y: 130, width: 100, height: 100))
                    CVPixelBufferUnlockBaseAddress(buffer, [])
                    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
                    frame += 1
                }
                if frame == 60 {
                    frame += 1
                    input.markAsFinished()
                    done.resume()
                }
            }
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        return fileName
    }

    /// Writes the photos with indices in `range` (and the copy or version that follows some of
    /// them) and returns their names in order. A range starts on a multiple of
    /// `duplicateStride`, so a photo and its copy or version fall in the same range.
    func writePhotos(_ range: Range<Int>, of photos: Int) throws -> [String] {
        var names: [String] = []
        var index = range.lowerBound
        while index < range.upperBound {
            let written = try writePhoto(index)
            names.append(written)
            // One photo in `duplicateStride` is followed by an exact copy of its file and one by
            // a version of it re-encoded at a lower quality: an identical group and a same-photo
            // group.
            if index % duplicateStride == 3, index + 1 < photos {
                let copy = name(index, "-copy", ext: camera(index).ext)
                try FileManager.default.copyItem(at: url(index, written), to: url(index, copy))
                names.append(copy)
                index += 1
            } else if index % duplicateStride == 7, index + 1 < photos {
                names.append(try writePhoto(index, suffix: "-version", quality: 0.5))
                index += 1
            }
            index += 1
        }
        return names
    }
}

/// The names each range wrote, collected from the workers.
final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [[String]]
    private var failure: Error?

    init(count: Int) {
        names = Array(repeating: [], count: count)
    }

    func set(_ chunk: Int, _ result: Result<[String], Error>) {
        lock.withLock {
            switch result {
            case let .success(written): names[chunk] = written
            case let .failure(error): failure = failure ?? error
            }
        }
    }

    func collected() throws -> [String] {
        try lock.withLock {
            if let failure { throw failure }
            return names.flatMap(\.self)
        }
    }
}

let arguments = CommandLine.arguments
guard (5 ... 6).contains(arguments.count), let photos = Int(arguments[3]), let videos = Int(arguments[4]), photos >= 0, videos >= 0,
      let size = Generator.Size(rawValue: arguments.count == 6 ? arguments[5] : "camera")
else {
    FileHandle.standardError.write(Data("usage: sandbox-library-media.swift <folder> <prefix> <photos> <videos> [camera|small]\n".utf8))
    exit(2)
}
let generator = Generator(folder: URL(fileURLWithPath: arguments[1], isDirectory: true), prefix: arguments[2], size: size)
// Camera-size photos are written one at a time (a 48 MP frame alone holds about 200 MB);
// small ones in parallel, a thousand to a range.
let chunk = size == .camera ? max(photos, 1) : 1000
let chunks = (photos + chunk - 1) / chunk
let results = Results(count: chunks)
DispatchQueue.concurrentPerform(iterations: chunks) { index in
    let range = index * chunk ..< min(photos, (index + 1) * chunk)
    results.set(index, Result { try generator.writePhotos(range, of: photos) })
}
for name in try results.collected() {
    print(name)
}
for video in 0 ..< videos {
    print(try await generator.writeVideo(video))
}
