import Foundation

/// Sidebar selection policy application guide
///
/// `CatalogWindowViewModel` applies `SidebarSelectionPolicy` when projected sources
/// change. This extension keeps the main ViewModel file within the repo file-length
/// budget while preserving one `setQueryDescriptor` writer for automatic selection.
extension CatalogWindowViewModel {
    func applyAutomaticSidebarSelection(_ selection: SidebarSelection) {
        setQueryDescriptor(CatalogQueryDescriptor(
            scope: selection,
            filter: queryDescriptor.filter,
            sort: queryDescriptor.sort
        ))
    }

    func dismissEjectAlert() {
        ejectAlertMessage = nil
    }

    func applySidebarSelectionPolicy(previous: CatalogWindowState, next: CatalogWindowState) {
        // Compare against previously *available* identities so a remembered card that
        // flips unavailable → available (the common re-insert case) still counts as
        // newly attached and auto-selects.
        let previousAvailableIdentities = Set(
            previous.removableSources.filter(\.isAvailable).compactMap(\.deviceIdentity)
        )
        let newlyAttached = next.removableSources.filter { source in
            guard source.isAvailable, let identity = source.deviceIdentity else {
                return false
            }
            return !previousAvailableIdentities.contains(identity)
        }
        if let attached = newlyAttached.max(by: { left, right in
            (left.lastSeenAt ?? .distantPast) < (right.lastSeenAt ?? .distantPast)
        }), let selection = SidebarSelectionPolicy.selectionOnAttach(attached: attached) {
            applyAutomaticSidebarSelection(selection)
            return
        }

        // Do not latch the initial default on a pre-load empty world (zero roots of
        // both kinds). That state can publish before `store.start()` finishes; latching
        // there would skip the real startup default once libraries/cards appear.
        guard !userHasChosenSource, !hasAppliedInitialDefault,
              !(next.libraries.isEmpty && next.removableSources.isEmpty)
        else {
            return
        }
        hasAppliedInitialDefault = true
        applyAutomaticSidebarSelection(
            SidebarSelectionPolicy.defaultSelection(
                libraries: next.libraries,
                removableSources: next.removableSources
            )
        )
    }

    func handleEjectOutcome(_ outcome: RemovableEjectOutcome, for intent: CatalogMutationIntent) {
        guard case let .ejectRemovableSource(root) = intent,
              let identity = root.deviceIdentity
        else {
            return
        }
        clearEjectingSourceIdentity(identity)
        switch outcome {
        case .ejected, .cancelled:
            return
        case let .busy(displayName):
            ejectAlertMessage =
                "The disk \"\(displayName)\" couldn't be ejected because it's in use."
        case let .failed(description):
            ejectAlertMessage = description
        }
    }

    func currentSelectionWasRemoved(in nextState: CatalogWindowState) -> Bool {
        guard case let .library(path) = queryDescriptor.scope else {
            return false
        }
        return !nextState.libraries.contains { $0.path == path }
            && !nextState.removableSources.contains { $0.path == path }
    }
}
