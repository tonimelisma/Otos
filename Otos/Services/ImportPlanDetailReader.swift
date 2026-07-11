import Foundation
import OSLog

/// Visible-plan detail reader guide
///
/// Analogous to `MediaTileDetailReader`: the grid/footer ask only for dispositions
/// of currently visible IDs for one plan generation. The coordinator never publishes
/// a full `[MediaAssetID: PlanEntry]` map into `CatalogWindowState`.
struct ImportPlanDetailReader {
    private let coordinator: MediaOperationCoordinator
    private let sourcePath: LibraryRootPath
    private let generation: UInt64

    init(coordinator: MediaOperationCoordinator, sourcePath: LibraryRootPath, generation: UInt64) {
        self.coordinator = coordinator
        self.sourcePath = sourcePath
        self.generation = generation
    }

    func dispositions(for ids: [MediaAssetID]) async -> [MediaAssetID: MediaOperationDisposition] {
        guard !ids.isEmpty else {
            return [:]
        }
        guard let plan = await coordinator.readyPlan(for: sourcePath),
              plan.generation == generation
        else {
            return [:]
        }
        var result: [MediaAssetID: MediaOperationDisposition] = [:]
        result.reserveCapacity(ids.count)
        let byID = Dictionary(uniqueKeysWithValues: plan.entries.map { ($0.source.id, $0.disposition) })
        for id in ids {
            if let disposition = byID[id] {
                result[id] = disposition
            }
        }
        return result
    }
}
