import CoreImage
import CryptoKit
import Foundation

/// Upsample an aligned 3-cube additive field to the existing 9-cube. Curves,
/// decoder, input domain and runtime interpolation retain their current owners.
func nativeFieldProfile(_ data: Data, coefficients: [Double]) throws -> Data {
    guard coefficients.count == 81, coefficients.allSatisfy({ $0.isFinite && abs($0) <= 0.25 })
    else { throw HarnessError.invalidManifest }
    let model = try LookModel(json: data)
    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    var lut = model.residualLUT
    for r in 0 ..< 9 {
        for g in 0 ..< 9 {
            for b in 0 ..< 9 {
                let q = [Double(r) / 4, Double(g) / 4, Double(b) / 4]
                let lo = q.map { min(1, Int($0)) }, f = zip(q, lo).map { $0 - Double($1) }
                for dr in 0 ... 1 {
                    for dg in 0 ... 1 {
                        for db in 0 ... 1 {
                            let weight = (dr == 0 ? 1 - f[0] : f[0]) * (dg == 0 ? 1 - f[1] : f[1]) * (db == 0 ? 1 - f[2] : f[2])
                            let node = ((lo[0] + dr) * 9 + (lo[1] + dg) * 3 + lo[2] + db) * 3
                            for c in 0 ..< 3 {
                                lut[r][g][b][c] += weight * coefficients[node + c]
                            }
                        }
                    }
                }
            }
        }
    }
    object["residualLUT"] = lut
    object["note"] = "Target-assisted native colour-field diagnostic; not inference validation."
    let result = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    _ = try LookModel(json: result)
    return result
}

enum NativeFieldCurvature: String { case distance, components }

