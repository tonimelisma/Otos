import Foundation

/// Invalid calibration inputs must stop before producing a model or reading
/// media. The only bytes here are synthetic sampled-pixel fixtures in a private
/// temporary directory; the declared originals do not exist.
func lookCalibrationSelfTest() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("sony-calibration-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func manifest(_ role: PairRole) -> Manifest {
        Manifest(pairs: (0 ..< 100).map {
            Pair(id: "sample\($0)", raw: "/synthetic-calibration-originals/\($0).arw",
                 target: "/synthetic-calibration-originals/\($0).hif", session: "synthetic", role: role)
        })
    }
    let destination = root.appendingPathComponent("model.json")
    do {
        try fitLookCalibration(manifest(.acceptance), samplesRoot: root, destination: destination)
        throw HarnessError.malformedReferenceData
    } catch LookCalibrationError.invalidTrainingManifest {}
    guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw HarnessError.malformedReferenceData
    }
    let input = root.appendingPathComponent("sample0")
    try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
    let samples = input.appendingPathComponent("samples.f32")
    try Data([1, 2, 3]).write(to: samples)
    do {
        try fitLookCalibration(manifest(.training), samplesRoot: root, destination: destination)
        throw HarnessError.malformedReferenceData
    } catch LookCalibrationError.invalidSamples {}
    var invalid = [Float](repeating: 0.5, count: 500 * 6)
    let recipe: [String: Any] = [
        "contractVersion": 2, "decoder": "9", "samples": 500,
        "nativeLensCorrectionEnabled": true, "calibrationBlurRadius": 1.2,
        "evaluationLongEdge": 768,
        "neutralSettings": ["boostAmount": 0, "localToneMapAmount": 0, "contrastAmount": 0, "sharpnessAmount": 0],
    ]
    let recipePath = input.appendingPathComponent("recipe.json")
    try JSONSerialization.data(withJSONObject: recipe).write(to: recipePath)
    invalid[0] = .nan
    try invalid.withUnsafeBytes { try Data($0).write(to: samples) }
    do {
        try fitLookCalibration(manifest(.training), samplesRoot: root, destination: destination)
        throw HarnessError.malformedReferenceData
    } catch LookCalibrationError.invalidSamples {}
    guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw HarnessError.malformedReferenceData
    }
    invalid[0] = 0.5
    try invalid.withUnsafeBytes { try Data($0).write(to: samples) }
    var wrongRecipe = recipe
    wrongRecipe["decoder"] = "8"
    try JSONSerialization.data(withJSONObject: wrongRecipe).write(to: recipePath)
    do {
        try fitLookCalibration(manifest(.training), samplesRoot: root, destination: destination)
        throw HarnessError.malformedReferenceData
    } catch LookCalibrationError.invalidSamples {}
    let existing = Data("preserve calibration".utf8)
    try existing.write(to: destination)
    do {
        try fitLookCalibration(manifest(.training), samplesRoot: root, destination: destination)
        throw HarnessError.malformedReferenceData
    } catch LookCalibrationError.existingOutput {}
    guard try Data(contentsOf: destination) == existing else { throw HarnessError.malformedReferenceData }
    let unsupported = root.appendingPathComponent("unsupported.arw")
    try Data("synthetic unsupported image".utf8).write(to: unsupported)
    let pair = Pair(id: "unsupported", raw: unsupported.path,
                    target: root.appendingPathComponent("unread-target.hif").path,
                    session: "synthetic", role: .training)
    do {
        try exportLookCalibrationPair(pair, output: root)
        throw HarnessError.malformedReferenceData
    } catch SonySensorRAWHEIFRenderer.Failure.unsupportedOriginal {}
    guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(pair.id).path) else {
        throw HarnessError.malformedReferenceData
    }
    print("Calibration holdout-role, malformed/non-finite sample, unsupported original and no-overwrite fixtures: pass")
}
