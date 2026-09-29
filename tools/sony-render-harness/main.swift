import CoreImage
import Darwin
import Foundation
import ImageIO
import simd
import Vision

enum PairRole: String, Decodable { case training, selection, regression, acceptance }

struct Pair: Decodable {
    let id: String
    let raw: String
    let target: String
    let session: String
    let role: PairRole
}

struct Manifest: Decodable { let pairs: [Pair] }

enum HarnessError: Error {
    case usage, unavailableOriginal, decodeFailed(String), decoderUnavailable
    case incompatibleDimensions, registrationFailed, malformedReferenceData
    case invalidManifest, partialEvaluation
}

let numericContext = CIContext(options: [
    .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
    .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false,
])
let colorContext = CIContext(options: [
    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
    .cacheIntermediates: false,
])
let encodedSpace = CGColorSpace(name: CGColorSpace.extendedSRGB)!
let displaySpace = CGColorSpace(name: CGColorSpace.sRGB)!

func localData(_ path: String) throws -> Data {
    var info = stat()
    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
          (info.st_flags & 0x4000_0000) == 0
    else { throw HarnessError.unavailableOriginal }
    return try Data(contentsOf: URL(fileURLWithPath: path))
}

func zeroOrigin(_ image: CIImage) -> CIImage {
    image.transformed(by: CGAffineTransform(
        translationX: -image.extent.minX, y: -image.extent.minY
    ))
}

func scaled(_ image: CIImage, longEdge: CGFloat = 768) -> CIImage {
    let original = zeroOrigin(image)
    let factor = longEdge / max(original.extent.width, original.extent.height)
    return zeroOrigin(original.applyingFilter("CILanczosScaleTransform", parameters: [
        kCIInputScaleKey: factor, kCIInputAspectRatioKey: 1,
    ]))
}

func encodedImage(_ image: CIImage) throws -> CIImage {
    guard image.extent.width.isFinite, image.extent.height.isFinite,
          !image.extent.isEmpty
    else {
        throw HarnessError.decodeFailed("invalid extent \(image.extent)")
    }
    guard let cg = colorContext.createCGImage(image, from: image.extent,
                                              format: .RGBAh, colorSpace: encodedSpace)
    else { throw HarnessError.decodeFailed("encoded image conversion") }
    return CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
}

