//
//  ContentView.swift
//  Otos
//
//  Created by Taylor on 6/2/26.
//

import SwiftUI

/// ContentView composes already-projected state and is deliberately passive: it
/// renders the view model's state and forwards intents, but never subscribes to catalog
/// notifications, sorts, or derives catalog state in `body`. Why: a SwiftUI `body`
/// can run many times per second, so doing real work there — or re-deriving catalog
/// state — would be both slow and a second source of truth that could drift from
/// the model. The model decides; the view renders.
///
/// It reads no part of the window state itself. Each column — `SidebarColumn`,
/// `DetailColumn`, `InspectorColumn` and `CatalogToolbar` — reads the parts it shows from
/// `viewModel.parts` in its own body, so a publication re-renders only the columns whose
/// parts it changed (`CatalogWindowParts`): a one-tile hide the detail column, a
/// publication that changed nothing none.
struct ContentView: View {
    @Bindable var viewModel: CatalogWindowViewModel
    /// The pane the inspector last showed: view-local, so a collapsing column keeps it.
    /// None until a pane is first shown, so a window whose inspector is closed builds no
    /// pane: a hidden edit panel cost the launch its every slider and value field.
    @State private var lastInspectorPane: InspectorPane?
    @FocusState private var isSearchFocused: Bool

