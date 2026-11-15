import Darwin
import DiskArbitration
import Foundation
import OSLog

/// Catalog mutation execution guide
///
/// `CatalogWindowViewModel` owns delivery: user and smoke-tooling commands enter
/// one lossless serial stream there. This file owns the tiny execution switch so
/// Store remains the only catalog writer and every mutation records the same
/// bounded diagnostics/error shape.
extension CatalogWindowViewModel {
    func submitCatalogMutation(_ intent: CatalogMutationIntent) {
        switch mutationContinuation.yield(intent) {
        case .enqueued:
            return
        case .dropped:
            // The stream is unbounded, so dropping indicates that its declared
            // lossless contract has been broken rather than normal backpressure.
            assertionFailure("Unbounded catalog mutation stream dropped an intent")
            OtosLog.ui.error("Catalog mutation intent was unexpectedly dropped")
        case .terminated:
            assertionFailure("Catalog mutation submitted after stream termination")
            OtosLog.ui.error("Catalog mutation intent submitted after termination")
        @unknown default:
            assertionFailure("Unknown catalog mutation stream yield result")
            OtosLog.ui.error("Catalog mutation intent returned an unknown yield result")
        }
    }

    func addLibrary(url: URL) {
        logCatalogIntent("addLibrary", path: url.path)
        submitCatalogMutation(.addLibrary(url))
    }

    func ensureLibrary(url: URL) {
        logCatalogIntent("ensureLibrary", path: url.path)
        submitCatalogMutation(.ensureLibrary(url))
    }

    func removeLibrary(_ library: LibraryRoot) {
        logCatalogIntent("removeLibrary", path: library.path.rawValue)
        submitCatalogMutation(.removeLibrary(library))
    }

    /// One path for drag, `Move Up`/`Move Down`, and ⌘↑/⌘↓ in Settings →
    /// Libraries.
    func moveLibrary(_ path: LibraryRootPath, _ move: LibraryOrderMove) {
        OtosLog.ui.noticeOperation("intent.moveLibrary", phase: "received", fields: [
            "path": path.rawValue, "move": String(describing: move),
        ])
        submitCatalogMutation(.moveLibrary(path, move))
    }

    func ejectRemovableSource(_ source: LibraryRoot) {
        OtosLog.ui.noticeOperation("intent.eject", phase: "received", fields: [
            "sourcePath": source.path.rawValue,
        ])
        guard let identity = source.deviceIdentity else {
            OtosLog.ui.noticeOperation("intent.eject", phase: "rejected", fields: [
                "reason": "missingDeviceIdentity",
                "sourcePath": source.path.rawValue,
            ])
            ejectAlertMessage = "The source can’t be ejected because its device identity is unavailable."
            return
        }
        beginEjectingSource(identity)
        releaseLoupeVideo(under: source.path)
        submitCatalogMutation(.ejectRemovableSource(source))
    }

    func forgetRemovableSource(_ source: LibraryRoot) {
        logCatalogIntent("forgetRemovableSource", path: source.path.rawValue)
        submitCatalogMutation(.forgetRemovableSource(source))
    }

    private func logCatalogIntent(_ name: String, path: String) {
        OtosLog.ui.noticeOperation("intent.\(name)", phase: "received", fields: ["path": path])
    }

