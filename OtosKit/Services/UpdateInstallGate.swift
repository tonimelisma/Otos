import Foundation
import OSLog

/// Update install gate guide
///
/// A downloaded update replaces the running app: Sparkle quits Otos, swaps the bundle and
/// opens it again (ADR 0059). That never interrupts work (ADR 0030): while an import or a
/// reorganization is in flight the install is held, and it runs once the Store says none is
/// (`CatalogStore.operationalWorkChanges`). Nothing here waits on time: the Store reports
/// every change of the answer from the journal write that made it.
///
/// One gate per app. Sparkle hands it the install each time it has a downloaded update; the
/// newest install replaces a held one. One task waits on the Store's answers and ends with
/// the install, or when the gate goes away.
///
/// The install quits the app, and quitting can wait on a reply that arrives as a main-queue
/// job (`applicationShouldTerminate`'s `.terminateLater`). So the install never runs inside a
/// main-queue job, where that reply could not be delivered: it runs from the main run loop's
/// own callback (`RunLoop.main.perform`).
@MainActor
@Observable
final class UpdateInstallGate {
    /// The Store's answers to "is an import or a reorganization in flight", current first.
    @ObservationIgnored private let operationalWork: @Sendable () async -> AsyncStream<Bool>
    /// The install Sparkle handed over last, until it runs.
    @ObservationIgnored private var install: (() -> Void)?
    /// The version the held install installs, as the user knows it; nil while none is held.
    /// App ▸ Check for Updates… says it (`AppUpdater.CheckAnswer`).
    private(set) var heldVersion: String?
    @ObservationIgnored private var waiting: Task<Void, Never>?

    init(operationalWork: @escaping @Sendable () async -> AsyncStream<Bool>) {
        self.operationalWork = operationalWork
    }

    /// Holds `install` until no import or reorganization is in flight, then runs it once.
    func hold(_ install: @escaping () -> Void, version: String) {
        self.install = install
        heldVersion = version
        OtosLog.app.noticeOperation("update.install", phase: "held", fields: ["version": version])
        guard waiting == nil else { return }
        let answers = operationalWork
        waiting = Task { [weak self] in
            for await inFlight in await answers() where !inFlight {
                guard let self else { return }
                self.waiting = nil
                RunLoop.main.perform { [weak self] in
                    MainActor.assumeIsolated { self?.runHeldInstall() }
                }
                return
            }
        }
    }

    /// Whether an install is held now.
    var isHolding: Bool {
        install != nil
    }

    private func runHeldInstall() {
        guard let install else { return }
        self.install = nil
        OtosLog.app.noticeOperation("update.install", phase: "installing", fields: ["version": heldVersion ?? ""])
        heldVersion = nil
        install()
    }

    isolated deinit {
        waiting?.cancel()
    }
}
