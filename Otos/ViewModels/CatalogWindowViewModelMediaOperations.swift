import Foundation
import Observation
import OSLog

/// Media-operation intents and presentation owned by the catalog window ViewModel.
///
/// The coordinator actor owns plan lifecycle; this MainActor bridge only assigns
/// SwiftUI-visible presentation, destination intents, and queued Import starts.
extension CatalogWindowViewModel {
    var selectedImportPresentation: MediaOperationSourcePresentation? {
        guard case let .library(path) = sidebarSelection else {
            return nil
        }
        guard state.removableSources.contains(where: { $0.path == path }) else {
            return nil
        }
        return importPresentations.first { $0.sourcePath == path }
    }

    var importPlanDetailReader: ImportPlanDetailReader? {
        guard let coordinator = mediaOperationCoordinator,
              let presentation = selectedImportPresentation
        else {
            return nil
        }
        let generation: UInt64
        switch presentation.state {
        case let .ready(_, generationValue, _),
             let .executionUnavailable(_, generationValue):
            generation = generationValue
        default:
            return nil
        }
        return ImportPlanDetailReader(
            coordinator: coordinator,
            sourcePath: presentation.sourcePath,
            generation: generation
        )
    }

    func startMediaOperationsIfNeeded() {
        guard mediaOperationCoordinator == nil else {
            return
        }
        let coordinator = MediaOperationCoordinator(store: catalogStore)
        mediaOperationCoordinator = coordinator
        mediaOperationStartTask = Task { [weak self] in
            await coordinator.start()
            guard let self else {
                return
            }
            let stream = await coordinator.presentationsStream()
            importPresentationTask = Task { [weak self] in
                for await presentations in stream {
                    guard let self else {
                        return
                    }
                    applyImportPresentations(presentations)
                }
            }
        }
    }

    func applyImportPresentations(_ presentations: [MediaOperationSourcePresentation]) {
        importPresentations = presentations
    }

    func setImportDestination(_ destination: LibraryRootPath, for source: LibraryRootPath) {
        guard let coordinator = mediaOperationCoordinator else {
            return
        }
        Task {
            await coordinator.setDestination(destination, for: source)
        }
    }

    func queueImport(for source: LibraryRootPath) {
        guard let coordinator = mediaOperationCoordinator else {
            return
        }
        Task {
            await coordinator.queueImport(for: source)
        }
    }

    func setImportPreferences(_ preferences: ImportPreferences) {
        importPreferences = preferences
        ImportPreferencesStore.save(preferences)
        guard let coordinator = mediaOperationCoordinator else {
            return
        }
        Task {
            await coordinator.preferencesDidChange()
        }
    }

    func readyImportPlan(for source: LibraryRootPath) async -> MediaOperationPlan? {
        await mediaOperationCoordinator?.readyPlan(for: source)
    }

    func toggleImportPlanOverlay() {
        showsImportPlanOverlay.toggle()
    }

    func dismissImportPlanOverlay() {
        showsImportPlanOverlay = false
    }
}
