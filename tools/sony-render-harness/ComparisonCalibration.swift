import CoreImage
import Foundation

/// Offline evaluator calibration on already-used development images. Deliberate
/// defects characterize measurement response; they do not train the renderer or
/// establish perceptual acceptability thresholds.
func comparisonCalibration(_ pair: Pair, destination: URL, nativeCrop: Bool = false) throws {
    guard pair.role == .selection || pair.role == .regression else { throw HarnessError.invalidManifest }
    let sourcePath = pair.target
    let inputDirectory = URL(fileURLWithPath: sourcePath).deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
    let outputDirectory = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
    guard outputDirectory != inputDirectory, !outputDirectory.hasPrefix(inputDirectory + "/"),
          !FileManager.default.fileExists(atPath: destination.path),
          let decoded = try CIImage(data: localData(sourcePath), options: [.applyOrientationProperty: true]) else { throw HarnessError.invalidManifest }
    let source = zeroOrigin(decoded)
    let cropSide = min(768.0, min(source.extent.width, source.extent.height))
    let crop = CGRect(x: ((source.extent.width - cropSide) / 2).rounded(.down), y: ((source.extent.height - cropSide) / 2).rounded(.down), width: cropSide, height: cropSide)
    let preview = try encodedImage(nativeCrop ? zeroOrigin(source.cropped(to: crop)) : scaled(source))
    let decodedFrame = frame(preview, width: Int(preview.extent.width), height: Int(preview.extent.height))
    // Isolate injected defects from the display gamut boundary. Extended decoded
    // values are reported separately; every perturbation uses the same bounded
    // sRGB reference rather than adding an unrelated clamp outside its region.
    let target = RGBFrame(width: decodedFrame.width, height: decodedFrame.height,
                          rgba: decodedFrame.rgba.enumerated().map { $0.offset % 4 == 3 ? $0.element : min(1, max(0, $0.element)) })
    func decode(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    func encode(_ v: Double) -> Double {
        v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
    func transform(_ input: RGBFrame, clamp: Bool = true, _ operation: (Int, Int, Int, Double) -> Double) -> RGBFrame {
        var output = input.rgba
        for y in 0 ..< input.height {
            for x in 0 ..< input.width {
                for c in 0 ..< 3 {
                    let i = (y * input.width + x) * 4 + c
                    let value = operation(x, y, c, Double(input.rgba[i]))
                    output[i] = Float(clamp ? min(1, max(0, value)) : value)
                }
            }
        }
        return RGBFrame(width: input.width, height: input.height, rgba: output)
    }
    func linearBlur(_ input: RGBFrame) -> RGBFrame {
        let linear = transform(input, clamp: false) { _, _, _, v in decode(v) }
        let blurred = gaussianBlur(linear)
        return transform(blurred, clamp: false) { _, _, _, v in encode(v) }
    }
    func shifted(_ input: RGBFrame, pixels: Double) -> RGBFrame {
        var result = input.rgba
        for y in 0 ..< input.height {
            for x in 0 ..< input.width {
                let u = min(Double(input.width - 1), max(0, Double(x) + pixels))
                let ix = Int(u), f = Float(u - Double(ix))
                for c in 0 ..< 4 {
                    result[(y * input.width + x) * 4 + c] = input.rgba[(y * input.width + ix) * 4 + c] * (1 - f)
                        + input.rgba[(y * input.width + min(input.width - 1, ix + 1)) * 4 + c] * f
                }
            }
        }
        return RGBFrame(width: input.width, height: input.height, rgba: result)
    }
    let blurred = gaussianBlur(target, sigma: 1)
    var variants: [(String, RGBFrame)] = [("identity", target)]
    variants.append(("colour-roundtrip", transform(target, clamp: false) { _, _, _, v in encode(decode(v)) }))
    for ev in [-0.1, 0.1] {
        variants.append(("exposure-\(ev)", transform(target) { _, _, _, v in encode(decode(v) * pow(2, ev)) }))
    }
    variants.append(("saturation-plus5percent", transform(target) { x, y, _, v in
        let i = (y * target.width + x) * 4
        let l = 0.2126 * decode(Double(target.rgba[i])) + 0.7152 * decode(Double(target.rgba[i + 1])) + 0.0722 * decode(Double(target.rgba[i + 2]))
        return encode(max(0, l + 1.05 * (decode(v) - l)))
    }))
    variants.append(("local-red-cast", transform(target) { x, y, c, v in
        x > target.width / 3 && x < target.width * 2 / 3 && y > target.height / 3 && y < target.height * 2 / 3 && c == 0 ? v + 0.04 : v
    }))
    variants.append(("opposing-red-casts", transform(target) { x, _, c, v in c == 0 ? v + (x < target.width / 2 ? 0.04 : -0.04) : v }))
    variants.append(("highlight-clipping", transform(target) { _, _, _, v in min(v, 0.85) }))
    variants.append(("blur-sigma1", blurred))
    variants.append(("sharpen-halo", transform(target) { x, y, c, v in v + 0.8 * (v - Double(blurred.rgba[(y * target.width + x) * 4 + c])) }))
    variants.append(("deterministic-noise", transform(target) { x, y, c, v in
        let hash = UInt32(truncatingIfNeeded: x * 73_856_093 ^ y * 19_349_663 ^ c * 83_492_791)
        return v + (Double(hash % 1024) / 1023 - 0.5) * 0.04
    }))
    for shift in [0.25, 1.0, 2.0] {
        variants.append(("shift-\(shift)-evaluation-pixels", shifted(target, pixels: shift)))
    }
    let root = destination.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let assets = root.appendingPathComponent(destination.deletingPathExtension().lastPathComponent + "-assets")
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: false)
    try writePNG(image(target), to: assets.appendingPathComponent("target.png"))
    var results = [[String: Any]]()
    for (name, candidate) in variants {
        let old = try colorScore(candidate: candidate, target: target)
        let a = linearBlur(candidate), b = linearBlur(target)
        // score without another blur: the unblurred fields are the alternate
        // linear-light-prepared result. Historical fields remain untouched.
        let alternate = try colorScore(candidate: a, target: b)
        let region = AppearanceLookCard.Region(name: "central-third", rectangle: [1.0 / 3, 1.0 / 3, 2.0 / 3, 2.0 / 3])
        let card = AppearanceLookCard(formatVersion: 5, maximumLightnessDifference: 2, maximumMedianDE00: 3,
                                      maximumChromaDifference: 3, maximumSensitivityDE00: 1, regions: ["calibration": [region]])
        let local = try appearanceRegionScores(candidate: candidate, target: target, regions: [region], card: card, correspondences: [.identity])[0]
        var knownShiftRecovery: Double?
        if name.hasPrefix("shift-"), let shift = Double(name.split(separator: "-")[1]) {
            let correspondence = RegionCorrespondence(status: .measuredLocal, dx: -shift, dy: 0,
                                                      supportRadius: 0, reliableMatches: 0, supportPaddingNativePixels: 0)
            knownShiftRecovery = try appearanceRegionScores(candidate: candidate, target: target, regions: [region], card: card, correspondences: [correspondence])[0].meanLowFrequencyDE00
            if shift == 1 || shift == 2 {
                guard knownShiftRecovery! < 0.0001 else { throw ReferenceError.invalidPixels }
            }
        }
        let low = gaussianBlur(candidate), targetLow = gaussianBlur(target)
        var map = target.rgba
        for i in stride(from: 0, to: map.count, by: 4) {
            let a = Lab.srgb(Double(low.rgba[i]), Double(low.rgba[i + 1]), Double(low.rgba[i + 2]))
            let b = Lab.srgb(Double(targetLow.rgba[i]), Double(targetLow.rgba[i + 1]), Double(targetLow.rgba[i + 2]))
            let intensity = Float(min(1, ciede2000(a, b) / 10))
            map[i] = intensity
            map[i + 1] = 0
            map[i + 2] = 0
            map[i + 3] = 1
        }
        try writePNG(image(candidate), to: assets.appendingPathComponent(name + ".png"))
        try writePNG(image(RGBFrame(width: target.width, height: target.height, rgba: map)), to: assets.appendingPathComponent(name + "-DE00-map.png"))
        try results.append(["perturbation": name, "historical": JSONSerialization.jsonObject(with: JSONEncoder().encode(old)),
                            "linearLightGaussianMeanDE00": alternate.meanUnblurredDE00,
                            "linearLightGaussianP95DE00": alternate.p95UnblurredDE00,
                            "centralRegion": JSONSerialization.jsonObject(with: JSONEncoder().encode(local)),
                            "knownShiftRecoveredRegionMeanDE00": knownShiftRecovery.map { $0 as Any } ?? NSNull()])
        print("op=comparison.calibration case=\(name) mean=\(old.meanLowFrequencyDE00) unblurred=\(old.meanUnblurredDE00) region=\(local.meanLowFrequencyDE00)")
        if name == "identity" {
            guard old.meanUnblurredDE00 == 0, old.meanLowFrequencyDE00 == 0 else { throw ReferenceError.invalidPixels }
        }
        if name == "colour-roundtrip" {
            guard old.meanUnblurredDE00 < 0.0001 else { throw ReferenceError.invalidPixels }
        }
    }
    let report: [String: Any] = try ["formatVersion": 3, "id": pair.id, "session": pair.session, "role": pair.role.rawValue, "source": sourcePath, "width": target.width, "height": target.height,
                                     "scale": nativeCrop ? "central native crop, no resize" : "768 long edge whole-view",
                                     "historicalPreparation": "encoded sRGB Gaussian sigma1.2; inset8",
                                     "mapLegend": "red intensity is DE00/10, clipped at10; PNG preview only",
                                     "alternatePreparation": "same resampled input; linear sRGB Gaussian sigma1.2 then sRGB encoding; not S-CIELAB",
                                     "viewingConditions": "not perceptually calibrated",
                                     "calibrationTarget": "decoded/resampled encoded sRGB clamped to display range before perturbations",
                                     "preparationClampScore": JSONSerialization.jsonObject(with: JSONEncoder().encode(colorScore(candidate: target, target: decodedFrame))),
                                     "inputMinimumRGB": decodedFrame.rgba.enumerated().filter { $0.offset % 4 != 3 }.map(\.element).min()!,
                                     "inputMaximumRGB": decodedFrame.rgba.enumerated().filter { $0.offset % 4 != 3 }.map(\.element).max()!,
                                     "inputOutOfGamutChannels": decodedFrame.rgba.enumerated().filter { $0.offset % 4 != 3 && ($0.element < 0 || $0.element > 1) }.count,
                                     "results": results]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .atomic)
}
