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
        let previousIdentities = Set(previous.removableSources.compactMap(\.deviceIdentity))
        let newlyAttached = next.removableSources.filter { source in
            guard source.isAvailable, let identity = source.deviceIdentity else {
                return false
            }
            return !previousIdentities.contains(identity)
        }
        if let attached = newlyAttached.max(by: { left, right in
            (left.lastSeenAt ?? .distantPast) < (right.lastSeenAt ?? .distantPast)
        }), let selection = SidebarSelectionPolicy.selectionOnAttach(attached: attached) {
            applyAutomaticSidebarSelection(selection)
            return
        }

        guard !userHasChosenSource, !hasAppliedInitialDefault else {
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
        case .ejected:
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