func frame(_ image: CIImage, width: Int, height: Int) -> RGBFrame {
    var pixels = [Float](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { bytes in
        numericContext.render(image, toBitmap: bytes.baseAddress!, rowBytes: width * 16,
                              bounds: CGRect(x: 0, y: 0, width: width, height: height),
                              format: .RGBAf, colorSpace: nil)
    }
    return RGBFrame(width: width, height: height, rgba: pixels)
}

func image(_ pixels: RGBFrame) -> CIImage {
    CIImage(bitmapData: pixels.rgba.withUnsafeBytes { Data($0) },
            bytesPerRow: pixels.width * 16,
            size: CGSize(width: pixels.width, height: pixels.height),
            format: .RGBAf, colorSpace: nil)
}

func registrationImage(_ image: CIImage) throws -> CGImage {
    guard let cg = numericContext.createCGImage(image, from: image.extent,
                                                format: .RGBA8, colorSpace: displaySpace)
    else { throw HarnessError.decodeFailed("registration image conversion") }
    return cg
}

/// Vision reports a homography in its image-coordinate convention. Test its two
/// directions and y-axis conventions against the same fixed interior; record the
/// selected orientation rather than allowing a silent registration fallback.
func perspective(_ image: CIImage, matrix: simd_float3x3,
                 size: CGSize, flipY: Bool) -> CIImage
{
    let width = image.extent.width, height = image.extent.height
    func point(_ x: CGFloat, _ y: CGFloat) -> CIVector {
        let py = flipY ? height - y : y
        let v = matrix * SIMD3<Float>(Float(x / width * size.width),
                                      Float(py / height * size.height), 1)
        let mappedX = CGFloat(v.x / v.z) / size.width * width
        let mappedY = CGFloat(v.y / v.z) / size.height * height
        return CIVector(x: mappedX, y: flipY ? height - mappedY : mappedY)
    }
    return image.applyingFilter("CIPerspectiveTransform", parameters: [
        "inputTopLeft": point(0, height),
        "inputTopRight": point(width, height),
        "inputBottomLeft": point(0, 0),
        "inputBottomRight": point(width, 0),
    ])
}

func interiorMSE(_ a: RGBFrame, _ b: RGBFrame) -> Double {
    var total = 0.0, count = 0
    for y in 16 ..< a.height - 16 {
        for x in 16 ..< a.width - 16 {
            let index = (y * a.width + x) * 4
            guard a.rgba[index + 3] > 0.99 else { continue }
            for channel in 0 ..< 3 {
                let delta = Double(a.rgba[index + channel] - b.rgba[index + channel])
                total += delta * delta
                count += 1
            }
        }
    }
    return count == 0 ? .infinity : total / Double(count)
}

func register(_ source: CIImage, to target: CIImage, width: Int, height: Int)
    throws -> (image: CIImage, mse: Double, matrix: simd_float3x3, inverse: Bool, flipY: Bool)
{
    let request = try VNHomographicImageRegistrationRequest(
        targetedCGImage: registrationImage(source), options: [:]
    )
    try VNImageRequestHandler(cgImage: registrationImage(target), options: [:])
        .perform([request])
    guard let matrix = request.results?.first?.warpTransform else {
        throw HarnessError.registrationFailed
    }
    let targetFrame = frame(target, width: width, height: height)
    var best: (CIImage, Double, Bool, Bool)?
    for inverse in [false, true] {
        for flip in [false, true] {
            let aligned = perspective(source, matrix: inverse ? matrix.inverse : matrix,
                                      size: CGSize(width: width, height: height), flipY: flip)
            let error = interiorMSE(frame(aligned, width: width, height: height), targetFrame)
            if best == nil || error < best!.1 {
                best = (aligned, error, inverse, flip)
            }
        }
    }
    guard let best, best.1.isFinite else { throw HarnessError.registrationFailed }
    return (best.0, best.1, matrix, best.2, best.3)
}

func writePNG(_ image: CIImage, to url: URL) throws {
    try numericContext.writePNGRepresentation(of: image, to: url,
                                              format: .RGBA8, colorSpace: displaySpace)
}

/// Four unregistered, native-resolution corners. These reveal real detail and
/// geometry errors instead of magnifying the 768-pixel evaluation previews.
func writeNativeCorners(rawData: Data, target: CIImage, decoder: CIRAWDecoderVersion,
                        neutralRaw: CIRAWFilter, model: LookModel, directory: URL)
    throws -> (width: Int, height: Int, geometry: NativeGeometryScore)
{
    guard let defaultRaw = CIRAWFilter(imageData: rawData,
                                       identifierHint: "com.sony.arw-raw-image"),
        defaultRaw.supportedDecoderVersions.contains(decoder)
    else { throw HarnessError.decoderUnavailable }
    defaultRaw.decoderVersion = decoder
    defaultRaw.scaleFactor = 1
    neutralRaw.scaleFactor = 1
    guard let defaultImage = defaultRaw.outputImage,
          let neutralImage = neutralRaw.outputImage
    else {
        throw HarnessError.decodeFailed("native RAW output")
    }
    let apple = zeroOrigin(defaultImage), neutral = zeroOrigin(neutralImage)
    let reference = zeroOrigin(target)
    guard apple.extent.size == reference.extent.size,
          neutral.extent.size == reference.extent.size,
          reference.extent.width >= 1024, reference.extent.height >= 1024
    else { throw HarnessError.incompatibleDimensions }
    let width = Int(reference.extent.width), height = Int(reference.extent.height)
    let geometry = try nativeGeometryScore(source: neutral, target: reference) { crop in
        let encoded = try encodedImage(zeroOrigin(crop))
        return frame(encoded, width: 192, height: 192)
    }
    let size = 512
    let corners: [(String, Int, Int)] = [
        ("tl", 0, height - size), ("tr", width - size, height - size),
        ("bl", 0, 0), ("br", width - size, 0),
    ]
    for (name, x, y) in corners {
        let rect = CGRect(x: x, y: y, width: size, height: size)
        let cropDirectory = directory.appendingPathComponent("native-" + name)
        try FileManager.default.createDirectory(at: cropDirectory, withIntermediateDirectories: true)
        let appleCrop = try encodedImage(zeroOrigin(apple.cropped(to: rect)))
        let neutralCrop = try encodedImage(zeroOrigin(neutral.cropped(to: rect)))
        let sonyCrop = try encodedImage(zeroOrigin(reference.cropped(to: rect)))
        let neutralFrame = frame(neutralCrop, width: size, height: size)
        let fixedCrop = try image(apply(model, to: neutralFrame))
        try writePNG(appleCrop, to: cropDirectory.appendingPathComponent("apple.png"))
        try writePNG(neutralCrop, to: cropDirectory.appendingPathComponent("neutral.png"))
        try writePNG(fixedCrop, to: cropDirectory.appendingPathComponent("fixed-model.png"))
        try writePNG(sonyCrop, to: cropDirectory.appendingPathComponent("sony.png"))
    }
    return (width, height, geometry)
}

func apply(_ model: LookModel, to source: RGBFrame) throws -> RGBFrame {
    var pixels = source.rgba
    for index in stride(from: 0, to: pixels.count, by: 4) {
        let rgb = try model.evaluateRGB([
            Double(pixels[index]), Double(pixels[index + 1]), Double(pixels[index + 2]),
        ])
        pixels[index] = Float(rgb[0])
        pixels[index + 1] = Float(rgb[1])
        pixels[index + 2] = Float(rgb[2])
    }
    return RGBFrame(width: source.width, height: source.height, rgba: pixels)
}

func evaluate(_ pair: Pair, model: LookModel, output: URL) throws -> [String: Any] {
    // Both original reads are preceded immediately by the SF_DATALESS gate.
    let rawData = try localData(pair.raw)
    let targetData = try localData(pair.target)
    guard let raw = CIRAWFilter(imageData: rawData,
                                identifierHint: "com.sony.arw-raw-image")
    else { throw HarnessError.decodeFailed("RAW filter") }
    guard let targetOriginal = CIImage(data: targetData,
                                       options: [.applyOrientationProperty: true])
    else { throw HarnessError.decodeFailed("Sony target") }
    let decoder = CIRAWDecoderVersion(rawValue: "8")
    guard raw.supportedDecoderVersions.contains(decoder) else {
        throw HarnessError.decoderUnavailable
    }
    raw.decoderVersion = decoder
    raw.scaleFactor = Float(768 / max(raw.nativeSize.width, raw.nativeSize.height))
    guard let appleOutput = raw.outputImage else { throw HarnessError.decodeFailed("Apple RAW output") }
    let apple = try encodedImage(scaled(appleOutput))
    raw.boostAmount = 0
    raw.localToneMapAmount = 0
    raw.contrastAmount = 0
    raw.sharpnessAmount = 0
    raw.detailAmount = 0
    guard let neutralOutput = raw.outputImage else { throw HarnessError.decodeFailed("neutral RAW output") }
    let neutral = try encodedImage(scaled(neutralOutput))
    let target = try encodedImage(scaled(targetOriginal))
    let width = Int(target.extent.width.rounded())
    let height = Int(target.extent.height.rounded())
    guard Int(neutral.extent.width.rounded()) == width,
          Int(neutral.extent.height.rounded()) == height,
          Int(apple.extent.width.rounded()) == width,
          Int(apple.extent.height.rounded()) == height
    else { throw HarnessError.incompatibleDimensions }
    let neutralFrame = frame(neutral, width: width, height: height)
    let filtered = try image(apply(model, to: neutralFrame))
    let registration = try register(filtered, to: target, width: width, height: height)
    let matrixTarget = registration.image
    // These are measurement-only coordinates. Viewer images below remain in each
    // renderer's original output geometry for honest full-frame inspection.
    let alignedNeutral = perspective(neutral,
                                     matrix: registration.inverse ? registration.matrix.inverse : registration.matrix,
                                     size: CGSize(width: width, height: height),
                                     flipY: registration.flipY)
    let alignedApple = perspective(apple,
                                   matrix: registration.inverse ? registration.matrix.inverse : registration.matrix,
                                   size: CGSize(width: width, height: height),
                                   flipY: registration.flipY)
    let targetPixels = frame(target, width: width, height: height)
    let alignedFixedPixels = frame(matrixTarget, width: width, height: height)
    let geometry = try geometryScore(candidate: alignedFixedPixels, target: targetPixels,
                                     nativeLongEdge: Int(max(raw.nativeSize.width,
                                                             raw.nativeSize.height)))
    let scores = try [
        "apple": colorScore(candidate: frame(alignedApple, width: width, height: height), target: targetPixels),
        "neutral": colorScore(candidate: frame(alignedNeutral, width: width, height: height), target: targetPixels),
        "fixedModel": colorScore(candidate: alignedFixedPixels, target: targetPixels),
    ]
    let pairDirectory = output.appendingPathComponent(pair.id)
    try FileManager.default.createDirectory(at: pairDirectory, withIntermediateDirectories: true)
    try writePNG(apple, to: pairDirectory.appendingPathComponent("apple.png"))
    try writePNG(neutral, to: pairDirectory.appendingPathComponent("neutral.png"))
    try writePNG(filtered, to: pairDirectory.appendingPathComponent("fixed-model.png"))
    try writePNG(target, to: pairDirectory.appendingPathComponent("sony.png"))
    let native = try writeNativeCorners(rawData: rawData, target: targetOriginal,
                                        decoder: decoder, neutralRaw: raw, model: model,
                                        directory: pairDirectory)
    let scoreData = try JSONEncoder().encode(scores)
    let scoreObject = try JSONSerialization.jsonObject(with: scoreData)
    let geometryObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(geometry))
    let nativeGeometryObject = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(native.geometry)
    )
    return [
        "id": pair.id, "session": pair.session, "role": pair.role.rawValue,
        "width": width, "height": height, "decoder": raw.decoderVersion.rawValue,
        "nativeWidth": native.width, "nativeHeight": native.height,
        "rawBytesRead": rawData.count, "targetBytesRead": targetData.count,
        "materialization": "alreadyLocal",
        "scores": scoreObject, "registrationMSE": registration.mse,
        "geometry": geometryObject,
        "nativeGeometry": nativeGeometryObject,
        "registrationInverse": registration.inverse,
        "registrationFlipY": registration.flipY,
    ]
}

