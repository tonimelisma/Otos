import Accelerate
import CoreGraphics
import CoreML
import Foundation

/// Search embedding model guide
///
/// SigLIP 2 B/16-256 (Google, Apache-2.0), converted to Core ML with 8-bit linear per-channel
/// weights (ADR 0048). Its two towers map a photo and a piece of English text into one
/// 768-d space, where a photo and a description of it have a high cosine:
///
/// - `SearchImageModel` (`SigLIP2Image.mlpackage`, 94 MB; the positional embedding at full
///   precision): one 256 × 256 RGB image, resized by `SearchImageResampler` and with the
///   model's normalisation folded into the image input, to a unit-length embedding.
/// - `SearchTextModel` (`SigLIP2Text.mlpackage`, 87 MB, and the token table): 64 token ids
///   (`SearchTextTokenizer`) to a unit-length embedding. The token lookup happens here, not in
///   Core ML: the 256,000 × 768 table is 197M of the tower's 282M weights. It ships as four
///   int8 files of 64,000 rows of 768 bytes, then one Float32 scale per row
///   (`value = int8 × scale`), so no file reaches GitHub's 100 MB limit;
///   they are memory-mapped, and a query touches only its own rows.
///
/// Chosen and measured on the owner's library
/// (`docs/research/2026-11-09-keyword-search.md`). CPU only, as every Otos model runs
/// (ADR 0045). Neither type is `Sendable`: each lives inside the one actor that owns it.
nonisolated enum SearchEmbedding {
    /// The length of an embedding.
    static let dimensions = 768

    /// The model, its preprocessing and the scene labels read with it; stored with every
    /// image embedding, so a change makes every stored one stale.
    static let revision = 2

    static let computeUnits = MLComputeUnits.cpuOnly

    enum ModelError: Error {
        case missingResource(String)
        case unexpectedInterface
        case unexpectedOutput
    }

    static func load(_ name: String, bundle: Bundle) throws -> MLModel {
        guard let url = bundle.url(forResource: name, withExtension: "mlmodelc") else {
            throw ModelError.missingResource(name)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        return try MLModel(contentsOf: url, configuration: configuration)
    }

    static func vector(_ output: MLFeatureProvider) throws -> [Float] {
        guard let array = output.featureValue(for: "embedding")?.multiArrayValue, array.count == dimensions else {
            throw ModelError.unexpectedOutput
        }
        return (0 ..< dimensions).map { array[$0].floatValue }
    }
}

nonisolated struct SearchImageModel {
    /// The image tower's input side.
    static let side = 256

    private let model: MLModel
    private let constraint: MLImageConstraint

    init(bundle: Bundle) throws {
        model = try SearchEmbedding.load("SigLIP2Image", bundle: bundle)
        guard let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
              constraint.pixelsWide == Self.side, constraint.pixelsHigh == Self.side
        else {
            throw SearchEmbedding.ModelError.unexpectedInterface
        }
        self.constraint = constraint
    }

    /// The embedding of `image`, an upright picture of any size, squashed to 256 × 256 as the
    /// model was trained (`SearchImageResampler`).
    func embedding(of image: CGImage) throws -> [Float] {
        guard let square = SearchImageResampler.square(image, side: Self.side) else {
            throw SearchEmbedding.ModelError.unexpectedInterface
        }
        let input = try MLFeatureValue(cgImage: square, constraint: constraint)
        return try SearchEmbedding.vector(model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input])))
    }
}