func refineNativeProfileField(_ pair: Pair, baseData: Data, card: AppearanceLookCard,
                              geometryReport: Data, geometryBaseline: Data, curvature: NativeFieldCurvature = .components, destination: URL) throws
{
    try card.validate()
    _ = try LookModel(json: baseData)
    guard pair.role == .regression, pair.session == String(pair.id.prefix(8)),
          !FileManager.default.fileExists(atPath: destination.path), let regions = card.regions[pair.id],
          let report = try JSONSerialization.jsonObject(with: geometryReport) as? [String: Any],
          report["formatVersion"] as? Int == 7,
          let rows = report["scores"] as? [[String: Any]], rows.count == regions.count,
          let digest = report["geometryBaselineSHA256"] as? String,
          digest == SHA256.hash(data: geometryBaseline).description
    else { throw HarnessError.invalidManifest }
    try validate(Manifest(pairs: [pair]), output: destination)
    let span = OtosSignpost.rendering.beginInterval("NativeProfileField")
    defer { OtosSignpost.rendering.endInterval("NativeProfileField", span) }
    let started = Date()
    let developed = try NativeRAWDevelopment.develop(localData(pair.raw), recipe: .mapped)
    let input = try encodedImage(developed.image)
    let full = frame(input, width: Int(input.extent.width.rounded()), height: Int(input.extent.height.rounded()))
    guard let decoded = try CIImage(data: localData(pair.target), options: [.applyOrientationProperty: true]),
          zeroOrigin(decoded).extent.size == CGSize(width: full.width, height: full.height)
    else { throw HarnessError.incompatibleDimensions }
    let target = try gaussianBlur(matchingReducedFrame(decoded))
    let (observations, reliable) = try nativeMatchingObservations(regions: regions, rows: rows, target: target,
                                                                  maximumSensitivity: card.maximumSensitivityDE00)
    let observationContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false,
    ])
    var evaluations = 0
    let result = try solveNativeField(weights: observations.map { $0.weight / Double(reliable.count) }) { parameters in
        try Task.checkCancellation()
        // Each evaluation owns its temporary Metal/CI/CG resources. Repeated
        // native renders otherwise retain autoreleased buffers until process exit.
        let distances = try autoreleasepool {
            let model = try LookModel(json: nativeFieldProfile(baseData, coefficients: parameters))
            let transformed = try MetalLook(model: model).apply(full.rgba)
            let native = RGBFrame(width: full.width, height: full.height, rgba: transformed)
            let tagged = CIImage(bitmapData: native.rgba.withUnsafeBytes { Data($0) }, bytesPerRow: native.width * 16,
                                 size: CGSize(width: native.width, height: native.height), format: .RGBAf, colorSpace: displaySpace)
            let reduced = scaled(tagged)
            // Float observation avoids the half-float quantization floor during
            // numerical differentiation. Output HEIF scoring remains unchanged.
            guard let cg = observationContext.createCGImage(reduced, from: reduced.extent, format: .RGBAf, colorSpace: encodedSpace)
            else { throw HarnessError.decodeFailed("native field float observation") }
            let numeric = CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
            let pixels = gaussianBlur(frame(numeric, width: Int(reduced.extent.width.rounded()), height: Int(reduced.extent.height.rounded())))
            if curvature == .distance {
                return nativeMatchingDistances(pixels, observations: observations).map { SIMD3($0, 0, 0) }
            }
            return nativeMatchingResiduals(pixels, observations: observations)
        }
        evaluations += 1
        if evaluations == 1 || evaluations % 20 == 0 {
            FileHandle.standardOutput.write(Data("op=matching.nativeFieldObserve id=\(pair.id) evaluations=\(evaluations) elapsedMs=\(Date().timeIntervalSince(started) * 1000)\n".utf8))
        }
        return distances
    }
    let output: [String: Any] = ["contractVersion": 3, "id": pair.id, "validationEvidence": false,
                                 "samplingPolicy": "full scored region, uniform budget1024",
                                 "scope": "target-assisted coupled directions inside existing profile", "curvature": curvature.rawValue,
                                 "baseModelSHA256": SHA256.hash(data: baseData).description, "geometryBaselineSHA256": digest,
                                 "reliableRegions": reliable, "samples": observations.count,
                                 "coarseDimension": 3, "coefficientBound": 0.25, "differenceStep": 0.001, "observationFormat": "RGBAf; exported HEIF gates unchanged",
                                 "maximumIterations": 6, "maximumLineSearchTrials": 20,
                                 "quadraticStep": "stabilized curvature with declared-objective gradient; rhs H*x-g", "curvatureNormFloor": 0.1,
                                 "edgePenalty": 1, "ridgePenalty": 0.1,
                                 "derivativeRelativeRMSLimit": 0.25, "derivativeFullBoundDE00Floor": 0.05,
                                 "derivativeChecks": result.derivativeChecks,
                                 "status": result.status, "initialLoss": result.initialLoss, "loss": result.loss,
                                 "coefficients": result.coefficients, "iterations": result.iterations,
                                 "evaluations": evaluations, "elapsedMs": Date().timeIntervalSince(started) * 1000]
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        .write(to: destination.appendingPathComponent("fit.json"), options: .withoutOverwriting)
    try nativeFieldProfile(baseData, coefficients: result.coefficients)
        .write(to: destination.appendingPathComponent("model.json"), options: .withoutOverwriting)
    OtosLog.rendering.noticeOperation("matching.nativeField", phase: result.status, fields: [
        "id": pair.id, "evaluations": String(evaluations), "elapsedMs": String(Date().timeIntervalSince(started) * 1000),
    ])
}

