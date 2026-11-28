import CoreGraphics
import Foundation
import ImageIO
@testable import OtosKit
import Testing

/// The models Auto crop and Auto straighten read with (ADR 0043), and the solver that turns
/// GeoCalib's fields into a roll and its uncertainty.
@Suite(.testScope)
struct AutoEditModelTests {
    // MARK: - Solver

    // Validates: APP-048
    /// Fields drawn from a known camera are explained exactly by it: the solver recovers the
    /// roll to a hundredth of a degree, confidently enough for Auto straighten to use it.
    @Test func theSolverRecoversTheCameraThatDrewTheFields() throws {
        let roll = 5 * Double.pi / 180, pitch = 12 * Double.pi / 180, focal = 380.0
        let fields = PerspectiveFieldSolver.Fields.camera(width: 104, height: 80, roll: roll, pitch: pitch, focal: focal)

        let solution = try #require(PerspectiveFieldSolver.solve(fields))

        #expect(abs(solution.roll - roll) * 180 / .pi < 0.01)
        #expect(abs(solution.pitch - pitch) * 180 / .pi < 0.01)
        #expect(abs(solution.focal - focal) / focal < 0.01)
        #expect(solution.rollUncertainty < AutoLevelModel.maximumUncertainty)
    }

    // Validates: APP-048
    /// Fields with no confidence anywhere constrain nothing: there is no roll to report.
    @Test func fieldsWithoutConfidenceGiveNoRoll() {
        var fields = PerspectiveFieldSolver.Fields.camera(width: 64, height: 64, roll: 0.1, pitch: 0, focal: 200)
        fields = PerspectiveFieldSolver.Fields(
            width: fields.width, height: fields.height, up: fields.up,
            upConfidence: Array(repeating: 0, count: fields.upConfidence.count),
            latitude: fields.latitude,
            latitudeConfidence: Array(repeating: 0, count: fields.latitudeConfidence.count)
        )

        #expect(PerspectiveFieldSolver.solve(fields) == nil)
    }

    // MARK: - Preprocessing and selection

    // Validates: APP-048
    /// GeoCalib's preprocessing: short side 320, the long side truncated, then centered crops
    /// to a multiple of 32 and to the nearest converted shape.
    @Test func photosRunAtTheNearestConvertedShape() {
        let landscape = AutoLevelModel.geometry(width: 4032, height: 3024)
        #expect(landscape.resized.width == 426 && landscape.resized.height == 320)
        #expect(landscape.shape == AutoLevelModel.Shape(height: 320, width: 416))
        #expect(landscape.crop.left == 5 && landscape.crop.top == 0)

        let portrait = AutoLevelModel.geometry(width: 3024, height: 4032)
        #expect(portrait.shape == AutoLevelModel.Shape(height: 416, width: 320))

        // 5:4 resizes to 400, a multiple of 32 at 384, which has no converted shape: 320.
        let nearlySquare = AutoLevelModel.geometry(width: 5000, height: 4000)
        #expect(nearlySquare.shape == AutoLevelModel.Shape(height: 320, width: 320))
        #expect(nearlySquare.crop.left == 40)
    }

    // Validates: APP-048
    /// Candidates cover ten shapes at five sizes, stay inside the frame, include the whole
    /// frame, and come sorted, as FocalNet's `np.unique` leaves them.
    @Test func candidatesSpanTheShapesInsideTheFrame() {
        let boxes = AutoCropModel.candidates(width: 1200, height: 800)

        #expect(boxes.contains([0, 0, 1, 1]))
        #expect(boxes.allSatisfy { $0[0] >= 0 && $0[1] >= 0 && $0[2] <= 1 + 1e-9 && $0[3] <= 1 + 1e-9 && $0[0] < $0[2] && $0[1] < $0[3] })
        #expect(zip(boxes, boxes.dropFirst()).allSatisfy { $0.lexicographicallyPrecedes($1) })
        #expect(Set(boxes).count == boxes.count)
    }

    // Validates: APP-048
    /// FocalNet's rule: only candidates keeping nearly the most importance compete, and the
    /// best score among them wins, however good a candidate outside them scores.
    @Test func theBestScoreWinsAmongCandidatesThatKeepTheSubject() {
        let retention = [0.98, 0.70, 0.95, 0.99]
        let scores = [0.2, 9.0, 0.5, 0.1]

        #expect(AutoCropModel.select(scores: scores, retention: retention) == 2)
    }

    // MARK: - The bundled models

    // Validates: APP-048
    /// Both models load from the framework and read a photo; the same photo always reads the
    /// same.
    @Test func theBundledModelsReadAPhotoTheSameWayEveryTime() throws {
        let url = try makeTestDirectory().appending(path: "subject.jpg")
        try writeSubjectJPEG(to: url, center: CGPoint(x: 0.8, y: 0.3))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let bundle = Bundle(for: CatalogWindowViewModel.self)

        let crop = try AutoCropModel(bundle: bundle)
        #expect(try crop.crop(of: image) == crop.crop(of: image))

        let level = try AutoLevelModel(bundle: bundle)
        let first = try level.roll(of: image)
        let second = try level.roll(of: image)
        #expect(first?.roll == second?.roll)
        #expect(first?.uncertainty == second?.uncertainty)
    }
}

extension PerspectiveFieldSolver.Fields {
    /// GeoCalib's perspective fields of a pinhole camera with the given roll, pitch and focal
    /// length, every pixel fully confident.
    static func camera(width: Int, height: Int, roll: Double, pitch: Double, focal: Double) -> Self {
        let gravity = SIMD3(-sin(roll) * cos(pitch), -cos(roll) * cos(pitch), sin(pitch))
        var upX: [Float] = [], upY: [Float] = [], latitude: [Float] = []
        for y in 0 ..< height {
            for x in 0 ..< width {
                let u = (Double(x) - Double(width) / 2) / focal
                let v = (Double(y) - Double(height) / 2) / focal
                let px = gravity.x - gravity.z * u, py = gravity.y - gravity.z * v
                let length = (px * px + py * py).squareRoot()
                upX.append(Float(px / length))
                upY.append(Float(py / length))
                let ray = SIMD3(u, v, 1) / (u * u + v * v + 1).squareRoot()
                latitude.append(Float(asin((ray * gravity).sum())))
            }
        }
        let ones = [Float](repeating: 1, count: width * height)
        return Self(
            width: width, height: height, up: upX + upY, upConfidence: ones,
            latitude: latitude, latitudeConfidence: ones
        )
    }
}
