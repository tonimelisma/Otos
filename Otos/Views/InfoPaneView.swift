import MapKit
import SwiftUI

/// The inspector's Info pane (APP-041, DES-088): read-only facts about the current target,
/// laid out as the Edit pane is (DES-092) so the column reads the same in both panes — the
/// file name, a quiet line saying when it was taken, then folding sections under a hairline,
/// each a heading of its symbol and title over rows indented beneath it.
///
/// Passive: it renders the `PhotoInfo` it is given. Its rows keep their place for every item
/// of a kind (DES-053); with no single item they read `—`. Which sections are folded is the
/// person's, remembered across launches like the Edit pane's.
struct InfoPaneView: View {
    let info: PhotoInfo?

    /// Section IDs the person folded, comma-separated.
    @AppStorage("infoPane.foldedSections") private var foldedSections = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: PhotoInfo {
        info ?? .none(itemCount: 0)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(shown.title)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityAddTraits(.isHeader)
                    Text(shown.captured)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Captured \(shown.captured)")
                }
                ForEach(shown.sections) { section in
                    // The Edit pane's hairline above each section (DES-092).
                    Divider()
                    sectionView(section)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func isOpen(_ section: PhotoInfo.SectionID) -> Bool {
        !foldedSections.split(separator: ",").contains(Substring(section.rawValue))
    }

    private func toggleFold(_ section: PhotoInfo.SectionID) {
        var folded = Set(foldedSections.split(separator: ",").map(String.init))
        if folded.contains(section.rawValue) {
            folded.remove(section.rawValue)
        } else {
            folded.insert(section.rawValue)
        }
        // DES-070 for content appearing; DES-075 under Reduce Motion. The content fades in
        // place either way, so nothing translates.
        withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.25)) {
            foldedSections = folded.sorted().joined(separator: ",")
        }
    }

    private func sectionView(_ section: PhotoInfo.Section) -> some View {
        let open = isOpen(section.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                toggleFold(section.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: EditPanelView.disclosureWidth)
                    Image(systemName: section.id.symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(section.id.title)
                        .font(.title3)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(section.id.title)
            .accessibilityValue(open ? "expanded" : "collapsed")
            .accessibilityAddTraits(.isHeader)
            .help(open ? "Hide \(section.id.title)" : "Show \(section.id.title)")
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    if section.id == .location, let coordinate = shown.coordinate {
                        map(coordinate)
                    }
                    rows(section.rows)
                }
                // Indented under the heading, as the Edit pane's controls are, so the
                // headings form one edge the eye runs down.
                .padding(.leading, EditPanelView.contentIndent)
                .transition(.opacity)
            }
        }
    }

    /// Label and value, the label secondary (DES-088). Labels share one leading edge, the
    /// edge the Edit pane's control names use, and a long value wraps beside its label.
    private func rows(_ rows: [PhotoInfo.Row]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                    Text(row.value)
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Where it was taken: a still map with one pin, read-only like the rest of the pane.
    private func map(_ coordinate: PlaceCoordinate) -> some View {
        let center = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return Map(
            initialPosition: .camera(MapCamera(centerCoordinate: center, distance: 4000)),
            interactionModes: []
        ) {
            Marker("", coordinate: center)
        }
        // A new item recenters the map rather than keeping the last one's camera.
        .id(coordinate)
        .frame(height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Map of \(shown.placeName ?? "where it was taken")")
    }
}
