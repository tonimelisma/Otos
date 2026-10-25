import SwiftUI

/// The trailing edit panel (ADR 0036, `docs/design/edit-panel.md`). Passive: it renders
/// the draft recipe and the open photo's facts it is given, and reports each control's
/// movement and drag state to the view model, which owns saving, rendering and undo.
///
/// The controls stay in place and disabled while there is no single photo to edit or it
/// is still being opened (DES-053); their tooltip says which (DES-038).
struct EditPanelView: View {
    let photoName: String?
    let facts: EditPhotoFacts?
    let recipe: EditRecipe
    let isPickingNeutral: Bool
    let canPickNeutral: Bool
    let setValue: @MainActor (Double, EditControl) -> Void
    let setDragging: @MainActor (Bool, EditControl) -> Void
    let resetSection: @MainActor (EditSection) -> Void
    let toggleNeutralPicker: @MainActor () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(photoName ?? "No Selection")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                ForEach(EditSection.allCases) { section in
                    sectionView(section)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Why the controls are disabled, or nil when they act.
    private var unavailableHelp: String? {
        if photoName == nil {
            return "Select one photo to edit"
        }
        return facts == nil ? "Preparing to edit" : nil
    }

    private func sectionView(_ section: EditSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(section.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Reset") { resetSection(section) }
                    .controlSize(.small)
                    .disabled(unavailableHelp != nil || section.isNeutral(in: recipe))
                    .help(unavailableHelp ?? section.resetActionName)
            }
            if section == .color {
                whiteBalancePicker
            }
            ForEach(section.controls) { control in
                EditSliderRow(
                    title: control.title,
                    formattedValue: facts.map { control.formatted(recipe, facts: $0) } ?? "",
                    value: control.sliderValue(in: recipe, facts: facts ?? .still),
                    range: control.sliderRange(facts ?? .still),
                    setValue: { setValue($0, control) },
                    setDragging: { setDragging($0, control) }
                )
                .disabled(unavailableHelp != nil)
                .help(unavailableHelp ?? "")
            }
        }
    }

    /// Lightroom's white balance selector: armed, the next click on the loupe image makes
    /// that point neutral. The filled glyph, not color alone, shows it armed (DES-029).
    private var whiteBalancePicker: some View {
        HStack {
            Text("White Balance")
            Spacer()
            Button(action: toggleNeutralPicker) {
                Image(systemName: isPickingNeutral ? "eyedropper.full" : "eyedropper")
            }
            .controlSize(.small)
            .disabled(unavailableHelp != nil || !(canPickNeutral || isPickingNeutral))
            .help(pickerHelp)
            .accessibilityLabel("Pick a Neutral Point")
            .accessibilityValue(isPickingNeutral ? "on" : "off")
        }
        .font(.body)
    }

    private var pickerHelp: String {
        if let unavailableHelp {
            return unavailableHelp
        }
        if isPickingNeutral {
            return "Click a neutral point in the photo; Escape cancels"
        }
        return canPickNeutral
            ? "Pick a neutral point in the photo"
            : "Open the photo in the loupe to pick a neutral point"
    }
}

/// One control: its name and value on a line, the slider under them — the label-left,
/// value-right relationship of DES-017 with the slider at full panel width.
private struct EditSliderRow: View {
    let title: String
    let formattedValue: String
    let value: Double
    let range: ClosedRange<Double>
    let setValue: @MainActor (Double) -> Void
    let setDragging: @MainActor (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(formattedValue)
                    .monospacedDigit()
            }
            .font(.body)
            .accessibilityHidden(true)
            Slider(
                value: Binding(get: { value }, set: { setValue($0) }),
                in: range,
                label: { Text(title) },
                onEditingChanged: { setDragging($0) }
            )
            .labelsHidden()
            .accessibilityValue(formattedValue)
        }
    }
}
