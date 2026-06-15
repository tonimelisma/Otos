import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class CatalogSession {
    var snapshot: CatalogSnapshot = .empty

    @ObservationIgnored let projection: CatalogProjection
    @ObservationIgnored private let catalogStore: CatalogStore
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var projectionTask: Task<Void, Never>?
    @ObservationIgnored private var projectionGeneration = 0
    @ObservationIgnored private var hasStarted = false

    init(
        catalogStore: CatalogStore = CatalogStore(),
        projection: CatalogProjection = CatalogProjection()
    ) {
        self.catalogStore = catalogStore
        self.projection = projection
    }

    func start() {
        guard !hasStarted else {
            return
        }
        hasStarted = true

        let state = OtosSignpost.ui.beginInterval("CatalogSessionStart")
        OtosSignpost.ui.endInterval("CatalogSessionStart", state)
        OtosLog.ui.info("Catalog session started")

        snapshotTask = Task {
            let snapshots = await catalogStore.snapshots()
            for await snapshot in snapshots {
                apply(snapshot)
            }
        }

        startTask = Task {
            do {
                try await catalogStore.start()
            } catch {
                OtosLog.persistence.error("Catalog start failed")
                await CatalogDiagnostics.shared.record(
                    operation: "catalog.start",
                    phase: "error",
                    fields: ["error": String(describing: error)]
                )
            }
        }
    }

    func addLibrary(url: URL) {
        Task {
            do {
                try await catalogStore.addLibrary(url: url)
            } catch {
                OtosLog.catalog.error("Catalog add library failed")
                await CatalogDiagnostics.shared.record(
                    operation: "catalog.library.add",
                    phase: "error",
                    fields: [
                        "url": url.path(percentEncoded: false),
                        "error": String(describing: error),
                    ]
                )
            }
        }
    }

    func removeLibrary(_ library: LibraryRoot) {
        Task {
            do {
                try await catalogStore.removeLibrary(path: library.path)
            } catch {
                OtosLog.catalog.error("Catalog remove library failed")
                await CatalogDiagnostics.shared.record(
                    operation: "catalog.library.remove",
                    phase: "error",
                    fields: [
                        "rootPath": library.path.rawValue,
                        "error": String(describing: error),
                    ]
                )
            }
        }
    }

    private func apply(_ snapshot: CatalogSnapshot) {
        projectionGeneration += 1
        let generation = projectionGeneration
        projectionTask?.cancel()
        projectionTask = Task {
            let projectedSnapshot = await projection.sortedSnapshot(from: snapshot)
            guard !Task.isCancelled, generation == projectionGeneration else {
                return
            }
            self.snapshot = projectedSnapshot
        }
    }
}
