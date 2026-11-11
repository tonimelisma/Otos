//
//  ContentView.swift
//  Otos
//
//  Created by Taylor on 6/2/26.
//

import SwiftUI

/// ContentView composes already-projected state and is deliberately passive: it
/// renders `viewModel.state` and forwards intents, but never subscribes to catalog
/// notifications, sorts, or derives catalog state in `body`. Why: a SwiftUI `body`
/// can run many times per second, so doing real work there — or re-deriving catalog
/// state — would be both slow and a second source of truth that could drift from
/// the model. The model decides; the view renders.
struct ContentView: View {
    @Bindable var viewModel: CatalogWindowViewModel
    /// The pane the inspector last showed: view-local, so a collapsing column keeps it.
    /// None until a pane is first shown, so a window whose inspector is closed builds no
    /// pane: a hidden edit panel cost the launch its every slider and value field.
    @State private var lastInspectorPane: InspectorPane?
    @FocusState private var isSearchFocused: Bool

    /// The large-download question (Plan 0104): the suppression checkbox writes the same
    /// preference as Settings ▸ General.
    /// The inspector's pane: Info or Edit. While the column collapses its last pane stays,
    /// so the content does not switch under the animation.
    @ViewBuilder
    private var inspectorContent: some View {
        switch viewModel.inspectorPane ?? lastInspectorPane {
        case nil:
            EmptyView()
        case .info:
            InfoPaneView(info: viewModel.photoInfo)
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
                )
            )
        }
    }

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

    /// The libraries an import may copy into now.
    private var importDestinations: [CatalogLibraryState] {
        viewModel.state.libraries.filter { $0.kind.isImportDestination && $0.availability == .available }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                showsAllMedia: viewModel.showsAllMediaRow,
                showsPlaces: viewModel.showsPlacesRow,
                showsPeople: viewModel.showsPeopleRow,
                onThisDay: viewModel.onThisDayRowDay,
                showsDuplicates: viewModel.showsDuplicatesRow,
                duplicatesCount: viewModel.duplicatesCount,
                libraries: viewModel.state.libraries,
                accountStatuses: viewModel.immichAccountStatuses,
                importBatches: viewModel.state.importBatches,
                removableSources: viewModel.state.removableSources,
                importPresentations: viewModel.importPresentations,
                sidebarSelection: viewModel.sidebarSelection,
                ejectingSourceIdentities: viewModel.ejectingSourceIdentities,
                selectSidebar: viewModel.selectSidebar,
                ejectSource: viewModel.ejectRemovableSource
            )
        } detail: {
            VStack(spacing: 0) {
                if viewModel.sidebarSelection == .allImports {
                    AllImportsListView(
                        batches: viewModel.state.importBatches,
                        selectBatch: { batchID in
                            viewModel.selectSidebar(.importBatch(batchID))
                        }
                    )
                } else {
                    detailContent
                        // An active filter names itself under the title, so a scope that
                        // looks short is never mistaken for the whole of it (DES-029:
                        // never the filter glyph's color alone). The duplicates list
                        // ignores the filter, so it never claims to be filtered.
                        .navigationSubtitle(
                            viewModel.queryDescriptor.filter.isActive && !viewModel.showsDuplicatesList
                                && !viewModel.showsPeopleList && !viewModel.showsPeopleReview ? "Filtered" : ""
                        )
                }
                if let presentation = viewModel.selectedImportPresentation {
                    ImportPlanFooter(
                        presentation: presentation,
                        fixedLibraries: importDestinations,
                        sourceDisplayName: viewModel.state.removableSources
                            .first { $0.path == presentation.sourcePath }?.displayName ?? "",
                        isCancelling: viewModel.cancellingImportSources.contains(presentation.sourcePath),
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
                            if let source = viewModel.state.removableSources
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
            // Hosted on its own view so `Do not ask again` applies to this alert only.
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
                inspectorContent
                    .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
            }
            .onChange(of: viewModel.inspectorPane) { _, pane in
                if let pane {
                    lastInspectorPane = pane
                }
            }
        }
        .toolbar {
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
            // Back to People, while the browser shows one person's photos or the review; Back
            // to Review, while it shows one review row's photos (ADR 0047).
            if viewModel.showsPersonLeaf || viewModel.showsPeopleReview {
                ToolbarItem(placement: .navigation) {
                    Button {
                        viewModel.returnToPeople()
                    } label: {
                        Label("Back to People", systemImage: "chevron.left")
                    }
                    .help("Back to People")
                }
            }
            if viewModel.showsReviewPhotosLeaf {
                ToolbarItem(placement: .navigation) {
                    Button {
                        viewModel.returnToReview()
                    } label: {
                        Label("Back to Review", systemImage: "chevron.left")
                    }
                    .help("Back to Review")
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
                    viewMode: viewModel.showsPlacesMap || viewModel.showsOnThisDay ? nil : viewModel.viewMode,
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
                    options: viewModel.state.filterOptions,
                    isPresented: Binding(
                        get: { viewModel.isFilterPresented },
                        set: { viewModel.setFilterPresented($0) }
                    ),
                    setKind: viewModel.setMediaKind,
                    setFileType: viewModel.setMediaFileType,
                    setChoice: viewModel.setMediaChoice,
                    clearFilters: viewModel.clearMediaFilter
                )
                CatalogSortMenu(
                    sort: viewModel.queryDescriptor.sort,
                    search: viewModel.queryDescriptor.search,
                    setOrder: viewModel.setSortOrder,
                    orderByRelevance: viewModel.orderSearchByRelevance
                )
                // On This Day fixes its own order (DES-053: disabled in place; DES-038: the
                // reason is the tooltip).
                .disabled(!viewModel.canChangeSort)
                .help(viewModel.canChangeSort ? "Sort" : "On This Day always shows the newest year first")
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
        // Keyword search (ADR 0048): the toolbar's trailing search field narrows whatever
        // scope is shown; Edit ▸ Find focuses it.
        .searchable(
            text: Binding(get: { viewModel.searchText }, set: { viewModel.setSearchText($0) }),
            placement: .toolbar,
            prompt: "Search"
        )
        .searchFocused($isSearchFocused)
        .onChange(of: viewModel.searchFocusRequest) {
            isSearchFocused = true
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
        // Rename… and Set Birthday…, and the new person a split makes (ADR 0047).
        .modifier(PersonSheetHost(viewModel: viewModel))
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
            "Reorganize Library?",
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
            "Reorganization",
            isPresented: Binding(
                get: { viewModel.reorganizationAlertMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.reorganizationAlertMessage = nil
                    }
                }
            )
        ) {
            Button("OK") {
                viewModel.reorganizationAlertMessage = nil
            }
        } message: {
            if let message = viewModel.reorganizationAlertMessage {
                Text(message)
            }
        }
    }

    @ViewBuilder
    var detailContent: some View {
        if viewModel.showsPeopleList {
            // Until People is first built the pane claims nothing (APP-044).
            if let people = viewModel.state.people {
                PeopleView(
                    people: people,
                    unnamed: viewModel.shownUnnamedGroups,
                    session: viewModel.peopleSession,
                    librariesState: viewModel.state.mediaEmptyState,
                    images: viewModel.faceTileImages,
                    derivedImageDirectory: viewModel.thumbnailDirectory,
                    canReview: viewModel.canReviewSuggestions,
                    actions: viewModel.peopleActions
                )
                .navigationTitle("People")
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if viewModel.showsPeopleReview {
            if let people = viewModel.state.people {
                PeopleReviewView(
                    people: people,
                    layout: viewModel.peopleReviewLayout,
                    session: viewModel.peopleSession,
                    bar: viewModel.peopleReviewBarState,
                    names: { viewModel.peopleIndex.name($0) },
                    images: viewModel.faceTileImages,
                    derivedImageDirectory: viewModel.thumbnailDirectory,
                    actions: viewModel.peopleReviewActions
                )
                .navigationTitle("Review Suggestions")
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if viewModel.showsDuplicatesList {
            // Until the groups are first built the pane claims nothing (APP-044).
            if let duplicates = viewModel.state.duplicates {
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
            if let story = viewModel.story, let item = viewModel.storyItem, let onThisDay = viewModel.state.onThisDay {
                StoryPlayerView(
                    story: story,
                    item: item,
                    onThisDay: onThisDay,
                    orderedIDs: viewModel.state.mediaGrid.orderedAssetIDs,
                    today: viewModel.today,
                    kind: viewModel.focusedAssetKind,
                    panePreview: viewModel.displayedPanePreview(.loupe),
                    videoState: viewModel.loupeVideoState,
                    isDownloading: viewModel.downloadingSlots.contains(.loupe),
                    tileContentStore: viewModel.tileContentStore,
                    thumbnailDirectory: viewModel.thumbnailDirectory,
                    detailReader: viewModel.tileDetailReader,
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
                    onThisDay: viewModel.state.onThisDay,
                    today: viewModel.today,
                    emptyState: viewModel.state.mediaEmptyState,
                    focusRequest: viewModel.onThisDayFocusRequest,
                    tileContentStore: viewModel.tileContentStore,
                    thumbnailDirectory: viewModel.thumbnailDirectory,
                    detailReader: viewModel.tileDetailReader,
                    play: { viewModel.playStory(year: $0) },
                    clearFilters: viewModel.clearMediaFilter
                )
            }
        } else if viewModel.showsPlacesMap {
            PlacesMapView(
                map: viewModel.state.map ?? .empty,
                clusters: viewModel.mapClusters,
                cameraRequest: viewModel.mapCameraRequest,
                selection: viewModel.gridSelection.selection,
                emptyState: viewModel.state.mediaEmptyState,
                tileContentStore: viewModel.tileContentStore,
                thumbnailDirectory: viewModel.thumbnailDirectory,
                detailReader: viewModel.tileDetailReader,
                onViewportChanged: viewModel.mapViewportChanged,
                onClusterClick: viewModel.selectMapCluster,
                onClusterDoubleClick: viewModel.activateMapCluster,
                clearFilters: viewModel.clearMediaFilter
            )
        } else {
            browserContent
        }
    }

    @ViewBuilder
    private var browserContent: some View {
        switch viewModel.viewMode {
        case .grid:
            MediaGridView(
                title: viewModel.windowTitle,
                grid: viewModel.state.mediaGrid,
                tileContentStore: viewModel.tileContentStore,
                emptyState: viewModel.mediaEmptyState,
                deviceConnectionBanner: viewModel.state.deviceConnectionBanner,
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
                contextMenu: viewModel.makeMediaItemContextMenu,
                focusTargetID: viewModel.focusedAssetID,
                dismissedCameraBannerIdentities: viewModel.dismissedCameraBannerIdentities,
                onDismissCameraBanner: { viewModel.dismissCameraConnectionBanner($0.identity) }
            )
        case .loupe:
            LoupeView(
                grid: viewModel.state.mediaGrid,
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
                onPlayLivePhoto: { viewModel.playLivePhoto() }
            )
            .navigationTitle(viewModel.windowTitle)
        case .compare:
            CompareView(
                grid: viewModel.state.mediaGrid,
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
                contextMenu: viewModel.makeMediaItemContextMenu
            )
            .navigationTitle(viewModel.windowTitle)
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
                    Text("\(batch.assetCount) items")
                        .foregroundStyle(DesignPalette.l3(for: colorScheme))
                        .monospacedDigit()
                }
                .tag(batch.batchID)
            }
        }
        .navigationTitle("All Imports")
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

/// Presents the Person sheet for the person the view model names.
private struct PersonSheetHost: ViewModifier {
    let viewModel: CatalogWindowViewModel

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { viewModel.peopleSession.sheet },
            set: {
                if $0 == nil {
                    viewModel.cancelEditingPerson()
                }
            }
        )) { request in
            if let person = viewModel.peopleIndex.summaries[request.person] {
                PersonSheetView(
                    person: person,
                    refusal: { name, birthday in viewModel.personSheetRefusal(request.person, name: name, birthday: birthday) },
                    save: { name, birthday in viewModel.savePerson(request.person, name: name, birthday: birthday) },
                    cancel: viewModel.cancelEditingPerson
                )
            }
        }
    }
}
