import AppKit
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
            editSession.endEditing()
        }
        if pane == .edit {
            editSession.refreshEditTarget()
        }
        refreshPhotoInfo()
    }

    // MARK: - Edit session

    /// Text holds the keyboard, as the relay last reported it: what enables Edit ▸ Cut and
    /// Paste. A command itself asks AppKit when it runs (`KeyboardFocus.live`).
    var textHoldsKeyboard: Bool {
        keyboardFocus == .text
    }

    /// Edit ▸ Copy is available: text holds the keyboard, or photos are targeted.
    var canCopy: Bool {
        textHoldsKeyboard || hasMediaChoiceTarget
    }

    /// The key window's first responder changed what holds the keyboard
    /// (`KeyboardFocusRelay`).
    func setKeyboardFocus(_ focus: KeyboardFocus) {
        guard focus != keyboardFocus else { return }
        keyboardFocus = focus
        OtosLog.ui.debugOperation("keyboardFocus", phase: "changed", fields: ["focus": focus.diagnosticName])
    }

    /// Edit ▸ Copy (⌘C): the text that holds the keyboard when the command runs, else the
    /// current targets (`copyCurrentTargets`).
    func copyCommand(focus: KeyboardFocus = .live) {
        OtosLog.ui.noticeOperation("editCommand", phase: "copy", fields: [
            "route": focus.diagnosticName, "targets": "\(targetIDs(.current).count)",
        ])
        switch focus {
        case .text:
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        case .photos:
            copyCurrentTargets()
        }
    }

    /// Edit ▸ Select All (⌘A): the text that holds the keyboard when the command runs, else
    /// every photo shown.
    func selectAllCommand(focus: KeyboardFocus = .live) {
        switch focus {
        case .text:
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        case .photos:
            selectAll()
        }
    }

    /// What `editSession` reads of this window and the intents it calls on it, each this
    /// window's own. Unowned: the window owns the session, so the session never outlives it.
    func makeEditSessionWindow() -> EditSession.Window {
        EditSession.Window(
            currentTargets: { [unowned self] in targetIDs(.current) },
            viewMode: { [unowned self] in viewMode },
            isPlayingStory: { [unowned self] in story != nil },
            focusedAssetID: { [unowned self] in focusedAssetID },
            focusedAssetKind: { [unowned self] in focusedAssetKind },
            loupeVideoState: { [unowned self] in loupeVideoState },
            showsSelectedScope: { [unowned self] in showsSelectedScope },
            isEditPanelPresented: { [unowned self] in isEditPanelPresented },
            panePreview: { [unowned self] slot in panePreviews[slot] },
            expectedAsset: { [unowned self] slot in expectedAsset(for: slot) },
            setInspectorPane: { [unowned self] pane in setInspectorPane(pane) },
            setViewMode: { [unowned self] mode in setViewMode(mode) },
            updateLoupeVideoState: { [unowned self] change in updateLoupeVideoState(change) },
            requestPanePreview: { [unowned self] id, slot in requestPanePreview(id, slot: slot) },
            forgetFullResolutionRequest: { [unowned self] id in forgetFullResolutionRequest(for: id) },
            publishUndoState: { [unowned self] in publishUndoState() },
            revealUndoneChange: { [unowned self] ids in revealUndoneChange(ids) }
        )
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
        let rootNames = Dictionary(
            (parts.libraries + parts.removableSources).map { ($0.path, $0.displayName) }
        ) { first, _ in first }
        let labelNames = sceneLabelNames
        let availability = descriptionAvailability
        photoInfoTask = Task { [weak self] in
            let read: PhotoInfo
            do {
                read = try await Self.readPhotoInfo(
                    id: id, store: store, reader: reader, materialization: materialization, libraryName: libraryName,
                    rootNames: rootNames, labelNames: labelNames, descriptionAvailability: availability()
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
            photoInfo = read.withStack(parts.gridStacks.stack(shownBy: id))
            photoInfoTask = nil
            // This read's In This Photo and Description may predate a reading announced while
            // it ran, when the refresh still re-read the item shown before; one more re-read
            // covers it.
            readingsDoorbell?.yield()
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
        rootNames: [LibraryRootPath: String],
        labelNames: SceneLabelNames,
        descriptionAvailability: PhotoDescriptionAvailability
    ) async throws -> PhotoInfo {
        async let asset = store.windowReads.mediaAssets(for: [id])[id]
        async let metadata = store.windowReads.metadata(for: id)
        async let overlay = store.windowReads.photoInfoOverlay(for: id)
        async let detail = reader.detail(for: id)
        async let locality = materialization.locality(of: id)
        async let recipe = store.windowReads.editRecipe(for: id)
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
            rootNames: rootNames,
            locality: locality,
            editRecipe: recipe?.recipe,
            labelNames: names,
            descriptionAvailability: descriptionAvailability
        ))
    }

    /// A photo's scene labels named in the Mac's language (`Locale.current`, as place names
    /// are, ADR 0051), each name once; nil while the reading is owed.
    private nonisolated static func name(_ labels: [SceneLabel]?, labelNames: SceneLabelNames) async throws -> [PhotoInfo.Recognized.Label]? {
        guard let labels else { return nil }
        return try await labelNames.labels(of: labels, in: Locale.current.language)
    }

    /// The item the Info pane's readings describe, while the pane shows one.
    private var readingsTarget: MediaAssetID? {
        showsInfo ? photoInfo?.id : nil
    }

    /// Keeps In This Photo, Description and the File section's `Original` current while they
    /// change: each ring re-reads the shown item's labels, text, description and where its
    /// original is, and applies them if it is still the one shown. Only those are re-read, so
    /// the place lookup is not restarted.
    ///
    /// One loop, woken by a newest-wins doorbell that four sources ring: search's index each
    /// time it announces new readings, the description writer each time it writes, the
    /// download coordinator each time an original it fetched lands, and each Info read as it
    /// lands. The last closes the one order the others cannot: a reading
    /// announced while an Info read is in flight is re-read for the item shown then, and the
    /// Info read lands afterwards with what it read before the reading. A ring during a re-read
    /// is kept, so the last write to the sections is always followed by a fresh read. The loop
    /// holds the view model weakly across each wait and ends with it; the announcers' streams
    /// are forwarded by children of the same task, so teardown ends them all. A failed read is
    /// logged and changes nothing (ADR 0032 rule 4).
    func startReadingsRefresh() {
        let (rings, doorbell) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        readingsDoorbell = doorbell
        let index = photoSearchIndex
        let writer = photoDescriptionWriter
        let store = catalogStore
        let labelNames = sceneLabelNames
        let availability = descriptionAvailability
        let materialization = materializationCoordinator
        readingsRefreshTask = Task { [weak self] in
            await withDiscardingTaskGroup { group in
                if let index {
                    group.addTask {
                        for await _ in await index.changes() {
                            doorbell.yield()
                        }
                    }
                }
                if let writer {
                    group.addTask {
                        for await _ in await writer.changes() {
                            doorbell.yield()
                        }
                    }
                }
                group.addTask {
                    for await _ in await materialization.landings() {
                        doorbell.yield()
                    }
                }
                for await _ in rings {
                    guard let id = self?.readingsTarget else {
                        if self == nil {
                            break
                        }
                        continue
                    }
                    // Where the original is: a download Otos ran may have made it local.
                    let locality = await materialization.locality(of: id)
                    if let self, self.readingsTarget == id, self.photoInfo?.locality != locality {
                        self.photoInfo?.update(locality: locality)
                        OtosLog.ui.debugOperation("photo.info.locality", phase: "applied", fields: [
                            "id": id.relativePath.rawValue,
                            "locality": "\(locality)",
                        ])
                    }
                    let readsText = self?.photoInfo?.recognized?.readsText ?? true
                    let describes = self?.photoInfo?.photoDescription != nil
                    let recognized: PhotoInfo.Recognized
                    let description: PhotoInfo.Description?
                    do {
                        let overlay = try await store.windowReads.photoInfoOverlay(for: id)
                        recognized = try await PhotoInfo.Recognized(
                            overlay: overlay, labels: Self.name(overlay?.sceneLabels, labelNames: labelNames), readsText: readsText
                        )
                        description = describes ? PhotoInfo.Description(overlay?.photoDescription, availability: availability()) : nil
                    } catch {
                        OtosLog.ui.errorOperation("photo.info.readings", phase: "readFailed", fields: [
                            "id": id.relativePath.rawValue,
                            "error": String(describing: error),
                        ])
                        continue
                    }
                    guard !Task.isCancelled, let self else {
                        break
                    }
                    guard self.readingsTarget == id,
                          self.photoInfo?.recognized != recognized || self.photoInfo?.photoDescription != description
                    else {
                        continue
                    }
                    self.photoInfo?.recognized = recognized
                    self.photoInfo?.photoDescription = description
                    OtosLog.ui.debugOperation("photo.info.readings", phase: "applied", fields: [
                        "id": id.relativePath.rawValue,
                        "labels": recognized.labels.map { "\($0.count)" } ?? "owed",
                        "lines": recognized.text.diagnosticCount,
                        "description": description?.diagnosticState ?? "none",
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
