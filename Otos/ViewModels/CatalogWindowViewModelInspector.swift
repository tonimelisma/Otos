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
        refreshTargetFaces()
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
        let labelNames = sceneLabelNames
        photoInfoTask = Task { [weak self] in
            let read: PhotoInfo
            do {
                read = try await Self.readPhotoInfo(
                    id: id, store: store, reader: reader, materialization: materialization, libraryName: libraryName,
                    labelNames: labelNames
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
            photoInfo = read.withStack(state.mediaGrid.stacks.stack(shownBy: id))
            photoInfoTask = nil
            // This read's In This Photo may predate a reading search announced while it ran,
            // when the refresh still re-read the item shown before; one more re-read covers it.
            recognizedDoorbell?.yield()
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
    /// and any read that throws fails the whole refresh. The overlay's scene labels are named
    /// in the Mac's language (`Locale.current`, as place names are, ADR 0051).
    private nonisolated static func readPhotoInfo(
        id: MediaAssetID,
        store: CatalogStore,
        reader: MediaTileDetailReader,
        materialization: MaterializationCoordinator,
        libraryName: String?,
        labelNames: SceneLabelNames
    ) async throws -> PhotoInfo {
        async let asset = store.mediaAssets(for: [id])[id]
        async let metadata = store.metadata(for: id)
        async let overlay = store.photoInfoOverlay(for: id)
        async let detail = reader.detail(for: id)
        async let locality = materialization.locality(of: id)
        async let recipe = store.editRecipe(for: id)
        let resolvedDetail = try await detail
        let resolvedOverlay = try await overlay
        let names = try await name(resolvedOverlay?.sceneLabels, labelNames: labelNames)
        return try await PhotoInfo.make(PhotoInfo.Source(
            id: id,
            asset: asset,
            metadata: metadata,
            overlay: resolvedOverlay,
            kind: resolvedDetail?.bestKind,
            nativePixelSize: resolvedDetail?.nativePixelSize,
            libraryName: libraryName,
            locality: locality,
            editRecipe: recipe?.recipe,
            labelNames: names
        ))
    }

    /// A photo's scene labels named in the Mac's language (`Locale.current`, as place names
    /// are, ADR 0051), each name once; nil while the reading is owed.
    private nonisolated static func name(_ labels: [String]?, labelNames: SceneLabelNames) async throws -> [PhotoInfo.Recognized.Label]? {
        guard let labels else { return nil }
        return try await labelNames.labels(of: labels, in: Locale.current.language)
    }

    /// The item In This Photo describes, while the Info pane shows one.
    private var recognizedTarget: MediaAssetID? {
        showsInfo ? photoInfo?.id : nil
    }

    /// Keeps In This Photo current while search reads: each ring re-reads the shown item's
    /// labels and text and applies them if it is still the one shown. Only that section is
    /// re-read, so the place lookup is not restarted.
    ///
    /// One loop, woken by a newest-wins doorbell that two sources ring: search's index each time
    /// it announces new readings, and each Info read as it lands. The second closes the one
    /// order the first cannot: a reading announced while an Info read is in flight is re-read
    /// for the item shown then, and the Info read lands afterwards with what it read before the
    /// reading. A ring during a re-read is kept, so the last write to the section is always
    /// followed by a fresh read. The loop holds the view model weakly across each wait and ends
    /// with it; the index's stream is forwarded by a child of the same task, so teardown ends
    /// both. A failed read is logged and changes nothing (ADR 0032 rule 4).
    func startRecognizedRefresh() {
        let (rings, doorbell) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        recognizedDoorbell = doorbell
        let index = photoSearchIndex
        let store = catalogStore
        let labelNames = sceneLabelNames
        recognizedRefreshTask = Task { [weak self] in
            await withDiscardingTaskGroup { group in
                if let index {
                    group.addTask {
                        for await _ in await index.changes() {
                            doorbell.yield()
                        }
                    }
                }
                for await _ in rings {
                    guard let id = self?.recognizedTarget else {
                        if self == nil {
                            break
                        }
                        continue
                    }
                    let readsText = self?.photoInfo?.recognized?.readsText ?? true
                    let recognized: PhotoInfo.Recognized
                    do {
                        let overlay = try await store.photoInfoOverlay(for: id)
                        recognized = try await PhotoInfo.Recognized(
                            overlay: overlay, labels: Self.name(overlay?.sceneLabels, labelNames: labelNames), readsText: readsText
                        )
                    } catch {
                        OtosLog.ui.errorOperation("photo.info.recognized", phase: "readFailed", fields: [
                            "id": id.relativePath.rawValue,
                            "error": String(describing: error),
                        ])
                        continue
                    }
                    guard !Task.isCancelled, let self else {
                        break
                    }
                    guard self.recognizedTarget == id, self.photoInfo?.recognized != recognized else {
                        continue
                    }
                    self.photoInfo?.recognized = recognized
                    OtosLog.ui.debugOperation("photo.info.recognized", phase: "applied", fields: [
                        "id": id.relativePath.rawValue,
                        "labels": recognized.labels.map { "\($0.count)" } ?? "owed",
                        "lines": recognized.text.diagnosticCount,
                    ])
                }
                group.cancelAll()
            }
        }
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
