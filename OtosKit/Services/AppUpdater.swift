import AppKit
import Foundation
import OSLog
@preconcurrency import Sparkle

/// App updater guide
///
/// The installed app updates itself with Sparkle (ADR 0059). CI builds every `main` commit
/// whose `Required CI Gate` passed, signs it with the owner's development certificate and
/// with Otos's own EdDSA update key, and publishes it with Sparkle's feed on GitHub Releases
/// (`script/release.sh`). Sparkle checks the feed every hour (`SUScheduledCheckInterval`, its
/// shortest), downloads a newer build in the background without showing anything, and hands
/// the install to `UpdateInstallGate`, which holds it while an import or a reorganization is
/// in flight.
///
/// Only the installed app updates: the product identity `net.melisma.Otos`, a build that
/// carries the update key, and never a test run. A dev build (`net.melisma.Otos.dev`) would
/// replace itself with the published build of another identity, and a build without the key
/// could not check a download's signature.
@MainActor
final class AppUpdater {
    nonisolated static let installedBundleIdentifier = "net.melisma.Otos"

    private let controller: SPUStandardUpdaterController?
    /// Sparkle holds its delegate weakly; this keeps it.
    private let delegate: AppUpdaterDelegate

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

    /// App ▸ Check for Updates… is offered.
    var canCheckForUpdates: Bool {
        controller != nil
    }

    /// App ▸ Check for Updates…: Sparkle's own check, which shows what it finds.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

/// Sparkle's delegate: a downloaded update is installed through the gate, never on Sparkle's
/// own schedule. Sparkle calls it on the main thread.
@MainActor
final class AppUpdaterDelegate: NSObject, @preconcurrency SPUUpdaterDelegate {
    private let gate: UpdateInstallGate

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
        gate.hold(immediateInstallHandler, version: item.versionString)
        return true
    }
}
