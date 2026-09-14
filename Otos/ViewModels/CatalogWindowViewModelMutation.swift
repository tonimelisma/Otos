import AppKit
import Darwin
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
        submitCatalogMutation(.removeLibrary(library.path))
    }

    /// One path for drag, `Move Up`/`Move Down`, and ⌘↑/⌘↓ in Settings →
    /// Libraries.
    func moveLibrary(from sourceIndex: Int, to destinationIndex: Int) {
        OtosLog.ui.noticeOperation("intent.moveLibrary", phase: "received", fields: [
            "from": "\(sourceIndex)", "to": "\(destinationIndex)",
        ])
        submitCatalogMutation(.moveLibrary(from: sourceIndex, to: destinationIndex))
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
        coordinator: EnrichmentCoordinator?
    ) async -> RemovableEjectOutcome? {
        switch intent {
        case let .addLibrary(url):
            await performAddLibrary(url, store: store)
            return nil
        case let .ensureLibrary(url):
            await performEnsureLibrary(url, store: store)
            return nil
        case let .removeLibrary(path):
            await performRemoveLibrary(path, store: store)
            return nil
        case let .moveLibrary(sourceIndex, destinationIndex):
            await performMoveLibrary(from: sourceIndex, to: destinationIndex, store: store)
            return nil
        case let .ejectRemovableSource(root):
            return await performEjectRemovableSource(
                root,
                store: store,
                coordinator: coordinator
            )
        case let .forgetRemovableSource(root):
            await performForgetRemovableSource(root, store: store)
            return nil
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
        }
    }
}

extension CatalogWindowViewModel {
    nonisolated static func removableEjectOutcome(for error: Error, displayName: String) -> RemovableEjectOutcome {
        let nsError = error as NSError
        if isUserCancelledEjectError(nsError) {
            return .cancelled
        }
        if isVolumeBusyError(nsError) {
            return .busy(displayName: displayName)
        }
        OtosLog.catalog.error(
            "op=removableEject unrecognizedError domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
        )
        return .failed(description: nsError.localizedDescription)
    }

