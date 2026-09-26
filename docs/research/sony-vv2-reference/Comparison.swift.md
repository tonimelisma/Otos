# Native pixel comparison harness

Extract to `main.swift` in a separate directory and compile alongside
`NativeReference.swift`. Uses only Apple frameworks. This is the synchronous
research CLI, not application code. Invalid/missing inputs fail the experiment.

Arguments: model JSON, private job-array JSON, zero-based job index, output JSON,
optional luminance noise amount (or `native`), optional `save` (otherwise `nosave`),
optional RAW sharpening amount, optional RAW detail amount. Job entries need only
`id`, `raw`, and `target` strings. Make the private manifest locally for new pairs;
never commit it. The harness checks materialization before opening each original.
The default is neutral RAW sharpness/detail zero, native noise reduction, and all
eight post-sharpening candidates. Outputs include per-crop measurements and timing.

The measurement methodology and its registration limitations are in the
[native-detail research](../2026-09-23-sony-vv2-native-detail.md).

```swift
import CoreImage
import Darwin
import Foundation
import ImageIO
import simd
import Vision

let numericContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
func numericPixels(_ image: CIImage, rect: CGRect, context: CIContext = numericContext, space: CGColorSpace? = nil) -> [Float] {
    let w = Int(rect.width), h = Int(rect.height)
    var pixels = [Float](repeating: 0, count: w * h * 4)
    pixels.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: rect, format: .RGBAf, colorSpace: space) }
    return pixels
}

func localData(_ path: String) throws -> Data {
    var info = stat()
    guard lstat(path, &info) == 0, (info.st_flags & 0x4000_0000) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw NSError(domain: "notLocal", code: 1) }
    return try Data(contentsOf: URL(fileURLWithPath: path))
}

func imageOf(_ pixels: [Float], width: Int, height: Int) -> CIImage {
    CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16, size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: nil)
}

func zeroOrigin(_ image: CIImage) -> CIImage {
    image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
}

func cg(_ image: CIImage) -> CGImage {
    numericContext.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
}

func preview(_ image: CIImage, edge: CGFloat = 768) -> CIImage {
    let scale = edge / max(image.extent.width, image.extent.height)
    return zeroOrigin(image).applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale])
}

func perspective(_ image: CIImage, _ matrix: simd_float3x3, previewSize: CGSize, flipY: Bool) -> CIImage {
    let w = image.extent.width, h = image.extent.height
    func point(_ x: CGFloat, _ y: CGFloat) -> CIVector {
        let py = flipY ? h - y : y
        let v = matrix * SIMD3<Float>(Float(x / w * previewSize.width), Float(py / h * previewSize.height), 1)
        let nx = CGFloat(v.x / v.z) / previewSize.width * w; let ny = CGFloat(v.y / v.z) / previewSize.height * h
        return CIVector(x: nx, y: flipY ? h - ny : ny)
    }
    return image.applyingFilter("CIPerspectiveTransform", parameters: ["inputTopLeft": point(0, h), "inputTopRight": point(w, h), "inputBottomLeft": point(0, 0), "inputBottomRight": point(w, 0)])
}

func meanError(_ a: [Float], _ b: [Float]) -> Double {
    var s = 0.0; for i in stride(from: 0, to: min(a.count, b.count), by: 4) {
        for c in 0 ..< 3 {
            let d = Double(a[i + c] - b[i + c]); s += d * d
        }
    }
    return s / Double(min(a.count, b.count) / 4 * 3)
}

func luminance(_ pixels: [Float]) -> [Float] {
    stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] * 0.2126 + pixels[$0 + 1] * 0.7152 + pixels[$0 + 2] * 0.0722 }
}

func metrics(_ image: CIImage, _ target: [Float], _ targetHigh: [Float], _ rect: CGRect) -> [String: Double] {
    let p = numericPixels(image, rect: rect); let lum = luminance(p)
    let low = luminance(numericPixels(image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.2]), rect: rect))
    var hpMSE = 0.0, energy = 0.0, cross = 0.0, mae = 0.0
    for i in 0 ..< lum.count {
        let v = Double(lum[i] - low[i]); let t = Double(targetHigh[i]); hpMSE += (v - t) * (v - t); energy += v * v; cross += v * t
    }
    for i in stride(from: 0, to: p.count, by: 4) {
        for c in 0 ..< 3 {
            mae += abs(Double(p[i + c] - target[i + c]))
        }
    }
    return ["rgbMSE": meanError(p, target), "rgbMAE": mae / Double(p.count / 4 * 3), "highpassMSE": hpMSE / Double(lum.count), "highpassEnergy": energy / Double(lum.count), "highpassCross": cross / Double(lum.count)]
}

func refineOffset(source: [Float], target: [Float], width: Int, margin: Int) -> (Double, Double) {
    let inner = width - margin * 2
    var best = Double.infinity, bestX = 0.0, bestY = 0.0
    for dy in [-0.5, -0.25, 0.0, 0.25, 0.5] {
        for dx in [-0.5, -0.25, 0.0, 0.25, 0.5] {
            var error = 0.0
            for y in stride(from: 0, to: inner, by: 2) {
                for x in stride(from: 0, to: inner, by: 2) {
                    let px = Double(x + margin) + dx, py = Double(y + margin) + dy
                    let ix = Int(floor(px)), iy = Int(floor(py)); let fx = Float(px - Double(ix)), fy = Float(py - Double(iy))
                    let a = source[iy * width + ix] * (1 - fx) + source[iy * width + ix + 1] * fx
                    let b = source[(iy + 1) * width + ix] * (1 - fx) + source[(iy + 1) * width + ix + 1] * fx
                    let delta = Double(a * (1 - fy) + b * fy - target[y * inner + x]); error += delta * delta
                }
            }
            if error < best {
                best = error; bestX = dx; bestY = dy
            }
        }
    }
    return (bestX, bestY)
}

let args = CommandLine.arguments; let started = Date()
let model = try LookModel(json: Data(contentsOf: URL(fileURLWithPath: args[1])))
let jobs = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [[String: Any]]
let job = jobs[Int(args[3])!]; let id = job["id"] as! String
let rawData = try localData(job["raw"] as! String), targetData = try localData(job["target"] as! String)
let raw = CIRAWFilter(imageData: rawData, identifierHint: "com.sony.arw-raw-image")!
let decoder = CIRAWDecoderVersion(rawValue: "8")
guard raw.supportedDecoderVersions.contains(decoder) else { fatalError("decoder 8 unavailable") }
raw.decoderVersion = decoder; raw.scaleFactor = 1
let defaults: [String: Any] = ["luminanceNR": raw.luminanceNoiseReductionAmount, "colorNR": raw.colorNoiseReductionAmount, "sharpness": raw.sharpnessAmount, "detail": raw.detailAmount, "contrast": raw.contrastAmount, "baselineExposure": raw.baselineExposure, "shadowBias": raw.shadowBias, "temperature": raw.neutralTemperature, "tint": raw.neutralTint, "lens": raw.isLensCorrectionEnabled, "highlightRecovery": raw.isHighlightRecoveryEnabled, "gamutMapping": raw.isGamutMappingEnabled]
raw.boostAmount = 0; raw.localToneMapAmount = 0; raw.contrastAmount = 0; raw.sharpnessAmount = 0; raw.detailAmount = 0
if args.count > 5, let noise = Float(args[5]) {
    raw.luminanceNoiseReductionAmount = noise
}

if args.count > 7 {
    raw.sharpnessAmount = Float(args[7])!
}

if args.count > 8 {
    raw.detailAmount = Float(args[8])!
}

let colorContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates: true])
let encoded = CGColorSpace(name: CGColorSpace.extendedSRGB)!
let rawImage = zeroOrigin(raw.outputImage!); let targetImage = zeroOrigin(CIImage(data: targetData, options: [.applyOrientationProperty: true])!)
guard rawImage.extent.size == targetImage.extent.size else { fatalError("dimension mismatch") }
let rawCG = colorContext.createCGImage(rawImage, from: rawImage.extent, format: .RGBAh, colorSpace: encoded)!
let targetCG = colorContext.createCGImage(targetImage, from: targetImage.extent, format: .RGBAh, colorSpace: encoded)!
let neutral = CIImage(cgImage: rawCG, options: [.colorSpace: NSNull()]); let target = CIImage(cgImage: targetCG, options: [.colorSpace: NSNull()])
let metal = try MetalLook(model: model)
let rawSmall = preview(neutral), targetSmall = preview(target)
let size = CGSize(width: Int(rawSmall.extent.width.rounded()), height: Int(rawSmall.extent.height.rounded()))
let bounds = CGRect(origin: .zero, size: size)
let lookSmall = try imageOf(metal.apply(numericPixels(rawSmall, rect: bounds)), width: Int(size.width), height: Int(size.height))
let request = VNHomographicImageRegistrationRequest(targetedCGImage: cg(lookSmall), options: [:])
try VNImageRequestHandler(cgImage: cg(targetSmall), options: [:]).perform([request])
guard let matrix = request.results?.first?.warpTransform else { fatalError("global registration failed") }
let targetP = numericPixels(targetSmall, rect: bounds.insetBy(dx: 16, dy: 16))
var bestError = Double.infinity; var bestFlip = false; var bestInverse = false
for flip in [false, true] {
    for inverse in [false, true] {
        let candidate = perspective(lookSmall, inverse ? matrix.inverse : matrix, previewSize: size, flipY: flip)
        let e = meanError(numericPixels(candidate, rect: bounds.insetBy(dx: 16, dy: 16)), targetP)
        if e < bestError {
            bestError = e; bestFlip = flip; bestInverse = inverse
        }
    }
}

let registered = perspective(neutral, bestInverse ? matrix.inverse : matrix, previewSize: size, flipY: bestFlip)
let settings: [(String, Double, Double)] = [("none", 0, 1), ("r05s025", 0.25, 0.5), ("r05s05", 0.5, 0.5), ("r1s025", 0.25, 1), ("r1s05", 0.5, 1), ("r1s1", 1, 1), ("r2s025", 0.25, 2), ("r2s05", 0.5, 2)]
var patches = [[String: Any]](); let patchSize = 384
for row in 0 ..< 3 {
    for col in 0 ..< 3 {
        try autoreleasepool {
            let x = round(target.extent.width * CGFloat(col + 1) / 4 - CGFloat(patchSize) / 2), y = round(target.extent.height * CGFloat(row + 1) / 4 - CGFloat(patchSize) / 2)
            let crop = CGRect(x: x, y: y, width: CGFloat(patchSize), height: CGFloat(patchSize))
            let rawP = numericPixels(registered, rect: crop)
            let filtered = try imageOf(metal.apply(rawP), width: patchSize, height: patchSize)
            let reference = zeroOrigin(target.cropped(to: crop))
            let translation = VNTranslationalImageRegistrationRequest(targetedCGImage: cg(filtered), options: [:])
            try VNImageRequestHandler(cgImage: cg(reference), options: [:]).perform([translation])
            let transform = translation.results?.first?.alignmentTransform ?? .identity
            guard abs(transform.tx) < 24, abs(transform.ty) < 24 else { patches.append(["row": row, "column": col, "accepted": false, "tx": transform.tx, "ty": transform.ty]); return }
            let rect = CGRect(x: 24, y: 24, width: patchSize - 48, height: patchSize - 48)
            let targetPixels = numericPixels(reference, rect: rect)
            var localBest = Double.infinity; var aligned = filtered; var selectedTransform = CGAffineTransform.identity
            for tx in [transform.tx, -transform.tx] {
                for ty in [transform.ty, -transform.ty] {
                    let t = CGAffineTransform(translationX: tx, y: ty); let candidate = filtered.transformed(by: t)
                    let e = meanError(numericPixels(candidate, rect: rect), targetPixels)
                    if e < localBest {
                        localBest = e; aligned = candidate; selectedTransform = t
                    }
                }
            }
            let targetLum = luminance(targetPixels); let targetLow = luminance(numericPixels(reference.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.2]), rect: rect))
            let targetHigh = zip(targetLum, targetLow).map { $0 - $1 }
            let fullRect = CGRect(x: 0, y: 0, width: patchSize, height: patchSize)
            let sourceLum = luminance(numericPixels(aligned, rect: fullRect))
            let sourceLow = luminance(numericPixels(aligned.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.2]), rect: fullRect))
            let sourceHigh = zip(sourceLum, sourceLow).map { $0 - $1 }
            let refinement = refineOffset(source: sourceHigh, target: targetHigh, width: patchSize, margin: 24)
            var refinedError = metrics(aligned, targetPixels, targetHigh, rect)["highpassMSE"]!
            var refined = aligned
            for dy in [refinement.1, -refinement.1] {
                let candidate = aligned.transformed(by: CGAffineTransform(translationX: -refinement.0, y: dy))
                let error = metrics(candidate, targetPixels, targetHigh, rect)["highpassMSE"]!
                if error < refinedError {
                    refinedError = error; refined = candidate
                }
            }
            aligned = refined
            var scores = [String: Any]()
            for (name, strength, radius) in settings {
                let im = strength == 0 ? aligned : aligned.clampedToExtent().applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": strength, "inputRadius": radius]).cropped(to: aligned.extent)
                let bounded = im.applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0), "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
                scores[name] = metrics(bounded, targetPixels, targetHigh, rect)
            }
            patches.append(["row": row, "column": col, "accepted": true, "tx": selectedTransform.tx, "ty": selectedTransform.ty, "scores": scores, "targetHighpassEnergy": targetHigh.reduce(0.0) { $0 + Double($1 * $1) } / Double(targetHigh.count), "fractionalOffsetX": refinement.0, "fractionalOffsetY": refinement.1])
            if args.count > 6, args[6] == "save" {
                let dir = URL(fileURLWithPath: args[4]).deletingLastPathComponent().appendingPathComponent(id + "-crops"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for (name, im) in [("base", aligned), ("target", reference), ("sharp", aligned.clampedToExtent().applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": 0.5, "inputRadius": 1]))] {
                    try numericContext.writePNGRepresentation(of: im.cropped(to: rect), to: dir.appendingPathComponent("\(row)-\(col)-\(name).png"), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                }
            }
        }
    }
}

let result: [String: Any] = ["id": id, "width": rawCG.width, "height": rawCG.height, "decoder": raw.decoderVersion.rawValue, "defaults": defaults, "noiseReduction": raw.luminanceNoiseReductionAmount, "rawSharpness": raw.sharpnessAmount, "rawDetail": raw.detailAmount, "globalPreviewMSE": bestError, "globalFlip": bestFlip, "globalInverse": bestInverse, "patches": patches, "seconds": Date().timeIntervalSince(started)]
try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: URL(fileURLWithPath: args[4]))
print("id=\(id) native=\(rawCG.width)x\(rawCG.height) accepted=\(patches.filter { ($0["accepted"] as? Bool) == true }.count)/9 seconds=\(Date().timeIntervalSince(started)) defaults=\(defaults)")
```
