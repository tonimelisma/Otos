import CoreLocation
import Foundation
import MapKit
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

    /// Rebuilds the Info pane's facts for the current target. With no single item the pane
    /// reads `No Selection` or a count; with one, everything Otos holds for it is read off
    /// the main actor and applied when it still describes the target. Called when the pane is
    /// shown and by every writer of the target.
    func refreshPhotoInfo() {
        photoInfoTask?.cancel()
        placeNameTask?.cancel()
        placeNameTask = nil
        let ids = targetIDs(.current)
        guard showsInfo else {
            photoInfo = nil
            photoInfoTask = nil
            return
        }
        guard ids.count == 1, let id = ids.first else {
            photoInfo = .none(itemCount: ids.count)
            photoInfoTask = nil
            return
        }
        let store = catalogStore
        let reader = tileDetailReader
        let materialization = materializationCoordinator
        let libraryName = sourceName(for: id.libraryRootPath)
        photoInfoTask = Task { [weak self] in
            let read: PhotoInfo
            do {
                read = try await Self.readPhotoInfo(
                    id: id, store: store, reader: reader, materialization: materialization, libraryName: libraryName
                )
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
            photoInfo = read
            photoInfoTask = nil
            OtosLog.ui.debugOperation("photo.info", phase: "applied", fields: [
                "id": id.relativePath.rawValue,
                "located": read.coordinate == nil ? "false" : "true",
            ])
            if let coordinate = read.coordinate {
                lookUpPlaceName(coordinate, for: id)
            }
        }
    }

    /// Everything the pane shows for `id`, from the catalog and the original's locality. The
    /// metadata record and overlay are read whole, so a missing one is a fact (`Unknown`),
    /// and any read that throws fails the whole refresh.
    private nonisolated static func readPhotoInfo(
        id: MediaAssetID,
        store: CatalogStore,
        reader: MediaTileDetailReader,
        materialization: MaterializationCoordinator,
        libraryName: String?
    ) async throws -> PhotoInfo {
        async let asset = store.mediaAssets(for: [id])[id]
        async let metadata = store.metadata(for: id)
        async let overlay = store.photoInfoOverlay(for: id)
        async let detail = reader.detail(for: id)
        async let locality = materialization.locality(of: id)
        let resolvedDetail = try await detail
        return try await PhotoInfo.make(PhotoInfo.Source(
            id: id,
            asset: asset,
            metadata: metadata,
            overlay: overlay,
            kind: resolvedDetail?.bestKind,
            nativePixelSize: resolvedDetail?.nativePixelSize,
            libraryName: libraryName,
            locality: locality
        ))
    }

    /// Looks up the place name for the pane's located item. It names the place in the
    /// Mac's language; a failed or empty lookup leaves the row `Unknown` and is logged.
    private func lookUpPlaceName(_ coordinate: PlaceCoordinate, for id: MediaAssetID) {
        let lookup = placeNameLookup
        placeNameTask = Task { [weak self] in
            let name: String?
            do {
                name = try await lookup.name(coordinate)
            } catch {
                guard !Task.isCancelled else { return }
                OtosLog.ui.errorOperation("photo.info.place", phase: "lookupFailed", fields: [
                    "id": id.relativePath.rawValue,
                    "error": String(describing: error),
                ])
                return
            }
            guard !Task.isCancelled, let self, photoInfo?.id == id, showsInfo else { return }
            OtosLog.ui.debugOperation("photo.info.place", phase: name == nil ? "none" : "named", fields: [
                "id": id.relativePath.rawValue,
            ])
            photoInfo?.placeName = name
            placeNameTask = nil
        }
    }
}

/// How the Info pane names a coordinate. `mapKit` asks Apple Maps; tests substitute their
/// own so no test reaches the network.
nonisolated struct PlaceNameLookup: Sendable {
    let name: @Sendable (PlaceCoordinate) async throws -> String?

    static let mapKit = PlaceNameLookup { coordinate in
        guard let request = MKReverseGeocodingRequest(
            location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        ) else {
            return nil
        }
        let items = try await request.mapItems
        return items.first?.addressRepresentations?.cityWithContext
    }
}
