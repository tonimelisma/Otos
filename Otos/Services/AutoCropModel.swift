import CoreGraphics
import CoreML
import Foundation

/// Auto crop model guide
///
/// Appwrite FocalNet (MIT; https://huggingface.co/appwrite/focalnet) proposes the crop. Its
/// Core ML conversion (`FocalNet.mlpackage`, full precision: half precision changed the chosen
/// crop on 3.6% of GAICD's test photos) takes the photo letterboxed into 256 × 256, up to 128
/// candidate boxes and the letterbox's content box, and returns a 64 × 64 importance map and
/// one human-preference score per box, trained on people's crop ratings (CPC, GAICD).
///
/// The selection is FocalNet's own `predict-human` rule, run over ten shapes so the crop takes
/// whatever shape suits the photo (ADR 0045): five positions × five sizes per shape, keep the
/// candidates retaining within 0.05 of the most importance any keeps, take the best scored. A
/// choice overlapping the whole frame by IoU 0.97 or more is no crop: FocalNet keeps most photos
/// whole, and then there is nothing to suggest.
///
/// Measured in `docs/research/2026-11-01-auto-straighten-and-crop-suggestions.md`.
/// Owned by `EditAnalyzer`, which runs it on its own serial queue.
nonisolated struct AutoCropModel {
    private let model: MLModel

    /// CPU only. On the GPU, concurrent predictions deadlock inside MPSGraph (eight analyzers at
    /// once, as parallel tests run them, parked every thread on its lock); the CPU path reads the
    /// same crops and levels as the measured reference at about the same speed (~0.1 s a crop,
    /// ~0.35 s a level on an M1 Pro), and it leaves the GPU to the live render. The Neural Engine
    /// is not offered: Core ML refuses a function name on GeoCalib's multi-function model with it.
    static let computeUnits = MLComputeUnits.cpuOnly
    static let inputSize = 256
    static let mapSize = 64
    static let maximumCandidates = 128
    /// The photo's own shape (nil) and the common print and screen shapes, both ways up.
    static let shapes: [Double?] = [nil, 1, 4.0 / 3, 3.0 / 4, 3.0 / 2, 2.0 / 3, 16.0 / 9, 9.0 / 16, 5.0 / 4, 4.0 / 5]
    static let scales: [Double] = [1.0, 0.9, 0.8, 0.7, 0.65]
    static let positions = 5
    static let retentionTolerance = 0.05
    /// A crop this close to the whole frame is no crop.
    static let wholeFrameOverlap = 0.97

    init(bundle: Bundle) throws {
        guard let url = bundle.url(forResource: "FocalNet", withExtension: "mlmodelc") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = Self.computeUnits
        model = try MLModel(contentsOf: url, configuration: configuration)
    }

    /// The suggested crop of `image` as fractions of it, or nil when FocalNet would keep it whole.
    func crop(of image: CGImage) throws -> EditCrop? {
        let letterbox = Letterbox(width: image.width, height: image.height)
        let tensor = try Self.tensor(image, letterbox: letterbox)
        let candidates = Self.candidates(width: image.width, height: image.height)
        var scores: [Double] = []
        var importance: [Float] = []
        for start in stride(from: 0, to: candidates.count, by: Self.maximumCandidates) {
            let chunk = Array(candidates[start ..< min(start + Self.maximumCandidates, candidates.count)])
            let output = try score(tensor: tensor, boxes: chunk, content: letterbox.content)
            scores += output.scores
            if importance.isEmpty {
                importance = output.importance
            }
        }
        let map = Self.restore(importance, letterbox: letterbox)
        let retention = candidates.map {
            Self.retention(of: Self.pixelBox($0, width: image.width, height: image.height), in: map, width: image.width, height: image.height)
        }
        guard let best = Self.select(scores: scores, retention: retention) else { return nil }
        let box = candidates[best]
        let crop = EditCrop(left: box[0], top: box[1], width: box[2] - box[0], height: box[3] - box[1])
        return crop.overlap(with: .whole) >= Self.wholeFrameOverlap ? nil : crop
    }

    /// FocalNet's rule: among candidates within the tolerance of the best retention, the
    /// highest score; the first on a tie, as candidates are in sorted order.
    static func select(scores: [Double], retention: [Double]) -> Int? {
        guard let most = retention.max(), scores.count == retention.count else { return nil }
        var best: Int?
        for index in retention.indices where retention[index] >= most - retentionTolerance {
            if best == nil || scores[index] > scores[best!] {
                best = index
            }
        }
        return best
    }

    // MARK: - Candidates

    /// FocalNet's `generate_candidates` for every shape, deduplicated and sorted like
    /// `np.unique`: boxes as [left, top, right, bottom] fractions of the frame.
    static func candidates(width: Int, height: Int) -> [[Double]] {
        let source = Double(width) / Double(height)
        var boxes = Set<[Double]>()
        for shape in shapes {
            let ratio = shape ?? source
            let (maximumWidth, maximumHeight) = source > ratio ? (ratio / source, 1.0) : (1.0, source / ratio)
            for scale in scales {
                let w = maximumWidth * scale, h = maximumHeight * scale
                let xs = linspace(0, 1 - w, w < 1 - 1e-7 ? positions : 1)
                let ys = linspace(0, 1 - h, h < 1 - 1e-7 ? positions : 1)
                for top in ys {
                    for left in xs {
                        boxes.insert([left, top, left + w, top + h].map { ($0 * 1e6).rounded() / 1e6 })
                    }
                }
            }
        }
        return boxes.sorted { $0.lexicographicallyPrecedes($1) }
    }

    private static func linspace(_ start: Double, _ end: Double, _ count: Int) -> [Double] {
        count == 1 ? [start] : (0 ..< count).map { start + (end - start) * Double($0) / Double(count - 1) }
    }

    // MARK: - Preprocessing

    /// FocalNet's `Letterbox.fit`: the photo aspect-fit into the square input, centered.
    struct Letterbox {
        let left: Int, top: Int, width: Int, height: Int
        let size = AutoCropModel.inputSize

        init(width imageWidth: Int, height imageHeight: Int) {
            let size = AutoCropModel.inputSize
            let scale = min(Double(size) / Double(imageWidth), Double(size) / Double(imageHeight))
            width = max(1, min(size, Int(Double(imageWidth) * scale + 0.5)))
            height = max(1, min(size, Int(Double(imageHeight) * scale + 0.5)))
            left = (size - width) / 2
            top = (size - height) / 2
        }

        /// The content box as fractions of the input, as the ranking head is given it.
        var content: [Float] {
            [Float(left), Float(top), Float(left + width), Float(top + height)].map { $0 / Float(size) }
        }

        /// The share of each map cell the photo covers (`Letterbox.coverage`).
        func coverage(grid: Int) -> [Double] {
            let cell = Double(size) / Double(grid)
            func axis(_ start: Int, _ length: Int) -> [Double] {
                (0 ..< grid).map { i in
                    max(0, min(Double(i + 1) * cell, Double(start + length)) - max(Double(i) * cell, Double(start)))
                }
            }
            let xs = axis(left, width), ys = axis(top, height)
            return ys.flatMap { y in xs.map { x in x * y / (cell * cell) } }
        }
    }

    private static let mean: [Float] = [0.485, 0.456, 0.406]
    private static let deviation: [Float] = [0.229, 0.224, 0.225]

    /// The photo resized into its letterbox, ImageNet-normalized, zero elsewhere, NCHW.
    private static func tensor(_ image: CGImage, letterbox: Letterbox) throws -> MLMultiArray {
        let pixels = try ModelImage.rgb(image, width: letterbox.width, height: letterbox.height)
        let size = inputSize
        let array = try MLMultiArray(shape: [1, 3, NSNumber(value: size), NSNumber(value: size)], dataType: .float32)
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: 3 * size * size)
        pointer.initialize(repeating: 0, count: 3 * size * size)
        for y in 0 ..< letterbox.height {
            for x in 0 ..< letterbox.width {
                let source = (y * letterbox.width + x) * 3
                let target = (letterbox.top + y) * size + letterbox.left + x
                for channel in 0 ..< 3 {
                    pointer[channel * size * size + target] = (pixels[source + channel] - mean[channel]) / deviation[channel]
                }
            }
        }
        return array
    }

    private func score(tensor: MLMultiArray, boxes: [[Double]], content: [Float]) throws -> (scores: [Double], importance: [Float]) {
        let count = Self.maximumCandidates
        let boxArray = try MLMultiArray(shape: [1, NSNumber(value: count), 4], dataType: .float32)
        let boxPointer = boxArray.dataPointer.bindMemory(to: Float.self, capacity: count * 4)
        boxPointer.initialize(repeating: 0, count: count * 4)
        for (index, box) in boxes.enumerated() {
            for k in 0 ..< 4 {
                boxPointer[index * 4 + k] = Float(box[k])
            }
        }
        let contentArray = try MLMultiArray(shape: [1, 4], dataType: .float32)
        for k in 0 ..< 4 {
            contentArray[k] = NSNumber(value: content[k])
        }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(multiArray: tensor),
            "boxes": MLFeatureValue(multiArray: boxArray),
            "content": MLFeatureValue(multiArray: contentArray),
        ])
        let output = try model.prediction(from: input)
        guard let scoreArray = output.featureValue(for: "crop_scores")?.multiArrayValue,
              let importanceArray = output.featureValue(for: "importance")?.multiArrayValue
        else { throw CocoaError(.coderReadCorrupt) }
        let scores = (0 ..< boxes.count).map { scoreArray[$0].doubleValue }
        let cells = Self.mapSize * Self.mapSize
        let importance = (0 ..< cells).map { importanceArray[$0].floatValue }
        return (scores, importance)
    }

    // MARK: - Importance

    /// FocalNet's `restore_map`: the importance map without its letterbox padding, 64 × 64 over
    /// the photo, normalized at the boundary so padding cannot pull mass into the photo.
    static func restore(_ values: [Float], letterbox: Letterbox) -> [Double] {
        let grid = mapSize, size = mapSize
        let valid = letterbox.coverage(grid: grid).map { $0 > 0 ? 1.0 : 0.0 }
        let masked = zip(values, valid).map { Double($0) * $1 }
        let centers = (0 ..< size).map { (Double($0) + 0.5) / Double(size) }
        let xs = centers.map { (Double(letterbox.left) + $0 * Double(letterbox.width)) / Double(letterbox.size) * Double(grid) - 0.5 }
        let ys = centers.map { (Double(letterbox.top) + $0 * Double(letterbox.height)) / Double(letterbox.size) * Double(grid) - 0.5 }
        let numerator = sample(masked, grid: grid, xs: xs, ys: ys)
        let denominator = sample(valid, grid: grid, xs: xs, ys: ys)
        return zip(numerator, denominator).map { $0 / max($1, 1e-8) }
    }

    /// Bilinear sampling at pixel-center coordinates with edge extension (`_sample`).
    private static func sample(_ values: [Double], grid: Int, xs: [Double], ys: [Double]) -> [Double] {
        var result: [Double] = []
        result.reserveCapacity(xs.count * ys.count)
        for rawY in ys {
            let y = min(max(rawY, 0), Double(grid - 1))
            let y0 = Int(y.rounded(.down)), y1 = min(y0 + 1, grid - 1), wy = y - Double(y0)
            for rawX in xs {
                let x = min(max(rawX, 0), Double(grid - 1))
                let x0 = Int(x.rounded(.down)), x1 = min(x0 + 1, grid - 1), wx = x - Double(x0)
                let a = values[y0 * grid + x0] * (1 - wx) + values[y0 * grid + x1] * wx
                let b = values[y1 * grid + x0] * (1 - wx) + values[y1 * grid + x1] * wx
                result.append(a * (1 - wy) + b * wy)
            }
        }
        return result
    }

    /// A crop in whole pixels of the photo it was read from.
    struct PixelBox: Equatable {
        let left: Int, top: Int, width: Int, height: Int
    }

    /// A candidate in whole pixels (`HumanCropPredictor._pixel_crop`).
    static func pixelBox(_ box: [Double], width: Int, height: Int) -> PixelBox {
        let left = max(0, min(width - 1, Int(box[0] * Double(width) + 0.5)))
        let top = max(0, min(height - 1, Int(box[1] * Double(height) + 0.5)))
        let right = max(left + 1, min(width, Int(box[2] * Double(width) + 0.5)))
        let bottom = max(top + 1, min(height, Int(box[3] * Double(height) + 0.5)))
        return PixelBox(left: left, top: top, width: right - left, height: bottom - top)
    }

    /// The share of the map's importance inside a pixel box (`score_crop`).
    static func retention(of box: PixelBox, in map: [Double], width: Int, height: Int) -> Double {
        let grid = mapSize
        let values = map.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        let total = values.reduce(0, +)
        guard total > 0 else { return 0 }
        let cellWidth = Double(width) / Double(grid), cellHeight = Double(height) / Double(grid)
        let wx = (0 ..< grid).map { i in
            max(0, min(Double(i + 1) * cellWidth, Double(box.left + box.width)) - max(Double(i) * cellWidth, Double(box.left))) / cellWidth
        }
        let wy = (0 ..< grid).map { j in
            max(0, min(Double(j + 1) * cellHeight, Double(box.top + box.height)) - max(Double(j) * cellHeight, Double(box.top))) / cellHeight
        }
        var kept = 0.0
        for j in 0 ..< grid where wy[j] > 0 {
            for i in 0 ..< grid where wx[i] > 0 {
                kept += wy[j] * values[j * grid + i] * wx[i]
            }
        }
        return min(max(kept / total, 0), 1)
    }
}

/// Pixels for the models: a `CGImage` drawn at a given size into 8-bit RGB, as floats in 0…1.
nonisolated enum ModelImage {
    static func rgb(_ image: CGImage, width: Int, height: Int) throws -> [Float] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw CocoaError(.coderInvalidValue) }
        var result = [Float](repeating: 0, count: width * height * 3)
        for pixel in 0 ..< width * height {
            for channel in 0 ..< 3 {
                result[pixel * 3 + channel] = Float(bytes[pixel * 4 + channel]) / 255
            }
        }
        return result
    }
}