    /// User declined the system eject UI — not a busy failure.
    nonisolated static func isUserCancelledEjectError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain, error.code == NSUserCancelledError {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isUserCancelledEjectError(underlying)
        }
        return false
    }

    /// Prefer typed underlying errors (DiskArbitration dissenter / POSIX EBUSY) over
    /// English substring matching on `localizedDescription`. The substring check remains
    /// only as a last-chance fallback for unrecognized shapes.
    nonisolated static func isVolumeBusyError(_ error: NSError) -> Bool {
        if isTypedBusyError(error) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           isTypedBusyError(underlying) || isVolumeBusyError(underlying)
        {
            return true
        }
        let description = error.localizedDescription
        return description.localizedCaseInsensitiveContains("in use")
            || description.localizedCaseInsensitiveContains("busy")
    }

    /// `fBsyErr` from CarbonCore/MacErrors.h, spelled out because the Carbon
    /// error enums do not import into Swift by name.
    nonisolated static let fileBusyOSStatus = -47

    nonisolated static func isTypedBusyError(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain, error.code == EBUSY {
            return true
        }
        // `NSWorkspace.unmountAndEjectDevice` reports a held volume as the
        // Carbon `fBsyErr` ("File is busy", CarbonCore/MacErrors.h) —
        // observed 2026-09-13.
        if error.domain == NSOSStatusErrorDomain, error.code == fileBusyOSStatus {
            return true
        }
        // DiskArbitration dissenter domain; busy/in-use dissent codes vary by OS, so any
        // dissenter error is treated as busy rather than a generic failure.
        if error.domain == "com.apple.DiskArbitration.DADissenterError" {
            return true
        }
        return false
    }

    nonisolated static func outcomeDiagnosticCase(_ outcome: RemovableEjectOutcome) -> String {
        switch outcome {
        case .ejected:
            "ejected"
        case .cancelled:
            "cancelled"
        case .busy:
            "busy"
        case .failed:
            "failed"
        }
    }

    /// How long a busy volume is given before the eject is reported as busy.
    /// Otos's own readers on a card — a thumbnail or metadata pass that was in
    /// flight when the erase sweep finished — close within a few seconds; a
    /// bounded retry outlasts them without hiding a volume that is genuinely
    /// held by something else. On 2026-09-13 the first attempt came 120 ms
    /// after the erase sweep released the card and failed `fBsyErr`.
    nonisolated static let ejectBusyRetryDelays: [Duration] = [
        .milliseconds(500), .seconds(1), .seconds(2), .seconds(4),
    ]

    nonisolated static func performEjectRemovableSource(
        _ root: LibraryRoot,
        store: CatalogStore,
        coordinator: EnrichmentCoordinator?,
        retryDelays: [Duration] = ejectBusyRetryDelays,
        unmount: @Sendable (URL) async throws -> Void = unmountAndEjectDeviceOffMain
    ) async -> RemovableEjectOutcome {
        guard let identity = root.deviceIdentity else {
            return .failed(description: "The disk could not be ejected.")
        }
        do {
            try await store.quiesceRemovableSource(identity: identity)
            if let coordinator {
                let drained = await coordinator.drainWork(under: root.path)
                if !drained {
                    OtosLog.catalog.error(
                        "op=removableEject drainTimedOut rootPath=\(root.path.rawValue, privacy: .public)"
                    )
                }
            }
        } catch {
            return await ejectFailed(root: root, error: error)
        }
        var attempt = 0
        while true {
            do {
                try await unmount(root.path.url)
                OtosLog.catalog.notice(
                    // swiftlint:disable:next line_length
                    "op=catalog.removable.eject phase=finish outcome=ejected attempts=\(attempt + 1, privacy: .public) rootPath=\(root.path.rawValue, privacy: .public)"
                )
                return .ejected
            } catch {
                let outcome = removableEjectOutcome(for: error, displayName: root.displayName)
                guard case .busy = outcome, attempt < retryDelays.count else {
                    return await ejectFailed(root: root, error: error)
                }
                let delay = retryDelays[attempt]
                attempt += 1
                OtosLog.catalog.notice(
                    // swiftlint:disable:next line_length
                    "op=catalog.removable.eject phase=retry reason=busy attempt=\(attempt, privacy: .public) delayMs=\(DiagnosticsTiming.milliseconds(delay), privacy: .public) rootPath=\(root.path.rawValue, privacy: .public)"
                )
                try? await Task.sleep(for: delay)
            }
        }
    }

    private nonisolated static func ejectFailed(root: LibraryRoot, error: Error) async -> RemovableEjectOutcome {
        let outcome = removableEjectOutcome(for: error, displayName: root.displayName)
        await recordMutationError(
            "Catalog eject removable source failed",
            operation: "catalog.removable.eject",
            fields: [
                "rootPath": root.path.rawValue,
                "outcome": outcomeDiagnosticCase(outcome),
            ],
            error: error
        )
        return outcome
    }

    nonisolated static func unmountAndEjectDeviceOffMain(_ url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
        }.value
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

    nonisolated static func performRemoveLibrary(
        _ path: LibraryRootPath,
        store: CatalogStore
    ) async {
        do {
            try await store.removeLibrary(path: path)
        } catch {
            await recordMutationError(
                "Catalog remove library failed",
                operation: "catalog.library.remove",
                fields: ["rootPath": path.rawValue],
                error: error
            )
        }
    }

    nonisolated static func performMoveLibrary(
        from sourceIndex: Int,
        to destinationIndex: Int,
        store: CatalogStore
    ) async {
        do {
            try await store.moveLibrary(from: sourceIndex, to: destinationIndex)
        } catch {
            await recordMutationError(
                "Catalog move library failed",
                operation: "catalog.library.move",
                fields: ["from": "\(sourceIndex)", "to": "\(destinationIndex)"],
                error: error
            )
        }
    }

    nonisolated static func performForgetRemovableSource(
        _ root: LibraryRoot,
        store: CatalogStore
    ) async {
        do {
            try await store.removeLibrary(path: root.path)
        } catch {
            await recordMutationError(
                "Catalog forget removable source failed",
                operation: "catalog.removable.forget",
                fields: ["rootPath": root.path.rawValue],
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
                    "identity": attachment.identity,
                    "url": attachment.mountURL.path(percentEncoded: false),
                ],
                error: error
            )
        }
    }

    nonisolated static func performQuiesceRemovableSource(
        _ identity: String,
        store: CatalogStore
    ) async {
        do {
            try await store.quiesceRemovableSource(identity: identity)
        } catch {
            await recordMutationError(
                "Catalog quiesce removable source failed",
                operation: "catalog.removable.quiesce",
                fields: ["identity": identity],
                error: error
            )
        }
    }

    nonisolated static func performResumeRemovableSource(
        _ identity: String,
        store: CatalogStore
    ) async {
        do {
            try await store.resumeRemovableSource(identity: identity)
        } catch {
            await recordMutationError(
                "Catalog resume removable source failed",
                operation: "catalog.removable.resume",
                fields: ["identity": identity],
                error: error
            )
        }
    }

    nonisolated static func performDetachRemovableSource(
        _ identity: String,
        reason: RemovableSourceDetachReason,
        store: CatalogStore
    ) async {
        do {
            try await store.detachRemovableSource(identity: identity, reason: reason)
        } catch {
            await recordMutationError(
                "Catalog detach removable source failed",
                operation: "catalog.removable.detach",
                fields: ["identity": identity],
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
