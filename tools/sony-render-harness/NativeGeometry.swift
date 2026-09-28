import CoreImage
import Foundation

struct NativeGeometryScore: Encodable {
    let attempted: Int
    let reliable: Int
    let sufficientCoverage: Bool
    let medianResidualPixels: Double?
    let p95ResidualPixels: Double?
    let edgeP95ResidualPixels: Double?
    let medianCorrelation: Double?
    let rejectedFlat: Int
    let rejectedAmbiguous: Int
    let rejectedSearchBoundary: Int
    let points: [NativeGeometryPoint]
}

struct NativeGeometryPoint: Encodable {
    let x: Double
    let y: Double
    let dx: Double
    let dy: Double
    let correlation: Double
}

private enum NativeMatchResult {
    case reliable(dx: Double, dy: Double, correlation: Double, anchorX: Int, anchorY: Int)
    case flat, ambiguous, searchBoundary
}

/// The two 192-pixel tiles remain in their original native geometry. A coarse
/// two-pixel search finds the likely displacement; one-pixel refinement and a
/// local quadratic peak estimate keep the measurement independent of the
/// 768-pixel Vision homography used only by the color scorecard.
private func matchNativeTile(_ source: RGBFrame, _ target: RGBFrame) -> NativeMatchResult {
    let width = target.width, height = target.height
    precondition(source.width == width && source.height == height && width == 192 && height == 192)

    func gradient(_ frame: RGBFrame) -> [Double] {
        var gray = [Double](repeating: 0, count: width * height)
        for index in 0 ..< gray.count {
            let pixel = index * 4
            gray[index] = 0.2126 * Double(frame.rgba[pixel])
                + 0.7152 * Double(frame.rgba[pixel + 1])
                + 0.0722 * Double(frame.rgba[pixel + 2])
        }
        var result = gray
        for y in 1 ..< height - 1 {
            for x in 1 ..< width - 1 {
                let index = y * width + x
                result[index] = hypot(gray[index + 1] - gray[index - 1],
                                      gray[index + width] - gray[index - width])
            }
        }
        return result
    }

    let a = gradient(target), b = gradient(source)
    var centerX = width / 2, centerY = height / 2
    let radius = 20, limit = 28
    // Choose texture using the Sony tile alone, before looking at the RAW.
    // The fixed five-by-five offsets keep spatial coverage predictable while
    // avoiding an arbitrary flat center in an otherwise informative tile.
    var strongest = 0.0
    for oy in [-36, -18, 0, 18, 36] {
        for ox in [-36, -18, 0, 18, 36] {
            let cx = width / 2 + ox, cy = height / 2 + oy
            var sum = 0.0, squares = 0.0, samples = 0.0
            for y in Swift.stride(from: -radius, through: radius, by: 2) {
                for x in Swift.stride(from: -radius, through: radius, by: 2) {
                    let value = a[(cy + y) * width + cx + x]
                    sum += value
                    squares += value * value
                    samples += 1
                }
            }
            let variance = (squares - sum * sum / samples) / samples
            if variance > strongest {
                strongest = variance
                centerX = cx
                centerY = cy
            }
        }
    }
    guard strongest > 0.000015 else { return .flat }
    func correlation(_ dx: Int, _ dy: Int, stride step: Int) -> Double {
        var sumA = 0.0, sumB = 0.0, sumAA = 0.0, sumBB = 0.0, sumAB = 0.0
        var samples = 0
        for y in Swift.stride(from: -radius, through: radius, by: step) {
            for x in Swift.stride(from: -radius, through: radius, by: step) {
                let lhs = a[(centerY + y) * width + centerX + x]
                let rhs = b[(centerY + y + dy) * width + centerX + x + dx]
                sumA += lhs
                sumB += rhs
                sumAA += lhs * lhs
                sumBB += rhs * rhs
                sumAB += lhs * rhs
                samples += 1
            }
        }
        let n = Double(samples)
        let varianceA = sumAA - sumA * sumA / n
        let varianceB = sumBB - sumB * sumB / n
        guard varianceA > n * 0.000015, varianceB > n * 0.000015 else { return -.infinity }
        return (sumAB - sumA * sumB / n) / sqrt(varianceA * varianceB)
    }
    var best = (dx: 0, dy: 0, value: -Double.infinity)
    for dy in -limit ... limit {
        for dx in -limit ... limit {
            let value = correlation(dx, dy, stride: 2)
            if value > best.value {
                best = (dx, dy, value)
            }
        }
    }
    guard best.value.isFinite else { return .flat }
    var fine = (dx: best.dx, dy: best.dy, value: -Double.infinity)
    var alternatives = [(Int, Int, Double)]()
    for dy in max(-limit, best.dy - 2) ... min(limit, best.dy + 2) {
        for dx in max(-limit, best.dx - 2) ... min(limit, best.dx + 2) {
            let value = correlation(dx, dy, stride: 1)
            alternatives.append((dx, dy, value))
            if value > fine.value {
                fine = (dx, dy, value)
            }
        }
    }
    guard fine.value >= 0.65 else { return .ambiguous }
    guard abs(fine.dx) < limit, abs(fine.dy) < limit else { return .searchBoundary }
    let rival = alternatives.filter {
        abs($0.0 - fine.dx) > 1 || abs($0.1 - fine.dy) > 1
    }.map(\.2).max() ?? -.infinity
    guard fine.value - rival >= 0.02 else { return .ambiguous }
    func subpixel(_ before: Double, _ center: Double, _ after: Double) -> Double? {
        let curvature = before - 2 * center + after
        guard before.isFinite, after.isFinite, curvature < -0.0001 else { return nil }
        return max(-1, min(1, 0.5 * (before - after) / curvature))
    }
    guard let finerX = subpixel(correlation(fine.dx - 1, fine.dy, stride: 1), fine.value,
                                correlation(fine.dx + 1, fine.dy, stride: 1)),
        let finerY = subpixel(correlation(fine.dx, fine.dy - 1, stride: 1), fine.value,
                              correlation(fine.dx, fine.dy + 1, stride: 1))
    else { return .ambiguous }
    return .reliable(dx: Double(fine.dx) + finerX,
                     dy: Double(fine.dy) + finerY, correlation: fine.value,
                     anchorX: centerX - width / 2, anchorY: centerY - height / 2)
}

