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
            let signpost = OtosSignpost.ui.beginInterval("CatalogAddLibraryIntent")
            do {
                try await store.addLibrary(url: url)
            } catch {
                OtosLog.catalog.error("Catalog add library failed")
                await diagnostics?.record(
                    operation: "catalog.library.add",
                    phase: "error",
                    fields: ["url": url.path(percentEncoded: false), "error": String(describing: error)]
                )
            }
            OtosSignpost.ui.endInterval("CatalogAddLibraryIntent", signpost)
        case let .ensureLibrary(url):
            let signpost = OtosSignpost.ui.beginInterval("CatalogEnsureLibraryIntent")
            do {
                try await store.ensureLibrary(url: url)
            } catch {
                OtosLog.catalog.error("Catalog ensure library failed")
                await diagnostics?.record(
                    operation: "catalog.library.ensure",
                    phase: "error",
                    fields: ["url": url.path(percentEncoded: false), "error": String(describing: error)]
                )
            }
            OtosSignpost.ui.endInterval("CatalogEnsureLibraryIntent", signpost)
        case let .removeLibrary(path):
            let signpost = OtosSignpost.ui.beginInterval("CatalogRemoveLibraryIntent")
            do {
                try await store.removeLibrary(path: path)
            } catch {
                OtosLog.catalog.error("Catalog remove library failed")
                await diagnostics?.record(
                    operation: "catalog.library.remove",
                    phase: "error",
                    fields: ["rootPath": path.rawValue, "error": String(describing: error)]
                )
            }
            OtosSignpost.ui.endInterval("CatalogRemoveLibraryIntent", signpost)
        }
    }
}
