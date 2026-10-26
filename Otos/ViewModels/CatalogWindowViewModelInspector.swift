import Foundation
import OSLog

/// Which pane the trailing inspector shows: the photo's Info or its Edit controls.
nonisolated enum InspectorPane: String, Sendable {
    case info
    case edit
}

/// Inspector guide
///
/// The trailing inspector is one column with two panes, as Lightroom's right panel is:
/// Info (APP-041) and Edit (ADR 0036). `inspectorPane` is the one owner — nil while the
/// column is hidden. View ▸ Show Info (I) and Show Edit (E), and the toolbar's Info and
/// Edit toggles, each show their pane, switch the column to it, or hide the column when
/// their pane is the one shown (DES-097).
///
/// Leaving the Edit pane lets go of the photo it edits, as hiding the column does. Info
/// describes the current target — the grid's single selection, the loupe's photo, the
/// active Compare pane — in every mode, refreshed by every writer of the target.
extension CatalogWindowViewModel {
    var isEditPanelPresented: Bool {
        inspectorPane == .edit
    }

    var showsInfo: Bool {
        inspectorPane == .info
    }

    /// View ▸ Show Info / Hide Info (I), Show Edit / Hide Edit (E) and the toolbar's toggles.
    func toggleInspector(_ pane: InspectorPane) {
        setInspectorPane(inspectorPane == pane ? nil : pane)
    }

    /// The one path that changes the inspector: ends what the pane leaving held and
    /// resolves what the pane arriving shows.
    func setInspectorPane(_ pane: InspectorPane?) {
        guard pane != inspectorPane else { return }
        let previous = inspectorPane
        inspectorPane = pane
        OtosLog.ui.noticeOperation("inspector", phase: pane.map(\.rawValue) ?? "hidden", fields: [
            "previous": previous.map(\.rawValue) ?? "hidden",
        ])
        if previous == .edit {
            endEditing()
        }
        if pane == .edit {
            refreshEditTarget()
        }
        refreshPhotoInfo()
    }

    /// Rebuilds the Info pane's facts for the current target when it is exactly one item.
    /// Called when the pane is shown and by every writer of the target.
    func refreshPhotoInfo() {
        photoInfoTask?.cancel()
        let ids = targetIDs(.current)
        guard showsInfo, ids.count == 1, let id = ids.first else {
            photoInfo = nil
            photoInfoTask = nil
            return
        }
        let store = catalogStore
        let reader = tileDetailReader
        photoInfoTask = Task { [weak self] in
            let asset: MediaAsset?
            let detail: MediaTileDetail?
            do {
                asset = try await store.mediaAssets(for: [id])[id]
                detail = try await reader.detail(for: id)
            } catch {
                guard !Task.isCancelled, let self, targetIDs(.current) == [id], showsInfo else { return }
                // A failed read is not an asset without facts: nothing reads `Unknown` for
                // it. The pane keeps what it showed for this asset, drops another asset's,
                // and the next refresh reads again.
                OtosLog.ui.errorOperation("photo.info", phase: "readFailed", fields: [
                    "id": id.relativePath.rawValue,
                    "error": String(describing: error),
                ])
                if photoInfo?.id != id {
                    photoInfo = nil
                }
                photoInfoTask = nil
                return
            }
            guard !Task.isCancelled, let self, targetIDs(.current) == [id], showsInfo else { return }
            photoInfo = PhotoInfo.make(
                id: id,
                asset: asset,
                kind: detail?.bestKind,
                nativePixelSize: detail?.nativePixelSize
            )
            photoInfoTask = nil
        }
    }
}
