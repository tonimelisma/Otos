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
        submitCatalogMutation(.addLibrary(url))
    }

    func ensureLibrary(url: URL) {
        submitCatalogMutation(.ensureLibrary(url))
    }

    func removeLibrary(_ library: LibraryRoot) {
        submitCatalogMutation(.removeLibrary(library.path))
    }

    func ejectRemovableSource(_ source: LibraryRoot) {
        guard let identity = source.deviceIdentity else {
            return
        }
        beginEjectingSource(identity)
        submitCatalogMutation(.ejectRemovableSource(source))
    }

    func forgetRemovableSource(_ source: LibraryRoot) {
        submitCatalogMutation(.forgetRemovableSource(source))
    }

    nonisolated static func performCatalogMutation(
        _ intent: CatalogMutationIntent,
        store: CatalogStore,
        coordinator: EnrichmentCoordinator?,
        diagnostics: CatalogDiagnostics?
    ) async -> RemovableEjectOutcome? {
        switch intent {
        case let .addLibrary(url):
            await performAddLibrary(url, store: store, diagnostics: diagnostics)
            return nil
        case let .ensureLibrary(url):
            await performEnsureLibrary(url, store: store, diagnostics: diagnostics)
            return nil
        case let .removeLibrary(path):
            await performRemoveLibrary(path, store: store, diagnostics: diagnostics)
            return nil
        case let .ejectRemovableSource(root):
            return await performEjectRemovableSource(
                root,
                store: store,
                coordinator: coordinator,
                diagnostics: diagnostics
            )
        case let .forgetRemovableSource(root):
            await performForgetRemovableSource(root, store: store, diagnostics: diagnostics)
            return nil
        case let .attachRemovableVolume(attachment):
            await performAttachRemovableVolume(attachment, store: store, diagnostics: diagnostics)
            return nil
        case let .quiesceRemovableSource(identity):
            await performQuiesceRemovableSource(identity, store: store, diagnostics: diagnostics)
            return nil
        case let .resumeRemovableSource(identity):
            await performResumeRemovableSource(identity, store: store, diagnostics: diagnostics)
            return nil
        case let .detachRemovableSource(identity, reason):
            await performDetachRemovableSource(identity, reason: reason, store: store, diagnostics: diagnostics)
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

    nonisolated static func isTypedBusyError(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain, error.code == EBUSY {
            return true
        }
        // DiskArbitration dissenter domain; busy/in-use dissent codes vary by OS, so any
        // dissenter error is treated as busy rather than a generic failure.
        if error.domain == "com.apple.DiskArbitration.DADissenterError" {
            return true
        }
        // Historical Cocoa shape sometimes seen for busy unmounts (not user-cancelled).
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteUnknownError {
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
}

private extension CatalogWindowViewModel {
    nonisolated static func performAddLibrary(
        _ url: URL,
        store: CatalogStore,
        diagnostics: CatalogDiagnostics?
    ) async {
        let signpost = OtosSignpost.ui.beginInterval("CatalogAddLibraryIntent")
        do {
            try await store.addLibrary(url: url)
        } catch {
            await recordMutationError(
                "Catalog add library failed",
                operation: "catalog.library.add",
                fields: ["url": url.path(percentEncoded: false)],
                error: error,
                diagnostics: diagnostics
            )
        }
        OtosSignpost.ui.endInterval("CatalogAddLibraryIntent", signpost)
    }

    nonisolated static func performEnsureLibrary(
        _ url: URL,
        store: CatalogStore,
        diagnostics: CatalogDiagnostics?
    ) async {
        let signpost = OtosSignpost.ui.beginInterval("CatalogEnsureLibraryIntent")
        do {
            try await store.ensureLibrary(url: url)
        } catch {
            await recordMutationError(
                "Catalog ensure library failed",
                operation: "catalog.library.ensure",
                fields: ["url": url.path(percentEncoded: false)],
                error: error,
                diagnostics: diagnostics
            )
        }
        OtosSignpost.ui.endInterval("CatalogEnsureLibraryIntent", signpost)
    }

    nonisolated static func performRemoveLibrary(
        _ path: LibraryRootPath,
        store: CatalogStore,
        diagnostics: CatalogDiagnostics?
    ) async {
        let signpost = OtosSignpost.ui.beginInterval("CatalogRemoveLibraryIntent")
        do {
            try await store.removeLibrary(path: path)
        } catch {
            await recordMutationError(
                "Catalog remove library failed",
                operation: "catalog.library.remove",
                fields: ["rootPath": path.rawValue],
                error: error,
                diagnostics: diagnostics
            )
        }
        OtosSignpost.ui.endInterval("CatalogRemoveLibraryIntent", signpost)
    }

    nonisolated static func performEjectRemovableSource(
        _ root: LibraryRoot,
        store: CatalogStore,
        coordinator: EnrichmentCoordinator?,
        diagnostics: CatalogDiagnostics?
    ) async -> RemovableEjectOutcome {
        let signpost = OtosSignpost.ui.beginInterval("CatalogEjectRemovableSourceIntent")
        defer {
            OtosSignpost.ui.endInterval("CatalogEjectRemovableSourceIntent", signpost)
        }
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
            try await unmountAndEjectDeviceOffMain(root.path.url)
            await diagnostics?.record(
                operation: "catalog.removable.eject",
                phase: "finish",
                fields: [
                    "rootPath": root.path.rawValue,
                    "outcome": "ejected",
                ]
            )
            return .ejected
        } catch {
            let outcome = removableEjectOutcome(for: error, displayName: root.displayName)
            await recordMutationError(
                "Catalog eject removable source failed",
                operation: "catalog.removable.eject",
                fields: [
                    "rootPath": root.path.rawValue,
                    "outcome": outcomeDiagnosticCase(outcome),
                ],
                error: error,
                diagnostics: diagnostics
            )
            return outcome
        }
    }

    nonisolated static func unmountAndEjectDeviceOffMain(_ url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
        }.value
    }

    nonisolated static func performForgetRemovableSource(
        _ root: LibraryRoot,
        store: CatalogStore,
        diagnostics: CatalogDiagnostics?
    ) async {
        let signpost = OtosSignpost.ui.beginInterval("CatalogForgetRemovableSourceIntent")
        do {
            try await store.removeLibrary(path: root.path)
        } catch {
            await recordMutationError(
                "Catalog forget removable source failed",
                operation: "catalog.removable.forget",
                fields: ["rootPath": root.path.rawValue],
                error: error,
                diagnostics: diagnostics
            )
        }
        OtosSignpost.ui.endInterval("CatalogForgetRemovableSourceIntent", signpost)
    }

    nonisolated static func performAttachRemovableVolume(
        _ attachment: RemovableVolumeAttachment,
        store: CatalogStore,
        diagnostics: CatalogDiagnostics?
    ) async {
        let signpost = OtosSignpost.ui.beginInterval("CatalogAttachRemovableVolumeIntent")
        do {
            try await store.attachRemovableVolume(
                mountURL: attachment.mountURL,
                identity: attachment.identity,
                displayName: attachment.displayName,
                isEjectable: attachment.isEjectable
            )
        } catch {
            await recordMutationError(
                "Catalog attach removable volume failed",
                operation: "catalog.removable.attach",
                fields: [
                    "identity": attachment.identity,
                    "url": attachment.mountURL.path(percentEncoded: false),
                ],
                error: error,
                diagnostics: diagnostics
            )
        }
        OtosSignpost.ui.endInterval("CatalogAttachRemovableVolumeIntent", signpost)
    }

    nonisolated static func performQuiesceRemovableSource(
        _ identity: String,
        store: CatalogStore,
        diagnostics: CatalogDiagnostics?
    ) async {
        do {
            try await store.quiesceRemovableSource(identity: identity)
        } catch {
            await recordMutationError(
                "Catalog quiesce removable source failed",
                operation: "catalog.removable.quiesce",
                fields: ["identity": identity],
                error: error,
                diagnostics: diagnostics
            )
        }
    }

    nonisolated static func performResumeRemovableSource(
        _ identity: String,
        store: CatalogStore,
        diagnostics: CatalogDiagnostics?
    ) async {
        do {
            try await store.resumeRemovableSource(identity: identity)
        } catch {
            await recordMutationError(
                "Catalog resume removable source failed",
                operation: "catalog.removable.resume",
                fields: ["identity": identity],
                error: error,
                diagnostics: diagnostics
            )
        }
    }

    nonisolated static func performDetachRemovableSource(
        _ identity: String,
        reason: RemovableSourceDetachReason,
        store: CatalogStore,
        diagnostics: CatalogDiagnostics?
    ) async {
        let signpost = OtosSignpost.ui.beginInterval("CatalogDetachRemovableSourceIntent")
        do {
            try await store.detachRemovableSource(identity: identity, reason: reason)
        } catch {
            await recordMutationError(
                "Catalog detach removable source failed",
                operation: "catalog.removable.detach",
                fields: ["identity": identity],
                error: error,
                diagnostics: diagnostics
            )
        }
        OtosSignpost.ui.endInterval("CatalogDetachRemovableSourceIntent", signpost)
    }

    nonisolated static func recordMutationError(
        _ message: String,
        operation: String,
        fields: [String: String],
        error: Error,
        diagnostics: CatalogDiagnostics?
    ) async {
        OtosLog.catalog.error("\(message, privacy: .public)")
        var fields = fields
        fields["error"] = String(describing: error)
        await diagnostics?.record(operation: operation, phase: "error", fields: fields)
    }
}