    nonisolated static func performCatalogMutation(
        _ intent: CatalogMutationIntent,
        store: CatalogStore,
        coordinator: EnrichmentCoordinator?,
        previewLoader: (any PreviewLoading)?,
        importer: MediaOperationCoordinator?,
        immichAccounts: ImmichAccounts? = nil
    ) async -> CatalogMutationReport? {
        switch intent {
        case let .addLibrary(url):
            await performAddLibrary(url, store: store)
            return nil
        case let .ensureLibrary(url):
            await performEnsureLibrary(url, store: store)
            return nil
        case let .removeLibrary(root):
            // An account's session and sync end before its root goes, so no pass holds
            // the root's listing lease while it is removed (ADR 0046).
            await immichAccounts?.forget(root)
            return await performRemoveLibrary(root, operation: "catalog.library.remove", store: store)
        case let .moveLibrary(path, move):
            await performMoveLibrary(path, move, store: store)
            return nil
        case let .ejectRemovableSource(root):
            return await .eject(performEjectRemovableSource(
                root,
                store: store,
                coordinator: coordinator,
                previewLoader: previewLoader,
                importInProgress: importer?.isImporting(from: root.path) ?? false
            ))
        case let .forgetRemovableSource(root):
            return await performRemoveLibrary(root, operation: "catalog.removable.forget", store: store)
        case let .attachRemovableVolume(attachment):
            await performAttachRemovableVolume(attachment, store: store)
            return nil
        case let .quiesceRemovableSource(identity):
            await performQuiesceRemovableSource(identity, store: store)
            return nil
        case let .resumeRemovableSource(identity):
            await performResumeRemovableSource(identity, store: store)
            return nil
        case let .detachRemovableSource(identity, reason):
            await performDetachRemovableSource(identity, reason: reason, store: store)
            return nil
        case let .acknowledgeIdentityRemaps(batchIDs):
            await performAcknowledgeIdentityRemaps(batchIDs, store: store)
            return nil
        case let .setDuplicatesReach(reach):
            await store.setDuplicatesReach(reach)
            return nil
        }
    }
}

extension CatalogWindowViewModel {
    nonisolated static func outcomeDiagnosticCase(_ outcome: RemovableEjectOutcome) -> String {
        switch outcome {
        case .ejected:
            "ejected"
        case .busy:
            "busy"
        case .failed:
            "failed"
        }
    }

    /// Backoff after the system refuses an unmount as busy. Before the first attempt Otos
    /// has released every read it owns on the card: quiesce awaits the cancelled scan and
    /// stops new claims, the enrichment drain waits for the work already running, the
    /// preview loader finishes its decodes there and refuses new ones, and the window has
    /// released a loupe player showing a card file. A busy refusal after that is a holder
    /// outside Otos — Spotlight, Finder, another app — which Otos cannot ask to finish, so
    /// a few retries outlast a short-lived one without hiding a volume that stays held.
    nonisolated static let ejectBusyRetryDelays: [Duration] = [
        .milliseconds(500), .seconds(1), .seconds(2), .seconds(4),
    ]

    nonisolated static func performEjectRemovableSource(
        _ root: LibraryRoot,
        store: CatalogStore,
        coordinator: EnrichmentCoordinator?,
        previewLoader: (any PreviewLoading)?,
        importInProgress: Bool = false,
        retryDelays: [Duration] = ejectBusyRetryDelays,
        eject: @Sendable (URL) async -> DiskEjector.Outcome = DiskEjector.eject(volumeAt:)
    ) async -> RemovableEjectOutcome {
        guard let identity = root.deviceIdentity else {
            return .failed(description: "The disk could not be ejected.")
        }
        // The import holds the card's files open until it ends, and is Otos's own work:
        // the eject is refused now with the in-use alert, and nothing was quiesced.
        guard !importInProgress else {
            OtosLog.catalog.noticeOperation("catalog.removable.eject", phase: "refused", fields: [
                "rootPath": root.path.rawValue,
                "reason": "importRunning",
            ])
            return .busy(displayName: root.displayName)
        }
        do {
            try await store.quiesceRemovableSource(identity: identity)
        } catch {
            await recordMutationError(
                "Catalog eject removable source failed",
                operation: "catalog.removable.eject",
                fields: ["rootPath": root.path.rawValue, "phase": "quiesce"],
                error: error
            )
            return await ejectFailed(root: root, store: store, previewLoader: previewLoader, reason: .quiesceFailed)
        }
        if let coordinator {
            await coordinator.drainWork(under: root.path)
        }
        await previewLoader?.quiesce(under: root.path)
        var attempt = 0
        while true {
            let outcome = await eject(root.path.url)
            switch outcome {
            case .ejected:
                OtosLog.catalog.notice(
                    "op=catalog.removable.eject phase=finish outcome=ejected attempts=\(attempt + 1, privacy: .public) rootPath=\(root.path.rawValue, privacy: .public)"
                )
                await previewLoader?.resume(under: root.path)
                return .ejected
            case .busy where attempt < retryDelays.count:
                let delay = retryDelays[attempt]
                attempt += 1
                OtosLog.catalog.notice(
                    "op=catalog.removable.eject phase=retry reason=busy attempt=\(attempt, privacy: .public) delayMs=\(DiagnosticsTiming.milliseconds(delay), privacy: .public) rootPath=\(root.path.rawValue, privacy: .public)"
                )
                do {
                    // time: backoff — a holder outside Otos keeps the card busy
                    try await Task.sleep(for: delay)
                } catch {
                    return await ejectFailed(root: root, store: store, previewLoader: previewLoader, reason: .cancelled)
                }
            case .busy:
                return await ejectFailed(root: root, store: store, previewLoader: previewLoader, reason: .busy)
            case let .refused(status):
                return await ejectFailed(root: root, store: store, previewLoader: previewLoader, reason: .refused(status))
            case .diskUnavailable:
                return await ejectFailed(root: root, store: store, previewLoader: previewLoader, reason: .diskUnavailable)
            }
        }
    }

