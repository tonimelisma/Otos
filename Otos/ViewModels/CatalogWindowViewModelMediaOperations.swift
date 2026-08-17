import Foundation
import Observation
import OSLog

/// Media-operation intents and presentation owned by the catalog window ViewModel.
///
/// The coordinator actor owns plan lifecycle; this MainActor bridge only assigns
/// SwiftUI-visible presentation, destination intents, and queued Import starts.
extension CatalogWindowViewModel {
    /// The bar is reachable from two sidebar rows once execution starts — the
    /// removable row and the batch row — both views onto the same operation
    /// (`import-bar.md` "Where the user is standing", state F: "Both the
    /// removable row and the import batch row are views onto the same
    /// operation, so both show the same bar"). A batch row can outlive its
    /// source's session (card ejected or pulled), which is why matching by
    /// `batchID` also has to see `detachedBatchPresentations` on the
    /// coordinator — `applyImportPresentations` already folds those into
    /// `importPresentations`.
    var selectedImportPresentation: MediaOperationSourcePresentation? {
        switch sidebarSelection {
        case let .library(path):
            guard state.removableSources.contains(where: { $0.path == path }) else {
                return nil
            }
            return importPresentations.first { $0.sourcePath == path }
        case let .importBatch(batchID):
            return importPresentations.first { $0.batchID == batchID }
        default:
            return nil
        }
    }

    // ImportPlanDetailReader and the Details sheet are deleted (ADR 0021): the
    // grid is the plan view and the footer shows the status (ARC-047).

    func startMediaOperationsIfNeeded() {
        guard mediaOperationCoordinator == nil else {
            return
        }
        let cameraImport = deviceStagingRegistry.makeCameraImportAccess()
        let store = catalogStore
        let coordinator = MediaOperationCoordinator(
            store: store,
            preferencesDomain: preferencesDomain,
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
        if !cancellingImportSources.isEmpty {
            let stillExecuting = Set(presentations.compactMap { presentation -> LibraryRootPath? in
                guard case .executing = presentation.state else { return nil }
                return presentation.sourcePath
            })
            cancellingImportSources.formIntersection(stillExecuting)
        }
        Task {
            await refreshRemovableDestinations()
            await refreshSessionPreferences()
        }
    }

    func refreshSessionPreferences() async {
        guard let coordinator = mediaOperationCoordinator else {
            return
        }
        var cache: [LibraryRootPath: ImportPreferences] = [:]
        for presentation in importPresentations {
            let prefs = await coordinator.sessionPreferences(for: presentation.sourcePath)
            cache[presentation.sourcePath] = prefs
        }
        await MainActor.run {
            sessionPreferencesBySource = cache
        }
    }

    func sessionPreferences(for source: LibraryRootPath) -> ImportPreferences {
        sessionPreferencesBySource[source] ?? importPreferences
    }

    func setSessionPreferences(_ prefs: ImportPreferences, for source: LibraryRootPath) {
        sessionPreferencesBySource[source] = prefs
        guard let coordinator = mediaOperationCoordinator else {
            return
        }
        Task {
            await coordinator.setSessionPreferences(prefs, for: source)
        }
    }

    func refreshRemovableDestinations() async {
        guard let coordinator = mediaOperationCoordinator else {
            return
        }
        let all = await coordinator.allDestinations()
        await MainActor.run {
            removableDestinations = all
        }
    }

    func setImportDestination(_ destination: LibraryRootPath, for source: LibraryRootPath) {
        guard let coordinator = mediaOperationCoordinator else {
            return
        }
        Task { [weak self] in
            await coordinator.setDestination(destination, for: source)
            await self?.refreshRemovableDestinations()
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

    func cancelImport(for source: LibraryRootPath) {
        guard let coordinator = mediaOperationCoordinator else {
            return
        }
        cancellingImportSources.insert(source)
        Task {
            await coordinator.cancelImport(for: source)
        }
    }

    func retryImportPlanning(for source: LibraryRootPath) {
        guard let coordinator = mediaOperationCoordinator else {
            return
        }
        Task {
            await coordinator.retryPlanning(for: source)
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

    // MARK: - Library reorganization (ARC-051)

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
        let runner = reorganizationRunner ?? LibraryReorganizationRunner(
            store: catalogStore,
            preferencesDomain: preferencesDomain
        )
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
        let runner = reorganizationRunner ?? LibraryReorganizationRunner(
            store: catalogStore,
            preferencesDomain: preferencesDomain
        )
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
            let mapped = map[focus] ?? focus
            if mapped != focus {
                setFocus(mapped)
            }
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
