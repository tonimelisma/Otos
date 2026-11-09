import CoreGraphics
import CoreML
import Foundation

/// Face embedding model guide
///
/// AdaFace IR-101 trained on WebFace12M (CVLFace weights), converted to Core ML with 8-bit
/// linear per-channel weights (`AdaFaceIR101.mlpackage`, 66 MB; ADR 0047). It takes one aligned
/// 112 × 112 RGB face, with the model's normalisation folded into the image input, and returns
/// a unit-length 512-d embedding; two faces of one person have a high cosine.
///
/// Chosen on the owner's labelled photos (`docs/research/2026-11-07-face-recognition-models.md`):
/// it never mistook one of the owner's children for a sibling, and 8-bit weights changed no
/// decision on a child's face against full precision.
///
/// Owned by `FaceAnalyzer`, which runs it on its own serial queue.
nonisolated struct FaceEmbeddingModel {
    /// The length of an embedding.
    static let dimensions = 512

    /// CPU only, as ADR 0045 runs every Otos model: concurrent GPU predictions deadlocked
    /// inside MPSGraph, and the CPU reads a face in about 33 ms, small next to decoding the
    /// original it came from.
    static let computeUnits = MLComputeUnits.cpuOnly

    private let model: MLModel
    private let constraint: MLImageConstraint

    enum ModelError: Error {
        case missingResource
        case unexpectedInterface
        case unexpectedOutput
    }

    init(bundle: Bundle) throws {
        guard let url = bundle.url(forResource: "AdaFaceIR101", withExtension: "mlmodelc") else {
            throw ModelError.missingResource
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = Self.computeUnits
        model = try MLModel(contentsOf: url, configuration: configuration)
        guard let constraint = model.modelDescription.inputDescriptionsByName["face"]?.imageConstraint,
              constraint.pixelsWide == FaceAlignment.side, constraint.pixelsHigh == FaceAlignment.side
        else {
            throw ModelError.unexpectedInterface
        }
        self.constraint = constraint
    }

    /// The embedding of an aligned, opaque 112 × 112 face crop.
    func embedding(of crop: CGImage) throws -> [Float] {
        let input = try MLFeatureValue(cgImage: crop, constraint: constraint)
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["face": input]))
        guard let array = output.featureValue(for: "embedding")?.multiArrayValue,
              array.count == Self.dimensions
        else {
            throw ModelError.unexpectedOutput
        }
        return (0 ..< array.count).map { array[$0].floatValue }
    }
}
