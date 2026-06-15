import Foundation
import Observation

@MainActor
@Observable
final class CatalogBrowserState {
    var selection: CatalogSelection = .allMedia
    var projection: CatalogBrowserProjection = .empty

    @ObservationIgnored private let catalogProjection: CatalogProjection
    @ObservationIgnored private var projectionTask: Task<Void, Never>?
    @ObservationIgnored private var projectionGeneration = 0

    init(catalogProjection: CatalogProjection) {
        self.catalogProjection = catalogProjection
    }

    var title: String {
        projection.title
    }

    var assetsForSelection: [MediaAsset] {
        projection.assetsForSelection
    }

    func update(snapshot: CatalogSnapshot) {
        let selectedLibraryWasRemoved: Bool = if case let .library(path) = selection {
            !snapshot.roots.contains(where: { $0.path == path })
        } else {
            false
        }

        if selectedLibraryWasRemoved {
            selection = .allMedia
        }

        projectionGeneration += 1
        let generation = projectionGeneration
        let selection = selection
        projectionTask?.cancel()
        projectionTask = Task {
            let projection = await catalogProjection.browserProjection(
                snapshot: snapshot,
                selection: selection
            )
            guard !Task.isCancelled, generation == projectionGeneration else {
                return
            }
            self.projection = projection
        }
    }
}
