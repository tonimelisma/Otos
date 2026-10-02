// Calibration for the named RAW 9 encoded-sRGB baseline, outside the app.
// Originals are read through the materialization gate; sampled pixels remain
// private. Capture verification precedes export. Fitting accepts training roles
// only, and uses Apple's LAPACK instead of a separate numerical dependency.
import Accelerate
import CoreImage
import Foundation
import ImageIO
import simd

enum LookCalibrationError: Error {
    case invalidTrainingManifest, existingOutput, invalidSamples, solveFailed(Int32)
}

private struct CalibrationRecipe: Codable {
    let contractVersion: Int
    let decoder: String
    let samples: Int
    let nativeLensCorrectionEnabled: Bool
    let calibrationBlurRadius: Double
    let evaluationLongEdge: Int
    let neutralSettings: [String: Double]
}

func exportLookCalibrationPair(_ pair: Pair, output: URL) throws {
    guard pair.role == .training else { throw LookCalibrationError.invalidTrainingManifest }
    let directory = output.appendingPathComponent(pair.id)
    guard !FileManager.default.fileExists(atPath: directory.path) else {
        throw LookCalibrationError.existingOutput
    }
    let rawBytes = try localData(pair.raw)
    // In-memory ARW data can otherwise be recognized as generic TIFF, losing
    // the camera metadata used to enforce this calibration's supported body.
    let sourceOptions = [kCGImageSourceTypeIdentifierHint: "com.sony.arw-raw-image"] as CFDictionary
    guard let rawSource = CGImageSourceCreateWithData(rawBytes as CFData, sourceOptions),
          let properties = CGImageSourceCopyPropertiesAtIndex(rawSource, 0, nil) as? [String: Any],
          let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
          tiff[kCGImagePropertyTIFFModel as String] as? String == "ILCE-6700"
    else { throw SonySensorRAWHEIFRenderer.Failure.unsupportedOriginal }
    let targetBytes = try localData(pair.target)
    guard let raw = CIRAWFilter(imageData: rawBytes, identifierHint: "com.sony.arw-raw-image"),
          let original = CIImage(data: targetBytes, options: [.applyOrientationProperty: true]),
          raw.supportedDecoderVersions.contains(CIRAWDecoderVersion(rawValue: "9")),
          raw.isLensCorrectionSupported
    else { throw HarnessError.decoderUnavailable }
    raw.decoderVersion = CIRAWDecoderVersion(rawValue: "9")
    raw.isLensCorrectionEnabled = true
    raw.scaleFactor = Float(768 / max(raw.nativeSize.width, raw.nativeSize.height))
    raw.boostAmount = 0
    raw.localToneMapAmount = 0
    raw.contrastAmount = 0
    raw.sharpnessAmount = 0
    guard let developed = raw.outputImage else { throw HarnessError.decodeFailed("calibration RAW") }
    let source = try encodedImage(scaled(developed)), target = try encodedImage(scaled(original))
    guard source.extent.size == target.extent.size else { throw HarnessError.incompatibleDimensions }
    let width = Int(target.extent.width.rounded()), height = Int(target.extent.height.rounded())
    let aligned = try register(source, to: target, width: width, height: height)
    /// This radius preserves the saved baseline's calibration recipe. It is not
    /// the independently specified Gaussian sigma used by the release scorecard.
    func samples(_ input: CIImage) -> RGBFrame {
        let blurred = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.2])
            .cropped(to: target.extent)
        return frame(blurred, width: width, height: height)
    }
    let input = samples(aligned.image), reference = samples(target)
    var values = [Float]()
    for row in 0 ..< 50 {
        for column in 0 ..< 50 {
            let x = min(width - 9, max(8, Int((Double(column) + 0.5) * Double(width) / 50)))
            let y = min(height - 9, max(8, Int((Double(row) + 0.5) * Double(height) / 50)))
            let i = (y * width + x) * 4
            guard input.rgba[i + 3] > 0.999, reference.rgba[i + 3] > 0.999 else { continue }
            let sourceRGB = Array(input.rgba[i ..< i + 3])
            let targetRGB = Array(reference.rgba[i ..< i + 3])
            // Calibration omits near-black/clipped samples under the baseline
            // contract. Photographic scoring does not omit those colors.
            guard sourceRGB.allSatisfy({ $0.isFinite && $0 > 0.005 && $0 < 1.245 }),
                  targetRGB.allSatisfy({ $0.isFinite && $0 > 0.005 && $0 < 0.99 })
            else { continue }
            values += sourceRGB + targetRGB
        }
    }
    guard values.count >= 500 * 6 else { throw LookCalibrationError.invalidSamples }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var bytes = Data(capacity: values.count * 4)
    for value in values {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
    }
    try bytes.write(to: directory.appendingPathComponent("samples.f32"), options: .withoutOverwriting)
    let recipe: [String: Any] = [
        "contractVersion": 2, "decoder": "9", "samples": values.count / 6,
        "nativeLensCorrectionEnabled": true, "registrationMSE": aligned.mse,
        "calibrationBlurRadius": 1.2, "evaluationLongEdge": 768,
        "neutralSettings": ["boostAmount": 0, "localToneMapAmount": 0, "contrastAmount": 0, "sharpnessAmount": 0],
        "temperature": raw.neutralTemperature, "tint": raw.neutralTint,
        "baselineExposure": raw.baselineExposure, "shadowBias": raw.shadowBias,
    ]
    try JSONSerialization.data(withJSONObject: recipe, options: [.sortedKeys])
        .write(to: directory.appendingPathComponent("recipe.json"), options: .withoutOverwriting)
    print("op=calibration.export id=\(pair.id) samples=\(values.count / 6) decoder=9")
}