func selfTest(_ path: String) throws {
    let content = try String(contentsOfFile: path, encoding: .utf8)
    let lines = content.split(separator: "\n").filter { !$0.hasPrefix("#") }
    guard lines.count == 34 else { throw HarnessError.malformedReferenceData }
    for (index, line) in lines.enumerated() {
        let values = line.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        guard values.count == 7 else { throw HarnessError.malformedReferenceData }
        let first = Lab(l: values[0], a: values[1], b: values[2])
        let second = Lab(l: values[3], a: values[4], b: values[5])
        for (a, b) in [(first, second), (second, first)] {
            let error = ciede2000(a, b)
            guard abs(error - values[6]) < 0.000051 else {
                throw NSError(domain: "CIEDE2000 reference row \(index + 1)",
                              code: 1, userInfo: ["actual": error, "expected": values[6]])
            }
        }
    }
    let gray = Lab.srgb(0.5, 0.5, 0.5)
    guard abs(gray.a) < 0.01, abs(gray.b) < 0.01 else { throw HarnessError.malformedReferenceData }
    let constant = RGBFrame(width: 32, height: 32,
                            rgba: Array(repeating: [Float(0.5), 0.5, 0.5, 1], count: 32 * 32).flatMap(\.self))
    let score = try colorScore(candidate: constant, target: constant)
    guard score.meanLowFrequencyDE00 == 0, score.validFraction == 1 else {
        throw HarnessError.malformedReferenceData
    }
    var pattern = [Float](repeating: 0, count: 128 * 96 * 4)
    var state: UInt32 = 0x6172_7738
    for i in 0 ..< 128 * 96 {
        state = 1_664_525 &* state &+ 1_013_904_223
        let value = Float(state & 0xFFFF) / 65535
        for channel in 0 ..< 3 {
            pattern[i * 4 + channel] = value
        }
        pattern[i * 4 + 3] = 1
    }
    let patterned = RGBFrame(width: 128, height: 96, rgba: pattern)
    let identicalGeometry = try geometryScore(candidate: patterned, target: patterned,
                                              nativeLongEdge: 128)
    let flat = RGBFrame(width: 128, height: 96,
                        rgba: Array(repeating: [Float(0.5), 0.5, 0.5, 1],
                                    count: 128 * 96).flatMap(\.self))
    let flatGeometry = try geometryScore(candidate: flat, target: flat,
                                         nativeLongEdge: 128)
    guard identicalGeometry.reliable > 20,
          (identicalGeometry.p95ResidualNativePixels ?? .infinity) < 0.05,
          flatGeometry.reliable == 0 else { throw HarnessError.malformedReferenceData }
    try nativeGeometrySelfTest()
    print("34 published CIEDE2000 pairs, scorecard and geometry fixtures: pass")
}

