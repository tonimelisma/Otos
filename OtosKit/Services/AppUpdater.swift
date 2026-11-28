import AppKit
import Foundation
import OSLog
@preconcurrency import Sparkle

/// App updater guide
///
/// The installed app updates itself with Sparkle (ADR 0059). CI builds every `main` commit
/// whose `CI gate` passed, signs it with the maintainer's Apple Development certificate and
/// with Otos's own EdDSA update key, and publishes it with Sparkle's feed on GitHub Releases
/// (`script/release.sh`). Sparkle checks the feed every hour (`SUScheduledCheckInterval`, its
/// shortest), downloads a newer build in the background without showing anything, and hands
/// the install to `UpdateInstallGate`, which holds it while an import or a reorganization is
/// in flight. App ▸ Check for Updates… always answers: Sparkle's check, the version Otos holds
/// and why, or disabled while Sparkle's own session runs (`CheckAnswer`).
///
/// Only the installed app updates: the product identity `net.melisma.Otos`, a build that
/// carries the update key, and never a test run. A dev build (`net.melisma.Otos.dev`) would
/// replace itself with the published build of another identity, and a build without the key
/// could not check a download's signature.
@MainActor
@Observable
final class AppUpdater {
    nonisolated static let installedBundleIdentifier = "net.melisma.Otos"

    /// What App ▸ Check for Updates… does when chosen: Sparkle's own check, which shows what
    /// it finds; or, while Otos holds an update it downloaded, say which version waits and
    /// why (`UpdateInstallGate`); else nothing it could do, so the item is disabled. Sparkle
    /// itself answers a check with nothing while its session runs — the hourly check, a
    /// download, or an update Otos holds — so the menu never offers one then.
    enum CheckAnswer: Equatable {
        case check
        case showHeld(version: String)
        case unavailable
    }

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    /// Sparkle holds its delegate weakly; this keeps it.
    @ObservationIgnored private let delegate: AppUpdaterDelegate
    @ObservationIgnored private var sessionObservation: NSKeyValueObservation?
    /// Whether Sparkle would start a check now: no session of its own in progress.
    private var sparkleCanCheck = false

    init(store: CatalogStore, bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) {
        delegate = AppUpdaterDelegate(gate: UpdateInstallGate { await store.operationalWorkChanges() })
        let updates = Self.updatesItself(
            bundleIdentifier: bundle.bundleIdentifier,
            publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            environment: environment
        )
        controller = updates
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
            : nil
        // Sparkle sets `canCheckForUpdates` on the main thread as its sessions begin and end
        // (KVO-observable, its own documented way to validate the menu item).
        sessionObservation = controller?.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            MainActor.assumeIsolated {
                self?.sparkleCanCheck = canCheck
            }
        }
        OtosLog.app.noticeOperation("update.updater", phase: updates ? "started" : "off", fields: [
            "bundle": bundle.bundleIdentifier ?? "none",
        ])
    }

    /// Whether this build updates itself: the installed identity, carrying the update key,
    /// not under a test host.
    nonisolated static func updatesItself(bundleIdentifier: String?, publicKey: String?, environment: [String: String]) -> Bool {
        bundleIdentifier == installedBundleIdentifier
            && !(publicKey ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            && environment["XCTestConfigurationFilePath"] == nil
    }

    /// App ▸ Check for Updates… is offered: only by a build that updates itself.
    var offersCheck: Bool {
        controller != nil
    }

    /// What choosing App ▸ Check for Updates… does now; `.unavailable` disables it.
    var checkAnswer: CheckAnswer {
        Self.checkAnswer(sparkleCanCheck: sparkleCanCheck, heldVersion: delegate.gate.heldVersion)
    }

    /// A held update is said first: Sparkle's session stays open while Otos holds it, so it
    /// would answer a check with nothing.
    nonisolated static func checkAnswer(sparkleCanCheck: Bool, heldVersion: String?) -> CheckAnswer {
        if let heldVersion {
            return .showHeld(version: heldVersion)
        }
        return sparkleCanCheck ? .check : .unavailable
    }

    /// App ▸ Check for Updates….
    func checkForUpdates() {
        let answer = checkAnswer
        OtosLog.app.noticeOperation("update.check", phase: "chosen", fields: ["answer": "\(answer)"])
        switch answer {
        case .check:
            controller?.checkForUpdates(nil)
        case let .showHeld(version):
            let alert = NSAlert()
            alert.messageText = Self.heldTitle(version: version)
            alert.informativeText = Self.heldMessage
            alert.runModal()
        case .unavailable:
            break
        }
    }

    /// The alert's title for a held update (HIG Alerts: a short statement of the situation).
    nonisolated static func heldTitle(version: String) -> String {
        "Otos \(version) Is Ready to Install"
    }

    /// The alert's message: what holds the install, and what the user can do.
    nonisolated static let heldMessage = """
    Otos will restart to install it when the import or library reorganization in progress \
    finishes. To install it now, quit Otos.
    """
}

/// Sparkle's delegate: a downloaded update is installed through the gate, never on Sparkle's
/// own schedule. Sparkle calls it on the main thread.
@MainActor
final class AppUpdaterDelegate: NSObject, @preconcurrency SPUUpdaterDelegate {
    let gate: UpdateInstallGate

    init(gate: UpdateInstallGate) {
        self.gate = gate
    }

    /// A downloaded update is ready. Returning true keeps it until the gate runs the install;
    /// a quit before then installs it as Otos quits, which is Sparkle's default.
    func updater(
        _: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        gate.hold(immediateInstallHandler, version: item.displayVersionString)
        return true
    }
}