    private nonisolated enum EjectFailure {
        case quiesceFailed
        case cancelled
        case busy
        case refused(DAReturn)
        case diskUnavailable

        var logReason: String {
            switch self {
            case .quiesceFailed: "quiesceFailed"
            case .cancelled: "cancelled"
            case .busy: "busy"
            case let .refused(status): String(format: "refused:0x%08X", UInt32(bitPattern: status))
            case .diskUnavailable: "diskUnavailable"
            }
        }
    }

    /// An eject Otos asked for reports its own outcome, so a failed one resumes the source
    /// at once: the card is still mounted and its scan, enrichment and previews have no
    /// reason to stay stopped. An eject started elsewhere reports nothing when it is
    /// refused, which is why `RemovableVolumeMonitor` keeps its own limit for that case.
    private nonisolated static func ejectFailed(
        root: LibraryRoot,
        store: CatalogStore,
        previewLoader: (any PreviewLoading)?,
        reason: EjectFailure
    ) async -> RemovableEjectOutcome {
        if let identity = root.deviceIdentity {
            do {
                try await store.resumeRemovableSource(identity: identity)
            } catch {
                OtosLog.catalog.errorOperation("catalog.removable.eject", phase: "resumeFailed", fields: [
                    "rootPath": root.path.rawValue,
                    "error": String(describing: error),
                ])
            }
        }
        await previewLoader?.resume(under: root.path)
        let outcome: RemovableEjectOutcome = switch reason {
        case .busy:
            .busy(displayName: root.displayName)
        case let .refused(status):
            .failed(description: ejectFailureDescription(displayName: root.displayName, status: status))
        case .quiesceFailed, .cancelled, .diskUnavailable:
            .failed(description: ejectFailureDescription(displayName: root.displayName, status: nil))
        }
        OtosLog.catalog.errorOperation("catalog.removable.eject", phase: "finish", fields: [
            "rootPath": root.path.rawValue,
            "outcome": outcomeDiagnosticCase(outcome),
            "reason": reason.logReason,
        ])
        return outcome
    }

    /// The alert text for a refusal that is not "busy": the BSD error the status encodes,
    /// in the system's own words, or no cause at all when the status is DiskArbitration's
    /// own — never a guess at one.
    nonisolated static func ejectFailureDescription(displayName: String, status: DAReturn?) -> String {
        let base = "The disk \u{201C}\(displayName)\u{201D} couldn\u{2019}t be ejected."
        guard let status, let code = DiskEjector.bsdError(in: status), let reason = strerror(code) else {
            return base
        }
        return "\(base) \(String(cString: reason))."
    }
}

private extension CatalogWindowViewModel {
    nonisolated static func performAddLibrary(
        _ url: URL,
        store: CatalogStore
    ) async {
        do {
            try await store.addLibrary(url: url)
        } catch {
            await recordMutationError(
                "Catalog add library failed",
                operation: "catalog.library.add",
                fields: ["url": url.path(percentEncoded: false)],
                error: error
            )
        }
    }

    nonisolated static func performEnsureLibrary(
        _ url: URL,
        store: CatalogStore
    ) async {
        do {
            try await store.ensureLibrary(url: url)
        } catch {
            await recordMutationError(
                "Catalog ensure library failed",
                operation: "catalog.library.ensure",
                fields: ["url": url.path(percentEncoded: false)],
                error: error
            )
        }
    }

