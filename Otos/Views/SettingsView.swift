import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var model: OtosAppModel

    var body: some View {
        TabView {
            LibrariesSettingsView(model: model)
                .tabItem {
                    Label("Libraries", systemImage: "folder")
                }
        }
        .frame(width: 660, height: 380)
        .scenePadding()
    }
}

private struct LibrariesSettingsView: View {
    @Bindable var model: OtosAppModel
    @State private var showingImporter = false
    @State private var selectedPath: String?
    @State private var removalCandidate: LibraryRoot?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Libraries")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    showingImporter = true
                } label: {
                    Label("Add Library", systemImage: "plus")
                }
                Button(role: .destructive) {
                    removalCandidate = selectedRoot
                } label: {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(selectedRoot == nil)
            }

            Table(model.snapshot.roots, selection: $selectedPath) {
                TableColumn("Name") { root in
                    Text(root.displayName)
                        .lineLimit(1)
                }
                .width(min: 140, ideal: 180)

                TableColumn("Path") { root in
                    Text(root.path)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                model.addLibrary(url: url)
            }
        }
        .alert("Remove Library?", isPresented: removalAlertBinding, presenting: removalCandidate) { root in
            Button("Remove Library", role: .destructive) {
                model.removeLibrary(root)
                removalCandidate = nil
                selectedPath = nil
            }
            Button("Cancel", role: .cancel) {
                removalCandidate = nil
            }
        } message: { _ in
            Text(
                """
                Original media files will stay on disk. Otos will delete this library's catalog information, \
                and adding it again will require a new scan.
                """
            )
        }
    }

    private var selectedRoot: LibraryRoot? {
        guard let selectedPath else {
            return nil
        }
        return model.snapshot.roots.first { $0.path == selectedPath }
    }

    private var removalAlertBinding: Binding<Bool> {
        Binding {
            removalCandidate != nil
        } set: { isPresented in
            if !isPresented {
                removalCandidate = nil
            }
        }
    }
}

#Preview {
    SettingsView(model: OtosAppModel())
}
