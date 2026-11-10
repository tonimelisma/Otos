import CoreGraphics
import CoreImage
import Foundation
import ImageIO
@testable import OtosKit
import Testing

/// Face analysis (ADR 0047): the alignment geometry, the admission rules, the opaque crop and
/// the bundled embedding model.
struct FaceAnalyzerTests {
    // MARK: - Alignment

    /// Points that are the template moved by a known rotation, scale and shift align back onto
    /// the template exactly.
    @Test func alignmentUndoesAKnownSimilarity() throws {
        let moved = CGAffineTransform(rotationAngle: 0.35).scaledBy(x: 4.2, y: 4.2).translatedBy(x: 310, y: -45)
        let photoPoints = FaceAlignment.template.map { $0.applying(moved) }

        let transform = try #require(FaceAlignment.similarity(from: photoPoints, to: FaceAlignment.template))

        for (point, target) in zip(photoPoints.map { $0.applying(transform) }, FaceAlignment.template) {
            #expect(abs(point.x - target.x) < 1e-9 && abs(point.y - target.y) < 1e-9)
        }
        #expect(abs(FaceAlignment.scale(of: transform) - 1 / 4.2) < 1e-12)
    }

    /// Points that all coincide have no shape to align, so there is no alignment rather than
    /// an identity one that could pass the admission check.
    @Test func coincidentPointsHaveNoAlignment() {
        let points = Array(repeating: CGPoint(x: 10, y: 10), count: 5)
        #expect(FaceAlignment.similarity(from: points, to: FaceAlignment.template) == nil)
    }

    /// A face is read only when its box height times the alignment scale is about the
    /// template's face height: 50 to 150, inclusive.
    @Test func admissionAcceptsOnlyFaceSizedAlignments() {
        func transform(scale: Double) -> CGAffineTransform {
            CGAffineTransform(scaleX: scale, y: scale)
        }
        #expect(FaceAlignment.admits(boxHeight: 300, transform: transform(scale: 0.31)))
        #expect(FaceAlignment.admits(boxHeight: 100, transform: transform(scale: 0.5)))
        #expect(FaceAlignment.admits(boxHeight: 100, transform: transform(scale: 1.5)))
        #expect(!FaceAlignment.admits(boxHeight: 300, transform: transform(scale: 0.1)))
        #expect(!FaceAlignment.admits(boxHeight: 300, transform: transform(scale: 0.6)))
    }

    // MARK: - The crop

    /// Where the aligned face reaches past the photo's edge, the crop is black and opaque,
    /// never transparent; inside the photo it keeps the photo's pixels.
    @Test func theCropIsOpaqueWhereItReachesPastThePhoto() throws {
        let photo = try Self.solidImage(width: 200, height: 200, red: 255, green: 0, blue: 0)
        // The photo covers only the crop's left half.
        let transform = CGAffineTransform(translationX: CGFloat(FaceAlignment.side / 2) - 200, y: 0)

        let crop = try #require(
            FaceAnalyzer.alignedCrop(of: CIImage(cgImage: photo), transform: transform, context: CIContext())
        )