func validate(_ manifest: Manifest, output: URL) throws {
    guard !manifest.pairs.isEmpty, output.path.hasPrefix("/") else {
        throw HarnessError.invalidManifest
    }
    var ids = Set<String>()
    var sessionRoles = [String: PairRole]()
    let outputPath = output.resolvingSymlinksInPath().standardizedFileURL.path + "/"
    for pair in manifest.pairs {
        guard !pair.id.isEmpty,
              pair.id.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).contains($0)
              }),
              ids.insert(pair.id).inserted,
              !pair.session.isEmpty,
              (sessionRoles[pair.session] ?? pair.role) == pair.role,
              pair.raw.lowercased().hasSuffix(".arw"),
              [".heif", ".hif", ".jpg", ".jpeg"].contains(where: {
                  pair.target.lowercased().hasSuffix($0)
              }),
              pair.raw != pair.target
        else { throw HarnessError.invalidManifest }
        sessionRoles[pair.session] = pair.role
        for path in [pair.raw, pair.target] {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
                .resolvingSymlinksInPath().standardizedFileURL.path + "/"
            guard !outputPath.hasPrefix(directory) else { throw HarnessError.invalidManifest }
        }
    }
}

func run() throws {
    let arguments = CommandLine.arguments
    guard arguments.count >= 3 else { throw HarnessError.usage }
    if arguments[1] == "self-test", arguments.count == 3 {
        try selfTest(arguments[2])
    } else if arguments[1] == "lens-audit", arguments.count == 4 {
        let manifest = try JSONDecoder().decode(Manifest.self,
                                                from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
        let output = URL(fileURLWithPath: arguments[3])
        try validate(manifest, output: output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var failures = [[String: String]]()
        for pair in manifest.pairs {
            do {
                let record = try lensAudit(pair)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(record).write(to: output.appendingPathComponent(pair.id + ".json"))
                print("audited \(pair.id) \(pair.role.rawValue) \(pair.session)")
            } catch {
                failures.append(["id": pair.id, "reason": String(describing: error)])
                fputs("failed: \(pair.id)\n", stderr)
            }
        }
        let summary = try JSONSerialization.data(withJSONObject: [
            "planned": manifest.pairs.count,
            "completed": manifest.pairs.count - failures.count,
            "failures": failures,
        ], options: [.prettyPrinted, .sortedKeys])
        try summary.write(to: output.appendingPathComponent("summary.json"))
        if !failures.isEmpty {
            throw HarnessError.partialEvaluation
        }
    } else if arguments[1] == "evaluate", arguments.count == 5 {
        let manifest = try JSONDecoder().decode(Manifest.self,
                                                from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
        let model = try LookModel(json: Data(contentsOf: URL(fileURLWithPath: arguments[3])))
        let output = URL(fileURLWithPath: arguments[4])
        try validate(manifest, output: output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var failures = [[String: String]]()
        var completedIDs = [String]()
        for pair in manifest.pairs {
            do {
                let result = try evaluate(pair, model: model, output: output)
                let data = try JSONSerialization.data(withJSONObject: result,
                                                      options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output.appendingPathComponent(pair.id + ".json"))
                completedIDs.append(pair.id)
                print("evaluated \(pair.id) \(pair.role.rawValue) \(pair.session)")
            } catch {
                let status = if let harnessError = error as? HarnessError,
                                case .unavailableOriginal = harnessError
                {
                    "unavailable"
                } else {
                    "failed"
                }
                failures.append(["id": pair.id, "status": status,
                                 "reason": String(describing: error)])
                fputs("\(status): \(pair.id)\n", stderr)
            }
        }
        let summary = try JSONSerialization.data(withJSONObject: [
            "planned": manifest.pairs.count,
            "completed": manifest.pairs.count - failures.count,
            "failures": failures,
        ], options: [.prettyPrinted, .sortedKeys])
        try summary.write(to: output.appendingPathComponent("summary.json"))
        try viewerHTML(ids: completedIDs).write(to: output.appendingPathComponent("index.html"),
                                                atomically: true, encoding: .utf8)
        if !failures.isEmpty {
            throw HarnessError.partialEvaluation
        }
    } else {
        throw HarnessError.usage
    }
}

do {
    try run()
} catch {
    fputs("Sony render harness: \(error)\n", stderr)
    exit(1)
}
