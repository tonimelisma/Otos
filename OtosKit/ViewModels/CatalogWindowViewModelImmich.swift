import Foundation
import OSLog

/// Immich account intents guide
///
/// Settings ▸ Libraries ▸ Add Immich Account… opens a sheet (`immichAccountSheet`) that
/// asks for the server's address, an email and a password. Add submits one request to an
/// ordered, lossless lane (`immichIntentStream`) with one consumer, which hands it to
/// `ImmichAccounts` and shows what came back: the sheet closes once the account is added,
/// and stays open with the reason when it is not. A sheet cancelled while its request
/// runs ignores the answer (`generation`).
///
/// Each account's status — online, offline, signed out — arrives newest-wins from
/// `ImmichAccounts.statuses` into `immichAccountStatuses` for the sidebar and Settings.
nonisolated enum ImmichAccountIntent: Sendable {
    case add(server: URL, email: String, password: String, generation: UInt64)
}

/// The Add Immich Account sheet's state; its fields are the sheet's own.
nonisolated struct ImmichAccountSheetState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case editing
        case adding
        case failed(ImmichAddAccountOutcome)
    }

    var phase: Phase = .editing
    /// The address to prefill: an account signing in again names its own server.
    var server: String = ""
    /// Signing an account Otos already has back in, rather than adding one.
    var isSigningIn = false

    /// The sheet's L1 fact, and its action's title (DES-036: the result it commits to).
    var title: String {
        isSigningIn ? "Sign In to Immich" : "Add Immich Account"
    }

    var actionTitle: String {
        isSigningIn ? "Sign In" : "Add Account"
    }

    var isAdding: Bool {
        phase == .adding
    }

    /// Why the last attempt did not add the account, as the sheet says it.
    var failure: String? {
        guard case let .failed(outcome) = phase else {
            return nil
        }
        return switch outcome {
        case .added: nil
        case .invalidServer: "Enter the server’s web address, starting with http:// or https://."
        case .unreachable: "Nothing answered at that address. Check it, and that this Mac can reach the server."
        case .notImmich: "That address didn’t answer as an Immich server."
        case let .unsupportedVersion(major): "This server runs Immich \(major). Otos works with Immich 3."
        case .wrongCredentials: "The email or password is incorrect."
        case .notSaved: "The account couldn’t be saved. Try again."
        }
    }
}

extension CatalogWindowViewModel {
    /// Settings' Add Immich Account…: opens the sheet.
    func beginAddingImmichAccount(server: URL? = nil) {
        guard immichAccounts != nil else { return }
        immichAccountSheet = ImmichAccountSheetState(server: server?.absoluteString ?? "", isSigningIn: server != nil)
    }

    func cancelImmichAccountSheet() {
        immichAccountSheet = nil
    }

    /// The sheet's Add Account: one request on the ordered lane.
    func addImmichAccount(server: String, email: String, password: String) {
        guard var sheet = immichAccountSheet, !sheet.isAdding else { return }
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ImmichServerAddress.normalized(url) != nil else {
            sheet.phase = .failed(.invalidServer)
            immichAccountSheet = sheet
            return
        }
        sheet.phase = .adding
        immichAccountSheet = sheet
        immichAddRequested &+= 1
        immichIntentContinuation.yield(.add(
            server: url, email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password,
            generation: immichAddRequested
        ))
        OtosLog.ui.noticeOperation("immich.add", phase: "submitted", fields: [
            "generation": "\(immichAddRequested)",
        ])
    }

    /// Hears the accounts' statuses and runs the sheet's intents from now; the accounts' own
    /// sync starts with the other background owners, after the first grid
    /// (`startBackgroundOwners`).
    func startImmichAccounts() {
        guard let accounts = immichAccounts else { return }
        immichStatusTask = Task { [weak self, accounts] in
            for await statuses in accounts.statuses {
                guard let self else { break }
                immichAccountStatuses = statuses
            }
        }
        immichIntentTask = Task { [weak self, immichIntentStream, accounts] in
            for await intent in immichIntentStream {
                guard !Task.isCancelled else { break }
                switch intent {
                case let .add(server, email, password, generation):
                    let outcome = await accounts.add(server: server, email: email, password: password)
                    self?.finishAddingImmichAccount(outcome, generation: generation)
                }
            }
        }
    }

    private func finishAddingImmichAccount(_ outcome: ImmichAddAccountOutcome, generation: UInt64) {
        OtosLog.ui.noticeOperation("immich.add", phase: "finished", fields: [
            "generation": "\(generation)", "outcome": String(describing: outcome),
        ])
        guard generation == immichAddRequested, var sheet = immichAccountSheet else { return }
        if case .added = outcome {
            immichAccountSheet = nil
        } else {
            sheet.phase = .failed(outcome)
            immichAccountSheet = sheet
        }
    }
}
