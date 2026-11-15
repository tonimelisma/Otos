import Foundation
import Observation
import OSLog

/// A user action aimed at the import coordinator. Every case travels through the view
/// model's one lossless stream, so the coordinator sees the user's actions in the order the
/// user made them.
nonisolated enum ImportIntent: Sendable {
    case setDestination(LibraryRootPath, source: LibraryRootPath)
    case setSessionPreferences(ImportPreferences, source: LibraryRootPath)
    case queueImport(source: LibraryRootPath)
    case cancelImport(source: LibraryRootPath)
    case retryPlanning(source: LibraryRootPath)
    case preferencesDidChange
}

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
            volumeCapacity: volumeCapacity,
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
        startImportIntentConsumer(coordinator: coordinator)
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
            let destinations = await coordinator.destinationsStream()
            removableDestinationsTask = Task { [weak self] in
                for await map in destinations {
                    guard let self else {
                        return
                    }
                    removableDestinations = map
                }
            }
        }
    }

    /// The one consumer of import intents. It delivers them to the coordinator strictly in
    /// submission order and holds the view model weakly across each wait, ending when the
    /// stream ends or the view model is gone.
    func startImportIntentConsumer(coordinator: MediaOperationCoordinator) {
        importIntentTask?.cancel()
        let intents = importIntentStream
        importIntentTask = Task { [weak self, coordinator] in
            for await intent in intents {
                guard let self else {
                    return
                }
                await deliver(intent, to: coordinator)
            }
        }
    }

    private func deliver(_ intent: ImportIntent, to coordinator: MediaOperationCoordinator) async {
        switch intent {
        case let .setDestination(destination, source):
            await coordinator.setDestination(destination, for: source)
        case let .setSessionPreferences(prefs, source):
            await coordinator.setSessionPreferences(prefs, for: source)
        case let .queueImport(source):
            // Returns when the intent is applied, not when the run ends: the next intent
            // (Cancel, above all) must not wait behind a copy.
            await coordinator.submitImport(for: source)
        case let .cancelImport(source):
            await coordinator.cancelImport(for: source)
        case let .retryPlanning(source):
            await coordinator.retryPlanning(for: source)
        case .preferencesDidChange:
            await coordinator.preferencesDidChange()
        }
    }

    private func submitImportIntent(_ intent: ImportIntent) {
        switch importIntentContinuation.yield(intent) {
        case .enqueued:
            return
        case .dropped:
            // The stream is unbounded, so dropping means its lossless contract broke.
            assertionFailure("Unbounded import intent stream dropped an intent")
            OtosLog.ui.error("Import intent was unexpectedly dropped")
        case .terminated:
            assertionFailure("Import intent submitted after stream termination")
            OtosLog.ui.error("Import intent submitted after termination")
        @unknown default:
            assertionFailure("Unknown import intent stream yield result")
            OtosLog.ui.error("Import intent returned an unknown yield result")
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
        for presentation in presentations {
            if let batchID = presentation.batchID,
               case .executing = presentation.state,
               !followedImportBatches.contains(batchID)
            {
                importBatchesAwaitingTheirRow[batchID] = presentation.sourcePath
            }
        }
        followRunsIntoTheirBatches()
        if !cancellingImportSources.isEmpty {
            let stillExecuting = Set(presentations.compactMap { presentation -> LibraryRootPath? in
                guard case .executing = presentation.state else { return nil }
                return presentation.sourcePath
            })
            cancellingImportSources.formIntersection(stillExecuting)
        }
    }

    /// Moves the user from a card's own row to the batch its run copied into, once, the
    /// first time the sidebar draws that batch's row: selecting a row the sidebar does not
    /// draw yet highlights nothing and leaves the card's photos on screen without the bar.
    /// Called on every presentation and every applied window state, since either can be the
    /// one that completes the pair. A user who is anywhere else when the row first appears
    /// stays there, and one who returns to the card afterwards is not pulled back — the
    /// card's row keeps the bar, Cancel and Eject. Same path as a sidebar click
    /// (`selectSidebar`).
    func followRunsIntoTheirBatches() {
        for (batchID, sourcePath) in importBatchesAwaitingTheirRow
            where state.importBatches.contains(where: { $0.batchID == batchID })
        {
            importBatchesAwaitingTheirRow[batchID] = nil
            guard followedImportBatches.insert(batchID).inserted,
                  sidebarSelection == .library(sourcePath)
            else {
                continue
            }
            OtosLog.ui.noticeOperation("import.follow", phase: "select", fields: [
                "batch": "\(batchID.unixMilliseconds)",
                "sourcePath": sourcePath.rawValue,
            ])
            selectSidebar(.importBatch(batchID))
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
        guard mediaOperationCoordinator != nil else {
            return
        }
        // Command: every toggle is the user's latest word and must apply in order.
        submitImportIntent(.setSessionPreferences(prefs, source: source))
    }

    func setImportDestination(_ destination: LibraryRootPath, for source: LibraryRootPath) {
        guard mediaOperationCoordinator != nil else {
            return
        }
        // Command: ordered before a following Import, which must run into this destination.
        submitImportIntent(.setDestination(destination, source: source))
    }

    func queueImport(for source: LibraryRootPath) {
        guard mediaOperationCoordinator != nil else {
            return
        }
        // Command: ordered after any destination or preference change made before it.
        submitImportIntent(.queueImport(source: source))
    }

    func cancelImport(for source: LibraryRootPath) {
        guard mediaOperationCoordinator != nil else {
            return
        }
        cancellingImportSources.insert(source)
        // Command: delivered in order, and never held behind the run it cancels.
        submitImportIntent(.cancelImport(source: source))
    }

    func retryImportPlanning(for source: LibraryRootPath) {
        guard mediaOperationCoordinator != nil else {
            return
        }
        // Command: `Try Again` is a user act, not a state, so none may be dropped.
        submitImportIntent(.retryPlanning(source: source))
    }

    func setImportPreferences(_ newPreferences: ImportPreferences) {
        importPreferences = newPreferences
        ImportPreferencesStore.save(newPreferences, defaults: preferences)
        guard mediaOperationCoordinator != nil else {
            return
        }
        // Command: ordered with the other import intents.
        submitImportIntent(.preferencesDidChange)
    }

    // MARK: - Library reorganization (ARC-051)

    private var selectedFixedLibraryPath: LibraryRootPath? {
        guard case let .library(path) = sidebarSelection else {
            return nil
        }
        guard state.libraries.contains(where: { $0.path == path && $0.kind.supportsReorganization }) else {
            return nil
        }
        return path
    }

    var canRequestReorganization: Bool {
        selectedFixedLibraryPath != nil
    }

    func requestReorganizationConfirmation() {
        guard let path = selectedFixedLibraryPath, reorganizationTask == nil else {
            return
        }
        let runner = reorganizationRunner()
        // One preview or run in flight, owned here: a second request while one runs is
        // ignored, and the window's teardown cancels it.
        reorganizationTask = Task { [weak self] in
            let outcome = await runner.preview(libraryRoot: path)
            guard let self else { return }
            reorganizationTask = nil
            presentReorganizationOutcome(outcome)
        }
    }

    func cancelReorganizationConfirmation() {
        reorganizationConfirmation = nil
    }

    /// Runs the plan the dialog showed: its library and its revision, whatever the
    /// sidebar selects now. If the library changed since, the run reports the new plan
    /// and the dialog asks again.
    func confirmReorganization() {
        guard let confirmation = reorganizationConfirmation, reorganizationTask == nil else {
            return
        }
        reorganizationConfirmation = nil
        let runner = reorganizationRunner()
        reorganizationTask = Task { [weak self] in
            let outcome = await runner.run(
                libraryRoot: confirmation.libraryRoot,
                confirmedRevision: confirmation.rootRevision
            )
            guard let self else { return }
            reorganizationTask = nil
            presentReorganizationOutcome(outcome)
        }
    }

    private func reorganizationRunner() -> LibraryReorganizationRunner {
        if let runner = reorganizationRunnerInstance {
            return runner
        }
        let runner = LibraryReorganizationRunner(store: catalogStore, preferencesDomain: preferencesDomain)
        reorganizationRunnerInstance = runner
        return runner
    }

    private func presentReorganizationOutcome(_ outcome: LibraryReorganizationRunner.Outcome) {
        OtosLog.ui.noticeOperation("reorganization.outcome", phase: "presented", fields: [
            "outcome": String(describing: outcome),
        ])
        switch outcome {
        case let .needsConfirmation(summary):
            reorganizationConfirmation = ReorganizationConfirmation(summary: summary)
        case .completed:
            break
        case let .unavailable(reason):
            reorganizationAlertMessage = ReorganizationOutcomePresentation.message(for: reason)
        case let .stopped(stop):
            reorganizationAlertMessage = ReorganizationOutcomePresentation.message(for: stop)
        }
    }

    /// Carries selection, compare pair, focus and painted tiles across every batch this
    /// window has not applied yet, then asks the Store to drop them. Runs inside
    /// `applyState`, before the new order is compared with the old one, so a remapped
    /// identity is never pruned or shown without its thumbnail (ARC-052, APP-015).
    func applyPendingIdentityRemaps(_ batches: [CatalogIdentityRemapBatch]) {
        let unapplied = batches.filter { !appliedIdentityRemapBatchIDs.contains($0.id) }
        guard !unapplied.isEmpty else { return }
        var focusChanged = false
        for batch in unapplied {
            appliedIdentityRemapBatchIDs.insert(batch.id)
            guard !batch.remaps.isEmpty else { continue }
            let map = Dictionary(uniqueKeysWithValues: batch.remaps.map { ($0.oldID, $0.newID) })
            gridSelection = gridSelection.remapped(by: batch)
            comparePair = comparePair.remapped(by: batch)
            tileContentStore.applyIdentityRemapBatch(batch)
            if let focus = focusedAssetID, let mapped = map[focus], mapped != focus {
                // `setFocus` re-requests every pane under the new identity.
                setFocus(mapped)
                focusChanged = true
            }
            OtosLog.ui.noticeOperation("reorganization.remapUI", phase: "applied", fields: [
                "batch": "\(batch.id)",
                "remapCount": "\(batch.remaps.count)",
            ])
        }
        if !focusChanged {
            // A compare pair can move while focus does not.
            refreshPanePreviews()
        }
        submitCatalogMutation(.acknowledgeIdentityRemaps(unapplied.map(\.id)))
    }
}
