import SwiftUI

/// Settings ▸ Libraries ▸ Add Immich Account…'s sheet, also opened by Sign In… for an
/// account that is signed out (ADR 0046). Its L1 fact is its title; the three fields are
/// L2 controls; one L3 footnote line says what Otos does with the account, or why the
/// last attempt failed, so the sheet keeps one height in every state (DES-053). Passive:
/// the fields are local control state, `state` comes from the view model, and its action
/// and Cancel call the view model's intents.
struct ImmichAccountSheetView: View {
    let state: ImmichAccountSheetState
    let add: @MainActor (_ server: String, _ email: String, _ password: String) -> Void
    let cancel: @MainActor () -> Void

    @State private var server = ""
    @State private var email = ""
    @State private var password = ""

    /// Verbatim, like the address prompt: a `LocalizedStringKey` is read as Markdown,
    /// which draws a URL in the accent color as a link (DES-024).
    private static let promise = "Otos shows this account’s photos and never changes anything on the server."

    private var canAdd: Bool {
        !state.isAdding && !server.isEmpty && !email.isEmpty && !password.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(state.title)
                .font(.title2)
                .padding(.horizontal, 20)
                .padding(.top, 20)
            Form {
                Section {
                    TextField("Server", text: $server, prompt: Text(verbatim: "https://photos.example.com"))
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } footer: {
                    Label {
                        Text(verbatim: state.failure ?? Self.promise)
                    } icon: {
                        Image(systemName: state.failure == nil ? "info.circle" : "exclamationmark.triangle")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .disabled(state.isAdding)
            HStack(spacing: 8) {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .opacity(state.isAdding ? 1 : 0)
                    .accessibilityHidden(!state.isAdding)
                    .accessibilityLabel("Signing in")
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(state.actionTitle) {
                    add(server, email, password)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            server = state.server
        }
    }
}
