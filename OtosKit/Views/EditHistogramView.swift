import SwiftUI

/// The edit panel's histogram (DES-100): the red, green and blue channels of the photo as
/// last rendered, drawn over one another in the system's channel colors, so where they
/// overlap the mix reads as the neutral tones it is. It keeps one height in every state
/// (DES-053): with nothing counted yet it is the empty well, and when the photo's original
/// can't be read the well says so where the picture would be.
struct EditHistogramView: View {
    static let height: CGFloat = 64
    /// What the well, and the panel's disabled controls, say while the original can't be read.
    static let unreadableTitle = "Can’t read the original right now"

    let histogram: EditHistogram?
    let isOriginalUnreadable: Bool

    var body: some View {
        Canvas { context, size in
            guard let histogram else { return }
            for (bins, color) in [(histogram.red, Color.red), (histogram.green, .green), (histogram.blue, .blue)] {
                context.fill(Self.area(bins, in: size), with: .color(color.opacity(0.5)))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
        .overlay {
            if isOriginalUnreadable {
                Text(Self.unreadableTitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement()
        .accessibilityLabel("Histogram")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        if isOriginalUnreadable {
            return Self.unreadableTitle
        }
        return histogram?.accessibilityDescription ?? "Not available"
    }

    /// One channel as the area under its bins, black at the leading edge.
    private static func area(_ bins: [Double], in size: CGSize) -> Path {
        Path { path in
            guard bins.count > 1 else { return }
            let step = size.width / CGFloat(bins.count - 1)
            path.move(to: CGPoint(x: 0, y: size.height))
            for (index, value) in bins.enumerated() {
                path.addLine(to: CGPoint(x: CGFloat(index) * step, y: size.height * (1 - CGFloat(value))))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
        }
    }
}
