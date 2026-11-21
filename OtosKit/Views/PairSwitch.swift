import SwiftUI

/// The `JPG`/`RAW` switch (ADR 0052, DES-117): which file of a RAW+JPEG pair the loupe
/// and the edit panel show and edit. One view for both surfaces, calling one intent
/// (`CatalogWindowViewModel.showPairMember`). The processed file comes first, as it is the
/// pair's default; each segment is named by its file's own type (`JPG`, `HEIC`, `RAW`).
struct PairSwitch: View {
    let pair: PhotoStack
    let shown: MediaAssetID
    let onSelect: (MediaAssetID) -> Void

    private var members: [MediaAssetID] {
        pair.members.filter { !pair.isRaw($0) } + pair.members.filter(pair.isRaw)
    }

    var body: some View {
        Picker("Shown File", selection: Binding(get: { shown }, set: onSelect)) {
            ForEach(members, id: \.self) { member in
                Text(pair.label(of: member))
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