func nativeProfileFieldSelfTest() throws {
    let tail = nativeFieldMeanTail([1, 10], weights: [0.9, 0.1])
    guard abs(tail.loss - 4.4) < 1e-12, tail.effectiveWeights == [0.9, 0.35] else { throw HarnessError.malformedReferenceData }
    let result = try solveNativeField(weights: [1]) { coefficients in [SIMD3(1 - coefficients[0], 0, 0)] }
    guard abs(result.coefficients[0] - 0.25) < 1e-7, result.loss < result.initialLoss,
          result.coefficients.allSatisfy({ abs($0) <= 0.25 }),
          result.coefficients.enumerated().allSatisfy({ $0.offset % 3 == 0 || abs($0.element) < 1e-10 })
    else { throw HarnessError.malformedReferenceData }
    // A regularized quadratic step must still optimize the declared distance
    // objective when the required correction is much smaller than 0.1 DE00.
    let small = try solveNativeField(weights: [1]) { coefficients in [SIMD3(0.01 - coefficients[0], 0, 0)] }
    guard abs(small.coefficients[0] - 0.01) < 1e-5 else {
        print("Native field small-residual objective failed: error=\(abs(small.coefficients[0] - 0.01))")
        throw HarnessError.malformedReferenceData
    }
    print("Native field small-residual: error=\(abs(small.coefficients[0] - 0.01)) status=\(small.status)")
    let curve = (0 ..< 49).map { Double($0) * 1.25 / 48 }
    let base: [String: Any] = ["formatVersion": 2, "decoder": "9", "dimension": 9, "domain": [0, 1.25],
                               "curveKnots": curve, "curvesRGB": [curve, curve, curve],
                               "residualLUT": Array(repeating: Array(repeating: Array(repeating: [0.0, 0, 0], count: 9), count: 9), count: 9),
                               "neutralSettings": ["boostAmount": 0, "localToneMapAmount": 0, "contrastAmount": 0, "sharpnessAmount": 0]]
    let data = try JSONSerialization.data(withJSONObject: base)
    var coefficients = [Double](repeating: 0, count: 81)
    for r in 0 ..< 3 {
        for g in 0 ..< 3 {
            for b in 0 ..< 3 {
                let i = (r * 9 + g * 3 + b) * 3
                coefficients[i] = Double(r) * 0.02 + Double(r * g * b) * 0.001
                coefficients[i + 1] = Double(g) * -0.015
                coefficients[i + 2] = Double(b) * 0.01
            }
        }
    }
    let model = try LookModel(json: nativeFieldProfile(data, coefficients: coefficients))
    let identity = try LookModel(json: nativeFieldProfile(data, coefficients: Array(repeating: 0, count: 81)))
    var input = [Float](), expected = [[Double]]()
    for k in 1 ... 24 {
        let rgb = [Double(k) / 30, Double(25 - k) / 30, Double(k % 7 + 1) / 10]
        let wanted = [rgb[0] * (1 + 0.04 / 1.25) + 0.008 * rgb[0] * rgb[1] * rgb[2] / pow(1.25, 3), rgb[1] * (1 - 0.03 / 1.25), rgb[2] * (1 + 0.02 / 1.25)]
        guard try zip(identity.evaluateRGB(rgb), rgb).allSatisfy({ abs($0 - $1) < 1e-12 }),
              try zip(model.evaluateRGB(rgb), wanted).allSatisfy({ abs($0 - $1) < 1e-12 })
        else { throw HarnessError.malformedReferenceData }
        input += rgb.map(Float.init) + [1]
        expected.append(wanted)
    }
    let actual = try MetalLook(model: model).apply(input)
    for (i, wanted) in expected.enumerated() {
        guard (0 ..< 3).allSatisfy({ abs(Double(actual[4 * i + $0]) - wanted[$0]) < 2e-6 }), actual[4 * i + 3] == 1
        else { throw HarnessError.malformedReferenceData }
    }
    let id = "20260101_120000"
    let card = AppearanceLookCard(formatVersion: 5, maximumLightnessDifference: 2, maximumMedianDE00: 3,
                                  maximumChromaDifference: 3, maximumSensitivityDE00: 1,
                                  regions: [id: [.init(name: "fixed", rectangle: [0, 0, 1, 1])]])
    let report = try JSONSerialization.data(withJSONObject: ["formatVersion": 7, "scores": [["name": "fixed"]], "geometryBaselineSHA256": "wrong"])
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent("sony-native-field-test-\(UUID().uuidString)")
    for role in [PairRole.acceptance, .regression] {
        let pair = Pair(id: id, raw: "/synthetic-native-field/missing.arw", target: "/synthetic-native-field/unread.heif", session: "20260101", role: role)
        do {
            try refineNativeProfileField(pair, baseData: data, card: card, geometryReport: report, geometryBaseline: Data(), destination: destination)
            throw HarnessError.malformedReferenceData
        } catch HarnessError.invalidManifest {}
    }
    guard !FileManager.default.fileExists(atPath: destination.path) else { throw HarnessError.malformedReferenceData }
    print("Native field: weighted tail, known bounded optimum, identity, continuous trilinear field CPU/Metal, alpha and role/hash guards pass")
}
