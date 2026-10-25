import SwiftUI

/// Bottom status surface for a hand-off being prepared (plan 0108 increment 13; DES-040's
/// pattern, the same layout as the trash bar, DES-089). Shown only while an edited photo
/// or a RAW is being made into a full-size file for Copy, Share or Open. Two zones at one
/// fixed height: *what* (L1, DES-030's Preparing) and *progress* (M of N, determinate,
/// DES-031), then *the act*, Cancel (DES-032). Passive: it renders `HandOffProgress` and
/// calls `cancel`.
struct HandOffStatusBar: View {
    let progress: HandOffProgress
    let cancel: @MainActor () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let contentHeight: CGFloat = 40

    private var primaryLine: String {
        let photos = progress.total == 1 ? "1 photo" : "\(progress.total) photos"
        return "Preparing \(photos) to \(progress.verb)"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            Text(primaryLine)
                .font(.title3.weight(.semibold))
                .foregroundStyle(DesignPalette.label(for: colorScheme))
                .monospacedDigit()
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(width: 160)
                    .animation(
                        reduceMotion ? .linear(duration: 0.1) : .linear(duration: 0.2),
                        value: progress.completed
                    )
                Text("\(progress.completed) of \(progress.total)")
                    .font(.subheadline)
                    .foregroundStyle(DesignPalette.l3(for: colorScheme))
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            Button("Cancel", action: cancel)
        }
        .frame(minHeight: Self.contentHeight, maxHeight: Self.contentHeight)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(DesignPalette.bar(for: colorScheme))
        .accessibilityElement(children: .contain)
    }
}
