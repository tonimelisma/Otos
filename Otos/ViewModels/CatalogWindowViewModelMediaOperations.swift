import Foundation
import Observation
import OSLog

/// Media-operation intents and presentation owned by the catalog window ViewModel.
///
/// The coordinator actor owns plan lifecycle; this MainActor bridge only assigns
/// SwiftUI-visible presentation, destination intents, and queued Import starts.
extension CatalogWindowViewModel {
    /// The bar is drawn only while a removable source's own row is selected
    /// (`import-bar.md` "Where the user is standing"). An import batch row
    /// shows that batch and nothing else, whatever state its run is in: the
    /// grid is the report there. The card's row keeps the bar — `Eject Card`,
    /// Erase, a Stopped run's remainder — for as long as the card is attached,
    /// derived from the plan on every frame.
    var selectedImportPresentation: MediaOperationSourcePresentation? {
        guard case let .library(path) = sidebarSelection,
              state.removableSources.contains(where: { $0.path == path })
        else {
            return nil
        }
        return importPresentations.first { $0.sourcePath == path }
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
            // One eject, one path: the same intent the sidebar's eject control
            // fires — quiesce, drain Otos's own readers, unmount with a bounded
            // busy retry, and the alert if it still can't (APP-008). On
            // 2026-09-13 this handler skipped the drain and dropped the outcome,
            // so a ticked "Eject the card" failed `fBsyErr` and told no one.
            autoEjectHandler: { [weak self] root in
                await MainActor.run { self?.ejectRemovableSource(root) }
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

    /// Applies drawn state, and logs what was actually drawn when it changes.
    ///
    /// The log recorded `drawnKind` alone. Both Preparing frames draw kind `.preparing`, so
    /// the number the user was looking at — and whether the track was determinate — never
    /// reached the log at all. When the count blanked for a fraction of every second, the
    /// evidence for it existed only on screen. Recording the drawn line and track is what
    /// makes that diagnosable without a camera attached.
    ///
    /// On change rather than on a 250 ms timer, for the same reason as `publish()`: a state
    /// that alternates faster than the timer is invisible to it.
    func applyImportPresentations(_ presentations: [MediaOperationSourcePresentation]) {
        for presentation in presentations {
            let drawn = ImportBarPresentation.map(
                presentation: presentation,
                preferences: presentation.sessionPreferences,
                sourceDisplayName: presentation.sourcePath.displayName
            )
            let track = if case let .progress(trackValue, _) = drawn.middleZone {
                switch trackValue {
                case .indeterminate: "indeterminate"
                case let .determinate(completed, total): "determinate:\(completed)/\(total)"
                }
            } else {
                "none"
            }
            let secondary: String = if case let .plain(text) = drawn.secondaryLine {
                text
            } else {
                String(describing: drawn.secondaryLine)
            }
            let signature = "\(drawn.kind)|\(secondary)|\(track)|\(drawn.primaryAction)|\(drawn.primaryEnabled)"
            guard lastDrawnSignature[presentation.sourcePath] != signature else { continue }
            lastDrawnSignature[presentation.sourcePath] = signature
            OtosLog.catalog.noticeOperation("import.presentation", phase: "apply", fields: [
                "sourcePath": presentation.sourcePath.rawValue,
                "drawnKind": String(describing: drawn.kind),
                "secondaryLine": secondary,
                "track": track,
                "primaryAction": String(describing: drawn.primaryAction),
                "primaryEnabled": "\(drawn.primaryEnabled)",
            ])
        }
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
        }
    }

    /// Reads straight off the live presentation — the coordinator's own
    /// `SourceSession.preferences` — rather than a second ViewModel-owned
    /// dictionary kept in sync by a per-frame refresh.
    func sessionPreferences(for source: LibraryRootPath) -> ImportPreferences {
        importPresentations.first { $0.sourcePath == source }?.sessionPreferences ?? importPreferences
    }

    /// Writes only to the coordinator; the next `publish()` carrying the new
    /// value on `sessionPreferences` is the confirmation. No optimistic local
    /// write — that double-write is exactly what let a per-frame refresh
    /// revert an in-flight toggle.
    func setSessionPreferences(_ prefs: ImportPreferences, for source: LibraryRootPath) {
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
                reorganizationSummaryText = ReorganizationSummaryPresentation.string(for: summary)
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
        comparePair = comparePair.remapped(by: batch)
        // A pane holding a decode under the old identity must be re-requested under the
        // new one: `setFocus` reconciles every slot, and a plain reconcile covers a
        // compare pair that moved while focus did not.
        if let focus = focusedAssetID, let mapped = map[focus], mapped != focus {
            setFocus(mapped)
        } else {
            refreshPanePreviews()
        }
        identityRemapBatch = batch
        identityRemapEpoch &+= 1
        let epoch = identityRemapEpoch
        OtosLog.ui.notice(
            "op=reorganization.remapUI phase=applied remapCount=\(batch.remaps.count, privacy: .public) epoch=\(epoch, privacy: .public)"
        )
    }
}