/// The resize SigLIP 2 was trained and measured with: open_clip hands a PIL image to
/// torchvision, which resizes it with PIL's bicubic filter (a = −0.5), widened by the scale
/// when shrinking, horizontally then vertically, rounding to 8 bits between the passes.
/// Core Graphics' high-quality interpolation is a different filter: on the owner's thumbnails
/// its squares moved embeddings to a median cosine of 0.973 against the reference, and this
/// filter's to 0.999 (`docs/research/2026-11-09-keyword-search.md` §8). Each pass is one
/// matrix product per channel (Accelerate), fast enough in a Debug build.
nonisolated enum SearchImageResampler {
    static func square(_ image: CGImage, side: Int) -> CGImage? {
        guard let source = rgb(image) else { return nil }
        let width = source.width, height = source.height
        let horizontal = weights(from: width, to: side, sourceMajor: true)
        let vertical = weights(from: height, to: side, sourceMajor: false)
        var output = [UInt8](repeating: 0, count: side * side * 3)
        var plane = [Float](repeating: 0, count: width * height)
        var wide = [Float](repeating: 0, count: height * side)
        var square = [Float](repeating: 0, count: side * side)
        for channel in 0 ..< 3 {
            source.pixels.withUnsafeBufferPointer { pixels in
                vDSP_vfltu8(pixels.baseAddress! + channel, 4, &plane, 1, vDSP_Length(width * height))
            }
            // Rows: (height × width) · (width × side). Columns: (side × height) · (height × side).
            vDSP_mmul(plane, 1, horizontal, 1, &wide, 1, vDSP_Length(height), vDSP_Length(side), vDSP_Length(width))
            roundTo8Bits(&wide)
            vDSP_mmul(vertical, 1, wide, 1, &square, 1, vDSP_Length(side), vDSP_Length(side), vDSP_Length(height))
            roundTo8Bits(&square)
            output.withUnsafeMutableBufferPointer { out in
                vDSP_vfixu8(square, 1, out.baseAddress! + channel, 3, vDSP_Length(side * side))
            }
        }
        return makeImage(output, width: side, height: side)
    }

    /// PIL's taps for one axis as a matrix: `sourceMajor` (input × side, `[source][target]`)
    /// for the horizontal pass, which multiplies rows from the right; otherwise (side × input,
    /// `[target][source]`) for the vertical pass, which multiplies columns from the left.
    private static func weights(from input: Int, to output: Int, sourceMajor: Bool) -> [Float] {
        let scale = Double(input) / Double(output)
        let filterScale = max(scale, 1)
        let support = 2 * filterScale
        var matrix = [Float](repeating: 0, count: output * input)
        for target in 0 ..< output {
            let center = (Double(target) + 0.5) * scale
            let first = max(Int(center - support + 0.5), 0)
            let last = min(Int(center + support + 0.5), input)
            let taps = (first ..< last).map { cubic((Double($0) - center + 0.5) / filterScale) }
            let total = taps.reduce(0, +)
            for (offset, tap) in taps.enumerated() {
                let source = first + offset
                matrix[sourceMajor ? source * output + target : target * input + source] = Float(total == 0 ? tap : tap / total)
            }
        }
        return matrix
    }

    /// Rounds to the nearest integer and clamps to 0…255, as PIL stores each pass in 8 bits.
    private static func roundTo8Bits(_ values: inout [Float]) {
        var count = Int32(values.count)
        values.withUnsafeMutableBufferPointer { buffer in
            vvnintf(buffer.baseAddress!, buffer.baseAddress!, &count)
        }
        var low: Float = 0, high: Float = 255
        vDSP_vclip(values, 1, &low, &high, &values, 1, vDSP_Length(values.count))
    }

    /// The image's pixels as RGBX bytes, row-major, in its own RGB space: PIL reads a file's
    /// values without converting from an embedded profile, so neither does this.
    private static func rgb(_ image: CGImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        let width = image.width, height = image.height
        let own = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        guard width > 0, height > 0, let space = own ?? CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var rgbx = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgbx.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (rgbx, width, height) : nil
    }

    private static func cubic(_ value: Double) -> Double {
        let a = -0.5, x = abs(value)
        if x < 1 {
            return ((a + 2) * x - (a + 3)) * x * x + 1
        }
        if x < 2 {
            return (((x - 5) * x + 8) * x - 4) * a
        }
        return 0
    }

    private static func makeImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData)
        else {
            return nil
        }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

nonisolated struct SearchTextModel {
    static let vocabularySize = 256_000
    static let rowsPerFile = 64000

    private let model: MLModel
    private let tables: [Data]

    init(bundle: Bundle) throws {
        model = try SearchEmbedding.load("SigLIP2Text", bundle: bundle)
        let fileCount = Self.vocabularySize / Self.rowsPerFile
        tables = try (0 ..< fileCount).map { index in
            let name = "SigLIP2TokenEmbeddings-\(index)"
            guard let url = bundle.url(forResource: name, withExtension: "bin") else {
                throw SearchEmbedding.ModelError.missingResource(name)
            }
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            guard data.count == Self.rowsPerFile * (SearchEmbedding.dimensions + 4) else {
                throw SearchEmbedding.ModelError.unexpectedInterface
            }
            return data
        }
    }

    /// The embedding of 64 token ids from `SearchTextTokenizer`.
    func embedding(of ids: [Int32]) throws -> [Float] {
        let dimensions = SearchEmbedding.dimensions
        guard ids.count == SearchTextTokenizer.contextLength else {
            throw SearchEmbedding.ModelError.unexpectedInterface
        }
        let tokens = try MLMultiArray(shape: [1, NSNumber(value: ids.count), NSNumber(value: dimensions)], dataType: .float32)
        let output = tokens.dataPointer.bindMemory(to: Float.self, capacity: ids.count * dimensions)
        for (position, id) in ids.enumerated() {
            guard id >= 0, Int(id) < Self.vocabularySize else {
                throw SearchEmbedding.ModelError.unexpectedInterface
            }
            let table = tables[Int(id) / Self.rowsPerFile]
            let row = Int(id) % Self.rowsPerFile
            table.withUnsafeBytes { raw in
                let scale = raw.loadUnaligned(fromByteOffset: Self.rowsPerFile * dimensions + row * 4, as: Float.self)
                let values = raw.baseAddress!.advanced(by: row * dimensions).assumingMemoryBound(to: Int8.self)
                let destination = output + position * dimensions
                for index in 0 ..< dimensions {
                    destination[index] = Float(values[index]) * scale
                }
            }
        }
        let input = MLFeatureValue(multiArray: tokens)
        return try SearchEmbedding.vector(model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["tokens": input])))
    }
}
