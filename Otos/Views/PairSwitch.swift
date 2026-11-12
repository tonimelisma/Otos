import SwiftUI

/// The `JPEG | RAW` switch (ADR 0052, DES-117): which file of a RAW+JPEG pair the loupe
/// and the edit panel show and edit. One view for both surfaces, calling one intent
/// (`CatalogWindowViewModel.showPairMember`). The processed file comes first, as it is the
/// pair's default; each segment is named by its file's own type (`JPG`, `HEIC`, `RAW`).
struct PairSwitch: View {
    let pair: PhotoStack
    let shown: MediaAssetID
    let onSelect: (MediaAssetID) -> Void

    private var members: [MediaAssetID] {
        pair.members.sorted { left, right in
            let leftIsRaw = pair.memberLabels[left] == "RAW"
            let rightIsRaw = pair.memberLabels[right] == "RAW"
            return !leftIsRaw && rightIsRaw
        }
    }

    var body: some View {
        Picker("Shown File", selection: Binding(get: { shown }, set: onSelect)) {
            ForEach(members, id: \.self) { member in
                Text(pair.memberLabels[member] ?? member.relativePath.fileExtension.uppercased())
                    .tag(member)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Choose which file of this RAW+JPEG pair is shown and edited")
        .accessibilityLabel("Shown file")
    }
}
