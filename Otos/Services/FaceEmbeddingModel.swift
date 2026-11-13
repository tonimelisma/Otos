import Accelerate
import CoreGraphics
import CoreML
import Foundation

/// Face embedding model guide
///
/// AdaFace IR-101 trained on WebFace12M (CVLFace weights), converted to Core ML with 8-bit
/// linear per-channel weights (`AdaFaceIR101.mlpackage`, 66 MB; ADR 0047). It takes one aligned
/// 112 × 112 RGB face, with the model's normalisation folded into the image input, and returns
/// a 512-d `FaceEmbedding`; two faces of one person have a high cosine.
///
/// Chosen on the owner's labelled photos (`docs/research/2026-11-07-face-recognition-models.md`):
/// it never mistook one of the owner's children for a sibling, and 8-bit weights changed no
/// decision on a child's face against full precision.
///
/// Owned by `FaceAnalyzer`, which runs it on its own serial queue.
nonisolated struct FaceEmbeddingModel {
    /// The length of an embedding.
    static let dimensions = 512
    /// The compiled model's name in the app bundle.
    static let resourceName = "AdaFaceIR101"

    /// CPU only, as ADR 0045 runs every Otos model: concurrent GPU predictions deadlocked
    /// inside MPSGraph, and the CPU reads a face in about 33 ms.
    static let computeUnits = MLComputeUnits.cpuOnly

    private let model: MLModel
    private let constraint: MLImageConstraint

    enum ModelError: Error {
        case missingResource
        case unexpectedInterface
        case unexpectedOutput
    }

    init(bundle: Bundle) throws {
        guard let url = BundledModel.url(named: Self.resourceName, in: bundle) else {
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
    func embedding(of crop: CGImage) throws -> FaceEmbedding {
        let input = try MLFeatureValue(cgImage: crop, constraint: constraint)
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["face": input]))
        guard let array = output.featureValue(for: "embedding")?.multiArrayValue,
              let embedding = FaceEmbedding(normalizing: (0 ..< array.count).map { array[$0].floatValue })
        else {
            throw ModelError.unexpectedOutput
        }
        return embedding
    }
}

/// A face's embedding: `FaceEmbeddingModel.dimensions` values of unit length.
///
/// Every face rule (ADR 0047) is a cosine, and assignment computes cosines as plain dot
/// products over a matrix of these, so unit length is part of the type rather than a promise
/// each producer keeps: the only ways to make one are to scale values to unit length or to
/// read back stored values that still are.
nonisolated struct FaceEmbedding: Sendable, Equatable {
    let values: [Float]

    /// How far a stored embedding's squared length may sit from 1: every embedding in the
    /// owner's catalog is within 2.2e-7 of it, as float rounding leaves a scaled vector.
    private static let storedTolerance: Float = 1e-4

    /// `values` scaled to unit length; nil unless there are `FaceEmbeddingModel.dimensions`
    /// of them with a finite, non-zero length.
    init?(normalizing values: [Float]) {
        guard values.count == FaceEmbeddingModel.dimensions else { return nil }
        let length = vDSP.sumOfSquares(values).squareRoot()
        guard length.isFinite, length > 0 else { return nil }
        self.values = vDSP.divide(values, length)
    }

    /// Values read back from the catalog, kept bit for bit so a face reads back equal to the
    /// one written; nil unless there are `FaceEmbeddingModel.dimensions` of them and they
    /// are still unit length.
    init?(stored values: [Float]) {
        guard values.count == FaceEmbeddingModel.dimensions,
              abs(vDSP.sumOfSquares(values) - 1) < Self.storedTolerance
        else { return nil }
        self.values = values
    }

    /// The cosine of two embeddings.
    func cosine(with other: FaceEmbedding) -> Float {
        vDSP.dot(values, other.values)
    }
}