    /// Removing a library and forgetting a removable source are one removal. One that
    /// waits for the owner holding the root reports it, so the user is told it will go
    /// when that work finishes.
    nonisolated static func performRemoveLibrary(
        _ root: LibraryRoot,
        operation: String,
        store: CatalogStore
    ) async -> CatalogMutationReport? {
        do {
            switch try await store.removeLibrary(path: root.path) {
            case .removed, .notInCatalog:
                return nil
            case let .waiting(owner):
                return .removalWaiting(LibraryRemovalNotice(displayName: root.displayName, waitingFor: owner))
            }
        } catch {
            await recordMutationError(
                "Catalog remove library failed",
                operation: operation,
                fields: ["rootPath": root.path.rawValue],
                error: error
            )
            return nil
        }
    }

    nonisolated static func performMoveLibrary(
        _ path: LibraryRootPath,
        _ move: LibraryOrderMove,
        store: CatalogStore
    ) async {
        do {
            try await store.moveLibrary(path, move)
        } catch {
            await recordMutationError(
                "Catalog move library failed",
                operation: "catalog.library.move",
                fields: ["path": path.rawValue, "move": String(describing: move)],
                error: error
            )
        }
    }

    /// A failed acknowledgement leaves the batches pending: they keep arriving with
    /// published states, the window skips them as applied, and the next launch's load
    /// clears them.
    nonisolated static func performAcknowledgeIdentityRemaps(
        _ batchIDs: [Int64],
        store: CatalogStore
    ) async {
        do {
            try await store.acknowledgeIdentityRemaps(batchIDs)
        } catch {
            await recordMutationError(
                "Identity remap acknowledgement failed",
                operation: "reorganization.remapAcknowledged",
                fields: ["batches": batchIDs.map(String.init).joined(separator: ",")],
                error: error
            )
        }
    }

    nonisolated static func performAttachRemovableVolume(
        _ attachment: RemovableVolumeAttachment,
        store: CatalogStore
    ) async {
        do {
            try await store.attachRemovableVolume(
                mountURL: attachment.mountURL,
                identity: attachment.identity,
                displayName: attachment.displayName,
                isEjectable: attachment.isEjectable,
                capabilities: attachment.capabilities,
                deviceModel: attachment.deviceModel,
                volumeFormat: attachment.volumeFormat
            )
        } catch {
            await recordMutationError(
                "Catalog attach removable volume failed",
                operation: "catalog.removable.attach",
                fields: [
                    "identity": attachment.identity.rawValue,
                    "url": attachment.mountURL.path(percentEncoded: false),
                ],
                error: error
            )
        }
    }

    nonisolated static func performQuiesceRemovableSource(
        _ identity: DeviceIdentity,
        store: CatalogStore
    ) async {
        do {
            try await store.quiesceRemovableSource(identity: identity)
        } catch {
            await recordMutationError(
                "Catalog quiesce removable source failed",
                operation: "catalog.removable.quiesce",
                fields: ["identity": identity.rawValue],
                error: error
            )
        }
    }

    nonisolated static func performResumeRemovableSource(
        _ identity: DeviceIdentity,
        store: CatalogStore
    ) async {
        do {
            try await store.resumeRemovableSource(identity: identity)
        } catch {
            await recordMutationError(
                "Catalog resume removable source failed",
                operation: "catalog.removable.resume",
                fields: ["identity": identity.rawValue],
                error: error
            )
        }
    }

    nonisolated static func performDetachRemovableSource(
        _ identity: DeviceIdentity,
        reason: RemovableSourceDetachReason,
        store: CatalogStore
    ) async {
        do {
            try await store.detachRemovableSource(identity: identity, reason: reason)
        } catch {
            await recordMutationError(
                "Catalog detach removable source failed",
                operation: "catalog.removable.detach",
                fields: ["identity": identity.rawValue],
                error: error
            )
        }
    }

    nonisolated static func recordMutationError(
        _ message: String,
        operation: String,
        fields: [String: String],
        error: Error
    ) async {
        OtosLog.catalog.error("\(message, privacy: .public)")
        var fields = fields
        fields["error"] = String(describing: error)
        OtosLog.catalog.error(
            "op=\(operation, privacy: .public) phase=error \(otosLogFields(fields), privacy: .public)"
        )
    }
}