private struct CalibrationSample {
    let input: SIMD3<Double>
    let target: SIMD3<Double>
    let weight: Double
}

private func calibrationSamples(_ manifest: Manifest, root: URL) throws -> [CalibrationSample] {
    var result = [CalibrationSample]()
    for pair in manifest.pairs {
        let path = root.appendingPathComponent(pair.id).appendingPathComponent("samples.f32")
        let data = try localData(path.path)
        guard data.count % 24 == 0, (500 ... 2500).contains(data.count / 24) else {
            throw LookCalibrationError.invalidSamples
        }
        let recipePath = root.appendingPathComponent(pair.id).appendingPathComponent("recipe.json")
        guard let recipeData = try? localData(recipePath.path),
              let recipe = try? JSONDecoder().decode(CalibrationRecipe.self, from: recipeData),
              recipe.contractVersion == 2, recipe.decoder == "9",
              recipe.samples == data.count / 24, recipe.nativeLensCorrectionEnabled,
              recipe.calibrationBlurRadius == 1.2, recipe.evaluationLongEdge == 768,
              recipe.neutralSettings == ["boostAmount": 0, "localToneMapAmount": 0, "contrastAmount": 0, "sharpnessAmount": 0]
        else { throw LookCalibrationError.invalidSamples }
        let values: [Double] = data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).map {
                Double(Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self))))
            }
        }
        for i in stride(from: 0, to: values.count, by: 6) {
            let x = SIMD3(values[i], values[i + 1], values[i + 2])
            let y = SIMD3(values[i + 3], values[i + 4], values[i + 5])
            guard (0 ..< 3).allSatisfy({
                x[$0].isFinite && x[$0] > 0.005 && x[$0] < 1.245
                    && y[$0].isFinite && y[$0] > 0.005 && y[$0] < 0.99
            }) else { throw LookCalibrationError.invalidSamples }
            result.append(CalibrationSample(input: x, target: y, weight: 2500 / Double(data.count / 24)))
        }
    }
    return result
}

private func isotonic(_ values: [Double], weights: [Double]) -> [Double] {
    struct Block {
        var first: Int, last: Int
        var weight: Double, total: Double
    }
    var blocks = [Block]()
    for i in values.indices {
        blocks.append(Block(first: i, last: i, weight: weights[i], total: values[i] * weights[i]))
        while blocks.count > 1 {
            let left = blocks[blocks.count - 2], right = blocks[blocks.count - 1]
            guard left.total / left.weight > right.total / right.weight else { break }
            blocks.removeLast(2)
            blocks.append(Block(first: left.first, last: right.last,
                                weight: left.weight + right.weight, total: left.total + right.total))
        }
    }
    var result = values
    for block in blocks {
        for i in block.first ... block.last {
            result[i] = block.total / block.weight
        }
    }
    return result
}

