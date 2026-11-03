import CoreGraphics
import CoreML
import Foundation

/// Auto level model guide
///
/// GeoCalib (Veicht et al., ECCV 2024; code Apache-2.0, weights CC-BY-4.0, © 2024 ETH Zurich)
/// reads the camera's roll from the pixels when the file carries no gravity reading. Its network
/// is converted to Core ML (`GeoCalib.mlpackage`, half precision: no change in accuracy measured,
/// and it keeps the file under the repository's 100 MB limit) with one function per input shape,
/// since Core ML cannot size its upsampling from a flexible input; the functions share one copy of
/// the weights. `PerspectiveFieldSolver` turns its fields into a roll and that roll's uncertainty.
///
/// Preprocessing is GeoCalib's: short side 320 (the long side truncated), then a centered crop of
/// each side to a multiple of 32, then a further centered crop to the nearest converted shape. A
/// centered crop keeps the principal point in the middle, which the solver assumes.
///
/// The NMF block of the network starts from random bases in GeoCalib; the converted model uses one
/// seeded set, so a photo always reads the same (no measured change in accuracy).
///
/// A roll is trusted only when its uncertainty is at most 3° (ADR 0045): on 114 iPhone photos with
/// calibrated gravity, that kept 61% of them, 93% within 2° and none off by more than 5°.
/// Owned by `EditAnalyzer`, which runs it on its own serial queue.
nonisolated struct AutoLevelModel {
    private let functions: [Shape: MLModel]

    struct Shape: Hashable {
        let height: Int
        let width: Int
    }

    /// See `AutoCropModel.computeUnits`.
    static let computeUnits = AutoCropModel.computeUnits
    static let shortSide = 320
    static let longSides = [320, 416, 480, 544, 640]
    static let maximumUncertainty = 3 * Double.pi / 180

    init(bundle: Bundle) throws {
        guard let url = bundle.url(forResource: "GeoCalib", withExtension: "mlmodelc") else {
            throw CocoaError(.fileNoSuchFile)
        }
        var functions: [Shape: MLModel] = [:]
        for long in Self.longSides {
            for shape in Set([Shape(height: Self.shortSide, width: long), Shape(height: long, width: Self.shortSide)]) {
                let configuration = MLModelConfiguration()
                configuration.computeUnits = Self.computeUnits
                configuration.functionName = "h\(shape.height)w\(shape.width)"
                functions[shape] = try MLModel(contentsOf: url, configuration: configuration)
            }
        }
        self.functions = functions
    }

    /// GeoCalib's roll of the photo and its uncertainty, both in radians; positive is the
    /// clockwise straighten that levels it.
    func roll(of image: CGImage) throws -> (roll: Double, uncertainty: Double)? {
        let geometry = Self.geometry(width: image.width, height: image.height)
        guard let model = functions[geometry.shape] else { return nil }
        let resized = try ModelImage.rgb(image, width: geometry.resized.width, height: geometry.resized.height)
        let height = geometry.shape.height, width = geometry.shape.width
        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: height), NSNumber(value: width)], dataType: .float32)
        let pointer = input.dataPointer.bindMemory(to: Float.self, capacity: 3 * height * width)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let source = ((y + geometry.crop.top) * geometry.resized.width + x + geometry.crop.left) * 3
                for channel in 0 ..< 3 {
                    pointer[(channel * height + y) * width + x] = resized[source + channel]
                }
            }
        }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: input)]))
        func values(_ name: String) throws -> [Float] {
            guard let array = output.featureValue(for: name)?.multiArrayValue else { throw CocoaError(.coderReadCorrupt) }
            return (0 ..< array.count).map { array[$0].floatValue }
        }
        let fields = try PerspectiveFieldSolver.Fields(
            width: width, height: height,
            up: values("up_field"), upConfidence: values("up_confidence"),
            latitude: values("latitude_field"), latitudeConfidence: values("latitude_confidence")
        )
        return PerspectiveFieldSolver.solve(fields).map { ($0.roll, $0.rollUncertainty) }
    }

    /// The resized size, the converted shape the network runs at, and the centered crop between
    /// them, following GeoCalib's `ImagePreprocessor` and `fit_to_multiple`.
    static func geometry(width: Int, height: Int) -> (resized: (width: Int, height: Int), shape: Shape, crop: (left: Int, top: Int)) {
        let aspect = Double(width) / Double(height)
        let resized = aspect >= 1
            ? (width: Int(Double(shortSide) * aspect), height: shortSide)
            : (width: shortSide, height: Int(Double(shortSide) / aspect))
        func fitted(_ side: Int) -> Int {
            let multiple = side / 32 * 32
            return longSides.last { $0 <= multiple } ?? shortSide
        }
        let shape = Shape(height: fitted(resized.height), width: fitted(resized.width))
        /// Python's floor division on the negative padding takes the extra pixel from the start.
        func start(_ from: Int, _ to: Int) -> Int {
            let pad = to - from
            return -Int((Double(pad) / 2).rounded(.down))
        }
        return (resized, shape, (start(resized.width, shape.width), start(resized.height, shape.height)))
    }
}