        #expect(crop.width == FaceAlignment.side && crop.height == FaceAlignment.side)
        let pixels = try Self.rgba(crop)
        let inside = Array(pixels[(56 * 112 + 20) * 4 ..< (56 * 112 + 20) * 4 + 4])
        let outside = Array(pixels[(56 * 112 + 90) * 4 ..< (56 * 112 + 90) * 4 + 4])
        // Core Image renders through its working colour space, so the photo's red comes back
        // within a step of what went in; outside the photo is exactly black.
        #expect(inside[0] >= 254 && inside[1] <= 1 && inside[2] <= 1 && inside[3] == 255)
        #expect(outside == [0, 0, 0, 255])
        #expect(stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 255 })
    }

    // MARK: - The bundled model

    /// The model loads from the framework and reads a crop as a unit-length 512-d embedding,
    /// the same every time; a different crop reads differently.
    @Test func theBundledModelEmbedsACropTheSameWayEveryTime() throws {
        let model = try FaceEmbeddingModel(bundle: Bundle(for: CatalogWindowViewModel.self))
        let crop = try Self.patternImage(seed: 1)

        let first = try model.embedding(of: crop)
        let second = try model.embedding(of: crop)
        let other = try model.embedding(of: Self.patternImage(seed: 2))

        #expect(first.count == FaceEmbeddingModel.dimensions)
        #expect(abs(Self.dot(first, first) - 1) < 1e-3)
        #expect(first == second)
        #expect(Self.dot(first, other) < 0.99)
    }

    /// A photo with no face in it has no faces and no rejections.
    @Test func aPhotoWithoutAFaceHasNoFaces() async throws {
        let analyzer = FaceAnalyzer(bundle: Bundle(for: CatalogWindowViewModel.self))

        let analysis = try await analyzer.analyze(Self.patternImage(seed: 3, size: 640))

        #expect(analysis == FaceAnalysis(
            faces: [], rejectedForQuality: 0, rejectedForAlignment: 0, rejectedForLandmarks: 0
        ))
    }

    // MARK: - Real faces

    /// The whole analysis on real portraits (`OtosTests/Fixtures/Faces`, public domain, sources in its `SOURCES.md`): each
    /// has one face, admitted, with its box and points on the face. One person twelve years
    /// apart reaches the threshold a suggestion needs; a different person stays below it.
    @Test func realPortraitsReadAsTheirPeople() async throws {
        let analyzer = FaceAnalyzer(bundle: Bundle(for: CatalogWindowViewModel.self))
        var faces: [String: DetectedFace] = [:]
        for name in ["williams-2006", "williams-2018", "obama-2013"] {
            let analysis = try await analyzer.analyze(Self.portrait(name))
            #expect(analysis.rejectedForQuality == 0, "\(name)")
            #expect(analysis.rejectedForAlignment == 0, "\(name)")
            #expect(analysis.rejectedForLandmarks == 0, "\(name)")
            let face = try #require(analysis.faces.count == 1 ? analysis.faces.first : nil, "\(name)")
            // A portrait's face sits in the frame's middle, its eyes above its mouth.
            #expect(face.box.midX > 0.3 && face.box.midX < 0.7 && face.box.height > 0.1, "\(name)")
            #expect(face.landmarks[0].x < face.landmarks[1].x, "\(name)")
            #expect(face.landmarks[0].y < face.landmarks[3].y, "\(name)")
            #expect(face.landmarks[1].y < face.landmarks[4].y, "\(name)")
            #expect(abs(Self.dot(face.embedding, face.embedding) - 1) < 1e-3, "\(name)")
            faces[name] = face
        }
        let earlier = try #require(faces["williams-2006"]).embedding
        let later = try #require(faces["williams-2018"]).embedding
        let other = try #require(faces["obama-2013"]).embedding

        let same = Self.dot(earlier, later)
        #expect(same >= FacePeoplePolicy.threshold, "same person \(same)")
        #expect(Self.dot(earlier, other) < FacePeoplePolicy.threshold - FacePeoplePolicy.margin)
        #expect(Self.dot(later, other) < FacePeoplePolicy.threshold - FacePeoplePolicy.margin)
    }

    static func portrait(_ name: String) throws -> CGImage {
        let url = SourceTree.root.appending(path: "OtosTests/Fixtures/Faces/\(name).jpg")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    // MARK: - Images

    static func solidImage(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = red
            pixels[index + 1] = green
            pixels[index + 2] = blue
        }
        return try image(pixels, width: width, height: height)
    }

    /// A deterministic opaque pattern, different for each seed.
    static func patternImage(seed: Int, size: Int = FaceAlignment.side) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0 ..< size {
            for x in 0 ..< size {
                let index = (y * size + x) * 4
                pixels[index] = UInt8((x * 3 + y * seed * 7) % 256)
                pixels[index + 1] = UInt8((x * seed * 5 + y) % 256)
                pixels[index + 2] = UInt8((x ^ y ^ (seed * 31)) % 256)
            }
        }
        return try image(pixels, width: size, height: size)
    }

    private static func image(_ pixels: [UInt8], width: Int, height: Int) throws -> CGImage {
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    /// The image's pixels as sRGB RGBA bytes, top row first.
    static func rgba(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).map(*).reduce(0, +)
    }
}