func fitLookCalibration(_ manifest: Manifest, samplesRoot: URL, destination: URL) throws {
    guard manifest.pairs.count >= 100, manifest.pairs.allSatisfy({ $0.role == .training }) else {
        throw LookCalibrationError.invalidTrainingManifest
    }
    try validate(manifest, output: samplesRoot)
    try validate(manifest, output: destination.deletingLastPathComponent())
    guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw LookCalibrationError.existingOutput
    }
    let started = Date(), samples = try calibrationSamples(manifest, root: samplesRoot)
    let knots = (0 ..< 49).map { Double($0) * 1.25 / 48 }
    var curves = [[Double]]()
    for c in 0 ..< 3 {
        var count = [Double](repeating: 0, count: 49), total = count
        for sample in samples {
            let bin = max(0, min(48, Int((sample.input[c] / 1.25 * 48).rounded(.toNearestOrEven))))
            count[bin] += sample.weight
            total[bin] += sample.weight * sample.target[c]
        }
        let weights = count.map { $0 + 1 }
        let values = (0 ..< 49).map { (total[$0] + min(1, max(0, knots[$0]))) / weights[$0] }
        curves.append(isotonic(values, weights: weights))
    }
    let size = 729
    // Column-major normal equations and three RHS columns are LAPACK's storage
    // contract. The positive ridge makes a Cholesky solve well-defined even for
    // palette regions with no training observations.
    var normal = [Double](repeating: 0, count: size * size)
    var rhs = [Double](repeating: 0, count: size * 3)
    for sample in samples {
        var residual = sample.target
        for c in 0 ..< 3 {
            let q = max(0, min(1.25, sample.input[c])) / 1.25 * 48
            let i = min(47, Int(q)), f = q - Double(i)
            residual[c] -= curves[c][i] * (1 - f) + curves[c][i + 1] * f
        }
        let q = simd_clamp(sample.input / 1.25 * 8, SIMD3(repeating: 0), SIMD3(repeating: 8))
        let low = SIMD3(min(7, Int(q.x)), min(7, Int(q.y)), min(7, Int(q.z)))
        let f = q - SIMD3<Double>(Double(low.x), Double(low.y), Double(low.z))
        var nodes = [(Int, Double)]()
        for r in 0 ... 1 {
            for g in 0 ... 1 {
                for b in 0 ... 1 {
                    let node = (low.x + r) * 81 + (low.y + g) * 9 + low.z + b
                    let weight = (r == 0 ? 1 - f.x : f.x) * (g == 0 ? 1 - f.y : f.y) * (b == 0 ? 1 - f.z : f.z)
                    nodes.append((node, weight))
                }
            }
        }
        for (a, wa) in nodes {
            let weight = sample.weight * wa
            for c in 0 ..< 3 {
                rhs[a + c * size] += weight * residual[c]
            }
            for (b, wb) in nodes {
                normal[a + b * size] += weight * wb
            }
        }
    }
    for r in 0 ..< 9 {
        for g in 0 ..< 9 {
            for b in 0 ..< 9 {
                let a = r * 81 + g * 9 + b
                normal[a + a * size] += 2
                for (step, coordinate) in [(81, r), (9, g), (1, b)] where coordinate < 8 {
                    let other = a + step
                    normal[a + a * size] += 10
                    normal[other + other * size] += 10
                    normal[a + other * size] -= 10
                    normal[other + a * size] -= 10
                }
            }
        }
    }
    var triangle: CChar = 76, n = Int32(size), columns: Int32 = 3
    var leading = Int32(size), rhsLeading = Int32(size), info: Int32 = 0
    normal.withUnsafeMutableBufferPointer { matrix in
        rhs.withUnsafeMutableBufferPointer { values in
            dposv_(&triangle, &n, &columns, matrix.baseAddress!, &leading, values.baseAddress!, &rhsLeading, &info)
        }
    }
    guard info == 0, rhs.allSatisfy(\.isFinite) else { throw LookCalibrationError.solveFailed(info) }
    let lut = (0 ..< 9).map { r in (0 ..< 9).map { g in (0 ..< 9).map { b in
        (0 ..< 3).map { rhs[r * 81 + g * 9 + b + $0 * size] }
    } } }
    let object: [String: Any] = [
        "formatVersion": 2, "decoder": "9", "dimension": 9, "domain": [0, 1.25],
        "curveKnots": knots, "curvesRGB": curves, "residualLUT": lut,
        "neutralSettings": ["boostAmount": 0, "localToneMapAmount": 0, "contrastAmount": 0, "sharpnessAmount": 0],
        "note": "RAW 9 encoded-sRGB baseline; fitted only from verified private training captures.",
    ]
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    _ = try LookModel(json: data)
    try data.write(to: destination, options: .withoutOverwriting)
    print("op=calibration.fit images=\(manifest.pairs.count) samples=\(samples.count) seconds=\(Date().timeIntervalSince(started))")
}
