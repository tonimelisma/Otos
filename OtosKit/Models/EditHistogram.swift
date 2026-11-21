import CoreGraphics
import Foundation

/// The edit panel's histogram (DES-100): how the photo the loupe shows spreads over the
/// tonal range, per channel, as Lightroom's Edit panel opens with. Each channel has
/// `binCount` bins from black to white, scaled so the fullest bin of any channel is 1.
nonisolated struct EditHistogram: Equatable, Sendable {
    static let binCount = 64
    /// The long edge the image is reduced to before counting: enough pixels for a stable
    /// shape, few enough to count in about a millisecond.
    static let sampleLongEdge = 256

    let red: [Double]
    let green: [Double]
    let blue: [Double]
    /// Share of pixels with a channel at 0 or 255: clipped shadows and highlights.
    let clippedShadows: Double
    let clippedHighlights: Double

    /// `counting(_:)` off the caller's actor.
    @concurrent
    static func count(_ image: CGImage) async -> EditHistogram? {
        counting(image)
    }

    /// Counts `image`, reduced to `sampleLongEdge`, in sRGB. Synchronous and pure.
    static func counting(_ image: CGImage) -> EditHistogram? {
        let scale = min(1, Double(sampleLongEdge) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var counts = [[Int]](repeating: [Int](repeating: 0, count: binCount), count: 3)
        var shadows = 0
        var highlights = 0
        for index in 0 ..< width * height {
            let base = index * 4
            var dark = false
            var bright = false
            for channel in 0 ..< 3 {
                let value = Int(pixels[base + channel])
                counts[channel][value * binCount / 256] += 1
                dark = dark || value == 0
                bright = bright || value == 255
            }
            shadows += dark ? 1 : 0
            highlights += bright ? 1 : 0
        }
        let fullest = Double(max(1, counts.flatMap(\.self).max() ?? 1))
        let total = Double(width * height)
        return EditHistogram(
            red: counts[0].map { Double($0) / fullest },
            green: counts[1].map { Double($0) / fullest },
            blue: counts[2].map { Double($0) / fullest },
            clippedShadows: Double(shadows) / total,
            clippedHighlights: Double(highlights) / total
        )
    }

    /// What VoiceOver reads for the histogram: where the tones sit, and any clipping.
    var accessibilityDescription: String {
        let luminance = zip(zip(red, green), blue).map { ($0.0 + $0.1 + $1) / 3 }
        let total = max(luminance.reduce(0, +), .leastNonzeroMagnitude)
        let third = luminance.count / 3
        func share(_ range: Range<Int>) -> Int {
            Int((luminance[range].reduce(0, +) / total * 100).rounded())
        }
        var parts = [
            "shadows \(share(0 ..< third)) percent",
            "midtones \(share(third ..< 2 * third)) percent",
            "highlights \(share(2 * third ..< luminance.count)) percent",
        ]
        if clippedShadows >= 0.005 {
            parts.append("\(Int((clippedShadows * 100).rounded())) percent clipped black")
        }
        if clippedHighlights >= 0.005 {
            parts.append("\(Int((clippedHighlights * 100).rounded())) percent clipped white")
        }
        return parts.joined(separator: ", ")
    }
}
