import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class OtosAppModel {
    var snapshot: CatalogSnapshot = .empty
    var selection: CatalogSelection = .allMedia
    var message: String?

    @ObservationIgnored private let catalogStore: CatalogStore
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false

    init(catalogStore: CatalogStore = CatalogStore()) {
        self.catalogStore = catalogStore
    }

    var visibleAssets: [MediaAsset] {
        snapshot.assets(for: selection)
    }

    var selectedTitle: String {
        snapshot.title(for: selection)
    }

    func start() {
        guard !hasStarted else {
            return
        }
        hasStarted = true

        let state = OtosSignpost.ui.beginInterval("CatalogModelStart")
        OtosSignpost.ui.endInterval("CatalogModelStart", state)
        OtosLog.ui.info("Catalog model started")

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
                message = CatalogStoreError.catalogUnavailable.localizedDescription
                OtosLog.persistence.error("Catalog start failed")
            }
        }
    }

    func addLibrary(url: URL) {
        Task {
            do {
                try await catalogStore.addLibrary(url: url)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func removeLibrary(_ library: LibraryRoot) {
        Task {
            do {
                try await catalogStore.removeLibrary(path: library.path)
                if selection == .library(library.path) {
                    selection = .allMedia
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func dismissMessage() {
        message = nil
    }

    private func apply(_ snapshot: CatalogSnapshot) {
        let state = OtosSignpost.ui.beginInterval("CatalogSnapshotApply")
        self.snapshot = snapshot
        let selectedLibraryWasRemoved: Bool = if case let .library(path) = selection {
            !snapshot.roots.contains(where: { $0.path == path })
        } else {
            false
        }
        if selectedLibraryWasRemoved {
            selection = .allMedia
        }
        OtosSignpost.ui.endInterval("CatalogSnapshotApply", state)
    }
}
