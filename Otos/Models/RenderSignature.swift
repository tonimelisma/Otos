import CoreGraphics
import Foundation

/// A still's render signature (ADR 0042): what "these two thumbnails show the same pixels"
/// is measured with. A 64-bit difference hash proposes candidates; the mean absolute
/// difference of two 32 × 32 grayscale renders confirms them. Both are deterministic and
/// read only the stored thumbnail — never the original — and the thresholds are the ones
/// calibrated on the owner's library (`docs/research/2026-10-31-duplicate-calibration.md`).
nonisolated struct RenderSignature: Equatable, Sendable {
    /// 9 × 8 grayscale, one bit per horizontal step: brighter to the right.
    let differenceHash: UInt64
    /// 32 × 32 grayscale, row-major.
    let gray: [UInt8]

    static let grayEdge = 32
    /// Candidates differ in at most this many hash bits.
    static let candidateHammingDistance = 10
    /// Confirmed copies differ by less than this mean, on 0–255.
    static let confirmedMeanDifference = 4.0

    init?(differenceHash: UInt64, gray: [UInt8]) {
        guard gray.count == Self.grayEdge * Self.grayEdge else {
            return nil
        }
        self.differenceHash = differenceHash
        self.gray = gray
    }

    /// The signature of a decoded thumbnail, drawn at fixed sizes so two renders of one
    /// picture align whatever their stored dimensions.
    init?(image: CGImage) {
        guard let small = Self.grayPixels(image, width: 9, height: 8),
              let gray = Self.grayPixels(image, width: Self.grayEdge, height: Self.grayEdge)
        else {
            return nil
        }
        var hash: UInt64 = 0
        for row in 0 ..< 8 {
            for column in 0 ..< 8 {
                hash = (hash << 1) | (small[row * 9 + column] < small[row * 9 + column + 1] ? 1 : 0)
            }
        }
        self.init(differenceHash: hash, gray: gray)
    }

    func hammingDistance(to other: RenderSignature) -> Int {
        (differenceHash ^ other.differenceHash).nonzeroBitCount
    }

    func meanDifference(to other: RenderSignature) -> Double {
        var total = 0
        for index in gray.indices {
            total += abs(Int(gray[index]) - Int(other.gray[index]))
        }
        return Double(total) / Double(gray.count)
    }

    private static func grayPixels(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