    /// The large-download question (Plan 0104): the suppression checkbox writes the same
    /// preference as Settings ▸ General.
    private var largeTrashDownloadAlertHost: some View {
        Color.clear
            .alert(
                viewModel.largeTrashDownloadPrompt?.title ?? "",
                isPresented: Binding(
                    get: { viewModel.largeTrashDownloadPrompt != nil },
                    // Buttons answer; Escape triggers Cancel.
                    set: { _ in }
                )
            ) {
                Button(LargeTrashDownloadPrompt.confirmTitle) {
                    viewModel.confirmLargeTrashDownload()
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {
                    viewModel.cancelLargeTrashDownload()
                }
            } message: {
                if let prompt = viewModel.largeTrashDownloadPrompt {
                    Text(prompt.message)
                }
            }
            .dialogSuppressionToggle(
                isSuppressed: Binding(
                    get: { !viewModel.asksBeforeLargeTrashDownload },
                    set: { suppressed in viewModel.setAsksBeforeLargeTrashDownload(!suppressed) }
                )
            )
    }

    var body: some View {
        NavigationSplitView {
            SidebarColumn(viewModel: viewModel)
        } detail: {
            DetailColumn(viewModel: viewModel)
                .background { largeTrashDownloadAlertHost }
                // The trailing inspector column collapses and expands like the sidebar. It holds
                // one pane at a time, Info or Edit; the toolbar toggles and View ▸ Show Info /
                // Show Edit drive the same intents.
                .inspector(isPresented: Binding(
                    get: { viewModel.inspectorPane != nil },
                    set: { presented in
                        if !presented {
                            viewModel.setInspectorPane(nil)
                        }
                    }
                )) {
                    InspectorColumn(viewModel: viewModel, pane: viewModel.inspectorPane ?? lastInspectorPane)
                        .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
                }
                .onChange(of: viewModel.inspectorPane) { _, pane in
                    if let pane {
                        lastInspectorPane = pane
                    }
                }
        }
        .toolbar {
            CatalogToolbar(viewModel: viewModel)
        }
        // Keyword search (ADR 0048): the toolbar's trailing search field narrows whatever
        // scope is shown; Edit ▸ Find focuses it.
        .searchable(
            text: Binding(get: { viewModel.searchText }, set: { viewModel.setSearchText($0) }),
            placement: .toolbar,
            prompt: "Search"
        )
        .searchFocused($isSearchFocused)
        // The field's clear button, pressed while the field is not being edited, does not reach
        // the binding above; the field's own action does (`ToolbarSearchFieldClearRelay`).
        .background(ToolbarSearchFieldClearRelay { viewModel.setSearchText("") })
        .onChange(of: viewModel.searchFocusRequest) {
            isSearchFocused = true
        }
        // Focus however it came (a click, Tab, Edit ▸ Find) readies the first query.
        .onChange(of: isSearchFocused) { _, focused in
            if focused {
                viewModel.searchFieldFocused()
            }
        }
        .alert(
            "Could Not Eject Disk",
            isPresented: Binding(
                get: { viewModel.ejectAlertMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.dismissEjectAlert()
                    }
                }
            )
        ) {
            Button("OK") {
                viewModel.dismissEjectAlert()
            }
        } message: {
            if let message = viewModel.ejectAlertMessage {
                Text(message)
            }
        }
        // Add Name…, Rename…, Set Birthday…, New Name… and Someone Else…, and the merge any of
        // them, a drop or Merge Into ▸ asks first (ADR 0047).
        .modifier(PersonSheetHost(viewModel: viewModel))
        .modifier(PeopleMergeAlert(
            question: viewModel.peopleSession.mergeQuestion,
            name: { viewModel.peopleState.name($0) },
            answer: { viewModel.answerMerge($0) }
        ))
        .modifier(PeopleRefusalAlert(
            refusal: viewModel.peopleSession.refusal,
            dismiss: { viewModel.dismissPeopleRefusal() }
        ))
        .sheet(
            isPresented: Binding(
                get: { viewModel.exportSheet != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.cancelExportSheet()
                    }
                }
            )
        ) {
            ExportSheetView(
                title: viewModel.exportSheet?.title ?? "",
                settings: viewModel.exportSettings,
                setSettings: viewModel.setExportSettings,
                setDestination: viewModel.setExportDestination,
                export: viewModel.confirmExport,
                cancel: viewModel.cancelExportSheet
            )
        }
        .alert(
            viewModel.exportReport?.title ?? "",
            isPresented: Binding(
                get: { viewModel.exportReport != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.dismissExportReport()
                    }
                }
            )
        ) {
            if viewModel.exportReport?.exported.isEmpty == false {
                Button("Show in Finder") {
                    viewModel.revealExportedFiles()
                }
            }
            Button("OK", role: .cancel) {
                viewModel.dismissExportReport()
            }
        } message: {
            if let report = viewModel.exportReport {
                Text(report.message)
            }
        }
        .alert(
            "Couldn’t Prepare Photos",
            isPresented: Binding(
                get: { viewModel.handOffAlertMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.dismissHandOffAlert()
                    }
                }
            )
        ) {
            Button("OK") {
                viewModel.dismissHandOffAlert()
            }
        } message: {
            if let message = viewModel.handOffAlertMessage {
                Text(message)
            }
        }
        // A choice the catalog could not record (DES-120): its targets show what they showed
        // before and are selected, as a failed Move to Trash's are (DES-076).
        .modifier(MediaChoiceFailureAlert(
            failure: viewModel.mediaChoiceFailure,
            dismiss: { viewModel.dismissMediaChoiceFailure() }
        ))
        .alert(
            viewModel.trashAlertMessage ?? "Move to Trash",
            isPresented: Binding(
                get: { viewModel.trashAlertMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.dismissTrashAlert()
                    }
                }
            )
        ) {
            Button("Show in Finder") {
                viewModel.showFailedTrashItemsInFinder()
            }
            Button("Dismiss", role: .cancel) {
                viewModel.dismissTrashAlert()
            }
        } message: {
            Text(viewModel.trashAlertDetail)
        }
        .alert(
            viewModel.trashDecisions.first.map { TrashDecisionPrompt(decision: $0).title } ?? "",
            isPresented: Binding(
                get: { !viewModel.trashDecisions.isEmpty },
                // Every dismissal goes through a button (Escape triggers Cancel), and
                // each answers exactly the decision it was shown for; a setter that also
                // answered would consume the next queued decision.
                set: { _ in }
            )
        ) {
            Button(TrashDecisionPrompt.deleteTitle, role: .destructive) {
                viewModel.answerTrashDecisionDelete()
            }
            Button("Cancel", role: .cancel) {
                viewModel.answerTrashDecisionCancel()
            }
        } message: {
            if let decision = viewModel.trashDecisions.first {
                Text(TrashDecisionPrompt(decision: decision).message)
            }
        }
        .confirmationDialog(
            "Reorganize library?",
            isPresented: Binding(
                get: { viewModel.reorganizationConfirmation != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.cancelReorganizationConfirmation()
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: viewModel.reorganizationConfirmation
        ) { _ in
            Button("Reorganize", role: .destructive) {
                viewModel.confirmReorganization()
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelReorganizationConfirmation()
            }
        } message: { confirmation in
            Text(confirmation.summaryText)
        }
        .alert(
            viewModel.reorganizationAlert?.title ?? "",
            isPresented: Binding(
                get: { viewModel.reorganizationAlert != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.reorganizationAlert = nil
                    }
                }
            ),
            presenting: viewModel.reorganizationAlert
        ) { _ in
            Button("OK") {
                viewModel.reorganizationAlert = nil
            }
        } message: { alert in
            Text(alert.message)
        }
    }
}

/// The sidebar column: depends on the libraries, sources, import batches and the rows'
/// facts, never on the grid (`CatalogWindowParts`).
struct SidebarColumn: View {
    let viewModel: CatalogWindowViewModel

