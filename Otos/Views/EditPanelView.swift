import SwiftUI

/// The trailing edit panel (ADR 0036, `docs/design/edit-panel.md`). Passive: it renders
/// the draft recipe it is given and reports each control's movement and drag state to the
/// view model, which owns saving, rendering and undo.
///
/// The controls stay in place and disabled when there is no single photo to edit
/// (DES-053); their tooltip says why (DES-038).
struct EditPanelView: View {
    let photoName: String?
    let recipe: EditRecipe
    let setValue: (Double, LightControl) -> Void
    let setDragging: (Bool, LightControl) -> Void
    let resetLight: () -> Void

    private static let unavailableHelp = "Select one photo to edit"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(photoName ?? "No Selection")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                section
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isEnabled: Bool {
        photoName != nil
    }

    private var section: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Light")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Reset", action: resetLight)
                    .controlSize(.small)
                    .disabled(!isEnabled || recipe.isNeutral)
                    .help(isEnabled ? "Reset Light" : Self.unavailableHelp)
            }
            ForEach(LightControl.allCases) { control in
                EditSliderRow(
                    control: control,
                    value: control.value(in: recipe),
                    setValue: { setValue($0, control) },
                    setDragging: { setDragging($0, control) }
                )
                .disabled(!isEnabled)
                .help(isEnabled ? "" : Self.unavailableHelp)
            }
        }
    }
}

/// One control: its name and value on a line, the slider under them — the label-left,
/// value-right relationship of DES-017 with the slider at full panel width.
private struct EditSliderRow: View {
    let control: LightControl
    let value: Double
    let setValue: @MainActor (Double) -> Void
    let setDragging: @MainActor (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(control.title)
                Spacer()
                Text(control.formatted(value))
                    .monospacedDigit()
            }
            .font(.body)
            .accessibilityHidden(true)
            Slider(
                value: Binding(get: { value }, set: { setValue($0) }),
                in: control.range,
                onEditingChanged: setDragging
            ) {
                Text(control.title)
            }
            .labelsHidden()
            .accessibilityValue(control.formatted(value))
        }
    }
}
