import SwiftUI

/// Bottom status surface for a job that runs over several photos with progress and Cancel:
/// a hand-off being prepared (ADR 0037) or an export (ADR 0038). DES-040's pattern, the
/// same layout as the trash bar (DES-089), DES-094. Two zones at one fixed height: *what*
/// (L1, `title`, e.g. "Preparing 3 photos to copy" or "Exporting 3 photos") and
/// *progress* (M of N, determinate, DES-031), then *the act*, Cancel (DES-032). Passive:
/// it renders the counts it is given and calls `cancel`.
struct ProgressStatusBar: View {
    let title: String
    let completed: Int
    let total: Int
    let cancel: @MainActor () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let contentHeight: CGFloat = 40

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(DesignPalette.label(for: colorScheme))
                .monospacedDigit()
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                ProgressView(value: Double(completed), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(width: 160)
                    .animation(
                        reduceMotion ? .linear(duration: 0.1) : .linear(duration: 0.2),
                        value: completed
                    )
                Text("\(completed) of \(total)")
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
