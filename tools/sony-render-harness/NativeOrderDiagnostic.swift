import CoreImage
import Foundation

/// Development-only order audit. The shared Metal look runs on native RAW
/// pixels before managed reduction. A previously exported HEIF checks this
/// pre-encoding observation independently; target pixels never enter the look.
func nativeOrderDiagnostic(_ pair: Pair, recipe: AuthoredLook,
                           candidateURL: URL, destination: URL) throws
{
    guard pair.role == .selection || pair.role == .regression,
          !FileManager.default.fileExists(atPath: destination.path)
    else { throw HarnessError.invalidManifest }
    try validate(Manifest(pairs: [pair]), output: destination)
    let span = OtosSignpost.rendering.beginInterval("NativeOrderAudit")
    defer { OtosSignpost.rendering.endInterval("NativeOrderAudit", span) }
    let started = Date()
    try Task.checkCancellation()
    let development = try NativeRAWDevelopment.develop(localData(pair.raw), recipe: recipe.input)
    let full = try development.linearFrame()
    let look = try MetalAuthoredLook(recipe)
    // Runtime emits encoded sRGB numbers and tags them at the HEIF writer.
    // Recreate that boundary explicitly before colour-managed Lanczos reduction.
    let transformed = try look.apply(full.rgba)
    try Task.checkCancellation()
    let native = try nativeOrderReducedFrame(RGBFrame(width: full.width, height: full.height, rgba: transformed))
    // Existing initializer: numerically reduce linear BT.2020 first, then look.
    let linearReduced = scaled(image(full).settingAlphaOne(in: CGRect(x: 0, y: 0, width: full.width, height: full.height)))
    let small = frame(linearReduced, width: Int(linearReduced.extent.width.rounded()),
                      height: Int(linearReduced.extent.height.rounded()))
    let initializer = try RGBFrame(width: small.width, height: small.height, rgba: look.apply(small.rgba))
    guard let exportedImage = try CIImage(data: localData(candidateURL.path), options: [.applyOrientationProperty: true]),
          let targetImage = try CIImage(data: localData(pair.target), options: [.applyOrientationProperty: true]),
          zeroOrigin(exportedImage).extent.size == CGSize(width: full.width, height: full.height),
          zeroOrigin(targetImage).extent.size == CGSize(width: full.width, height: full.height)
    else { throw HarnessError.incompatibleDimensions }
    let exported = try matchingReducedFrame(exportedImage), target = try matchingReducedFrame(targetImage)
    func score(_ a: RGBFrame, _ b: RGBFrame) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(colorScore(candidate: a, target: b)))
    }
    let report: [String: Any] = try [
        "contractVersion": 1, "id": pair.id, "role": pair.role.rawValue,
        "validationEvidence": false, "registered": false,
        "nativeWidth": full.width, "nativeHeight": full.height,
        "nativePreencodingVsExport": score(native, exported),
        "reducedInitializerVsNativeOrder": score(initializer, native),
        "nativePreencodingVsTarget": score(native, target),
        "exportVsTarget": score(exported, target),
        "reducedInitializerVsTarget": score(initializer, target),
        "elapsedMs": Date().timeIntervalSince(started) * 1000,
    ]
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: destination, options: .withoutOverwriting)
    OtosLog.rendering.noticeOperation("matching.nativeOrderAudit", phase: "complete", fields: [
        "id": pair.id, "elapsedMs": String(Date().timeIntervalSince(started) * 1000),
    ])
    print("op=matching.nativeOrderAudit id=\(pair.id) native=\(full.width)x\(full.height) output=\(destination.path)")
}

private func matchingReducedFrame(_ source: CIImage) throws -> RGBFrame {
    let reduced = try encodedImage(scaled(source))
    return frame(reduced, width: Int(reduced.extent.width.rounded()),
                 height: Int(reduced.extent.height.rounded()))
}