func nativeGeometryScore(source: CIImage, target: CIImage,
                         render: (CIImage) throws -> RGBFrame) throws -> NativeGeometryScore
{
    let width = Int(target.extent.width), height = Int(target.extent.height)
    guard source.extent.size == target.extent.size, width >= 1000, height >= 1000 else {
        throw HarnessError.incompatibleDimensions
    }
    let fractionsX = [0.04, 0.27, 0.5, 0.73, 0.96]
    let fractionsY = [0.06, 0.5, 0.94]
    let tileSize = 192
    var matches = [NativeGeometryPoint]()
    var flat = 0, ambiguous = 0, boundary = 0
    for fy in fractionsY {
        for fx in fractionsX {
            let x = max(tileSize / 2, min(width - tileSize / 2,
                                          Int((Double(width) * fx).rounded())))
            let y = max(tileSize / 2, min(height - tileSize / 2,
                                          Int((Double(height) * fy).rounded())))
            let crop = CGRect(x: x - tileSize / 2, y: y - tileSize / 2,
                              width: tileSize, height: tileSize)
            let sourcePixels = try render(source.cropped(to: crop))
            let targetPixels = try render(target.cropped(to: crop))
            switch matchNativeTile(sourcePixels, targetPixels) {
            case let .reliable(dx, dy, correlation, anchorX, anchorY):
                matches.append(NativeGeometryPoint(x: Double(x + anchorX) / Double(width),
                                                   y: Double(y + anchorY) / Double(height),
                                                   dx: dx, dy: dy,
                                                   correlation: correlation))
            case .flat: flat += 1
            case .ambiguous: ambiguous += 1
            case .searchBoundary: boundary += 1
            }
        }
    }
    let attempted = fractionsX.count * fractionsY.count
    guard !matches.isEmpty else {
        return NativeGeometryScore(attempted: attempted, reliable: 0,
                                   sufficientCoverage: false,
                                   medianResidualPixels: nil, p95ResidualPixels: nil,
                                   edgeP95ResidualPixels: nil, medianCorrelation: nil,
                                   rejectedFlat: flat, rejectedAmbiguous: ambiguous,
                                   rejectedSearchBoundary: boundary, points: [])
    }
    func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
    func p95(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
    }
    let translationX = median(matches.map(\.dx))
    let translationY = median(matches.map(\.dy))
    func residual(_ match: NativeGeometryPoint) -> Double {
        hypot(match.dx - translationX, match.dy - translationY)
    }
    let enough = matches.count >= 8
    let edge = matches.filter { $0.x < 0.1 || $0.x > 0.9 || $0.y < 0.1 || $0.y > 0.9 }
    return NativeGeometryScore(attempted: attempted, reliable: matches.count,
                               sufficientCoverage: enough,
                               medianResidualPixels: enough ? median(matches.map(residual)) : nil,
                               p95ResidualPixels: enough ? p95(matches.map(residual)) : nil,
                               edgeP95ResidualPixels: edge.count >= 6 ? p95(edge.map(residual)) : nil,
                               medianCorrelation: median(matches.map(\.correlation)),
                               rejectedFlat: flat, rejectedAmbiguous: ambiguous,
                               rejectedSearchBoundary: boundary, points: matches)
}

func nativeGeometrySelfTest() throws {
    let size = 192
    var seed: UInt32 = 0x6F74_6F73
    var target = [Float](repeating: 0, count: size * size * 4)
    for index in 0 ..< size * size {
        seed = 1_664_525 &* seed &+ 1_013_904_223
        let value = Float(seed & 0xFFFF) / 65535
        for channel in 0 ..< 3 {
            target[index * 4 + channel] = value
        }
        target[index * 4 + 3] = 1
    }
    var shifted = target
    for y in 0 ..< size {
        for x in 0 ..< size {
            let from = (min(size - 1, max(0, y + 2)) * size
                + min(size - 1, max(0, x - 3))) * 4
            let to = (y * size + x) * 4
            for channel in 0 ..< 4 {
                shifted[to + channel] = target[from + channel]
            }
        }
    }
    let targetFrame = RGBFrame(width: size, height: size, rgba: target)
    let sourceFrame = RGBFrame(width: size, height: size, rgba: shifted)
    guard case let .reliable(dx, dy, score, _, _) = matchNativeTile(sourceFrame, targetFrame),
          abs(dx - 3) < 0.1, abs(dy + 2) < 0.1, score > 0.99
    else { throw HarnessError.malformedReferenceData }
    let flat = RGBFrame(width: size, height: size,
                        rgba: Array(repeating: [Float(0.5), 0.5, 0.5, 1],
                                    count: size * size).flatMap(\.self))
    guard case .flat = matchNativeTile(flat, flat) else {
        throw HarnessError.malformedReferenceData
    }
}
