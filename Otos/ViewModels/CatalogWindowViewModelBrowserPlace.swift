import Foundation
import OSLog

// Browser place on relaunch (APP-043, ADR 0031)
//
// The ViewModel is the single owner of `BrowserPlace`: `loadBrowserPlace(from:)` runs once
// at the end of init, `persistBrowserPlace()` once at quit, and `restoreBrowserPlaceIfReady()`
// after every state apply until it has restored once or been dropped.
//
// Restore is split in two because the two halves become possible at different times. The
// query is restored at init, so the very first projection already asks for the restored
// scope, filter and sort — there is no flash of the default collection. The scope's
// validity, though, is only known once the catalog has loaded its roots, which is the
// sidebar latch in `applySidebarSelectionPolicy`. Selection, view mode and position need
// the items themselves, so they wait for the first non-empty result of the restored query.

extension CatalogWindowViewModel {
    /// Reads the stored place. `init` adopts its query — `queryDescriptor` is
    /// `private(set)` there — and keeps the rest pending for the restore.
    static func loadBrowserPlace(from preferences: any PreferenceStore) -> BrowserPlace? {
        guard let place = BrowserPlace.load(from: preferences) else {
            OtosLog.ui.notice("op=browserPlace.load result=none")
            return nil
        }
        OtosLog.ui.notice(
            """
            op=browserPlace.load result=restored mode=\(place.viewMode.rawValue, privacy: .public) \
            selection=\(place.selection.count, privacy: .public) focus=\(place.focus != nil, privacy: .public) \
            \(place.descriptor.diagnosticDescription, privacy: .public)
            """
        )
        return place
    }

    /// Saves where the user is now. A place still waiting to be restored is left as
    /// stored: quitting before the catalog loaded must not overwrite the user's real
    /// place with the launch defaults.
    func persistBrowserPlace() {
        guard pendingPlaceRestore == nil else {
            OtosLog.ui.notice("op=browserPlace.save result=skipped reason=restorePending")
            return
        }
        let focus: MediaAssetID? = switch viewMode {
        case .grid: gridViewportCenterID
        case .loupe: focusedAssetID
        case .compare: nil
        }
        let place = BrowserPlace(
            descriptor: queryDescriptor,
            viewMode: viewMode,
            focus: focus,
            selection: GridSelection.orderedSelection(
                gridSelection.selection,
                in: state.mediaGrid.orderedAssetIDs
            )
        )
        place.save(to: preferences)
        OtosLog.ui.notice(
            """
            op=browserPlace.save result=saved mode=\(place.viewMode.rawValue, privacy: .public) \
            selection=\(place.selection.count, privacy: .public) focus=\(place.focus != nil, privacy: .public) \
            \(place.descriptor.diagnosticDescription, privacy: .public)
            """
        )
    }

    /// Brings back selection, view mode and position once the restored query has
    /// produced items. Every stored identity is checked against what is actually in the
    /// result; whatever is gone is dropped rather than guessed at.
    func restoreBrowserPlaceIfReady() {
        guard let place = pendingPlaceRestore,
              hasAppliedInitialDefault,
              state.mediaGrid.descriptor == place.descriptor,
              !state.mediaGrid.orderedAssetIDs.isEmpty
        else {
            return
        }
        pendingPlaceRestore = nil
        let present = Set(state.mediaGrid.orderedAssetIDs)
        let selection = place.selection.filter(present.contains)
        if !selection.isEmpty {
            let selected = Set(selection)
            gridSelection = GridSelection(selection: selected, anchor: selection.first, base: selected)
        }
        let focus = place.focus.flatMap { present.contains($0) ? $0 : nil }
        switch place.viewMode {
        case .grid:
            // The grid centers on the focus target, and the saved focus is the middle of
            // the viewport the user left, so centering on it puts the viewport back.
            if let focus {
                setFocus(focus)
            }
        case .loupe:
            openLoupe(id: focus)
        case .compare:
            enterCompare()
        }
        let restoredMode = viewMode
        OtosLog.ui.notice(
            """
            op=browserPlace.restore phase=applied mode=\(restoredMode.rawValue, privacy: .public) \
            selection=\(selection.count, privacy: .public)/\(place.selection.count, privacy: .public) \
            focus=\(place.focus == nil ? "none" : (focus == nil ? "missing" : "found"), privacy: .public)
            """
        )
    }
}
