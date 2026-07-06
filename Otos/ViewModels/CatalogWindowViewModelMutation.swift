import AppKit
import Foundation
import OSLog

/// Catalog mutation execution guide
///
/// `CatalogWindowViewModel` owns delivery: user and smoke-tooling commands enter
/// one lossless serial stream there. This file owns the tiny execution switch so
/// Store remains the only catalog writer and every mutation records the same
/// bounded diagnostics/error shape.
extension CatalogWindowViewModel {
    nonisolated static func performCatalogMutation(
        _ intent: CatalogMutationIntent,
        store: CatalogStore,
        diagnostics: CatalogDiagnostics?
    ) async {
        switch intent {
        case let .addLibrary(url):
            await performAddLibrary(url, store: store, diagnostics: diagnostics)
        case let .ensureLibrary(url):
            await performEnsureLibrary(url, store: store, diagnostics: diagnostics)
        case let .removeLibrary(path):
            await performRemoveLibrary(path, store: store, diagnostics: diagnostics)
        case let .ejectRemovableSource(root):
            await performEjectRemovableSource(root, store: store, diagnostics: diagnostics)
        case let .forgetRemovableSource(root):
            await performForgetRemovableSource(root, store: store, diagnostics: diagnostics)
        case let .attachRemovableVolume(attachment):
            await performAttachRemovableVolume(attachment, store: store, diagnostics: diagnostics)
        case let .detachRemovableSource(identity, reason):
            await performDetachRemovableSource(identity, reason: reason, store: store, diagnostics: diagnostics)
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
        diagnostics: CatalogDiagnostics?
    ) async {
        let signpost = OtosSignpost.ui.beginInterval("CatalogEjectRemovableSourceIntent")
        do {
            if let identity = root.deviceIdentity {
                try await store.detachRemovableSource(identity: identity, reason: .ejected)
            }
            try await MainActor.run {
                try NSWorkspace.shared.unmountAndEjectDevice(at: root.path.url)
            }
        } catch {
            await recordMutationError(
                "Catalog eject removable source failed",
                operation: "catalog.removable.eject",
                fields: ["rootPath": root.path.rawValue],
                error: error,
                diagnostics: diagnostics
            )
        }
        OtosSignpost.ui.endInterval("CatalogEjectRemovableSourceIntent", signpost)
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
