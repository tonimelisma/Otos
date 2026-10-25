import SwiftUI

/// The trailing edit panel (ADR 0036, `docs/design/edit-panel.md`). Passive: it renders
/// the draft recipe and the open photo's facts it is given, and reports each control's
/// movement and drag state to the view model, which owns saving, rendering and undo.
///
/// The controls stay in place and disabled while there is no single photo to edit or it
/// is still being opened (DES-053); their tooltip says which (DES-038).
///
/// Each section folds under its heading's disclosure triangle (`hig-validation.md` F-16).
/// Which sections are folded is the person's own arrangement of the panel, kept across
/// launches in `@AppStorage`; the crop tool's section is shown while the tool is on.
struct EditPanelView: View {
    let photoName: String?
    let facts: EditPhotoFacts?
    let recipe: EditRecipe
    let isPickingNeutral: Bool
    let canPickNeutral: Bool
    let crop: EditPanelCropState
    let setValue: @MainActor (Double, EditControl) -> Void
    let setDragging: @MainActor (Bool, EditControl) -> Void
    let resetSection: @MainActor (EditSection) -> Void
    let toggleNeutralPicker: @MainActor () -> Void
    let cropActions: EditPanelCropActions
    /// A value field gained or lost the keyboard.
    let setEntering: @MainActor (Bool) -> Void

    /// Section IDs the person folded, comma-separated.
    @AppStorage("editPanel.foldedSections") private var foldedSections = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    private func isOpen(_ section: EditSection) -> Bool {
        (section == .crop && crop.isCropping) || !foldedSections.split(separator: ",").contains(Substring(section.id))
    }

