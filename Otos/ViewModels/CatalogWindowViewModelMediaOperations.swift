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
    /// (`import-bar.md` "Where the user is standing"). A batch row can outlive
    /// its source's session (card ejected or pulled), which is why matching by
    /// `batchID` also has to see `detachedBatchPresentations` on the
    /// coordinator — `applyImportPresentations` already folds those into
    /// `importPresentations`.
    ///
    /// The batch row shows the bar only while there is something the grid
    /// cannot say: the run in flight, or a settled run that was not fully
    /// clean (its `Show them` reveal lives here). A fully clean settle has
    /// nothing left to report on this row — the user is looking at exactly
    /// what they just imported — so the bar leaves the moment it settles, with
    /// no timer and no remembered dismissal (`import-bar.md` state F,
    /// "Dismissal"). The card's own row is unaffected: it keeps `Eject Card`
    /// and Erase for as long as the card is attached, derived from the plan
    /// on every frame.
    var selectedImportPresentation: MediaOperationSourcePresentation? {
        switch sidebarSelection {
        case let .library(path):
            guard state.removableSources.contains(where: { $0.path == path }) else {
                return nil
            }
            return importPresentations.first { $0.sourcePath == path }
        case let .importBatch(batchID):
            guard let presentation = importPresentations.first(where: { $0.batchID == batchID }),
                  presentation.isFullyClean != true
            else {
                return nil
            }
            return presentation
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
        // Live sessions only (`cardStillExists`): a detached snapshot carries
        // the *previous* attachment's batch under the same `sourcePath`, and
        // would otherwise resurrect it over the fresh session's honest `nil`.
        // Assigning the optional straight through is what makes this
        // self-clearing — re-inserting a card starts a session with no batch,
        // which removes the key, so ejecting it again without importing falls
        // back normally instead of following a stale batch.
        for presentation in presentations where presentation.cardStillExists {
            lastBatchBySourcePath[presentation.sourcePath] = presentation.batchID
        }
        followNewBatchesOnce(presentations)
        Task {
            await refreshRemovableDestinations()
        }
    }

    /// Moves the sidebar selection to a batch the first time a presentation
    /// shows it has something in it, and never again for that batch
    /// (`import-bar.md` "Where the user is standing", "Required change").
    /// `batchID` is carried as state rather than an event specifically so this
    /// can't miss a dropped intermediate frame — the check is "have we seen
    /// this ID," not "did we just observe a transition."
    ///
    /// A batch with nothing in it is skipped *and not marked seen*: a run
    /// refused before any copy still pins its batch for state G, but moving
    /// the user to an empty row leaves the sidebar and the grid disagreeing,
    /// and once the next run mints a new batch the footer has nothing to match
    /// and unmounts. Leaving the ID unmarked means the first frame that proves
    /// the batch non-empty still gets the once-only move.
    ///
    /// `.allImports` counts as not having navigated away (J12: "that list is a
    /// navigation surface, not a place to watch work from"); any other
    /// selection — a different library, a different removable source, All
    /// Media — is a real navigation choice and is respected.
    private func followNewBatchesOnce(_ presentations: [MediaOperationSourcePresentation]) {
        for presentation in presentations {
            guard let batchID = presentation.batchID,
                  presentation.batchHasPublishedAssets,
                  !autoSelectedBatchIDs.contains(batchID)
            else {
                continue
            }
            autoSelectedBatchIDs.insert(batchID)
            let hasNotNavigatedAway = sidebarSelection == .library(presentation.sourcePath) || sidebarSelection ==
                .allImports
            if hasNotNavigatedAway {
                selectSidebar(.importBatch(batchID))
            }
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
            "op=reorganization.remapUI phase=applied remapCount=\(batch.remaps.count, privacy: .public) epoch=\(epoch, privacy: .public)"
        )
    }
}
