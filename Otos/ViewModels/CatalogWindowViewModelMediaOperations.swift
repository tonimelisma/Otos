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
        let cameraImport = deviceStagingRegistry.makeCameraImportAccess()
        let store = catalogStore
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferences: preferences,
            cameraImport: cameraImport,
            materializationRequester: materializationCoordinator,
            autoEjectHandler: { root in
                _ = await CatalogWindowViewModel.performCatalogMutation(
                    .ejectRemovableSource(root),
                    store: store,
                    coordinator: nil
                )
            }
        )
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

    func setImportPreferences(_ newPreferences: ImportPreferences) {
        importPreferences = newPreferences
        ImportPreferencesStore.save(newPreferences, defaults: preferences)
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

    // MARK: - Library reorganization (Stage G3)

    private var selectedFixedLibraryPath: LibraryRootPath? {
        guard case let .library(path) = sidebarSelection else {
            return nil
        }
        guard state.libraries.contains(where: { $0.path == path }) else {
            return nil
        }
        return path
    }

    var canRequestReorganization: Bool {
        selectedFixedLibraryPath != nil
    }

    func requestReorganizationConfirmation() {
        guard let path = selectedFixedLibraryPath else {
            return
        }
        let runner = reorganizationRunner ?? LibraryReorganizationRunner(store: catalogStore, preferences: preferences)
        reorganizationRunner = runner
        Task { [weak self] in
            let outcome = await runner.preview(libraryRoot: path)
            guard let self else { return }
            switch outcome {
            case let .needsConfirmation(summary):
                reorganizationSummaryText =
                    "\(summary.relocateCount) relocate · \(summary.noOpCount) no-op · \(summary.blockedCount) blocked · \(summary.componentCount) components"
                showsReorganizationConfirmation = true
            case let .blocked(reason), let .failed(reason):
                reorganizationAlertMessage = reason
            case .completed, .cancelled:
                break
            }
        }
    }

    func cancelReorganizationConfirmation() {
        showsReorganizationConfirmation = false
        reorganizationSummaryText = nil
    }

    func confirmReorganization() {
        guard let path = selectedFixedLibraryPath else {
            return
        }
        showsReorganizationConfirmation = false
        let runner = reorganizationRunner ?? LibraryReorganizationRunner(store: catalogStore, preferences: preferences)
        reorganizationRunner = runner
        Task { [weak self] in
            let outcome = await runner.run(libraryRoot: path)
            guard let self else { return }
            switch outcome {
            case let .completed(batches, _, _):
                for batch in batches {
                    applyIdentityRemapBatch(batch)
                }
            case let .blocked(reason), let .failed(reason):
                reorganizationAlertMessage = reason
            case .cancelled, .needsConfirmation:
                break
            }
        }
    }

    /// Atomically remaps selection, loupe/compare focus, and publishes a batch for
    /// `TileContentStore` via `identityRemapEpoch`.
    func applyIdentityRemapBatch(_ batch: CatalogIdentityRemapBatch) {
        guard !batch.remaps.isEmpty else { return }
        let map = Dictionary(uniqueKeysWithValues: batch.remaps.map { ($0.oldID, $0.newID) })
        gridSelection = gridSelection.remapped(by: batch)
        if let focus = focusedAssetID {
            focusedAssetID = map[focus] ?? focus
        }
        comparePair = comparePair.remapped(by: batch)
        identityRemapBatch = batch
        identityRemapEpoch &+= 1
        let epoch = identityRemapEpoch
        OtosLog.ui.notice(
            // swiftlint:disable:next line_length
            "op=reorganization.remapUI phase=applied remapCount=\(batch.remaps.count, privacy: .public) epoch=\(epoch, privacy: .public)"
        )
    }
}