private func nativeOrderReducedFrame(_ pixels: RGBFrame) throws -> RGBFrame {
    let tagged = CIImage(bitmapData: pixels.rgba.withUnsafeBytes { Data($0) },
                         bytesPerRow: pixels.width * 16,
                         size: CGSize(width: pixels.width, height: pixels.height),
                         format: .RGBAf, colorSpace: displaySpace)
    return try matchingReducedFrame(tagged)
}

/// Bounded whole-image expression diagnostic, not an inference recipe. Geometry
/// and reliability come from the unchanged RAW baseline report. Only four current
/// global controls vary; all target-dependent fitting remains offline.
func refineNativeOrder(_ pair: Pair, base: AuthoredLook, card: AppearanceLookCard,
                       geometryReport: Data, destination: URL) throws
{
    try card.validate()
    guard pair.role == .regression, pair.session == String(pair.id.prefix(8)),
          !FileManager.default.fileExists(atPath: destination.path),
          let regions = card.regions[pair.id],
          let report = try JSONSerialization.jsonObject(with: geometryReport) as? [String: Any],
          report["formatVersion"] as? Int == 7,
          let rows = report["scores"] as? [[String: Any]], rows.count == regions.count,
          let digest = report["geometryBaselineSHA256"] as? String, !digest.isEmpty
    else { throw HarnessError.invalidManifest }
    try validate(Manifest(pairs: [pair]), output: destination)
    try Task.checkCancellation()
    let span = OtosSignpost.rendering.beginInterval("NativeOrderRefine")
    defer { OtosSignpost.rendering.endInterval("NativeOrderRefine", span) }
    let started = Date()
    let full = try NativeRAWDevelopment.develop(localData(pair.raw), recipe: base.input).linearFrame()
    guard let decoded = try CIImage(data: localData(pair.target), options: [.applyOrientationProperty: true]),
          zeroOrigin(decoded).extent.size == CGSize(width: full.width, height: full.height)
    else { throw HarnessError.incompatibleDimensions }
    let target = try gaussianBlur(matchingReducedFrame(decoded))
    struct Observation { let x: Double
        let y: Double
        let target: SIMD3<Double>
        let weight: Double
    }
    var observations = [Observation](), reliable = [String]()
    for (region, row) in zip(regions, rows) {
        guard row["name"] as? String == region.name else { throw HarnessError.invalidManifest }
        guard let sensitivity = row["meanDE00Sensitivity"] as? Double, sensitivity.isFinite, sensitivity >= 0,
              sensitivity <= card.maximumSensitivityDE00,
              let correspondence = row["correspondence"] as? [String: Any],
              correspondence["status"] as? String == "measured-local",
              let dx = correspondence["dx"] as? Double, let dy = correspondence["dy"] as? Double,
              dx.isFinite, dy.isFinite else { continue }
        let q = region.rectangle
        var samples = [Observation]()
        for y in stride(from: Int(q[1] * Double(target.height)) + 8, to: Int(q[3] * Double(target.height)) - 8, by: 8) {
            for x in stride(from: Int(q[0] * Double(target.width)) + 8, to: Int(q[2] * Double(target.width)) - 8, by: 8) {
                let u = Double(x) + dx, v = Double(y) + dy
                guard u >= 0, v >= 0, u < Double(target.width - 1), v < Double(target.height - 1) else { continue }
                let i = (y * target.width + x) * 4
                let rgb = SIMD3(Double(target.rgba[i]), Double(target.rgba[i + 1]), Double(target.rgba[i + 2]))
                guard (0 ..< 3).allSatisfy({ rgb[$0].isFinite }) else { throw HarnessError.malformedReferenceData }
                let bounded = SIMD3(min(1, max(0, rgb.x)), min(1, max(0, rgb.y)), min(1, max(0, rgb.z)))
                samples.append(Observation(x: u, y: v, target: DisplayColourObjective.normalizedLab.coordinates(bounded), weight: 1))
            }
        }
        guard !samples.isEmpty else { continue }
        reliable.append(region.name)
        observations += samples.map { Observation(x: $0.x, y: $0.y, target: $0.target, weight: 1 / Double(samples.count)) }
    }
    guard reliable.count >= 8, observations.count >= 128 else { throw HarnessError.registrationFailed }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let baseObject = try JSONSerialization.jsonObject(with: encoder.encode(base)) as! [String: Any]
    let names = ["contrast", "tonePivot", "skew", "saturation"]
    let bounds = [0.5 ... 2.5, 0.01 ... 8, 0.3 ... 3, 0.5 ... 1.5]
    func recipe(_ parameters: [Double]) throws -> AuthoredLook {
        var object = baseObject
        for (i, name) in names.enumerated() {
            object[name] = min(bounds[i].upperBound, max(bounds[i].lowerBound, exp(parameters[i])))
        }
        return try AuthoredLook(json: JSONSerialization.data(withJSONObject: object))
    }
    var evaluations = [[String: Any]]()
    func loss(_ look: AuthoredLook) throws -> Double {
        try Task.checkCancellation()
        let transformed = try MetalAuthoredLook(look).apply(full.rgba)
        let pixels = try gaussianBlur(nativeOrderReducedFrame(RGBFrame(width: full.width, height: full.height, rgba: transformed)))
        var total = 0.0
        for sample in observations {
            let x = Int(sample.x), y = Int(sample.y), fx = sample.x - Double(x), fy = sample.y - Double(y)
            var rgb = SIMD3<Double>(repeating: 0)
            for (ox, oy, weight) in [(0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)), (0, 1, (1 - fx) * fy), (1, 1, fx * fy)] {
                let i = ((y + oy) * pixels.width + x + ox) * 4
                rgb += SIMD3(Double(pixels.rgba[i]), Double(pixels.rgba[i + 1]), Double(pixels.rgba[i + 2])) * weight
            }
            let bounded = SIMD3(min(1, max(0, rgb.x)), min(1, max(0, rgb.y)), min(1, max(0, rgb.z)))
            let e = DisplayColourObjective.normalizedLab.coordinates(bounded) - sample.target
            total += sample.weight * (e.x * e.x + e.y * e.y + e.z * e.z)
        }
        total /= Double(reliable.count)
        evaluations.append(["loss": total, "contrast": look.contrast, "tonePivot": look.tonePivot, "skew": look.skew, "saturation": look.saturation])
        print("op=matching.nativeOrderRefine id=\(pair.id) evaluation=\(evaluations.count) loss=\(total)")
        return total
    }
    var parameters = [log(base.contrast), log(base.tonePivot), log(base.skew), log(base.saturation)]
    var best = try loss(base)
    let initial = best
    // Two fixed passes and both directions: at most 17 native evaluations.
    // This is a local correction diagnostic, not a claim of global convergence.
    for step in [0.08, 0.04] {
        for c in 0 ..< 4 {
            let current = parameters
            for direction in [-1.0, 1.0] {
                var trial = current
                trial[c] += direction * step
                let measured = try loss(recipe(trial))
                if measured < best {
                    best = measured
                    parameters = trial
                }
            }
        }
    }
    let fitted = try recipe(parameters)
    let result: [String: Any] = ["contractVersion": 1, "id": pair.id, "validationEvidence": false,
                                 "scope": "whole-image expression; fitted targets are not validation",
                                 "geometryBaselineSHA256": digest, "reliableRegions": reliable,
                                 "samples": observations.count, "initialLoss": initial, "loss": best,
                                 "evaluations": evaluations, "elapsedMs": Date().timeIntervalSince(started) * 1000]
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        .write(to: destination.appendingPathComponent("fit.json"), options: .withoutOverwriting)
    try encoder.encode(fitted).write(to: destination.appendingPathComponent("recipe.json"), options: .withoutOverwriting)
    OtosLog.rendering.noticeOperation("matching.nativeOrderRefine", phase: "complete", fields: [
        "id": pair.id, "evaluations": String(evaluations.count), "elapsedMs": String(Date().timeIntervalSince(started) * 1000),
    ])
}
