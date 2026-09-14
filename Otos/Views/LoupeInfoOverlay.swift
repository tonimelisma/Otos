import SwiftUI

/// Read-only facts for the loupe's focused asset (APP-041, DES-088). Bottom-leading on
/// a material so the curation group keeps the top-left of the picture (DES-066). The
/// file name is an L2 label; each fact is L3. Nothing here is interactive.
struct LoupeInfoOverlay: View {
    let model: LoupeInfoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.fileName)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            fact(model.captureDate)
            fact(model.dimensions)
            fact(model.kind)
            fact(model.fileSize)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: 320, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Info")
        .allowsHitTesting(false)
    }

    private func fact(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}
