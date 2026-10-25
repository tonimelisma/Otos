import SwiftUI
import UniformTypeIdentifiers

/// File ▸ Export…'s sheet (ADR 0038). The L1 fact is its title, what it exports ("Export 3
/// Photos"); the rows are L2 controls, the footnote L3. Every row is always shown, and
/// the rows an Original does not use are disabled rather than removed, so the sheet keeps
/// one height whatever is chosen (DES-053). Passive: it renders `settings` and reports
/// each change through `setSettings`; the folder chooser is local control state.
struct ExportSheetView: View {
    let title: String
    let settings: ExportSettings
    let setSettings: @MainActor (ExportSettings) -> Void
    let setDestination: @MainActor (URL) -> Void
    let export: @MainActor () -> Void
    let cancel: @MainActor () -> Void

    @State private var isChoosingFolder = false

    private func binding<Value>(_ keyPath: WritableKeyPath<ExportSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                var changed = settings
                changed[keyPath: keyPath] = value
                setSettings(changed)
            }
        )
    }

    private var footnote: String {
        settings.shapesRenderedFile
            ? "Photos are exported with their edits. Videos are exported as movies, trimmed as edited."
            : "Each file is exported as it is on disk, without its edit."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)
            Form {
                Section {
                    Picker("Format", selection: binding(\.format)) {
                        ForEach(ExportFormat.allCases, id: \.self) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    Picker("Size", selection: binding(\.limitsSize)) {
                        Text("Full Size").tag(false)
                        Text("Long Edge").tag(true)
                    }
                    .disabled(!settings.shapesRenderedFile)
                    LabeledContent("Long Edge") {
                        HStack(spacing: 6) {
                            TextField("Long Edge", value: binding(\.longEdge), format: .number.grouping(.never))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 72)
                            Text("pixels")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!settings.shapesRenderedFile || !settings.limitsSize)
                    LabeledContent("Quality") {
                        HStack(spacing: 8) {
                            Slider(value: binding(\.quality), in: 0 ... 1)
                                .labelsHidden()
                                .frame(width: 160)
                            Text("\(Int((settings.quality * 100).rounded()))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                        }
                    }
                    .disabled(!settings.shapesRenderedFile)
                    Toggle("Remove location", isOn: binding(\.removesLocation))
                        .disabled(!settings.shapesRenderedFile)
                } footer: {
                    Text(footnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Folder") {
                        HStack(spacing: 8) {
                            Text(settings.destination?.lastPathComponent ?? "None")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(settings.destination == nil ? .secondary : .primary)
                                .help(settings.destination?.path(percentEncoded: false) ?? "")
                            Button("Choose…") {
                                isChoosingFolder = true
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Export", action: export)
                    .keyboardShortcut(.defaultAction)
                    .disabled(settings.destination == nil)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                setDestination(url)
            }
        }
    }
}