    private func toggleFold(_ section: EditSection) {
        var folded = Set(foldedSections.split(separator: ",").map(String.init))
        if folded.contains(section.id) {
            folded.remove(section.id)
        } else {
            folded.insert(section.id)
        }
        // DES-070 for content appearing; DES-075 under Reduce Motion. The content fades
        // in place either way, so nothing translates.
        withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.25)) {
            foldedSections = folded.sorted().joined(separator: ",")
        }
    }

    private func sectionView(_ section: EditSection) -> some View {
        let open = isOpen(section)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                // A disclosure triangle: pointing in from the leading edge while folded,
                // down while open (Disclosure controls).
                Button {
                    toggleFold(section)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .foregroundStyle(.secondary)
                        Text(section.title)
                            .font(.headline)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(section == .crop && crop.isCropping)
                .accessibilityLabel(section.title)
                .accessibilityValue(open ? "expanded" : "collapsed")
                .accessibilityAddTraits(.isHeader)
                .help(open ? "Hide \(section.title)" : "Show \(section.title)")
                Spacer()
                Button("Reset") { resetSection(section) }
                    .controlSize(.small)
                    .disabled(unavailableHelp != nil || section.isNeutral(in: recipe))
                    .help(unavailableHelp ?? section.resetActionName)
            }
            if open {
                sectionControls(section)
                    .transition(.opacity)
            }
        }
    }

    private func sectionControls(_ section: EditSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if section == .crop {
                cropTool
                aspectRow
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
                    setDragging: { setDragging($0, control) },
                    setEntering: setEntering,
                    enter: { text in
                        guard let facts, let position = control.position(fromEntered: text, facts: facts) else {
                            return false
                        }
                        setValue(position, control)
                        return true
                    }
                )
                .disabled(unavailableHelp != nil)
                .help(unavailableHelp ?? "")
            }
            if section == .crop {
                orientationButtons
            }
        }
    }

    /// The crop tool's switch: Done while it is on, which Return answers.
    private var cropTool: some View {
        Button {
            cropActions.toggleTool()
        } label: {
            Label(crop.isCropping ? "Done" : "Crop", systemImage: "crop")
        }
        .controlSize(.small)
        .keyboardShortcut(crop.isCropping ? .defaultAction : nil)
        .disabled(unavailableHelp != nil || !(crop.canCrop || crop.isCropping))
        .help(cropToolHelp)
    }

    /// The aspect choice, introduced by its label so its options read without opening it
    /// (Pop-up buttons; `hig-validation.md` F-14), and Rotate Aspect.
    private var aspectRow: some View {
        HStack(spacing: 8) {
            Text("Aspect")
                .font(.body)
            Spacer()
            Picker("Aspect", selection: Binding(get: { crop.aspect }, set: { cropActions.setAspect($0) })) {
                ForEach(CropAspect.allCases) { aspect in
                    Text(aspect.title).tag(aspect)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .disabled(!crop.isCropping)
            .help(crop.isCropping ? "Aspect" : "Start cropping to choose an aspect")
            Button {
                cropActions.rotateAspect()
            } label: {
                Image(systemName: crop.isLandscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate")
            }
            .controlSize(.small)
            .disabled(!crop.isCropping || crop.aspect == .free)
            .help("Rotate Aspect")
            .accessibilityLabel("Rotate Aspect")
        }
    }

    private var cropToolHelp: String {
        if let unavailableHelp {
            return unavailableHelp
        }
        if crop.isCropping {
            return "Finish cropping"
        }
        return crop.canCrop ? "Crop the photo" : "Open the photo in the loupe to crop it"
    }

    /// Quarter turns and flips, as icons in Lightroom's order.
    private var orientationButtons: some View {
        HStack(spacing: 8) {
            orientationButton("Rotate Left", systemImage: "rotate.left") { cropActions.turn(false) }
            orientationButton("Rotate Right", systemImage: "rotate.right") { cropActions.turn(true) }
            Spacer()
            orientationButton(
                "Flip Horizontal",
                systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right"
            ) { cropActions.flip(true) }
            orientationButton(
                "Flip Vertical",
                systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down"
            ) { cropActions.flip(false) }
        }
    }

    private func orientationButton(
        _ title: String,
        systemImage: String,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .controlSize(.small)
        .disabled(unavailableHelp != nil)
        .help(unavailableHelp ?? title)
        .accessibilityLabel(title)
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
///
/// The value is a field (`hig-validation.md` F-15): it reads like the value, and clicking
/// or tabbing into it lets the exact number be typed. Return or leaving the field enters it
/// through `enter`, which saves it as one step; text that is not a number is put back,
/// and Escape puts back the shown value.
private struct EditSliderRow: View {
    let title: String
    let formattedValue: String
    let value: Double
    let range: ClosedRange<Double>
    let setValue: @MainActor (Double) -> Void
    let setDragging: @MainActor (Bool) -> Void
    let setEntering: @MainActor (Bool) -> Void
    /// Enters typed text; false when it is not a value.
    let enter: @MainActor (String) -> Bool

    @State private var entry = ""
    @FocusState private var isEntering: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .accessibilityHidden(true)
                Spacer()
                // Shows the value whenever it is not being typed, so it is never stale.
                TextField(title, text: Binding(get: { isEntering ? entry : formattedValue }, set: { entry = $0 }))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 72)
                    .focused($isEntering)
                    .onSubmit {
                        commitEntry()
                        isEntering = false
                    }
                    .onExitCommand {
                        entry = formattedValue
                        isEntering = false
                    }
                    .onChange(of: isEntering) { _, entering in
                        setEntering(entering)
                        if entering {
                            entry = formattedValue
                        } else {
                            commitEntry()
                        }
                    }
                    .accessibilityLabel("\(title) value")
            }
            .font(.body)
            Slider(
                value: Binding(get: { value }, set: { setValue($0) }),
                in: range,
                label: { Text(title) },
                onEditingChanged: { setDragging($0) }
            )
            .labelsHidden()
            // A value, not a selection: the accent stays for what is selected or acted on
            // (DES-024), and a fill from the left edge would read as an amount on a slider
            // whose neutral point is its middle.
            .tint(Color.secondary)
            .accessibilityValue(formattedValue)
        }
    }

    private func commitEntry() {
        guard entry != formattedValue else { return }
        if !enter(entry) {
            entry = formattedValue
        }
    }
}

/// The crop tool's state as the panel shows it.
struct EditPanelCropState {
    let isCropping: Bool
    let canCrop: Bool
    let aspect: CropAspect
    let isLandscape: Bool
}

/// The crop tool's intents, as the panel calls them.
struct EditPanelCropActions {
    let toggleTool: @MainActor () -> Void
    let setAspect: @MainActor (CropAspect) -> Void
    let rotateAspect: @MainActor () -> Void
    /// Clockwise when true.
    let turn: @MainActor (Bool) -> Void
    /// Horizontally when true.
    let flip: @MainActor (Bool) -> Void
}
