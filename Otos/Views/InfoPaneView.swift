import SwiftUI

/// The inspector's Info pane (APP-041, DES-088): read-only facts about the current target.
/// Passive: it renders the `PhotoInfo` it is given. Its rows keep their place in every
/// state (DES-053); with no single item to describe they read `—`.
struct InfoPaneView: View {
    let info: PhotoInfo?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(info?.fileName ?? "No Selection")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                    row("Captured", info?.captureDate)
                    row("Dimensions", info?.dimensions)
                    row("Kind", info?.kind)
                    row("File Size", info?.fileSize)
                }
                .font(.body)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value ?? "—")
                .foregroundStyle(.primary)
                .monospacedDigit()
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}