    var body: some View {
        SidebarView(
            showsAllMedia: viewModel.showsAllMediaRow,
            showsPlaces: viewModel.showsPlacesRow,
            showsPeople: viewModel.showsPeopleRow,
            onThisDay: viewModel.onThisDayRowDay,
            showsDuplicates: viewModel.showsDuplicatesRow,
            duplicatesCount: viewModel.duplicatesCount,
            libraries: viewModel.parts.libraries,
            accountStatuses: viewModel.immichAccountStatuses,
            importBatches: viewModel.parts.importBatches,
            removableSources: viewModel.parts.removableSources,
            importPresentations: viewModel.importPresentations,
            sidebarSelection: viewModel.sidebarSelection,
            ejectingSourceIdentities: viewModel.ejectingSourceIdentities,
            selectSidebar: viewModel.selectSidebar,
            ejectSource: viewModel.ejectRemovableSource
        )
    }
}

/// The detail column: the surface the selected scope draws, its bars and the window's
/// title. A one-tile change re-renders this column alone (`CatalogWindowParts`).
struct DetailColumn: View {
    let viewModel: CatalogWindowViewModel

    /// The libraries an import may copy into now.
    private var importDestinations: [CatalogLibraryState] {
        viewModel.parts.libraries.filter { $0.kind.isImportDestination && $0.availability == .available }
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.sidebarSelection == .allImports {
                AllImportsListView(
                    batches: viewModel.parts.importBatches,
                    selectBatch: { batchID in
                        viewModel.selectSidebar(.importBatch(batchID))
                    }
                )
            } else {
                detailContent
                    .navigationSubtitle(viewModel.windowSubtitle)
            }
            if let presentation = viewModel.selectedImportPresentation {
                ImportPlanFooter(
                    presentation: presentation,
                    fixedLibraries: importDestinations,
                    sourceDisplayName: viewModel.parts.removableSources
                        .first { $0.path == presentation.sourcePath }?.displayName ?? "",
                    isCancelling: viewModel.cancellingImportSources.contains(presentation.sourcePath),
                    isImportClickHeld: viewModel.heldImportClicks.contains(presentation.sourcePath),
                    importPreferences: viewModel.importPreferences,
                    setDestination: { destination in
                        viewModel.setImportDestination(destination, for: presentation.sourcePath)
                    },
                    queueImport: {
                        viewModel.queueImport(for: presentation.sourcePath)
                    },
                    cancelImport: {
                        viewModel.cancelImport(for: presentation.sourcePath)
                    },
                    ejectCard: {
                        if let source = viewModel.parts.removableSources
                            .first(where: { $0.path == presentation.sourcePath })
                        {
                            viewModel.ejectRemovableSource(source.root)
                        }
                    },
                    retryPlanning: {
                        viewModel.retryImportPlanning(for: presentation.sourcePath)
                    },
                    revealAttentionItems: { ids in
                        viewModel.selectAssets(ids)
                    },
                    sessionPreferences: viewModel.sessionPreferences(for: presentation.sourcePath),
                    setSessionPreferences: { prefs in
                        viewModel.setSessionPreferences(prefs, for: presentation.sourcePath)
                    }
                )
            }
            if let trashStatus = TrashStatusPresentation.map(viewModel.trashQueueState) {
                TrashStatusBar(presentation: trashStatus, cancel: viewModel.cancelPendingTrash)
            }
            if let handOff = viewModel.handOffProgress {
                ProgressStatusBar(
                    title: handOff.title,
                    completed: handOff.completed,
                    total: handOff.total,
                    cancel: viewModel.cancelHandOff
                )
            }
            if let export = viewModel.exportProgress {
                ProgressStatusBar(
                    title: export.title,
                    completed: export.completed,
                    total: export.total,
                    cancel: viewModel.cancelExport
                )
            }
        }
        // One title for every scope, from its one owner: no pane names itself.
        .navigationTitle(viewModel.windowTitle)
    }

    @ViewBuilder
    var detailContent: some View {
        // The selected scope from the click on (DES-118): until its state is applied, its
        // surface waits, drawing nothing of the scope left.
        if case let .waiting(showsIndicator) = viewModel.detailPane.content {
            ScopeWaitingView(
                bar: waitingBar,
                title: viewModel.windowTitle,
                showsIndicator: showsIndicator,
                opening: viewModel.catalogOpeningPresentation,
                framePresented: viewModel.waitingFramePresented
            )
        } else if viewModel.showsPeopleList {
            // Until People is first built the pane claims nothing (APP-044).
            if let people = viewModel.shownPeople {
                PeopleView(
                    people: people,
                    session: viewModel.peopleSession,
                    librariesState: viewModel.parts.mediaEmptyState,
                    images: viewModel.faceTileImages,
                    derivedImageDirectory: viewModel.thumbnailDirectory,
                    actions: viewModel.peopleActions
                )
                .equatable()
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if viewModel.showsDuplicatesList {
            // Until the groups are first built the pane claims nothing (APP-044).
            if let duplicates = viewModel.parts.duplicates {
                DuplicatesView(
                    duplicates: duplicates,
                    session: viewModel.duplicatesSession,
                    canUndoMove: viewModel.canUndoDuplicatesMove,
                    selection: viewModel.gridSelection.selection,
                    tileContentStore: viewModel.tileContentStore,
                    thumbnailDirectory: viewModel.thumbnailDirectory,
                    detailReader: viewModel.tileDetailReader,
                    actions: viewModel.duplicatesActions
                )
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if viewModel.showsOnThisDay {
            if let story = viewModel.story, let item = viewModel.storyItem, let onThisDay = viewModel.parts.onThisDay {
                StoryPlayerView(
                    story: story,
                    item: item,
                    onThisDay: onThisDay,
                    orderedIDs: viewModel.parts.mediaGrid.orderedAssetIDs,
                    today: viewModel.today,
                    kind: viewModel.focusedAssetKind,
                    panePreview: viewModel.displayedPanePreview(.loupe),
                    videoState: viewModel.loupeVideoState,
                    isDownloading: viewModel.downloadingSlots.contains(.loupe),
                    tileContentStore: viewModel.tileContentStore,
                    thumbnailDirectory: viewModel.thumbnailDirectory,
                    detailReader: viewModel.tileDetailReader,
                    titles: viewModel.anniversaryTitles,
                    actions: StoryPlayerActions(
                        canTogglePause: viewModel.canToggleStoryPause,
                        canPrevious: viewModel.canStoryPrevious,
                        canNext: viewModel.canStoryNext,
                        togglePause: viewModel.toggleStoryPause,
                        previous: viewModel.storyPrevious,
                        next: viewModel.storyNext,
                        close: viewModel.closeStory
                    )
                )
            } else {
                OnThisDayView(
                    onThisDay: viewModel.parts.onThisDay,
                    today: viewModel.today,
                    emptyState: viewModel.parts.mediaEmptyState,
                    focusRequest: viewModel.onThisDayFocusRequest,
                    tileContentStore: viewModel.tileContentStore,
                    thumbnailDirectory: viewModel.thumbnailDirectory,
                    detailReader: viewModel.tileDetailReader,
                    titles: viewModel.anniversaryTitles,
                    play: { viewModel.playStory(anniversary: $0) },
                    clearFilters: viewModel.clearMediaFilter
                )
            }
        } else if viewModel.showsPlacesMap {
            PlacesMapView(
                map: viewModel.parts.map ?? .empty,
                clusters: viewModel.mapClusters,
                cameraRequest: viewModel.mapCameraRequest,
                emptyState: viewModel.parts.mediaEmptyState,
                tileContentStore: viewModel.tileContentStore,
                thumbnailDirectory: viewModel.thumbnailDirectory,
                detailReader: viewModel.tileDetailReader,
                onViewportChanged: viewModel.mapViewportChanged,
                onClusterClick: viewModel.clickMapCluster,
                onMouseDown: viewModel.mapMouseDown(clickCount:),
                onClusterOpen: viewModel.openMapCluster,
                clearFilters: viewModel.clearMediaFilter
            )
        } else {
            browserContent
        }
    }

    /// The waiting surface's bar, with what the window holds without the scope's read.
    private var waitingBar: ScopeWaitingBar {
        switch viewModel.detailPane.surface {
        case nil:
            .none
        case .placesMap:
            .places
        case .onThisDay:
            if case let .onThisDay(day) = viewModel.sidebarSelection {
                .onThisDay(day)
            } else {
                .onThisDay(viewModel.today)
            }
        case .people:
            .people(viewModel.shownPeople)
        case .duplicates:
            .duplicates(
                viewModel.parts.duplicates.map { duplicates in
                    DuplicatesBarPresentation.map(
                        viewModel.duplicatesSession.tally(in: duplicates),
                        receipt: viewModel.duplicatesSession.receipt,
                        canUndoMove: viewModel.canUndoDuplicatesMove
                    ).waiting
                },
                viewModel.duplicatesActions
            )
        }
    }

    @ViewBuilder
    private var browserContent: some View {
        switch viewModel.viewMode {
        case .grid:
            MediaGridView(
                grid: viewModel.parts.mediaGrid,
                tileContentStore: viewModel.tileContentStore,
                emptyState: viewModel.mediaEmptyState,
                deviceConnectionBanner: viewModel.parts.deviceConnectionBanner,
                thumbnailDirectory: viewModel.thumbnailDirectory,
                detailReader: viewModel.tileDetailReader,
                stallMonitor: viewModel.uiStallMonitor,
                onViewportChanged: viewModel.viewportChanged,
                clearFilters: viewModel.clearMediaFilter,
                gridColumnCount: viewModel.gridColumnCount,
                onGridColumnCountChangeRequested: viewModel.setGridColumnCount,
                selectionHandlers: .from(viewModel),
                onItemDoubleClick: { viewModel.openLoupe(id: $0) },
                onReturnKey: { viewModel.openLoupe(id: nil) },
                onMediaChoiceKey: { viewModel.submitMediaChoice($0, origin: .keyboard) },
                onMediaChoice: { id, choice in
                    viewModel.submitMediaChoice(choice, target: .item(id), origin: .inline)
                },
                onStackBadge: { viewModel.toggleStack(shownBy: $0) },
                contextMenu: viewModel.makeMediaItemContextMenu,
                faceOutlines: viewModel.outlinedFaceBoxes,
                tileChoiceChange: viewModel.tileChoiceChange,
                focusTargetID: viewModel.focusedAssetID,
                dismissedCameraBannerIdentities: viewModel.dismissedCameraBannerIdentities,
                onDismissCameraBanner: { viewModel.dismissCameraConnectionBanner($0.identity) }
            )
        case .loupe:
            LoupeView(
                grid: viewModel.parts.mediaGrid,
                tileContentStore: viewModel.tileContentStore,
                focusedAssetID: viewModel.focusedAssetID,
                focusedAssetKind: viewModel.focusedAssetKind,
                panePreview: viewModel.displayedPanePreview(.loupe),
                loupeVideoState: viewModel.loupeVideoState,
                isDownloading: viewModel.downloadingSlots.contains(.loupe),
                stripTileEdge: viewModel.stripTileEdge,
                setStripTileEdge: viewModel.setStripTileEdge,
                thumbnailDirectory: viewModel.thumbnailDirectory,
                detailReader: viewModel.tileDetailReader,
                stallMonitor: viewModel.uiStallMonitor,
                selectionHandlers: .from(viewModel),
                onViewportChanged: viewModel.viewportChanged,
                onStripArrow: { delta in
                    if delta < 0 {
                        viewModel.focusPrevious()
                    } else {
                        viewModel.focusNext()
                    }
                },
                onEscape: viewModel.loupeEscape,
                onMediaChoiceKey: { viewModel.submitMediaChoice($0, origin: .keyboard) },
                onMediaChoice: { id, choice in
                    viewModel.submitMediaChoice(choice, target: .item(id), origin: .inline)
                },
                onPlayVideo: { id in viewModel.playLoupeVideo(id: id) },
                focusedMediaChoice: viewModel.panePreviews[.loupe]?.mediaChoice,
                onPreviewMediaChoice: { choice in
                    guard let id = viewModel.focusedAssetID else { return }
                    viewModel.submitMediaChoice(choice, target: .item(id), origin: .inline)
                },
                contextMenu: viewModel.makeMediaItemContextMenu,
                loupeZoomCommand: viewModel.loupeZoomCommand,
                onZoomReport: viewModel.reportLoupeZoom,
                onZoomDoubleClick: { viewModel.toggleLoupeZoom(at: $0) },
                isPickingNeutral: viewModel.isPickingNeutral,
                onPickNeutral: viewModel.pickNeutral(at:),
                faceOutlineBoxes: viewModel.outlinedFaceBoxes,
                tileChoiceChange: viewModel.tileChoiceChange,
                cropEditor: viewModel.isCropping
                    ? viewModel.editCropBase.map { base in
                        CropEditorInput(
                            image: base.image,
                            crop: viewModel.editDraft.crop ?? .whole,
                            fractionRatio: viewModel.cropFractionRatio,
                            setCrop: viewModel.setCrop,
                            isDrawingLine: viewModel.isDrawingStraightenLine,
                            straighten: viewModel.straighten(along:to:)
                        )
                    }
                    : nil,
                videoTrimCommand: viewModel.videoTrimCommand,
                onVideoTrimmed: viewModel.finishTrim(id:),
                showsOriginal: viewModel.loupeShowsOriginal,
                canPlayLivePhoto: viewModel.canPlayLivePhoto,
                onPlayLivePhoto: { viewModel.playLivePhoto() },
                shownPair: viewModel.shownPair,
                onShowPairMember: { viewModel.showPairMember($0) }
            )
        case .compare:
            CompareView(
                grid: viewModel.parts.mediaGrid,
                tileContentStore: viewModel.tileContentStore,
                leftID: viewModel.comparePair.left,
                rightID: viewModel.comparePair.right,
                leftPreview: viewModel.displayedPanePreview(.compareLeft),
                rightPreview: viewModel.displayedPanePreview(.compareRight),
                leftIsDownloading: viewModel.downloadingSlots.contains(.compareLeft),
                rightIsDownloading: viewModel.downloadingSlots.contains(.compareRight),
                focusTargetID: viewModel.compareStripFocusTargetID,
                stripTileEdge: viewModel.stripTileEdge,
                setStripTileEdge: viewModel.setStripTileEdge,
                thumbnailDirectory: viewModel.thumbnailDirectory,
                detailReader: viewModel.tileDetailReader,
                stallMonitor: viewModel.uiStallMonitor,
                selectionHandlers: .from(viewModel),
                onViewportChanged: viewModel.viewportChanged,
                onStripArrow: { delta in
                    viewModel.slideCompare(delta)
                },
                onEscape: viewModel.exitToGrid,
                onMediaChoiceKey: { viewModel.submitMediaChoice($0, origin: .keyboard) },
                onMediaChoice: { id, choice in
                    viewModel.submitMediaChoice(choice, target: .item(id), origin: .inline)
                },
                leftMediaChoice: viewModel.panePreviews[.compareLeft]?.mediaChoice,
                rightMediaChoice: viewModel.panePreviews[.compareRight]?.mediaChoice,
                onPaneMediaChoice: { pane, choice in
                    viewModel.submitMediaChoice(choice, target: .compare(pane), origin: .inline)
                },
                activePane: viewModel.activeComparePane,
                onPaneActivated: viewModel.activateComparePane,
                contextMenu: viewModel.makeMediaItemContextMenu,
                faceOutlineBoxes: viewModel.outlinedFaceBoxes,
                tileChoiceChange: viewModel.tileChoiceChange
            )
        }
    }
}

/// The inspector's column: the pane it shows, Info or Edit, built from what that pane
/// reads alone, so a publication that changes neither renders neither.
struct InspectorColumn: View {
    let viewModel: CatalogWindowViewModel
    /// The pane shown, or the one last shown while the column collapses.
    let pane: InspectorPane?

    /// The inspector's pane: Info or Edit. While the column collapses its last pane stays,
    /// so the content does not switch under the animation.
    var body: some View {
        switch pane {
        case nil:
            EmptyView()
        case .info:
            InfoPaneView(
                info: viewModel.photoInfo,
                people: InfoPanePeople(
                    menu: viewModel.targetFaceMenu,
                    line: viewModel.targetFacesLine,
                    images: viewModel.faceTileImages,
                    derivedImageDirectory: viewModel.thumbnailDirectory,
                    perform: viewModel.performMediaItemCommand,
                    hover: viewModel.outlineFaces
                ),
                search: viewModel.searchForLabel,
                folded: viewModel.foldedInfoSections,
                toggleFold: viewModel.toggleInfoSectionFold
            )
            .equatable()
        case .edit:
            EditPanelView(
                photoName: viewModel.editTarget?.id.fileURL.lastPathComponent,
                facts: viewModel.editPhotoFacts,
                recipe: viewModel.editDraft,
                histogram: viewModel.editHistogram,
                original: EditPanelOriginalState(
                    isShowingOriginal: viewModel.isShowingOriginal,
                    canShowOriginal: viewModel.canShowOriginal,
                    canRevert: viewModel.canRevertToOriginal
                ),
                selectedControl: viewModel.selectedEditControl,
                isPickingNeutral: viewModel.isPickingNeutral,
                canPickNeutral: viewModel.canPickNeutral,
                crop: EditPanelCropState(
                    isCropping: viewModel.isCropping,
                    canCrop: viewModel.canCrop,
                    aspect: viewModel.cropAspect,
                    isLandscape: viewModel.cropAspectIsLandscape,
                    isDrawingLine: viewModel.isDrawingStraightenLine,
                    autoStraighten: viewModel.autoStraightenState,
                    autoCrop: viewModel.autoCropState
                ),
                setValue: viewModel.setEditValue,
                setDragging: viewModel.setEditDragging,
                resetSection: viewModel.resetEditSection,
                toggleNeutralPicker: viewModel.toggleNeutralPicker,
                cropActions: EditPanelCropActions(
                    toggleTool: viewModel.toggleCropTool,
                    setAspect: viewModel.setCropAspect,
                    rotateAspect: viewModel.rotateCropAspect,
                    turn: viewModel.turnPhoto(clockwise:),
                    flip: viewModel.flipPhoto(horizontally:),
                    autoStraighten: viewModel.autoStraighten,
                    toggleLine: viewModel.toggleStraightenLine,
                    autoCrop: viewModel.autoCrop
                ),
                setEntering: viewModel.setEnteringEditValue,
                setLensCorrection: viewModel.setLensCorrection,
                resetControl: viewModel.resetEditControl,
                originalActions: EditPanelOriginalActions(
                    toggleShowOriginal: viewModel.toggleShowOriginal,
                    revert: viewModel.revertToOriginal
                ),
                pair: viewModel.shownPair.flatMap { pair in
                    viewModel.editTarget.map { (stack: pair, shown: $0.id) }
                },
                showPairMember: { viewModel.showPairMember($0) },
                folded: viewModel.foldedEditSections,
                toggleFold: viewModel.toggleEditSectionFold
            )
        }
    }
}

/// The window's toolbar as its own content: it depends on what its controls show (the
/// query, the filter's options, the targets), never on the grid's order.
struct CatalogToolbar: ToolbarContent {
    let viewModel: CatalogWindowViewModel

    var body: some ToolbarContent {
        // Back to Map, while the browser shows an area under the Places map (ADR 0040).
        // A different scope is a different surface, so the item exists only there.
        if viewModel.showsMapAreaLeaf {
            ToolbarItem(placement: .navigation) {
                Button {
                    viewModel.returnToPlaces()
                } label: {
                    Label("Back to Map", systemImage: "chevron.left")
                }
                .help("Back to Map")
            }
        }
        // Back to People, while the browser shows the people it was opened on from the
        // gallery (ADR 0047).
        if viewModel.showsBackToPeople {
            ToolbarItem(placement: .navigation) {
                Button {
                    viewModel.returnToPeople()
                } label: {
                    Label("Back to People", systemImage: "chevron.left")
                }
                .help("Back to People")
            }
        }
        // The person the filter shows, with their settings: the one place a person's
        // photos are named and edited from (`docs/design/people.md`).
        if let person = viewModel.shownPerson {
            ToolbarItem(placement: .navigation) {
                PersonToolbarMenu(person: person, viewModel: viewModel)
            }
        }
        // Back to Duplicates, while the browser shows one duplicate group (ADR 0042).
        if viewModel.showsDuplicateGroupLeaf {
            ToolbarItem(placement: .navigation) {
                Button {
                    viewModel.returnToDuplicates()
                } label: {
                    Label("Back to Duplicates", systemImage: "chevron.left")
                }
                .help("Back to Duplicates")
            }
        }
        // Four groups, each on its own glass, broad to narrow (DES-114): how the items
        // look, which items show and in what order, acts on the current targets, and the
        // inspector's panes nearest the column they open. Search trails them (DES-108).
        ToolbarItemGroup(placement: .primaryAction) {
            ViewModePicker(
                // The map and On This Day are not view modes: no segment is selected.
                viewMode: viewModel.showsViewModeSegment ? viewModel.viewMode : nil,
                setViewMode: viewModel.setViewMode
            )
            // The duplicates list has one presentation (DES-053: disabled, never removed).
            .disabled(!viewModel.canChangeViewMode)
            CatalogZoomControl(
                canZoomOut: viewModel.canZoomOut,
                canZoomIn: viewModel.canZoomIn,
                zoomOut: viewModel.zoomOut,
                zoomIn: viewModel.zoomIn
            )
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            CatalogFilterControl(
                descriptor: viewModel.queryDescriptor,
                options: viewModel.parts.filterOptions,
                isPresented: Binding(
                    get: { viewModel.isFilterPresented },
                    set: { viewModel.setFilterPresented($0) }
                ),
                setKind: viewModel.setMediaKind,
                setFileType: viewModel.setMediaFileType,
                setChoice: viewModel.setMediaChoice,
                people: viewModel.peopleFilterControls,
                places: PlaceFilterControls(setPlace: viewModel.setPlaceFilter),
                clearFilters: viewModel.clearMediaFilter
            )
            CatalogSortMenu(
                sort: viewModel.queryDescriptor.effectiveSort,
                search: viewModel.queryDescriptor.search,
                person: viewModel.shownPerson?.displayName,
                setOrder: viewModel.setSortOrder,
                orderByRelevance: viewModel.orderSearchByRelevance
            )
            // On This Day fixes its own order (DES-053: disabled in place; DES-038: the
            // reason is the tooltip).
            .disabled(!viewModel.canChangeSort)
            .help(viewModel.canChangeSort ? "Sort" : "On This Day always shows the newest first")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        // Acts on the current targets (APP-013, APP-036). File ▸ Share… and the Photo
        // menu are the menu-bar equivalents every toolbar item must have; the Share
        // button is also the anchor every Share path presents from.
        ToolbarItemGroup(placement: .primaryAction) {
            CatalogCurationToolbarControl(
                currentChoice: viewModel.currentTargetChoice,
                isEnabled: viewModel.hasMediaChoiceTarget,
                choose: { viewModel.submitMediaChoice($0, origin: .toolbar) }
            )
            CatalogShareToolbarButton(
                isEnabled: !viewModel.currentTargetFileURLs.isEmpty,
                onAnchor: viewModel.setShareAnchor,
                share: { viewModel.shareCurrentTargets(origin: .toolbar) }
            )
            CatalogActionToolbarMenu(
                openWith: viewModel.openWithMenu,
                icons: viewModel.openWithApplicationIcons,
                canReveal: !viewModel.currentTargetFileURLs.isEmpty,
                canTrash: viewModel.canMoveTargetedMediaToTrash,
                open: viewModel.openTargetsInDefaultApplication,
                openWithApplication: viewModel.openTargets(with:),
                openWithOther: viewModel.openTargetsWithChosenApplication,
                reveal: viewModel.revealCurrentTargetsInFinder,
                moveToTrash: viewModel.moveTargetedMediaToTrash
            )
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        // The inspector's two panes (APP-041, DES-092, DES-097); View ▸ Show Info and
        // Show Edit are their menu-bar equivalents.
        ToolbarItemGroup(placement: .primaryAction) {
            CatalogSurfaceToolbarToggle(
                title: "Info",
                systemImage: "info.circle",
                isShowing: viewModel.showsInfo,
                toggle: { viewModel.toggleInspector(.info) }
            )
            CatalogSurfaceToolbarToggle(
                title: "Edit",
                systemImage: "slider.horizontal.3",
                isShowing: viewModel.isEditPanelPresented,
                toggle: { viewModel.toggleInspector(.edit) }
            )
        }
    }
}

private struct AllImportsListView: View {
    let batches: [ImportBatchSummary]
    let selectBatch: (ImportBatchID) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // A real `List(selection:)`, not `Button`s inside a plain `List`:
        // Tab reaches the list, Up/Down move a genuine selection, and
        // Return/click both fire `selectBatch` the same way (DES-080).
        // There is no persistent selection to hold here — picking
        // a row navigates away from `.allImports` entirely, replacing this
        // view — so the binding's getter always reads `nil`.
        List(selection: selectionBinding) {
            ForEach(batches, id: \.batchID) { batch in
                HStack {
                    Text(ImportBatchFormatting.sidebarTitle(for: batch.batchID, among: batches))
                        .foregroundStyle(DesignPalette.label(for: colorScheme))
                    Spacer()
                    if let photoCount = batch.photoCount {
                        Text("\(photoCount) items")
                            .foregroundStyle(DesignPalette.l3(for: colorScheme))
                            .monospacedDigit()
                    }
                }
                .tag(batch.batchID)
            }
        }
    }

    private var selectionBinding: Binding<ImportBatchID?> {
        Binding(
            get: { nil },
            set: { newValue in
                if let newValue {
                    selectBatch(newValue)
                }
            }
        )
    }
}

#Preview {
    ContentView(
        viewModel: CatalogWindowViewModel(
            catalogStore: CatalogStore(location: .inMemory),
            preferencesDomain: .suite("Otos.Preview.\(UUID().uuidString)"),
            volumeCapacity: FreeSpaceFloor.availableBytes(onVolumeOf:),
            trashFiles: .refusing
        )
    )
}

/// Presents the Person sheet the view model asks for: one person's, or faces' to name.
private struct PersonSheetHost: ViewModifier {
    let viewModel: CatalogWindowViewModel

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { viewModel.peopleSession.sheet },
            set: {
                if $0 == nil {
                    viewModel.cancelPersonSheet()
                }
            }
        )) { request in
            PersonSheetView(
                context: viewModel.personSheetContext(request),
                images: viewModel.faceTileImages,
                derivedImageDirectory: viewModel.thumbnailDirectory,
                refusal: { name, birthday in viewModel.personSheetRefusal(request.subject, name: name, birthday: birthday) },
                save: { name, birthday in viewModel.savePersonSheet(request.subject, name: name, birthday: birthday) },
                cancel: viewModel.cancelPersonSheet
            )
        }
    }
}

/// The person the filter shows, as a toolbar menu titled with their name: their settings,
/// as the gallery's context menu offers them.
private struct PersonToolbarMenu: View {
    let person: PersonSummary
    let viewModel: CatalogWindowViewModel

    var body: some View {
        Menu {
            if let menu = viewModel.shownPersonMenu {
                PersonMenuContent(menu: menu) { viewModel.performPersonAct($0, on: person.id) }
            }
        } label: {
            Label(person.displayName, systemImage: "person.crop.circle")
        }
        .help("\(person.displayName)’s settings")
    }
}

/// A choice the catalog could not record (DES-120), in DES-076's form: its items are back as
/// they were and selected.
private struct MediaChoiceFailureAlert: ViewModifier {
    let failure: MediaChoiceFailure?
    let dismiss: () -> Void

    func body(content: Content) -> some View {
        content.alert(
            failure?.title ?? "",
            isPresented: Binding(
                get: { failure != nil },
                set: { isPresented in
                    if !isPresented {
                        dismiss()
                    }
                }
            )
        ) {
            Button("OK", action: dismiss)
        } message: {
            Text(MediaChoiceFailure.message)
        }
    }
}
